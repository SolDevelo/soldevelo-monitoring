# Wiring PostgreSQL into soldevelo-monitoring

PostgreSQL doesn't expose Prometheus metrics natively, so run `postgres_exporter`
as a sidecar. It connects with a limited-privilege user and translates
`pg_stat_*` views into Prometheus metrics.

## 1. Deploy the exporter

Add to your project's docker-compose, next to PostgreSQL. It must be on the
**same docker network** as the app so the Alloy agent can reach it:

```yaml
postgres-exporter:
  image: quay.io/prometheuscommunity/postgres-exporter:v0.20.1
  restart: unless-stopped
  environment:
    DATA_SOURCE_NAME: "postgresql://monitoring:${POSTGRES_MONITORING_PASSWORD}@postgres:5432/postgres?sslmode=disable"
  labels:
    monitoring.scrape: "true"
    monitoring.port: "9187"
    monitoring.service: "postgres"
  networks:
    - local-cfp-net
  depends_on:
    - postgres
```

`monitoring.path` defaults to `/metrics`. `app` / `deployment` / `host` come
from the agent's env; `service=postgres`. `datname` differentiates individual
databases within the instance.

## 2. Create the monitoring user

A dedicated read-only user rather than the app's DB credentials:

```sql
CREATE USER monitoring WITH PASSWORD 'strong-password-here';
GRANT pg_monitor TO monitoring;
```

`pg_monitor` (PostgreSQL 10+) grants read access to the stats views
`postgres_exporter` needs (`pg_stat_*`, `pg_settings`, …) with no data or DDL
privileges. Put the password in `.env` as `POSTGRES_MONITORING_PASSWORD`.

## 3. Verify

```bash
docker compose exec postgres-exporter curl -s localhost:9187/metrics | head -20
```
Should print `pg_*` metrics. Errors are usually a connection-string typo or a
missing `pg_monitor` grant.

## 4. What you get

Dashboard: **Grafana → PostgreSQL**. Panels: up/down, connections + utilization
(%), cache hit ratio, per-database connections, commit vs rollback rate,
deadlocks, DB size, tuple operations.

Alerts: **`prometheus/rules/postgresql_rules.yml`**:

- `PostgreSQLDown` — unreachable for 2m.
- `PostgreSQLTooManyConnections` — >85% of max_connections for 10m.
- `PostgreSQLLowCacheHitRatio` — <90% for 30m (working set outgrew
  `shared_buffers`, or full scans).
- `PostgreSQLDeadlocks` — deadlock rate for 5m (sustained ⇒ lock-ordering bug).
- `PostgreSQLReplicationLag` — replica >15m behind primary (needs the
  replication collector, exporter pointed at the primary).

## Multiple databases

`postgres_exporter` connects to one database but queries stats for *all*
databases on the instance — the `datname` label differentiates them, powering
the dashboard's "Database" filter.

## Optional: custom queries

`postgres_exporter` supports user-defined queries via `queries.yaml` — useful
for app-specific counts on a business-critical table. Same discipline as
[`business-metrics.md`](business-metrics.md).

## Common gotchas

- **Connection refused between exporter and PostgreSQL** — hostname (`postgres`
  service name inside the network), and `pg_hba.conf` allows the user + source.
- **Metrics all zero** — `pg_monitor` not granted. `\du monitoring` to check.
- **Gap after a PG major upgrade** — stats views rename columns between
  majors; bump `postgres_exporter` to match your PG major.
- **High cardinality on `pg_stat_user_tables`** — thousands of tables blow up
  cardinality; use `--disable-default-metrics` and enable only what you need.
