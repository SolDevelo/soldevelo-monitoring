# Metric catalog

This is the authoritative list of metrics the soldevelo-monitoring package
relies on or expects projects to expose. It is the **contract between
projects**: a metric with the same name on two SolDevelo projects measures
the same thing the same way, with the same labels.

A dashboard or alert that works on Project A should work on Project B without
re-learning vocabulary. That only holds if everyone reads from — and
contributes back to — this file.

## Conventions

### Naming

Names follow [Prometheus naming conventions][prom-naming] and align with
[OpenTelemetry semantic conventions][otel-conv] where the two agree.

- `snake_case`.
- Unit suffix: `_seconds`, `_bytes`, `_ratio`, `_celsius`, `_meters`. No `_ms`, `_kb`, `_pct`.
- `_total` suffix for monotonic counters (e.g. `http_requests_total`).
- No process/container/host name in the metric name — those go in labels.
- Booleans: a gauge with value `0` or `1`, *not* a string-valued label.

[prom-naming]: https://prometheus.io/docs/practices/naming/
[otel-conv]: https://opentelemetry.io/docs/specs/semconv/

### Required labels on application-exposed metrics

Every metric a project exposes from its own code (Micrometer, prom-client,
etc.) must carry these labels:

| Label         | Example                | Meaning                                                |
| ------------- | ---------------------- | ------------------------------------------------------ |
| `service`     | `cfp-classifier-api`   | Short, stable slug for the deployed service.           |
| `host`        | `cfp-classifier-prod`  | The host slug (not IP/DNS). Matches `TARGET_NAME`.     |
| `environment` | `production`           | One of `production`, `staging`, `dev`.                 |

These can be supplied by the application or attached as `external_labels` /
relabeling on the Prometheus side — whichever is more practical for the
project. The dashboards expect them present either way.

### Reserved labels (don't set in app code)

These are populated automatically by Prometheus, the agents, or the package's
configs. Don't override them.

| Label      | Set by                            | Notes                                |
| ---------- | --------------------------------- | ------------------------------------ |
| `instance` | Prometheus                        | `host:port` of the scrape target.    |
| `job`      | Prometheus (scrape config)        | Scrape-job name.                     |
| `monitor`  | `prometheus.yml` external_labels  | Which monitoring instance scraped.   |
| `container`| Promtail / cAdvisor               | Docker container name.               |
| `stream`   | Promtail                          | `stdout` / `stderr` for log lines.   |

### Adding to this catalog

When a project introduces a new metric, add it here in the appropriate
section before merging. Code review checks:

1. Name follows the conventions above.
2. Required labels are present.
3. Both **What it means** and **What it does NOT mean** are filled in.
4. If the metric is project-specific (business metric), it goes under
   *Business metrics — examples*, not under a generic section.

The single most useful field is **"What it does NOT mean"** — that's where
silent semantic drift between projects gets headed off.

---

## Host metrics (node-exporter)

Source: [`prom/node-exporter`][nx]. Exposed on port `9100` on every target
host that runs `agents/docker-compose.yml`.

[nx]: https://github.com/prometheus/node_exporter

### `node_cpu_seconds_total`

- **Type:** counter
- **Unit:** seconds
- **Labels:** `cpu`, `mode` (`idle` / `user` / `system` / `iowait` / `nice` / `irq` / `softirq` / `steal`)
- **Means:** Cumulative CPU time per core, per mode, since boot.
- **Does NOT mean:** instantaneous CPU usage. To compute % busy:
  `100 - (avg by (host) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)`.

### `node_memory_MemAvailable_bytes`

- **Type:** gauge
- **Unit:** bytes
- **Means:** Memory the kernel estimates is available for new allocations
  (free + reclaimable cache/buffers). This is the right number for
  "how full is the box?".
- **Does NOT mean:** `MemFree`. Free memory is misleading on Linux — caches
  count as "used" but are reclaimable. Use `MemAvailable` for alerting.

### `node_memory_MemTotal_bytes`

- **Type:** gauge
- **Unit:** bytes
- **Means:** Total physical RAM visible to the kernel.

### `node_filesystem_avail_bytes`

- **Type:** gauge
- **Unit:** bytes
- **Labels:** `device`, `fstype`, `mountpoint`
- **Means:** Free space on the filesystem, *for non-root users* (reserves
  the typical 5% root-reserved blocks).
- **Does NOT mean:** total free space — use `node_filesystem_free_bytes` if
  you need that. Our alerts intentionally use `avail` because that's the
  space applications actually have.
