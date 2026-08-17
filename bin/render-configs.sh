#!/usr/bin/env bash
# Render *.template files in the repo by envsubst-ing values from .env (or $1).
# Usage:  bin/render-configs.sh [path/to/.env]
set -euo pipefail

# Force umask 022 so rendered files are 644 (world-readable). Without this,
# hardened distros with umask 0027 (e.g. CIS-benchmarked Ubuntu/RHEL) produce
# mode-640 files that container processes — running as `nobody` (uid 65534) or
# similar non-host-group users — cannot read.
umask 022

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${1:-${REPO_ROOT}/.env}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: env file not found: ${ENV_FILE}" >&2
  echo "Copy .env.example to .env and fill in values." >&2
  exit 1
fi

if ! command -v envsubst >/dev/null 2>&1; then
  echo "ERROR: envsubst not installed (package: gettext)" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

# Optional vars with a documented fallback. Unset ones must still be expanded,
# or envsubst leaves the literal '${VAR}' in the output and the config is invalid.
: "${SLACK_WEBHOOK_URL_PROD:=${SLACK_WEBHOOK_URL:-}}"
: "${SLACK_CHANNEL_PROD:=${SLACK_CHANNEL:-}}"
# Dead man's switch is inert until HEARTBEAT_URL points at a real endpoint:
# the Watchdog route defaults to a receiver that discards. See
# docs/dead-man-switch.md.
: "${WATCHDOG_RECEIVER:=heartbeat-disabled}"
: "${HEARTBEAT_URL:=https://heartbeat.invalid/not-configured}"
export SLACK_WEBHOOK_URL_PROD SLACK_CHANNEL_PROD WATCHDOG_RECEIVER HEARTBEAT_URL

# Restrict envsubst to only vars defined in .env — avoids accidentally
# expanding $PATH, $HOME etc. that appear inside templates.
var_list=$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "${ENV_FILE}" \
  | sed -E 's/=.*//' \
  | sed 's/^/$/' \
  | tr '\n' ' ')
var_list+=' $SLACK_WEBHOOK_URL_PROD $SLACK_CHANNEL_PROD $WATCHDOG_RECEIVER $HEARTBEAT_URL'

found_any=0
while IFS= read -r -d '' template; do
  output="${template%.template}"
  envsubst "${var_list}" < "${template}" > "${output}"
  echo "rendered: ${output#${REPO_ROOT}/}"
  found_any=1
done < <(find "${REPO_ROOT}" -type f -name '*.template' -print0)

if [[ "${found_any}" -eq 0 ]]; then
  echo "no *.template files found under ${REPO_ROOT}"
fi

# Ensure config directories that get bind-mounted into containers are
# traversable and readable by container processes. Idempotent; fixes the
# common case where git clone under a restrictive umask leaves dirs at 750
# and files at 640, which containers running as non-host-group users
# (nobody / 65534, grafana / 472, etc.) cannot read.
config_dirs=(
  "${REPO_ROOT}/prometheus"
  "${REPO_ROOT}/loki"
  "${REPO_ROOT}/alertmanager"
  "${REPO_ROOT}/blackbox"
  "${REPO_ROOT}/grafana"
  "${REPO_ROOT}/caddy"
  "${REPO_ROOT}/agents-alloy"
)
for d in "${config_dirs[@]}"; do
  if [[ -d "${d}" ]]; then chmod -R a+rX "${d}"; fi
done
