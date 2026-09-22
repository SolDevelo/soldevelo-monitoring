# Silences during deploys

A planned deploy looks exactly like an outage: containers stop, scrapes fail,
series disappear. Tuning `for:` durations until deploys stop alerting is the
wrong fix — it delays real detection to accommodate a *known*, *scheduled*
event. Silence the window instead.

## From a deploy pipeline

Wrap the deploy. `amtool` ships in the Alertmanager image, so no host install
is needed:

```sh
AM=http://localhost:9093   # loopback-only: run on the monitoring host, or ssh -L 9093:localhost:9093

# before the deploy
SILENCE_ID=$(docker run --rm --entrypoint amtool prom/alertmanager:v0.27.0 \
  --alertmanager.url="$AM" silence add \
  --duration=30m --author="$BUILD_USER" --comment="deploy $BUILD_TAG" \
  deployment=acme environment=prod)

# ... deploy ...

# after it verifies healthy — don't wait out the 30m
docker run --rm --entrypoint amtool prom/alertmanager:v0.27.0 \
  --alertmanager.url="$AM" silence expire "$SILENCE_ID"
```

Scope the matchers as narrowly as the deploy: `deployment` + `environment` for
a full-stack deploy, plus `service=~"reports|requisition"` when only some
services are being replaced. A silence that covers more than the deploy hides
unrelated failures for its whole duration.

Always set a duration. An open-ended silence is how a stack ends up quietly
unmonitored for months.

## By hand

```sh
amtool --alertmanager.url=$AM silence add deployment=acme environment=uat \
  --duration=2h --comment="RDS restore"
amtool --alertmanager.url=$AM silence query
amtool --alertmanager.url=$AM silence expire <id>
```

Or in Grafana / the Alertmanager UI at `<MONITORING_SITE>` → Alerting →
Silences.

## What not to silence

`Watchdog` — silencing it stops the heartbeat, which the external service reads
as "the monitoring stack is dead". If a deploy touches the monitoring host
itself, pause the check at the heartbeat provider instead. See
[dead-man-switch.md](dead-man-switch.md).
