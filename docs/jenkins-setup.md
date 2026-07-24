# Wiring Jenkins into soldevelo-monitoring

Jenkins exposes Prometheus metrics via a well-maintained community plugin.
Install the plugin, register the endpoint, and Jenkins becomes another
component alongside RabbitMQ / PostgreSQL.

## 1. Install the Prometheus plugin

In the Jenkins UI:

- **Manage Jenkins → Plugins → Available plugins**
- Search for **Prometheus metrics** (plugin ID: `prometheus`).
- Install and restart Jenkins.

Or on the Jenkins host command line if you manage plugins declaratively:

```bash
jenkins-plugin-cli --plugins prometheus:latest
```

## 2. Configure the endpoint

**Manage Jenkins → System → Prometheus** (section appears after plugin
install). Defaults are usually fine:

- **Path**: `/prometheus` (this is what the scrape job in
  `prometheus.yml.template` expects — don't change).
- **Namespace**: `default` (feeds into metric name prefixes).
- **Collecting metrics period**: 30 seconds.
- **Per-build metrics**: enable if you want per-job success/failure
  visibility; disable if you have hundreds of jobs and Prometheus
  cardinality is a concern.

Save. Verify by curling from the Jenkins host:

```bash
curl http://localhost:8080/prometheus | head -20
```

Should print `jenkins_*` metrics.

## 3. Publish the port (if not already)

Jenkins typically runs on port 8080. If it's already reachable from the
monitoring host, no change needed. If Jenkins is behind a reverse proxy,
ensure `/prometheus` isn't blocked by auth (the endpoint is unauthenticated
by default, which is why you want it firewalled off from the public
internet).

## 4. Register with Prometheus

Drop a JSON file in `prometheus/targets/jenkins/`:

`prometheus/targets/jenkins/malawi.json`:
```json
[
  {
    "targets": ["jenkins.example.com:8080"],
    "labels": {
      "app": "jenkins",
      "deployment": "malawi",
      "host": "malawi-jenkins",
      "environment": "production"
    }
  }
]
```

For standalone infrastructure like Jenkins that isn't part of a monitored
application, `app` / `deployment` name the system itself (here `app: jenkins`,
`deployment: malawi`) rather than a product deployment — the point is only
that every target carries the pair so nothing lands unlabelled.

Prometheus hot-reloads within 30 seconds. Verify at
`http://<monitor>:9090/targets` — `jenkins` job should show `UP`.

## 5. What you get

Dashboard: **Grafana → Dashboards → Jenkins**. Panels:

- Up/down, aggregate health score, queue size, executors in use.
- Executors over time (in use vs free, stacked).
- Queue size + pending over time.
- Agent nodes online vs offline.
- Build success / failure rate over the last hour.

Alerts: **`prometheus/rules/jenkins_rules.yml`** ships with:

- `JenkinsDown` — unreachable for 2m.
- `JenkinsHealthCheckFailed` — Jenkins' own aggregate health score < 1
  (thread deadlock, disk space, plugin, other internal check failing).
- `JenkinsQueueBacklog` — queue > 10 for 30 minutes. Threshold generous;
  tighten per-project if a smaller queue is normal for you.
- `JenkinsExecutorSaturated` — zero free executors for 30 minutes,
  distinct from queue backlog (which is a symptom of this being sustained).

## Common gotchas

- **`/prometheus` returns 404.** Plugin not installed or not enabled.
  Check **Manage Jenkins → Plugins → Installed** and confirm "Prometheus
  metrics" is present + enabled.
- **`up{job="jenkins"}` shows 1 but no other metrics visible.** Endpoint
  returned an empty body — usually means the "Collect metrics" setting is
  disabled. Check the plugin's configuration page.
- **Metric names differ from what the dashboard expects.** Some older
  plugin versions prefix metrics with `default_jenkins_`. Newer versions
  drop the prefix. If your dashboard shows "No data" but Prometheus targets
  are UP, curl the raw endpoint and check the actual metric names — you
  may need to adjust the dashboard queries or the namespace setting.
- **Endpoint requires auth.** By default `/prometheus` is public; some
  security-hardened setups gate it. If Prometheus scrapes are 401, either
  exempt `/prometheus` from auth (firewall the port instead) or configure
  the scrape target with `basic_auth`.
- **High cardinality from per-job metrics.** If you have hundreds of jobs
  and enabled "Per-build metrics", Prometheus storage will grow rapidly.
  Disable per-build metrics for the aggregate-view use case; enable only
  if you have a specific reason to monitor individual jobs.
