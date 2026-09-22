# Dead man's switch

A monitoring stack cannot alert on its own death. If the monitoring host powers
off, fills its disk, loses egress, or has its Slack webhook revoked, every
alert it would have sent dies with it — and the failure mode is *silence*,
which is indistinguishable from healthy.

`prometheus-meta` does not solve this. It's a container on the same host, the
same disk, behind the same Caddy, and its alerts travel through the very
Alertmanager whose failure it would report. It catches "the Prometheus
container crashed"; it cannot catch anything that kills the host.

The answer is inverted: an alert that **always fires**, pushed continuously to
a service outside this infrastructure, which alerts you when the beat stops.

## How it works

`Watchdog` (`expr: vector(1)`, in both `prometheus/rules/watchdog.yml` and
`prometheus/rules_meta/meta_rules.yml`) fires permanently. Alertmanager routes
it — first, before the environment routes, so nothing can swallow it — to a
webhook receiver that POSTs to an external heartbeat endpoint every 5 minutes.
That external service is configured to notify you if it stops hearing from us.

Two rule files means two independent beats: the heartbeat survives the main
Prometheus dying.

## Setup

1. Create a check on any heartbeat service — [Healthchecks.io][hc] (free tier
   is enough), Dead Man's Snitch, Better Stack, or a PagerDuty heartbeat.
2. Set its **grace period to ~15 minutes** (three missed 5-minute beats).
3. Point its alert at whoever answers out-of-hours — this is the one alert that
   cannot arrive through the normal Slack channel, because that channel is
   downstream of the thing being checked.
4. In `.env`:

   ```sh
   WATCHDOG_RECEIVER=heartbeat
   HEARTBEAT_URL=https://hc-ping.com/<your-uuid>
   ```

5. Render and recreate:

   ```sh
   bin/render-configs.sh .env
   docker compose --env-file .env -f stack/docker-compose.yml up -d --force-recreate alertmanager
   ```

6. Verify — the heartbeat service should show a ping within 5 minutes:

   ```sh
   docker run --rm --network host --entrypoint amtool prom/alertmanager:v0.27.0 \
     --alertmanager.url=http://localhost:9093 config routes test alertname=Watchdog
   # expect: heartbeat
   ```

## Until it's configured

`WATCHDOG_RECEIVER` defaults to `heartbeat-disabled`, a receiver with no
notifier. The Watchdog alert still fires and is visible in Alertmanager; it just
goes nowhere. That is deliberate — an unconfigured deployment gets no delivery
failures and no noise, but also **no dead man's switch**. Until you complete the
setup above, the stack's own death is undetectable.

## Testing it

Stop Alertmanager and confirm the external service notifies you within its
grace period:

```sh
docker compose --env-file .env -f stack/docker-compose.yml stop alertmanager
# wait out the grace period, confirm you were notified, then:
docker compose --env-file .env -f stack/docker-compose.yml start alertmanager
```

An untested dead man's switch is not a dead man's switch. Test it once at
deployment, and again whenever the heartbeat provider or the egress path
changes.

[hc]: https://healthchecks.io/
