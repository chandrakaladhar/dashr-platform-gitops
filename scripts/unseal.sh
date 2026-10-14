#!/usr/bin/env bash
# Unseal every in-cluster OpenBao pod (local clusters). Needed after any pod
# or node restart, because OpenBao always starts sealed. Prompts for the key.
set -euo pipefail
NS="${NS:-openbao}"
for pod in $(kubectl get pods -n "$NS" -l app.kubernetes.io/name=openbao,component=server -o name); do
  if kubectl exec -n "$NS" "${pod#pod/}" -- bao status >/dev/null 2>&1; then
    echo "${pod#pod/}: already unsealed"
  else
    echo "${pod#pod/}: unsealing"
    kubectl exec -n "$NS" -ti "${pod#pod/}" -- bao operator unseal
  fi
done
