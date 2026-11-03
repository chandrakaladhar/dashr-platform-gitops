#!/usr/bin/env bash
# Bring up (or repair) a local DASHR cluster from this repo, without
# `flux bootstrap`. Needs only read access to the Git repos. Safe to re-run:
# after a restart it re-applies everything and unseals OpenBao.
#
#   ./scripts/local-up.sh
#   BRANCH=my-feature ./scripts/local-up.sh          # follow your own branch
#   CLUSTER=kind ./scripts/local-up.sh               # kind instead of Docker Desktop
#
# Settings (environment variables):
#   CLUSTER       docker-desktop (default) or kind
#   KUBE_CONTEXT  kubectl context (default: docker-desktop, or kind-$KIND_NAME)
#   KIND_NAME     kind cluster name (default: dashr)
#   BRANCH        branch of this repo Flux follows (default: main). Must be pushed.
#   REPO_URL      this repo over HTTPS (default: the GitHub repo)
#   GITHUB_TOKEN  read-only token, only needed while the repos are private
#   CORP_CA_FILE  TLS-inspecting proxy root CA (PEM). On macOS the
#                 "$CORP_CA_NAME" (default: Zscaler Root CA) is found automatically.
#   APP_DIR       dashr-nova checkout, to build the app image (default: ../dashr-nova)
#   SKIP_IMAGE=1  don't build the app image
#   BAO_PORT      local port for the OpenBao port-forward (default: 8200)
#   WAIT_MINUTES  how long to wait for the tenants to become Ready (default: 30)
#
# The OpenBao unseal key and root token are saved to
# ~/.config/dashr/openbao-init-<context>.json (mode 600). That is fine for a
# throwaway local cluster; never do this for a shared one.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER="${CLUSTER:-docker-desktop}"
KIND_NAME="${KIND_NAME:-dashr}"
case "$CLUSTER" in
  docker-desktop) CTX="${KUBE_CONTEXT:-docker-desktop}" ;;
  kind)           CTX="${KUBE_CONTEXT:-kind-$KIND_NAME}" ;;
  *) echo "error: CLUSTER must be docker-desktop or kind" >&2; exit 1 ;;
esac
BRANCH="${BRANCH:-main}"
REPO_URL="${REPO_URL:-https://github.com/chandrakaladhar/dashr-platform-gitops}"
CORP_CA_NAME="${CORP_CA_NAME:-Zscaler Root CA}"
APP_DIR="${APP_DIR:-$ROOT/../dashr-nova}"
DEPLOY_DIR="${DEPLOY_DIR:-$ROOT/../dashr-nova-deploy}"
BAO_PORT="${BAO_PORT:-8200}"
BAO_ADDR="http://127.0.0.1:${BAO_PORT}"
WAIT_MINUTES="${WAIT_MINUTES:-30}"
STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/dashr"
INIT_FILE="$STATE_DIR/openbao-init-${CTX}.json"

