# soldevelo-monitoring

Opinionated, OSS-based monitoring package for SolDevelo projects. Pre-baked
stack (Prometheus + Loki + Grafana + Alertmanager + Blackbox), pre-baked
dashboards-as-code, pre-baked alerts wired to Slack, and a documented metric
catalog so the same names mean the same things across projects. Deployable on
any Linux host with Docker.

**Version:** `0.3.0`. See [`CHANGELOG.md`](CHANGELOG.md).

## What's in the box

```
                       ┌─────────────────────────────────────────┐
                       │       Monitoring host (one VM)          │
                       │                                         │
  metrics scrape  ┌─── │  Prometheus ─► Alertmanager ─► Slack    │
  ◄──────────────┐│    │      ▲              ▲                   │
                 ││    │      └──── Blackbox (HTTP probes)       │
  Loki push      ││    │                                         │
  ◄──────────────┼┘    │      Grafana (provisioned dashboards)   │
                 │     │         ▲                               │
  /actuator/     │     │      Loki ◄── (logs)                    │
  prometheus   ◄─┤     │                                         │
                 │     │      + Prometheus-meta (self-monitor)   │
                 │     └─────────────────────────────────────────┘
                 │
       ┌─────────┴────────────────────────────────────┐
       │  Target host(s)                               │
       │   node-exporter | cAdvisor | Promtail         │
       │   + your services (Java apps emit Micrometer) │
       └───────────────────────────────────────────────┘
```

