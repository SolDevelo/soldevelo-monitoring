# Onboarding a Kubernetes cluster

A cluster runs one **Grafana Alloy** Deployment (`agents-alloy/kubernetes/`)
that discovers pods through the API, collects their logs and metrics, and
pushes to the central monitoring host over authenticated HTTPS — the same
push model and label contract as the docker agent in
[`host-setup.md`](host-setup.md). Plain manifests, no Helm, no DaemonSet, no
hostPath: logs are read via the API (`loki.source.kubernetes`), so one small
pod is enough.

## What it collects

| Source | `job` | Labels |
| --- | --- | --- |
| Pods annotated `prometheus.io/scrape: "true"` | `app` | `service` (pod label `app`), `instance` (pod name), `namespace` |
| kube-state-metrics (shipped) | `kube-state` | `service="kube-state-metrics"`; KSM's own `namespace` / `pod` stay, its `deployment` / `service` become `exported_*` (the agent's win) |
| The agent itself (`prometheus.exporter.self`) | `agent` | `instance` pinned to `TARGET_NAME` |
| Every container's logs, all namespaces except `monitoring` | — | `service`, `container`, `pod`, `namespace` |

Every series and log stream also carries `app` / `deployment` / `environment` /
`host` from the agent's env; `host` is the cluster slug (`TARGET_NAME`).

**Not collected — deliberately.** No node metrics (`node_*`) and no cAdvisor
container metrics (`container_*`): the agent has no host to mount, and the
package's *Host overview* and *Containers* dashboards and their alerts
(`InstanceDown`, `HighCPU`, `LowDiskSpace`, `ContainerAbsent`, …) are
docker-shaped. On a cluster that ground is covered by kube-state-metrics
(`kube_pod_status_ready`, `kube_pod_container_status_restarts_total`,
`kube_deployment_status_replicas_available`) — queryable now, dashboards and
rules for it are a roadmap item. `ServiceDown` / `ServiceAbsent` work as on
docker; see *Gotchas* for how `ServiceAbsent` behaves across a rollout.

## Prerequisites

- `kubectl` with cluster-admin on the target cluster (a ClusterRole is created).
- The monitoring host's ingest token (`INGEST_TOKEN` in its `.env`).
- **Outbound access** from the pods to the monitoring host's `MONITORING_SITE`
  (443 in production; plain HTTP only for local testing). Nothing inbound.

## 1. Configure and apply

```sh
git clone <repo-url>
cd soldevelo-monitoring
cp agents-alloy/kubernetes/30-agent-config.yaml.example agents-alloy/kubernetes/30-agent-config.yaml
$EDITOR agents-alloy/kubernetes/30-agent-config.yaml   # the one file to edit; gitignored
```

```yaml
data:
  APP: myapp                     # the application this cluster runs
  DEPLOYMENT: main               # which deployment of it
  ENVIRONMENT: prod              # prod | uat | staging | dev — Alertmanager routes on it
  TARGET_NAME: myapp-prod-eks    # cluster slug → the `host` label
  INGEST_METRICS_URL: https://monitoring.example.com/ingest/prometheus/api/v1/write
  INGEST_LOGS_URL: https://monitoring.example.com/ingest/loki/loki/api/v1/push
```

Same variables as the docker agent's `.env`, and the same `.example` → real
file pattern, so `git pull` never touches your identity. The token is a Secret, created out-of-band so it never sits in a
tracked file (`ingest-secret.yaml.example` shows the shape):

```sh
kubectl apply -f agents-alloy/kubernetes/00-namespace.yaml
kubectl create secret generic alloy-ingest -n monitoring \
  --from-literal=INGEST_TOKEN='<INGEST_TOKEN from the monitoring host .env>'
kubectl apply -f agents-alloy/kubernetes/
kubectl -n monitoring rollout status deploy/alloy deploy/kube-state-metrics
```

Files are numbered so the directory apply creates the namespace first; the two
`.example` files are not `*.yaml`, so the directory apply skips them and can
never overwrite the real token or identity with the placeholders.

## 2. Onboard the workloads

