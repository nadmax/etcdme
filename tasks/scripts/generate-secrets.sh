#!/usr/bin/env bash
# Generate secrets for cluster deployment
# Usage: ./generate-secrets.sh <overlay-name>
#
# Idempotent: Only generates missing secrets, preserves existing ones.
# External credentials (AWS, AGE key) must be provided via environment variables.

set -euo pipefail

OVERLAY="${1:-etcdme-nbg1-dc3}"
SECRETS_FILE="argocd/overlays/${OVERLAY}/secrets.sops.yaml"
EXAMPLE_FILE="argocd/overlays/${OVERLAY}/secrets.example.yaml"
TEMP_FILE=$(mktemp)
DECRYPTED_FILE=$(mktemp)

trap "rm -f $TEMP_FILE $DECRYPTED_FILE" EXIT

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Generate random password (32 chars, alphanumeric)
gen_password() {
  openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32
}

# Extract value from YAML by key pattern (simple grep-based)
get_existing_value() {
  local key="$1"
  local file="$2"
  grep -E "^\s+${key}:" "$file" 2>/dev/null | head -1 | sed "s/.*${key}: *//" | tr -d '\r'
}

echo -e "${GREEN}=== Cluster Secrets Generator (Idempotent) ===${NC}"
echo ""

# Check required external variables
missing_vars=()
[[ -z "${AWS_ACCESS_KEY_ID:-}" ]] && missing_vars+=("AWS_ACCESS_KEY_ID")
[[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]] && missing_vars+=("AWS_SECRET_ACCESS_KEY")
[[ -z "${AWS_HOSTED_ZONE_ID:-}" ]] && missing_vars+=("AWS_HOSTED_ZONE_ID")
[[ -z "${SOPS_AGE_KEY:-}" ]] && missing_vars+=("SOPS_AGE_KEY")

if [[ ${#missing_vars[@]} -gt 0 ]]; then
  echo -e "${RED}Error: Missing required environment variables:${NC}"
  for var in "${missing_vars[@]}"; do
    echo "  - $var"
  done
  echo ""
  echo "Configure these in .env (see .env.example)"
  exit 1
fi

# Check example file exists
if [[ ! -f "$EXAMPLE_FILE" ]]; then
  echo -e "${RED}Error: Example file not found: ${EXAMPLE_FILE}${NC}"
  exit 1
fi

echo -e "${YELLOW}Overlay: ${OVERLAY}${NC}"
echo ""

# Check if secrets file already exists and decrypt it
EXISTING_SECRETS=false
if [[ -f "$SECRETS_FILE" ]]; then
  echo -e "${YELLOW}Existing secrets file found, preserving values...${NC}"
  if sops -d "$SECRETS_FILE" > "$DECRYPTED_FILE" 2>/dev/null; then
    EXISTING_SECRETS=true
    echo -e "${GREEN}Decrypted existing secrets${NC}"
  else
    echo -e "${YELLOW}Warning: Could not decrypt existing file, starting fresh${NC}"
  fi
  echo ""
fi

# Function to get value - use existing if available, otherwise generate/use env
get_or_generate() {
  local key="$1"
  local default_action="$2"  # "generate", "env:VAR_NAME", or "literal:value"

  if [[ "$EXISTING_SECRETS" == "true" ]]; then
    local existing=$(get_existing_value "$key" "$DECRYPTED_FILE")
    # Check if value exists and is not a placeholder
    if [[ -n "$existing" && ! "$existing" =~ ^REPLACE ]]; then
      echo "$existing"
      return
    fi
  fi

  # Generate new value
  case "$default_action" in
    generate)
      gen_password
      ;;
    env:*)
      local var_name="${default_action#env:}"
      echo "${!var_name}"
      ;;
    literal:*)
      echo "${default_action#literal:}"
      ;;
  esac
}

echo "Resolving secrets (preserving existing, generating missing)..."
echo ""

# Get or generate all secrets
KEYCLOAK_DB_PASSWORD=$(get_or_generate "db-password" "generate")
GRAFANA_ADMIN_PASSWORD=$(get_or_generate "admin-password" "generate")
ARGOCD_SERVER_SECRET=$(get_or_generate "server.secretkey" "generate")
N8N_ENCRYPTION_KEY=$(get_or_generate "N8N_ENCRYPTION_KEY" "generate")

