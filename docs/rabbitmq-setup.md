# Wiring RabbitMQ into soldevelo-monitoring

RabbitMQ 3.8+ ships with a built-in Prometheus plugin — no sidecar exporter.
Enable the plugin, label the container.

## 1. Enable the Prometheus plugin

Inside the RabbitMQ container / host:

```bash
rabbitmq-plugins enable rabbitmq_prometheus
```

Or, with a mounted `enabled_plugins` file:
```
[rabbitmq_management,rabbitmq_prometheus].
```

The plugin listens on port **15692**. Use the **`/metrics/per-object`**
endpoint — it emits one series per queue with a `queue=` label. The default
`/metrics` is aggregated with no `queue` label, which leaves Grafana's Queue
picker empty and stops `RabbitMQNoConsumers` / `RabbitMQQueueBacklog` from
firing per-queue. With thousands of queues where cardinality is a concern, use
`/metrics` and accept that per-queue views/alerts go dark.

Verify from the RabbitMQ host:
```bash
curl http://localhost:15692/metrics/per-object | grep '^rabbitmq_queue_messages{'
```
should print one line per queue with a `queue="…"` label.

## 2. Label the container for discovery

Add compose labels so the Alloy agent scrapes it (no need to publish `15692`
to the host — the agent reaches it on the internal docker network):

```yaml
rabbitmq:
  # ... existing config ...
  labels:
    monitoring.scrape: "true"
    monitoring.port: "15692"
    monitoring.path: "/metrics/per-object"
    monitoring.service: "rabbitmq"
```

`app` / `deployment` / `host` come from the agent's env, so a second
deployment's broker stays separate automatically.

## 3. What you get

Dashboard: **Grafana → RabbitMQ**. Panels:

- Node up / down, total messages across queues, active connections, consumer
  count.
- Messages per queue over time (queue picker).
- Publish vs delivery rate — divergence precedes queue backlog.
- Consumers per queue (zero = stuck queue).
- Unacked messages (climbing = slow or dying consumer).
- RabbitMQ process memory and disk space.

Alerts: **`prometheus/rules/rabbitmq_rules.yml`**:

- `RabbitMQDown` — node unreachable for 2m.
- `RabbitMQNoConsumers` — queue has messages but zero consumers for 5m.
- `RabbitMQQueueBacklog` — >10k messages sitting for 15m (tighten per-project).
- `RabbitMQDiskLow` — <5 GB free. RabbitMQ *blocks all publishers* when disk
  fills, so this is a real cliff.

## Clusters

For a cluster (multiple nodes, one logical broker), the plugin exposes
cluster-wide metrics — labelling one node is enough. Labelling all nodes is
fine too; queue metrics are deduplicated by node.

## Common gotchas

- **`/metrics` returns 404 or empty** — plugin not enabled. `rabbitmq-plugins
  list | grep prometheus` should show `E`.
- **Queue picker empty / per-queue panels blank, totals fine** — the label
  points at `/metrics` (aggregated), not `/metrics/per-object`. Fix
  `monitoring.path`. Same symptom silently disables the per-queue alerts.
- **No metrics at all** — confirm the `monitoring.scrape` label and that the
  agent shares the app's docker network.
