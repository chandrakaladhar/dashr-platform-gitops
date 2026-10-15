# Harbor (not enabled yet)

The shared Postgres already has a `harbor` role and a `registry` database, and
`scripts/seed-secrets.sh` / `seed-secrets-aws.sh` already create `harbor/db` in
OpenBao (local) and AWS Secrets Manager (production).

To enable Harbor:

1. Add a `harbor` namespace to `platform/namespaces/namespaces.yaml` with the
   label `platform.dashr/postgres-client: "true"`.
2. In `platform/secrets/base/`, add an ExternalSecret `harbor-db` with key
   `password` from `harbor/db`. In `platform/secrets/stores/openbao/` and
   `stores/aws/`, add a ServiceAccount and SecretStore `platform` for the
   `harbor` namespace (copy the dashr-nova pair, changing the namespace and
   the role).
3. Locally, add `harbor` to the component loop in `scripts/configure-openbao.sh`
   and re-run it. In AWS, create the IAM role `<eks_cluster_name>-eso-harbor`
   reading `harbor/*` (see "Production on AWS EKS" in the main README).
4. Rename `helmrelease.yaml.example` to `helmrelease.yaml`, add a
   `kustomization.yaml`, and add a `platform-harbor` Flux Kustomization to
   `clusters/<env>/platform.yaml` depending on `platform-postgres`.
5. Switch `image_registry` in `clusters/<env>/cluster-vars.yaml` to the Harbor
   project path, and the dashr-nova overlays to the same repository.
