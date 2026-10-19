FROM python:3.14 AS builder

WORKDIR /build

RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

RUN pip install --no-cache-dir flask

FROM python:3.14-slim

WORKDIR /app

COPY --from=builder /opt/venv /opt/venv
COPY api.py .

ENV PATH="/opt/venv/bin:$PITH"

EXPOSE 8080

CMD ["python3","api.py"]
