#!/usr/bin/env bash
set -euo pipefail

# Użycie:
#   VAULT_ADDR=https://vault.example.com \
#   VAULT_ROLE_ID=... VAULT_SECRET_ID=... \
#   ./scripts/sync-env-to-vault.sh secret/myapp/prod [.env.example]
#
# Wymagania: vault CLI, jq
# Zmienne opcjonalne:
#   VAULT_NAMESPACE   (Vault Enterprise)
#   VAULT_AUTH_PATH   (domyślnie: auth/approle)
#   DRY_RUN=1         (pokaż zmiany bez zapisu)

VAULT_PATH="${1:-}"
ENV_FILE="${2:-.env.example}"
[[ -z "$VAULT_PATH" ]] && { echo "usage: $0 <kv-path> [envfile]" >&2; exit 2; }
[[ -f "$ENV_FILE" ]] || { echo "Brak pliku $ENV_FILE" >&2; exit 2; }

: "${VAULT_ADDR:?Brak VAULT_ADDR}"
: "${VAULT_AUTH_PATH:=auth/approle}"
: "${VAULT_NAMESPACE:=}"

# --- AppRole auto-login jeśli brak VAULT_TOKEN ---
if [[ -z "${VAULT_TOKEN:-}" ]]; then
  if [[ -n "${VAULT_ROLE_ID:-}" && -n "${VAULT_SECRET_ID:-}" ]]; then
    echo "Logowanie do Vault przez AppRole ($VAULT_AUTH_PATH)..."
    LOGIN_JSON=$(VAULT_NAMESPACE="$VAULT_NAMESPACE" vault write -format=json \
      "$VAULT_AUTH_PATH/login" role_id="$VAULT_ROLE_ID" secret_id="$VAULT_SECRET_ID")
    export VAULT_TOKEN
    VAULT_TOKEN=$(echo "$LOGIN_JSON" | jq -r '.auth.client_token')
  else
    echo "Brak VAULT_TOKEN oraz (VAULT_ROLE_ID/VAULT_SECRET_ID) — nie mogę się zalogować." >&2
    exit 1
  fi
fi

# --- Pobierz istniejące klucze (KV v2: .data.data) ---
EXISTING_JSON=$(VAULT_NAMESPACE="$VAULT_NAMESPACE" vault kv get -format=json "$VAULT_PATH" 2>/dev/null || echo '{}')

# Mapy istniejących kluczy i wartości
declare -A EXIST EXIST_VALS
while IFS=$'\t' read -r k v; do
  [[ -z "${k:-}" ]] && continue
  EXIST["$k"]=1
  EXIST_VALS["$k"]="$v"
done < <(echo "$EXISTING_JSON" | jq -r '.data.data | to_entries[]? | "\(.key)\t\(.value)"')

# --- Parsuj .env.example: klucze docelowe + wartości domyślne (gdy nie "required") ---
declare -A DESIRED DESIRED_VALS
declare -a REQUIRED_MISSING=()

is_required_value() {
  [[ "$1" =~ ^\<required\>$|^__SECRET__$|^REQUIRED$ ]]
}

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  # obsługa "export KEY=VALUE"
  if [[ "$line" =~ ^[[:space:]]*export[[:space:]]+ ]]; then
    line="${line#*export }"
  fi
  # tylko KEY=VALUE
  if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
    key="${line%%=*}"
    value="${line#*=}"
    key="$(echo -n "$key" | xargs)"

    # usuń CR i otaczające cudzysłowy
    value="${value%$'\r'}"
    value="$(printf "%s" "$value" | sed -e 's/^"//; s/"$//' -e "s/^'//; s/'$//")"

    DESIRED["$key"]=1
    if is_required_value "$value"; then
      # jeśli w Vault nie ma wartości dla required -> zgłoś błąd
      if [[ -z "${EXIST[$key]:-}" ]]; then
        REQUIRED_MISSING+=("$key")
      fi
      # nie ustawiaj domyślnej wartości
    else
      DESIRED_VALS["$key"]="$value"
    fi
  fi
done < "$ENV_FILE"

# --- Wyznacz zestawy zmian ---
declare -a TO_ADD=() TO_DELETE=() TO_KEEP=()

# Do dodania: klucze z .env.example, których nie ma w Vault i nie są "required"
for k in "${!DESIRED[@]}"; do
  if [[ -z "${EXIST[$k]:-}" ]]; then
    if [[ -n "${DESIRED_VALS[$k]:-}" ]]; then
      TO_ADD+=("$k")
    fi
  else
    TO_KEEP+=("$k")
  fi
done

# Do usunięcia: klucze, które są w Vault, a nie ma ich w .env.example
for k in "${!EXIST[@]}"; do
  if [[ -z "${DESIRED[$k]:-}" ]]; then
    TO_DELETE+=("$k")
  fi
done

# --- Zbuduj nowy zestaw danych do wgrania (PUT nadpisze całość wersji) ---
declare -A NEW_DATA
# 1) Zostaw istniejące wartości dla kluczy, które są w schemacie
for k in "${TO_KEEP[@]}"; do
  NEW_DATA["$k"]="${EXIST_VALS[$k]}"
done
# 2) Dodaj nowe klucze z wartościami z .env.example
for k in "${TO_ADD[@]}"; do
  NEW_DATA["$k"]="${DESIRED_VALS[$k]}"
done
# Klucze z TO_DELETE NIE są w NEW_DATA -> będą „wycięte”

# --- Raport zmian ---
echo "Stan docelowy ($VAULT_PATH):"
echo "  • Zostają:  ${#TO_KEEP[@]}  -> ${TO_KEEP[*]:-—}"
echo "  • Do dodania: ${#TO_ADD[@]} -> ${TO_ADD[*]:-—}"
echo "  • Do usunięcia: ${#TO_DELETE[@]} -> ${TO_DELETE[*]:-—}"

if (( ${#REQUIRED_MISSING[@]} > 0 )); then
  echo "✗ Brakuje wartości dla wymaganych kluczy (oznaczonych w .env.example): ${REQUIRED_MISSING[*]}" >&2
  FAIL=1
else
  FAIL=0
fi

# Brak zmian?
if (( ${#TO_ADD[@]} == 0 && ${#TO_DELETE[@]} == 0 )); then
  echo "✓ Brak zmian do zastosowania."
  exit $FAIL
fi

# --- Zapis nowej wersji (PUT) lub DRY_RUN ---
if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "DRY_RUN=1 — pominąłem zapis do Vault."
else
  # Zbuduj argumenty key=value (jeden element tablicy na parę, żeby zachować spacje i '=')
  ARGS=()
  for k in "${!NEW_DATA[@]}"; do
    ARGS+=("$k=${NEW_DATA[$k]}")
  done
  echo "➜ Wgrywam nową wersję sekreta (z pruningiem): ${#ARGS[@]} kluczy."
  VAULT_NAMESPACE="$VAULT_NAMESPACE" vault kv put "$VAULT_PATH" "${ARGS[@]}"
fi

exit $FAIL
