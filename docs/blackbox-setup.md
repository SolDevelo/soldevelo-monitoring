# Configuring HTTP probes (Blackbox)

Blackbox probes are the "is this URL alive?" check. They hit each target
URL from the monitoring host and record success, latency, and SSL cert
expiry. Configure by dropping JSON files in `prometheus/targets/blackbox/`.

## Format

`prometheus/targets/blackbox/malawi.json`:
```json
[
  {
    "targets": [
      "https://openlmis.example.mw",
      "https://openlmis.example.mw/api/health",
      "https://reporting.example.mw"
    ],
    "labels": {
      "app": "openlmis",
      "deployment": "malawi",
      "environment": "production"
    }
  },
  {
    "targets": [
      "https://uat.openlmis.example.mw",
      "https://uat.openlmis.example.mw/api/health"
    ],
    "labels": {
      "app": "openlmis",
      "deployment": "malawi",
      "environment": "uat"
    }
  }
]
```

Each entry's `labels` apply to all URLs in that entry's `targets` list.
Multiple entries let you tag different URLs with different labels. The
`instance` label on the resulting metrics is set to the URL itself. Tag
probes with the `app` / `deployment` they belong to so probe results line up
with that deployment's other metrics — e.g. probing the `ilo` deployment's
public endpoints would use `app: cfp-classifier`, `deployment: ilo`.

Prometheus hot-reloads within 30 seconds. Verify at
`http://<monitor>:9090/targets` — the `blackbox_http` job lists every URL,
each with `UP` / `DOWN` status.

## What you get, automatically

- **HTTP probes dashboard** — probe success status per URL, request
  duration, SSL certificate days remaining.
- **Alerts** — `ProbeFailing` (2m of non-2xx), `ProbeSlow` (>3s for 5m),
  `SSLCertExpiringSoon` (<14 days) — fire on any newly-added URL.

## Probing behaviour

The default module is `http_2xx`: GET the URL, follow redirects, expect a
2xx response. That's what the shipped scrape config uses. If you need
different behaviour (POST, custom headers, allow non-2xx, HTTPS-required,
TCP-only, etc.), `blackbox/blackbox.yml` defines several modules:

- `http_2xx` — the default. GET, follow redirects, 2xx expected.
- `http_2xx_post` — POST instead of GET.
- `tcp_connect` — TCP handshake only, no HTTP.
- `icmp` — ping (needs the container to run with cap_net_raw).

To use a non-default module, add a `module` label to the target entry.
It's picked up by the scrape config's relabel rules:

```json
[
  {
    "targets": ["tcp://redis.example.com:6379"],
    "labels": {
      "app": "openlmis",
      "deployment": "malawi",
      "environment": "production",
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

## Common gotchas

- **Probe shows DOWN with `connection refused` / `timeout`** — target URL
  isn't reachable from the monitoring host's network. Test with `curl` from
  the monitoring host itself.
- **Probe shows DOWN with `SSL certificate problem`** — cert is
  self-signed, expired, or hostname mismatch. Legitimate signal if the
  cert really is bad; if you want to allow self-signed for internal URLs,
  add `fail_if_ssl: false` in a custom module in `blackbox/blackbox.yml`.
- **`SSLCertExpiringSoon` fires when the cert is fine** — probably a chain
  issue (an intermediate cert closer to expiry than the leaf). Renew the
  full chain, not just the leaf.
- **The `module: xyz` label isn't picking up** — verify the module exists
  in `blackbox/blackbox.yml`. Add new modules there if needed.
