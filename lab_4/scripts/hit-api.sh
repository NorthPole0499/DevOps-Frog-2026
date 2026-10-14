#!/usr/bin/env bash
exec kubectl exec -n shop deploy/worker -- python -u -c "
import urllib.request as u, json, time
ok = fail = 0
while True:
    try:
        u.urlopen('http://api:8080/health', timeout=2).read()
        v = json.loads(u.urlopen('http://api:8080/version', timeout=2).read())
        ok += 1; print(f'{time.strftime(\"%H:%M:%S\")} ok={ok} fail={fail}  {v[\"version\"]}  {v[\"hostname\"]}')
    except Exception as e:
        fail += 1; print(f'{time.strftime(\"%H:%M:%S\")} FAIL ok={ok} fail={fail}  {e}')
    time.sleep(0.2)
"
