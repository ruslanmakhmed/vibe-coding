# Shortlink DevOps project

Сервис сокращает HTTP(S)-ссылки, хранит их в PostgreSQL и считает переходы. Репозиторий включает контейнерный локальный стек, Kubernetes-манифесты, роль Ansible, CI-этапы и конфигурацию мониторинга. Приложение намеренно маленькое: на защите важны воспроизводимость и объяснение инфраструктуры.

## Схема

```text
curl/browser -> Ingress (Traefik) -> shortlink Service -> 2 app pods -> postgres Service -> PostgreSQL PVC
                                                   Prometheus -> /metrics
                                                   Grafana -> Prometheus
```

## Локальный запуск (Docker Compose)

Нужны Docker Engine с Compose v2, Bash, curl и openssl. Из корня репозитория выполните:

```bash
./scripts/bootstrap.sh
curl -sS -X POST http://localhost:8080/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.org"}'
curl -i http://localhost:8080/r/CODE_FROM_RESPONSE
docker compose --env-file compose/.env -f compose/docker-compose.yml down
./scripts/bootstrap.sh
```

Ссылка должна сохраниться в именованном томе `postgres_data`. `down -v` удаляет этот том вместе с данными. Файл `compose/.env` создаётся локально, пароль генерируется при первом запуске и не должен попадать в Git. В Compose также запускается реестр на `localhost:5001`; `docker push localhost:5001/shortlink:TAG` использует его без Docker Hub.

## Развёртывание в k3d

Нужны Docker, k3d, kubectl, curl, Python 3. Команды ниже создают локальный кластер с Traefik и пробросом HTTP-порта:

```bash
k3d cluster create shortlink --servers 1 --agents 1 -p '8081:80@loadbalancer'
kubectl get ingressclass
```

Скопируйте локальный образ в кластер; для внешнего реестра укажите соответствующий адрес в `IMAGE_REPOSITORY` и настройте доступ к нему для узлов k3d.

```bash
docker build -t shortlink:dev app
k3d image import shortlink:dev -c shortlink
export DB_PASSWORD="$(openssl rand -hex 24)"
export GRAFANA_PASSWORD="$(openssl rand -hex 24)"
kubectl apply -f k8s/namespace.yaml
kubectl create secret generic shortlink-secret -n shortlink --from-literal=DB_PASSWORD="$DB_PASSWORD" --from-literal=GRAFANA_PASSWORD="$GRAFANA_PASSWORD"
kubectl apply -f k8s/app-config.yaml -f k8s/postgres.yaml -f k8s/app.yaml
kubectl apply -f monitoring/prometheus.yaml -f monitoring/grafana.yaml
kubectl rollout status statefulset/postgres -n shortlink
kubectl rollout status deployment/shortlink -n shortlink
```

Откройте `http://shortlink.localhost:8081` (при необходимости добавьте `127.0.0.1 shortlink.localhost` в hosts). Для Grafana используйте `kubectl port-forward -n shortlink svc/grafana 3000:3000`; имя пользователя `admin`, пароль равен локальной переменной `GRAFANA_PASSWORD`. Секреты выше существуют только в текущей оболочке и объекте Kubernetes Secret; они не коммитятся. На удалённом кластере задайте их защищёнными CI-переменными.

## CI

GitLab pipeline расположен в корневом `.gitlab-ci.yml`. Pipeline содержит `lint`, `build`, `push`, `deploy`. `push` и ручной `deploy` выполняются только для `main` или Git-тега. Для deploy runner нужен доступ к кластеру через `KUBECONFIG`, а также protected variables `DB_PASSWORD` и `GRAFANA_PASSWORD`. Образу кластера нужен доступ к registry из `IMAGE_REPOSITORY`. Локально те же стадии запускаются командами:

```bash
./ci/run-stage.sh lint
./ci/run-stage.sh build
./ci/run-stage.sh push
./ci/run-stage.sh deploy
```

`IMAGE_TAG` берётся из Git-тега или короткого SHA; `latest` не используется. Требования к инструментам для `lint`: shellcheck, yamllint, ansible-lint.

## Ansible

Установите коллекции `ansible.posix` и `community.general`, скопируйте `ansible/inventory/hosts.ini.example` в `ansible/inventory/hosts.ini`, замените адреса и SSH-ключ, затем выполните:

```bash
ansible-galaxy collection install ansible.posix community.general
export ANSIBLE_CONFIG=ansible/ansible.cfg
ansible-playbook -i ansible/inventory/hosts.ini ansible/site.yml --vault-password-file ansible/vault-password.txt --check --diff
ansible-playbook -i ansible/inventory/hosts.ini ansible/site.yml --vault-password-file ansible/vault-password.txt
ansible-playbook -i ansible/inventory/hosts.ini ansible/site.yml --vault-password-file ansible/vault-password.txt
```

Примерные адреса из диапазона TEST-NET намеренно не являются реальными узлами. Локально созданный пароль Vault хранится в игнорируемом `ansible/vault-password.txt`; замените его своим и никогда не добавляйте в Git. Зашифрованный `ansible/group_vars/all/vault.yml` содержит только пример SSH-ключа: обновите значение через `ansible-vault edit`. Ограничьте SSH CIDR в inventory переменной `shortlink_allowed_ssh_cidr` до адреса вашей админской сети. Повторный прогон нужно проверить на реальном Debian/Ubuntu узле: модули UFW и nginx требуют привилегий.

## Переменные окружения

| Имя | Назначение | Значение по умолчанию | Обязательна |
|---|---|---:|---|
| `DB_HOST` | DNS-имя PostgreSQL | `db` в Compose | да |
| `DB_PORT` | порт PostgreSQL | `5432` | нет |
| `DB_NAME` | имя базы | `shortlink` | да |
| `DB_USER` | пользователь базы | `shortlink` | да |
| `DB_PASSWORD` | пароль базы | нет | да |
| `LOG_LEVEL` | уровень логирования | `INFO` | нет |
| `APP_PORT` | локальный порт публикации Compose | `8080` | нет |
| `IMAGE_TAG` | локальный тег образа | `dev` | нет |
| `IMAGE_REPOSITORY` | имя образа для CI | `localhost:5001/shortlink` | нет |
| `REGISTRY_PORT` | порт локального Docker Registry | `5001` | нет |
| `GRAFANA_PASSWORD` | пароль Grafana (Kubernetes Secret) | нет | для кластера |

## Частые проблемы

| Симптом | Проверка / действие |
|---|---|
| Compose не стартует | `docker compose ... ps` и `docker compose ... logs db app`; проверьте свободные порты 8080 и 5001. |
| `/readyz` отвечает 503 | Проверьте `DB_HOST=db` в Compose, пароль и `docker compose ... logs db`. |
| Pod в `Pending` | `kubectl describe pod -n shortlink POD`; проверьте PVC и доступную память/CPU. |
| Ingress недоступен | `kubectl get ingressclass,ingress -n shortlink`; проверьте Traefik и проброшенный порт k3d. |

## Ограничения учебного стенда

Метрики — счётчики процесса в памяти; с двумя репликами они не являются глобальными и сбрасываются при перезапуске. PostgreSQL один, без HA. Kubernetes Secret хранится в API-объекте и сам по себе не зашифрован в Git/etcd без настроенного encryption-at-rest. PV в k3d локален кластеру. Замените учебные пароли и ключи перед реальным использованием.
