#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-shop}"
INTERVAL="${INTERVAL:-5}"
DURATION="${DURATION:-600}"
MODE="${MODE:-evict}"
TARGETS="${TARGETS:-api worker}"
LOG="${LOG:-$(dirname "$0")/../chaos.log}"

case "${MODE}" in evict|delete|force|crash) ;; *) echo "MODE: evict | delete | force | crash"; exit 1 ;; esac

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "${LOG}"; }

pick() {
  kubectl get pods -n "${NS}" -l "app.kubernetes.io/name in ($(echo ${TARGETS} | tr ' ' ','))" \
    -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.deletionTimestamp}|{.metadata.name}|{.status.podIP}|{.spec.nodeName}{"\n"}{end}' \
    | awk -F'|' -v seed="${RANDOM}" 'BEGIN {srand(seed)} $1 == "" {p[++n] = $2 " " $3 " " $4} END {if (n) print p[int(rand() * n) + 1]}'
}

kill_pod() {
  case "${MODE}" in
    evict)
      kubectl create --raw "/api/v1/namespaces/${NS}/pods/$1/eviction" -f - >/dev/null 2>"${err}" <<EOF
{"apiVersion": "policy/v1", "kind": "Eviction", "metadata": {"name": "$1", "namespace": "${NS}"}}
EOF
      ;;
    delete) kubectl delete pod -n "${NS}" "$1" --wait=false >/dev/null 2>"${err}" ;;
    force)  kubectl delete pod -n "${NS}" "$1" --grace-period=0 --force >/dev/null 2>"${err}" ;;
    crash)
      local cid
      cid=$(kubectl get pod -n "${NS}" "$1" -o jsonpath='{.status.containerStatuses[0].containerID}')
      docker exec "$2" sh -c "kill -9 \$(crictl inspect -o go-template --template '{{.info.pid}}' ${cid#containerd://})" 2>"${err}"
      ;;
  esac
}

err=$(mktemp); trap 'rm -f "${err}"' EXIT
log "start mode=${MODE} interval=${INTERVAL}s duration=${DURATION}s targets=[${TARGETS}]"
killed=0; refused=0
end=$(( $(date +%s) + DURATION ))
while [ "$(date +%s)" -lt "${end}" ]; do
  read -r pod ip node <<<"$(pick)" || true
  if [ -z "${pod:-}" ]; then
    log "skip: no running pods"
  elif kill_pod "${pod}" "${node}"; then
    killed=$((killed + 1))
    log "kill ${pod} ip=${ip} node=${node}"
  elif grep -q "disruption budget" "${err}"; then
    refused=$((refused + 1))
    log "refused ${pod}: PDB"
  else
    log "error ${pod}: $(tr '\n' ' ' <"${err}")"
  fi
  sleep "${INTERVAL}"
done
log "done killed=${killed} refused_by_pdb=${refused}"
