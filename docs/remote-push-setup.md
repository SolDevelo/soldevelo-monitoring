# Ingest endpoints (metrics + logs)

Every target runs a Grafana Alloy agent that pushes metrics and logs to this
monitoring host over authenticated HTTPS — works the same whether the target
shares a network with the monitor or lives in a different AWS account. This doc
covers the **receiver side** (the monitoring host); the agent side is
`agents-alloy/` and [`host-setup.md`](host-setup.md).

## What's exposed

Both endpoints sit behind Caddy on the existing `MONITORING_SITE`, path-routed
and gated by a bearer token. The raw Prometheus (9090) and Loki (3100) ports
stay off the public internet — everything arrives over TLS through Caddy.

| Purpose | Endpoint | Proxies to |
|---|---|---|
| Metrics (Prometheus remote-write) | `<MONITORING_SITE>/ingest/prometheus/api/v1/write` | `prometheus:9090` `/api/v1/write` |
| Logs (Loki push) | `<MONITORING_SITE>/ingest/loki/loki/api/v1/push` | `loki:3100` `/loki/api/v1/push` |

Caddy's `handle_path` strips the `/ingest/<target>` prefix, so each backend
receives the exact path it expects. The Grafana UI keeps serving every other
path unchanged (there is no collision — Grafana's own `/api/*` is separate
from `/ingest/…`).

## Enabling it on the monitoring host

The pieces ship in the package; you enable them with config + a recreate.

1. **Set a token** in `.env`:
   ```bash
   openssl rand -hex 32     # copy the output
   ```
   ```env
   INGEST_TOKEN=<the-generated-secret>
   ```
   Keep it secret; anyone with it can write metrics/logs into your stack.

2. **Render and recreate** the affected services:
   ```bash
   bin/render-configs.sh
   docker compose --env-file .env -f stack/docker-compose.yml up -d --force-recreate prometheus caddy
   ```
   - `prometheus` picks up `--web.enable-remote-write-receiver` (already in the
     compose command list).
   - `caddy` picks up the rendered `/ingest/*` routes from `Caddyfile.template`.

3. **Open network access.** The pushing agent needs to reach `MONITORING_SITE`
   on 443. Allow that deployment's egress IP(s) in the monitoring host's
   security group / firewall. Nothing else needs opening — do **not** expose
   9090 or 3100 publicly.

## Verifying

From any machine that can reach the site (substitute your token):

```bash
# Loki push — expect 204 No Content on success, 401 without the token.
# (-w prints the code; body prints too, so Loki's reason shows on a 400.)
curl -sS -w '\n%{http_code}\n' \
  -H "Authorization: Bearer $INGEST_TOKEN" \
  -H "Content-Type: application/json" \
  "https://monitoring.example.com/ingest/loki/loki/api/v1/push" \
  --data-raw '{"streams":[{"stream":{"app":"myapp","deployment":"main","service":"smoke-test"},"values":[["'"$(date +%s%N)"'","hello from remote push"]]}]}'

# Same URL without the header should return 401.
```

- A successful Loki push then shows up in **Grafana → Explore → Loki** with
  `{deployment="main"}`.
- For metrics, once an Alloy agent is remote-writing, its series appear in
  **Prometheus → Graph** (e.g. `up{deployment="main"}`) and in the dashboards
  under the new `deployment` value.

## Labeling

Pushed data must carry the same taxonomy as everything else —
`app` / `deployment` / `service` (+ `host` / `environment`). The pushing agent
attaches them (relabel on metrics, static labels on logs); this receiver does
not add or rewrite labels. See `docs/metrics.md` for the contract, and set a
distinct `deployment` value per remote so its data stays separable.

## Security notes

- **One shared token today.** For multiple remote deployments, prefer a token
  per deployment so one can be revoked without disrupting the others — add a
  matcher per token in `Caddyfile.template`. (Single token is fine to start.)
- **Rotation** — change `INGEST_TOKEN`, re-render, recreate `caddy`, and update
  the agent. No Prometheus/Loki restart needed for a token change.
- **Loki stays single-tenant** (`auth_enabled: false`); the `deployment` label
  provides logical separation and Caddy provides the auth. Hard multi-tenant
  isolation (per-tenant `X-Scope-OrgID`) is a later step if needed.
- **Bearer token, not mTLS** — simplest first step. Move to mTLS or per-
  deployment client certs if you later need stronger client authentication.

## Common gotchas

- **401 from a correct-looking token** — the header must be exactly
  `Authorization: Bearer <token>`; a trailing newline or missing `Bearer ` word
  fails the match. Confirm `INGEST_TOKEN` rendered into `caddy/Caddyfile` (it's
  gitignored) matches what the agent sends.
- **404 on the ingest path** — you rendered before adding `INGEST_TOKEN` to
  `.env`, so `${INGEST_TOKEN}` stayed literal and the site block may not have
  rendered as expected; or the path prefix is wrong (note the doubled segment
  for Loki: `/ingest/loki/loki/api/v1/push`).
- **Metrics rejected as "out of order" / "too old"** — if the agent batches and
  back-fills, add `--storage.tsdb.out-of-order-time-window=5m` to the
  prometheus command. Not enabled by default; only add it if you see rejects.
- **413 Request Entity Too Large** — very large push batches; Caddy passes them
  through, but tune the agent's batch size down if a backend rejects them.
