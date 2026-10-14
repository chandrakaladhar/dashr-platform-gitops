#!/usr/bin/env bash
# Phase B, step 2: create credentials that don't exist yet. Never overwrites.
# Passwords are generated here and piped straight into OpenBao, so they never
# appear in shell history, the process list, or Git.
#
#   ./scripts/seed-secrets.sh
#
# To rotate one: bao kv put kv/<component>/db username=<user> password=-  (paste or pipe)
# ESO picks it up within refreshInterval; CNPG updates the role automatically.
set -euo pipefail

KV_MOUNT="kv"
command -v bao >/dev/null     || { echo "error: bao CLI not found" >&2; exit 1; }
command -v openssl >/dev/null || { echo "error: openssl not found" >&2; exit 1; }

# seed_db <component> <postgres username>
seed_db() {
  local path="${KV_MOUNT}/$1/db"
  if bao kv get "$path" >/dev/null 2>&1; then
    echo "exists, skipping: $path"
  else
    # hex keeps passwords URL-safe for connection strings
    openssl rand -hex 24 | bao kv put "$path" username="$2" password=- >/dev/null
    echo "created: $path"
  fi
}

seed_db dashr-nova dashr_nova
seed_db temporal   temporal
seed_db harbor     harbor

echo "Done. Flux will unblock platform-secrets on its next retry, or run:"
echo "  flux reconcile kustomization platform-secrets"
