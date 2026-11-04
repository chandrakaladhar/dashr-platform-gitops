#!/usr/bin/env bash
# Dump databases from the local cluster's Postgres to your machine, so they
# survive wiping the cluster. Restore them with ./scripts/restore-db.sh.
#
#   ./scripts/backup-db.sh
#   DATABASES="keycloak dashr_nova temporal" ./scripts/backup-db.sh
#
# Settings (environment variables):
#   KUBE_CONTEXT  kubectl context (default: docker-desktop)
#   DATABASES     databases to dump (default: keycloak dashr_nova). Keycloak's
#                 holds realms, clients, identity providers, users and keys.
#   BACKUP_ROOT   where backups go (default: ~/.config/dashr/backups/<context>)
#
# Each run writes <BACKUP_ROOT>/<timestamp>/<database>.dump (pg_dump custom
# format) and points <BACKUP_ROOT>/latest at it. The dumps contain secrets
# (Keycloak client and identity-provider secrets, signing keys), so the
# directories are mode 700 and the files 600. Keep them off shared drives.
#
# Passwords are not in the dumps: they belong to the cluster (OpenBao), and
# CNPG sets them on the roles. Database roles are, as role names only.
set -euo pipefail

CTX="${KUBE_CONTEXT:-docker-desktop}"
DATABASES="${DATABASES:-keycloak dashr_nova}"
STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/dashr"
BACKUP_ROOT="${BACKUP_ROOT:-$STATE_DIR/backups/$CTX}"
PG_NAMESPACE="database"
PG_CLUSTER="platform-pg"

die() { echo "error: $*" >&2; exit 1; }
k()   { kubectl --context "$CTX" "$@"; }

command -v kubectl >/dev/null || die "kubectl not found"

PRIMARY="$(k -n "$PG_NAMESPACE" get pod \
  -l "cnpg.io/cluster=$PG_CLUSTER,cnpg.io/instanceRole=primary" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" || true
[ -n "$PRIMARY" ] || die "no running primary for $PG_CLUSTER in namespace $PG_NAMESPACE (context $CTX)"
psql_in_pod() { k -n "$PG_NAMESPACE" exec "$PRIMARY" -c postgres -- psql -XAtq "$@"; }

umask 077
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="$BACKUP_ROOT/$STAMP"
mkdir -p "$DEST"

echo "Backing up from $PRIMARY ($CTX) to $DEST"
for db in $DATABASES; do
  exists="$(psql_in_pod -c "select 1 from pg_database where datname = '$db'")"
  [ "$exists" = 1 ] || die "database $db not found"
  # Written to a temporary name first, so a failed dump never looks complete.
  k -n "$PG_NAMESPACE" exec "$PRIMARY" -c postgres -- pg_dump -Fc -d "$db" > "$DEST/$db.dump.part"
  [ "$(head -c 5 "$DEST/$db.dump.part")" = PGDMP ] || die "dump of $db is not a valid pg_dump archive"
  mv "$DEST/$db.dump.part" "$DEST/$db.dump"
  printf '  %-12s %s\n' "$db" "$(du -h "$DEST/$db.dump" | cut -f1)"
done

ln -sfn "$STAMP" "$BACKUP_ROOT/latest"
echo "Done. Restore with: ./scripts/restore-db.sh   (uses $BACKUP_ROOT/latest)"
