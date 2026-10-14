#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROFILE="${MINIKUBE_PROFILE:-lab4}"
K8S_VERSION="v1.35.1"
NODES="${NODES:-2}"
NODE_MEMORY="${NODE_MEMORY:-2560}"
NODE_CPUS="${NODE_CPUS:-3}"
REGISTRY="registry.shop.local/shop"
KYVERNO_CHART_VERSION="3.9.1"
CNPG_CHART_VERSION="0.29.1"
KPS_CHART_VERSION="91.5.2"
LAB2="${ROOT}/../lab_2"
VALUES="${ROOT}/chart/shop/values.yaml"

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
mk() { minikube -p "${PROFILE}" "$@"; }

values_tag() {
  awk -v svc="$1" '
    $0 ~ "^"svc":" {in_svc=1; next}
    /^[a-z]/       {in_svc=0}
    in_svc && /^[[:space:]]+tag:/ {gsub(/["[:space:]]/, "", $2); print $2; exit}
  ' "${VALUES}"
}

step "Кластер minikube (профиль ${PROFILE}, ${NODES} ноды по ${NODE_MEMORY} МБ / ${NODE_CPUS} CPU)"
if mk status --format '{{.APIServer}}' 2>/dev/null | grep -q Running; then
  echo "уже запущен"
else
  mk start --nodes="${NODES}" --memory="${NODE_MEMORY}" --cpus="${NODE_CPUS}" --kubernetes-version="${K8S_VERSION}"
fi
kubectl config use-context "${PROFILE}" >/dev/null
mk addons enable volumesnapshots
mk addons enable csi-hostpath-driver
mk addons enable metrics-server
kubectl get nodes -o wide
kubectl get storageclass

step "Kyverno (chart ${KYVERNO_CHART_VERSION})"
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo update kyverno >/dev/null
helm upgrade --install kyverno kyverno/kyverno \
  --version "${KYVERNO_CHART_VERSION}" \
  -n kyverno --create-namespace \
  --set backgroundController.enabled=false \
  --set cleanupController.enabled=false \
  --set reportsController.enabled=false \
  --set features.policyExceptions.enabled=true \
  --set features.policyExceptions.namespace=kyverno
kubectl rollout status -n kyverno deploy/kyverno-admission-controller --timeout=180s

step "Политики"
for i in $(seq 1 12); do
  if kubectl apply -f "${ROOT}/policies/" 2>/dev/null; then break; fi
  [ "$i" = 12 ] && { kubectl apply -f "${ROOT}/policies/"; exit 1; }
  echo "Kyverno ещё не готов принимать политики, ждём..."; sleep 5
done
kubectl wait --for=condition=Ready clusterpolicy --all --timeout=120s

step "Оператор CloudNativePG (chart ${CNPG_CHART_VERSION})"
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo update cnpg >/dev/null
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --version "${CNPG_CHART_VERSION}" \
  -n cnpg-system --create-namespace \
  -f "${ROOT}/platform/cnpg-values.yaml"
kubectl rollout status -n cnpg-system deploy/cnpg-cloudnative-pg --timeout=180s

if [ "${SKIP_MONITORING:-0}" != "1" ]; then
  step "Мониторинг из Лабы 2 (kube-prometheus-stack ${KPS_CHART_VERSION})"
  kubectl apply -f "${ROOT}/policies/exceptions/"
  sleep 5
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update prometheus-community >/dev/null
  helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
    --version "${KPS_CHART_VERSION}" \
    -n monitoring --create-namespace \
    -f "${LAB2}/monitoring-default-values.yaml" \
    -f "${LAB2}/alertmanager-values.yaml" \
    -f "${ROOT}/platform/monitoring-values.yaml" \
    --wait --timeout 10m
  kubectl rollout status -n monitoring statefulset/prometheus-monitoring-kube-prometheus-prometheus --timeout=300s
  kubectl apply -f "${ROOT}/platform/alert-webhook.yaml"
  kubectl rollout status -n monitoring deploy/alert-webhook --timeout=180s
fi

if [ "${SKIP_IMAGES:-0}" != "1" ]; then
  for svc in api worker batch; do
    versions="$(printf '%s\n' "$(values_tag "${svc}")" ${APP_VERSION:-} | sort -u)"
    [ "${svc}" = api ] && versions="$(printf '%s\n' ${versions} 0.1.0 0.2.0 | sort -u)"
    step "Образы ${svc}: [$(echo ${versions})]"
    for v in ${versions}; do
      docker build -q -t "${REGISTRY}/${svc}:${v}" --build-arg APP_VERSION="${v}" "${ROOT}/services/${svc}"
      mk image load "${REGISTRY}/${svc}:${v}"
    done
  done
  mk image ls | grep "${REGISTRY}" | sort || true
fi

if [ "${SKIP_SHOP:-0}" != "1" ]; then
  step "Чарт shop"
  helm upgrade --install shop "${ROOT}/chart/shop" -n shop --create-namespace --reset-values
  echo "Ждём, пока оператор поднимет Postgres (при первой установке — пара минут)..."
  kubectl wait --for=condition=Ready cluster/shop-postgres -n shop --timeout=600s
  kubectl rollout status -n shop deploy/api --timeout=300s
  kubectl rollout status -n shop deploy/worker --timeout=300s
  kubectl rollout status -n shop deploy/batch --timeout=300s

  if ! kubectl exec -n shop deploy/api -- sh -c 'test -n "$DB_PASSWORD"' 2>/dev/null; then
    echo "Поды стартовали раньше Secret с паролем БД — rollout restart api/worker"
    kubectl rollout restart -n shop deploy/api deploy/worker
    kubectl rollout status -n shop deploy/api --timeout=300s
    kubectl rollout status -n shop deploy/worker --timeout=300s
  fi

  step "Smoke-тест: заказ через api -> postgres -> worker"
  kubectl exec -n shop deploy/worker -- python -c "
import urllib.request as u, json, time
req = u.Request('http://api:8080/order', data=json.dumps({'item': 'bootstrap-check'}).encode(),
                headers={'Content-Type': 'application/json'})
order = json.loads(u.urlopen(req, timeout=5).read())
print('создан заказ', order['id'])
for _ in range(15):
    orders = json.loads(u.urlopen('http://api:8080/orders', timeout=5).read())
    status = next(o['status'] for o in orders if o['id'] == order['id'])
    if status == 'processed':
        print('worker обработал заказ', order['id']); break
    time.sleep(1)
else:
    raise SystemExit('заказ не обработан за 15 с')
"
fi

step "Готово"
kubectl get pods -n kyverno
kubectl get pods -n cnpg-system
kubectl get clusterpolicy
kubectl get policyexception -n kyverno
[ "${SKIP_MONITORING:-0}" != "1" ] && kubectl get pods -n monitoring
if [ "${SKIP_SHOP:-0}" != "1" ]; then
  kubectl get cluster -n shop
  kubectl get pods -n shop -o wide
fi
kubectl describe nodes | grep -A8 "Allocated resources"
