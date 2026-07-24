# Onboarding a target host

Every host you want monitored (application host, DB host, reporting host,
Jenkins host, etc.) runs the same three agents: **node-exporter** for OS
metrics, **cAdvisor** for container metrics, **Promtail** for logs. All of
them ship in `agents/docker-compose.yml`. Registering the host with the
monitoring stack is a matter of two JSON files.

Same procedure for one host or fifty. Same procedure for UAT / Prod / DEV.

## 1. Deploy the agents on the target host

Assuming the target host has Docker + Docker Compose v2 already:

```bash
git clone <repo-url>
cd soldevelo-monitoring
git checkout v0.3.0
cp .env.example .env
```

Edit `.env` — only the agents-side variables matter here (see the "AGENTS
SIDE" section of `.env.example`):

```env
TARGET_NAME=malawi-prod-app          # host slug — appears on all metrics + logs
MONITORING_SERVER_HOST=10.0.0.20     # IP/DNS of the monitoring host (Loki push target)
TARGET_NODE_EXPORTER_PORT=9100       # default, only change on port conflict
TARGET_CADVISOR_PORT=9180            # default, only change on port conflict
```

Then:

```bash
bin/render-configs.sh
docker compose --env-file .env -f agents/docker-compose.yml up -d
```

Verify on the target host:

```bash
curl http://localhost:9100/metrics | head    # node-exporter
curl http://localhost:9180/metrics | head    # cAdvisor
```

Both should print Prometheus-format text.

## 2. Open network access

The monitoring host needs to reach the target on **9100** (node-exporter)
and **9180** (cAdvisor). The target needs to reach the monitoring host on
**3100** (Loki push).

For AWS: adjust security groups. For a private VPC, allow only the
monitoring host's security group as the source — don't open these ports to
the public internet.

## 3. Register the host with Prometheus (two JSON files, paired)

On the **monitoring host**, drop paired JSON files describing the target.
Convention: one file per project (or per environment), listing every host
in that scope.

`prometheus/targets/nodes/malawi.json`:
```json
[
  {
    "targets": ["10.0.1.10:9100"],
    "labels": {
      "app": "openlmis",
      "deployment": "malawi",
      "host": "malawi-prod-app",
      "environment": "production"
    }
  },
  {
    "targets": ["10.0.1.11:9100"],
    "labels": {
      "app": "openlmis",
      "deployment": "malawi",
      "host": "malawi-prod-db",
      "environment": "production"
    }
  },
  {
    "targets": ["10.0.2.10:9100"],
    "labels": {
      "app": "openlmis",
      "deployment": "malawi",
      "host": "malawi-uat-app",
      "environment": "uat"
    }
  }
]
```

`prometheus/targets/cadvisor/malawi.json`:
```json
[
  {
    "targets": ["10.0.1.10:9180"],
    "labels": {
      "app": "openlmis",
      "deployment": "malawi",
      "host": "malawi-prod-app",
      "environment": "production"
    }
  },
  {
    "targets": ["10.0.1.11:9180"],
    "labels": {
      "app": "openlmis",
      "deployment": "malawi",
      "host": "malawi-prod-db",
      "environment": "production"
    }
  },
  {
    "targets": ["10.0.2.10:9180"],
    "labels": {
      "app": "openlmis",
      "deployment": "malawi",
      "host": "malawi-uat-app",
      "environment": "uat"
    }
  }
]
```

**The two files are mirrors** — same hosts, different ports, same labels.
The `host` label needs to match what you set as `TARGET_NAME` in the
target's `.env` (so logs, host metrics, and container metrics all label
consistently). `app` / `deployment` scope the host to the application and
deployment it belongs to, so host and container dashboards can filter by
deployment (set them when a host is dedicated to one deployment; omit them
on hosts genuinely shared by several). The `environment` label distinguishes
prod / uat / dev within a deployment.

Log streams from these hosts carry `host` / `container` automatically; to get
`app` / `deployment` on logs too, set them as static labels in the target's
Promtail config (or via Alloy once the host is migrated). Metrics get them
from the target JSON above regardless.

Prometheus hot-reloads within 30 seconds. Verify at
`http://<monitor>:9090/targets` — the `node` and `cadvisor` jobs each show
one entry per host, all `UP`.

## 4. What you get, automatically

Once the target is registered:

- **Host overview dashboard** — CPU, memory, disk, network, load, filtered
  by `host` variable.
- **Containers dashboard** — per-container CPU / memory / network / logs on
  that host, filtered by `host` and `container` variables.
- **Alerts wired up** — `InstanceDown`, `HighCPU`, `HighMemoryUsage`,
  `LowDiskSpace`, `HostOOMKill`, container-family alerts. All fire against
  the new host without further configuration.
- **Logs flowing to Loki** from every container on the host, searchable in
  Grafana Explore with labels `host` and `container`.

## Adding another host later

Two operations, both quick:

1. Deploy agents on the new host (repeat step 1).
2. Add an entry (or entries) to the existing `malawi.json` files (both
   nodes and cadvisor). Prometheus picks it up within 30s.

No changes to `.env` on the monitoring host, no service restarts.

## Common gotchas

- **`up` shows DOWN with "connection refused"** — target's node-exporter /
  cAdvisor isn't running, or the port isn't reachable. Check the security
  group and confirm `docker compose ps` on the target.
- **`up` shows DOWN with "no such host"** — you used a hostname the monitor
  can't resolve. Use IPs, or ensure DNS resolves.
- **Metrics reach Prometheus but the `host` label is wrong or missing** —
  check the target JSON's `labels` section. This is the source of the
  `host` label — the target host's `.env` `TARGET_NAME` doesn't affect
  metric labels (only log labels, via Promtail).
- **Logs don't appear in Loki** — Promtail push failing. Check
  `MONITORING_SERVER_HOST` on the target — must be an address the target
  can actually reach on port 3100. On restrictive networks, verify egress.
- **Metrics from the target's own network interface (eth0) show near-zero
  numbers** — you likely forgot `network_mode: host` on the target's
  node-exporter. This is set correctly in the shipped compose; only shows
  up if someone customized. See the `agents/docker-compose.yml` comment.
- **Host directory permissions denied when Prometheus tries to read the
  target file** — CIS-benchmarked distros with `umask 0027`. The render
  script's built-in `chmod -R a+rX` on config directories fixes this;
  re-run `bin/render-configs.sh`.
