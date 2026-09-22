# soldevelo-monitoring

SolDevelo's opinionated, OSS-based monitoring package — open source, usable
by anyone with a Linux host and Docker. Pre-baked stack (Prometheus + Loki +
Grafana + Alertmanager + Blackbox), pre-baked dashboards-as-code, pre-baked
alerts wired to Slack, and a documented metric catalog so the same names mean
the same things across projects.

**Version:** `0.5.1`. See [`CHANGELOG.md`](CHANGELOG.md).

## What's in the box

```
                    ┌──────────────────────────────────────────┐
                    │            Monitoring host (VM)           │
   push (HTTPS)     │                                           │
   metrics ─────────┼─► Prometheus ─► Alertmanager ─► Slack     │
   logs    ─────────┼─► Loki                                    │
                    │   Grafana (dashboards)   Blackbox (probes)│
                    │   + Prometheus-meta (self-monitor)        │
                    └──────────────────────────────────────────┘
                    ▲
       ┌────────────┴───────────────────────────────────┐
       │  Target host / cluster                          │
       │   Grafana Alloy: discovers workloads, collects  │
       │   host + container + app metrics and all logs,  │
       │   pushes to the monitoring host over HTTPS       │
       └─────────────────────────────────────────────────┘
```

- **stack/** — runs on the monitoring host (Prometheus with the remote-write
  receiver + Prometheus-meta + Loki + Grafana + Alertmanager + Blackbox + the
  monitor's own node-exporter + cAdvisor).
- **agents-alloy/** — one Grafana Alloy agent per target host: discovers the
  local workloads, collects host + container + app metrics and every
  container's logs, and pushes them in over authenticated HTTPS.
- **prometheus/**, **loki/**, **alertmanager/**, **blackbox/**, **grafana/** —
  configs (templates rendered from `.env` plus committed rule files).
- **bin/render-configs.sh** — envsubst `*.template` files using `.env` values.
- **docs/** — `metrics.md` (catalog and conventions), `remote-push-setup.md`
  (the ingest endpoints), `host-setup.md` (run the agent), `blackbox-setup.md`
  (HTTP probes), `java-app-setup.md`, `python-app-setup.md`, `rabbitmq-setup.md`,
  `postgresql-setup.md`, `jenkins-setup.md` (label a service for discovery),
  `business-metrics.md`, `dead-man-switch.md` (external heartbeat),
  `silences.md` (deploy windows), `releasing.md` (cutting a version).

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
- **Service / push-model absence**: `ServiceDown` (scraped, reports down),
  `ServiceAbsent` and `ContainerAbsent` (was reporting within 2h, no longer
  is — under push, a dead target simply stops arriving, so `== 0` never fires),
  `AgentAbsent` (overlay, see below).
- **Container**: `ContainerHighMemoryVsLimit`, `ContainerOOMKilled`,
  `ContainerRestartLoop`.
- **HTTP probes**: `ProbeFailing`, `AppDown`, `PublicUrlUnreachable`,
  `ProbeSlow`, `SSLCertExpiringSoon`.
- **JVM**: `JvmHeapPressure`, `JvmGCThrashing`, `JvmMetaspacePressure`,
  `JvmThreadGrowth`, `HttpServerErrorRateHigh`, `HttpClientErrorRateHigh`,
  `HttpLatencyP95High`, `HikariCPPoolExhausted`.
- **RabbitMQ**: `RabbitMQDown`, `RabbitMQNoConsumers`,
  `RabbitMQQueueBacklog`, `RabbitMQDiskLow`.
- **PostgreSQL**: `PostgreSQLDown`, `PostgreSQLTooManyConnections`,
  `PostgreSQLLowCacheHitRatio`, `PostgreSQLDeadlocks`,
  `PostgreSQLReplicationLag`.
- **Jenkins**: `JenkinsDown`, `JenkinsHealthCheckFailed`,
  `JenkinsQueueBacklog`, `JenkinsExecutorSaturated`.
- **Logs**: `ErrorLogsSpike`, `JvmOutOfMemoryError`, `JvmGCOverheadLimit`,
  `JvmStackOverflowError`, `JvmFatalSignal`.
- **Monitor self-health** (Prometheus-meta): `MonitorDiskLow`,
  `PrometheusUnreachable`, `LokiUnreachable`, `AlertmanagerUnreachable`,
  `AlertmanagerNotificationsFailing`, `PrometheusNotificationsDropped`,
  `PrometheusRuleEvaluationFailing`.
- **Dead man's switch**: `Watchdog` — always firing, routed to an external
  heartbeat ([`docs/dead-man-switch.md`](docs/dead-man-switch.md)).

`AgentAbsent` is the one rule the base package cannot ship: it is
`absent(up{job="agent", host="<host>"})` over an explicit host inventory, so
each deployment writes its own copy in `prometheus/rules/overlay/` (gitignored;
template and rationale in
[`prometheus/rules/overlay/README.md`](prometheus/rules/overlay/README.md)).
The Alertmanager inhibition chain assumes it exists — a dead agent takes every
series from that host with it, and `AgentAbsent` is what mutes the resulting
`ServiceDown` / `ServiceAbsent` / `ContainerAbsent` / `InstanceDown` alerts
into one notification. A deployment that skips the overlay gets that storm
instead, so writing the file is part of onboarding a host, not optional.

Alerts labelled `environment="dev"` are routed to a null receiver: dev targets
get dashboards, metrics and logs, but never a Slack notification. Change that
route's receiver in `alertmanager/alertmanager.yml.template` to opt in.

Alerts labelled `environment="prod"` go to the `slack-prod` receiver. Set
`SLACK_WEBHOOK_URL_PROD` and `SLACK_CHANNEL_PROD` to give production its own
channel; unset, both fall back to `SLACK_WEBHOOK_URL` / `SLACK_CHANNEL` and
everything shares one channel.

## Prerequisites

- Linux host with Docker 24+ and **Docker Compose v2** (the Go plugin —
  invoked as `docker compose`, with a space). The legacy v1 Python tool
  (`docker-compose` with a hyphen) does not accept this package's compose
  files and is EOL since 2023. Install with
  `sudo apt-get install docker-compose-plugin` (Debian/Ubuntu) or
  `sudo dnf install docker-compose-plugin` (Amazon Linux / Fedora /
  RHEL-family).
- `gettext` (provides `envsubst`) for the render script.
- Network: each target host needs **outbound HTTPS (443)** to the monitoring
  host's ingest endpoints — nothing inbound. The monitoring host serves Grafana
  and the bearer-gated `/ingest/*` paths through Caddy on 80/443
  (`CADDY_HTTP_PORT` / `CADDY_HTTPS_PORT`); the other stack ports bind to
  loopback (node-exporter's `:9101` excepted — see *Reverse proxy*).

## Quickstart — monitoring host

```bash
cp .env.example .env
$EDITOR .env                       # STACK-SIDE vars: MONITORING_*, GRAFANA_*, SLACK_*, INGEST_TOKEN
bin/render-configs.sh
docker compose --env-file .env -f stack/docker-compose.yml up -d
xdg-open http://localhost           # or whatever MONITORING_SITE you set
```

Grafana login: whatever you set in `GRAFANA_ADMIN_*`. You'll land on the
**SolDevelo Monitoring** home dashboard.

Then onboard what you want monitored — each target host/cluster runs one Alloy
agent that discovers its workloads and pushes in:
- [`docs/host-setup.md`](docs/host-setup.md) — run the agent on a host.
- [`docs/remote-push-setup.md`](docs/remote-push-setup.md) — the ingest endpoints.
- [`docs/blackbox-setup.md`](docs/blackbox-setup.md) — HTTP probes.
- [`docs/java-app-setup.md`](docs/java-app-setup.md),
  [`docs/python-app-setup.md`](docs/python-app-setup.md) — application services.
- [`docs/rabbitmq-setup.md`](docs/rabbitmq-setup.md),
  [`docs/postgresql-setup.md`](docs/postgresql-setup.md),
  [`docs/jenkins-setup.md`](docs/jenkins-setup.md) — infra components.

Then close the loop on the alerting itself — neither is optional for a
deployment anyone relies on:
- [`docs/dead-man-switch.md`](docs/dead-man-switch.md) — the stack cannot alert
  on its own death. Set up the external heartbeat.
- [`docs/silences.md`](docs/silences.md) — silence deploy windows instead of
  loosening thresholds around them.

## Reverse proxy (Caddy) — works the same on laptop and EC2

The stack includes Caddy in front of Grafana and the ingest endpoints. Caddy's
auto-HTTPS picks behaviour from the site address in `MONITORING_SITE`:

| `MONITORING_SITE` value | What Caddy does |
|---|---|
| `http://localhost` | Plain HTTP, no TLS. Default. |
| `http://localhost:8080` | Plain HTTP on a remapped port. Set `CADDY_HTTP_PORT=8080` to match. |
| `localhost` | Caddy's internal CA + self-signed TLS. Browser warns until you trust the CA. Remap: `localhost:8443` + `CADDY_HTTPS_PORT=8443`. |
| `https://monitoring.example.com` | Free Let's Encrypt cert, A+ TLS, auto-renewed. Needs the defaults 80/443 open inbound (80 for the ACME challenge + redirect, 443 for the site) + DNS pointing to the host. |

You change one env var and the same compose works locally and on a public
EC2 with no other changes. `LETSENCRYPT_EMAIL` is used only when the site is
a real domain.

A TLS site address is also a Host filter: agents must address the stack by
exactly that hostname, and a wrong one fails TLS loudly. The plain-HTTP forms
are rendered as a bare `:<port>` and answer on any host name — which is what
makes the same-machine test below work.

If port 80 / 443 are already taken on the host (common on dev laptops),
remap via `CADDY_HTTP_PORT` / `CADDY_HTTPS_PORT` and put the same port in
`MONITORING_SITE` (`CADDY_HTTP_PORT=8080` + `MONITORING_SITE=http://localhost:8080`;
self-signed: `CADDY_HTTPS_PORT=8443` + `MONITORING_SITE=localhost:8443`).
Compose publishes the port 1:1 and Caddy listens on the port in the address,
so the two must agree. Both ports are always published, so when 80 *and* 443
are taken remap both, or `up` fails on the one still on its default.

Caddy is the only public entry point. Prometheus (9090), Prometheus-meta
(9091), Loki (3100), Alertmanager (9093), Blackbox (9115) and Grafana (3000)
bind to `127.0.0.1` — reachable from the host itself (`curl localhost:9090`,
or an SSH tunnel), never from the network; none of them has auth. The one
non-loopback service port is the monitor's own node-exporter on `:9101` (host
network) — firewall it on a host with a public interface.

## Quickstart — target host (the thing being monitored)

Each target host runs one Alloy agent:

```bash
git clone <this repo>
cd soldevelo-monitoring
cp .env.example .env
$EDITOR .env                       # AGENT-SIDE: APP, DEPLOYMENT, ENVIRONMENT, TARGET_NAME, APP_NETWORK, INGEST_*
docker compose --env-file .env -f agents-alloy/docker-compose.yml up -d
```

`ENVIRONMENT` is one of `prod|uat|staging|dev` (Alertmanager routes on it);
`APP_NETWORK` is the app stack's compose network (`docker network ls`, e.g.
`myapp_default`) — the agent joins it to reach container IPs.

Host + container metrics and all container logs now flow. Add compose labels to
your app services so the agent scrapes them too. Full walkthrough:
[`docs/host-setup.md`](docs/host-setup.md) and
[`agents-alloy/README.md`](agents-alloy/README.md).

## Adding a Java application

Spring Boot apps with Actuator + Micrometer get the JVM dashboard and alerts.
Full walkthrough: [`docs/java-app-setup.md`](docs/java-app-setup.md).

Short version:
1. Add `spring-boot-starter-actuator` + `micrometer-registry-prometheus`.
2. Serve actuator on a separate unsecured management port:
   `management.server.port=9090`, `management.server.address=0.0.0.0`,
   `management.endpoints.web.exposure.include=health,prometheus`.
3. Label the service so the agent discovers it:
   ```yaml
   labels:
     monitoring.scrape: "true"
     monitoring.port: "9090"
     monitoring.path: "/actuator/prometheus"
     monitoring.service: "scraper"
   ```
   `app` / `deployment` / `environment` / `host` come from the agent's env;
   `service` from the label. On Kubernetes use `prometheus.io/scrape` pod
   annotations. Label contract: [`docs/metrics.md`](docs/metrics.md).

## How do I know it's working?

- **Grafana → SolDevelo Monitoring (home)** — alert counts, dashboard list,
  currently-firing table.
- **Prometheus → Status → Targets** at `http://localhost:9090/targets` on the
  monitoring host (loopback-only; from elsewhere,
  `ssh -L 9090:localhost:9090 <monitor-host>`) — the `prometheus` and
  `blackbox_http` jobs are `UP`. App / host / container metrics arrive via
  remote_write; query e.g. `up{deployment="<name>"}` to see the pushed targets.
- **Grafana → Explore → Loki** — `{deployment="<name>"}` shows logs streaming.
- **Alertmanager** at `http://localhost:9093` on the monitoring host (same
  tunnel trick) — firing alerts, silences, routing.
- **Slack** — set a probe URL to something broken (e.g.
  `https://example.com/does-not-exist-x`); a `ProbeFailing` alert lands
  in `SLACK_CHANNEL` within ~2 minutes.

## Local testing on a single machine

Run the stack and an Alloy agent on the same Docker host, and point the agent's
`INGEST_*` at the local stack. `localhost` inside a container is the container
itself, so use `host.docker.internal` — both compose files carry the
`host-gateway` alias for it, so it resolves on Linux Docker too. Only Caddy's
port is reachable that way — the other stack ports bind to loopback — so the
agent goes through `/ingest/*` like a remote one. This needs a plain-HTTP
`MONITORING_SITE` (`http://localhost[:port]`), which answers on any host name;
a TLS site matches its hostname only.

On the **agent** `.env`:
```env
APP=<app>
DEPLOYMENT=local
ENVIRONMENT=<prod|uat|staging|dev>
TARGET_NAME=<host-slug>
APP_NETWORK=<the app stack's compose network, e.g. myapp_default — docker network ls>
INGEST_METRICS_URL=http://host.docker.internal/ingest/prometheus/api/v1/write
INGEST_LOGS_URL=http://host.docker.internal/ingest/loki/loki/api/v1/push
INGEST_TOKEN=<token from the stack .env>
```

The agent joins `APP_NETWORK` to reach container IPs. If you remapped
`CADDY_HTTP_PORT`, add the port to both `INGEST_*` URLs
(`http://host.docker.internal:8080/ingest/...`).

Port collision: if Grafana's `3000` clashes with something else (e.g.
Keycloak), change the host side of the mapping in `stack/docker-compose.yml`,
keeping the loopback bind: `"127.0.0.1:13000:3000"`.

After stack `.env` changes:
```bash
bin/render-configs.sh
docker compose --env-file .env -f stack/docker-compose.yml up -d --force-recreate prometheus alertmanager blackbox caddy grafana
```

## Operating notes

- **After `.env` edits** — re-run `bin/render-configs.sh` AND force-recreate
  the containers that bind-mount rendered config (Prometheus, Alertmanager,
  Blackbox, Caddy). A plain `restart` doesn't always pick up bind-mounted
  file changes.
- **After blackbox target edits** (`prometheus/targets/blackbox/*.json`) —
  Prometheus hot-reloads within 30 s. No render, no restart.
- **After dashboard edits** (`grafana/dashboards/*.json`) — Grafana
  hot-reloads within 30 s, no restart. **Permissions caveat:** on
  umask-hardened hosts (CIS AMIs, `umask 0027`) a `git pull` writes the file
  `640`, which the Grafana container user (uid 472) can't read — provisioning
  then logs `permission denied` and the dashboard silently keeps its old
  version. Fix after pulling: `chmod -R a+rX grafana/dashboards` (or re-run
  `bin/render-configs.sh`, which applies the same read bits).
- **Resetting state** — `docker compose down -v` wipes Prometheus, Loki, and
  Grafana data volumes. Keep a backup before doing this in anger.
- **Exposure** — Caddy (TLS + reverse proxy, `CADDY_HTTP_PORT` /
  `CADDY_HTTPS_PORT`) is the only public entry point. Prometheus,
  Prometheus-meta, Loki, Alertmanager, Blackbox and Grafana bind to
  `127.0.0.1`; reach them from the host (`curl localhost:9090`) or over an SSH
  tunnel. node-exporter (`:9101`, host network) is the one non-loopback port —
  firewall it on a host with a public interface.
- **Secrets and per-deployment files** — `.env`,
  `prometheus/targets/**/*.json`, `prometheus/rules/overlay/*.yml` and
  `grafana/dashboards/overlay/*.json` are gitignored. Keep the master copies
  in the deployment's own repo; don't commit them here.

## Conventions

- **Labeling** — every series carries `app` / `deployment` / `service` /
  `host` / `environment`. `app` names the application, `deployment`
  distinguishes multiple deployments of that same application (e.g. `acme`,
  `globex`), and `service` is the component within it (no app prefix). A series
  is unique on (`app`, `deployment`, `service`, `instance`), which is what
  lets one instance monitor several apps and several deployments of one app
  without collisions. `app` / `deployment` / `environment` / `host` are set
  once by the agent; `service` comes from the workload's label / annotation. Full contract:
  [`docs/metrics.md`](docs/metrics.md).
- **Metric catalog** — [`docs/metrics.md`](docs/metrics.md) is the canonical
  list of metrics this package relies on, with required labels and the
  "what it does NOT mean" pattern for heading off semantic drift between
  projects.
- **Self-describing workloads** — a service is monitored by declaring its
  metrics endpoint on itself (docker compose labels, or `prometheus.io/*` pod
  annotations); the agent discovers it. No target lists to maintain.

## Versioning

`soldevelo-monitoring` uses [semantic versioning](https://semver.org/).

- **`0.x.y`** — pre-1.0, breaking changes possible between minor versions.
  Pin a release (`git checkout v0.1.0`) in your project's overlay and read
  the CHANGELOG before bumping.
- **`1.0.0`** — first stable release. Backward compatibility for `.env`
  schema, dashboard UIDs, and file layout will hold within the `1.x` line.

The git tag `vX.Y.Z` is the source of truth for the version. The `**Version:**`
badge above and the `CHANGELOG.md` heading are stamped from it by
`bin/release.sh` — don't hand-edit them (`bin/validate.sh` fails if they drift).
See [`docs/releasing.md`](docs/releasing.md).

The V1 / V2 / V3 markers in the Roadmap below are planned *capability
stages*, not version numbers; what goes on a git tag is always semver.

## Roadmap

- **V1 (complete)** — Alloy push agents, JVM / Python / RabbitMQ / PostgreSQL /
  Jenkins dashboards + alerts, HTTP RED, HikariCP, business-metrics convention,
  and the multi-app / multi-deployment label taxonomy — proven on two live
  deployments (docker + EKS).
- **V2** — Terraform module to provision the monitoring VM on AWS:
  EC2 + EBS + Route53 + Caddy reverse proxy + automatic backups.
- **V3+** — Frontend RUM (Grafana Faro), multi-tenant Grafana, Kubernetes
  Alloy chart, unified Service dashboard (constant top + technology-adaptive
  panels), runbook directory linked from alert payloads.

## Why these choices

- **Push, not pull** — each target runs one Alloy agent that discovers its
  workloads (docker labels / k8s annotations), collects host + container + app
  metrics and logs, and pushes to the monitoring host over authenticated
  HTTPS. No target lists to maintain, no inbound scrape ports, and it works
  across separate networks / cloud accounts unchanged.
- **Self-describing workloads** — the scrape intent lives on the workload, next
  to the team that owns it; the agent discovers it. No drift between a service
  and a separate registry.
- **Versioned base + thin overlay**, not copy-and-modify. Target projects pin
  a release and override via `.env` + per-project files; improvements fan out
  by bumping the version.
- **Dashboards-as-code (provisioned JSON)**, not "import-from-UI". Dashboards
  land automatically on first boot; no clicks needed.
- **Two Prometheus instances** (main + meta). Meta watches the monitoring
  host itself, so a disk-full or Loki outage on the monitor doesn't silently
  stop alerting.

## License

MIT — see [`LICENSE`](LICENSE). Copyright © 2026 SolDevelo.
