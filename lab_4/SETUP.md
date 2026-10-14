# Лаба 3 — как поднять у себя

Платформа для `shop` на локальном minikube: ограждения Kyverno, Helm-чарт `api`/`worker`, Postgres через оператор CloudNativePG. Всё поднимается одним скриптом.

## Статус

| Часть лабы | Что | Готово |
|---|---|---|
| 0 | Сервисы `api` / `worker` + Dockerfile | ✅ |
| 1 | Kyverno, 5 политик, 5 манифестов-нарушителей | ✅ |
| 2 | Чарт `shop`, reconciliation, rolling update без потерь, откат сломанного релиза | ✅ |
| 3 | Postgres через CloudNativePG (`Cluster` в чарте) | ✅ |
| 4 | Падение control plane | ✅ (сценарий ниже) |
| 5 | Мониторинг: стек Лабы 2 рядом с Kyverno (`PolicyException`) | ✅ |
| 5 | Мониторинг: `ServiceMonitor` / `PrometheusRule`, 3 алерта, дашборд | ✅ |

## Требования

| Что | Минимум | Проверено на |
|---|---|---|
| Docker Desktop | **6 ГБ памяти**, 4 CPU (Settings → Resources) | Docker 24.0.7 |
| minikube | с поддержкой Kubernetes v1.35 | v1.38.1 |
| kubectl | любой свежий | v1.28 (работает, но minikube предупреждает о разнице версий) |
| Helm | 3.x или 4.x | v4.3.0 |

Первый запуск качает около 1.5 ГБ образов (Kyverno, оператор, Postgres) — нужен интернет.

## Быстрый старт

```bash
cd lab3-shop
./bootstrap.sh
```

С нуля это занимает **~8–10 минут** (дольше всего — скачивание образа Postgres). В конце скрипт сам делает smoke-тест: создаёт заказ через `api` и ждёт, пока `worker` его обработает. Если видите `worker обработал заказ N` и `Cluster in healthy state` — всё работает.

Что делает скрипт, по порядку (повторный запуск безопасен — доводит до нужного состояния, ничего не ломает):

1. **minikube** — 4 CPU, 4.5 ГБ, Kubernetes v1.35.1.
2. **Kyverno** — только admission-контроллер; `PolicyException` разрешены лишь в namespace `kyverno`.
3. **Политики** из `policies/`.
4. **Оператор CloudNativePG** — с values из `platform/cnpg-values.yaml`, чтобы он сам проходил политики.
   **Мониторинг из Лабы 2** — `kube-prometheus-stack` 91.5.2 с values из `../lab_2/` плюс оверлей `platform/monitoring-values.yaml` (метки и лимиты) и `PolicyException` из `policies/exceptions/` (только правило реестра, только релиз `monitoring`), плюс `platform/alert-webhook.yaml` — receiver из Лабы 2 для `severity=critical`.
5. **Образы** `api` (теги из `values.yaml` + `0.1.0`/`0.2.0` для демо) и `worker` — собираются локально и грузятся в minikube. Реестр `registry.shop.local` фиктивный: образ уже лежит на ноде, kubelet никуда не ходит.
6. **Чарт `shop`** в namespace `shop` + проверка, что поды получили пароль БД, + smoke-тест.

Переменные:

| Переменная | Что делает |
|---|---|
| `SKIP_IMAGES=1` | не пересобирать образы |
| `SKIP_SHOP=1` | только платформа (без чарта `shop`) |
| `SKIP_MONITORING=1` | не ставить стек мониторинга |
| `APP_VERSION=0.3.0` | дополнительно собрать образы этой версии |
| `MINIKUBE_PROFILE=lab3` | отдельный профиль minikube вместо `minikube` |

**Уже есть свой кластер minikube?** Память, CPU и версия Kubernetes применяются только при **создании** кластера — у существующего профиля останутся старые значения. Проще поднять отдельный: `MINIKUBE_PROFILE=lab3 ./bootstrap.sh`.

## Что где лежит

