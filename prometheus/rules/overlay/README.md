# Per-deployment rules (overlay)

Drop-zone for rules the base package can't write because they depend on a
specific deployment's inventory. Files here are loaded by
`/etc/prometheus/rules/overlay/*.yml` and are **not** committed to the base
package — they live in the deployment's own repo, like
`prometheus/targets/blackbox/*.json` and `grafana/dashboards/overlay/*.json`.

## Why AgentAbsent lives here

Every other absence rule in this package infers its inventory from history
("what was reporting 2h ago"). That works without configuration, but it has two
holes: it can never fire for a host that has **never once reported**, and it
fires for 2h after a host is deliberately decommissioned.

For app containers that trade is fine — they're many and they churn. For hosts
it isn't: they're few, they're stable, and a host that silently never came up is
exactly the failure you most need to catch. So the host inventory is written
down explicitly, reviewed in git, and `absent()` alerts on it.

`absent()` returns only the labels in its matcher, which is why every label the
alert needs — including the ones Alertmanager routes and inhibits on — is
restated under `labels:`.

## Example

Copy to `<deployment>.yml` and edit. One stanza per agent host per environment:

```yaml
groups:
  - name: agent-inventory
    rules:
      - alert: AgentAbsent
        # `for` must be SHORTER than every alert it inhibits (ServiceDown 10m,
        # ServiceAbsent 30m, ContainerAbsent 30m) — Alertmanager only
        # suppresses alerts that are already firing when the source fires.
        expr: absent(up{job="agent", deployment="acme", environment="prod", host="acme-prod"})
        for: 5m
        labels:
          severity: critical
          app: acme-app
          deployment: acme
          environment: prod
          host: acme-prod
        annotations:
          summary: "Monitoring agent absent: acme-prod (prod)"
          description: "No metrics have arrived from the Alloy agent on acme-prod for 5m. The host, the agent, or the network path to the monitoring host is down — everything else reported for this host is stale."
```

After adding or changing a file:

```sh
curl -X POST localhost:9090/-/reload
curl -s localhost:9090/api/v1/rules | jq '.data.groups[].name'
```
