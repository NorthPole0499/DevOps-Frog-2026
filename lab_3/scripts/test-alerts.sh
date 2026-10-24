#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROM_IMAGE="${PROM_IMAGE:-quay.io/prometheus/prometheus:v3.14.0}"
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

helm template shop "${ROOT}/chart/shop" -n shop -s templates/prometheusrule.yaml \
  | python3 -c 'import sys, yaml; yaml.safe_dump(yaml.safe_load(sys.stdin)["spec"], sys.stdout, allow_unicode=True)' \
  > "${WORK}/rules.yaml"
cp "${ROOT}/tests/alerts.test.yaml" "${WORK}/"

docker run --rm -v "${WORK}:/w" -w /w --entrypoint promtool "${PROM_IMAGE}" check rules rules.yaml
docker run --rm -v "${WORK}:/w" -w /w --entrypoint promtool "${PROM_IMAGE}" test rules alerts.test.yaml
