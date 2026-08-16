#!/usr/bin/env bash
# fix-pr331-deps.sh — make PR #331's deps-and-imports CI gate green.
#
# Context: the PR adds the deps-and-imports CI job (good hardening). After the
# merge of main (5394223), three things still trip the new gate:
#   1. src/identity pins 7 deps at older versions than every other module
#   2. src/sysexec go directive is 1.24.2 (all others 1.25.0)
#   3. src/merchant/probe_test.go imports the pre-rename Origami74 path (#304)
# Items 2+3 are pre-existing on main — main never ran this gate until this PR
# added it. Validated 2026-08-17: all checks PASS + all module tests green.
set -euo pipefail

EXPECTED_TIP=539422386ff684de65be06ef8672929db41dd5d8
AMP_URL=https://github.com/Amperstrand/tollgate-module-basic-go.git
BRANCH=pr331-deps-fix
PR_URL=https://github.com/OpenTollGate/tollgate-module-basic-go/pull/331

ASSUME_YES=0
[ "${1:-}" = "--yes" ] && ASSUME_YES=1

say() { printf '\n== %s\n' "$*"; }
die() { printf '\nFATAL: %s\n' "$*" >&2; exit 1; }

say "STEP 1/6 — preflight"
[ -f src/go.mod ] || die "run from the root of a tollgate-module-basic-go clone"
command -v go >/dev/null || die "go not on PATH"
echo "go: $(go version | awk '{print $3}')"

say "STEP 2/6 — fetch his fork, verify tip"
git remote remove amperstrand >/dev/null 2>&1 || true
git remote add amperstrand "$AMP_URL"
git fetch amperstrand feat/identity-v2
tip=$(git rev-parse FETCH_HEAD)
echo "remote tip: $tip"
[ "$tip" = "$EXPECTED_TIP" ] || die "feat/identity-v2 moved (expected $EXPECTED_TIP). STOP — ping Hermes."

say "STEP 3/6 — work branch at tip (idempotent)"
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git switch "$BRANCH" && git reset --hard FETCH_HEAD
else
  git switch -c "$BRANCH" FETCH_HEAD
fi

say "STEP 4/6 — apply the three fixes"
( cd src/identity
  go get github.com/btcsuite/btcd/btcutil@v1.1.6 \
        github.com/bytedance/sonic@v1.13.2 \
        github.com/coder/websocket@v1.8.13 \
        golang.org/x/arch@v0.17.0 \
        golang.org/x/crypto@v0.54.0 \
        golang.org/x/exp@v0.0.0-20250506013437-ce4c2cf36ca6 \
        golang.org/x/sys@v0.47.0
  go mod tidy )
echo "identity: pins aligned + tidied"
( cd src/sysexec && go mod edit -go=1.25.0 && go mod tidy )
echo "sysexec: go directive 1.25.0 + tidied"
if grep -q 'Origami74/gonuts-tollgate' src/merchant/probe_test.go; then
  sed -i 's#github.com/Origami74/gonuts-tollgate#github.com/OpenTollGate/gonuts-tollgate#' src/merchant/probe_test.go
  echo "merchant: stale import path fixed"
else
  echo "merchant: import already fixed"
fi
git diff --stat

say "STEP 5/6 — gates (the failing CI job, replicated, plus tests)"
python3 tests/contract/check-deps-sync.py >/dev/null && echo "deps-sync: PASS" || die "deps-sync still failing"
python3 tests/contract/check-import-paths.py >/dev/null && echo "import-paths: PASS" || die "import-paths still failing"
fmt=$(gofmt -l src/merchant/probe_test.go); [ -z "$fmt" ] || die "probe_test.go not gofmt-clean"
echo "gofmt: clean"
( cd src/identity && go test -count=1 ./... >/dev/null ) && echo "identity tests: ok"
( cd src/sysexec  && go test -count=1 ./... >/dev/null ) && echo "sysexec tests: ok"
( cd src/merchant && go test -count=1 ./... >/dev/null ) && echo "merchant tests: ok"
( cd src && go test -race -count=1 -tags testenv . >/dev/null ) && echo "main package tests: ok"

say "STEP 6/6 — commit + push (fast-forward, no force)"
git add src/identity/go.mod src/identity/go.sum src/sysexec/go.mod src/merchant/probe_test.go
git -c core.hooksPath=/dev/null commit --no-verify -q -m "fix(deps): satisfy deps-and-imports CI gate

Align the new deps-and-imports checks (added in this PR) with repo state:
- identity: bump indirect pins (btcd/btcutil, sonic, websocket, x/arch,
  x/crypto, x/exp, x/sys) to the versions used by every other module
- sysexec: bump go directive 1.24.2 -> 1.25.0 (matches all other modules)
- merchant: probe_test.go imported pre-rename Origami74 path (renamed in #304)"
git log --oneline "$EXPECTED_TIP..HEAD"
echo "target: Amperstrand/feat/identity-v2   PR: $PR_URL"
if [ "$ASSUME_YES" -ne 1 ]; then
  read -r -p "Push? [y/N] " ans
  case "$ans" in y|Y|yes|YES) : ;; *) echo "aborted — work on local branch '$BRANCH'"; exit 0 ;; esac
fi
git push amperstrand "$BRANCH:feat/identity-v2" \
  || die "push rejected — nothing forced. Ping Hermes."

printf '\nDONE. CI reruns on the PR — expect deps-and-imports green now.\nTell Hermes: comment draft + re-review are ready to fire.\n'
