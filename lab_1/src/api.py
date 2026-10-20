from flask import Flask, request
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
import time

app = Flask(__name__)

REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "endpoint", "status"]
)

REQUEST_DURATION = Histogram(
    "http_request_duration_seconds",
    "HTTP request duration",
    ["endpoint"]
)

allocated_memory = []

@app.get("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}

@app.get("/health")
def health():
	return "ok\n"

@app.before_request
def start_timer():
    request._start_time = time.time()

@app.after_request
def record_metrics(response):
    endpoint = request.path

    REQUEST_COUNT.labels(
        method=request.method,
        endpoint=endpoint,
        status=response.status_code
    ).inc()

    if hasattr(request, "_start_time"):
        REQUEST_DURATION.labels(
            endpoint=endpoint
        ).observe(time.time() - request._start_time)

    return response




@app.get("/eat")
def eat():
	mb = int(request.args.get("mb", 1))

	block = bytearray(mb * 1024 * 1024)
	allocated_memory.append(block)

	return f"Allocated and holding {mb} MB\n"

@app.get("/burn")
def burn():
	while True:
		pass

if __name__ == "__main__":
	app.run(host="0.0.0.0", port=8080)
