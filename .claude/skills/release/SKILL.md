---
name: release
description: Cut a soldevelo-monitoring release — pick the semver bump from the changelog, validate, tag, and publish. Use when asked to "release", "cut a release", "tag a version", or "publish" this repo.
---

# Release soldevelo-monitoring

Drive a release through `bin/release.sh`. The git tag `vX.Y.Z` is the source of
truth; the script stamps README + CHANGELOG and `bin/validate.sh` enforces they
match. Full reference: `docs/releasing.md`.

Do the steps in order. Don't hand-edit the version in README/CHANGELOG — the
script does that.

## 1. Preconditions

- On `main`, working tree clean (`git status`). If dirty, stop and ask.
- Docker running; `envsubst`, `python3`, `jq` on PATH.

## 2. Propose the version

- Latest tag: `git describe --tags --abbrev=0`.
- Read commits since it: `git log <tag>..HEAD --oneline`.
- Read the `## [Unreleased]` section of `CHANGELOG.md`.
- Pick the semver bump and tell the user your reasoning:
  - pre-1.0 (`0.x`): a breaking change bumps the **minor** (`0.3.0 → 0.4.0`);
    features also minor; fixes bump the **patch**.
  - Look for "Breaking" / "⚠️" in the Unreleased section — that forces a minor.
- If `## [Unreleased]` is empty or stale, draft entries from the commit log
  (Keep a Changelog: Added/Changed/Fixed) and get the user's OK before cutting.

## 3. Dry run

```
bin/release.sh X.Y.Z --dry-run
```

Renders, runs the full validation gate, prints the CHANGELOG/README diff, then
reverts. If validation fails, fix the underlying config — do not bypass the
gate. Show the diff to the user.

## 4. Cut it (on approval)

```
bin/release.sh X.Y.Z
```

Commits `Release X.Y.Z` and creates the annotated tag `vX.Y.Z`. Nothing is
pushed yet.

## 5. Publish (confirm first — this is outward-facing)

```
git push --follow-tags origin main
```

Then optionally open a GitHub Release (notes come from the tag annotation):

```
git tag -l --format='%(contents:body)' vX.Y.Z | gh release create vX.Y.Z --title vX.Y.Z --notes-file -
```

## Notes

- Never commit per-project overlay here: `prometheus/targets/blackbox/*.json`
  and `grafana/dashboards/overlay/*.json` are gitignored on purpose.
- Botched release, not yet pushed: `git tag -d vX.Y.Z && git reset --hard HEAD~1`.
  Already pushed: cut a new patch instead of rewriting the tag.
