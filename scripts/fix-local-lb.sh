#!/usr/bin/env bash
# Repair localhost access to the local cluster after Docker Desktop restarts.
#
#   ./scripts/fix-local-lb.sh
#
# Docker Desktop's kind cluster gets LoadBalancer services from
# cloud-provider-kind: one Envoy container per service (kindccm-*) publishes
# its ports on localhost and forwards them to the node's NodePorts. When Docker
# Desktop restarts, the node can come back on a new IP while those Envoys keep
# forwarding to the old one. Pods are Running, but localhost:8443 (Keycloak)
# and localhost:80 return "Empty reply from server".
#
# This script compares each Envoy's targets with the node's current IP and, if
# any are stale, restarts the kind-cloud-provider container so it rewrites
# them. It changes nothing when the targets are already right.
#
# Settings (environment variables):
#   KUBE_CONTEXT  kubectl context (default: docker-desktop)
#   CCM_NAME      cloud-provider-kind container (default: kind-cloud-provider)
#   TIMEOUT       seconds to wait for the new targets (default: 60)
set -euo pipefail

CTX="${KUBE_CONTEXT:-docker-desktop}"
CCM="${CCM_NAME:-kind-cloud-provider}"
TIMEOUT="${TIMEOUT:-60}"

die() { echo "error: $*" >&2; exit 1; }

command -v kubectl >/dev/null || die "kubectl not found"
command -v docker  >/dev/null || die "docker not found"

docker inspect "$CCM" >/dev/null 2>&1 || die "no container named $CCM; is this Docker Desktop's kind cluster?"

# Node IPs the Envoys should point at (IPv4 InternalIPs of every node).
NODE_IPS="$(kubectl --context "$CTX" get nodes \
  -o jsonpath='{range .items[*]}{range .status.addresses[?(@.type=="InternalIP")]}{.address}{"\n"}{end}{end}' \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u)"
[ -n "$NODE_IPS" ] || die "could not read node IPs (context $CTX)"

# Prints "<container> <target ip>" for every target that isn't a node IP.
stale_targets() {
  local c
  # Docker Desktop hides its kind containers from `docker ps`; the kind
  # network still lists them.
  for c in $(docker network inspect kind \
      --format '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' | grep '^kindccm-'); do
    docker exec "$c" cat /home/envoy/cds.yaml 2>/dev/null \
      | awk '/socket_address:/ {s=1; next} s && /address:/ {print $2; s=0}' \
      | sort -u \
      | while read -r ip; do
          grep -qxF "$ip" <<<"$NODE_IPS" || echo "$c $ip"
        done
  done
}

echo "node IP: $(tr '\n' ' ' <<<"$NODE_IPS")"
STALE="$(stale_targets)"
if [ -z "$STALE" ]; then
  echo "load balancers already point at the node; nothing to do"
  exit 0
fi

echo "stale load balancer targets:"
sed 's/^/  /' <<<"$STALE"
echo "restarting $CCM"
docker restart "$CCM" >/dev/null

deadline=$(( $(date +%s) + TIMEOUT ))
while [ -n "$(stale_targets)" ]; do
  [ "$(date +%s)" -lt "$deadline" ] || die "targets still stale after ${TIMEOUT}s; check: docker logs $CCM"
  sleep 2
done
echo "load balancers now point at the node"

code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 https://localhost:8443/ || true)"
echo "localhost:8443 -> HTTP ${code:-none}"
