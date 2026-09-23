#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
usage() { echo "Usage: $0 [--help]"; }
fail() { echo "bootstrap: $*" >&2; exit 1; }
[[ ${1:-} == --help ]] && { usage; exit 0; }
[[ $# -eq 0 ]] || { usage >&2; exit 2; }
for cmd in docker curl openssl; do command -v "$cmd" >/dev/null || fail "required command not found: $cmd"; done
docker compose version >/dev/null 2>&1 || fail "Docker Compose plugin is required"
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="$root_dir/compose/.env"
[[ -f $env_file ]] || cp "$root_dir/compose/.env.example" "$env_file"
if ! grep -Eq '^DB_PASSWORD=.+$' "$env_file"; then
  password="$(openssl rand -hex 24)"
  sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=$password/" "$env_file"
  echo "Generated a local database password in compose/.env; keep it untracked."
fi
docker compose --env-file "$env_file" -f "$root_dir/compose/docker-compose.yml" up -d --build
app_port="$(sed -n 's/^APP_PORT=//p' "$env_file" | tail -n1)"
[[ $app_port =~ ^[0-9]+$ ]] || fail "APP_PORT must be numeric"
for attempt in {1..30}; do
  if curl --fail --silent "http://127.0.0.1:$app_port/readyz" >/dev/null; then
    image_tag="$(sed -n 's/^IMAGE_TAG=//p' "$env_file" | tail -n1)"
    registry_port="$(sed -n 's/^REGISTRY_PORT=//p' "$env_file" | tail -n1)"
    [[ $image_tag =~ ^[a-zA-Z0-9_.-]+$ ]] || fail "IMAGE_TAG has unsupported characters"
    [[ $registry_port =~ ^[0-9]+$ ]] || fail "REGISTRY_PORT must be numeric"
    registry_ready=false
    for registry_attempt in {1..15}; do
      if curl --fail --silent "http://127.0.0.1:$registry_port/v2/" >/dev/null; then
        registry_ready=true
        break
      fi
      sleep 2
    done
    [[ $registry_ready == true ]] || fail "local registry did not become ready within 30 seconds"
    docker tag "shortlink:$image_tag" "localhost:$registry_port/shortlink:$image_tag"
    docker push "localhost:$registry_port/shortlink:$image_tag"
    docker pull "localhost:$registry_port/shortlink:$image_tag"
    echo "Shortlink is ready; image was pushed to and pulled from localhost:$registry_port."
    exit 0
  fi
  sleep 2
done
docker compose --env-file "$env_file" -f "$root_dir/compose/docker-compose.yml" ps >&2
fail "application did not become ready within 60 seconds"
