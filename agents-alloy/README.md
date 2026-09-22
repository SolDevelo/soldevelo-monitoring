# Alloy host agent

One Grafana Alloy container per target host. It:

- **discovers** docker containers labelled `monitoring.scrape=true` and scrapes
  their metrics on the container's internal IP:port (no host port publishing);
- collects **host** metrics (`prometheus.exporter.unix`) and **container**
  metrics (`prometheus.exporter.cadvisor`);
- tails **all container logs**;
- **pushes** metrics (`remote_write`) and logs to the central host's
  bearer-gated `/ingest/*` endpoints.

Workloads self-describe (compose labels here, `prometheus.io/*` pod annotations
on Kubernetes) and the agent discovers them. See `docs/remote-push-setup.md`
(receiver) and `docs/metrics.md` (label contract).

## Self-describing services

Each scrapable service declares its metrics endpoint + role via compose labels:

```yaml
labels:
  monitoring.scrape: "true"
  monitoring.port: "9090"                 # internal metrics port
  monitoring.path: "/actuator/prometheus" # default /metrics
  monitoring.service: "scraper"           # role (stable) → `service` label
```

`app` / `deployment` / `environment` / `host` come from the agent's env (`APP` /
`DEPLOYMENT` / `ENVIRONMENT` / `TARGET_NAME`), not per-service. `instance` is
the compose service name (`scraper`, `scraper-2`, …) — readable per-replica
identity. So N replicas of one role become `service=<role>` split by `instance`.

`ENVIRONMENT` must be one of `prod` / `uat` / `staging` / `dev`. Alertmanager
routes on the literal value: an unset or off-enum value misses both the prod
channel and the dev mute, and the alert lands in the default receiver instead.

`job` is set by the agent to the collector kind — `app` for everything found by
docker SD, plus `node` / `cadvisor` / `agent` for the built-in exporters. Alert
rules key on those four values; see `docs/metrics.md`.

## Prerequisites

- The agent joins the app stack's docker network (`APP_NETWORK` in `.env`,
  declared `external` in `docker-compose.yml`) so it can reach container IPs.
  `docker network ls` shows the real name (compose v2: `<project>_default`).
- Any service to be scraped internally must be on that network (e.g. a
  `postgres-exporter` sidecar has to join it too).

## Deploy

```sh
cp .env.example .env
$EDITOR .env         # ALLOY_VERSION, APP, DEPLOYMENT, ENVIRONMENT, TARGET_NAME, APP_NETWORK, INGEST_*
docker compose --env-file .env -f agents-alloy/docker-compose.yml up -d
docker compose --env-file .env -f agents-alloy/docker-compose.yml logs alloy | tail   # no remote_write/loki 4xx
```

Add the `monitoring.*` labels to the app's compose services and recreate them
so the labels take effect (`docker compose up -d` — labels need a container
recreate).
