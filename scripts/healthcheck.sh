#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
usage() { echo "Usage: $0 [--help]"; }
fail() { echo "healthcheck: $*" >&2; exit 1; }
[[ ${1:-} == --help ]] && { usage; exit 0; }
[[ $# -eq 0 ]] || { usage >&2; exit 2; }
for cmd in curl df; do command -v "$cmd" >/dev/null || fail "required command not found: $cmd"; done
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="$root_dir/compose/.env"
ready_url="${SHORTLINK_READY_URL:-}"
if [[ -z $ready_url ]]; then
  [[ -r $env_file ]] || fail "set SHORTLINK_READY_URL or run scripts/bootstrap.sh first"
  app_port="$(sed -n 's/^APP_PORT=//p' "$env_file" | tail -n1)"
  [[ $app_port =~ ^[0-9]+$ ]] || fail "APP_PORT must be numeric"
  ready_url="http://127.0.0.1:$app_port/readyz"
fi
curl --fail --silent --show-error "$ready_url" >/dev/null || fail "application is not ready: $ready_url"
df -P "$root_dir" | awk 'NR==2 { if ($5+0 >= 90) exit 1 }' || fail "filesystem usage is at least 90%"
if [[ -f $root_dir/compose/docker-compose.yml ]]; then
  command -v docker >/dev/null || fail "docker is required for the local Compose container check"
  running_services="$(docker compose --env-file "$env_file" -f "$root_dir/compose/docker-compose.yml" ps --status running --services)" || fail "could not inspect Compose containers"
  printf '%s\n' "$running_services" | grep -qx app || fail "app container is not running"
  printf '%s\n' "$running_services" | grep -qx db || fail "db container is not running"
else
  echo "healthcheck: Compose file not present; container check skipped on this edge node" >&2
fi
echo "healthcheck: all checks passed"
