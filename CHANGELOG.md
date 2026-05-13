# Changelog

All notable changes to `soldevelo-monitoring` are documented here. Format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning
follows [semver](https://semver.org/).

## [Unreleased]

## [0.1.0] — 2026-05-13

First release. Internal SolDevelo use; pre-public.

### Stack

- Pre-baked monitoring host compose: Prometheus + Prometheus-meta + Loki +
  Grafana + Alertmanager + Blackbox + monitor's own node-exporter + cAdvisor.
- Pre-baked agents compose for target hosts: node-exporter + cAdvisor +
  Promtail (with Docker service discovery).
- `host.docker.internal:host-gateway` alias on Prometheus / Blackbox /
  Promtail for local-on-one-machine testing on Linux.
- `network_mode: host` on both node-exporters so the netdev / netclass
  collectors see real host interfaces, not the container's own netns.
- Promtail drops `/soldevelo-monitoring-*` containers from log scraping to
  avoid feedback loops between log-based alert rules and the ruler's own
  logs.

### Dashboards (provisioned-as-code)

- **SolDevelo Monitoring** (home) — alert counts, dashboard list, currently
  firing table. Set as the default landing page; replaces Grafana's "Welcome"
  screen.
- **Host overview** — CPU, memory, disk, per-NIC network (real interfaces
  only), load average.
- **Containers** — per-container CPU / memory / network with stacking,
  totals across the host, live Loki log panel filtered by host + container.
- **HTTP probes** — probe success, latency, SSL cert days remaining.
- **JVM application** — heap %, GC overhead, GC pause times, per-pool memory,
  threads by state, process CPU. Multi-service via variable picker.
- **Active alerts** — currently-firing and pending alerts with severity
  colour-coding and stat counts.

### Alerts (Slack-routed via Alertmanager)

- Host: `InstanceDown`, `HighCPU`, `HighMemoryUsage`, `LowDiskSpace`,
  `HostOOMKill`.
- Container: `ContainerNotSeen`, `ContainerHighMemoryVsLimit`,
  `ContainerOOMKilled`, `ContainerRestartLoop`.
- HTTP probes: `ProbeFailing`, `ProbeSlow`, `SSLCertExpiringSoon`.
- JVM: `JvmHeapPressure`, `JvmGCThrashing`, `JvmMetaspacePressure`,
  `JvmThreadGrowth`, `JvmScrapeDown`.
- Logs (Loki): `ErrorLogsSpike`, `JvmOutOfMemoryError`, `JvmGCOverheadLimit`,
  `JvmStackOverflowError`, `JvmFatalSignal`.
- Self-monitoring (via prometheus-meta): `MonitorDiskLow`,
  `PrometheusUnreachable`, `LokiUnreachable`, `AlertmanagerUnreachable`.

### Java application support

- Prometheus scrape job for Spring Boot Actuator + Micrometer
  (`/actuator/prometheus`).
- File-based service discovery (`prometheus/targets/java/*.json`) for
  multi-app deployments. Hot-reloaded every 30 s by Prometheus — no restart
  needed when adding or removing apps.
- Setup walkthrough in `docs/java-app-setup.md` including:
  - Dependencies, configuration, port publishing.
  - `-Xmx` vs container `mem_limit` alignment (recommends
    `-XX:MaxRAMPercentage=75.0`).
  - JVM launch flags for `OutOfMemoryError` forensics
    (`-XX:+HeapDumpOnOutOfMemoryError`, `-XX:+ExitOnOutOfMemoryError`).
  - Diagnostic ladder for "target is DOWN" (Spring Security 401,
    `localhost` bind address, JSON syntax, custom paths).

### Documentation

- `README.md` — architecture, quickstart, conventions, roadmap, versioning.
- `docs/metrics.md` — canonical metric catalog with required labels and the
  "what it does NOT mean" pattern. Covers node-exporter (host),
  cAdvisor (container, including OOM and network), Blackbox, JVM
  (Micrometer), and Loki log labels.
- `docs/java-app-setup.md` — Spring Boot onboarding.
- `CHANGELOG.md` — this file.

### License

- **MIT** — see `LICENSE`. Copyright © 2026 SolDevelo.

### Reverse proxy

- **Caddy** included in the stack as TLS terminator and reverse proxy in
  front of Grafana. One `MONITORING_SITE` env var controls behaviour:
  - `http://localhost` → plain HTTP, no TLS (local default).
  - `localhost` → Caddy's internal CA, self-signed TLS.
  - Real domain → free Let's Encrypt cert, auto-renewed.
- Same Caddyfile works on a laptop and on a public EC2; the only change
  between environments is the `MONITORING_SITE` value.

### Branding

- Grafana browser tab title set to "SolDevelo Monitoring" via
  `GF_DEFAULT_INSTANCE_NAME`.
- Default home dashboard set to the SolDevelo Monitoring landing page via
  `GF_USERS_DEFAULT_HOME_DASHBOARD_UID`.

### Conventions

- All scrape targets carry `host` (host slug) and where applicable
  `service` + `environment` labels.
- Metric names follow Prometheus + OpenTelemetry naming conventions:
  `snake_case`, unit suffix, `_total` for counters.
- JVM metrics labelled by `service` (Micrometer common tag) so dashboards
  port between Java services without query rewrites.
- Log-pattern alerts use FQCN (`java.lang.OutOfMemoryError`) rather than
  bare class names, to avoid recursive matching on the ruler's own logs.

### Known limitations

- No CI yet — config validation (`docker compose config`,
  `promtool check rules`) is manual.
- No Terraform module — manual VM provisioning. Planned for V2.
- Single `TARGET_HOST` in `.env`. Multi-target-host support comes when a
  second adopter (OpenLMIS Malawi) lands; will follow the same file_sd
  pattern as Java multi-app.
- Spring Boot HTTP RED dashboard (`http_server_requests_seconds`) deferred
  to a later 0.x release.
- Caddy fronts Grafana only; Prometheus and Alertmanager remain on direct
  ports without auth. Production deployments should firewall those off the
  public internet (or extend the Caddyfile with basic auth + sub-paths in a
  later release).

[Unreleased]: https://github.com/soldevelo/soldevelo-monitoring/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/soldevelo/soldevelo-monitoring/releases/tag/v0.1.0
