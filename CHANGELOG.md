# Changelog

All notable changes to `soldevelo-monitoring` are documented here. Format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning
follows [semver](https://semver.org/).

## [Unreleased]

## [0.2.0] — 2026-06-11

First feedback-driven release, informed by real production use of `0.1.x`
against an internal SolDevelo tool. The package caught a real memory leak
(which was fixed), and running with real workloads surfaced concrete
usability gaps and new coverage needs. This release addresses them.

### Added

- **Python application dashboard + setup guide.** New `python` scrape job
  (file_sd via `prometheus/targets/python/*.json`), dashboard
  (`grafana/dashboards/python.json`) covering process memory / CPU / FDs /
  GC + optional HTTP RED panels + business-metrics section + logs. Full
  onboarding walkthrough in `docs/python-app-setup.md` including framework
  instrumentors (Flask / FastAPI / Django), multiproc-mode gotcha, and
  target-file examples.
- **RabbitMQ component** — new `rabbitmq` scrape job (file_sd via
  `prometheus/targets/rabbitmq/*.json`), dashboard (`rabbitmq.json`),
  alert rules (`rabbitmq_rules.yml`: `RabbitMQDown`, `RabbitMQNoConsumers`,
  `RabbitMQQueueBacklog`, `RabbitMQDiskLow`). Setup guide in
  `docs/rabbitmq-setup.md` covers the RabbitMQ 3.8+ built-in Prometheus
  plugin (no sidecar exporter needed).
- **PostgreSQL component** — new `postgresql` scrape job (file_sd),
  dashboard, alert rules (`postgresql_rules.yml`: `PostgreSQLDown`,
  `PostgreSQLTooManyConnections`, `PostgreSQLLowCacheHitRatio`,
  `PostgreSQLDeadlocks`). Setup guide in `docs/postgresql-setup.md` covers
  `postgres_exporter` deployment with `pg_monitor` role.
- **Logs panel on JVM Application dashboard.** New container-picker
  template variable that lists containers whose name matches the selected
  service. Kills the "keep switching between Containers and JVM dashboards"
  papercut that came up in first-project use.
- **Business-metrics convention doc** (`docs/business-metrics.md`) — naming
  rules, required labels, per-language exposure examples (Micrometer +
  prometheus_client), where they live per-project vs in the base package,
  and dashboard integration. Fills the last of the five deliverables named
  in `IDEAS.md`.

### Changed

- **`ContainerHighMemoryVsLimit` alarm — `for:` extended from 5m to 15m.**
  Was flapping when memory oscillated around the 90% threshold — firing,
  resolving, and re-firing every ~10 min. Longer window means the alarm
  only fires on sustained pressure, not on brief crossings. Fix per the
  "flapping is a rule-tuning problem, not an alerting-system problem"
  principle — no exotic backoff logic needed.

### Package structure

- Component pattern established: each stack component (RabbitMQ, PostgreSQL;
  future: Redis, Nginx, Kafka, etc.) contributes a file_sd targets dir, a
  scrape job in `prometheus.yml.template`, a dashboard, a rules file, and a
  setup doc. Consistent structure makes adding the next component a
  copy-paste operation rather than bespoke design.

## [0.1.1] — 2026-05-14

Post-`0.1.0`-first-deployment compatibility fixes — surfaced by deploying
the package to a real Ubuntu 22.04 EC2 and informed by the diagnostic
ladder that became part of the package itself.

### Fixed

- **Restrictive-umask compatibility** (e.g. CIS-benchmarked Ubuntu / RHEL
  with `umask 027`). `bin/render-configs.sh` now forces `umask 022` at the
  start (so rendered files are 644) and runs `chmod -R a+rX` on config
  directories at the end (so directories created by `git clone` under the
  restrictive umask become 755 instead of 750). Container processes running
  as `nobody` (uid 65534) or `grafana` (uid 472) can then read the
  bind-mounted configs, which they couldn't with the previous 640 / 750
  modes. Idempotent on every render.
- **SELinux compatibility** on Amazon Linux 2023 / RHEL / Fedora hosts. All
  bind-mounted config files in `stack/docker-compose.yml` and
  `agents/docker-compose.yml` now use `:ro,z`, which tells Docker to relabel
  the file to the shared container context. Without this, SELinux-enforcing
  hosts deny container processes access to bind-mounted configs with a
  generic `permission denied` even though Linux file permissions look
  correct. No-op on Ubuntu/Debian (no SELinux), required on RHEL-family.

### Docs

- README prerequisites clarified that Docker Compose v2 (the `docker compose`
  Go plugin) is required, not the legacy v1 `docker-compose` Python tool
  (EOL 2023). Includes install commands for apt and dnf families.

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

[Unreleased]: https://github.com/soldevelo/soldevelo-monitoring/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/soldevelo/soldevelo-monitoring/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/soldevelo/soldevelo-monitoring/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/soldevelo/soldevelo-monitoring/releases/tag/v0.1.0
