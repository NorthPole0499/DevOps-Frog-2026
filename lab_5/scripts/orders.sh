#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-shop}"
KIND_NETWORK="${KIND_NETWORK:-kind}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.11.1}"
INTERVAL="${INTERVAL:-0.5}"
TIMEOUT="${TIMEOUT:-3}"

port="$(kubectl get svc api -n "${NS}" -o jsonpath='{.spec.ports[0].nodePort}')"
nodes="$(kubectl get pods -n "${NS}" -l app.kubernetes.io/name=api --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.status.hostIP}{"\n"}{end}' | sort -u | tr '\n' ' ')"
[ -n "${nodes}" ] || { echo "нет Running-подов api"; exit 1; }

echo "POST /order через NodePort ${port} на [${nodes% }] из сети Docker ${KIND_NETWORK}, Ctrl-C — стоп"
exec docker run --rm -i --init --network "${KIND_NETWORK}" --entrypoint sh "${CURL_IMAGE}" -c '
port=$1 interval=$2 timeout=$3; shift 3
ok=0 fail=0
while :; do
  for node in "$@"; do
    code=$(curl -s -m "$timeout" -o /dev/null -w "%{http_code}" -X POST \
      -H "Content-Type: application/json" -d "{\"item\": \"orders.sh\"}" "http://$node:$port/order")
    if [ "$code" = 201 ]; then ok=$((ok + 1)); mark=""; else fail=$((fail + 1)); mark="FAIL "; fi
    [ "$code" = 000 ] && code=TIMEOUT
    echo "$(date +%H:%M:%S) ${mark}$node $code ok=$ok fail=$fail"
    sleep "$interval"
  done
done
' orders "${port}" "${INTERVAL}" "${TIMEOUT}" ${nodes}
