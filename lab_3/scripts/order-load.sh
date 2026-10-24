#!/usr/bin/env bash
exec kubectl exec -n shop deploy/api -- python -u -c "
import urllib.request as u, urllib.error as ue, json, time
period = 1 / float(${RATE:-2})
ok = fail = 0
while True:
    try:
        req = u.Request('http://api:8080/order', data=json.dumps({'item': 'load'}).encode(),
                        headers={'Content-Type': 'application/json'})
        u.urlopen(req, timeout=3).read()
        u.urlopen('http://api:8080/orders?limit=20', timeout=3).read()
        ok += 1
    except ue.HTTPError as e:
        fail += 1
    except Exception as e:
        fail += 1
    if (ok + fail) % 20 == 0:
        print(f'{time.strftime(\"%H:%M:%S\")} ok={ok} fail={fail}')
    time.sleep(period)
"