```
lab3-shop/
├── bootstrap.sh              — поднять всё
├── services/api, worker/     — подопытные сервисы (Python) + Dockerfile
├── policies/                 — 5 политик Kyverno (ClusterPolicy)
│   ├── violations/           — 5 манифестов, каждый нарушает ровно одно правило
│   └── exceptions/           — PolicyException для стека мониторинга (только реестр)
├── platform/cnpg-values.yaml — values оператора CNPG под наши политики
├── platform/monitoring-values.yaml — оверлей к values Лабы 2: метки и лимиты под политики
├── platform/alert-webhook.yaml — receiver Alertmanager из Лабы 2, доведённый до политик
├── chart/shop/               — Helm-чарт: api, worker, Service'ы, Cluster (Postgres),
│   │                           ServiceMonitor, PrometheusRule, ConfigMap с дашбордом
│   └── dashboards/           — JSON дашборда Grafana
├── tests/alerts.test.yaml    — unit-тесты алертов (promtool)
├── img/monitoring/           — скриншоты Части 5
└── scripts/
    ├── hit-api.sh            — нагрузка /health + /version (Часть 2)
    ├── order-load.sh         — поток заказов (Часть 5); RATE=заказов/с
    └── test-alerts.sh        — promtool test rules по правилам из чарта
```

## Сценарии лабы

Все команды — из папки `lab3-shop`.

### Часть 1 — политики отклоняют нарушителей

```bash
for f in policies/violations/*.yaml; do kubectl apply --dry-run=server -f $f; done
```

