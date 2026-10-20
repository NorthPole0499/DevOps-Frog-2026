#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import threading
import time
import urllib.parse

NS = os.environ.get("NS", "shop")
OTHER_NS = os.environ.get("OTHER_NS", "other")
IMAGE = os.environ.get("PROBE_IMAGE", "registry.shop.local/shop/worker:0.1.0")
CURL_IMAGE = os.environ.get("CURL_IMAGE", "curlimages/curl:8.11.1")
KIND_NETWORK = os.environ.get("KIND_NETWORK", "kind")
OUT = os.environ.get("OUT", "")
KEEP = os.environ.get("KEEP", "0") == "1"
TIMEOUT = 3

PY_TCP = """
import socket, sys
s = socket.socket()
s.settimeout(%d)
try:
    s.connect((sys.argv[1], int(sys.argv[2])))
    print('OPEN')
except socket.timeout:
    print('TIMEOUT')
except ConnectionRefusedError:
    print('REFUSED')
except OSError as e:
    print('ERROR')
""" % TIMEOUT

PY_DNS = """
import socket, signal
def stop(*args):
    raise TimeoutError
signal.signal(signal.SIGALRM, stop)
signal.alarm(4)
try:
    socket.getaddrinfo('kubernetes.default.svc.cluster.local', 443)
    print('OPEN')
except OSError:
    print('TIMEOUT')
"""

BASH_TCP = 'timeout %d bash -c "exec 3<>/dev/tcp/$0/$1" 2>/dev/null; echo $?' % TIMEOUT
BASH_DNS = "timeout 4 getent hosts kubernetes.default.svc.cluster.local >/dev/null 2>&1; echo $?"


def sh(*args, timeout=90):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


def kubectl(*args, timeout=90):
    return sh("kubectl", *args, timeout=timeout)


def jsonpath(ns, kind, name, path):
    return kubectl("get", kind, name, "-n", ns, "-o", "jsonpath=" + path).stdout.strip()


def first_pod(ns, selector, exclude=None):
    out = kubectl("get", "pods", "-n", ns, "-l", selector, "--field-selector=status.phase=Running",
                  "-o", "jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end}").stdout.split()
    out = [p for p in out if p != exclude]
    return out[0]


def pod_ip(ns, name):
    return jsonpath(ns, "pod", name, "{.status.podIP}")


def ensure_probe(ns, name, labels, ready=True):
    kubectl("delete", "pod", name, "-n", ns, "--ignore-not-found", "--wait=true")
    spec = {"spec": {"containers": [{
        "name": name, "image": IMAGE, "imagePullPolicy": "IfNotPresent",
        "command": ["sleep", "3600"],
        "resources": {"requests": {"cpu": "10m", "memory": "16Mi"}, "limits": {"cpu": "100m", "memory": "64Mi"}},
    }]}}
    if not ready:
        spec["spec"]["containers"][0]["readinessProbe"] = {"exec": {"command": ["/bin/false"]}, "periodSeconds": 3600}
    r = kubectl("run", name, "-n", ns, "--restart=Never", "--image", IMAGE, "--labels", labels,
                "--overrides", json.dumps(spec))
    if r.returncode != 0:
        sys.exit("не удалось создать под %s/%s: %s" % (ns, name, r.stderr))
    kubectl("wait", "pod/" + name, "-n", ns, "--for=jsonpath={.status.phase}=Running", "--timeout=120s", timeout=130)


