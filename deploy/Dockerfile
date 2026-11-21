# cxq server image: Python 3 stdlib only, no pip packages.
FROM python:3.12-slim

WORKDIR /app
COPY server/cxq_server.py /app/cxq_server.py
RUN mkdir -p /data

# The SQLite file lives on the mounted volume (/data). The token must be
# supplied at runtime (fly secrets set CXQ_TOKEN=...); the server refuses
# to start without it.
ENV CXQ_DB=/data/tasks.db

EXPOSE 8080
CMD ["python3", "cxq_server.py", "--host", "0.0.0.0", "--port", "8080", "--db", "/data/tasks.db"]
