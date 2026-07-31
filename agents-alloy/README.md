# Alloy host agent

One Grafana Alloy container per target host. Supersedes the `agents/` bundle
(node-exporter + cAdvisor + Promtail). It:

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

## Migrating an existing host off `agents/` (sdd)

Run in this order to avoid a gap and avoid double-counting:

1. **Bring up Alloy** (above) alongside the existing setup. Metrics briefly
   double-collect — the pulled series (`instance=<ip>:<port>`) and the pushed
   series (`instance=<compose-service>`) differ, so nothing is lost.
2. **Verify** on the central stack: `up{deployment="sdd"}` shows the pushed
   targets; `{deployment="sdd"}` logs now carry `app`/`service` (they didn't
   under Promtail).
3. **Retire the pull:** delete the sdd file_sd targets on the monitoring host
   (`prometheus/targets/{java,python,postgresql,cadvisor,nodes,rabbitmq}/cfp.json`).
   Prometheus drops them within 30 s.
4. **Stop the old bundle:** `docker compose -f agents/docker-compose.yml down`.
5. **Close inbound metric ports** in the host security group (9100/9180/9190-
   9198/9291-9293/9380/15692) — the agent now scrapes internally and only needs
   outbound 443. Optionally drop the `ports:` metrics mappings from the app
   compose too.

**Rollback:** `docker compose -f agents-alloy/... down`, restore the target
JSON files, `docker compose -f agents/... up -d`.

## Label transition note

sdd's per-service `scraper-1..8` become `service=scraper` + `instance=scraper..
scraper-8`. Historical series keep the old labels; new data uses role+instance.
Dashboards already handle this (the `instance` picker). Same one-time shift as
the Phase 0 relabel.
