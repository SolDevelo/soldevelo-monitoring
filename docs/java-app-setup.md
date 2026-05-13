# Wiring a Java app into soldevelo-monitoring

This is what a Spring Boot application has to do to be picked up by the
package's JVM dashboard and alerts. Total work: 2 dependencies, 2 properties,
1 published port. ~10 minutes including verification.

## 1. Dependencies

**Gradle:**
```groovy
dependencies {
    implementation 'org.springframework.boot:spring-boot-starter-actuator'
    implementation 'io.micrometer:micrometer-registry-prometheus'
}
```

**Maven:**
```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>
<dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-registry-prometheus</artifactId>
</dependency>
```

Spring Boot 2.x and 3.x both work. No version pinning required — let the
Spring Boot BOM resolve them.

## 2. Configuration

In `application.properties` (or `application.yml`):

```properties
# Expose the prometheus endpoint (and health, which Blackbox probes use).
management.endpoints.web.exposure.include=health,prometheus

# Apply package-standard labels to every metric (see docs/metrics.md).
management.metrics.tags.service=cfp-scraper
management.metrics.tags.environment=production
```

Set `service` to match `JAVA_APP_NAME` in the monitoring host's `.env` —
that's how the JVM dashboard's "Service" variable resolves.

`environment` should reflect the deployment (`production` / `staging` /
`dev`). If the same artifact runs in multiple environments, set it via an
env var: `MANAGEMENT_METRICS_TAGS_ENVIRONMENT=staging`.

## 3. Publish the management port

If your Spring Boot app already binds a port that's reachable from the
monitoring host, nothing more to do. If not, expose it in the service's
docker-compose:

```yaml
services:
  scraper:
    # ...existing config...
    ports:
      - "8080:8080"   # whatever your management port is
```

## 4. Register the app with Prometheus (multi-app friendly)

Prometheus picks up Java apps from JSON files in
`prometheus/targets/java/*.json`. Drop one file per deployment (or per
service — your call) and Prometheus hot-reloads every 30 seconds with no
restart needed.

**Single project, two apps (the CFP case):**

`prometheus/targets/java/cfp-classifier.json`:
```json
[
  {
    "targets": ["host.docker.internal:8080"],
    "labels": {
      "service": "cfp-scraper",
      "host": "cfp-classifier",
      "environment": "production"
    }
  },
  {
    "targets": ["host.docker.internal:8081"],
    "labels": {
      "service": "cfp-management",
      "host": "cfp-classifier",
      "environment": "production"
    }
  }
]
```

**Microservices deployment (the OpenLMIS Malawi case):**

`prometheus/targets/java/openlmis-malawi.json`:
```json
[
  {"targets":["malawi-prod:8080"], "labels":{"service":"requisition",      "host":"malawi-prod","environment":"production"}},
  {"targets":["malawi-prod:8081"], "labels":{"service":"fulfillment",       "host":"malawi-prod","environment":"production"}},
  {"targets":["malawi-prod:8082"], "labels":{"service":"stockmanagement",   "host":"malawi-prod","environment":"production"}},
  {"targets":["malawi-prod:8083"], "labels":{"service":"referencedata",     "host":"malawi-prod","environment":"production"}},
  {"targets":["malawi-prod:8084"], "labels":{"service":"auth",              "host":"malawi-prod","environment":"production"}}
]
```

**Custom metrics path** (rare — only if you've moved actuator off the
default `/actuator/prometheus`):
```json
[
  {
    "targets": ["app.example.com:443"],
    "labels": {
      "service": "legacy-app",
      "host": "legacy-prod",
      "environment": "production",
      "metrics_path": "/internal/metrics"
    }
  }
]
```
The package's `java` scrape job picks up `metrics_path` from labels via
relabel rules; the default if absent is `/actuator/prometheus`.

**Hot-reload** — once your JSON is in place, Prometheus picks it up within
30 s. Verify at `http://localhost:9090/targets`: the `java` job lists every
target with its `service` / `host` / `environment` labels. Each target shows
`UP` (scrape OK) or `DOWN` with a reason — the JVM dashboard's Service
variable picker populates with whatever's reachable.

**Why JSON files and not .env entries?** As you grow past one Java app the
.env approach doesn't compose well (you'd end up with `JAVA_APP_1_*`,
`JAVA_APP_2_*`, etc., and editing them means re-rendering and recreating
Prometheus). JSON files in `prometheus/targets/java/` are picked up live,
work cleanly across 1 to 50+ services, are easy to template/generate from
project compose files, and match the way real Prometheus deployments
manage target lists.

## 4. Optional but recommended

**Separate management port** if you don't want the metrics endpoint exposed
on your public app port:
```properties
management.server.port=9090
management.server.address=0.0.0.0
```
…and expose `9090` instead of `8080` in the compose. Slight extra plumbing,
much smaller attack surface.