WORK="$(mktemp -d)"
PF_PID=""
cleanup() {
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

step() { printf '\n==> %s\n' "$*"; }
die()  { echo "error: $*" >&2; exit 1; }
k()    { kubectl --context "$CTX" "$@"; }

# --- preflight ---------------------------------------------------------------
for tool in kubectl flux docker bao jq curl openssl git; do
  command -v "$tool" >/dev/null || die "$tool not found"
done
[ "$CLUSTER" = kind ] && { command -v kind >/dev/null || die "kind not found"; }

if ! git -C "$ROOT" ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
  echo "warning: branch '$BRANCH' not found on origin. Push it, or Flux has nothing to sync." >&2
fi

# --- CA bundle ---------------------------------------------------------------
# The committed local manifests reference Secret corp-ca everywhere, so it must
# exist on every machine. Behind a proxy it holds the proxy CA; otherwise (and
# in addition) the system roots, so hosts the proxy doesn't intercept still work.
step "CA bundle"
CORP_CA="$WORK/corp-ca.pem"
if [ -n "${CORP_CA_FILE:-}" ]; then
  cp "$CORP_CA_FILE" "$CORP_CA"
elif command -v security >/dev/null &&
     security find-certificate -c "$CORP_CA_NAME" -p /Library/Keychains/System.keychain > "$CORP_CA" 2>/dev/null; then
  :
else
  : > "$CORP_CA"
fi
if [ -s "$CORP_CA" ]; then
  HAVE_CORP_CA=1
  echo "TLS-inspecting proxy CA: $(openssl x509 -in "$CORP_CA" -noout -subject)"
else
  HAVE_CORP_CA=0
  echo "No proxy CA found; using system roots only."
fi
CA_BUNDLE="$WORK/ca.crt"
if [ -f /etc/ssl/certs/ca-certificates.crt ]; then
  cat /etc/ssl/certs/ca-certificates.crt > "$CA_BUNDLE"
else
  security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain > "$CA_BUNDLE"
fi
cat "$CORP_CA" >> "$CA_BUNDLE"

# --- image pull workaround (Docker Desktop behind a proxy) -------------------
# Docker Desktop's registry-mirror fails (500) on new images when TLS is
# intercepted. Pulling on the host fixes it; then the pod is recreated.
HEALED=" "
heal_image_pulls() {
  [ "$CLUSTER" = docker-desktop ] || return 0
  local ns pod image
  # process substitution, not a pipe, so HEALED survives the loop
  while read -r ns pod image; do
    case "$image" in registry.local/*) continue ;; esac   # built locally, never pulled
    case "$HEALED" in *" $image "*) continue ;; esac
    echo "    pulling $image on the host for $ns/$pod"
    docker pull -q "$image" >/dev/null && k -n "$ns" delete pod "$pod" --wait=false >/dev/null || true
    HEALED="$HEALED$image "
  done < <(k get pods -A -o json 2>/dev/null | jq -r '
    .items[] | . as $p
    | ((.status.initContainerStatuses // []) + (.status.containerStatuses // []))[]
    | select(.state.waiting.reason == "ImagePullBackOff" or .state.waiting.reason == "ErrImagePull")
    | "\($p.metadata.namespace) \($p.metadata.name) \(.image)"')
}

# wait_for <what> <seconds> <command...>: poll until the command succeeds
wait_for() {
  local what="$1" deadline=$((SECONDS + $2)); shift 2
  echo "    waiting for $what"
  until "$@" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || die "timed out waiting for $what (see: flux --context $CTX get all -A)"
    heal_image_pulls
    sleep 5
  done
}

# --- cluster -----------------------------------------------------------------
step "Cluster ($CTX)"
if [ "$CLUSTER" = kind ] && ! kind get clusters 2>/dev/null | grep -qx "$KIND_NAME"; then
  kind create cluster --name "$KIND_NAME"
fi
k get --raw /readyz >/dev/null 2>&1 || die "context '$CTX' is not reachable (is Kubernetes enabled in Docker Desktop?)"
if [ "$CLUSTER" = kind ] && [ "$HAVE_CORP_CA" = 1 ]; then
  # containerd on the node pulls images itself and needs the proxy CA too
  for node in $(kind get nodes --name "$KIND_NAME"); do
    docker cp "$CORP_CA" "$node:/usr/local/share/ca-certificates/corp-ca.crt"
    docker exec "$node" sh -c 'update-ca-certificates >/dev/null && systemctl restart containerd'
  done
fi

# --- Flux controllers ----------------------------------------------------------
# Installed from the committed manifests, so every developer runs the same
# Flux version as the repo. Re-running upgrades them after a version bump.
step "Flux controllers"
k apply --server-side --force-conflicts -f "$ROOT/clusters/local/flux-system/gotk-components.yaml" >/dev/null
wait_for "Flux controllers" 300 k -n flux-system wait deploy --all --for=condition=Available --timeout=5s

# --- secrets -------------------------------------------------------------------
step "Secrets"
GIT_AUTH=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
  GIT_AUTH=(--from-literal=username=git --from-literal=password="$GITHUB_TOKEN")
fi
# recreate <ns> <name> <args...>: replace a secret wholesale, so no stale keys
# (such as a bootstrap SSH identity) are left behind
recreate() {
  local ns="$1" name="$2"; shift 2
  k -n "$ns" delete secret "$name" --ignore-not-found >/dev/null
  k -n "$ns" create secret generic "$name" "$@" >/dev/null
  echo "    $ns/$name"
}
for ns in dashr-nova policy; do
  k create namespace "$ns" --dry-run=client -o yaml | k apply -f - >/dev/null
done
recreate flux-system flux-system --from-file=ca.crt="$CA_BUNDLE" ${GIT_AUTH[@]+"${GIT_AUTH[@]}"}
recreate flux-system corp-ca     --from-file=ca.crt="$CA_BUNDLE"
# tenants.yaml and the dashr-nova-deploy local overlay point every tenant
# GitRepository at corp-ca, so Git credentials for private repos go here too
recreate dashr-nova  corp-ca     --from-file=ca.crt="$CA_BUNDLE" ${GIT_AUTH[@]+"${GIT_AUTH[@]}"}
# OPA pulls policy bundles from an OCI registry (platform/opa/opa.yaml)
recreate policy      corp-ca     --from-file=ca.crt="$CA_BUNDLE"

# --- sync ----------------------------------------------------------------------
step "Sync $REPO_URL @ $BRANCH, path clusters/local"
# A cluster made with `flux bootstrap` has a flux-system Kustomization whose
# inventory includes the Flux controllers. Since the sync below ignores
# clusters/local/flux-system, that Kustomization would prune Flux itself.
# Detach it first: with prune off, deleting it leaves every object in place.
if k -n flux-system get kustomization flux-system >/dev/null 2>&1 &&
   [ "$(k -n flux-system get kustomization flux-system -o jsonpath='{.metadata.labels.dashr\.local/managed-by}')" != local-up ]; then
  echo "    detaching the bootstrap sync"
  k -n flux-system patch kustomization flux-system --type=merge -p '{"spec":{"prune":false}}' >/dev/null
  k -n flux-system delete kustomization flux-system >/dev/null
fi
k apply -f - >/dev/null <<EOF
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: flux-system
  namespace: flux-system
  labels:
    dashr.local/managed-by: local-up
spec:
  interval: 1m
  url: ${REPO_URL}
  ref:
    branch: ${BRANCH}
  secretRef:
    name: flux-system
  # The committed flux-system/ is for bootstrapped clusters (SSH, main).
  # Applying it here would repoint this cluster, so it is left out.
  ignore: |
    /.git/
    /clusters/local/flux-system/
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flux-system
  namespace: flux-system
  labels:
    dashr.local/managed-by: local-up
spec:
  interval: 10m
  path: ./clusters/local
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
EOF
flux --context "$CTX" reconcile source git flux-system >/dev/null ||
  die "Flux can't fetch $REPO_URL@$BRANCH (private repo? set GITHUB_TOKEN)"

# --- app image -----------------------------------------------------------------
# The local overlay runs a locally built image (pullPolicy Never) at the tag in
# dashr-nova-deploy/overlays/local/helmrelease-patch.yaml.
if [ "${SKIP_IMAGE:-0}" != 1 ]; then
  step "App image"
  PATCH="$DEPLOY_DIR/overlays/local/helmrelease-patch.yaml"
  if [ ! -x "$APP_DIR/scripts/build-local.sh" ] || [ ! -f "$PATCH" ]; then
    echo "Skipping: needs dashr-nova at $APP_DIR and dashr-nova-deploy at $DEPLOY_DIR (set APP_DIR / DEPLOY_DIR)."
  else
    TAG="$(sed -n 's/^ *tag: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "$PATCH" | head -1)"
    [ -n "$TAG" ] || die "no image tag in $PATCH"
    echo "Building dashr-nova:$TAG (the tag in your dashr-nova-deploy checkout; Flux deploys the one on main)"
    CA_ARG=()
    [ "$HAVE_CORP_CA" = 1 ] && CA_ARG=(env CORP_CA_FILE="$CORP_CA")
    if [ "$CLUSTER" = kind ]; then
      ${CA_ARG[@]+"${CA_ARG[@]}"} "$APP_DIR/scripts/build-local.sh" "$TAG" kind "$KIND_NAME"
    else
      ${CA_ARG[@]+"${CA_ARG[@]}"} "$APP_DIR/scripts/build-local.sh" "$TAG" docker-desktop "$CTX"
    fi
  fi
fi

# --- OpenBao (README Phase B) ----------------------------------------------------
step "OpenBao"
openbao_running() { [ "$(k -n openbao get pod openbao-0 -o jsonpath='{.status.phase}')" = Running ]; }
wait_for "openbao-0 (infra and platform must reconcile first)" 900 openbao_running

k -n openbao port-forward pod/openbao-0 "$BAO_PORT:8200" >/dev/null 2>&1 &
PF_PID=$!
wait_for "port-forward to OpenBao on :$BAO_PORT" 30 curl -fsS "$BAO_ADDR/v1/sys/seal-status"
export BAO_ADDR

STATUS="$(curl -fsS "$BAO_ADDR/v1/sys/seal-status")"
if [ "$(jq -r .initialized <<<"$STATUS")" != true ]; then
  mkdir -p "$STATE_DIR"
  if [ -e "$INIT_FILE" ]; then
    # left over from an earlier cluster with this context name; its data is gone
    mv "$INIT_FILE" "$INIT_FILE.$(date +%Y%m%d%H%M%S).old"
  fi
  (umask 077; curl -fsS -X PUT "$BAO_ADDR/v1/sys/init" \
     -d '{"secret_shares":1,"secret_threshold":1}' > "$INIT_FILE")
  echo "Initialised. Unseal key and root token saved to $INIT_FILE"
  STATUS="$(curl -fsS "$BAO_ADDR/v1/sys/seal-status")"
fi

if [ "$(jq -r .sealed <<<"$STATUS")" = true ]; then
  [ -f "$INIT_FILE" ] || die "OpenBao is sealed and $INIT_FILE is missing. Run ./scripts/unseal.sh with your key, then re-run with BAO_TOKEN set."
  jq '{key: .keys_base64[0]}' "$INIT_FILE" | curl -fsS -X PUT "$BAO_ADDR/v1/sys/unseal" -d @- >/dev/null
  echo "Unsealed."
fi

if [ -z "${BAO_TOKEN:-}" ]; then
  [ -f "$INIT_FILE" ] || die "set BAO_TOKEN (no $INIT_FILE to read the root token from)"
  BAO_TOKEN="$(jq -r .root_token "$INIT_FILE")"
fi
export BAO_TOKEN
"$ROOT/scripts/configure-openbao.sh"
"$ROOT/scripts/seed-secrets.sh"

# ExternalSecrets that failed while OpenBao was sealed back off; nudge them.
k get externalsecrets -A --no-headers 2>/dev/null | while read -r ns name _; do
  k -n "$ns" annotate externalsecret "$name" force-sync="$(date +%s)" --overwrite >/dev/null
done
flux --context "$CTX" reconcile kustomization platform-secrets >/dev/null 2>&1 || true

# --- wait for the app ------------------------------------------------------------
step "Postgres, Temporal and tenants (up to ${WAIT_MINUTES}m; Ctrl-C is safe, Flux carries on)"
wait_for "the tenants Kustomization" $((WAIT_MINUTES * 60)) \
  k -n flux-system wait kustomization/tenants --for=condition=Ready --timeout=5s
flux --context "$CTX" get kustomizations -A

cat <<EOF

Local cluster is up, following $BRANCH.
  App:       kubectl --context $CTX -n dashr-nova port-forward svc/dashr-nova 8080:80  -> http://localhost:8080
  Status:    flux --context $CTX get kustomizations -A
  New build: bump image.tag in dashr-nova-deploy/overlays/local/helmrelease-patch.yaml, push, re-run
  OpenBao:   unseal key and root token in $INIT_FILE
After a Docker Desktop or node restart, re-run this script (it unseals OpenBao).
EOF
