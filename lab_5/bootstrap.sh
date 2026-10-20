#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CLUSTER="${CLUSTER:-lab5}"
NODE_IMAGE="kindest/node:v1.35.1"
NODE_CPUS="${NODE_CPUS:-3}"
CP_MEMORY="${CP_MEMORY:-2688}"
CP_RESERVED_MEMORY="${CP_RESERVED_MEMORY:-1664}"
WORKER_MEMORY="${WORKER_MEMORY:-2432}"
WORKER_RESERVED_MEMORY="${WORKER_RESERVED_MEMORY:-384}"
VM_HEADROOM_MEMORY="${VM_HEADROOM_MEMORY:-768}"
REGISTRY="registry.shop.local/shop"
KYVERNO_CHART_VERSION="3.9.1"
CNPG_CHART_VERSION="0.29.1"
KPS_CHART_VERSION="91.5.2"
METRICS_SERVER_CHART_VERSION="3.14.0"
CILIUM_CHART_VERSION="1.20.3"
LAB2="${ROOT}/../lab_2"
VALUES="${ROOT}/chart/shop/values.yaml"

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

kubelet_args() {
  cat <<EOF
          kubeletExtraArgs:
            system-reserved: "cpu=${reserved_cpus},memory=${2}Mi"
            eviction-hard: "memory.available<$(( host_memory - $1 ))Mi,nodefs.available<0%,nodefs.inodesFree<0%,imagefs.available<0%"
            enforce-node-allocatable: "none"
EOF
}

kind_config() {
  cat <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  kubeProxyMode: iptables
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
nodes:
  - role: control-plane
    image: ${NODE_IMAGE}
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          taints: []
$(kubelet_args "${CP_MEMORY}" "${CP_RESERVED_MEMORY}")
  - role: worker
    image: ${NODE_IMAGE}
    kubeadmConfigPatches:
      - |
        kind: JoinConfiguration
        nodeRegistration:
$(kubelet_args "${WORKER_MEMORY}" "${WORKER_RESERVED_MEMORY}")
EOF
}

values_tag() {
  awk -v svc="$1" '
    $0 ~ "^"svc":" {in_svc=1; next}
    /^[a-z]/       {in_svc=0}
    in_svc && /^[[:space:]]+tag:/ {gsub(/["[:space:]]/, "", $2); print $2; exit}
  ' "${VALUES}"
}

step "Кластер kind ${CLUSTER}: control-plane ${CP_MEMORY} МБ, worker ${WORKER_MEMORY} МБ, по ${NODE_CPUS} CPU"
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  echo "уже есть"
else
  host_memory=$(( $(docker info --format '{{.MemTotal}}') / 1048576 ))
  reserved_cpus=$(( $(docker info --format '{{.NCPU}}') - NODE_CPUS ))
  if [ $(( CP_MEMORY + WORKER_MEMORY + VM_HEADROOM_MEMORY )) -gt "${host_memory}" ]; then
    echo "бюджеты нод (${CP_MEMORY} + ${WORKER_MEMORY} МБ) + запас VM (${VM_HEADROOM_MEMORY} МБ) не помещаются в Docker VM (${host_memory} МБ)"; exit 1
  fi
  kind_config > "${ROOT}/platform/kind.generated.yaml"
  kind create cluster --name "${CLUSTER}" --config "${ROOT}/platform/kind.generated.yaml"
fi
kubectl config use-context "kind-${CLUSTER}" >/dev/null

step "CNI: Cilium (chart ${CILIUM_CHART_VERSION}) + Hubble"
kubectl get nodes
helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo update cilium >/dev/null
helm upgrade --install cilium cilium/cilium \
  --version "${CILIUM_CHART_VERSION}" \
  -n kube-system \
  -f "${ROOT}/platform/cilium-values.yaml"
kubectl rollout status -n kube-system ds/cilium --timeout=600s
kubectl rollout status -n kube-system deploy/cilium-operator --timeout=300s
kubectl wait --for=condition=Ready node --all --timeout=300s
kubectl rollout status -n kube-system deploy/coredns --timeout=300s
kubectl rollout status -n kube-system deploy/hubble-relay --timeout=300s
kubectl exec -n kube-system ds/cilium -c cilium-agent -- cilium-dbg status --brief
kubectl get nodes -o wide
kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.memory,ALLOCATABLE:.status.allocatable.memory,CPU:.status.allocatable.cpu,TAINTS:.spec.taints[*].key'

step "metrics-server (chart ${METRICS_SERVER_CHART_VERSION})"
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
helm repo update metrics-server >/dev/null
helm upgrade --install metrics-server metrics-server/metrics-server \
  --version "${METRICS_SERVER_CHART_VERSION}" \
  -n kube-system \
  --set 'args={--kubelet-insecure-tls}'

if [ "${WITH_KYVERNO:-0}" = "1" ]; then
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
  kubectl rollout status -n kyverno deploy/kyverno-admission-controller --timeout=600s

  step "Политики"
  for i in $(seq 1 12); do
    if kubectl apply -f "${ROOT}/policies/" 2>/dev/null; then break; fi
    [ "$i" = 12 ] && { kubectl apply -f "${ROOT}/policies/"; exit 1; }
    echo "Kyverno ещё не готов принимать политики, ждём..."; sleep 5
  done
  kubectl wait --for=condition=Ready clusterpolicy --all --timeout=120s
fi

step "Оператор CloudNativePG (chart ${CNPG_CHART_VERSION})"
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo update cnpg >/dev/null
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --version "${CNPG_CHART_VERSION}" \
  -n cnpg-system --create-namespace \
  -f "${ROOT}/platform/cnpg-values.yaml"
kubectl rollout status -n cnpg-system deploy/cnpg-cloudnative-pg --timeout=600s

if [ "${SKIP_MONITORING:-0}" != "1" ]; then
  step "Мониторинг из Лабы 2 (kube-prometheus-stack ${KPS_CHART_VERSION})"
  if [ "${WITH_KYVERNO:-0}" = "1" ]; then
    kubectl apply -f "${ROOT}/policies/exceptions/"
    sleep 5
  fi
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
      kind load docker-image --name "${CLUSTER}" "${REGISTRY}/${svc}:${v}"
    done
  done
  docker exec "${CLUSTER}-worker" crictl images | grep "${REGISTRY}" | sort || true
fi

if [ "${SKIP_SHOP:-0}" != "1" ]; then
  step "Чарт shop"
  [ "${WITH_KYVERNO:-0}" = "1" ] && kubectl rollout status -n kyverno deploy/kyverno-admission-controller --timeout=600s
  kubectl rollout status -n cnpg-system deploy/cnpg-cloudnative-pg --timeout=600s
  shop_args=()
  [ "${SKIP_MONITORING:-0}" = "1" ] && shop_args+=(--set monitoring.enabled=false)
  helm upgrade --install shop "${ROOT}/chart/shop" -n shop --create-namespace --reset-values ${shop_args[@]+"${shop_args[@]}"}
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
  "${ROOT}/scripts/py-in-cluster.sh" "
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
if [ "${WITH_KYVERNO:-0}" = "1" ]; then
  kubectl get pods -n kyverno
  kubectl get clusterpolicy
  kubectl get policyexception -n kyverno
fi
kubectl get pods -n cnpg-system
[ "${SKIP_MONITORING:-0}" != "1" ] && kubectl get pods -n monitoring
if [ "${SKIP_SHOP:-0}" != "1" ]; then
  kubectl get cluster -n shop
  kubectl get pods -n shop -o wide
fi
kubectl describe nodes | grep -E "^Name:|^  (cpu|memory) "
kubectl top nodes
