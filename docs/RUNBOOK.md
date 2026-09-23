# Операционный runbook

Команды выполняются из корня репозитория. Для локальных операций установите Docker Compose v2; для кластера — kubectl с выбранным контекстом.

## Запуск и проверка локального стека

```bash
./scripts/bootstrap.sh
./scripts/healthcheck.sh
docker compose --env-file compose/.env -f compose/docker-compose.yml ps
docker compose --env-file compose/.env -f compose/docker-compose.yml logs --tail=100 app db
```

## Выкатка в Kubernetes

Подготовьте Secret (`DB_PASSWORD`, `GRAFANA_PASSWORD`) по шагам README, соберите и загрузите новый образ в registry, доступный кластеру. Затем:

```bash
export IMAGE_REPOSITORY=registry.example/your-group/shortlink
export IMAGE_TAG=v0.2.0
./ci/run-stage.sh deploy
kubectl rollout status deployment/shortlink -n shortlink
kubectl get pods,svc,ingress -n shortlink
```

Тег должен быть существующим неизменяемым тегом образа. Для проверки прогресса:

```bash
kubectl rollout history deployment/shortlink -n shortlink
kubectl describe deployment/shortlink -n shortlink
kubectl logs -n shortlink deployment/shortlink --all-pods=true --tail=100
```

## Откат

```bash
kubectl rollout undo deployment/shortlink -n shortlink
kubectl rollout status deployment/shortlink -n shortlink
kubectl rollout history deployment/shortlink -n shortlink
```

Kubernetes возвращает предыдущую Pod template revision. Убедитесь, что предыдущий image tag всё ещё доступен в registry, затем проверьте `/readyz` и создание/переход ссылки.

## Логи и диагностика

```bash
kubectl get pods -n shortlink -o wide
kubectl describe pod -n shortlink POD_NAME
kubectl logs -n shortlink POD_NAME --previous
kubectl logs -n shortlink deployment/shortlink --all-pods=true --tail=200
kubectl get events -n shortlink --sort-by=.lastTimestamp
kubectl get endpoints -n shortlink shortlink postgres
kubectl port-forward -n shortlink svc/prometheus 9090:9090
```

Prometheus targets: `http://localhost:9090/targets`. Grafana: `kubectl port-forward -n shortlink svc/grafana 3000:3000`, затем открыть `http://localhost:3000`.

## Резервная копия и восстановление (Compose)

```bash
./scripts/backup.sh --retention-days 14
mkdir -p /tmp/shortlink-restore
tar -xzf backups/shortlink-YYYYMMDDTHHMMSSZ.tar.gz -C /tmp/shortlink-restore
docker compose --env-file compose/.env -f compose/docker-compose.yml exec -T db pg_restore -c -U shortlink -d shortlink < /tmp/shortlink-restore/database.dump
```

Замените метку времени на имя созданного архива. `pg_restore -c` удаляет конфликтующие объекты в целевой базе; перед восстановлением сохраните текущую копию.

## Масштабирование

```bash
kubectl scale deployment/shortlink -n shortlink --replicas=3
kubectl get deployment/shortlink -n shortlink
```

Метрики счётчиков хранятся в памяти процесса и не суммируются приложением между репликами. Для production используйте библиотечный Prometheus client с корректной моделью метрик.
