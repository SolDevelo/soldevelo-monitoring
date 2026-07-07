# Wiring PostgreSQL into soldevelo-monitoring

PostgreSQL doesn't expose Prometheus metrics natively, so we run
`postgres_exporter` as a sidecar. It connects to the DB with a limited-
privilege user and translates `pg_stat_*` views into Prometheus metrics.

## 1. Deploy the exporter

Add to your project's docker-compose, next to your PostgreSQL service:

```yaml
postgres-exporter:
  image: quay.io/prometheuscommunity/postgres-exporter:v0.15.0
  restart: unless-stopped
  environment:
    DATA_SOURCE_NAME: "postgresql://monitoring:${POSTGRES_MONITORING_PASSWORD}@postgres:5432/postgres?sslmode=disable"
  ports:
    - "9187:9187"
  depends_on:
    - postgres
```

## 2. Create the monitoring user

Give the exporter a dedicated read-only user rather than reusing your app's
DB credentials:

```sql
CREATE USER monitoring WITH PASSWORD 'strong-password-here';
GRANT pg_monitor TO monitoring;
```

`pg_monitor` is a built-in role that grants read access to the stats views
`postgres_exporter` needs (`pg_stat_*`, `pg_settings`, etc.) without any
data or DDL privileges. Available in PostgreSQL 10+.

Put the password in your `.env` and reference it as
`POSTGRES_MONITORING_PASSWORD` in the compose.

## 3. Verify the exporter

```bash
curl http://localhost:9187/metrics | head -20
```

Should print `pg_*` metrics. If it errors, check the exporter's logs —
usually a connection-string typo or missing `pg_monitor` grant.

## 4. Register with Prometheus

Drop a JSON file in `prometheus/targets/postgresql/`:

`prometheus/targets/postgresql/cfp-classifier.json`:
```json
[
  {
    "targets": ["host.docker.internal:9187"],
    "labels": {
      "host": "cfp-classifier",
      "environment": "production"
    }
  }
]
```

Prometheus hot-reloads within 30 seconds. Verify at
`http://<monitor>:9090/targets` — `postgresql` job should be `UP`.

## 5. What you get

Dashboard: **Grafana → Dashboards → PostgreSQL**. Panels:

- Up/down, active connections, connection utilization (%), cache hit ratio.
- Connections over time per database.
- Transaction rate (commit vs rollback — rising rollback is a smell).
- Deadlocks and conflicts.
- Database size over time.
- Tuple operations (fetched / inserted / updated / deleted rates).

Alerts: **`prometheus/rules/postgresql_rules.yml`** ships with:

- `PostgreSQLDown` — unreachable for 2m.
- `PostgreSQLTooManyConnections` — >85% of max_connections for 10m.
  Usually a client-side connection pool sizing issue or a leak.
- `PostgreSQLLowCacheHitRatio` — <90% for 30m. Working set has outgrown
  `shared_buffers`, or a query is doing full scans.
- `PostgreSQLDeadlocks` — any deadlock rate for 5m. Occasional deadlocks
  under contention are normal; sustained rate usually means a lock-ordering
  bug in application code.
- `PostgreSQLReplicationLag` — replica > 15 minutes behind primary.
  Requires the exporter's replication collector to be enabled and the
  exporter to be pointed at the primary. Panel and alert both show "No
  data" if replication isn't configured.

## Multiple databases

`postgres_exporter` connects to *one* database (the one in
`DATA_SOURCE_NAME`) but by default queries stats for *all* databases on
that PostgreSQL instance — the `datname` label in metrics differentiates
them. That's what powers the "Database" filter on the dashboard.

If you have PostgreSQL instances on different hosts, deploy one exporter
per host and add one entry per host in the JSON file (or split into per-
host files). The `host` label differentiates them.

## Optional: custom queries

`postgres_exporter` supports user-defined queries via a `queries.yaml` file.
Useful for exposing app-specific metrics that live in database tables
(e.g. row counts on a business-critical table). This turns into business
metrics — same discipline as `docs/business-metrics.md`; naming convention
applies.

## Common gotchas

- **Connection refused between exporter and PostgreSQL.** Check hostname
  (`postgres` vs `localhost` — inside a Docker network, service name; from
  outside, the mapped port). Check that PostgreSQL's `pg_hba.conf` allows
  the exporter's user + source IP.
- **Exporter runs but metrics are all zero.** Grant issue — `pg_monitor`
  wasn't granted to the user. `\du monitoring` in psql to check.
- **Sudden gap in metrics after a PostgreSQL upgrade.** The stats views
  occasionally rename columns between major versions. Update
  `postgres_exporter` to a version that matches your PG major.
- **`pg_stat_replication_lag_bytes` is empty even though we have
  replication.** The exporter needs to be pointed at a *primary* to see
  replication metrics; replicas expose different views. If you want
  metrics from replicas too, deploy an exporter per node.
- **High cardinality on `pg_stat_user_tables` metrics.** Databases with
  thousands of tables can blow up cardinality. Configure the exporter's
  `--disable-default-metrics` and enable only what you need if you hit
  Prometheus storage pressure.
