#!/usr/bin/env bash
set -euo pipefail

# Użycie:
#   VAULT_ADDR=https://vault.example.com \
#   VAULT_ROLE_ID=... VAULT_SECRET_ID=... \
#   ./scripts/sync-env-to-vault.sh secret/myapp/prod [.env.example]
#
# Wymagania: vault CLI, jq
# Dodatkowe zmienne:
#   VAULT_NAMESPACE   (opcjonalnie, Vault Enterprise)
#   VAULT_AUTH_PATH   (domyślnie: auth/approle)
#   DRY_RUN=1         (jeśli chcesz zobaczyć co doda bez zapisu)

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
EXISTING_KEYS=$(echo "$EXISTING_JSON" | jq -r '.data.data | keys[]?' 2>/dev/null || true)

declare -A EXIST
for k in $EXISTING_KEYS; do EXIST["$k"]=1; done

declare -A TO_PUT
FAIL=0

# --- Parsowanie .env.example ---
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  # dopuszczamy "export KEY=VALUE"
  if [[ "$line" =~ ^[[:space:]]*export[[:space:]]+ ]]; then
    line="${line#*export }"
  fi
  # tylko KEY=VALUE
  if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
    key="${line%%=*}"
    value="${line#*=}"
    key="$(echo -n "$key" | xargs)"

    # usuń CR i otaczające pojedyncze/podwójne cudzysłowy
    value="${value%$'\r'}"
    value="$(printf "%s" "$value" | sed -e 's/^"//; s/"$//' -e "s/^'//; s/'$//")"

    # pomiń jeśli już jest w Vault
    if [[ -z "${EXIST[$key]:-}" ]]; then
      # marker pól wymagających ręcznego ustawienia
      if [[ "$value" =~ ^\<required\>$|^__SECRET__$|^REQUIRED$ ]]; then
        echo "✗ Brak wartości dla wymagającego klucza: $key — ustaw ręcznie w Vault."
        FAIL=1
      else
        TO_PUT["$key"]="$value"
      fi
    fi
  fi
done < "$ENV_FILE"

# --- Zapis brakujących kluczy ---
if (( ${#TO_PUT[@]} > 0 )); then
  echo "➜ Dodaję ${#TO_PUT[@]} klucze do $VAULT_PATH: ${!TO_PUT[@]}"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "DRY_RUN=1 — pominąłem zapis."
  else
    ARGS=()
    for k in "${!TO_PUT[@]}"; do ARGS+=("$k=${TO_PUT[$k]}"); done
    VAULT_NAMESPACE="$VAULT_NAMESPACE" vault kv patch "$VAULT_PATH" "${ARGS[@]}"
  fi
else
  echo "✓ Brak brakujących kluczy."
fi

exit $FAIL
