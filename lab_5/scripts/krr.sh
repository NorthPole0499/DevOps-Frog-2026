#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${ROOT}/krr"
PROM="${PROM:-http://localhost:9090}"
HISTORY_HOURS="${HISTORY_HOURS:-1}"
STEP_MINUTES="${STEP_MINUTES:-1}"
POINTS="${POINTS:-50}"
CPU_PERCENTILE=95
MEMORY_BUFFER=15
MEM_MIN="${MEM_MIN:-32}"
CPU_MIN="${CPU_MIN:-10}"

mkdir -p "${OUT}"
args=(simple -n shop -s app.kubernetes.io/part-of=shop -p "${PROM}"
  --history_duration "${HISTORY_HOURS}" --timeframe_duration "${STEP_MINUTES}" --points_required "${POINTS}"
  --cpu_percentile "${CPU_PERCENTILE}" --memory_buffer_percentage "${MEMORY_BUFFER}"
  --mem-min "${MEM_MIN}" --cpu-min "${CPU_MIN}" -q)

COLUMNS=220 krr "${args[@]}" -f table | tee "${OUT}/report.txt"
krr "${args[@]}" -f json > "${OUT}/report.json"

promq() {
  curl -sfG "${PROM}/api/v1/query" --data-urlencode "query=$1" \
    | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "nan")'
}

window="${HISTORY_HOURS}h"
step="${STEP_MINUTES}m"
sel='namespace="shop",container="postgres"'
pg_cpu=$(promq "quantile_over_time(0.${CPU_PERCENTILE}, max(rate(container_cpu_usage_seconds_total{${sel}}[${step}]))[${window}:${step}])")
pg_mem=$(promq "max(max_over_time(container_memory_working_set_bytes{${sel}}[${window}]))")
python3 - "${pg_cpu}" "${pg_mem}" "${MEMORY_BUFFER}" "${CPU_MIN}" "${MEM_MIN}" <<'PY' | tee "${OUT}/postgres.txt"
import sys
cpu, mem, buf, cpu_min, mem_min = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
cpu_m = max(cpu_min, round(cpu * 1000))
mem_mi = max(mem_min, round(mem * (1 + buf / 100) / 1048576))
print("postgres (CNPG Cluster, krr его не видит; тот же алгоритм simple через PromQL)")
print(f"  CPU p95 = {cpu * 1000:.0f}m -> request {cpu_m}m, limit: нет")
print(f"  memory max = {mem / 1048576:.0f}Mi -> request = limit = {mem_mi}Mi")
PY