class Source:
    def __init__(self, key, label, ns, pod, container, kind):
        self.key, self.label, self.ns, self.pod, self.container, self.kind = key, label, ns, pod, container, kind

    def tcp(self, ip, port):
        if self.kind == "bash":
            r = kubectl("exec", "-n", self.ns, self.pod, "-c", self.container, "--", "bash", "-c", BASH_TCP, ip, str(port))
            code = (r.stdout.strip().splitlines() or ["?"])[-1]
            return {"0": "OPEN", "124": "TIMEOUT", "1": "REFUSED"}.get(code, "ERROR")
        r = kubectl("exec", "-n", self.ns, self.pod, "-c", self.container, "--", "python", "-c", PY_TCP, ip, str(port))
        return (r.stdout.strip().splitlines() or ["ERROR"])[-1]

    def dns(self):
        if self.kind == "bash":
            r = kubectl("exec", "-n", self.ns, self.pod, "-c", self.container, "--", "bash", "-c", BASH_DNS)
            return "OPEN" if (r.stdout.strip().splitlines() or ["?"])[-1] == "0" else "TIMEOUT"
        r = kubectl("exec", "-n", self.ns, self.pod, "-c", self.container, "--", "python", "-c", PY_DNS)
        return (r.stdout.strip().splitlines() or ["ERROR"])[-1]


