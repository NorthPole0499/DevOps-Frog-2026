FROM python:3.14-slim

WORKDIR /app

RUN pip install --no-cache-dir flask

COPY api.py .

EXPOSE 8080

CMD ["python3", "api.py"]
