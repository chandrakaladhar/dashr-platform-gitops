#!/usr/bin/env bash
# Give the local cluster a TLS certificate for https://localhost:8443
# (Keycloak, keycloak_url in clusters/local/cluster-vars.yaml).
#
#   ./scripts/local-tls.sh
#
# Uses mkcert (brew install mkcert): a local certificate authority that this
# machine trusts (macOS keychain, and so Chrome, Safari and Node with
# --use-system-ca). The CA's private key stays in `mkcert -CAROOT` on this
# machine; only the localhost certificate and its key go into the cluster, as
# Secret istio-ingress/localhost-tls, which the gateway's port 8443 serves
# (clusters/local/infrastructure.yaml). Nothing is committed.
#
# Safe to re-run: it reuses the CA, issues a fresh certificate (valid about
# two years) and replaces the Secret. The first run asks for your macOS
# password to trust the CA. local-up.sh runs it when mkcert is installed.
#
# Settings (environment variables):
#   KUBE_CONTEXT  kubectl context (default: docker-desktop)
set -euo pipefail

CTX="${KUBE_CONTEXT:-docker-desktop}"
NS=istio-ingress
SECRET=localhost-tls

die() { echo "error: $*" >&2; exit 1; }
k()   { kubectl --context "$CTX" "$@"; }

command -v mkcert  >/dev/null || die "mkcert not found: brew install mkcert"
command -v kubectl >/dev/null || die "kubectl not found"

# Trusts the CA in the system keychain (asks once; a no-op afterwards).
mkcert -install

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkcert -cert-file "$WORK/tls.crt" -key-file "$WORK/tls.key" localhost 127.0.0.1 ::1 >/dev/null 2>&1

# Flux owns the namespace once the cluster is synced; only create it if missing.
k get namespace "$NS" >/dev/null 2>&1 || k create namespace "$NS" >/dev/null
k -n "$NS" create secret tls "$SECRET" --cert="$WORK/tls.crt" --key="$WORK/tls.key" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
echo "    $NS/$SECRET (localhost, 127.0.0.1, ::1; CA $(mkcert -CAROOT)/rootCA.pem)"
