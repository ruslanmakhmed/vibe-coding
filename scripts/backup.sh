#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
usage() { echo "Usage: $0 [--retention-days N] [--help]"; }
fail() { echo "backup: $*" >&2; exit 1; }
retention_days=14
while (($#)); do
  case "$1" in
    --help) usage; exit 0 ;;
    --retention-days) (($# >= 2)) || { usage >&2; exit 2; }; retention_days=$2; shift 2 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ $retention_days =~ ^[1-9][0-9]*$ ]] || fail "retention days must be a positive integer"
for cmd in docker tar find; do command -v "$cmd" >/dev/null || fail "required command not found: $cmd"; done
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="$root_dir/compose/.env"
[[ -r $env_file ]] || fail "missing compose/.env; run scripts/bootstrap.sh first"
backup_dir="$root_dir/backups"
mkdir -p "$backup_dir"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
tmp_dir="$(mktemp -d "$backup_dir/.backup.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
db_user="$(sed -n 's/^DB_USER=//p' "$env_file" | tail -n1)"
db_name="$(sed -n 's/^DB_NAME=//p' "$env_file" | tail -n1)"
[[ -n $db_user && -n $db_name ]] || fail "DB_USER and DB_NAME must be set in compose/.env"
docker compose --env-file "$env_file" -f "$root_dir/compose/docker-compose.yml" exec -T db \
  pg_dump -Fc -U "$db_user" "$db_name" > "$tmp_dir/database.dump"
tar -czf "$backup_dir/shortlink-$stamp.tar.gz" -C "$tmp_dir" database.dump
find "$backup_dir" -type f -name 'shortlink-*.tar.gz' -mtime "+$retention_days" -delete
echo "Created $backup_dir/shortlink-$stamp.tar.gz; retention=${retention_days}d"
