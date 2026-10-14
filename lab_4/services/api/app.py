import json
import logging
import os
import sys
import time

import psycopg
from flask import Flask, Response, g, jsonify, request
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

APP_VERSION = os.getenv("APP_VERSION", "dev")
HEALTH_FAIL = os.getenv("HEALTH_FAIL", "false").lower() in ("1", "true", "yes")

class JsonFormatter(logging.Formatter):
    def format(self, record):
        entry = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname.lower(),
            "service": "api",
            "version": APP_VERSION,
            "msg": record.getMessage(),
        }
        entry.update(getattr(record, "extra_fields", {}))
        return json.dumps(entry, ensure_ascii=False)

handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
log = logging.getLogger("api")
log.addHandler(handler)
log.setLevel(logging.INFO)
log.propagate = False
logging.getLogger("werkzeug").setLevel(logging.WARNING)

REQUESTS = Counter(
    "http_requests_total", "HTTP requests", ["method", "path", "status"]
)
LATENCY = Histogram(
    "http_request_duration_seconds", "HTTP request latency", ["method", "path"]
)
ORDERS_CREATED = Counter("orders_created_total", "Orders created")
DB_ERRORS = Counter("db_errors_total", "Database errors", ["op"])

app = Flask(__name__)

def db_conninfo():
    return psycopg.conninfo.make_conninfo(
        host=os.getenv("DB_HOST", "localhost"),
        port=os.getenv("DB_PORT", "5432"),
        dbname=os.getenv("DB_NAME", "app"),
        user=os.getenv("DB_USER", "app"),
        password=os.getenv("DB_PASSWORD", ""),
        connect_timeout=3,
    )

SCHEMA = """
CREATE TABLE IF NOT EXISTS orders (
    id           SERIAL PRIMARY KEY,
    item         TEXT        NOT NULL,
    qty          INTEGER     NOT NULL DEFAULT 1,
    status       TEXT        NOT NULL DEFAULT 'new',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at TIMESTAMPTZ
)
"""

_schema_ready = False

def get_conn():
    global _schema_ready
    conn = psycopg.connect(db_conninfo(), autocommit=True)
    if not _schema_ready:
        conn.execute(SCHEMA)
        _schema_ready = True
    return conn

@app.before_request
def _start_timer():
    g.start = time.perf_counter()

@app.after_request
def _record(resp):
    path = request.url_rule.rule if request.url_rule else "unmatched"
    if path != "/metrics":
        REQUESTS.labels(request.method, path, str(resp.status_code)).inc()
        LATENCY.labels(request.method, path).observe(time.perf_counter() - g.start)
    if path not in ("/health", "/metrics"):
        log.info(
            "request",
            extra={
                "extra_fields": {
                    "method": request.method,
                    "path": request.path,
                    "status": resp.status_code,
                    "duration_ms": round((time.perf_counter() - g.start) * 1000, 1),
                }
            },
        )
    return resp

@app.get("/health")
def health():
    if HEALTH_FAIL:
        return Response("fail\n", status=503, mimetype="text/plain")
    return Response("ok\n", mimetype="text/plain")

@app.get("/version")
def version():
    return jsonify(version=APP_VERSION, hostname=os.getenv("HOSTNAME", ""))

@app.post("/order")
def create_order():
    body = request.get_json(silent=True) or {}
    item = str(body.get("item") or "widget")
    try:
        qty = int(body.get("qty") or 1)
    except (TypeError, ValueError):
        return jsonify(error="qty must be integer"), 400
    try:
        with get_conn() as conn:
            row = conn.execute(
                "INSERT INTO orders (item, qty) VALUES (%s, %s) "
                "RETURNING id, item, qty, status, created_at",
                (item, qty),
            ).fetchone()
    except psycopg.Error as e:
        DB_ERRORS.labels("insert").inc()
        log.error("db insert failed", extra={"extra_fields": {"error": str(e)}})
        return jsonify(error="database unavailable"), 503
    ORDERS_CREATED.inc()
    return (
        jsonify(
            id=row[0], item=row[1], qty=row[2], status=row[3],
            created_at=row[4].isoformat(),
        ),
        201,
    )

@app.get("/orders")
def list_orders():
    limit = min(int(request.args.get("limit", 50)), 500)
    try:
        with get_conn() as conn:
            rows = conn.execute(
                "SELECT id, item, qty, status, created_at, processed_at "
                "FROM orders ORDER BY id DESC LIMIT %s",
                (limit,),
            ).fetchall()
    except psycopg.Error as e:
        DB_ERRORS.labels("select").inc()
        log.error("db select failed", extra={"extra_fields": {"error": str(e)}})
        return jsonify(error="database unavailable"), 503
    return jsonify(
        [
            {
                "id": r[0], "item": r[1], "qty": r[2], "status": r[3],
                "created_at": r[4].isoformat(),
                "processed_at": r[5].isoformat() if r[5] else None,
            }
            for r in rows
        ]
    )

@app.get("/metrics")
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)

log.info("api starting", extra={"extra_fields": {"health_fail": HEALTH_FAIL}})
