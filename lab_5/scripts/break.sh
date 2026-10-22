#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALUES="${ROOT}/chart/shop/values.yaml"
STATE="${ROOT}/.break"
NS="${NS:-shop}"

VARIANTS=(port dns cidr deny)

patch() {
  case "$1" in
    port) perl -0pi -e 's/^(    postgres:) 5432$/$1 5433/m' "${VALUES}" ;;
    dns)  perl -0pi -e 's/^(    labels: \{k8s-app:) kube-dns\}$/$1 coredns}/m' "${VALUES}" ;;
    cidr) perl -0pi -e 's/^(  nodePortClientCIDRs: \["172\.)20(\.0\.0\/16"\])$/${1}21$2/m' "${VALUES}" ;;
    deny) perl -0pi -e 's/^(    - )fromEndpoints: \[\{matchLabels: \{k8s:io\.kubernetes\.pod\.namespace: other\}\}\]$/${1}fromEntities: [cluster]/m' "${VALUES}" ;;
  esac
}

describe() {
  case "$1" in
    port) echo "порт: networkPolicy.ports.postgres 5432 -> 5433" ;;
    dns)  echo "DNS: networkPolicy.dns.labels k8s-app=kube-dns -> k8s-app=coredns" ;;
    cidr) echo "CIDR: networkPolicy.nodePortClientCIDRs 172.20.0.0/16 -> 172.21.0.0/16" ;;
    deny) echo "deny: networkPolicy.postgresDeny fromEndpoints(ns other) -> fromEntities [cluster]" ;;
  esac
}

clean() { git -C "${ROOT}" diff --quiet -- "${VALUES}"; }

apply() {
  helm upgrade shop "${ROOT}/chart/shop" -n "${NS}" --reset-values >/dev/null
}

case "${1:-break}" in
  break)
    clean || { echo "values.yaml уже отличается от коммита — сначала почини или git checkout"; exit 1; }
    v="${VARIANTS[RANDOM % ${#VARIANTS[@]}]}"
    patch "${v}"
    clean && { echo "патч '${v}' не лёг на values.yaml — шаблон values изменился?"; exit 1; }
    printf '%s %s\n' "$(date +%FT%T)" "$(printf %s "${v}" | base64)" > "${STATE}"
    apply
    echo "поломка внесена в values.yaml и применена ($(date +%T)). Не смотри git diff — иди в Hubble."
    echo "когда починишь: $0 reveal"
    ;;
  reveal)
    [ -f "${STATE}" ] || { echo "поломка не вносилась"; exit 1; }
    read -r at enc < "${STATE}"
    echo "внесено ${at}: $(describe "$(printf %s "${enc}" | base64 --decode)")"
    if clean; then echo "values.yaml совпадает с коммитом — починено"; rm -f "${STATE}"; else
      echo "values.yaml всё ещё отличается от коммита:"; git -C "${ROOT}" diff --stat -- "${VALUES}"; fi
    ;;
  *) echo "использование: $0 [break|reveal]"; exit 1 ;;
esac
