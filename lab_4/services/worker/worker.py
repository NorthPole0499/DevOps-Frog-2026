import json
import logging
import os
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, generate_latest

APP_VERSION = os.getenv("APP_VERSION", "dev")
HEALTH_FAIL = os.getenv("HEALTH_FAIL", "false").lower() in ("1", "true", "yes")
POLL_INTERVAL = float(os.getenv("POLL_INTERVAL", "2"))
BATCH_SIZE = int(os.getenv("BATCH_SIZE", "10"))
PROCESS_DELAY = float(os.getenv("PROCESS_DELAY", "0"))
PORT = int(os.getenv("PORT", "8080"))

class JsonFormatter(logging.Formatter):
    def format(self, record):
        entry = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname.lower(),
            "service": "worker",
            "version": APP_VERSION,
            "msg": record.getMessage(),
        }
        entry.update(getattr(record, "extra_fields", {}))
        return json.dumps(entry, ensure_ascii=False)

handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
log = logging.getLogger("worker")
log.addHandler(handler)
log.setLevel(logging.INFO)
log.propagate = False

PROCESSED = Counter("orders_processed_total", "Orders processed by worker")
DB_ERRORS = Counter("worker_db_errors_total", "Worker database errors")
PENDING = Gauge("orders_pending", "Orders with status=new seen on last poll")
LAST_SUCCESS = Gauge(
    "worker_last_success_timestamp_seconds", "Unix time of last successful poll"
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

CLAIM = """
UPDATE orders SET status = 'processed', processed_at = now()
WHERE id IN (
    SELECT id FROM orders WHERE status = 'new'
    ORDER BY id LIMIT %s
    FOR UPDATE SKIP LOCKED
)
RETURNING id
"""

stop = threading.Event()

def conninfo():
    return psycopg.conninfo.make_conninfo(
        host=os.getenv("DB_HOST", "localhost"),
        port=os.getenv("DB_PORT", "5432"),
        dbname=os.getenv("DB_NAME", "app"),
        user=os.getenv("DB_USER", "app"),
        password=os.getenv("DB_PASSWORD", ""),
        connect_timeout=3,
    )

def poll_once(conn):
    with conn.transaction():
        ids = [r[0] for r in conn.execute(CLAIM, (BATCH_SIZE,)).fetchall()]
        if ids and PROCESS_DELAY > 0:
            time.sleep(PROCESS_DELAY * len(ids))
    if ids:
        PROCESSED.inc(len(ids))
        log.info("orders processed", extra={"extra_fields": {"ids": ids}})
    PENDING.set(conn.execute("SELECT count(*) FROM orders WHERE status = 'new'").fetchone()[0])
    LAST_SUCCESS.set(time.time())

def loop():
    conn = None
    while not stop.is_set():
        try:
            if conn is None or conn.closed:
                conn = psycopg.connect(conninfo(), autocommit=True)
                conn.execute(SCHEMA)
                log.info("connected to database")
            poll_once(conn)
        except psycopg.Error as e:
            DB_ERRORS.inc()
            log.error("db error", extra={"extra_fields": {"error": str(e)}})
            try:
                if conn is not None:
                    conn.close()
            except Exception:
                pass
            conn = None
        stop.wait(POLL_INTERVAL)
    if conn is not None:
        conn.close()
    log.info("worker stopped")

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            code, body, ctype = (503, b"fail\n", "text/plain") if HEALTH_FAIL else (200, b"ok\n", "text/plain")
        elif self.path == "/metrics":
            code, body, ctype = 200, generate_latest(), CONTENT_TYPE_LATEST
        else:
            code, body, ctype = 404, b"not found\n", "text/plain"
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    def shutdown(signum, _frame):
        log.info("signal received, shutting down", extra={"extra_fields": {"signal": signum}})
        stop.set()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    log.info("worker starting", extra={"extra_fields": {"port": PORT, "health_fail": HEALTH_FAIL}})
    loop()
    server.shutdown()

if __name__ == "__main__":
    main()