- **Filter:** `fstype!~"tmpfs|fuse.lxcfs"` to exclude in-memory and
  container-overlay filesystems from disk-usage dashboards.

### `node_filesystem_size_bytes`

- **Type:** gauge
- **Unit:** bytes
- **Labels:** `device`, `fstype`, `mountpoint`
- **Means:** Filesystem total size.

### `node_network_receive_bytes_total` / `node_network_transmit_bytes_total`

- **Type:** counter
- **Unit:** bytes
- **Labels:** `device`
- **Means:** Bytes received / transmitted per network interface since boot.
- **Filter:** `device!~"lo|docker.*|veth.*|br-.*"` to exclude loopback and
  Docker bridge interfaces from "real network" panels.

### `node_load1` / `node_load5` / `node_load15`

- **Type:** gauge
- **Unit:** runnable+uninterruptible tasks (Linux load average)
- **Means:** 1 / 5 / 15-minute load average.
- **Does NOT mean:** "% CPU used". Compare load to core count: load == cores
  means saturated, load > cores means backlog.

### `node_vmstat_oom_kill`

- **Type:** counter
- **Labels:** `host` (no per-process labels — kernel doesn't expose that here)
- **Means:** Total number of kernel-level OOM kills on this host since
  boot. Source: `/proc/vmstat` `oom_kill` field, surfaced by node-exporter's
  vmstat collector.
- **Does NOT mean:** which process or container was killed. To find that,
  cross-reference with `container_oom_events_total` (per container) and
  the `dmesg` / kernel logs (process name and PID).
- **Used for:** the `HostOOMKill` alert. Almost always fires together with
  `ContainerOOMKilled` when the killed process was containerized.

### `node_uname_info`

- **Type:** gauge (always `1`)
- **Labels:** `nodename`, `release`, `sysname`, `machine`, ...
- **Use:** template variables — `label_values(node_uname_info, host)`
  enumerates known hosts.

---

## Container metrics (cAdvisor)

Source: [`gcr.io/cadvisor/cadvisor`][cadv]. Exposed on port `9180` on every
target host that runs `agents/docker-compose.yml`.

[cadv]: https://github.com/google/cadvisor

### `container_last_seen`

- **Type:** gauge
- **Unit:** unix timestamp seconds
- **Labels:** `id`, `image`, `name`, `host` (added by relabel)
- **Means:** Most recent time cAdvisor observed this container.
- **Used for:** `ContainerNotSeen` alert — `time() - container_last_seen > 300`
  means the container has been gone for 5 minutes.
- **Does NOT mean:** the container is still running *right now* if the
  scrape itself failed — combine with `up{job="cadvisor"}` checks.

### `container_cpu_usage_seconds_total`

- **Type:** counter
- **Unit:** seconds (CPU-seconds, aggregated across cores)
- **Labels:** `name`, `id`, `image`, `host`
- **Means:** Total CPU time consumed by the container. Filter `name!=""` to
  drop the synthetic "pod" / "" entries cAdvisor emits.
- **Does NOT mean:** % of host CPU. To get cores-equivalent:
  `rate(container_cpu_usage_seconds_total{name!=""}[5m])` — a value of `1.0`
  means the container is using one full core.

### `container_memory_usage_bytes`

- **Type:** gauge
- **Unit:** bytes
- **Labels:** `name`, `id`, `image`, `host`
- **Means:** Container's current resident memory (RSS + cache).
- **Does NOT mean:** "how much can be reclaimed under pressure" —
  page cache included in this number can usually be evicted.

### `container_spec_memory_limit_bytes`

- **Type:** gauge
- **Unit:** bytes
- **Labels:** `name`, `id`, `image`, `host`
- **Means:** The container's configured memory limit. **Zero** means no
  limit was set — always filter `> 0` before dividing by it, or you'll
  silently get NaN/+Inf in panels.

### `container_oom_events_total`

- **Type:** counter
- **Labels:** `name`, `id`, `image`, `host`
- **Means:** Number of OOM-kill events the kernel performed inside this
  container's cgroup. Increments when the kernel kills a process because
  the *container* hit its memory limit.
- **Does NOT mean:** that the host ran out of memory — that's
  `node_vmstat_oom_kill`. A container OOM kill can happen even on a host
  with plenty of free RAM, if the container's own memory limit (compose
  `mem_limit` / cgroup `memory.max`) was exceeded.
- **Used for:** the `ContainerOOMKilled` alert (fires on
  `increase(...[5m]) > 0`). This is the right early-warning for "this
  JVM is consistently blowing through its container budget."

