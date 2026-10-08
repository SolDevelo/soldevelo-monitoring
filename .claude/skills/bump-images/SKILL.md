---
name: bump-images
description: Check pinned images for newer upstream releases, measure the CVE delta with Grype, and open a PR bumping the ones that improve the InfraScan result.
disable-model-invocation: true
---

# Bump image pins against InfraScan

Run by hand now and then; there is no Renovate/Dependabot here. A scheduled
scan alone repeats the same result until a pin moves, so the work is spotting
upstream releases and proving each bump with a scan.

Pins: the `*_VERSION=` lines in `.env.example`, plus the two `image:` lines in
`agents-alloy/kubernetes/` (Alloy, kube-state-metrics). Work in a worktree off
`origin/main`.

## 1. Baseline

```
gh run list -w infrascan.yml -b main -L 1
gh run view <id> --log | grep -a -A6 "GRADING SUMMARY"
```

Done when you have the Overall/Container grade and Crit/High counts from `main`.

## 2. Find newer releases

Upstream repo per pin:

| Pin | Release repo | Image |
|---|---|---|
| `PROMETHEUS_VERSION` | `prometheus/prometheus` | `prom/prometheus` |
| `ALERTMANAGER_VERSION` | `prometheus/alertmanager` | `prom/alertmanager` |
| `LOKI_VERSION` | `grafana/loki` (skip `operator/*`) | `grafana/loki` |
| `GRAFANA_VERSION` | `grafana/grafana` | `grafana/grafana` |
| `BLACKBOX_VERSION` | `prometheus/blackbox_exporter` | `prom/blackbox-exporter` |
| `CADDY_VERSION` | `caddyserver/caddy` | `caddy` |
| `NODE_EXPORTER_VERSION` | `prometheus/node_exporter` | `prom/node-exporter` |
| `CADVISOR_VERSION` | `google/cadvisor` | `ghcr.io/google/cadvisor` |
| `ALLOY_VERSION` + K8s manifest | `grafana/alloy` | `grafana/alloy` |
| K8s manifest | `kubernetes/kube-state-metrics` | `registry.k8s.io/kube-state-metrics/kube-state-metrics` |

```
gh release list -R <repo> -L 6 --json tagName,publishedAt,isPrerelease \
  -q '.[]|select(.isPrerelease|not)|"\(.tagName) \(.publishedAt[:10])"'
```

Keep each pin's variant suffix: Grafana `-ubuntu` (Alpine carries critical
OpenSSL CVEs), Caddy `-alpine`, node-exporter `-distroless`. Prometheus stays
on its LTS line and off `-distroless` (uid 65532 cannot open an existing TSDB
volume). A major version (Grafana 13, Loki 4, Prometheus 4) is the user's call:
list it, don't bump it. Done when every pin is marked current, candidate, or
major-only.

## 3. Scan current vs candidate

Prefetch the Grype DB once; parallel scans without the cache each download it
and take 10+ minutes.

```
docker volume create grypedb
docker run --rm -u root -v grypedb:/db -e GRYPE_DB_CACHE_DIR=/db \
  --entrypoint grype soldevelo/infrascan:1.2.0 db update
```

Then, for each current and candidate image (in parallel, output to a fresh
scratch dir):

```
docker run --rm -u root -v grypedb:/db -e GRYPE_DB_CACHE_DIR=/db \
  -e GRYPE_DB_AUTO_UPDATE=false --entrypoint grype soldevelo/infrascan:1.2.0 \
  registry:<image> -q -o json > <out>.json
```

Count by `matches[].vulnerability.severity`. Done when every candidate has a
before/after Critical/High/Medium/Low count; keep only candidates that improve.

## 4. Read the changelogs

For each kept candidate, read every release note between the pins
(`gh release view <tag> -R <repo>`) for breaking changes. Check each against
our config: `blackbox/blackbox.yml`, `caddy/Caddyfile.template`,
`loki/loki-config.yaml`, `prometheus/`, `alertmanager/`. Done when each
breaking change is either irrelevant to our config or fixed in this PR.

## 5. Bump and verify

- Edit the pins; `grep -rn <old-tag> --exclude-dir=.git .` for other mentions
  (CHANGELOG history stays as is).
- `cp .env.example .env && bin/render-configs.sh .env && bin/validate.sh .env`
  must end `VALIDATION PASSED`.
- `validate.sh` already checks Prometheus and Alertmanager configs with the
  pinned images. Load the others in the new binary: Blackbox `--config.check`,
  `caddy validate --adapter caddyfile` on the rendered `caddy/Caddyfile`,
  Loki `-verify-config`.
- For a behaviour change, run old and new side by side on the same input.
- Add a `### Changed` entry under `## [Unreleased]` in `CHANGELOG.md`: old →
  new per image, the CVE delta, any breaking change hosts will notice.

## 6. PR

Commit `chore(deps): bump <images>`, push, open the PR with a before/after
table. Every PR is scanned (`skip-if-no-match: false`), so read the PR run's
`GRADING SUMMARY` and add it to the description next to the baseline. Grep that
log for `Timeout scanning image` / `Could not scan image`; either means a
finding count is silently zero.

Merging and releasing are the user's: hand over
`gh pr merge <n> --rebase --delete-branch`, then the `release` skill. Hosts
pick up the images only after copying the new pins into their `.env` and
force-recreating.

## What stays

The remaining HIGH are upstream: OS packages with no fix yet (Alpine OpenSSL,
busybox), and Go dependencies compiled into the binaries (grpc, stdlib), which
only an upstream rebuild fixes. Report them per image; rebuilding upstream
images ourselves is out of scope.
