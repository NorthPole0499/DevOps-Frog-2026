#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-shop}"
APP="${APP:-api}"

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
on_node() { docker exec "$1" sh -c "$2"; }

pod_pid() {
  local node="$1" cid="$2"
  on_node "${node}" "crictl inspect -o go-template --template '{{.info.pid}}' ${cid}"
}

pods=$(kubectl get pods -n "${NS}" -l "app.kubernetes.io/name=${APP}" --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.metadata.name} {.spec.nodeName} {.status.podIP} {.status.containerStatuses[0].containerID}{"\n"}{end}')

read -r A_POD A_NODE A_IP A_CID < <(echo "${pods}" | head -1)
read -r B_POD B_NODE B_IP B_CID < <(echo "${pods}" | awk -v n="${A_NODE}" '$2 != n' | head -1)
[ -n "${B_POD:-}" ] || { echo "все поды ${APP} на одной ноде — нужен под на другой ноде"; exit 1; }
A_CID="${A_CID#containerd://}"; B_CID="${B_CID#containerd://}"

step "Поды: A=${A_POD} (${A_NODE}, ${A_IP})  B=${B_POD} (${B_NODE}, ${B_IP})"
kubectl get pods -n "${NS}" -o wide -l "app.kubernetes.io/name=${APP}"
kubectl get nodes -o custom-columns='NODE:.metadata.name,INTERNAL-IP:.status.addresses[0].address,POD-CIDR:.spec.podCIDR'

A_PID=$(pod_pid "${A_NODE}" "${A_CID}")

step "Изнутри пода A (nsenter -t ${A_PID} -n): eth0 и маршруты"
on_node "${A_NODE}" "nsenter -t ${A_PID} -n ip -d addr show eth0"
on_node "${A_NODE}" "nsenter -t ${A_PID} -n ip route"
on_node "${A_NODE}" "nsenter -t ${A_PID} -n ip neigh"

PEER_IDX=$(on_node "${A_NODE}" "nsenter -t ${A_PID} -n ip -o link show eth0" | sed -E 's/.*eth0@if([0-9]+).*/\1/')

step "На ноде ${A_NODE}: интерфейс с ifindex ${PEER_IDX} — второй конец veth пода A"
PEER_IF=$(on_node "${A_NODE}" "ip -o link" | awk -F': ' -v i="${PEER_IDX}" '$1 == i {sub(/@.*/, "", $2); print $2}')
on_node "${A_NODE}" "ip -d link show ${PEER_IF}"
echo
echo "Маршрут ноды к поду A:"
on_node "${A_NODE}" "ip route get ${A_IP}"
echo
echo "Все veth на ноде:"
on_node "${A_NODE}" "ip -br link show type veth"

step "Маршруты между нодами: чужой podCIDR — через IP соседней ноды, без туннеля"
for n in "${A_NODE}" "${B_NODE}"; do
  echo "--- ${n}"
  on_node "${n}" "ip route | grep 10.244."
done
echo
echo "Путь пакета A -> B с ноды ${A_NODE}:"
on_node "${A_NODE}" "ip route get ${B_IP}"
echo "Туннельных интерфейсов нет:"
on_node "${A_NODE}" "ip -br link show type vxlan; ip -br link show type geneve" || true

step "Под A -> под B напрямую по IP (без Service и DNS)"
kubectl exec -n "${NS}" "${A_POD}" -- python -c "
import urllib.request as u, json
r = json.loads(u.urlopen('http://${B_IP}:8080/version', timeout=3).read())
print('ответил', r['hostname'], 'с IP ${B_IP}')
"

step "Тот же поток глазами Hubble (агент Cilium на ноде A)"
CILIUM_A=$(kubectl get pods -n kube-system -l k8s-app=cilium --field-selector "spec.nodeName=${A_NODE}" -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n kube-system "${CILIUM_A}" -c cilium-agent -- \
  hubble observe --from-ip "${A_IP}" --to-ip "${B_IP}" --last 6 --output compact

step "Как Cilium видит под A: эндпоинт и identity (по ним потом работают политики)"
A_ID=$(kubectl exec -n kube-system "${CILIUM_A}" -c cilium-agent -- cilium-dbg endpoint list -o jsonpath="{range [*]}{.status.networking.addressing[0].ipv4} {.status.identity.id}{'\n'}{end}" | awk -v ip="${A_IP}" '$1 == ip {print $2}')
kubectl exec -n kube-system "${CILIUM_A}" -c cilium-agent -- cilium-dbg identity get "${A_ID}"
