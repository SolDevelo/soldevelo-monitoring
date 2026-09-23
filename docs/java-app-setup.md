# Wiring a Java app into soldevelo-monitoring

What a Spring Boot service does to land on the JVM dashboard and alerts:
2 dependencies, 3 properties, 4 labels. ~10 minutes.

## 1. Dependencies

Gradle:
```groovy
dependencies {
    implementation 'org.springframework.boot:spring-boot-starter-actuator'
    implementation 'io.micrometer:micrometer-registry-prometheus'
}
```
Maven:
```xml
<dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-actuator</artifactId></dependency>
<dependency><groupId>io.micrometer</groupId><artifactId>micrometer-registry-prometheus</artifactId></dependency>
```
Spring Boot 2.x and 3.x both work.

## 2. Expose actuator on an unsecured management port

Spring Security guards `/actuator/**` by default, so serve actuator on a
separate management port that isn't behind the app's security filter:

```properties
management.server.port=9090
management.server.address=0.0.0.0
management.endpoints.web.exposure.include=health,prometheus
```

A typical Spring Boot service does exactly this —
actuator on `9090`, the app itself on `8080`. Don't publish `9090` to the
host; the agent reaches it on the internal docker network.

## 3. Label the service for discovery

Add compose labels so the Alloy agent scrapes it:

```yaml
services:
  scraper:
    labels:
      monitoring.scrape: "true"
      monitoring.port: "9090"
      monitoring.path: "/actuator/prometheus"
      monitoring.service: "scraper"
```

`monitoring.service` becomes the `service` label. `app` / `deployment` / `host`
are set once by the agent (`APP` / `DEPLOYMENT` / `TARGET_NAME`), never per
service. Replicas of one role share `service` and differ by `instance` (the
compose service name). On Kubernetes use pod-template annotations instead —
see [`kubernetes-setup.md`](kubernetes-setup.md). Contract: [`metrics.md`](metrics.md).

## 4. Align `-Xmx` with the container memory limit

A latent OOM trap: `-Xmx` larger than the container's `mem_limit`. The JVM
dashboard reports "30% heap used" while the kernel cgroup OOM-killer strikes
the moment total JVM footprint (heap + metaspace + code cache + thread
stacks + native buffers) crosses the *container* limit.

**Rule of thumb:** `-Xmx` ≈ 75% of `mem_limit`. On modern Java (10+), let the
JVM compute it from the cgroup limit:

```yaml
services:
  scraper:
    mem_limit: 1g
    environment:
      JAVA_OPTS: "-XX:MaxRAMPercentage=75.0"
```

Java 8 (8u191+) needs `-XX:+UseContainerSupport -Xmx768m` explicitly.

## 5. Verify

From the app's host:
```bash
docker compose exec scraper curl -s localhost:9090/actuator/prometheus | head
```
prints `jvm_memory_used_bytes`, `jvm_gc_pause_seconds`, `process_cpu_usage`.
Then Grafana → **JVM application** → pick your `deployment` / `service`.

## Common gotchas

- **`/actuator/prometheus` returns 401/403** — actuator is behind Spring
  Security on the app port. Move it to a separate `management.server.port`
  (section 2) that isn't secured, and label that port.
- **Endpoint works locally but the agent gets nothing** — the app bound
  actuator to `localhost`. Set `management.server.address=0.0.0.0` (required
  whenever `management.server.port` is set — it defaults to loopback), and make
  sure the agent shares the app's docker network.
- **Dashboard empty though metrics arrive** — you selected an `app` /
  `deployment` / `service` with no series; check the labels resolve.
