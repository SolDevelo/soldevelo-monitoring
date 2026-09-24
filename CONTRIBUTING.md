# Contributing

Issues and pull requests are welcome. For anything larger than a fix, open an
issue first.

- Run `bin/validate.sh` before opening a PR. CI runs the same gate on every
  push and PR (`.github/workflows/validate.yml`).
- Commit subjects follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`fix(rules): …`, `feat(agents): …`).
- Add a line under `## [Unreleased]` in [`CHANGELOG.md`](CHANGELOG.md). Don't
  touch the version badge or release headings; `bin/release.sh` stamps them
  ([`docs/releasing.md`](docs/releasing.md)).
- The label contract is load-bearing: `job` names the collector kind only, and
  identity lives in `app` / `deployment` / `environment` / `service` /
  `instance`. Alert rules, Alertmanager routing and every dashboard depend on
  it, and deployed agents must change in step with the stack. Open an issue
  before changing it. See [`docs/metrics.md`](docs/metrics.md#the-job-contract).
