#!/usr/bin/env bash
set -euo pipefail

IMAGE="${TOOLBOX_IMAGE:-registry.shop.local/shop/worker:0.1.0}"
NAME="${TOOLBOX_NAME:-toolbox-$(date +%s)}"
LABELS="${TOOLBOX_LABELS:-app.kubernetes.io/name=toolbox,app.kubernetes.io/part-of=shop-tools,team=shop}"
NAMESPACE="${TOOLBOX_NAMESPACE:-shop}"

overrides="$(python3 - "${NAME}" "${IMAGE}" "$1" <<'PY'
import json, sys
name, image, code = sys.argv[1:4]
print(json.dumps({"spec": {
    "securityContext": {"runAsNonRoot": True, "runAsUser": 10001},
    "containers": [{
        "name": name,
        "image": image,
        "imagePullPolicy": "IfNotPresent",
        "command": ["python", "-u", "-c", code],
        "stdin": True,
        "resources": {"requests": {"cpu": "50m", "memory": "32Mi"},
                      "limits": {"cpu": "200m", "memory": "64Mi"}},
        "securityContext": {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}},
    }],
}}))
PY
)"

exec kubectl run "${NAME}" -n "${NAMESPACE}" --rm -i --quiet --restart=Never --image="${IMAGE}" \
  --labels="${LABELS}" \
  --overrides="${overrides}"