# For secrets that appear multiple times, we need specific handling
if [[ "$EXISTING_SECRETS" == "true" ]]; then
  # Extract n8n specific secrets from their namespace context
  N8N_CLIENT_SECRET=$(grep -A5 "name: n8n-oauth2-proxy" "$DECRYPTED_FILE" | get_existing_value "client-secret" /dev/stdin || gen_password)
  N8N_COOKIE_SECRET=$(grep -A5 "name: n8n-oauth2-proxy" "$DECRYPTED_FILE" | get_existing_value "cookie-secret" /dev/stdin || gen_password)
  N8N_DB_PASSWORD=$(grep -A5 "name: n8n-postgres" "$DECRYPTED_FILE" | get_existing_value "postgres-password" /dev/stdin || gen_password)

  # Uptime Kuma secrets
  UPTIME_KUMA_ADMIN_PASSWORD=$(grep -A5 "name: uptime-kuma-admin" "$DECRYPTED_FILE" | get_existing_value "password" /dev/stdin || gen_password)
  UPTIME_KUMA_CLIENT_SECRET=$(grep -A5 "name: uptime-kuma-oauth2-proxy" "$DECRYPTED_FILE" | get_existing_value "client-secret" /dev/stdin || gen_password)
  UPTIME_KUMA_COOKIE_SECRET=$(grep -A5 "name: uptime-kuma-oauth2-proxy" "$DECRYPTED_FILE" | get_existing_value "cookie-secret" /dev/stdin || gen_password)
else
  N8N_CLIENT_SECRET=$(gen_password)
  N8N_COOKIE_SECRET=$(gen_password)
  N8N_DB_PASSWORD=$(gen_password)
  UPTIME_KUMA_ADMIN_PASSWORD=$(gen_password)
  UPTIME_KUMA_CLIENT_SECRET=$(gen_password)
  UPTIME_KUMA_COOKIE_SECRET=$(gen_password)
fi

# Handle empty values from failed greps
[[ -z "$N8N_CLIENT_SECRET" || "$N8N_CLIENT_SECRET" =~ ^REPLACE ]] && N8N_CLIENT_SECRET=$(gen_password)
[[ -z "$N8N_COOKIE_SECRET" || "$N8N_COOKIE_SECRET" =~ ^REPLACE ]] && N8N_COOKIE_SECRET=$(gen_password)
[[ -z "$N8N_DB_PASSWORD" || "$N8N_DB_PASSWORD" =~ ^REPLACE ]] && N8N_DB_PASSWORD=$(gen_password)
[[ -z "$UPTIME_KUMA_ADMIN_PASSWORD" || "$UPTIME_KUMA_ADMIN_PASSWORD" =~ ^REPLACE ]] && UPTIME_KUMA_ADMIN_PASSWORD=$(gen_password)
[[ -z "$UPTIME_KUMA_CLIENT_SECRET" || "$UPTIME_KUMA_CLIENT_SECRET" =~ ^REPLACE ]] && UPTIME_KUMA_CLIENT_SECRET=$(gen_password)
[[ -z "$UPTIME_KUMA_COOKIE_SECRET" || "$UPTIME_KUMA_COOKIE_SECRET" =~ ^REPLACE ]] && UPTIME_KUMA_COOKIE_SECRET=$(gen_password)

echo "Secrets resolved:"
echo "  - Keycloak DB password: $(if [[ "$EXISTING_SECRETS" == "true" ]]; then echo "preserved"; else echo "generated"; fi)"
echo "  - Grafana admin password: $(if [[ "$EXISTING_SECRETS" == "true" ]]; then echo "preserved"; else echo "generated"; fi)"
echo "  - ArgoCD server secret: $(if [[ "$EXISTING_SECRETS" == "true" ]]; then echo "preserved"; else echo "generated"; fi)"
echo "  - n8n secrets: $(if [[ "$EXISTING_SECRETS" == "true" ]]; then echo "preserved/generated"; else echo "generated"; fi)"
echo "  - Uptime Kuma secrets: $(if [[ "$EXISTING_SECRETS" == "true" ]]; then echo "preserved/generated"; else echo "generated"; fi)"
echo ""

