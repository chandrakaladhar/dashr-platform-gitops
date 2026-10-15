#!/usr/bin/env bash
# Production (AWS): create credentials in Secrets Manager that don't exist yet.
# Never overwrites. The AWS counterpart of seed-secrets.sh: same names, same
# JSON shape, so the ExternalSecrets in platform/secrets/base work unchanged.
# Passwords are generated here and piped straight to the AWS CLI, so they never
# appear in shell history, the process list, or Git.
#
#   AWS_REGION=<aws_region from cluster-vars> ./scripts/seed-secrets-aws.sh
#
# To rotate one: aws secretsmanager put-secret-value --secret-id <component>/db \
#   --secret-string file:///dev/stdin   (pipe the new JSON)
# ESO picks it up within refreshInterval; CNPG updates the role automatically.
set -euo pipefail

: "${AWS_REGION:?set AWS_REGION to aws_region in clusters/production/cluster-vars.yaml}"
command -v aws >/dev/null     || { echo "error: aws CLI not found" >&2; exit 1; }
command -v openssl >/dev/null || { echo "error: openssl not found" >&2; exit 1; }
aws sts get-caller-identity >/dev/null || { echo "error: not logged in to AWS" >&2; exit 1; }

# seed_db <component> <postgres username>
seed_db() {
  local name="$1/db"
  if aws secretsmanager describe-secret --region "$AWS_REGION" --secret-id "$name" >/dev/null 2>&1; then
    echo "exists, skipping: $name"
  else
    # hex keeps passwords URL-safe for connection strings
    printf '{"username":"%s","password":"%s"}' "$2" "$(openssl rand -hex 24)" |
      aws secretsmanager create-secret --region "$AWS_REGION" --name "$name" \
        --secret-string file:///dev/stdin >/dev/null
    echo "created: $name"
  fi
}

seed_db dashr-nova dashr_nova
seed_db temporal   temporal
seed_db harbor     harbor

echo "Done. Flux will unblock platform-secrets on its next retry, or run:"
echo "  flux reconcile kustomization platform-secrets"
