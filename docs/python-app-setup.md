# Wiring a Python app into soldevelo-monitoring

Python's runtime is rarely the bottleneck the way JVM heap can be, so a Python
service dashboard is less about the language and more about the application:
process resource use + HTTP RED metrics (if it's a web app) + your business
metrics. Wiring: one dependency, a few lines, 4 labels, and (for a web app) a
framework instrumentor. ~15 minutes.

## 1. Dependency

```
prometheus-client>=0.20
```

## 2. Expose `/metrics`

### Web frameworks — use the framework instrumentor

Each framework has a small library that exposes `/metrics` **and**
auto-instruments HTTP requests, so you get RED metrics
(`http_requests_total`, `http_request_duration_seconds_*`) for free.

**Flask:**
```
pip install prometheus-flask-exporter
```
```python
from flask import Flask
from prometheus_flask_exporter import PrometheusMetrics
app = Flask(__name__)
metrics = PrometheusMetrics(app)
```

**FastAPI:**
```
pip install prometheus-fastapi-instrumentator
```
```python
from fastapi import FastAPI
from prometheus_fastapi_instrumentator import Instrumentator
app = FastAPI()
Instrumentator().instrument(app).expose(app)
```

**Django:**
```
pip install django-prometheus
```
```python
# settings.py
INSTALLED_APPS = ['django_prometheus', ...]
MIDDLEWARE = ['django_prometheus.middleware.PrometheusBeforeMiddleware', ...,
              'django_prometheus.middleware.PrometheusAfterMiddleware']
# urls.py
urlpatterns = [path('', include('django_prometheus.urls')), ...]
```

### Non-web apps (workers, scripts, daemons)

Spin up the metrics server yourself:

```python
from prometheus_client import start_http_server
start_http_server(9000)   # exposes /metrics on :9000
```

This is what the CFP Classifier `classifier` workers do — `/metrics` on `9000`.
Add your own counters/gauges alongside (see [`business-metrics.md`](business-metrics.md)).

## 3. Label the service for discovery

Add compose labels so the Alloy agent scrapes it (no host port publishing
needed — the agent reaches it on the internal docker network):

```yaml
services:
  classifier:
    labels:
      monitoring.scrape: "true"
      monitoring.port: "9000"
      monitoring.service: "classifier"
```

`monitoring.path` defaults to `/metrics`; set it only for a non-default path
(Django serves `/metrics/` with a trailing slash). `monitoring.service` becomes
the `service` label; `app` / `deployment` / `host` come from the agent's env.
Don't attach `app`/`deployment`/`service` in Python code — the agent owns those
labels. On Kubernetes use `prometheus.io/scrape|port|path` pod annotations.
Contract: [`metrics.md`](metrics.md).

## 4. Verify

From the app's host:
```bash
docker compose exec classifier curl -s localhost:9000/metrics | head -20
```
Should print at least `process_resident_memory_bytes`, `process_cpu_seconds_total`,
`process_open_fds`, `python_gc_collections_total` (web apps also
`http_requests_total`). Then Grafana → **Python application**.

## Common gotchas

- **All values are zero under gunicorn/uvicorn workers** — `prometheus_client`
  keeps metrics per-process; with `--workers N`, the scrape hits whichever
  worker answers. Fix: multiprocess mode — export
  `PROMETHEUS_MULTIPROC_DIR=/tmp/prom_multiproc`, create the dir, and call
  `multiprocess.mark_process_dead(worker.pid)` in your `child_exit` hook. Each
  instrumentor's docs cover the wiring. Single-process apps: skip.
- **`/metrics` returns 404** — Django: verify the middleware *and* the URL
  include; Flask/FastAPI: the instrumentor must be wired before start.
- **Django path is `/metrics/`** (trailing slash) — set
  `monitoring.path: "/metrics/"`.
