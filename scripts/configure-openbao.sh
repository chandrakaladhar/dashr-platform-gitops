#!/usr/bin/env bash
# Phase B, step 1: configure OpenBao for this platform. Safe to re-run.
# Contains no secret values, only engines, auth, policies and roles.
#
# Local (OpenBao inside the cluster):
#   export BAO_ADDR=http://127.0.0.1:8200     # via kubectl port-forward
#   bao login
#   ./scripts/configure-openbao.sh
#
# Production (OpenBao outside the cluster), run once per cluster:
#   export BAO_ADDR=https://openbao.example.internal:8200
#   bao login
#   MODE=external AUTH_MOUNT=kubernetes-production \
#   K8S_HOST=https://<api-server>:6443 ./scripts/configure-openbao.sh
#   (kubectl must point at that cluster; Flux must have applied platform/openbao-reviewer)
#
# AUTH_MOUNT must match openbao_auth_mount in clusters/<env>/cluster-vars.yaml.
set -euo pipefail

MODE="${MODE:-in-cluster}"
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

if [ "$MODE" = "in-cluster" ]; then
  # OpenBao uses its own service account to call TokenReview.
  bao write "auth/${AUTH_MOUNT}/config" kubernetes_host="https://kubernetes.default.svc:443"
elif [ "$MODE" = "external" ]; then
  : "${K8S_HOST:?set K8S_HOST to the cluster API server URL}"
  tmp="$(mktemp -d)"; chmod 700 "$tmp"; trap 'rm -rf "$tmp"' EXIT
  kubectl get secret openbao-token-reviewer -n openbao-auth -o jsonpath='{.data.token}'  | base64 -d > "$tmp/jwt"
  kubectl get secret openbao-token-reviewer -n openbao-auth -o jsonpath='{.data.ca\.crt}' | base64 -d > "$tmp/ca.crt"
  bao write "auth/${AUTH_MOUNT}/config" \
    kubernetes_host="$K8S_HOST" \
    kubernetes_ca_cert=@"$tmp/ca.crt" \
    token_reviewer_jwt=@"$tmp/jwt"
else
  echo "error: MODE must be in-cluster or external" >&2; exit 1
fi

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
