# Changelog

All notable changes to `soldevelo-monitoring` are documented here. Format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning
follows [semver](https://semver.org/).

## [Unreleased]

### Added
- Blackbox: per-target `module` override via a `module` label in the target JSON
  (wires up the behaviour `docs/blackbox-setup.md` already described), and an
  `http_2xx_insecure` module for DNS-independent "is the app up" probes by
  IP / load-balancer DNS (no redirect-follow, no cert-name verify).
- Blackbox alerts `AppDown` (app-direct probe down = the application itself) and
  `PublicUrlUnreachable` (public probe down while the app-direct probe is up =
  DNS/edge issue, not an app outage), keyed on a `check` label. `ProbeFailing`
  now scopes to untagged probes so it doesn't double-fire with these.
- Dashboards: an `environment` template variable (UAT/Prod filter) on the JVM,
  Python, PostgreSQL, Host, Containers, and HTTP-probes dashboards. Defaults to
  All and matches series with or without an `environment` label, so single-
  environment deployments are unaffected.

## [0.4.0] — 2026-07-31

Push-based collection built on Grafana Alloy, with a label taxonomy that lets
one monitoring instance serve many applications and many deployments of the
same application. Proven on two live deployments (docker + AWS EKS).

### Added
- **Alloy push agents.** Each target host/cluster runs one Grafana Alloy agent
  (`agents-alloy/` for docker, in-cluster for Kubernetes) that discovers its
  workloads — docker compose `monitoring.*` labels or k8s `prometheus.io/*`
  annotations — collects host + container + application metrics and all
  container logs, and pushes them to the monitoring host. No target lists on the
  monitor; targets need no inbound ports, only outbound HTTPS.
- **Ingest endpoints.** Prometheus enables `--web.enable-remote-write-receiver`;
  Caddy exposes bearer-gated `/ingest/prometheus/api/v1/write` and
  `/ingest/loki/loki/api/v1/push` on `MONITORING_SITE` (9090 / 3100 stay off the
  public internet). New `INGEST_TOKEN`. Runbooks: `docs/remote-push-setup.md`
  (receiver), `agents-alloy/README.md` (agent).
- **`app` / `deployment` / `service` / `host` / `instance` taxonomy** — a series
  is unique on (`app`, `deployment`, `service`, `instance`), so multiple apps
  and multiple deployments of one app never collide. Dashboards gain an
  `app → deployment → service → instance` variable cascade; Alertmanager labels
  every alert with its `deployment`. Contract in `docs/metrics.md`; all setup
  guides and the README rewritten around the model.

### Changed
- The only Prometheus scrape jobs are Prometheus itself and the blackbox HTTP
  probes; all app / host / container metrics arrive via remote_write. Alert
  rules and dashboards are label-driven and model-agnostic.

## [0.3.0] — 2026-07-07

Preparation release for the OpenLMIS Malawi rollout (second adopter).
Normalizes target configuration across all scrape jobs so multi-host,
multi-environment deployments are first-class instead of a copy-paste
workaround. Adds HTTP RED metrics, HikariCP pool monitoring, PostgreSQL
replication lag, and a Jenkins component — all needed for parity with the
current Malawi CloudWatch + DataSet coverage. Also folds a review-pass
sweep on alert descriptions, dashboard defaults, and setup docs.

### ⚠️ Breaking changes — migration from 0.2.x

**All target configuration now uses file_sd JSON files. The old
env-var-based single-target model is gone.** Affected variables in `.env`:

- Removed (stack side): `TARGET_HOST`, `TARGET_NAME` (still used on the
  agents side — see below), `BLACKBOX_PROBE_TARGETS`.
- Kept (agents side only): `TARGET_NAME`, `TARGET_NODE_EXPORTER_PORT`,
  `TARGET_CADVISOR_PORT`. Agents' Promtail still uses `TARGET_NAME` as the
  `host` label on log streams.

**Migration steps for 0.2.x users:**

1. Delete `TARGET_HOST`, `TARGET_NAME` (stack side), and
   `BLACKBOX_PROBE_TARGETS` from the monitoring host's `.env`.
2. Create paired target files under `prometheus/targets/nodes/` and
   `prometheus/targets/cadvisor/` — one entry per host, using the same
   `host` label you had as `TARGET_NAME`. See `docs/host-setup.md`.
3. Move the URLs from your old `BLACKBOX_PROBE_TARGETS` array into
   `prometheus/targets/blackbox/<project>.json`. See `docs/blackbox-setup.md`.
4. `bin/render-configs.sh && docker compose -f stack/docker-compose.yml up
   -d --force-recreate prometheus`.

Existing `prometheus/targets/java/`, `python/`, `rabbitmq/`, `postgresql/`
files continue to work unchanged.

### Added

- **`nodes/`, `cadvisor/`, `blackbox/`, `jenkins/` target directories** —
  every scrape job now uses the same file_sd pattern. Adding a host, a
  probe URL, or a Jenkins server is a JSON entry, not a base-file edit.
- **HTTP RED metrics for Spring Boot services** — three new alerts
  (`HttpServerErrorRateHigh` at 1% 5xx for 5m, `HttpClientErrorRateHigh`
  at 5% 4xx for 10m, `HttpLatencyP95High` at 2s for 5m). Three new panels
  on the JVM Application dashboard covering request rate by outcome,
  error rate %, and p50/p95/p99 latency. Zero code changes required on
  the app side — Micrometer auto-collects `http_server_requests_seconds`
  once `spring-boot-starter-actuator` + web starter is on the classpath.
- **HikariCP connection pool monitoring** — new `HikariCPPoolExhausted`
  alert on `hikaricp_connections_pending > 0 for 2m` (the definitive
  signal that requests are queuing for a DB connection). Two new panels
  on the JVM Application dashboard: active/idle/max connections and
  pending count. Also auto-collected by Spring Boot Actuator when HikariCP
  is the connection pool (default in modern Spring Boot).
- **PostgreSQL replication lag** — new `PostgreSQLReplicationLag` alert
  (`pg_replication_lag > 900s` for 5m) and dashboard panel with staged
  thresholds. Matches the Malawi Tableau replica-lag alarm shape. Requires
  `postgres_exporter`'s replication collector, pointed at the primary.
- **Jenkins component** — new `jenkins` scrape job, dashboard
  (`grafana/dashboards/jenkins.json`), four alert rules (`JenkinsDown`,
  `JenkinsHealthCheckFailed`, `JenkinsQueueBacklog`,
  `JenkinsExecutorSaturated`), and setup guide (`docs/jenkins-setup.md`)
  covering the Jenkins Prometheus plugin.
- **Two new setup docs**: `docs/host-setup.md` (onboarding a target host
  with paired nodes/cadvisor JSON files) and `docs/blackbox-setup.md`
  (HTTP probe target configuration).

### Changed

- `.env.example` reorganised into explicit "STACK SIDE" and "AGENTS SIDE"
  sections, since the two sides now have meaningfully different variable
  sets after the file_sd normalization.
- **Alert descriptions homogenized to a terse style.** All rule files
  match the pattern in `host_rules.yml`: `summary` is a short label with
  the threshold; `description` is a single factual sentence. Removed
  embedded remediation prose (a future release will add `runbook_url`
  annotations pointing to per-alert runbooks; descriptions no longer need
  to duplicate that content). Affects `jvm_rules.yml`, `postgresql_rules.yml`,
  `container_rules.yml`, `jenkins_rules.yml`, `rabbitmq_rules.yml`,
  `host_rules.yml` (HostOOMKill), and Loki `loki_rules.yaml`.
- **Dashboard default time ranges normalized to `now-3h`.** The four
  dashboards that were on `now-6h` (`alerts.json`, `blackbox.json`,
  `home.json`, `jenkins.json`) now match the rest.
- **Setup docs trimmed.** `docs/java-app-setup.md` and
  `docs/python-app-setup.md` dropped the "optional but recommended"
  digressions and reduced "common gotchas" to the top three per doc.

### Fixed

- **`RabbitMQDown` never fired.** The rule expression was
  `rabbitmq_identity_info == 0`, but when RabbitMQ is unreachable the
  metric is absent rather than zero. Corrected to `up{job="rabbitmq"} == 0`,
  matching `PostgreSQLDown` / `JenkinsDown` / `InstanceDown`.
- **`.env.example` — `TARGET_NAME` comment corrected.** The old comment
  claimed Promtail relabels metric-side `host` labels using `TARGET_NAME`;
  it doesn't. `TARGET_NAME` is only used by Promtail as the `host` label
  on log streams. Metric-side `host` labels come from the target JSON
  files on the monitoring host.

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

[Unreleased]: https://github.com/soldevelo/soldevelo-monitoring/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/soldevelo/soldevelo-monitoring/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/soldevelo/soldevelo-monitoring/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/soldevelo/soldevelo-monitoring/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/soldevelo/soldevelo-monitoring/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/soldevelo/soldevelo-monitoring/releases/tag/v0.1.0
