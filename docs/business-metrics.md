# Business metrics — conventions & how to add them

Business metrics are project-specific counters and gauges that measure what
your *product* is doing, not what its infrastructure is doing. Examples:

- `scraper_pages_scanned_total` — how many web pages the scraper has processed
- `classifier_documents_classified_total{result="approved|rejected"}` — classification outcomes
- `payments_processed_total{status="success|failed"}` — payment throughput
- `queue_depth{queue="incoming"}` — a business-relevant queue size, not just RabbitMQ's internal one

These sit *alongside* the system metrics the package already collects
(`jvm_memory_used_bytes`, `container_cpu_usage_seconds_total`, etc.) and are
displayed as their own section on the service dashboards.

**Rule of thumb:** if the value would appear in a business review meeting
(pages/day, transactions/hour, error rate on this specific workflow), it's a
business metric. If it would only appear in an engineering incident review
(heap usage, CPU %), it's a system metric.

## Naming convention

Follow Prometheus + OpenTelemetry naming (same as everything else in
`docs/metrics.md`):

- `snake_case` throughout.
- **Prefix with the service slug** — e.g. `scraper_`, `classifier_`. Keeps
  business metrics unambiguous across projects and makes them easy to filter
  in dashboards (`{__name__=~"$service_.*"}`).
- **Unit suffix** if the metric has a unit: `_seconds`, `_bytes`,
  `_meters`. No `_ms`, `_kb`, `_pct`.
- **`_total` suffix for counters** (monotonically increasing values). E.g.
  `scraper_pages_scanned_total`, not `scraper_pages_scanned`.
- **No suffix for gauges** (values that can go up and down). E.g.
  `scraper_queue_depth`, `worker_active_jobs`.
- Don't put dimensions in the metric name — put them in labels. Bad:
  `scraper_pages_scanned_from_source1_total`. Good:
  `scraper_pages_scanned_total{source="source1"}`.

## Required labels

Every business metric must carry the same required labels as any application
metric (see `docs/metrics.md`):

| Label | Example | Notes |
|---|---|---|
| `service` | `cfp-scraper` | Short stable service slug. |
| `host` | `cfp-classifier-prod` | Host slug (not IP). Usually attached by the Prometheus scrape config. |
| `environment` | `production` | `production` / `staging` / `dev`. |

Plus whatever dimensional labels the metric itself needs (e.g. `source`,
`result`, `queue`). Keep dimensional label cardinality bounded — a label
whose value is unbounded (user IDs, request IDs, timestamps) will blow up
your storage cost.

## How to expose them (per language)

### Java (Micrometer)

Micrometer is already in your dependency graph if you followed
`docs/java-app-setup.md`. Add metric definitions in code:

```java
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Gauge;

@Component
public class ScraperMetrics {
    private final Counter pagesScanned;
    private final AtomicInteger queueDepth = new AtomicInteger(0);

    public ScraperMetrics(MeterRegistry registry) {
        this.pagesScanned = Counter.builder("scraper_pages_scanned_total")
            .description("Total pages the scraper has processed")
            .tag("source", "web")   // dimensional label
            .register(registry);

        Gauge.builder("scraper_queue_depth", queueDepth, AtomicInteger::get)
            .description("Current internal work queue depth")
            .register(registry);
    }

    public void onPageScanned() {
        pagesScanned.increment();
    }
}
```

`service` / `host` / `environment` come from Micrometer's common tags — set
them once via `application.properties` (see `docs/java-app-setup.md`), and
every metric inherits them automatically. Don't repeat them per-metric.

### Python (prometheus_client)

Once `docs/python-app-setup.md` is wired up:

```python
from prometheus_client import Counter, Gauge

pages_scanned = Counter(
    "scraper_pages_scanned_total",
    "Total pages the scraper has processed",
    ["source"],   # dimensional label
)
queue_depth = Gauge(
    "scraper_queue_depth",
    "Current internal work queue depth",
)

# In code:
pages_scanned.labels(source="web").inc()
queue_depth.set(len(current_queue))
```

`service` / `host` / `environment` are attached at scrape time (from the
target file's labels — see the Python setup doc). Don't add them at the app
level; you'd create conflicts.

## Where they live (documentation)

Business metrics are **project-specific** — the base package's
`docs/metrics.md` covers *system* metrics only (host, container, JVM, log
label conventions). Per-project business metrics get documented **in the
project's own overlay**, using the same "Name / Type / Labels / Means / Does
NOT mean" pattern.

Suggested layout in a project overlay:

```
<project-repo>/
├── monitoring/
│   ├── targets/
│   │   ├── java/<project>.json      # scrape targets
│   │   └── python/<project>.json
│   └── metrics.md                   # project-specific business metrics
```

The project's `metrics.md` is what a new engineer joining the project reads
to understand what the app measures and why. Same discipline as the base
package's catalog: every metric gets an entry, every entry has "does NOT
mean" so semantics don't drift.

## Where they appear on dashboards

Business metrics with the correct naming convention (prefixed by the service
slug) are picked up automatically by the service dashboard's "Business
metrics" section, which queries `{__name__=~"^${service}_.*"}` (filtered to
exclude the `_total` companions of histograms, etc.).

If you want a curated view, create a dashboard in the project overlay
(`<project>/monitoring/dashboards/<project>-business.json`) and drop it into
`grafana/dashboards/` on the monitoring host. It'll be provisioned
automatically like any other dashboard.

## Anti-patterns worth avoiding

- **Unbounded-cardinality labels.** Never label with user ID, request ID,
  timestamp, or anything else with millions of possible values. Prometheus
  will store one time series per unique label combination — cardinality is
  what blows storage up. Bound labels to <100 possible values as a
  rule of thumb.
- **Metric names that describe the dashboard, not the measurement.** Bad:
  `scraper_data_for_hourly_chart`. Good: `scraper_pages_scanned_total` (the
  chart is a consumer, not the definition).
- **Adding metrics that duplicate what's already collected.** Don't emit
  `scraper_memory_used_bytes` from the app — cAdvisor already reports this
  at the container level and the JVM's `jvm_memory_used_bytes` reports it at
  the runtime level. Emit only what only *your app* knows.
- **Emitting `service` / `host` / `environment` from the app when the scrape
  config already sets them.** You'll create label-mismatch errors or, worse,
  silent duplicates.
- **One giant "everything" counter.** If you find yourself writing
  `scraper_events_total{event_type="page_scanned|error|complete|...")` with a
  dozen event types, split into named metrics. Labels are for *bounded
  dimensions of one concept*, not for encoding what would be separate metrics.

## Checklist when adding a new business metric

Before merging:

- [ ] Name follows convention (service prefix, snake_case, unit suffix, `_total` for counters).
- [ ] Required labels (`service`, `host`, `environment`) are attached — via app common-tags or scrape-time labels, not per-metric.
- [ ] Dimensional labels have bounded cardinality.
- [ ] Entry in the project's `metrics.md` with name, type, labels, meaning, and "does NOT mean".
- [ ] Not duplicating something the package already collects (container, JVM, HTTP RED metrics).
