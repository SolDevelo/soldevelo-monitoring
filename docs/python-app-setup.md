# Wiring a Python app into soldevelo-monitoring

Python's runtime is rarely the bottleneck the way JVM heap can be, so a
Python service dashboard is less about the language and more about the
application: process resource use + HTTP RED metrics (if it's a web app) +
your business metrics. Total wiring work: one dependency, a few lines of
setup, one JSON file, and (for a web app) a framework-specific instrumentor.
~15 minutes.

## 1. Dependency

Add `prometheus_client` to your project:

```
prometheus-client>=0.20
```

That's the base library. Everything else below is optional but recommended
depending on your app shape.

## 2. Expose `/metrics`

The cleanest pattern depends on how your app runs:

### Web frameworks (Flask / FastAPI / Django) — recommended: use the framework instrumentor

Each has a small library that both exposes `/metrics` **and** auto-instruments
HTTP requests. You get the endpoint + RED metrics (`http_requests_total`,
`http_request_duration_seconds_*`) in one dependency:

**Flask:**
```
pip install prometheus-flask-exporter
```
```python
from flask import Flask
from prometheus_flask_exporter import PrometheusMetrics

app = Flask(__name__)
metrics = PrometheusMetrics(app)
# /metrics is now live
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
# /metrics is now live
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
    path('', include('django_prometheus.urls')),  # /metrics lives here
    ...
]
```

### Non-web apps (workers, scripts, daemons) — start_http_server

For a long-running script or worker, spin up the metrics server yourself:

```python
from prometheus_client import start_http_server

start_http_server(9000)   # exposes /metrics on :9000
# ... rest of your app
```

Add your own counters/gauges alongside (see `docs/business-metrics.md`).

## 3. Publish the metrics port

Whichever port you exposed (Flask/FastAPI's app port, Django's app port, or
your explicit `start_http_server` port), publish it in the service's
docker-compose so the monitoring host can reach it:

```yaml
services:
  scraper:
    # ...existing config...
    ports:
      - "8080:8080"  # or wherever /metrics lives
```

## 4. Register the app with Prometheus

Prometheus picks up Python apps from JSON files in
`prometheus/targets/python/*.json`. Format is identical to the Java one:

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

Prometheus hot-reloads within 30 seconds. Default metrics path is `/metrics`
(no `/actuator` prefix like Java). To use a custom path, add
`"metrics_path": "/internal/metrics"` to the labels — the scrape config
picks it up the same way it does for Java.

## 5. Recommended (production-grade)

### `service` / `host` / `environment` labels

These belong on the *scrape target* (the JSON above), not attached inside
your Python code. `prometheus_client` doesn't have a Micrometer-style
"common tags" concept — attaching labels app-side to every metric is
brittle and creates conflicts with scrape-time labels. Let Prometheus do it.

### Multiprocess mode (if using gunicorn / uvicorn workers)

**Critical gotcha:** `prometheus_client` by default keeps metrics in the
current process only. With `gunicorn --workers 4` or `uvicorn --workers 4`,
each worker has its own metrics and you'll see numbers that change
depending on which worker Prometheus happens to hit on scrape.

Enable multiprocess mode:

```bash
export PROMETHEUS_MULTIPROC_DIR=/tmp/prom_multiproc
mkdir -p $PROMETHEUS_MULTIPROC_DIR
```

```python
# In your app, use the multiproc collector:
from prometheus_client import multiprocess, CollectorRegistry

def child_exit(server, worker):
    multiprocess.mark_process_dead(worker.pid)

# Wire this into gunicorn config or uvicorn hooks.
# For Flask + prometheus-flask-exporter, set multiproc dir env var and it works.
# For FastAPI, see prometheus-fastapi-instrumentator's multiproc docs.
```

The relevant instrumentation libraries all support it — check each one's
docs for the exact wiring. If you're running a single-process app, ignore
this section.

### JVM launch-flag analogue: writing dumps on death

Python doesn't need `-XX:+HeapDumpOnOutOfMemoryError`. But for
production-grade debugging, consider:

- Structured logging (JSON to stdout) — makes Loki much more useful.
- Sentry / equivalent for uncaught exceptions.
- Container-level restart policy in Compose (`restart: unless-stopped`) — so
  a crash doesn't leave the service dead.

## 6. Verify

From the app's host:
```bash
curl http://localhost:<port>/metrics | head -20
```
Should print Prometheus-format metrics, including at minimum:
- `process_resident_memory_bytes`
- `process_cpu_seconds_total`
- `process_open_fds`
- `python_gc_collections_total`
- (if web app) `http_requests_total`, `http_request_duration_seconds_*`

From the monitoring host:
- `http://<monitor>:9090/targets` — the `python` job should show `UP`.
- Grafana → Dashboards → **Python application** — the Service dropdown
  populates with the value you set in the target file's `service` label.

## Common gotchas

- **`/metrics` returns 404.** For Django, verify you added the middleware
  *and* the URL include. For Flask/FastAPI, verify the instrumentor is
  wired before `app.run`/uvicorn start.
- **All values are zero.** Almost always multiprocess mode not enabled — one
  worker has the metric incremented, the scrape hits a different worker,
  you see zero. Fix per section 5.
- **Metric labels multiply strangely.** Cardinality explosion. Usually
  because you labelled with something unbounded (request ID, user ID,
  timestamp). Cap dimensional label values.
- **Numbers look right in curl but wrong on the dashboard.** Check the
  scrape target labels — if `service` isn't set correctly on the target,
  the dashboard's Service picker won't find your app.
- **Django's default metrics path is `/metrics/`** (trailing slash) rather
  than `/metrics`. Set `"metrics_path": "/metrics/"` in the target JSON.
- **Async apps.** FastAPI/Starlette/asyncio workflows generally work fine
  with `prometheus_client` since the library uses the C-level GIL. Doesn't
  need special async awareness for basic counters/gauges/histograms.