class Stream:
    def __init__(self, agent):
        self.flows = []
        self.proc = subprocess.Popen(
            ["kubectl", "exec", "-n", "kube-system", agent, "-c", "cilium-agent", "--",
             "timeout", "1800", "hubble", "observe", "--follow", "--verdict", "DROPPED", "-o", "json"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        for line in self.proc.stdout:
            try:
                flow = json.loads(line).get("flow")
            except ValueError:
                continue
            if flow:
                self.flows.append((time.time(), flow))

    def stop(self):
        self.proc.terminate()


def flow_port(flow):
    l4 = flow.get("l4", {})
    for proto in ("TCP", "UDP"):
        if proto in l4:
            return l4[proto].get("destination_port")
    return None


def drops(streams, src, dst, t0, t1):
    n = 0
    for stream in streams:
        for arrived, flow in list(stream.flows):
            if not (t0 <= arrived <= t1):
                continue
            s, d = flow.get("source", {}), flow.get("destination", {})
            if s.get("pod_name") != src.pod or s.get("namespace") != src.ns:
                continue
            if flow_port(flow) != dst["flow"]:
                continue
            labels = " ".join(d.get("labels", []))
            if dst["tok"] in labels or flow.get("IP", {}).get("destination") == dst["ip"]:
                n += 1
    return n


def prometheus_up():
    query = 'min by (job) (up{namespace="%s"})' % NS
    path = ("/api/v1/namespaces/monitoring/services/monitoring-kube-prometheus-prometheus:9090/proxy/api/v1/query?query="
            + urllib.parse.quote(query))
    r = kubectl("get", "--raw", path)
    try:
        data = json.loads(r.stdout)["data"]["result"]
    except (ValueError, KeyError):
        return {}
    return {x["metric"]["job"]: x["value"][1] for x in data}


def pods_ready(selector):
    r = kubectl("get", "pods", "-n", NS, "-l", selector, "-o",
                "jsonpath={range .items[*]}{.status.containerStatuses[*].ready}{\"\\n\"}{end}")
    rows = r.stdout.split()
    return bool(rows) and all(x == "true" for x in rows)


def main():
    for tool in ("kubectl", "docker"):
        if sh("which", tool).returncode != 0:
            sys.exit("нужен " + tool)

    print("подготовка: подопытные поды и адреса...", file=sys.stderr)
    ensure_probe(NS, "other", "app=other", ready=True)
    kubectl("create", "namespace", OTHER_NS)
    ensure_probe(OTHER_NS, "other", "app=other", ready=True)
    ensure_probe("monitoring", "prom-probe", "app.kubernetes.io/name=prometheus", ready=False)
    ensure_probe("cnpg-system", "operator-probe", "app.kubernetes.io/name=cloudnative-pg", ready=False)

    api_pods = kubectl("get", "pods", "-n", NS, "-l", "app.kubernetes.io/name=api", "--field-selector=status.phase=Running",
                       "-o", "jsonpath={.items[*].metadata.name}").stdout.split()
    worker_pods = kubectl("get", "pods", "-n", NS, "-l", "app.kubernetes.io/name=worker", "--field-selector=status.phase=Running",
                          "-o", "jsonpath={.items[*].metadata.name}").stdout.split()
    api_pod, worker_pod = api_pods[0], worker_pods[0]
    pg_pod = first_pod(NS, "app.kubernetes.io/name=postgres")
    client_pod = first_pod(NS, "app.kubernetes.io/name=client")

    sources = {
        "api": Source("api", "api", NS, api_pod, "api", "py"),
        "worker": Source("worker", "worker", NS, worker_pod, "worker", "bash"),
        "postgres": Source("postgres", "postgres", NS, pg_pod, "postgres", "bash"),
        "client": Source("client", "client", NS, client_pod, "client", "py"),
        "other": Source("other", "other (shop)", NS, "other", "other", "py"),
        "other_ns": Source("other_ns", "other (ns %s)" % OTHER_NS, OTHER_NS, "other", "other", "py"),
        "prometheus": Source("prometheus", "Prometheus (ns monitoring)", "monitoring", "prom-probe", "prom-probe", "py"),
        "operator": Source("operator", "оператор CNPG (ns cnpg-system)", "cnpg-system", "operator-probe", "operator-probe", "py"),
    }

    dst = {
        "api": dict(ip=jsonpath(NS, "svc", "api", "{.spec.clusterIP}"), port=8080, flow=8080, tok="app.kubernetes.io/name=api"),
        "worker": dict(ip=jsonpath(NS, "svc", "worker", "{.spec.clusterIP}"), port=8080, flow=8080, tok="app.kubernetes.io/name=worker"),
        "postgres": dict(ip=jsonpath(NS, "svc", "shop-postgres-rw", "{.spec.clusterIP}"), port=5432, flow=5432, tok="app.kubernetes.io/name=postgres"),
        "client": dict(ip=pod_ip(NS, client_pod), port=8080, flow=8080, tok="app.kubernetes.io/name=client"),
        "other": dict(ip=pod_ip(NS, "other"), port=8080, flow=8080, tok="k8s:app=other"),
        "dns": dict(ip=jsonpath("kube-system", "svc", "kube-dns", "{.spec.clusterIP}"), port=53, flow=53, tok="k8s-app=kube-dns"),
        "apiserver": dict(ip=jsonpath("default", "svc", "kubernetes", "{.spec.clusterIP}"), port=443, flow=6443, tok="reserved:kube-apiserver"),
        "world": dict(ip="1.1.1.1", port=443, flow=443, tok="reserved:world"),
    }
    pg_ip = pod_ip(NS, pg_pod)
    other_api = dict(dst["api"], ip=pod_ip(NS, api_pods[1]) if len(api_pods) > 1 else dst["api"]["ip"])
    other_worker = dict(dst["worker"], ip=pod_ip(NS, worker_pods[1]) if len(worker_pods) > 1 else dst["worker"]["ip"])
    pg_status = dict(dst["postgres"], ip=pg_ip, port=8000, flow=8000)
    pg_metrics = dict(dst["postgres"], ip=pg_ip, port=9187, flow=9187)
    pg_direct = dict(dst["postgres"], ip=pg_ip)

    plan = []

    def add(src, dkey, expect, dest=None, grid=True, label=None):
        plan.append(dict(src=src, dkey=dkey, expect=expect, dest=dest or dst[dkey], grid=grid, label=label))

    add("api", "api", "Deny", other_api)
    add("api", "worker", "Deny")
    add("api", "postgres", "Allow")
    add("api", "client", "Deny")
    add("api", "other", "Deny")
    add("api", "dns", "Allow")
    add("api", "apiserver", "Deny")
    add("api", "world", "Deny")

    add("worker", "api", "Deny")
    add("worker", "worker", "Deny", other_worker)
    add("worker", "postgres", "Allow")
    add("worker", "client", "Deny")
    add("worker", "other", "Deny")
    add("worker", "dns", "Allow")
    add("worker", "apiserver", "Deny")
    add("worker", "world", "Deny")

    add("postgres", "api", "Deny")
    add("postgres", "worker", "Deny")
    add("postgres", "client", "Deny")
    add("postgres", "other", "Deny")
    add("postgres", "dns", "Deny")
    add("postgres", "apiserver", "Allow")
    add("postgres", "world", "Deny")

    add("client", "api", "Allow")
    add("client", "worker", "Deny")
    add("client", "postgres", "Deny")
    add("client", "other", "Deny")
    add("client", "dns", "Allow")
    add("client", "apiserver", "Deny")
    add("client", "world", "Deny")

    add("other", "api", "Deny")
    add("other", "worker", "Deny")
    add("other", "postgres", "Deny")
    add("other", "client", "Deny")
    add("other", "dns", "Allow")
    add("other", "apiserver", "Deny")
    add("other", "world", "Deny")

    add("other_ns", "api", "Deny")
    add("other_ns", "worker", "Deny")
    add("other_ns", "postgres", "Deny")
    add("other_ns", "client", "Deny")
    add("other_ns", "other", "Deny")

    add("prometheus", "api", "Allow")
    add("prometheus", "worker", "Allow")
    add("prometheus", "postgres", "Deny", pg_metrics)
    add("prometheus", "client", "Allow")
    add("prometheus", "other", "Deny")

    add("operator", "api", "Deny")
    add("operator", "worker", "Deny")
    add("operator", "postgres", "Allow", pg_status)
    add("operator", "client", "Deny")
    add("operator", "other", "Deny")
    add("operator", "postgres", "Deny", pg_direct, grid=False, label="postgres :5432 (в обход Service)")

    agents = kubectl("get", "pods", "-n", "kube-system", "-l", "k8s-app=cilium", "-o", "name").stdout.split()
    streams = [Stream(a.split("/")[-1]) for a in agents]
    time.sleep(3)

    results = []
    total = len(plan)
    for i, cell in enumerate(plan, 1):
        src, d = sources[cell["src"]], cell["dest"]
        print("[%d/%d] %s -> %s:%s" % (i, total, src.label, cell["dkey"], d["port"]), file=sys.stderr)
        t0 = time.time()
        if cell["dkey"] == "dns":
            udp = src.dns()
            tcp = src.tcp(d["ip"], 53)
            actual = udp if udp == tcp else "UDP=%s TCP=%s" % (udp, tcp)
        else:
            actual = src.tcp(d["ip"], d["port"])
        t1 = time.time() + 2.5
        results.append(dict(cell, actual=actual, t0=t0, t1=t1, source=src, port=d["port"]))

    print("внешний клиент через NodePort, Prometheus и kubelet...", file=sys.stderr)
    node_port = jsonpath(NS, "svc", "api", "{.spec.ports[0].nodePort}")
    nodes = kubectl("get", "nodes", "-o", "jsonpath={.items[*].metadata.name}").stdout.split()
    extra = []
    for node in nodes:
        r = sh("docker", "run", "--rm", "--network", KIND_NETWORK, CURL_IMAGE, "-s", "-m", str(TIMEOUT),
               "-o", "/dev/null", "-w", "%{http_code}", "http://%s:%s/version" % (node, node_port))
        code = r.stdout.strip()
        extra.append(dict(src="nodeport", srclabel="клиент снаружи (NodePort, сеть Docker)", dkey="api", port="%s на %s" % (node_port, node),
                          expect="Allow", actual="HTTP 200" if code == "200" else ("TIMEOUT" if code in ("000", "") else "HTTP " + code),
                          good="HTTP 200", grid=True, label=None))
    up = prometheus_up()
    for job, dkey in (("api", "api"), ("worker", "worker"), ("shop/client", "client")):
        extra.append(dict(src="prometheus_real", srclabel="Prometheus (реальные targets)", dkey=dkey, port="up",
                          expect="Allow", actual="up=1" if up.get(job) == "1" else "up=%s" % up.get(job, "нет"),
                          good="up=1", grid=False, label=None))
    for dkey, selector in (("api", "app.kubernetes.io/name=api"), ("worker", "app.kubernetes.io/name=worker"),
                           ("postgres", "app.kubernetes.io/name=postgres"), ("client", "app.kubernetes.io/name=client")):
        extra.append(dict(src="kubelet", srclabel="нода / kubelet (пробы)", dkey=dkey, port="Ready",
                          expect="Allow", actual="Ready" if pods_ready(selector) else "NotReady",
                          good="Ready", grid=True, label=None))

    time.sleep(3)
    for s in streams:
        s.stop()

    rows = []
    for r in results:
        n = drops(streams, r["source"], r["dest"], r["t0"], r["t1"])
        if r["expect"] == "Allow":
            ok = r["actual"] == "OPEN" and n == 0
            evidence = "—" if n == 0 else "DROPPED ×%d" % n
        else:
            ok = r["actual"] == "TIMEOUT" and n > 0
            evidence = "DROPPED ×%d" % n if n else "нет DROPPED"
        rows.append(dict(src=r["src"], srclabel=r["source"].label, dkey=r["dkey"], port=r["port"], expect=r["expect"],
                         actual=r["actual"], evidence=evidence, ok=ok, grid=r["grid"], label=r["label"]))
    for e in extra:
        rows.append(dict(src=e["src"], srclabel=e["srclabel"], dkey=e["dkey"], port=e["port"], expect=e["expect"],
                         actual=e["actual"], evidence="—", ok=e["actual"] == e["good"], grid=e["grid"], label=e["label"]))

    cols = ["api", "worker", "postgres", "client", "other", "dns", "apiserver", "world"]
    heads = ["api", "worker", "postgres", "client", "other", "kube-dns", "API-сервер", "world"]
    order = []
    for r in rows:
        if r["grid"] and r["src"] not in order:
            order.append(r["src"])
    labels = {r["src"]: r["srclabel"] for r in rows}

    out = []
    out.append("### Матрица: ожидаемо (Allow/Deny) и вердикт (✓ совпало, ✗ нет)\n")
    out.append("| источник ↓ / адресат → | " + " | ".join(heads) + " |")
    out.append("|---|" + "---|" * len(cols))
    for s in order:
        cells = []
        for c in cols:
            hit = [r for r in rows if r["src"] == s and r["dkey"] == c and r["grid"]]
            if not hit:
                cells.append("·")
            else:
                mark = "✓" if all(r["ok"] for r in hit) else "✗"
                cells.append("%s %s" % (hit[0]["expect"], mark))
        out.append("| **%s** | %s |" % (labels[s], " | ".join(cells)))
    out.append("")
    out.append("### Подробно: каждая проверка\n")
    out.append("| источник | адресат | порт | ожидаемо | фактически | Hubble | вердикт |")
    out.append("|---|---|---|---|---|---|---|")
    for r in rows:
        dest = r["label"] or r["dkey"]
        out.append("| %s | %s | %s | %s | %s | %s | %s |" % (
            r["srclabel"], dest, r["port"], r["expect"], r["actual"], r["evidence"], "OK" if r["ok"] else "**FAIL**"))
    failed = [r for r in rows if not r["ok"]]
    out.append("")
    out.append("Проверок: %d, совпало: %d, не совпало: %d" % (len(rows), len(rows) - len(failed), len(failed)))
    text = "\n".join(out)
    print(text)
    if OUT:
        with open(OUT, "w") as f:
            f.write(text + "\n")

    if not KEEP:
        for ns, name in ((NS, "other"), (OTHER_NS, "other"), ("monitoring", "prom-probe"), ("cnpg-system", "operator-probe")):
            kubectl("delete", "pod", name, "-n", ns, "--ignore-not-found", "--wait=false")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
