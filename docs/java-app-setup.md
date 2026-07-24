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

Spring Boot 2.x and 3.x both work. Let the BOM resolve versions.

## 2. Configuration

In `application.properties` (or `application.yml`):

```properties
# Expose the prometheus endpoint (and health, which Blackbox probes use).
management.endpoints.web.exposure.include=health,prometheus

# Optional app-side common tags. The Prometheus target labels (section 4) are
# authoritative and override these (default honor_labels: false → an app-side
# `service` is preserved as `exported_service` and the target's value wins).
management.metrics.tags.service=scraper-1
management.metrics.tags.environment=production
```

The `app`, `deployment`, `service`, `host`, and `environment` labels all come
from the **Prometheus target** (section 4) — that's the source of truth. The
app cannot set `app` / `deployment` (the same artifact runs in every
deployment, so it can't know which one it is), and any `service` /
`environment` it does set is overridden by the target. Setting the app-side
tags is therefore optional; do it only for consistency or if the app is also
scraped somewhere without target labels. Full contract: `docs/metrics.md`.

## 3. Publish the management port

If your Spring Boot app already binds a port reachable from the monitoring
host, done. Otherwise expose it in the service's docker-compose:

```yaml
services:
  scraper:
    ports:
      - "8080:8080"
```

## 4. Register the app with Prometheus

Prometheus picks up Java apps from JSON files in
`prometheus/targets/java/*.json`. Drop one file per deployment (or per
service) and Prometheus hot-reloads every 30s.

**Single app, two services:**

`prometheus/targets/java/cfp.json`:
```json
[
  {
    "targets": ["host.docker.internal:9190"],
    "labels": {
      "app": "cfp-classifier",
      "deployment": "sdd",
      "service": "management",
      "host": "cfp-classifier",
      "environment": "production"
    }
  },
  {
    "targets": ["host.docker.internal:9191"],
    "labels": {
      "app": "cfp-classifier",
      "deployment": "sdd",
      "service": "scraper-1",
      "host": "cfp-classifier",
      "environment": "production"
    }
  }
]
```

`service` is the bare component name (`management`, `scraper-1`) — `app` and
`deployment` carry the rest, so the same picker works whether you're looking
at the `sdd` deployment or another deployment of the same app (`deployment:
"ilo"`).

**Microservices deployment:**

`prometheus/targets/java/openlmis-malawi.json`:
```json
[
  {"targets":["malawi-prod:8080"], "labels":{"app":"openlmis","deployment":"malawi","service":"requisition",     "host":"malawi-prod","environment":"production"}},
  {"targets":["malawi-prod:8081"], "labels":{"app":"openlmis","deployment":"malawi","service":"fulfillment",     "host":"malawi-prod","environment":"production"}},
  {"targets":["malawi-prod:8082"], "labels":{"app":"openlmis","deployment":"malawi","service":"stockmanagement", "host":"malawi-prod","environment":"production"}},
  {"targets":["malawi-prod:8083"], "labels":{"app":"openlmis","deployment":"malawi","service":"referencedata",   "host":"malawi-prod","environment":"production"}},
  {"targets":["malawi-prod:8084"], "labels":{"app":"openlmis","deployment":"malawi","service":"auth",            "host":"malawi-prod","environment":"production"}}
]
```

**Custom metrics path** (rare — if you've moved actuator off the default
`/actuator/prometheus`): add `"metrics_path": "/internal/metrics"` to the
labels. The scrape config picks it up via relabel rules.

Verify at `http://<monitor>:9090/targets`: the `java` job lists every
target with its `app` / `deployment` / `service` / `host` / `environment`
labels.

## 5. Align `-Xmx` with the container memory limit

A latent OOM trap: `-Xmx` larger than the container's `mem_limit`. The JVM
dashboard reports "30% heap used" while the kernel cgroup OOM-killer strikes
the moment total JVM footprint (heap + metaspace + code cache + thread
stacks + native buffers) crosses the *container* limit.

**Rule of thumb:** `-Xmx` ≈ 75% of `mem_limit`. On modern Java (10+), let
the JVM compute it from the cgroup limit:

```yaml
services:
  scraper:
    mem_limit: 1g
    environment:
      JAVA_OPTS: "-XX:MaxRAMPercentage=75.0"
```

Java 8 (8u191+) needs `-XX:+UseContainerSupport -Xmx768m` explicitly.

## 6. Verify

From the app's host: `curl http://localhost:<port>/actuator/prometheus | head`
prints Prometheus-format metrics including `jvm_memory_used_bytes`,
`jvm_gc_pause_seconds`, `process_cpu_usage`.

From the monitoring host:
- `http://<monitor>:9090/targets` — the `java` job shows `UP`.
- Grafana → Dashboards → **JVM application** — the Service dropdown
  populates with your `management.metrics.tags.service`.

## Common gotchas

- **`/actuator/prometheus` returns 401 or 403** — Spring Security is in
  front of the endpoint. Safest fix: use a separate management port
  (`management.server.port=9090`, `management.server.address=0.0.0.0`) and
  don't expose it publicly. Alternatives: basic-auth on actuator with
  `basic_auth` in the Prometheus scrape config, or `permitAll()` for
  `/actuator/**` in `SecurityConfig` (internal-only networks only).
- **Target `UP` but dashboard empty** — the target is missing the `service`
  label the dashboard's picker resolves against, or you've selected an
  `app` / `deployment` that has no series. Confirm the target JSON carries
  `app` / `deployment` / `service` (the target labels are authoritative;
  an app-side Micrometer `service` tag lands as `exported_service` and does
  not feed the picker).
- **Scrape from Prometheus container fails but curl from your laptop
  works** — the app binds to `localhost` only. Set
  `management.server.address=0.0.0.0` (required whenever you've set
  `management.server.port` — separate management port defaults to loopback).
