# Harbor (not enabled yet)

The shared Postgres already has a `harbor` role and a `registry` database, and
`scripts/seed-secrets.sh` already creates `kv/harbor/db` in OpenBao.

To enable Harbor:

1. Add a `harbor` namespace to `platform/namespaces/namespaces.yaml` with the
   label `platform.dashr/postgres-client: "true"`.
2. In `platform/secrets/`, add a ServiceAccount and SecretStore for the
   `harbor` namespace (copy the dashr-nova pair, role `harbor`), plus an
   ExternalSecret `harbor-db` with key `password` from `harbor/db`.
3. In `scripts/configure-openbao.sh`, add a `harbor` policy reading
   `kv/data/harbor/*` and a role bound to the `harbor` namespace. Re-run it.
4. Rename `helmrelease.yaml.example` to `helmrelease.yaml`, add a
   `kustomization.yaml`, and add a `platform-harbor` Flux Kustomization to
   `clusters/<env>/platform.yaml` depending on `platform-postgres`.
5. Switch `image_registry` in `clusters/<env>/cluster-vars.yaml` to the Harbor
   project path, and the dashr-nova overlays to the same repository.
