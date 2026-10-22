#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER="${CLUSTER:-lab4}"
K6_IMAGE="grafana/k6:1.3.0"
MIRROR="registry.shop.local/tools/k6:1.3.0"
export PROFILE="${PROFILE:-day}"
export PEAK_RPS="${PEAK_RPS:-20}"
export STEP_MINUTES="${STEP_MINUTES:-6}"

if ! docker exec "${CLUSTER}-worker" crictl inspecti "${MIRROR}" >/dev/null 2>&1; then
  docker pull -q "${K6_IMAGE}"
  docker tag "${K6_IMAGE}" "${MIRROR}"
  kind load docker-image --name "${CLUSTER}" "${MIRROR}"
fi

kubectl delete job order-load -n shop --ignore-not-found --wait
kubectl create configmap order-load -n shop --from-file="${ROOT}/load/order-load.js" \
  --dry-run=client -o yaml | kubectl label --local -f - team=shop app.kubernetes.io/name=order-load -o yaml \
  | kubectl apply -f -
sed -e "s/\${PROFILE}/${PROFILE}/" -e "s/\${PEAK_RPS}/${PEAK_RPS}/" -e "s/\${STEP_MINUTES}/${STEP_MINUTES}/" \
  "${ROOT}/load/k6-job.yaml" | kubectl apply -f -

echo "PROFILE=${PROFILE} PEAK_RPS=${PEAK_RPS} STEP_MINUTES=${STEP_MINUTES}, старт $(date +%T)"
until kubectl get pod -n shop -l job-name=order-load -o name 2>/dev/null | grep -q pod/; do sleep 1; done
kubectl wait -n shop --for=condition=Ready pod -l job-name=order-load --timeout=120s
exec kubectl logs -n shop -f job/order-load