**JVM launch flags** for the OOM scenario from the runbook:
```
-XX:+ExitOnOutOfMemoryError
-XX:+HeapDumpOnOutOfMemoryError
-XX:HeapDumpPath=/var/lib/<app>/dumps/
```
The first guarantees the container exits on `OutOfMemoryError` (instead of
limping). The second writes a heap dump for forensics. Mount
`/var/lib/<app>/dumps/` to a host directory so dumps survive restart.

## 5. Align `-Xmx` with the container memory limit

A latent OOM trap: it's easy to set `-Xmx` larger than the container's
`mem_limit`. The JVM dashboard will happily report `max heap = -Xmx` and
"only 30% used", while the kernel cgroup OOM-killer waits to strike the
moment total JVM footprint (heap + metaspace + code cache + thread stacks
+ native buffers) crosses the *container* limit — which is 30–50% lower
than `-Xmx` once you account for non-heap memory.

**Rule of thumb:** `-Xmx` ≈ 75% of the container `mem_limit`. The other
25% covers metaspace, JIT code cache, thread stacks, off-heap NIO buffers,
GC structures, and a small safety margin.

**Recommended on modern Java (10+)** — let the JVM compute heap from the
cgroup limit, so the same image works across dev/staging/prod with
different container limits:

```yaml
services:
  scraper:
    mem_limit: 1g
    environment:
      JAVA_OPTS: "-XX:MaxRAMPercentage=75.0"
```

**Java 8 (8u191+)**: needs `-XX:+UseContainerSupport` plus an explicit
`-Xmx`:

```
-XX:+UseContainerSupport -Xmx768m
```

**If the heap genuinely needs N MB:** bump `mem_limit` to ~`N * 1.33` MB.
For a workload that needs 1.5 GB heap → container limit `2g`. Setting
`-Xmx1536m` against a `1g` container limit is configuring an OOM crash
under any moderate load spike.

The `ContainerHighMemoryVsLimit` alert in the package will warn at >90%
of the container's limit. Catches this, but ideally you don't ship it.

## 6. Verify

From the app's host: `curl http://localhost:<port>/actuator/prometheus | head`
should print Prometheus-format metrics including `jvm_memory_used_bytes`,
`jvm_gc_pause_seconds`, `process_cpu_usage`, etc.

From the monitoring host:
- `http://<monitor>:9090/targets` — the `java` job should show `UP`.
- Grafana → Dashboards → **JVM application** — the Service dropdown
  populates with the value you set in `management.metrics.tags.service`.
- Within ~15 minutes you should have enough heap history for trends to be
  meaningful. The `JvmHeapPressure` and `JvmGCThrashing` alerts evaluate
  immediately but only fire after their `for:` windows (10m and 5m).

## Common gotchas

- **`/actuator/prometheus` returns 401 or 403** — Spring Security is in
  front of the endpoint. By default `spring-boot-starter-security` blocks
  `/actuator/**` along with everything else. Fix options, safest first:
  1. **Use a separate management port** (`management.server.port=9090`,
     `management.server.address=0.0.0.0`) and don't expose it to the
     public internet. Spring Security on the main port stays untouched.
     Recommended for any environment with public ingress.
  2. **Basic auth on actuator** with credentials in Prometheus' scrape
     config (`basic_auth: {username, password_file}` on the `java` job).
     Adds plumbing on both sides.
  3. **`permitAll()` for `/actuator/**`** in `SecurityConfig`. Acceptable
     only when the deployment has no public ingress at all (internal-only
     network). The metrics leak heap/GC/request-path detail to anyone who
     can reach the port.
- **No `service` label visible** — `management.metrics.tags.service` wasn't
  set, or wasn't picked up because Micrometer auto-configuration ran before
  your config. Restart the app; verify by curling the endpoint and
  grep-ping for `service="..."` in the output.
- **`/actuator/prometheus` returns 404** — the endpoint isn't exposed.
  Check `management.endpoints.web.exposure.include` includes `prometheus`,
  not just `health`.
- **`/actuator/prometheus` returns 200 but empty** — `micrometer-registry-prometheus`
  dependency missing. Actuator is enabled but no Prometheus registry is
  bound to it.
- **Target shows `UP` but dashboard is empty** — the `service` label in
  Prometheus is from the scrape config target labels, but Micrometer
  tags add their own `service`. If they disagree, the dashboard variable
  won't match anything. Make them identical.
- **Curl from laptop works, scrape from Prometheus container fails** —
  the app binds to `localhost` only. Set `management.server.address=0.0.0.0`
  (required when you've also set `management.server.port` — separate
  management port defaults to `localhost` binding).