- **stack/** — runs on the monitoring host (Prom + Prom-meta + Loki + Grafana
  + Alertmanager + Blackbox + monitor's own node-exporter + cAdvisor).
- **agents/** — runs on each target host (node-exporter + cAdvisor + Promtail
  with Docker service discovery).
- **prometheus/**, **loki/**, **alertmanager/**, **blackbox/**, **grafana/** —
  configs (templates rendered from `.env` plus committed rule files).
- **bin/render-configs.sh** — envsubst `*.template` files using `.env` values.
- **docs/** — `metrics.md` (catalog and conventions), `host-setup.md`,
  `blackbox-setup.md`, `java-app-setup.md`, `python-app-setup.md`,
  `business-metrics.md`, `rabbitmq-setup.md`, `postgresql-setup.md`,
  `jenkins-setup.md`.

### Dashboards (ten, all provisioned-as-code)

- **SolDevelo Monitoring** (home) — alert counts, dashboard list, quick links.
- **Host overview** — CPU, memory, disk, per-NIC network, load.
- **Containers** — per-container CPU / memory / network with stacking,
  totals, and a live log stream filtered by host + container.
- **HTTP probes** — Blackbox probe status, latency, SSL cert days remaining.
- **JVM application** — Spring Boot / Micrometer metrics: heap %, GC overhead,
  pauses, per-pool memory, thread states, process CPU, HTTP RED (rate /
  errors / latency), HikariCP connection pool, logs for the service's
  container. Multi-service via variable picker.
- **Python application** — process memory / CPU / FDs, GC, optional HTTP
  RED, business-metrics section, logs.
- **RabbitMQ** — node health, per-queue depth, publish/deliver rates,
  consumers, unacked messages, broker memory / disk.
- **PostgreSQL** — up/down, connection utilization, cache hit ratio,
  commit/rollback rate, deadlocks, DB size, tuple ops, replication lag.
- **Jenkins** — up/health, executor utilization, queue size, agent nodes,
  build success/failure rates.
- **Active alerts** — table of currently firing and pending alerts, severity
  colour-coded, with stat counts up top.

### Pre-baked alerts (in Slack)

- **Host**: `InstanceDown`, `HighCPU`, `HighMemoryUsage`, `LowDiskSpace`,
  `HostOOMKill`.
- **Container**: `ContainerNotSeen`, `ContainerHighMemoryVsLimit`,
  `ContainerOOMKilled`, `ContainerRestartLoop`.
- **HTTP probes**: `ProbeFailing`, `ProbeSlow`, `SSLCertExpiringSoon`.
- **JVM**: `JvmHeapPressure`, `JvmGCThrashing`, `JvmMetaspacePressure`,
  `JvmThreadGrowth`, `JvmScrapeDown`, `HttpServerErrorRateHigh`,
  `HttpClientErrorRateHigh`, `HttpLatencyP95High`, `HikariCPPoolExhausted`.
- **RabbitMQ**: `RabbitMQDown`, `RabbitMQNoConsumers`,
  `RabbitMQQueueBacklog`, `RabbitMQDiskLow`.
- **PostgreSQL**: `PostgreSQLDown`, `PostgreSQLTooManyConnections`,
  `PostgreSQLLowCacheHitRatio`, `PostgreSQLDeadlocks`,
  `PostgreSQLReplicationLag`.
- **Jenkins**: `JenkinsDown`, `JenkinsHealthCheckFailed`,
  `JenkinsQueueBacklog`, `JenkinsExecutorSaturated`.
- **Logs**: `ErrorLogsSpike`, `JvmOutOfMemoryError`, `JvmGCOverheadLimit`,
  `JvmStackOverflowError`, `JvmFatalSignal`.
- **Monitor self-health**: `MonitorDiskLow`, `PrometheusUnreachable`,
  `LokiUnreachable`, `AlertmanagerUnreachable`.

## Prerequisites

- Linux host with Docker 24+ and **Docker Compose v2** (the Go plugin —
  invoked as `docker compose`, with a space). The legacy v1 Python tool
  (`docker-compose` with a hyphen) does not accept this package's compose
  files and is EOL since 2023. Install with
  `sudo apt-get install docker-compose-plugin` (Debian/Ubuntu) or
  `sudo dnf install docker-compose-plugin` (Amazon Linux / Fedora /
  RHEL-family).
- `gettext` (provides `envsubst`) for the render script.
- Network: target host must reach monitoring host on **3100** (Loki push) and
  the monitoring host must reach each target on **9100** (node-exporter),
  **9180** (cAdvisor), and the management port of each Java app. Lock those
  down with security groups / firewalls — no authentication on the metrics
  ports.

## Quickstart — monitoring host

```bash
cp .env.example .env
$EDITOR .env                       # STACK-SIDE vars: MONITORING_*, GRAFANA_*, SLACK_*
bin/render-configs.sh
docker compose --env-file .env -f stack/docker-compose.yml up -d
xdg-open "${MONITORING_SITE:-http://localhost}"
```

Grafana login: whatever you set in `GRAFANA_ADMIN_*`. You'll land on the
**SolDevelo Monitoring** home dashboard.

Then register the things you want monitored by dropping JSON files in
`prometheus/targets/<component>/`. See:
- [`docs/host-setup.md`](docs/host-setup.md) — host onboarding (paired
  `nodes/` + `cadvisor/` targets).
- [`docs/blackbox-setup.md`](docs/blackbox-setup.md) — HTTP probes.
- [`docs/java-app-setup.md`](docs/java-app-setup.md),
  [`docs/python-app-setup.md`](docs/python-app-setup.md) — application
  scrape targets.
- [`docs/rabbitmq-setup.md`](docs/rabbitmq-setup.md),
  [`docs/postgresql-setup.md`](docs/postgresql-setup.md),
  [`docs/jenkins-setup.md`](docs/jenkins-setup.md) — stack components.

## Reverse proxy (Caddy) — works the same on laptop and EC2

The stack includes Caddy in front of Grafana. Caddy's auto-HTTPS picks
behaviour from the site address in `MONITORING_SITE`:

| `MONITORING_SITE` value | What Caddy does |
|---|---|
| `http://localhost` | Plain HTTP, no TLS. Default. |
| `http://localhost:8080` | Plain HTTP on whichever port you remap to (see `CADDY_HTTP_PORT`). |
| `localhost` | Caddy's internal CA + self-signed TLS. Browser warns until you trust the CA. |
| `https://monitoring.example.com` | Free Let's Encrypt cert, A+ TLS, auto-renewed. Needs ports 80/443 reachable + DNS pointing to the host. |

You change one env var and the same compose works locally and on a public
EC2 with no other changes. `LETSENCRYPT_EMAIL` is used only when the site is
a real domain.

If port 80 / 443 are already taken on the host (common on dev laptops),
remap via `CADDY_HTTP_PORT` / `CADDY_HTTPS_PORT` and update `MONITORING_SITE`
to include the port (`http://localhost:8080`).

In production, also recommend firewalling Grafana's direct port (3001 by
default) so users have to go through Caddy. Same recommendation for
Prometheus (9090) and Alertmanager (9093) — they have no auth.

## Quickstart — target host (the thing being monitored)

On each server you want to monitor:

```bash
git clone <this repo>
cd soldevelo-monitoring
cp .env.example .env
$EDITOR .env                       # AGENTS-SIDE vars: TARGET_NAME, MONITORING_SERVER_HOST
bin/render-configs.sh
docker compose --env-file .env -f agents/docker-compose.yml up -d
```

Verify on the target: `curl http://localhost:9100/metrics` (node-exporter) and
`http://localhost:9180/metrics` (cAdvisor) both return Prometheus-format data.

Then on the **monitoring host**, register the target by adding an entry to
paired JSON files in `prometheus/targets/nodes/*.json` and
`prometheus/targets/cadvisor/*.json`. Full walkthrough:
[`docs/host-setup.md`](docs/host-setup.md).

## Adding a Java application

Spring Boot apps with Actuator + Micrometer get the JVM dashboard and alerts.
Full walkthrough: [`docs/java-app-setup.md`](docs/java-app-setup.md).

Short version:
1. Add `spring-boot-starter-actuator` and `micrometer-registry-prometheus`
   to the app.
2. Set `management.endpoints.web.exposure.include=health,prometheus` plus
   `management.metrics.tags.service=<your-service-name>`.
3. Drop a JSON file in `prometheus/targets/java/`:
   ```json
   [
     {"targets": ["host:port"], "labels": {"service":"<name>", "host":"<host>", "environment":"production"}}
   ]
   ```
4. Wait 30 s. Prometheus hot-reloads target lists; no restart needed.

For 10+ microservices (OpenLMIS Malawi case), one entry per service in a
single JSON file — same shape, scales without further refactoring.

## How do I know it's working?

- **Grafana → SolDevelo Monitoring (home)** — alert counts, dashboard list,
  currently-firing table.
- **Prometheus → Status → Targets** at `http://<monitor-host>:9090/targets` —
  every configured job (`node`, `cadvisor`, `blackbox_http`, `java`,
  `python`, `rabbitmq`, `postgresql`, `jenkins`, meta jobs) should be `UP`.
  Jobs with no target JSON files simply show empty — expected.
- **Alertmanager** at `http://<monitor-host>:9093` — firing alerts, silences,
  routing.
- **Slack** — set a probe URL to something broken (e.g.
  `https://example.com/does-not-exist-x`); a `ProbeFailing` alert lands
  in `SLACK_CHANNEL` within ~2 minutes.

## Local testing on a single machine

For development and evaluation: run stack + agents on the same Docker host.
`localhost` inside a container is the container itself, so use
`host.docker.internal` instead — the package's compose files ship the
`host-gateway` alias on Prometheus / Blackbox / Promtail to make that resolve
on Linux Docker.

On the **agents side** of `.env`:
```env
TARGET_NAME=<host-slug>
MONITORING_SERVER_HOST=host.docker.internal
```

On the **monitoring host**, use `host.docker.internal` as the address in
target JSON files:
```json
[{"targets": ["host.docker.internal:9100"], "labels": {"host": "<host-slug>"}}]
```

Port collision: if Grafana's `3000` clashes with something else (e.g.
Keycloak), remap on the host side: `"3001:3000"`.

After `.env` changes:

```bash
bin/render-configs.sh
docker compose --env-file .env -f stack/docker-compose.yml up -d --force-recreate prometheus blackbox
docker compose --env-file .env -f agents/docker-compose.yml up -d --force-recreate promtail
```

Target JSON changes need no render/restart — Prometheus hot-reloads them
every 30 seconds.

## Operating notes

- **After `.env` edits** — re-run `bin/render-configs.sh` AND force-recreate
  any containers that bind-mount the rendered config (Prometheus,
  Alertmanager, Blackbox, Promtail). A plain `restart` doesn't always pick up
  bind-mounted file changes.
- **After target-file edits** (`prometheus/targets/<component>/*.json`) —
  Prometheus hot-reloads file_sd within 30 s. No render, no restart.
- **Resetting state** — `docker compose down -v` wipes Prometheus, Loki, and
  Grafana data volumes. Keep a backup before doing this in anger.
- **Public Grafana** — the Caddy service in `stack/` does TLS + reverse
  proxy automatically. For production, firewall the direct Grafana port
  (3001) so the only entry path is through Caddy on 80/443. Prometheus
  (9090) and Alertmanager (9093) should similarly not be public.
- **Secrets** — `.env` and `prometheus/targets/**/*.json` are gitignored.
  Don't commit them.

## Conventions

- **Metric catalog** — [`docs/metrics.md`](docs/metrics.md) is the canonical
  list of metrics this package relies on, with required labels and the
  "what it does NOT mean" pattern for heading off semantic drift between
  projects.
- **Java onboarding** — [`docs/java-app-setup.md`](docs/java-app-setup.md)
  covers dependencies, properties, ports, `-Xmx` sizing, the common
  Spring-Security-on-actuator gotcha, and the diagnostic ladder for "target
  is DOWN".

## Versioning

`soldevelo-monitoring` uses [semantic versioning](https://semver.org/).

- **`0.x.y`** — pre-1.0, breaking changes possible between minor versions.
  Pin a release (`git checkout v0.1.0`) in your project's overlay and read
  the CHANGELOG before bumping.
- **`1.0.0`** — first stable release. Backward compatibility for `.env`
  schema, dashboard UIDs, and file layout will hold within the `1.x` line.

The roadmap markers in `IDEAS.md` (V1 / V2 / V3) describe planned *capability
stages*, not version numbers. They're internal planning vocabulary; what
goes on a git tag is always semver.

## Roadmap

- **V1 (nearly complete)** — shipped across `0.1.0`–`0.3.0`: Java /
  Micrometer scrape + JVM dashboard + JVM alerts + HTTP RED + HikariCP +
  Python + RabbitMQ + PostgreSQL + Jenkins + business-metrics convention
  + file_sd everywhere. Remaining: second adopter deployment (OpenLMIS
  Malawi) to prove the distribution model in practice.
- **V2** — Terraform module to provision the monitoring VM on AWS:
  EC2 + EBS + Route53 + Caddy reverse proxy + automatic backups.
- **V3+** — Frontend RUM (Grafana Faro), multi-tenant Grafana, Helm/K8s
  variant, unified Service dashboard (constant top + technology-adaptive
  panels), runbook directory linked from alert payloads.

## Why these choices

- **Versioned base + thin overlay**, not copy-and-modify. Target projects
  pin a release and override via `.env` + per-project files (Java target
  JSON, probe URL list); improvements fan out by bumping the version.
- **Dashboards-as-code (provisioned JSON)**, not "import-from-UI". Dashboards
  land automatically on first boot; no clicks needed.
- **Two Prometheus instances** (main + meta). Meta watches the monitoring
  host itself, so a disk-full or Loki outage on the monitor doesn't silently
  stop alerting.
- **`network_mode: host` for node-exporter**, not the obvious-looking bridge
  default. Without it, the netdev / netclass collectors see the container's
  own netns rather than the real host's — which produces near-zero network
  numbers that look like the host is idle when it isn't.
- **File_sd everywhere** for target configuration. Every scrape job — hosts,
  containers, HTTP probes, Java apps, Python apps, PostgreSQL, RabbitMQ,
  Jenkins — reads targets from `prometheus/targets/<component>/*.json`.
  Consistent pattern, hot-reloaded, scales from one target to fifty
  without any base-file edits.

## License

MIT — see [`LICENSE`](LICENSE). Copyright © 2026 SolDevelo.