### `container_network_receive_bytes_total` / `container_network_transmit_bytes_total`

- **Type:** counter
- **Unit:** bytes
- **Labels:** `name`, `id`, `image`, `host`, `interface`
- **Means:** Bytes received / transmitted at the container's network
  interface(s) since the container started. Use `rate(...)` for a per-second
  view; `sum by (name)` collapses multiple interfaces inside one container
  to a single series.
- **Does NOT mean:** the same thing as `node_network_*_bytes_total`. Node
  metrics count traffic on the host's NICs, *including* Docker bridge
  internals; cAdvisor's container metrics count what a specific container
  sent or received, before Docker's NAT layer. For "what is this container
  doing on the network", use these, not the node metric.

---

## Probe metrics (Blackbox exporter)

Source: [`prom/blackbox-exporter`][bb]. Runs on the monitoring host. URLs to
probe are listed in `.env` (`BLACKBOX_PROBE_TARGETS`).

[bb]: https://github.com/prometheus/blackbox_exporter

### `probe_success`

- **Type:** gauge (0 or 1)
- **Labels:** `instance` (the probed URL)
- **Means:** `1` if the most recent probe succeeded (configured status code,
  no timeout, no DNS failure), `0` otherwise.
- **Does NOT mean:** the *service* is healthy — only that the prober could
  open a connection and get an expected response. A 200-OK from a stale
  cached error page will still read as `1`.

### `probe_duration_seconds`

- **Type:** gauge
- **Unit:** seconds
- **Labels:** `instance`
- **Means:** Total time for the most recent probe (DNS + connect + TLS + transfer).
- **Does NOT mean:** real-user latency. Probes come from one fixed location
  (the monitoring host); they say nothing about latency from end-user
  networks.

### `probe_ssl_earliest_cert_expiry`

- **Type:** gauge
- **Unit:** unix timestamp seconds
- **Labels:** `instance`
- **Means:** Expiry time of the earliest-to-expire certificate in the chain.
- **Use:** `(probe_ssl_earliest_cert_expiry - time()) / 86400` → days until expiry.

---

## Internal Prometheus metrics

### `up`

- **Type:** gauge (0 or 1)
- **Labels:** `instance`, `job` (whatever the scrape config defines)
- **Means:** `1` if Prometheus last scraped this target successfully.
- **Use:** generic liveness alerts (e.g. `up{job="node"} == 0` → InstanceDown).
- **Does NOT mean:** the service is processing real requests — only that
  it accepted the scrape connection and responded.

---

## Log labels (Loki / Promtail)

Loki streams aren't "metrics," but their labels follow the same conventions
because log-derived rules and dashboards depend on them.

| Label       | Set by                 | Example                          |
| ----------- | ---------------------- | -------------------------------- |
| `host`      | Promtail relabel       | `cfp-classifier-prod`            |
| `container` | Promtail (docker_sd)   | `classifier-api`                 |
| `stream`    | Promtail (docker_sd)   | `stdout` / `stderr`              |
| `job`       | Promtail scrape config | `docker` / `varlogs`             |

Application logs SHOULD be emitted as **JSON, one object per line**, with at
minimum these fields:

| Field         | Required | Example                                 |
| ------------- | -------- | --------------------------------------- |
| `level`       | yes      | `INFO` / `WARN` / `ERROR`               |
| `service`     | yes      | `cfp-classifier-api`                    |
| `message`     | yes      | `"failed to classify document"`         |
| `timestamp`   | yes      | RFC3339 with timezone                   |
| `request_id`  | when applicable | `9f3e...` (per-request correlation) |
| `trace_id`    | when applicable | OpenTelemetry trace id           |
| `user_id`     | when applicable | (avoid PII; use opaque id)       |

JSON log encoding is a project responsibility (e.g. logback-json for Spring
Boot, `python-json-logger` for Python). Promtail does not transform plain
text into JSON — what your app emits is what queries will see.

---

## Application metrics (RED) — V1 placeholder

Services that handle requests are expected to expose the **RED triad**:

- `http_requests_total` — counter, labels `service`, `method`, `route`, `status`
- `http_request_duration_seconds` — histogram, labels `service`, `method`, `route`
- `http_requests_in_flight` — gauge, labels `service`

Full specifications and required histogram buckets land in V1 alongside
the Java-app dashboard. Until then, this section is a placeholder so that
when a project starts emitting RED metrics, they land under names already
chosen here — not whatever the framework's default happens to be.

---

