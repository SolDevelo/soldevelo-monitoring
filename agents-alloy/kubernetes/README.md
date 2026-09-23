# Alloy Kubernetes agent

One Grafana Alloy Deployment per cluster: pod logs through the API, metrics
from pods annotated `prometheus.io/scrape: "true"`, kube-state-metrics, and the
agent heartbeat — pushed to the central `/ingest/*` endpoints under the same
label contract as the docker agent. Copy `30-agent-config.yaml.example` to
`30-agent-config.yaml` (gitignored) and edit it, create the `alloy-ingest`
Secret, `kubectl apply -f agents-alloy/kubernetes/`.

Walkthrough, what it does not collect, and the AgentAbsent overlay stanza:
[`docs/kubernetes-setup.md`](../../docs/kubernetes-setup.md).
