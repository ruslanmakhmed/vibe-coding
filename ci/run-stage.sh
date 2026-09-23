#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
usage() { echo "Usage: $0 lint|build|push|deploy"; }
fail() { echo "run-stage: $*" >&2; exit 1; }
[[ $# -eq 1 ]] || { usage >&2; exit 2; }
stage=$1
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"
image_repository="${IMAGE_REPOSITORY:-localhost:5001/shortlink}"
if [[ -n ${CI_COMMIT_TAG:-} ]]; then image_tag=$CI_COMMIT_TAG
elif [[ -n ${CI_COMMIT_SHORT_SHA:-} ]]; then image_tag=$CI_COMMIT_SHORT_SHA
else image_tag="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"; fi
image="$image_repository:$image_tag"

case "$stage" in
  lint)
    command -v shellcheck >/dev/null || fail "install shellcheck first"
    command -v yamllint >/dev/null || fail "install yamllint first"
    command -v ansible-lint >/dev/null || fail "install ansible-lint first"
    shellcheck scripts/*.sh ci/run-stage.sh
    yamllint -c .yamllint.yml .gitlab-ci.yml k8s monitoring ansible/site.yml ansible/roles compose
    ANSIBLE_CONFIG=ansible/ansible.cfg ansible-lint ansible/site.yml
    ;;
  build)
    command -v docker >/dev/null || fail "docker is required"
    docker build --pull -t "$image" app
    if [[ -n ${CI_JOB_ID:-} ]]; then docker save --output image.tar "$image"; fi
    ;;
  push)
    command -v docker >/dev/null || fail "docker is required"
    docker push "$image"
    ;;
  deploy)
    command -v kubectl >/dev/null || fail "kubectl is required"
    [[ -n ${DB_PASSWORD:-} ]] || fail "set DB_PASSWORD in CI variables or environment"
    [[ -n ${GRAFANA_PASSWORD:-} ]] || fail "set GRAFANA_PASSWORD in CI variables or environment"
    if [[ -n ${K3D_CLUSTER:-} ]]; then
      command -v k3d >/dev/null || fail "k3d is required when K3D_CLUSTER is set"
      k3d image import "$image" -c "$K3D_CLUSTER"
    fi
    kubectl apply -f k8s/namespace.yaml
    kubectl create secret generic shortlink-secret -n shortlink \
      --from-literal=DB_PASSWORD="$DB_PASSWORD" \
      --from-literal=GRAFANA_PASSWORD="$GRAFANA_PASSWORD" \
      --dry-run=client -o yaml | kubectl apply -f -
    if [[ -n ${REGISTRY_SERVER:-} && -n ${REGISTRY_USER:-} && -n ${REGISTRY_PASSWORD:-} ]]; then
      kubectl create secret docker-registry shortlink-registry-auth -n shortlink \
        --docker-server="$REGISTRY_SERVER" --docker-username="$REGISTRY_USER" \
        --docker-password="$REGISTRY_PASSWORD" --dry-run=client -o yaml | kubectl apply -f -
      kubectl patch serviceaccount default -n shortlink --type merge \
        -p '{"imagePullSecrets":[{"name":"shortlink-registry-auth"}]}'
    fi
    kubectl apply -f k8s/app-config.yaml -f k8s/postgres.yaml -f k8s/app.yaml
    kubectl apply -f monitoring/prometheus.yaml -f monitoring/grafana.yaml
    kubectl set image deployment/shortlink app="$image" -n shortlink
    kubectl rollout status deployment/shortlink -n shortlink --timeout=180s
    ;;
  *) usage >&2; fail "unknown stage: $stage" ;;
esac
echo "Completed stage=$stage image=$image"
