# Wiring a Python app into soldevelo-monitoring

Python's runtime is rarely the bottleneck the way JVM heap can be, so a
Python service dashboard is less about the language and more about the
application: process resource use + HTTP RED metrics (if it's a web app) +
your business metrics. Total wiring: one dependency, a few lines of setup,
one JSON file, and (for a web app) a framework-specific instrumentor.
~15 minutes.

## 1. Dependency

Add `prometheus_client` to your project:

```
prometheus-client>=0.20
```

## 2. Expose `/metrics`

The pattern depends on how your app runs:

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
MIDDLEWARE = [
    'django_prometheus.middleware.PrometheusBeforeMiddleware',
    ...
    'django_prometheus.middleware.PrometheusAfterMiddleware',
]

# urls.py
urlpatterns = [
    path('', include('django_prometheus.urls')),
    ...
]
```

### Non-web apps (workers, scripts, daemons)

Spin up the metrics server yourself:

```python
from prometheus_client import start_http_server

start_http_server(9000)   # exposes /metrics on :9000
```

Add your own counters/gauges alongside (see `docs/business-metrics.md`).

## 3. Publish the metrics port

Publish whatever port `/metrics` is served on in the service's compose:

```yaml
services:
  scraper:
    ports:
      - "8080:8080"
```

## 4. Register the app with Prometheus

Prometheus picks up Python apps from JSON files in
`prometheus/targets/python/*.json`. Format matches Java:

`prometheus/targets/python/cfp-classifier.json`:
```json
[
  {
    "targets": ["host.docker.internal:8080"],
    "labels": {
      "service": "cfp-scraper",
      "host": "cfp-classifier",
      "environment": "production"
    }
  }
]
```

Prometheus hot-reloads within 30s. Default metrics path is `/metrics` (no
`/actuator` prefix). Custom path: add `"metrics_path": "/internal/metrics"`
to the labels.

**Labels belong on the scrape target, not app-side.** `prometheus_client`
has no Micrometer-style "common tags" concept — trying to attach
`service`/`host`/`environment` to every metric in Python code creates
conflicts with the scrape-time labels. Let Prometheus do it.

## 5. Verify

From the app's host:
```bash
curl http://localhost:<port>/metrics | head -20
```
Should print at least:
- `process_resident_memory_bytes`
- `process_cpu_seconds_total`
- `process_open_fds`
- `python_gc_collections_total`
- (web apps) `http_requests_total`, `http_request_duration_seconds_*`

From the monitoring host:
- `http://<monitor>:9090/targets` — the `python` job shows `UP`.
- Grafana → Dashboards → **Python application** — the Service dropdown
  populates with your target's `service` label.

## Common gotchas

- **All values are zero under gunicorn/uvicorn workers** — `prometheus_client`
  keeps metrics per-process by default. With `--workers N`, each worker has
  its own metrics; the scrape hits whichever worker happens to answer. Fix:
  enable multiprocess mode. Export `PROMETHEUS_MULTIPROC_DIR=/tmp/prom_multiproc`,
  create the directory, and use `multiprocess.mark_process_dead(worker.pid)`
  in your `child_exit` hook. Each instrumentor's docs cover the exact
  wiring. Single-process apps: skip this.
- **`/metrics` returns 404** — for Django, verify you added the middleware
  *and* the URL include. For Flask/FastAPI, verify the instrumentor is
  wired before `app.run`/uvicorn start.
- **Django's default metrics path is `/metrics/`** (trailing slash), not
  `/metrics`. Set `"metrics_path": "/metrics/"` in the target JSON.
