#!/usr/bin/env bash
# Restore databases dumped by ./scripts/backup-db.sh into the local cluster's
# Postgres, for example after wiping and recreating the cluster with
# ./scripts/local-up.sh. REPLACES the current contents of each database.
#
#   ./scripts/restore-db.sh                         # latest backup, asks first
#   ./scripts/restore-db.sh ~/.config/dashr/backups/docker-desktop/20261104-120000
#   ASSUME_YES=1 ./scripts/restore-db.sh            # no question
#
# Settings (environment variables):
#   KUBE_CONTEXT  kubectl context (default: docker-desktop)
#   DATABASES     which dumps to restore (default: every <database>.dump in the backup)
#   BACKUP_ROOT   where backups are (default: ~/.config/dashr/backups/<context>)
#   ASSUME_YES=1  don't ask for confirmation
#
# Keycloak is stopped while its database is restored (Flux is suspended so it
# doesn't start it again) and started afterwards. Other databases are restored
# in one transaction after closing their connections: a failed restore leaves
# the database as it was. Objects are owned by the database's current owner.
#
# After restoring keycloak, sign in to the admin console with the admin
# password from the backup's cluster: the restored admin user replaces the
# bootstrap admin in OpenBao.
set -euo pipefail

CTX="${KUBE_CONTEXT:-docker-desktop}"
STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/dashr"
BACKUP_ROOT="${BACKUP_ROOT:-$STATE_DIR/backups/$CTX}"
BACKUP="${1:-$BACKUP_ROOT/latest}"
PG_NAMESPACE="database"
PG_CLUSTER="platform-pg"

die() { echo "error: $*" >&2; exit 1; }
k()   { kubectl --context "$CTX" "$@"; }

command -v kubectl >/dev/null || die "kubectl not found"
command -v flux >/dev/null    || die "flux not found"
[ -d "$BACKUP" ] || die "no backup at $BACKUP (run ./scripts/backup-db.sh first)"
BACKUP="$(cd "$BACKUP" && pwd -P)"

if [ -z "${DATABASES:-}" ]; then
  DATABASES="$(find "$BACKUP" -maxdepth 1 -name '*.dump' -exec basename {} .dump \; | sort | tr '\n' ' ')"
fi
[ -n "${DATABASES// /}" ] || die "no .dump files in $BACKUP"
for db in $DATABASES; do
  [ -f "$BACKUP/$db.dump" ] || die "missing $BACKUP/$db.dump"
  [ "$(head -c 5 "$BACKUP/$db.dump")" = PGDMP ] || die "$BACKUP/$db.dump is not a pg_dump archive"
done

PRIMARY="$(k -n "$PG_NAMESPACE" get pod \
  -l "cnpg.io/cluster=$PG_CLUSTER,cnpg.io/instanceRole=primary" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" || true
[ -n "$PRIMARY" ] || die "no running primary for $PG_CLUSTER in namespace $PG_NAMESPACE (context $CTX)"
psql_in_pod() { k -n "$PG_NAMESPACE" exec "$PRIMARY" -c postgres -- psql -XAtq -v ON_ERROR_STOP=1 "$@"; }

echo "Restore into $PRIMARY ($CTX) from $BACKUP:"
for db in $DATABASES; do echo "  $db  (current contents will be replaced)"; done
if [ "${ASSUME_YES:-}" != 1 ]; then
  read -r -p "Type 'restore' to continue: " answer
  [ "$answer" = restore ] || die "cancelled"
fi

KEYCLOAK_STOPPED=""
start_keycloak() {
  [ -n "$KEYCLOAK_STOPPED" ] || return 0
  echo "Starting Keycloak again (resuming Flux)"
  flux --context "$CTX" resume kustomization platform-keycloak >/dev/null
  KEYCLOAK_STOPPED=""
}
# Keycloak must come back even if a restore fails part-way.
trap start_keycloak EXIT

stop_keycloak() {
  echo "Stopping Keycloak (suspending Flux so it stays stopped)"
  flux --context "$CTX" suspend kustomization platform-keycloak >/dev/null
  KEYCLOAK_STOPPED=1
  k -n keycloak scale deploy/keycloak --replicas=0 >/dev/null
  k -n keycloak wait pod -l app=keycloak --for=delete --timeout=180s >/dev/null 2>&1 || true
}

for db in $DATABASES; do
  owner="$(psql_in_pod -c "select pg_get_userbyid(datdba) from pg_database where datname = '$db'")"
  [ -n "$owner" ] || die "database $db doesn't exist in this cluster (is the platform fully up?)"
  [ "$db" = keycloak ] && stop_keycloak
  # Close other sessions, so --clean isn't blocked by locks. Apps reconnect.
  psql_in_pod -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$db' and pid <> pg_backend_pid()" >/dev/null
  echo "Restoring $db (owner $owner)"
  k -n "$PG_NAMESPACE" exec -i "$PRIMARY" -c postgres -- \
    pg_restore --clean --if-exists --no-owner --role="$owner" --single-transaction --exit-on-error -d "$db" \
    < "$BACKUP/$db.dump"
done

start_keycloak
trap - EXIT
echo "Done."
case " $DATABASES " in *" keycloak "*)
  echo "Keycloak restarts in about a minute. Admin console: http://localhost:8080/admin,"
  echo "with the admin password of the cluster the backup came from." ;;
esac
