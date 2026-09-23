# Onboarding a target host

Every host or cluster you want monitored runs one **Grafana Alloy** agent. It
discovers the local workloads, collects host + container metrics and every
container's logs, and pushes them to the central monitoring host over
authenticated HTTPS. Nothing is registered on the monitoring host.

Same procedure for one host or fifty, and for prod / uat / dev.

## 1. Run the Alloy agent

On the target host (Docker + Docker Compose v2):

```bash
git clone <repo-url>
cd soldevelo-monitoring
cp .env.example .env
```

Set the agent variables in `.env`:

```env
ALLOY_VERSION=v1.5.1
APP=myapp                   # the application this host runs
DEPLOYMENT=main             # which deployment of it (one value per remote site)
ENVIRONMENT=prod            # prod | uat | staging | dev — Alertmanager routes on it
TARGET_NAME=myapp-prod-1    # host slug → the `host` label
APP_NETWORK=myapp_default   # the app stack's compose network (`docker network ls`)
INGEST_METRICS_URL=https://<monitor>/ingest/prometheus/api/v1/write
INGEST_LOGS_URL=https://<monitor>/ingest/loki/loki/api/v1/push
INGEST_TOKEN=<bearer token from the monitoring host>
```

Bring it up:

```bash
docker compose --env-file .env -f agents-alloy/docker-compose.yml up -d
docker compose --env-file .env -f agents-alloy/docker-compose.yml logs alloy | tail   # no 4xx to the ingest endpoints
```

Host metrics (`node_*`), container metrics (`container_*`), and all container
logs now flow, labelled `app` / `deployment` / `environment` / `host`. Full runbook, network
prerequisites, and the compose-label convention are in
[`agents-alloy/README.md`](../agents-alloy/README.md).

## 2. Network access

The agent needs **outbound HTTPS (443)** to the monitoring host's ingest
endpoints. Nothing inbound.

## 3. Onboard the services on the host

Application services are picked up by adding compose labels; the agent
discovers them and scrapes their internal port. Per-technology guides:
[`java-app-setup.md`](java-app-setup.md), [`python-app-setup.md`](python-app-setup.md),
[`rabbitmq-setup.md`](rabbitmq-setup.md), [`postgresql-setup.md`](postgresql-setup.md),
[`jenkins-setup.md`](jenkins-setup.md).

## What you get, automatically

- **Host overview dashboard** — CPU, memory, disk, network, load (per `host`).
- **Containers dashboard** — per-container CPU / memory / network / logs.
- **Alerts** — `InstanceDown`, `HighCPU`, `HighMemoryUsage`, `LowDiskSpace`,
  `HostOOMKill`, container-family alerts, against the new host automatically.
- **Logs** in Grafana Explore, labelled `app` / `deployment` / `host` /
  `service` / `container`.

## Kubernetes

On a cluster the agent runs in-cluster from plain manifests and workloads are
onboarded with `prometheus.io/*` pod annotations instead of compose labels;
same label contract. See [`kubernetes-setup.md`](kubernetes-setup.md).

## Common gotchas

- **No host/container metrics, `host` label empty** — `TARGET_NAME` isn't set
  in the agent `.env`; an empty value drops the `host` label, and the Host /
  Containers dashboards filter on it. Set it and recreate the agent.
- **Nothing from a service** — confirm its `monitoring.scrape: "true"` label and
  that the agent shares the app's docker network (it must reach the container's
  internal metrics port).
- **`entry … too old` on first start** — one-time backfill of long-running
  containers' historical logs hitting Loki's retention window; the agent drops
  the old batches and live-tails. Harmless.
