#!/usr/bin/env bash
# Validate the package before a release (or in CI): render templates, then
# lint rules / configs / dashboards / compose files. Runs promtool + amtool
# via the pinned stack images so no host installs are needed.
# Usage:  bin/validate.sh [path/to/.env]
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# Env file supplies the image version pins and the render values. Default to
# .env.example — the complete, committed reference that carries every var
# (stack + agents); a deployment's own .env is partial. Pass a path to validate
# a specific deployment instead.
ENV_FILE="${1:-.env.example}"
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: env file not found: ${ENV_FILE}" >&2; exit 2
fi
echo "Using env file: ${ENV_FILE}"

set -a; # shellcheck disable=SC1090
source "${ENV_FILE}"; set +a
PROM_IMG="prom/prometheus:${PROMETHEUS_VERSION:?set PROMETHEUS_VERSION in ${ENV_FILE}}"
AM_IMG="prom/alertmanager:${ALERTMANAGER_VERSION:?set ALERTMANAGER_VERSION in ${ENV_FILE}}"

for bin in docker python3 jq; do
  command -v "${bin}" >/dev/null || { echo "ERROR: ${bin} not installed" >&2; exit 2; }
done

FAILS=()
step() { echo; echo "==> $1"; }
ok()   { echo "    OK: $1"; }
fail() { echo "    FAIL: $1" >&2; FAILS+=("$1"); }

# file_sd target dirs are per-project overlay, not base — mount an empty dir so
# `check config` validates the base regardless of what overlay files exist.
EMPTY_TARGETS="$(mktemp -d)"
trap 'rm -rf "${EMPTY_TARGETS}"' EXIT

step "Render templates from ${ENV_FILE}"
if bin/render-configs.sh "${ENV_FILE}" >/dev/null; then ok "rendered"; else fail "render-configs.sh"; fi

step "promtool check rules"
if docker run --rm -v "${REPO_ROOT}:/work:ro" --entrypoint sh "${PROM_IMG}" \
     -c 'promtool check rules /work/prometheus/rules/*.yml /work/prometheus/rules_meta/*.yml'; then
  ok "rules"; else fail "promtool check rules"; fi

step "promtool test rules (absence rules)"
# The absence rules fail silently by construction — a broken one is
# indistinguishable from a healthy system — so their semantics are pinned here.
if docker run --rm -v "${REPO_ROOT}:/work:ro" --entrypoint sh "${PROM_IMG}" \
     -c 'cd /work/prometheus/tests && promtool test rules *.yml'; then
  ok "unit tests"; else fail "promtool test rules"; fi

step "promtool check config (main)"
if docker run --rm \
     -v "${REPO_ROOT}/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
     -v "${REPO_ROOT}/prometheus/rules:/etc/prometheus/rules:ro" \
     -v "${EMPTY_TARGETS}:/etc/prometheus/targets:ro" \
     --entrypoint promtool "${PROM_IMG}" check config /etc/prometheus/prometheus.yml; then
  ok "prometheus.yml"; else fail "promtool check config (main)"; fi

step "promtool check config (meta)"
if docker run --rm \
     -v "${REPO_ROOT}/prometheus/prometheus-meta.yml:/etc/prometheus/prometheus.yml:ro" \
     -v "${REPO_ROOT}/prometheus/rules_meta:/etc/prometheus/rules:ro" \
     --entrypoint promtool "${PROM_IMG}" check config /etc/prometheus/prometheus.yml; then
  ok "prometheus-meta.yml"; else fail "promtool check config (meta)"; fi

step "amtool check-config"
if docker run --rm -v "${REPO_ROOT}/alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro" \
     --entrypoint amtool "${AM_IMG}" check-config /etc/alertmanager/alertmanager.yml; then
  ok "alertmanager.yml"; else fail "amtool check-config"; fi

step "amtool routing (alerts reach the receiver they're labelled for)"
# A route matcher is a literal string match — a typo, or an `environment` value
# that drifts from the documented enum, silently sends alerts to the fallback
# receiver instead of the prod channel or the dev mute. Nothing else catches
# that; it looks identical to working.
routes_bad=0
route_expect() { # <expected-receiver> <label=value> ...
  local want="$1"; shift
  local got
  got=$(docker run --rm -v "${REPO_ROOT}/alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro" \
        --entrypoint amtool "${AM_IMG}" config routes test \
        --config.file=/etc/alertmanager/alertmanager.yml "$@" 2>/dev/null | tr -d '[:space:]')
  if [[ "${got}" == "${want}" ]]; then
    echo "    ${*} -> ${got}"
  else
    echo "    ${*} -> ${got:-<none>} (expected ${want})" >&2; routes_bad=1
  fi
}
route_expect "heartbeat-disabled" alertname=Watchdog
route_expect "null"               environment=dev severity=critical
route_expect "slack-prod"         environment=prod severity=critical
route_expect "slack-prod"         environment=prod severity=warning
route_expect "slack"              environment=uat severity=critical
route_expect "slack"              environment=uat severity=warning
# An alert with no environment label must still land somewhere visible.
route_expect "slack"              severity=critical
[[ "${routes_bad}" == 0 ]] && ok "routing" || fail "amtool routes test"

