# Configuring HTTP probes (Blackbox)

Blackbox probes are the "is this URL alive?" check. They hit each target
URL from the monitoring host and record success, latency, and SSL cert
expiry. Configure by dropping JSON files in `prometheus/targets/blackbox/` (`*.json`
there is gitignored — keep the master copy with your deployment).

## Format

`prometheus/targets/blackbox/acme.json`:
```json
[
  {
    "targets": [
      "https://app.example.com",
      "https://app.example.com/api/health",
      "https://reports.example.com"
    ],
    "labels": {
      "app": "myapp",
      "deployment": "acme",
      "environment": "prod"
    }
  },
  {
    "targets": [
      "https://uat.app.example.com",
      "https://uat.app.example.com/api/health"
    ],
    "labels": {
      "app": "myapp",
      "deployment": "acme",
      "environment": "uat"
    }
  }
]
```

Each entry's `labels` apply to all URLs in that entry's `targets` list.
Multiple entries let you tag different URLs with different labels. The
`instance` label on the resulting metrics is set to the URL itself. Tag
probes with the `app` / `deployment` they belong to so probe results line up
with that deployment's other metrics — use the same values its agents send.
`environment` must be one of `prod`, `uat`, `staging`, `dev`; `bin/validate.sh`
rejects anything else.

Prometheus hot-reloads within 30 seconds. Verify at
`http://localhost:9090/targets` on the monitoring host (the port is
loopback-only) — the `blackbox_http` job lists every URL,
each with `UP` / `DOWN` status.

## What you get, automatically

- **HTTP probes dashboard** — probe success status per URL, request
  duration, SSL certificate days remaining.
- **Alerts** — `ProbeSlow` (>3s for 5m) and `SSLCertExpiringSoon` (<14 days,
  not for `check: service` probes) fire on any newly-added URL. `ProbeFailing`
  (2m of failed probes) covers URLs without a `check` label; tagged ones are
  handled by `AppDown` / `PublicUrlUnreachable` / `ServiceUnreachable` (see
  below).

## Probing behaviour

The default module is `http_2xx`: GET the URL, follow redirects, expect a
2xx response. That's what the shipped scrape config uses. If you need
different behaviour (POST, custom headers, allow non-2xx, HTTPS-required,
TCP-only, etc.), `blackbox/blackbox.yml` defines several modules:

- `http_2xx` — the default. GET, follow redirects, 2xx expected.
- `http_2xx_insecure` — GET over HTTPS by IP / load-balancer DNS, no
  redirect-follow, no cert-name verify — for DNS-independent "is the app up"
  probes (pair it with a normal `http_2xx` probe of the public URL).
- `http_2xx_post` — POST instead of GET.
- `tcp_connect` — TCP handshake only, no HTTP. Target is `host:port`, no scheme.
- `icmp` — ping (needs the container to run with cap_net_raw).

To use a non-default module, add a `module` label to the target entry.
It's picked up by the scrape config's relabel rules:

```json
[
  {
    "targets": ["redis.example.com:6379"],
    "labels": {
      "app": "myapp",
      "deployment": "acme",
      "environment": "prod",
      "module": "tcp_connect"
    }
  }
]
```

## Guidance on what to probe

- **Public-facing URLs first** — anything a user hits (frontend, API root,
  login page). These matter most because they're what your users
  experience.
- **Health check endpoints if they exist** (`/health`, `/actuator/health`)
  — cheaper for the app to serve than a full page render, and they check
  more than just the load balancer being up.
- **One probe per critical endpoint, not per subpage.** Blackbox scrapes
  every 15 seconds; probing 50 URLs generates real traffic to your app.
- **Don't probe internal-only endpoints from the monitoring host if the
  monitor is outside the same network.** Use a health check that IS
  reachable, or accept that internal endpoints stay on the internal-only
  probe list (from an internal monitor if you have one).

## Public, app-direct and per-service availability (the `check` label)

When the public URL depends on DNS or an edge you don't control, probe the app
two ways and tag each with a `check` label so alerts can attribute failures:

- `check: public` — the real public URL (module `http_2xx`). Fails if DNS/edge
  **or** the app is down.
- `check: app-direct` — the app via a path you control (the load-balancer's
  cloud DNS or the instance IP), module `http_2xx_insecure`. Fails only if the
  app itself is down.

Tag both probes of one deployment with the same `app`/`deployment`/`environment`.
Two alerts key off this:

- `AppDown` (critical) — the `app-direct` probe is failing → the application is down.
- `PublicUrlUnreachable` (warning) — `public` fails while `app-direct` succeeds →
  a DNS/edge problem outside the app, not an outage.

Leave `check` off for ordinary probes; `ProbeFailing` covers those.

### Per-service probes (`check: service`)

When the entry point routes to several services (a reverse proxy or gateway in
front of separate backends), add one probe per service through the same path
as the `app-direct` probe. Tag it `check: service` and give it a `service`
label with the same value as the `service` label on that service's own metrics:

```json
[
  {
    "targets": ["https://lb.example.com/orders"],
    "labels": {
      "app": "myapp",
      "deployment": "acme",
      "environment": "prod",
      "check": "service",
      "service": "orders",
      "module": "http_2xx_insecure",
      "__scrape_interval__": "60s"
    }
  }
]
```

Pick a path the service itself answers (its root or a health endpoint), so a
2xx means the request reached that service.

`ServiceUnreachable` (critical) fires when a service probe has failed for 10m
while the `app-direct` probe of the same `app`/`deployment`/`environment`
succeeds. A whole-app outage is left to `AppDown`. The `app-direct` probe
usually hits the load-balancer root, which the web server serves from the UI,
so it only shows that the load balancer and UI answer: if routing to every
service breaks, each service probe fires (grouped into one notification per
environment) while `AppDown` stays quiet.

While `ServiceUnreachable` fires, Alertmanager mutes `ServiceDown` for the same
`service`, which is why the label values must match. `SSLCertExpiringSoon`
skips service probes, since they present the same certificate as the
deployment's other probes.

`__scrape_interval__` sets the probe interval for that target only; the label
does not reach the stored series. Several probes per environment at the global
15s add up in the app's access logs. At 60s, `for: 10m` still means ten failed
probes before the alert.

## Common gotchas

- **Probe shows DOWN with `connection refused` / `timeout`** — target URL
  isn't reachable from the monitoring host's network. Test with `curl` from
  the monitoring host itself.
- **Probe shows DOWN with `SSL certificate problem`** — cert is
  self-signed, expired, or hostname mismatch. Legitimate signal if the
  cert really is bad; if you want to allow self-signed for internal URLs,
  add `tls_config: {insecure_skip_verify: true}` in a custom module in
  `blackbox/blackbox.yml` (as `http_2xx_insecure` does).
- **`SSLCertExpiringSoon` fires when the cert is fine** — probably a chain
  issue (an intermediate cert closer to expiry than the leaf). Renew the
  full chain, not just the leaf.
- **The `module: xyz` label isn't picking up** — verify the module exists
  in `blackbox/blackbox.yml`. Add new modules there if needed.