Каждый манифест отклоняется ровно одной политикой. Показать отказ на уровне чарта (рендер Helm'ом, проверка через apiserver):

```bash
helm template shop chart/shop -n shop --set api.resources.limits=null | kubectl apply --dry-run=server -n shop -f -
```

> `helm install --dry-run=server` для этого **не подходит**: он только рендерит шаблоны и не отправляет объекты через admission.

### Часть 2 — reconciliation, rolling update, откат

Нагрузка (держать открытой в отдельном терминале; `port-forward` не годится — он привязан к одному поду):

```bash
./scripts/hit-api.sh
```

- **Удаление пода:** `kubectl delete pod -n shop <api-pod>` — ReplicaSet создаёт замену.
- **Rolling update:** поменять `api.image.tag` в `chart/shop/values.yaml` (`0.2.0` ↔ `0.3.0`) → `helm upgrade shop chart/shop -n shop --reset-values`. Поды меняются по одному (`maxSurge: 1`, `maxUnavailable: 0`), в `hit-api.sh` — `fail=0` благодаря `preStop: sleep`.
- **Сломанный релиз:** `api.healthFail: true` → `helm upgrade`. Helm говорит `deployed`, но `kubectl rollout status deploy/api -n shop` зависает: новый под не проходит readiness, старые живы, сервис отвечает.
- **Откат:** `helm history shop -n shop` → `helm rollback shop <последняя исправная> -n shop`. **Потом вернуть `healthFail: false` в `values.yaml`**, иначе следующий `helm upgrade` закатит поломку снова.

### Часть 3 — оператор возвращает Postgres

```bash
kubectl delete pod shop-postgres-1 -n shop
kubectl get pods -n shop -l cnpg.io/cluster=shop-postgres -w
```

Под ~3 минуты висит в `Terminating` — это нормально: Postgres ждёт отключения клиентов (smart shutdown). Возвращается с **тем же именем** и на **том же томе** — заказы на месте. `spec`/`status`: `kubectl get cluster shop-postgres -n shop -o yaml`.

### Часть 4 — падение control plane

`kubectl exec`/`port-forward` при лежащем apiserver не работают, поэтому проверяем приложение с ноды по ClusterIP. Сначала запомнить IP:

```bash
kubectl get svc api -n shop -o jsonpath='{.spec.clusterIP}{"\n"}'
```

Терминал А (подставить IP):

```bash
minikube ssh -- 'while true; do printf "%s health=%s orders=" "$(date +%T)" "$(curl -s -m2 -o /dev/null -w %{http_code} http://IP:8080/health)"; curl -s -m2 -o /dev/null -w "%{http_code}\n" http://IP:8080/orders; sleep 2; done'
```

Терминал Б — остановить etcd (kubelet гасит static pod, когда пропадает его манифест):

```bash
minikube ssh -- sudo mv /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/etcd.yaml.stopped
```

Через ~30 с `kubectl get pods -n shop` и `helm upgrade shop chart/shop -n shop` падают по таймауту, а терминал А продолжает показывать `200`. Вернуть:

```bash
minikube ssh -- sudo mv /etc/kubernetes/etcd.yaml.stopped /etc/kubernetes/manifests/etcd.yaml
```

### Часть 5 — мониторинг

Доступ (каждое в своём терминале):

```bash
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-alertmanager 9093:9093
kubectl get secret -n monitoring monitoring-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

- Таргеты: http://localhost:9090/targets?search=shop — `serviceMonitor/shop/shop/0`, 7/7 `up`.
- Дашборд: http://localhost:3000/d/shop-overview.
- Unit-тесты алертов: `./scripts/test-alerts.sh` (нужен Docker).
- Нагрузка: `./scripts/order-load.sh` (держать открытым).
- **`ShopOrdersNotProcessed`** (warning): `kubectl scale deploy/worker -n shop --replicas=0` → `pending` через ~5 мин (окно `[5m]`), `firing` ещё через 2. Вернуть: `kubectl scale deploy/worker -n shop --replicas=2`.
- **`ShopApiHighErrorRatio`** (critical, уходит в `alert-webhook`): `kubectl annotate cluster shop-postgres -n shop cnpg.io/hibernation=on --overwrite` → `firing` через ~3 мин; смотреть `kubectl logs -n monitoring deploy/alert-webhook`. Вернуть: `...hibernation=off --overwrite`, затем снять аннотацию `cnpg.io/hibernation-`.

## Ежедневная работа

- Выключать — `minikube stop`, включать — `minikube start`. Всё (политики, релизы, база, образы) сохраняется.
- **Не делать** `minikube delete` — это удаляет кластер целиком; тогда заново `./bootstrap.sh`.
- **Не делать** `docker system prune` / `docker container prune` при **остановленном** minikube — удалит контейнер-ноду.

## Если что-то не так

| Симптом | Причина | Что делать |
|---|---|---|
| поды `api`/`worker` в `ImagePullBackOff` | тег в `values.yaml` не совпадает с загруженным образом | `minikube image ls \| grep shop`; собрать нужный: `APP_VERSION=<тег> ./bootstrap.sh` |
| `api` отвечает 503 `database unavailable` | поды стартовали раньше Secret с паролем БД — env читается только при старте | `kubectl rollout restart deploy/api deploy/worker -n shop` |
| `helm install`/`upgrade` падает с `admission webhook "validate.kyverno..." denied` | шаблон нарушает политику — так и задумано | прочитать, какое правило, поправить шаблон/values |
| `kubectl` отвечает `connection refused` на `localhost:8080` | minikube остановлен, контекст сброшен | `minikube start` |
| поды в `Pending`, `Insufficient memory` | мало памяти у Docker / кластера | Docker Desktop ≥ 6 ГБ; закрыть тяжёлые приложения |
| `Cluster` долго `Setting up primary` | первый раз качается образ Postgres (~4–5 мин) | подождать; `kubectl get events -n shop` |
| `helm upgrade` говорит `deployed`, но правка `values.yaml` не применилась | без `-f`/`--set` Helm переиспользует values прошлой ревизии (например, после `helm rollback`) | `helm upgrade ... --reset-values`; проверить `helm get values shop -n shop` → `null` |
| таргетов `shop` нет в Prometheus | у `ServiceMonitor` нет метки `release: monitoring` или стек не установлен | `kubectl get servicemonitor -n shop --show-labels`; `SKIP_MONITORING` не выставлен |
| `monitoring-grafana` в `OOMKilled` | лимит памяти мал для ~30 дашбордов стека | лимит в `platform/monitoring-values.yaml` (сейчас 768Mi) |

## Известные компромиссы

- Kyverno в **одной** реплике (ради памяти): при аварийном падении с `failurePolicy: Fail` блокируется создание подов, включая самовосстановление.
- `kyverno.io/v1 ClusterPolicy` в Kyverno 1.19 помечен deprecated (замена — `ValidatingPolicy` на CEL); работает, отсюда предупреждения в выводе.
- Postgres в **одном** инстансе: при удалении/перезапуске пода база недоступна несколько минут.
- Стек мониторинга берёт образы с quay.io/docker.io/registry.k8s.io по `PolicyException`, а не через зеркало в `registry.shop.local` — подробности в README, Часть 5.
- `ghcr.io/cloudnative-pg/*` разрешён политикой реестра на весь кластер — доверие всей организации на GHCR, а не конкретным образам.
