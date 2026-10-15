#!/usr/bin/env bash
# Phase B, step 1: configure OpenBao for this platform. Safe to re-run.
# Contains no secret values, only engines, auth, policies and roles.
#
# OpenBao runs inside the local cluster (production uses AWS Secrets Manager):
#   export BAO_ADDR=http://127.0.0.1:8200     # via kubectl port-forward
#   bao login
#   ./scripts/configure-openbao.sh
#
# AUTH_MOUNT must match openbao_auth_mount in clusters/local/cluster-vars.yaml.
set -euo pipefail

AUTH_MOUNT="${AUTH_MOUNT:-kubernetes}"
KV_MOUNT="kv"

command -v bao >/dev/null || { echo "error: bao CLI not found" >&2; exit 1; }
bao token lookup >/dev/null 2>&1 || { echo "error: not logged in (run: bao login)" >&2; exit 1; }

# --- secrets engine -------------------------------------------------------
if ! bao secrets list -format=json | grep -q "\"${KV_MOUNT}/\""; then
  bao secrets enable -path="$KV_MOUNT" kv-v2
fi

# --- kubernetes auth for this cluster ---------------------------------------
if ! bao auth list -format=json | grep -q "\"${AUTH_MOUNT}/\""; then
  bao auth enable -path="$AUTH_MOUNT" kubernetes
fi

# OpenBao uses its own service account to call TokenReview.
bao write "auth/${AUTH_MOUNT}/config" kubernetes_host="https://kubernetes.default.svc:443"

# --- policies and roles -------------------------------------------------------
# role_for <namespace> <policy>: bind the namespace's external-secrets-reader SA
role_for() {
  bao write "auth/${AUTH_MOUNT}/role/$2" \
    bound_service_account_names=external-secrets-reader \
    bound_service_account_namespaces="$1" \
    token_policies="$2" \
    token_ttl=1h
}

# The database namespace reads every component's DB credentials: CNPG manages all roles.
bao policy write database - <<POLICY
path "${KV_MOUNT}/data/+/db" { capabilities = ["read"] }
POLICY
role_for database database

# Each component reads only its own path.
for component in temporal dashr-nova; do
  bao policy write "$component" - <<POLICY
path "${KV_MOUNT}/data/${component}/*" { capabilities = ["read"] }
POLICY
  role_for "$component" "$component"
done

echo "OpenBao configured (auth mount: ${AUTH_MOUNT}). Next: ./scripts/seed-secrets.sh"