Annotate the **pod template** (not the Deployment's own metadata):

```yaml
spec:
  template:
    metadata:
      labels:
        app: scraper                            # → `service`
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"              # metrics port, reached on the pod IP
        prometheus.io/path: "/actuator/prometheus"
```

| Annotation | Required | Example | Meaning |
| --- | --- | --- | --- |
| `prometheus.io/scrape` | yes | `"true"` | Opt the pod in. |
| `prometheus.io/port` | yes | `"9090"` | Port scraped on the pod IP — it need not be a Service port or a declared `containerPort`. |
| `prometheus.io/path` | no | `"/actuator/prometheus"` | Default `/metrics`. |
| `monitoring.service` | no | `"scraper"` | Overrides the pod label `app` as `service`. |

The agent picks a change up within ~30s of the pods rolling; no agent restart.

**The `service` rule.** `service` is the pod's `app` label — the conventional
Kubernetes selector label, so most workloads need nothing extra. When that
label is missing or carries an app prefix the contract forbids (`myapp-scraper`
instead of `scraper`), set the `monitoring.service` annotation, which wins.
`service` must be a short, stable role slug: N replicas of one role share
`service` and are split by `instance` (= pod name). Same rule for logs.

Per-technology guides apply unchanged: [`java-app-setup.md`](java-app-setup.md),
[`python-app-setup.md`](python-app-setup.md) — only the docker labels become
the annotations above.

## 3. The AgentAbsent overlay

A dead cluster agent cannot report itself; its series simply stop. Add one
stanza per cluster to the monitoring host's
`prometheus/rules/overlay/<deployment>.yml` (rationale and the `for` constraint
in [`prometheus/rules/overlay/README.md`](../prometheus/rules/overlay/README.md)).
`host` is the cluster's `TARGET_NAME`:

```yaml
groups:
  - name: agent-inventory
    rules:
      - alert: AgentAbsent
        expr: absent(up{job="agent", deployment="main", environment="prod", host="myapp-prod-eks"})
        for: 5m
        labels:
          severity: critical
          app: myapp
          deployment: main
          environment: prod
          host: myapp-prod-eks
        annotations:
          summary: "Monitoring agent absent: myapp-prod-eks (prod)"
          description: "No metrics from the Alloy agent on cluster myapp-prod-eks for 5m — the agent pod, the cluster, or its egress is down; everything else from this cluster is stale."
```

Then `curl -X POST localhost:9090/-/reload` on the monitoring host. The
heartbeat's `instance` is pinned to `TARGET_NAME`, so a rollout of the agent
pod does not fire this (a pod-name `instance` would).

## Verify

```sh
kubectl -n monitoring logs deploy/alloy | grep -E 'level=(warn|error)'
```

Empty output is the healthy result: a bad token or URL shows up here as
remote_write / loki 4xx errors on every push.

On the central Grafana:

- **Explore → Loki** `{deployment="main"}` — pod logs, labelled `service` /
  `container` / `pod` / `namespace`.
- **Explore → Prometheus** `up{job="agent", host="myapp-prod-eks"}` — the
  heartbeat, value `1`; `up{job="app", deployment="main"}` — one series per
  annotated pod; `kube_pod_status_ready{deployment="main"}` — KSM.

## Upgrade

- **Agent version** — bump the `grafana/alloy:` tag in `50-alloy.yaml` (same
  pin as `ALLOY_VERSION` in `.env.example`; `bin/validate.sh` checks they
  agree), then `kubectl apply -f agents-alloy/kubernetes/`.
- **Alloy config** (`40-alloy-config.yaml`) or **env** (`30-agent-config.yaml`)
  — `kubectl apply -f agents-alloy/kubernetes/` then
  `kubectl -n monitoring rollout restart deploy/alloy` (a ConfigMap change
  does not restart the pod on its own).
- The Deployment uses `Recreate`, so an upgrade is a gap of a few seconds, not
  two agents pushing the same heartbeat at once.

## Local testing (kind / minikube)

Point `INGEST_*_URL` at a plain-HTTP stack on the laptop
(`MONITORING_SITE=http://localhost[:port]`, see the README). Inside a kind pod
`host.docker.internal` does not resolve; use the IPv4 gateway of the cluster's
docker network as the host in both URLs:
`docker network inspect kind -f '{{range .IPAM.Config}}{{println .Gateway}}{{end}}'`
(a dual-stack kind network lists an IPv6 gateway too — take the IPv4 one).

## Gotchas

- **`ServiceAbsent` after a rollout.** `instance` is the pod name, and a
  Deployment mints new names on every rollout, so the replaced pod's
  (`service`, `instance`) stops reporting: `ServiceAbsent` (warning) pends for
  30m and clears 2h after the deploy. Silence deploy windows
  ([`silences.md`](silences.md)) rather than loosening the rule. A stable
  per-replica identity does not exist for Deployments; for a single-replica
  workload you may set `instance` to a constant by adding a relabel rule in
  `discovery.relabel "app"`.
- **Metrics port also declared as a `containerPort`.** Fine. Every declared
  port produces one discovered target, but after the relabel they all carry
  the same address and labels and the scraper keeps one; `count(up{job="app",
  service="x"})` equals the pod count. An annotated pod with no ports declared
  is scraped too.
- **Nothing from an annotated pod** — the annotations are on the Deployment,
  not the pod template; or `prometheus.io/port` is missing (required — no
  fallback to declared ports); or the port serves on `127.0.0.1` only (Spring:
  `management.server.address=0.0.0.0`); or the pod's `app` label is missing
  and no `monitoring.service` annotation was set (`service` is then empty).
- **Logs from every namespace.** The agent tails all pods except its own
  namespace (feedback loop); `kube-system` included. To narrow it, add a
  `keep` rule on `__meta_kubernetes_namespace` to `discovery.relabel "logs"`
  in `40-alloy-config.yaml`.
- **`tailer stopped; will retry … pods "<name>" not found` warnings** for a
  minute or two after a scraped or tailed pod is deleted: Alloy 1.5.1 keeps
  retrying the tail until discovery drops the target. Transient, not a fault.
- **Pod restart loses log position.** State is an `emptyDir`; a restarted agent
  tails from now. Backfilling old log tails would need a PVC, which the
  package does not ship.
- **Two Alertmanager-routing values that must be exact.** `ENVIRONMENT` is one
  of `prod|uat|staging|dev`; an off-enum value misses the prod channel and the
  dev mute silently. `TARGET_NAME` must match the overlay's `host=`.