## JVM metrics (Spring Boot Actuator + Micrometer)

Exposed on `/actuator/prometheus` once the application enables
`spring-boot-starter-actuator` + `micrometer-registry-prometheus`. Setup
walkthrough: [`docs/java-app-setup.md`](java-app-setup.md).

Required app-side labels per the conventions above (`service`, `host`,
`environment`) — these can be supplied by Micrometer common tags or attached
on the Prometheus scrape side via the scrape job's labels.

### `jvm_memory_used_bytes`

- **Type:** gauge
- **Unit:** bytes
- **Labels:** `service`, `host`, `area` (`heap` / `nonheap`), `id` (pool name)
- **Means:** Bytes currently used in each JVM memory pool. Aggregate by
  `area=heap` for total heap usage; per-pool view shows which generation is
  filling (G1 Old Gen, Eden, Survivor, Metaspace, Compressed Class Space).
- **Does NOT mean:** committed or reserved memory — those are
  `jvm_memory_committed_bytes` and reflect what's been requested from the OS,
  which may be larger than what's actually used.

### `jvm_memory_max_bytes`

- **Type:** gauge
- **Unit:** bytes
- **Labels:** `service`, `host`, `area`, `id`
- **Means:** Maximum bytes the pool is allowed to grow to. Filter `> 0`
  before dividing — some unbounded pools (e.g. Compressed Class Space)
  report `-1`, which produces nonsensical ratios.

### `jvm_gc_pause_seconds_sum` / `jvm_gc_pause_seconds_count` / `jvm_gc_pause_seconds_bucket`

- **Type:** histogram (three companion series per Prometheus convention)
- **Unit:** seconds
- **Labels:** `service`, `host`, `action` (e.g. `end of minor GC`,
  `end of major GC`), `cause` (e.g. `G1 Evacuation Pause`)
- **Means:** GC pause-time distribution. Use `rate(...sum[5m])` for "seconds
  of GC pause per second of wall time" (the `JvmGCThrashing` alert input);
  `rate(...sum) / rate(...count)` for average pause duration.
- **Does NOT mean:** GC frequency alone is benign — many small pauses can be
  healthier than rare long ones. Read pause time as the percentage of wall
  clock the JVM was stopped, not as "how often does GC happen."

### `jvm_threads_live_threads`

- **Type:** gauge
- **Labels:** `service`, `host`
- **Means:** Live (daemon + non-daemon) threads at scrape time. Should
  stabilise after warmup.
- **Does NOT mean:** active/running threads — many are blocked / waiting.
  For state-level breakdown, use `jvm_threads_states_threads{state=...}`.

### `jvm_threads_states_threads`

- **Type:** gauge
- **Labels:** `service`, `host`, `state` (`RUNNABLE`, `BLOCKED`, `WAITING`,
  `TIMED_WAITING`, `NEW`, `TERMINATED`)
- **Means:** Thread count per Thread.State enum value. Sustained high
  `BLOCKED` is a contention smell; sustained high `WAITING` for many threads
  is often pool starvation.

### `process_cpu_usage`

- **Type:** gauge (0.0–1.0)
- **Labels:** `service`, `host`
- **Means:** Recent CPU usage fraction for the JVM process, as reported by
  the OS bean. `1.0` = one fully busy core.
- **Does NOT mean:** % of host CPU when there are multiple cores —
  Spring Boot's value is a fraction of one core, not normalised across cores.
  For "what slice of the host CPU am I taking", use cAdvisor's
  `container_cpu_usage_seconds_total` per container.

---

## Business metrics — examples (not a contract)

Business metrics are project-specific and inherently *cannot* be standardised
across projects the way RED or JVM metrics can — a "document classified" on
CFP Classifier and an "RFP scraped" on RFPMonitor are not the same thing.

What IS standardised:

- **Naming conventions** (same as above — `snake_case`, unit suffix, `_total`).
- **Required labels** (`service`, `host`, `environment` — see above).
- **Documentation discipline** — every business metric a project emits gets
  an entry in *that project's* `monitoring/metrics.md`, with the same
  Means / Does NOT mean structure.

Examples (illustrative, not prescriptive):

- `cfp_documents_classified_total` — counter, labels `service`, `host`, `environment`, `classifier_version`, `result`.
- `cfp_scrape_bytes_total` — counter, labels `service`, `host`, `environment`, `source`.
- `cfp_queue_depth` — gauge, labels `service`, `host`, `environment`, `queue`.

A V3 cookbook will collect these patterns across projects and pull common
shapes back into this catalog.