# Copy example and replace values
cp "$EXAMPLE_FILE" "$TEMP_FILE"

# Replace external (AWS + AGE)
sed -i "s|access-key-id: REPLACE_ME|access-key-id: ${AWS_ACCESS_KEY_ID}|" "$TEMP_FILE"
sed -i "s|secret-access-key: REPLACE_ME|secret-access-key: ${AWS_SECRET_ACCESS_KEY}|" "$TEMP_FILE"
sed -i "s|hosted-zone-id: REPLACE_ME|hosted-zone-id: ${AWS_HOSTED_ZONE_ID}|" "$TEMP_FILE"
sed -i "s|# AGE-SECRET-KEY-REPLACE_ME|${SOPS_AGE_KEY}|" "$TEMP_FILE"

# Replace generated secrets
# Keycloak DB
sed -i "s|db-password: REPLACE_ME|db-password: ${KEYCLOAK_DB_PASSWORD}|" "$TEMP_FILE"

# Postgres (must match keycloak db-password)
sed -i "0,/password: REPLACE_ME/s|password: REPLACE_ME|password: ${KEYCLOAK_DB_PASSWORD}|" "$TEMP_FILE"

# Grafana admin
sed -i "s|admin-password: REPLACE_ME|admin-password: ${GRAFANA_ADMIN_PASSWORD}|" "$TEMP_FILE"

# ArgoCD server secret
sed -i "s|server.secretkey: REPLACE_ME|server.secretkey: ${ARGOCD_SERVER_SECRET}|" "$TEMP_FILE"

# n8n secrets
sed -i "s|client-secret: REPLACE_N8N_CLIENT_SECRET|client-secret: ${N8N_CLIENT_SECRET}|g" "$TEMP_FILE"
sed -i "s|cookie-secret: REPLACE_N8N_COOKIE_SECRET|cookie-secret: ${N8N_COOKIE_SECRET}|" "$TEMP_FILE"
sed -i "s|DB_POSTGRESDB_PASSWORD: REPLACE_N8N_DB_PASSWORD|DB_POSTGRESDB_PASSWORD: ${N8N_DB_PASSWORD}|" "$TEMP_FILE"
sed -i "s|password: REPLACE_N8N_DB_PASSWORD|password: ${N8N_DB_PASSWORD}|" "$TEMP_FILE"
sed -i "s|postgres-password: REPLACE_N8N_DB_PASSWORD|postgres-password: ${N8N_DB_PASSWORD}|" "$TEMP_FILE"
sed -i "s|N8N_ENCRYPTION_KEY: REPLACE_N8N_ENCRYPTION_KEY|N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}|" "$TEMP_FILE"

# Uptime Kuma secrets
sed -i "s|password: REPLACE_UPTIME_KUMA_ADMIN_PASSWORD|password: ${UPTIME_KUMA_ADMIN_PASSWORD}|" "$TEMP_FILE"
sed -i "s|client-secret: REPLACE_UPTIME_KUMA_CLIENT_SECRET|client-secret: ${UPTIME_KUMA_CLIENT_SECRET}|g" "$TEMP_FILE"
sed -i "s|cookie-secret: REPLACE_UPTIME_KUMA_COOKIE_SECRET|cookie-secret: ${UPTIME_KUMA_COOKIE_SECRET}|" "$TEMP_FILE"

# Move temp file to final location
mv "$TEMP_FILE" "$SECRETS_FILE"

echo -e "${GREEN}Secrets file created: ${SECRETS_FILE}${NC}"
echo ""

# Encrypt with SOPS
echo -e "${YELLOW}Encrypting with SOPS...${NC}"
sops -e -i "$SECRETS_FILE"

echo ""
echo -e "${GREEN}Done! Encrypted secrets file ready.${NC}"
echo ""
echo "Next steps:"
echo "  1. Commit: git add ${SECRETS_FILE} && git commit -m 'chore: update secrets'"
echo "  2. Push: git push"
echo "  3. ArgoCD will sync automatically"
