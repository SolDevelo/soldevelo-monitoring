# Changelog

All notable changes to `soldevelo-monitoring` are documented here. Format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning
follows [semver](https://semver.org/).

## [Unreleased]

## [0.6.1] — 2026-09-23

### Fixed
- **JVM series no longer carry an app-emitted `environment` label.** Spring
  apps stamp `environment="production"` on every series as a Micrometer common
  tag, and remote_write `external_labels` never overwrite a label already
  present — so those series bypassed the enum, the Alertmanager routing and
  every `environment=prod` dashboard filter. Both agents now drop `app` /
  `deployment` / `environment` / `host` from `job="app"` series before pushing
  (`prometheus.relabel` between the scrape and remote_write); the agent's
  values are re-attached as before. `service` / `instance` are untouched.
  Upgrade note: redeploy the agents together with the stack — until an agent
  is on 0.6.1 its JVM series keep the app's value, and picking `prod` in the
  dashboards' `environment` variable blanks the JVM panels.
- **JVM and Python dashboards' logs panel returns logs again.** Its Loki
  selector took `$environment` from JVM series (`production`) while Loki
  streams carry `prod`. The variable now reads `up{job="app"}`, which only the
  agent labels, so the picker shows enum values only and the logs panel's
  `environment` matcher agrees with Loki. The filter stays: one deployment can
  span environments (UAT and prod on one `deployment`), so dropping it would
  mix their logs.
- **Host overview network panel shows traffic.** `rate(...[1m])` on a 60s
  node scrape never spanned two samples. Now `$__rate_interval`, and the
  Prometheus datasource declares `timeInterval: 60s` (the slowest collector)
  so that interval is at least 4m — without it Grafana assumes 15s and the
  window would still be 60s. Side effect: Prometheus panels step at ≥ 60s.
- **RabbitMQ dashboard counts only the broker.** `rabbitmq_connections` and
  the other `rabbitmq_*` names are also emitted by Spring's Micrometer
  RabbitMQ binder, so "Active connections" summed the apps' client-side
  gauges into the exporter's. Every query is now scoped to
  `service="rabbitmq"` — the `monitoring.service` value `rabbitmq-setup.md`
  already required for `RabbitMQDown`.
- **Containers dashboard logs picker filters logs.** The `container`
  variable listed cAdvisor names (`prod_env_referencedata_1`) while Loki's
  `container` label is the compose service name (`referencedata`), so every
  specific selection returned no logs (same defect as 0.5.1 fixed for the JVM
  / Python dashboards). Values now come from Loki; the metric panels match the
  same names through `container_label_com_docker_compose_service`, so one
  picker drives both. "All" still shows non-compose containers' metrics.
- **Stats read `0` instead of blank when the counted thing has never
  happened**: JVM "GC overhead" (no GC pause yet — Micrometer registers the
  timer lazily) and both lines of "HTTP error rate (%)" (no 5xx / 4xx ever),
  RabbitMQ "Total messages" and "Consumers" (no queues yet), Containers
  "Containers seen recently". `OR vector(0)`, as the alerts / home stats
  already did. Time-series panels grouped by label are unchanged.
- **JVM HTTP latency panel has data on Spring Boot defaults.** Spring exports
  no `http_server_requests_seconds_bucket` unless
  `management.metrics.distribution.percentiles-histogram.http.server.requests=true`,
  so the p50 / p95 / p99 lines were empty and `HttpLatencyP95High` could never
  fire. The panel gains a `max, no histogram` line from `_max`;
  `java-app-setup.md` documents the property (with its cardinality cost) and
  the rule carries the caveat. The rule itself is unchanged.
- **`ContainerAbsent` / `ServiceAbsent` no longer fire for every container or
  service when the agent's label set changes.** Both cancelled the 2h lookback
  with `unless` on the full aggregation set, so series pushed before 0.6.0
  (no `environment`) could not be cancelled by the current ones — 22 false
  positives on one upgrade. They now cancel on identity only (`unless on
  (host, name)` / `on (host, service, instance)`) and keep the routing labels.
  Pinned by two new unit tests that reproduce the cutover.
- **`bin/validate.sh` runs with a stack-only `.env`.** The Kubernetes step
  required `ALLOY_VERSION`, an agent-side variable a monitoring host's `.env`
  never has. It now falls back to the pin in `.env.example` and prints which
  source it used.

## [0.6.0] — 2026-09-23

### Added
- **Kubernetes agent** (`agents-alloy/kubernetes/`, `docs/kubernetes-setup.md`):
  plain manifests — namespace, least-privilege RBAC, Alloy Deployment with the
  config in a ConfigMap, kube-state-metrics — for one Alloy per cluster. It
  scrapes pods annotated `prometheus.io/scrape` as `job="app"` (`service`
  from the pod's `app` label or a `monitoring.service` annotation, `instance`
  = pod name), kube-state-metrics under the new collector kind
  `job="kube-state"`, tails every pod's logs through the API, and pins the
  heartbeat `instance` to `TARGET_NAME` so `AgentAbsent` survives a rollout.
  Identity and endpoints come from the same variables as the docker agent's
  `.env`, via a ConfigMap plus a Secret. No node / cAdvisor metrics on
  Kubernetes: the host / containers dashboards are docker-shaped.
- **CI**: `bin/validate.sh` runs in GitHub Actions on every push and PR, and
  gains a step that kubeconforms the Kubernetes manifests and parses the
  ConfigMap's Alloy config.

### Changed
- **Stack ports are loopback-only** (behaviour change). Prometheus 9090,
  Prometheus-meta 9091, Loki 3100, Alertmanager 9093, Blackbox 9115 and Grafana
  3000 now publish on `127.0.0.1`. The remote-write receiver and Loki's push
  endpoint have no auth of their own — Caddy's bearer gate on `/ingest/*` was
  always the intended path, but on a host with a public interface the raw
  ports were open beside it. Anything that scraped or pushed to `<host>:9090`
  / `:3100` directly stops working; point it at `/ingest/*`. From the host,
  `curl localhost:9090` and SSH tunnels work as before. node-exporter (`:9101`,
  host network) is the one port left non-loopback — firewall it.
- **Caddy ports are published 1:1**, so `CADDY_HTTP_PORT=8080` actually works.
  Host 8080 used to map to container port 80, but Caddy listens on the port in
  `MONITORING_SITE` (`http://localhost:8080` → `:8080`), so nothing answered on
  either side. The port in `MONITORING_SITE` must now equal the matching
  `CADDY_*_PORT`; the README's remap recipe says so.
- **The agent joins the app network through `APP_NETWORK`** instead of a
  network name hardcoded in `agents-alloy/docker-compose.yml`. Existing agent
  `.env` files must add `APP_NETWORK=<the app stack's compose network>` before
  the next `up -d`, or compose refuses to start the agent (`docker network ls`
  shows the name). `ENVIRONMENT` and `APP_NETWORK` are now in every agent
  quickstart.
- **Example values neutralised for public release.** `monitoring.example.com`,
  `myapp` / `acme` / `globex` replace the original deployments' names in
  `.env.example`, docs and tests, and the home dashboard no longer calls the
  package "internal tooling". Label semantics are unchanged.

### Fixed
- **A plain-HTTP site address no longer host-matches.** Caddy served
  `http://localhost:8080` as a named site, so a push whose Host header was
  anything else (`host.docker.internal`, an IP) hit Caddy's default empty 200
  — the bearer gate was never consulted, Loki and Prometheus never saw the
  data, and the agent logged success. `bin/render-configs.sh` now renders the
  `http://` forms as a bare `:<port>`, which serves any Host; the TLS forms keep
  the hostname (it is what the certificate is issued for), so agents must use
  exactly that name — a wrong one fails TLS loudly instead of silently.
- **Agent compose ships the `host.docker.internal` alias**, so the
  single-machine recipe in the README works on Linux Docker — previously the
  README claimed the alias and the agent's every push failed at DNS.
- **`.env.example` no longer defines `INGEST_TOKEN` twice.** The agent section
  repeated it with the placeholder; `render-configs.sh` sources the file, so the
  last assignment won and an operator who set the stack-side one got Caddy
  baked with the public repo's placeholder as its bearer token.
  `render-configs.sh` now warns when `INGEST_TOKEN` or `GRAFANA_ADMIN_PASSWORD`
  is still a placeholder.
- **`bin/validate.sh` restores the rendered configs after the gate.** It
  renders from `.env.example` by default, which used to overwrite the live
  `Caddyfile`, `prometheus*.yml` and `alertmanager.yml` with example values on
  whatever host it ran — armed for the next `--force-recreate`.
- **Loki ruler posts to Alertmanager's v2 API** (`enable_alertmanager_v2:
  true`). Alertmanager 0.28 removed the v1 API, so a version bump would have
  silently killed every log alert (`ErrorLogsSpike`, the `Jvm*` log rules) —
  the ruler logs an error and nothing reaches Slack. `bin/validate.sh` now
  fails if the flag goes missing.
- **README alert list matches the rule files.** It named `ContainerNotSeen`
  (replaced by `ContainerAbsent` in 0.5.0) and `JvmScrapeDown` (removed in
  0.5.0), and omitted `ServiceDown`, `ServiceAbsent`, `AppDown`,
  `PublicUrlUnreachable`, `Watchdog` and the three meta notification-pipeline
  alerts. `AgentAbsent`'s place in the overlay, and why skipping it produces
  an alert storm, is now stated there too. The README also claimed Grafana's
  direct port was 3001 and recommended firewalling 9090/9093 by hand; the
  loopback binding above replaces both.
- **Docs examples fixed.** Blackbox examples used `environment: production`,
  which is off-enum and rejected by the gate; `tcp_connect` targets are
  `host:port` without a `tcp://` scheme; `Watchdog` lives in
  `prometheus/rules/watchdog.yml`, not `service_rules.yml`; the dead-man-switch
  `amtool` check runs through the Alertmanager image like `silences.md` does;
  `metrics.md` described `container_last_seen` in terms of the alert that could
  never fire.
- **"Container(s) for logs" now actually filters logs on the JVM and Python
  dashboards.** The variable was populated from cAdvisor's `name`
  (`prod_env_referencedata_1`) while the logs panel matched Loki's `container`
  label, which the agent sets from the compose service name
  (`referencedata`) — so every specific selection returned nothing. Only "All"
  worked, and only by accident: its `.*$service.*` regex substring-matches the
  service name. The variable now reads its values from Loki, so both
  vocabularies are the same one. The logs panel also gained
  `app`/`deployment`/`environment` matchers; without them "All" mixed UAT and
  prod logs into one stream.
- **Stack container logs are capped at 50 MB × 3 per service.** Docker's
  `json-file` default is unlimited, and the stack set no `logging:` at all, so
  every service grew a log file forever — measured at ~24 MB/day for Loki and
  ~6.7 MB/day for cAdvisor, 630 MB total on a host with a 29 GB root volume. A
  monitoring stack that fills its own disk takes the disk alerting down with it,
  so there is nothing left to report the outage. Applies on container re-create,
  not restart: Docker fixes a container's log options when it is created, so
  existing containers keep growing until the next `up --force-recreate`.
- **Agent container logs are capped at 50 MB × 7.** Larger than the stack's
  allowance because agents run on app hosts, which have the bigger disks. An
  ENOSPC on an agent host is worse than lost logs: it tears the metrics WAL
  mid-record, and Alloy then loops on the torn segment (`unexpected full
  record`) instead of pushing, which a restart does not clear — the WAL has to
  be dropped by hand. Same re-create caveat as above.

## [0.5.1] — 2026-08-26

### Added
- **Uptime % panel on the HTTP probes dashboard.** Reads
  `avg_over_time(probe_success[$__range])`, so the number follows the time
  picker instead of being pinned to a fixed window — "Last 3 hours" reports 3h
  of uptime, "Last 30 days" reports 30d. Instant query evaluated at the range
  end, which is what makes `$__range` line up with the selected window.
  Gaps average out rather than counting as downtime, so an outage of the
  monitoring stack itself doesn't score against the probed service.

### Fixed
- **`ContainerAbsent` no longer alerts on ephemeral containers.** A bare
  `docker run` gets a fresh random name each time, so each one became a new
  series that fired once and never resolved — seven such alerts in two hours on
  one deployment, all deploy helpers. Scoped to compose-managed containers
  (`com.docker.compose.project` present, `oneoff` not `True`), which also
  covers `docker-compose run`. Pinned by a unit test.

## [0.5.0] — 2026-08-17

### Fixed
- **Service-down alerting works again.** Four alerts had been dead since the
  move from pull to push: `InstanceDown`, `JvmScrapeDown`, `JenkinsDown` and
  `RabbitMQDown` selected on `job` values (`node`, `java`, `jenkins`,
  `rabbitmq`) that Alloy never produces — it labels its own component names
  (`prometheus.scrape.app`, `integrations/unix`). The agent now pins `job` to
  the collector kind (`app` / `node` / `cadvisor` / `agent`), which is the
  contract the rules key on. Service identity stays in `service`, so
  `JenkinsDown` is `up{job="app", service="jenkins"}`. Two stale `job`
  selectors in the Jenkins and Home dashboards fixed with it.
- **`ContainerNotSeen` could never fire**, and is replaced by `ContainerAbsent`.
  cAdvisor drops a container's series on removal rather than letting the value
  age, so `time() - container_last_seen > 300` had nothing to evaluate
  (observed staleness peaks around 60s). The replacement detects absence, and
  aggregates away `id` / `image` — Docker mints a new container id on every
  recreate, so keeping them would have fired for the whole lookback window on
  every redeploy. Pinned by a unit test.
- **The agent never set `environment`.** Every rule aggregates by it and
  Alertmanager routes on it, so any deployment using the stock agent config
  produced alerts that matched neither the prod route nor the dev mute and fell
  through to the default receiver. Now set from `ENVIRONMENT` on both metrics
  and logs.
- **`environment` enum was documented as `production`/`staging`/`dev` while
  Alertmanager routed on `prod`.** Standardised on `prod` / `uat` / `staging` /
  `dev`, and `bin/validate.sh` now enforces it. Deployments whose targets
  carry `environment="production"` must be updated or their prod alerts keep
  falling through.
- `agents-alloy` sets `hostname: ${TARGET_NAME}`, so the agent's own exporter
  targets get a stable `instance`. Without it the container id was used, and
  recreating the agent orphaned every series it produced.
- Alert rules now aggregate `by (app, deployment, environment, …)`. Rules that
  aggregated `by (service, host)` (JVM, HTTP RED, PostgreSQL, host CPU,
  container restarts, all log rules) emitted alerts with no `environment`
  label, so environment routing could not match them: production alerts fell
  through to the default receiver and `environment="dev"` alerts were never
  muted. `deployment` also reaches the Slack title now.

### Added
- **Absence detection for a push model.** When an agent stops pushing, its
  series don't go to zero — they stop existing, and an expression with no
  series never fires. Three new rules cover the split: `ServiceDown`
  (`up == 0`, the target is scraped but failing), `ServiceAbsent` (scraped
  within the last 2h and no longer), and `AgentAbsent` (the host stopped
  reporting at all). `AgentAbsent` is driven by an explicit per-deployment host
  inventory under `prometheus/rules/overlay/` rather than inferred from
  history, so it also catches a host that never came up. `JvmScrapeDown` is
  gone — `ServiceDown` covers every pushed target, JVM or not.
- **Dead man's switch.** An always-firing `Watchdog` alert, routed first so
  nothing can swallow it, POSTed to an external heartbeat service that notifies
  when the beat stops. This is the only way to detect that the monitoring host,
  its disk, or its egress died — `prometheus-meta` shares all three and dies
  with them. Inert until `WATCHDOG_RECEIVER` / `HEARTBEAT_URL` are set; see
  `docs/dead-man-switch.md`.
- **Alerting-pipeline health** in `prometheus-meta`:
  `AlertmanagerNotificationsFailing` (alerts fire but delivery fails — looks
  exactly like quiet), `PrometheusNotificationsDropped`, and
  `PrometheusRuleEvaluationFailing` (a rule that fails to evaluate is skipped
  silently forever).
- **Severity now changes cadence.** Both severities still land in the same
  channel, but `critical` notifies in 10s and repeats every 4h while `warning`
  batches for 1m and repeats daily. Previously the labels differed and nothing
  downstream acted on them.
- **Alertmanager inhibit rules** (there were none): `AgentAbsent` suppresses the
  per-service and per-container alerts for the same host, so one dead agent
  pages once instead of a dozen times naming the wrong problem; `ServiceDown`
  suppresses the component-specific down alerts; and a critical alert suppresses
  its own warning form.
- `bin/validate.sh` gains three gates: `amtool config routes test` assertions
  (a route matcher is a literal string match — a drifted `environment` value
  silently redirects alerts and looks identical to working), an `environment`
  enum check, and `promtool test rules` unit tests for the absence rules.
- `docs/dead-man-switch.md`, `docs/silences.md` (silence deploy windows rather
  than tuning `for:` durations around them), and a `job`-contract section in
  `docs/metrics.md`.
- Slack templates render `runbook_url` when an alert carries one.
- Blackbox: per-target `module` override via a `module` label in the target JSON
  (wires up the behaviour `docs/blackbox-setup.md` already described), and an
  `http_2xx_insecure` module for DNS-independent "is the app up" probes by
  IP / load-balancer DNS (no redirect-follow, no cert-name verify).
- Blackbox alerts `AppDown` (app-direct probe down = the application itself) and
  `PublicUrlUnreachable` (public probe down while the app-direct probe is up =
  DNS/edge issue, not an app outage), keyed on a `check` label. `ProbeFailing`
  now scopes to untagged probes so it doesn't double-fire with these.
- Alertmanager: alerts labelled `environment="prod"` route to their own
  `slack-prod` receiver, configured with the optional `SLACK_WEBHOOK_URL_PROD` /
  `SLACK_CHANNEL_PROD`. Both fall back to `SLACK_WEBHOOK_URL` / `SLACK_CHANNEL`,
  so deployments that want one channel for everything need no change.
- Alertmanager: alerts labelled `environment="dev"` route to a null receiver —
  dev environments are collected but not notified. Overridable by pointing that
  route at the `slack` receiver.
- Dashboards: an `environment` template variable (UAT/Prod filter) on the JVM,
  Python, PostgreSQL, Host, Containers, and HTTP-probes dashboards. Defaults to
  All and matches series with or without an `environment` label, so single-
  environment deployments are unaffected.

## [0.4.0] — 2026-07-31

Push-based collection built on Grafana Alloy, with a label taxonomy that lets
one monitoring instance serve many applications and many deployments of the
same application. Proven on two live deployments (docker + AWS EKS).

### Added
- **Alloy push agents.** Each target host/cluster runs one Grafana Alloy agent
  (`agents-alloy/` for docker, in-cluster for Kubernetes) that discovers its
  workloads — docker compose `monitoring.*` labels or k8s `prometheus.io/*`
  annotations — collects host + container + application metrics and all
  container logs, and pushes them to the monitoring host. No target lists on the
  monitor; targets need no inbound ports, only outbound HTTPS.
- **Ingest endpoints.** Prometheus enables `--web.enable-remote-write-receiver`;
  Caddy exposes bearer-gated `/ingest/prometheus/api/v1/write` and
  `/ingest/loki/loki/api/v1/push` on `MONITORING_SITE` (9090 / 3100 stay off the
  public internet). New `INGEST_TOKEN`. Runbooks: `docs/remote-push-setup.md`
  (receiver), `agents-alloy/README.md` (agent).
- **`app` / `deployment` / `service` / `host` / `instance` taxonomy** — a series
  is unique on (`app`, `deployment`, `service`, `instance`), so multiple apps
  and multiple deployments of one app never collide. Dashboards gain an
  `app → deployment → service → instance` variable cascade; Alertmanager labels
  every alert with its `deployment`. Contract in `docs/metrics.md`; all setup
  guides and the README rewritten around the model.

### Changed
- The only Prometheus scrape jobs are Prometheus itself and the blackbox HTTP
  probes; all app / host / container metrics arrive via remote_write. Alert
  rules and dashboards are label-driven and model-agnostic.

## [0.3.0] — 2026-07-07

Preparation release for the OpenLMIS Malawi rollout (second adopter).
Normalizes target configuration across all scrape jobs so multi-host,
multi-environment deployments are first-class instead of a copy-paste
workaround. Adds HTTP RED metrics, HikariCP pool monitoring, PostgreSQL
replication lag, and a Jenkins component — all needed for parity with the
current Malawi CloudWatch + DataSet coverage. Also folds a review-pass
sweep on alert descriptions, dashboard defaults, and setup docs.

### ⚠️ Breaking changes — migration from 0.2.x

**All target configuration now uses file_sd JSON files. The old
env-var-based single-target model is gone.** Affected variables in `.env`:

- Removed (stack side): `TARGET_HOST`, `TARGET_NAME` (still used on the
  agents side — see below), `BLACKBOX_PROBE_TARGETS`.
- Kept (agents side only): `TARGET_NAME`, `TARGET_NODE_EXPORTER_PORT`,
  `TARGET_CADVISOR_PORT`. Agents' Promtail still uses `TARGET_NAME` as the
  `host` label on log streams.

**Migration steps for 0.2.x users:**

1. Delete `TARGET_HOST`, `TARGET_NAME` (stack side), and
   `BLACKBOX_PROBE_TARGETS` from the monitoring host's `.env`.
2. Create paired target files under `prometheus/targets/nodes/` and
   `prometheus/targets/cadvisor/` — one entry per host, using the same
   `host` label you had as `TARGET_NAME`. See `docs/host-setup.md`.
3. Move the URLs from your old `BLACKBOX_PROBE_TARGETS` array into
   `prometheus/targets/blackbox/<project>.json`. See `docs/blackbox-setup.md`.
4. `bin/render-configs.sh && docker compose -f stack/docker-compose.yml up
   -d --force-recreate prometheus`.

Existing `prometheus/targets/java/`, `python/`, `rabbitmq/`, `postgresql/`
files continue to work unchanged.

### Added

- **`nodes/`, `cadvisor/`, `blackbox/`, `jenkins/` target directories** —
  every scrape job now uses the same file_sd pattern. Adding a host, a
  probe URL, or a Jenkins server is a JSON entry, not a base-file edit.
- **HTTP RED metrics for Spring Boot services** — three new alerts
  (`HttpServerErrorRateHigh` at 1% 5xx for 5m, `HttpClientErrorRateHigh`
  at 5% 4xx for 10m, `HttpLatencyP95High` at 2s for 5m). Three new panels
  on the JVM Application dashboard covering request rate by outcome,
  error rate %, and p50/p95/p99 latency. Zero code changes required on
  the app side — Micrometer auto-collects `http_server_requests_seconds`
  once `spring-boot-starter-actuator` + web starter is on the classpath.
- **HikariCP connection pool monitoring** — new `HikariCPPoolExhausted`
  alert on `hikaricp_connections_pending > 0 for 2m` (the definitive
  signal that requests are queuing for a DB connection). Two new panels
  on the JVM Application dashboard: active/idle/max connections and
  pending count. Also auto-collected by Spring Boot Actuator when HikariCP
  is the connection pool (default in modern Spring Boot).
- **PostgreSQL replication lag** — new `PostgreSQLReplicationLag` alert
  (`pg_replication_lag > 900s` for 5m) and dashboard panel with staged
  thresholds. Matches the Malawi Tableau replica-lag alarm shape. Requires
  `postgres_exporter`'s replication collector, pointed at the primary.
- **Jenkins component** — new `jenkins` scrape job, dashboard
  (`grafana/dashboards/jenkins.json`), four alert rules (`JenkinsDown`,
  `JenkinsHealthCheckFailed`, `JenkinsQueueBacklog`,
  `JenkinsExecutorSaturated`), and setup guide (`docs/jenkins-setup.md`)
  covering the Jenkins Prometheus plugin.
- **Two new setup docs**: `docs/host-setup.md` (onboarding a target host
  with paired nodes/cadvisor JSON files) and `docs/blackbox-setup.md`
  (HTTP probe target configuration).

### Changed

- `.env.example` reorganised into explicit "STACK SIDE" and "AGENTS SIDE"
  sections, since the two sides now have meaningfully different variable
  sets after the file_sd normalization.
- **Alert descriptions homogenized to a terse style.** All rule files
  match the pattern in `host_rules.yml`: `summary` is a short label with
  the threshold; `description` is a single factual sentence. Removed
  embedded remediation prose (a future release will add `runbook_url`
  annotations pointing to per-alert runbooks; descriptions no longer need
  to duplicate that content). Affects `jvm_rules.yml`, `postgresql_rules.yml`,
  `container_rules.yml`, `jenkins_rules.yml`, `rabbitmq_rules.yml`,
  `host_rules.yml` (HostOOMKill), and Loki `loki_rules.yaml`.
- **Dashboard default time ranges normalized to `now-3h`.** The four
  dashboards that were on `now-6h` (`alerts.json`, `blackbox.json`,
  `home.json`, `jenkins.json`) now match the rest.
- **Setup docs trimmed.** `docs/java-app-setup.md` and
  `docs/python-app-setup.md` dropped the "optional but recommended"
  digressions and reduced "common gotchas" to the top three per doc.

### Fixed

- **`RabbitMQDown` never fired.** The rule expression was
  `rabbitmq_identity_info == 0`, but when RabbitMQ is unreachable the
  metric is absent rather than zero. Corrected to `up{job="rabbitmq"} == 0`,
  matching `PostgreSQLDown` / `JenkinsDown` / `InstanceDown`.
- **`.env.example` — `TARGET_NAME` comment corrected.** The old comment
  claimed Promtail relabels metric-side `host` labels using `TARGET_NAME`;
  it doesn't. `TARGET_NAME` is only used by Promtail as the `host` label
  on log streams. Metric-side `host` labels come from the target JSON
  files on the monitoring host.

## [0.2.0] — 2026-06-11

First feedback-driven release, informed by real production use of `0.1.x`
against an internal SolDevelo tool. The package caught a real memory leak
(which was fixed), and running with real workloads surfaced concrete
usability gaps and new coverage needs. This release addresses them.

### Added

- **Python application dashboard + setup guide.** New `python` scrape job
  (file_sd via `prometheus/targets/python/*.json`), dashboard
  (`grafana/dashboards/python.json`) covering process memory / CPU / FDs /
  GC + optional HTTP RED panels + business-metrics section + logs. Full
  onboarding walkthrough in `docs/python-app-setup.md` including framework
  instrumentors (Flask / FastAPI / Django), multiproc-mode gotcha, and
  target-file examples.
- **RabbitMQ component** — new `rabbitmq` scrape job (file_sd via
  `prometheus/targets/rabbitmq/*.json`), dashboard (`rabbitmq.json`),
  alert rules (`rabbitmq_rules.yml`: `RabbitMQDown`, `RabbitMQNoConsumers`,
  `RabbitMQQueueBacklog`, `RabbitMQDiskLow`). Setup guide in
  `docs/rabbitmq-setup.md` covers the RabbitMQ 3.8+ built-in Prometheus
  plugin (no sidecar exporter needed).
- **PostgreSQL component** — new `postgresql` scrape job (file_sd),
  dashboard, alert rules (`postgresql_rules.yml`: `PostgreSQLDown`,
  `PostgreSQLTooManyConnections`, `PostgreSQLLowCacheHitRatio`,
  `PostgreSQLDeadlocks`). Setup guide in `docs/postgresql-setup.md` covers
  `postgres_exporter` deployment with `pg_monitor` role.
- **Logs panel on JVM Application dashboard.** New container-picker
  template variable that lists containers whose name matches the selected
  service. Kills the "keep switching between Containers and JVM dashboards"
  papercut that came up in first-project use.
- **Business-metrics convention doc** (`docs/business-metrics.md`) — naming
  rules, required labels, per-language exposure examples (Micrometer +
  prometheus_client), where they live per-project vs in the base package,
  and dashboard integration. Fills the last of the five deliverables named
  in `IDEAS.md`.

### Changed

- **`ContainerHighMemoryVsLimit` alarm — `for:` extended from 5m to 15m.**
  Was flapping when memory oscillated around the 90% threshold — firing,
  resolving, and re-firing every ~10 min. Longer window means the alarm
  only fires on sustained pressure, not on brief crossings. Fix per the
  "flapping is a rule-tuning problem, not an alerting-system problem"
  principle — no exotic backoff logic needed.

### Package structure

- Component pattern established: each stack component (RabbitMQ, PostgreSQL;
  future: Redis, Nginx, Kafka, etc.) contributes a file_sd targets dir, a
  scrape job in `prometheus.yml.template`, a dashboard, a rules file, and a
  setup doc. Consistent structure makes adding the next component a
  copy-paste operation rather than bespoke design.

## [0.1.1] — 2026-05-14

Post-`0.1.0`-first-deployment compatibility fixes — surfaced by deploying
the package to a real Ubuntu 22.04 EC2 and informed by the diagnostic
ladder that became part of the package itself.

### Fixed

- **Restrictive-umask compatibility** (e.g. CIS-benchmarked Ubuntu / RHEL
  with `umask 027`). `bin/render-configs.sh` now forces `umask 022` at the
  start (so rendered files are 644) and runs `chmod -R a+rX` on config
  directories at the end (so directories created by `git clone` under the
  restrictive umask become 755 instead of 750). Container processes running
  as `nobody` (uid 65534) or `grafana` (uid 472) can then read the
  bind-mounted configs, which they couldn't with the previous 640 / 750
  modes. Idempotent on every render.
- **SELinux compatibility** on Amazon Linux 2023 / RHEL / Fedora hosts. All
  bind-mounted config files in `stack/docker-compose.yml` and
  `agents/docker-compose.yml` now use `:ro,z`, which tells Docker to relabel
  the file to the shared container context. Without this, SELinux-enforcing
  hosts deny container processes access to bind-mounted configs with a
  generic `permission denied` even though Linux file permissions look
  correct. No-op on Ubuntu/Debian (no SELinux), required on RHEL-family.

### Docs

- README prerequisites clarified that Docker Compose v2 (the `docker compose`
  Go plugin) is required, not the legacy v1 `docker-compose` Python tool
  (EOL 2023). Includes install commands for apt and dnf families.

## [0.1.0] — 2026-05-13

First release. Internal SolDevelo use; pre-public.

### Stack

- Pre-baked monitoring host compose: Prometheus + Prometheus-meta + Loki +
  Grafana + Alertmanager + Blackbox + monitor's own node-exporter + cAdvisor.
- Pre-baked agents compose for target hosts: node-exporter + cAdvisor +
  Promtail (with Docker service discovery).
- `host.docker.internal:host-gateway` alias on Prometheus / Blackbox /
  Promtail for local-on-one-machine testing on Linux.
- `network_mode: host` on both node-exporters so the netdev / netclass
  collectors see real host interfaces, not the container's own netns.
- Promtail drops `/soldevelo-monitoring-*` containers from log scraping to
  avoid feedback loops between log-based alert rules and the ruler's own
  logs.

### Dashboards (provisioned-as-code)

- **SolDevelo Monitoring** (home) — alert counts, dashboard list, currently
  firing table. Set as the default landing page; replaces Grafana's "Welcome"
  screen.
- **Host overview** — CPU, memory, disk, per-NIC network (real interfaces
  only), load average.
- **Containers** — per-container CPU / memory / network with stacking,
  totals across the host, live Loki log panel filtered by host + container.
- **HTTP probes** — probe success, latency, SSL cert days remaining.
- **JVM application** — heap %, GC overhead, GC pause times, per-pool memory,
  threads by state, process CPU. Multi-service via variable picker.
- **Active alerts** — currently-firing and pending alerts with severity
  colour-coding and stat counts.

### Alerts (Slack-routed via Alertmanager)

- Host: `InstanceDown`, `HighCPU`, `HighMemoryUsage`, `LowDiskSpace`,
  `HostOOMKill`.
- Container: `ContainerNotSeen`, `ContainerHighMemoryVsLimit`,
  `ContainerOOMKilled`, `ContainerRestartLoop`.
- HTTP probes: `ProbeFailing`, `ProbeSlow`, `SSLCertExpiringSoon`.
- JVM: `JvmHeapPressure`, `JvmGCThrashing`, `JvmMetaspacePressure`,
  `JvmThreadGrowth`, `JvmScrapeDown`.
- Logs (Loki): `ErrorLogsSpike`, `JvmOutOfMemoryError`, `JvmGCOverheadLimit`,
  `JvmStackOverflowError`, `JvmFatalSignal`.
- Self-monitoring (via prometheus-meta): `MonitorDiskLow`,
  `PrometheusUnreachable`, `LokiUnreachable`, `AlertmanagerUnreachable`.

### Java application support

- Prometheus scrape job for Spring Boot Actuator + Micrometer
  (`/actuator/prometheus`).
- File-based service discovery (`prometheus/targets/java/*.json`) for
  multi-app deployments. Hot-reloaded every 30 s by Prometheus — no restart
  needed when adding or removing apps.
- Setup walkthrough in `docs/java-app-setup.md` including:
  - Dependencies, configuration, port publishing.
  - `-Xmx` vs container `mem_limit` alignment (recommends
    `-XX:MaxRAMPercentage=75.0`).
  - JVM launch flags for `OutOfMemoryError` forensics
    (`-XX:+HeapDumpOnOutOfMemoryError`, `-XX:+ExitOnOutOfMemoryError`).
  - Diagnostic ladder for "target is DOWN" (Spring Security 401,
    `localhost` bind address, JSON syntax, custom paths).

### Documentation

- `README.md` — architecture, quickstart, conventions, roadmap, versioning.
- `docs/metrics.md` — canonical metric catalog with required labels and the
  "what it does NOT mean" pattern. Covers node-exporter (host),
  cAdvisor (container, including OOM and network), Blackbox, JVM
  (Micrometer), and Loki log labels.
- `docs/java-app-setup.md` — Spring Boot onboarding.
- `CHANGELOG.md` — this file.

### License

- **MIT** — see `LICENSE`. Copyright © 2026 SolDevelo.

### Reverse proxy

- **Caddy** included in the stack as TLS terminator and reverse proxy in
  front of Grafana. One `MONITORING_SITE` env var controls behaviour:
  - `http://localhost` → plain HTTP, no TLS (local default).
  - `localhost` → Caddy's internal CA, self-signed TLS.
  - Real domain → free Let's Encrypt cert, auto-renewed.
- Same Caddyfile works on a laptop and on a public EC2; the only change
  between environments is the `MONITORING_SITE` value.

### Branding

- Grafana browser tab title set to "SolDevelo Monitoring" via
  `GF_DEFAULT_INSTANCE_NAME`.
- Default home dashboard set to the SolDevelo Monitoring landing page via
  `GF_USERS_DEFAULT_HOME_DASHBOARD_UID`.

### Conventions

- All scrape targets carry `host` (host slug) and where applicable
  `service` + `environment` labels.
- Metric names follow Prometheus + OpenTelemetry naming conventions:
  `snake_case`, unit suffix, `_total` for counters.
- JVM metrics labelled by `service` (Micrometer common tag) so dashboards
  port between Java services without query rewrites.
- Log-pattern alerts use FQCN (`java.lang.OutOfMemoryError`) rather than
  bare class names, to avoid recursive matching on the ruler's own logs.

### Known limitations

- No CI yet — config validation (`docker compose config`,
  `promtool check rules`) is manual.
- No Terraform module — manual VM provisioning. Planned for V2.
- Single `TARGET_HOST` in `.env`. Multi-target-host support comes when a
  second adopter (OpenLMIS Malawi) lands; will follow the same file_sd
  pattern as Java multi-app.
- Spring Boot HTTP RED dashboard (`http_server_requests_seconds`) deferred
  to a later 0.x release.
- Caddy fronts Grafana only; Prometheus and Alertmanager remain on direct
  ports without auth. Production deployments should firewall those off the
  public internet (or extend the Caddyfile with basic auth + sub-paths in a
  later release).

[Unreleased]: https://github.com/soldevelo/soldevelo-monitoring/compare/v0.6.1...HEAD
[0.6.1]: https://github.com/soldevelo/soldevelo-monitoring/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/soldevelo/soldevelo-monitoring/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/soldevelo/soldevelo-monitoring/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/soldevelo/soldevelo-monitoring/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/soldevelo/soldevelo-monitoring/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/soldevelo/soldevelo-monitoring/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/soldevelo/soldevelo-monitoring/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/soldevelo/soldevelo-monitoring/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/soldevelo/soldevelo-monitoring/releases/tag/v0.1.0
