# Wiring Jenkins into soldevelo-monitoring

Jenkins exposes Prometheus metrics via a community plugin. Install the plugin,
label the container.

## 1. Install the Prometheus plugin

In the Jenkins UI: **Manage Jenkins → Plugins → Available plugins** → search
**Prometheus metrics** (plugin ID `prometheus`) → install and restart. Or
declaratively:

```bash
jenkins-plugin-cli --plugins prometheus:latest
```

## 2. Configure the endpoint

**Manage Jenkins → System → Prometheus** (appears after install). Defaults are
usually fine:

- **Path**: `/prometheus`.
- **Namespace**: `default`.
- **Per-build metrics**: enable for per-job success/failure visibility; disable
  with hundreds of jobs (cardinality).

Verify:
```bash
docker compose exec jenkins curl -s localhost:8080/prometheus | head -20
```
Should print `jenkins_*` metrics.

## 3. Label the container for discovery

Add compose labels so the Alloy agent scrapes it:

```yaml
jenkins:
  labels:
    monitoring.scrape: "true"
    monitoring.port: "8080"
    monitoring.path: "/prometheus"
    monitoring.service: "jenkins"
```

`app` / `deployment` / `host` come from the agent's env. For standalone
infrastructure like Jenkins, name `APP`/`DEPLOYMENT` after the system itself
(e.g. `APP=jenkins`) so nothing lands unlabelled. Keep `/prometheus` off the
public internet — it's unauthenticated by default.

## 4. What you get

Dashboard: **Grafana → Jenkins**. Panels: up/down, aggregate health, queue
size, executors in use, executors over time, agent nodes online/offline, build
success/failure rate.

Alerts: **`prometheus/rules/jenkins_rules.yml`**:

- `JenkinsDown` — unreachable for 2m.
- `JenkinsHealthCheckFailed` — aggregate health score < 1.
- `JenkinsQueueBacklog` — queue > 10 for 30m.
- `JenkinsExecutorSaturated` — zero free executors for 30m.

## Common gotchas

- **`/prometheus` returns 404** — plugin not installed/enabled.
- **`up` is 1 but no metrics** — "Collect metrics" disabled on the plugin's
  config page.
- **Metric names differ** — older plugin versions prefix `default_jenkins_`;
  newer drop it. Curl the raw endpoint and check if the dashboard shows no data.
- **Endpoint requires auth** — some hardened setups gate `/prometheus`. Exempt
  it (and firewall the port) rather than opening it publicly.
- **High cardinality from per-job metrics** — disable "Per-build metrics" for
  the aggregate view.