step "environment enum (agent env + blackbox targets)"
# The enum is load-bearing: alertmanager.yml matches these literals.
if ENV_FILE="${ENV_FILE}" python3 - <<'PY'; then ok "environment enum"; else fail "environment enum"; fi
import glob, json, os, re, sys
ENUM = {"prod", "uat", "staging", "dev"}
bad = []
env_file = os.environ.get("ENV_FILE", ".env.example")
m = re.search(r"^ENVIRONMENT=(.*)$", open(env_file).read(), re.M)
if m and m.group(1).strip().strip('"\'') not in ENUM:
    bad.append(f"{env_file}: ENVIRONMENT={m.group(1).strip()}")
for f in glob.glob("prometheus/targets/blackbox/*.json"):
    for entry in json.load(open(f)):
        v = entry.get("labels", {}).get("environment")
        if v is not None and v not in ENUM:
            bad.append(f"{f}: environment={v}")
for b in bad:
    print(f"    off-enum: {b}")
print(f"    allowed: {sorted(ENUM)}")
sys.exit(1 if bad else 0)
PY

step "YAML parse (loki rules, loki config, provisioning, blackbox)"
if python3 - <<'PY'; then ok "yaml"; else exit_yaml=$?; fi
import glob, sys, yaml
files = (glob.glob("loki/rules/**/*.yaml", recursive=True)
         + glob.glob("loki/rules/**/*.yml", recursive=True)
         + glob.glob("grafana/provisioning/**/*.yml", recursive=True)
         + ["loki/loki-config.yaml", "blackbox/blackbox.yml"])
bad = 0
for f in files:
    try:
        list(yaml.safe_load_all(open(f)))
    except Exception as e:
        print(f"    {f}: {e}"); bad += 1
print(f"    parsed {len(files)} YAML files, {bad} bad")
sys.exit(1 if bad else 0)
PY
[[ "${exit_yaml:-0}" != 0 ]] && fail "YAML parse"

step "JSON parse (dashboards)"
json_bad=0
for f in grafana/dashboards/*.json; do
  jq -e . "$f" >/dev/null 2>&1 || { echo "    invalid: $f"; json_bad=1; }
done
[[ "${json_bad}" == 0 ]] && ok "$(ls grafana/dashboards/*.json | wc -l | tr -d ' ') dashboards" || fail "dashboard JSON"

step "version consistency (README badge == latest CHANGELOG release)"
# The git tag is the source of truth; release.sh stamps README + CHANGELOG from
# it. This catches a hand-edit that drifted them apart. Git-independent so it
# works on shallow CI checkouts; release.sh does the tag cross-check.
if python3 - <<'PY'; then ok "version"; else fail "version consistency"; fi
import re, sys
readme = re.search(r"\*\*Version:\*\* `([0-9]+\.[0-9]+\.[0-9]+)`", open("README.md").read())
changelog = re.search(r"^## \[([0-9]+\.[0-9]+\.[0-9]+)\] — ", open("CHANGELOG.md").read(), re.M)
if not readme:    print("    no **Version:** badge in README.md"); sys.exit(1)
if not changelog: print("    no dated release section in CHANGELOG.md"); sys.exit(1)
if readme.group(1) != changelog.group(1):
    print(f"    README {readme.group(1)} != CHANGELOG {changelog.group(1)}"); sys.exit(1)
print(f"    both at {readme.group(1)}"); sys.exit(0)
PY

step "docker compose config"
if docker compose --env-file "${ENV_FILE}" -f stack/docker-compose.yml config -q; then
  ok "stack/docker-compose.yml"; else fail "compose config (stack)"; fi
if docker compose --env-file "${ENV_FILE}" -f agents-alloy/docker-compose.yml config -q; then
  ok "agents-alloy/docker-compose.yml"; else fail "compose config (agents)"; fi

echo
if [[ ${#FAILS[@]} -eq 0 ]]; then
  echo "VALIDATION PASSED"; exit 0
else
  echo "VALIDATION FAILED (${#FAILS[@]}):"; printf '  - %s\n' "${FAILS[@]}"; exit 1
fi
