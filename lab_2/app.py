import asyncio
import json
import logging
import os
import random
import sys
import time

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from prometheus_client import Counter, Histogram, make_asgi_app
from prometheus_client import generate_latest, CONTENT_TYPE_LATEST
from fastapi.responses import Response

SERVICE_NAME = os.getenv("OTEL_SERVICE_NAME", "api")

# ---- metrics (RED) ----
REQUESTS = Counter("http_requests_total", "HTTP requests", ["method", "path", "status"])
ERRORS = Counter("http_request_errors_total", "HTTP 5xx responses", ["method", "path"])
LATENCY = Histogram("http_request_duration_seconds", "HTTP latency", ["method", "path"])

# ---- tracing ----
resource = Resource.create({"service.name": SERVICE_NAME})
provider = TracerProvider(resource=resource)
otlp_endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://jaeger-collector:4317")
provider.add_span_processor(
    BatchSpanProcessor(OTLPSpanExporter(endpoint=otlp_endpoint, insecure=True))
)
trace.set_tracer_provider(provider)
tracer = trace.get_tracer(__name__)

# ---- structured JSON logging with trace_id ----
class JsonFormatter(logging.Formatter):
    def format(self, record):
        span = trace.get_current_span()
        ctx = span.get_span_context() if span else None
        trace_id = format(ctx.trace_id, "032x") if ctx and ctx.trace_id else None
        out = {
            "ts": self.formatTime(record),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
            "trace_id": trace_id,
        }
        if record.exc_info:
            out["exc"] = self.formatException(record.exc_info)
        return json.dumps(out)

handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
logging.basicConfig(level=logging.INFO, handlers=[handler])
log = logging.getLogger("api")

app = FastAPI()
FastAPIInstrumentor.instrument_app(app)

@app.get("/metrics")
async def metrics():
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)

@app.middleware("http")
async def metrics_mw(request: Request, call_next):
    path = request.url.path
    method = request.method
    start = time.perf_counter()
    try:
        response = await call_next(request)
    except Exception:
        ERRORS.labels(method, path).inc()
        REQUESTS.labels(method, path, "500").inc()
        raise
    dur = time.perf_counter() - start
    LATENCY.labels(method, path).observe(dur)
    REQUESTS.labels(method, path, str(response.status_code)).inc()
    if response.status_code >= 500:
        ERRORS.labels(method, path).inc()
    return response

@app.get("/health")
async def health():
    return {"status": "ok"}

@app.get("/fail")
async def fail():
    with tracer.start_as_current_span("fail-op") as span:
        span.set_status(trace.Status(trace.StatusCode.ERROR, "forced failure"))
        log.error("forced failure triggered")
        return JSONResponse(status_code=500, content={"error": "forced failure"})

@app.get("/slow")
async def slow():
    with tracer.start_as_current_span("slow-op") as span:
        delay = random.uniform(1.0, 3.0)
        span.set_attribute("slow.delay_seconds", delay)
        log.info("slow op start delay=%.2f" % delay)
        await asyncio.sleep(delay)
        log.info("slow op done")
        return {"slept": delay}

@app.get("/load")
async def load(request: Request, n: int = 20):
    base = str(request.base_url).rstrip("/")
    async with httpx.AsyncClient(timeout=15.0) as client:
        tasks = []
        for i in range(n):
            tasks.append(client.get(f"{base}/health"))
            if i % 5 == 0:
                tasks.append(client.get(f"{base}/slow"))
        await asyncio.gather(*tasks, return_exceptions=True)
    return {"sent": n}