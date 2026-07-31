#!/usr/bin/env bash
# Cut a release: gate on bin/validate.sh, roll the CHANGELOG, stamp the README
# version, commit "Release X.Y.Z", and create the annotated tag vX.Y.Z.
# Does NOT push — prints the push command for you to run.
# Usage:  bin/release.sh X.Y.Z [--dry-run] [--date YYYY-MM-DD]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

VERSION=""; DRY_RUN=0; DATE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --date) DATE="$2"; shift 2 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) VERSION="$1"; shift ;;
  esac
done

[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "ERROR: version must be semver X.Y.Z (got '${VERSION}')" >&2; exit 2; }
TAG="v${VERSION}"
DATE="${DATE:-$(date +%F)}"

die() { echo "ERROR: $*" >&2; exit 1; }

# --- Preconditions --------------------------------------------------------
git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "${BRANCH}" != "main" && "${ALLOW_BRANCH:-0}" != 1 ]]; then
  die "on branch '${BRANCH}', not main (set ALLOW_BRANCH=1 to override)"
fi
git diff --quiet && git diff --cached --quiet || \
  die "working tree has uncommitted tracked changes — commit or stash first"
git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null && die "tag ${TAG} already exists"

# Previous released version, per the CHANGELOG footer, cross-checked vs git.
PREV="$(grep -oE '^\[Unreleased\]: .*compare/v[0-9]+\.[0-9]+\.[0-9]+\.\.\.HEAD' CHANGELOG.md \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[[ -n "${PREV}" ]] || die "could not parse previous version from CHANGELOG [Unreleased] footer link"
GIT_LATEST="$(git tag --sort=-v:refname | head -1)"
if [[ -n "${GIT_LATEST}" && "${GIT_LATEST}" != "${PREV}" ]]; then
  die "CHANGELOG says prev=${PREV} but latest git tag is ${GIT_LATEST} — reconcile first"
fi
[[ "${TAG}" != "${PREV}" ]] || die "version ${VERSION} equals the previous release"

echo "Releasing ${TAG}  (previous: ${PREV}, date: ${DATE}, dry-run: ${DRY_RUN})"

# --- Validation gate ------------------------------------------------------
echo; echo "==> Running validation gate"
bin/validate.sh >/tmp/release-validate.$$.log 2>&1 || {
  echo "VALIDATION FAILED — see below:" >&2; tail -30 /tmp/release-validate.$$.log >&2
  rm -f /tmp/release-validate.$$.log; exit 1; }
rm -f /tmp/release-validate.$$.log
echo "    validation passed"

# --- CHANGELOG roll + README stamp (python for safe multiline edits) ------
SECTION_FILE="$(mktemp)"; trap 'rm -f "${SECTION_FILE}"' EXIT
VERSION="${VERSION}" PREV="${PREV}" DATE="${DATE}" SECTION_FILE="${SECTION_FILE}" python3 - <<'PY'
import os, re, sys
v, prev, date, section_file = (os.environ[k] for k in ("VERSION","PREV","DATE","SECTION_FILE"))
cl = open("CHANGELOG.md").read()

# Content between "## [Unreleased]" and the next "## [" must be non-empty.
m = re.search(r"^## \[Unreleased\]\s*\n(.*?)(?=^## \[)", cl, re.S | re.M)
if not m:
    sys.exit("could not locate [Unreleased] section")
body = m.group(1).strip()
if not body:
    sys.exit("[Unreleased] section is empty — nothing to release")
open(section_file, "w").write(body + "\n")

# Roll heading: fresh empty [Unreleased] above the new dated version section.
cl, n = re.subn(r"^## \[Unreleased\]\n\n",
                f"## [Unreleased]\n\n## [{v}] — {date}\n\n", cl, count=1, flags=re.M)
if n != 1:
    sys.exit("could not roll [Unreleased] heading")

# Footer links: repoint Unreleased at the new tag, insert the new version link.
cl, n = re.subn(r"^\[Unreleased\]: (?P<u>.*compare/)v[0-9.]+\.\.\.HEAD",
                lambda mm: (f"[Unreleased]: {mm.group('u')}v{v}...HEAD\n"
                            f"[{v}]: {mm.group('u')}{prev}...v{v}"),
                cl, count=1, flags=re.M)
if n != 1:
    sys.exit("could not update [Unreleased] footer link")
open("CHANGELOG.md", "w").write(cl)

rm, n = re.subn(r"(\*\*Version:\*\* `)[0-9]+\.[0-9]+\.[0-9]+(`)",
                rf"\g<1>{v}\g<2>", open("README.md").read(), count=1)
if n != 1:
    sys.exit("could not find README version badge to stamp")
open("README.md", "w").write(rm)
print(f"    CHANGELOG rolled to {v}, README stamped")
PY

echo; echo "==> Diff"
git --no-pager diff -- CHANGELOG.md README.md | head -60

if [[ "${DRY_RUN}" == 1 ]]; then
  echo; echo "Dry run — reverting CHANGELOG.md / README.md edits."
  git checkout -- CHANGELOG.md README.md
  exit 0
fi

# --- Commit + annotated tag -----------------------------------------------
git add CHANGELOG.md README.md
git commit -m "Release ${VERSION}" >/dev/null
{ echo "Release ${VERSION}"; echo; cat "${SECTION_FILE}"; } | git tag -a "${TAG}" -F -
echo; echo "Committed 'Release ${VERSION}' and created annotated tag ${TAG}."
echo "Review, then publish with:"
echo "    git push --follow-tags origin ${BRANCH}"
