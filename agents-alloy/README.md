# Alloy host agent

One Grafana Alloy container per target host. It:

- **discovers** docker containers labelled `monitoring.scrape=true` and scrapes
  their metrics on the container's internal IP:port (no host port publishing);
- collects **host** metrics (`prometheus.exporter.unix`) and **container**
  metrics (`prometheus.exporter.cadvisor`);
- tails **all container logs**;
- **pushes** metrics (`remote_write`) and logs to the central host's
  bearer-gated `/ingest/*` endpoints.

This is the docker twin of the ILO Alloy setup — both deployments self-describe
(compose labels here, pod annotations on k8s) and the agent discovers them. See
`docs/remote-push-setup.md` (receiver) and `docs/metrics.md` (label contract).

## Self-describing services

Each scrapable service declares its metrics endpoint + role via compose labels:

```yaml
labels:
  monitoring.scrape: "true"
  monitoring.port: "9090"                 # internal metrics port
  monitoring.path: "/actuator/prometheus" # default /metrics
  monitoring.service: "scraper"           # role (stable) → `service` label
```

`app` / `deployment` / `host` come from the agent's env (`APP` / `DEPLOYMENT` /
`TARGET_NAME`), not per-service. `instance` is the compose service name
(`scraper`, `scraper-2`, …) — readable per-replica identity. So N replicas of
one role become `service=<role>` split by `instance`.

## Prerequisites

- The service network is `external: true` and the agent joins it
  (`local-cfp-net` in `docker-compose.yml`) so it can reach container IPs.
  Change that network name for another app.
- Any service to be scraped internally must be on that network (e.g.
  `postgres-exporter` had to join `local-cfp-net`).

## Deploy

```sh
cp .env.example .env
$EDITOR .env         # ALLOY_VERSION, APP, DEPLOYMENT, TARGET_NAME, INGEST_*
docker compose --env-file .env -f agents-alloy/docker-compose.yml up -d
docker compose -f agents-alloy/docker-compose.yml logs alloy | tail   # no remote_write/loki 4xx
```

Add the `monitoring.*` labels to the app's compose services and recreate them
so the labels take effect (`docker compose up -d` — labels need a container
recreate).
