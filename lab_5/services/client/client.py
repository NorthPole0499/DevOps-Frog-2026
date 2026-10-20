import json
import os
import time
import urllib.error
import urllib.request

from prometheus_client import Counter, Histogram, start_http_server

TARGET = os.getenv("TARGET", "http://api:8080")
RPS = float(os.getenv("RPS", "10"))
TIMEOUT = float(os.getenv("TIMEOUT", "2"))
REQUEST = os.getenv("REQUEST", "version")
METRICS_PORT = int(os.getenv("METRICS_PORT", "8080"))

REQUESTS = Counter("shop_client_requests_total", "Client requests to api", ["result", "reason"])
LATENCY = Histogram(
    "shop_client_request_duration_seconds", "Client request latency",
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2),
)


def log(**fields):
    print(json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%S"), **fields}), flush=True)


def call():
    if REQUEST == "order":
        req = urllib.request.Request(
            f"{TARGET}/order",
            data=json.dumps({"item": "chaos"}).encode(),
            headers={"Content-Type": "application/json", "Connection": "close"},
        )
        expected = 201
    else:
        req = urllib.request.Request(f"{TARGET}/version", headers={"Connection": "close"})
        expected = 200
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        body = resp.read()
        return resp.status == expected, resp.status, body


def main():
    start_http_server(METRICS_PORT)
    REQUESTS.labels("ok", "none").inc(0)
    for reason in ("http", "connect", "timeout", "other"):
        REQUESTS.labels("fail", reason).inc(0)
    log(msg="start", target=TARGET, request=REQUEST, rps=RPS)
    interval = 1 / RPS
    ok = fail = 0
    backends = set()
    next_at = time.monotonic()
    while True:
        started = time.monotonic()
        try:
            good, status, body = call()
            if good:
                REQUESTS.labels("ok", "none").inc()
                ok += 1
                if REQUEST != "order":
                    host = json.loads(body).get("hostname", "")
                    if host not in backends:
                        backends.add(host)
                        log(msg="new backend", pod=host, seen=len(backends))
            else:
                REQUESTS.labels("fail", "http").inc()
                fail += 1
                log(msg="fail", reason="http", status=status)
        except urllib.error.HTTPError as e:
            REQUESTS.labels("fail", "http").inc()
            fail += 1
            log(msg="fail", reason="http", status=e.code)
        except urllib.error.URLError as e:
            reason = "timeout" if isinstance(e.reason, TimeoutError) else "connect"
            REQUESTS.labels("fail", reason).inc()
            fail += 1
            log(msg="fail", reason=reason, error=str(e.reason))
        except TimeoutError as e:
            REQUESTS.labels("fail", "timeout").inc()
            fail += 1
            log(msg="fail", reason="timeout", error=repr(e))
        except Exception as e:
            REQUESTS.labels("fail", "other").inc()
            fail += 1
            log(msg="fail", reason="other", error=repr(e))
        LATENCY.observe(time.monotonic() - started)
        if (ok + fail) % max(1, int(RPS * 30)) == 0:
            log(msg="progress", ok=ok, fail=fail, backends_seen=len(backends))
        next_at += interval
        time.sleep(max(0, next_at - time.monotonic()))


if __name__ == "__main__":
    main()
