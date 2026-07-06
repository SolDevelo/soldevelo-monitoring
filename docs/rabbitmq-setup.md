# Wiring RabbitMQ into soldevelo-monitoring

RabbitMQ 3.8+ ships with a built-in Prometheus plugin — no sidecar exporter
required. Setup is: enable the plugin, publish the port, register the
instance with Prometheus.

## 1. Enable the Prometheus plugin

Inside the RabbitMQ container / host:

```bash
rabbitmq-plugins enable rabbitmq_prometheus
```

The plugin exposes metrics on port **15692** at `/metrics` by default.
Persistent enablement survives restart.

If you're using a Docker image with a mounted `enabled_plugins` file:

```
[rabbitmq_management,rabbitmq_prometheus].
```

Verify from the RabbitMQ host: `curl http://localhost:15692/metrics | head`
should print `rabbitmq_*` metrics.

## 2. Publish the port

In the RabbitMQ service's docker-compose:

```yaml
rabbitmq:
  # ... existing config ...
  ports:
    - "5672:5672"    # AMQP
    - "15672:15672"  # Management UI
    - "15692:15692"  # Prometheus metrics — add this
```

Keep 15692 firewalled to the monitoring host only, same as other metrics
ports (9100, 9180). It exposes internal state and shouldn't be public.

## 3. Register the RabbitMQ instance with Prometheus

Drop a JSON file in `prometheus/targets/rabbitmq/`. Same file_sd format as
Java / Python:

`prometheus/targets/rabbitmq/cfp-classifier.json`:
```json
[
  {
    "targets": ["host.docker.internal:15692"],
    "labels": {
      "host": "cfp-classifier",
      "environment": "production"
    }
  }
]
```

The `host` label ties the RabbitMQ instance to a broader target host (same
convention as node-exporter / cAdvisor). No `service` label is needed —
RabbitMQ itself is the service.

Prometheus hot-reloads within 30 seconds. Verify at
`http://<monitor>:9090/targets` — `rabbitmq` job should be `UP`.

## 4. What you get

Dashboard: **Grafana → Dashboards → RabbitMQ**. Panels:

- Node up / down, total messages across queues, active connections,
  consumer count.
- Messages per queue over time (queue picker lets you filter).
- Publish vs delivery rate — divergence here is the warning sign that
  precedes queue backlog.
- Consumers per queue (zero = stuck queue).
- Unacked messages (climbing = slow or dying consumer).
- RabbitMQ process memory and disk space.

Alerts: **`prometheus/rules/rabbitmq_rules.yml`** ships with:

- `RabbitMQDown` — node unreachable for 2m.
- `RabbitMQNoConsumers` — queue has messages but zero consumers for 5m.
  Catches the silent-consumer-died failure mode.
- `RabbitMQQueueBacklog` — >10k messages sitting for 15m. Threshold is
  generous; tighten per-project if you have queues where 10k is normal.
- `RabbitMQDiskLow` — <5 GB free. When RabbitMQ's disk fills, it *blocks
  all publishers*, so this is a real cliff, not a warning.

## Multiple RabbitMQ instances

If you have RabbitMQ instances on different hosts, add one entry per host
in the JSON file, or split into per-host files (`cfp-classifier.json`,
`another-project.json`). The `host` label differentiates them.

For clusters (multiple RabbitMQ nodes forming one logical broker), the
built-in plugin exposes cluster-wide metrics automatically — you only need
to scrape one node. But scraping all nodes is fine too; queue metrics are
deduplicated by node.

## Common gotchas

- **`/metrics` returns 404 or empty.** Plugin not enabled. Check
  `rabbitmq-plugins list | grep prometheus` — should show `E`.
- **Metrics exist but queue metrics are empty.** In some versions the
  plugin has `queue.messages` disabled by default for cardinality reasons
  when you have very many queues. If you have <100 queues, no issue. If
  more, enable `rabbitmq_prometheus_metrics_aggregated_queues=false`
  through the RabbitMQ config to see per-queue metrics.
- **Port 15692 refused from monitoring host.** Firewall / security group.
  Same fix as opening 9100 for node-exporter.
- **Metrics show up but there's no `host` label.** You forgot the target
  file's labels. The Prometheus scrape config adds them from the JSON.
