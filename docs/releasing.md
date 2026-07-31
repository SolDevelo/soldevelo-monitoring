# Releasing

How to cut a `soldevelo-monitoring` release. The git tag `vX.Y.Z` is the
source of truth for the version; everything else is derived from it.

## Model

- **Semver.** `0.x.y` while pre-1.0 — breaking changes are allowed between
  minor versions (bump the minor, e.g. `0.3.0 → 0.4.0`; note the break in the
  CHANGELOG). Features → minor, bug fixes → patch.
- **Keep a Changelog.** Every change lands with an entry under
  `## [Unreleased]` in `CHANGELOG.md`. Cutting a release just dates that
  section — so keep it current as you go, not at the last minute.
- **Tag = source of truth.** The `**Version:**` badge in `README.md` and the
  `CHANGELOG.md` heading are *stamped from the version by `bin/release.sh`*.
  Never hand-edit them; `bin/validate.sh` fails if they drift.

## Prerequisites

- Docker running (the checks run `promtool` / `amtool` via the pinned stack
  images — first run pulls them; no host installs needed).
- `envsubst` (package `gettext`), `python3`, `jq` on PATH.
- On `main`, working tree clean (no uncommitted tracked changes).

## Validate anytime

```
bin/validate.sh            # validates the base package (uses .env.example)
bin/validate.sh path/.env  # validate a specific deployment's config instead
```

Renders the templates, then lints Prometheus rules + config, Alertmanager
config, Loki/provisioning YAML, dashboard JSON, the version badge, and both
compose files. This is the release gate; run it in CI too.

## Cut a release

1. Confirm `## [Unreleased]` in `CHANGELOG.md` describes everything since the
   last tag. Pick the version (`X.Y.Z`) per semver.
2. Preview — renders and validates, shows the CHANGELOG/README diff, then
   reverts. Nothing is committed:
   ```
   bin/release.sh X.Y.Z --dry-run
   ```
3. Cut it. Runs the validation gate, rolls `[Unreleased]` into
   `## [X.Y.Z] — <today>`, updates the compare-link footer, stamps the README
   badge, commits `Release X.Y.Z`, and creates the annotated tag `vX.Y.Z`
   (annotation = the changelog section):
   ```
   bin/release.sh X.Y.Z
   ```
4. Review the commit and tag, then publish:
   ```
   git push --follow-tags origin main
   ```
5. Optional — open a GitHub Release from the tag (body = the changelog
   section already in the tag annotation):
   ```
   git tag -l --format='%(contents:body)' vX.Y.Z | gh release create vX.Y.Z --title vX.Y.Z --notes-file -
   ```

## Consuming a release

Target projects pin a tag in their overlay (`git checkout vX.Y.Z`) and layer
their own `.env`, probe targets (`prometheus/targets/blackbox/*.json`), and
project dashboards (`grafana/dashboards/overlay/*.json`) on top. Those overlay
paths are gitignored in the base — never commit a project's artifacts here.

## If a release goes wrong (before pushing)

```
git tag -d vX.Y.Z                 # remove the local tag
git reset --hard HEAD~1           # undo the Release commit
```

Once pushed, don't rewrite the tag — cut a new patch release instead.
