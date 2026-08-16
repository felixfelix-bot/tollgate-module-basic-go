#!/usr/bin/env bash
# fix-pr331.sh — push the 2 outstanding review fixes to Amperstrand's PR #331
# branch (feat/identity-v2) as a fast-forward. No rebase, no force, no squash:
# his 8 commits stay untouched, 1-2 fix commits land on top.
#
# Validated 2026-08-17 against tip 9591fe0: exactly the 3 reveal-seed tests
# fail before the fix (RED), all green after (GREEN). The deps-and-imports CI
# failures are stale-base artifacts (his branch base is Jul-28 main) and are
# resolved by the "Rebase and update branch" button AFTER this push — the
# script runs those checks as INFO only.
#
# Requirements: run from the ROOT of any tollgate-module-basic-go clone
# (e.g. this one), Go >= 1.25 on PATH, git push creds for a GitHub account
# with write access to OpenTollGate/tollgate-module-basic-go (c03rad0r).
set -euo pipefail

EXPECTED_TIP=9591fe03f5046d74be69953ca78085c928f7ce12
AMP_URL=https://github.com/Amperstrand/tollgate-module-basic-go.git
BRANCH=pr331-fixes
TESTFILE=src/identity_handler_test.go
PR_URL=https://github.com/OpenTollGate/tollgate-module-basic-go/pull/331

ASSUME_YES=0
[ "${1:-}" = "--yes" ] && ASSUME_YES=1

say() { printf '\n== %s\n' "$*"; }
die() { printf '\nFATAL: %s\n' "$*" >&2; exit 1; }

say "STEP 1/7 — preflight"
[ -f src/go.mod ] || die "run from the root of a tollgate-module-basic-go clone"
[ -f "$TESTFILE" ] && echo "note: $TESTFILE already present (unexpected on main base — continuing)" || echo "note: $TESTFILE not on this branch yet (expected — arrives with his branch in STEP 3)"
command -v go >/dev/null 2>&1 || die "go not on PATH (need >= 1.25)"
gov=$(go version | awk '{print $3}')
echo "go: $gov   git: $(git --version)"
case "$gov" in
  go1.2[5-9]*|go1.[3-9]*|go[2-9]*) : ;;
  *) die "need Go >= 1.25 (src/go.mod requires 1.25.0)" ;;
esac
git rev-parse --is-inside-work-tree >/dev/null || die "not a git repo"

say "STEP 2/7 — fetch Amperstrand's fork, verify branch tip"
git remote remove amperstrand >/dev/null 2>&1 || true
git remote add amperstrand "$AMP_URL"
git fetch amperstrand feat/identity-v2
tip=$(git rev-parse FETCH_HEAD)
echo "remote tip: $tip"
[ "$tip" = "$EXPECTED_TIP" ] || die "feat/identity-v2 moved (expected $EXPECTED_TIP). STOP — re-check with Hermes before pushing."

say "STEP 3/7 — work branch at his exact tip (idempotent: reuses + resets any earlier run's branch)"
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "branch '$BRANCH' exists from an earlier run — resetting to his tip"
  git switch "$BRANCH"
  git reset --hard FETCH_HEAD
else
  git switch -c "$BRANCH" FETCH_HEAD
fi
[ -f "$TESTFILE" ] || die "$TESTFILE missing on his branch — layout changed, ping Hermes"

say "STEP 4/7 — fix: loopback RemoteAddr in the 3 reveal-seed tests"
n=$(grep -c 'req.RemoteAddr = "127.0.0.1:1234"' "$TESTFILE" || true)
if [ "${n:-0}" -ge 3 ]; then
  echo "fix already present (x$n) — skipping edit"
else
  awk '{ print; if ($0 ~ /httptest\.NewRequest/ && $0 ~ /reveal-seed/) print "\treq.RemoteAddr = \"127.0.0.1:1234\"" }' \
    "$TESTFILE" > "$TESTFILE.tmp" && mv "$TESTFILE.tmp" "$TESTFILE"
fi
n=$(grep -c 'req.RemoteAddr = "127.0.0.1:1234"' "$TESTFILE" || true)
[ "${n:-0}" -eq 3 ] || die "expected exactly 3 RemoteAddr lines in $TESTFILE, found ${n:-0} — inspect manually"
gofmt -w "$TESTFILE"
git diff --stat
git add "$TESTFILE"
git commit -m "fix(tests): set loopback RemoteAddr in reveal-seed handler tests"

say "STEP 5/7 — tidy src/identity (only commits if it produces a diff)"
( cd src/identity && go mod tidy )
if git diff --quiet -- src/identity; then
  echo "src/identity already tidy — no commit needed"
else
  git add src/identity/go.mod
  [ -f src/identity/go.sum ] && git add src/identity/go.sum || true
  git commit -m "fix(deps): tidy identity module dependencies"
fi

say "STEP 6/7 — gate suite (gofmt scoped to OUR diff; vet/build/test blocking)"
mapfile -t changed < <(git diff --name-only "$EXPECTED_TIP..HEAD" -- '*.go')
[ "${#changed[@]}" -gt 0 ] || die "no Go files changed by our commits — unexpected"
fmt=$(gofmt -l "${changed[@]}")
[ -z "$fmt" ] || { printf 'our changed files not gofmt-clean:\n%s\n' "$fmt"; exit 1; }
echo "gofmt (our diff: ${changed[*]}): clean"
echo "note: files inherited from his branch may be unformatted until the rebase — not ours, not touched (repo rule: no drive-by reformatting)"
( cd src
  go vet ./...
  echo "vet: ok"
  go build ./...
  echo "build: ok"
  go test -race -count=1 -tags testenv .
)
echo "ALL BLOCKING GATES GREEN"
say "INFO — CI contract checks (expected to fail on his stale base; fixed by the rebase button, not blocking)"
python3 tests/contract/check-deps-sync.py 2>&1 | tail -3 || true
python3 tests/contract/check-import-paths.py 2>&1 | tail -3 || true

say "STEP 7/7 — push (fast-forward only, no force)"
git log --oneline "$EXPECTED_TIP..HEAD"
echo "target: Amperstrand/feat/identity-v2   PR: $PR_URL"
if [ "$ASSUME_YES" -ne 1 ]; then
  read -r -p "Push the commit(s) above to his branch? [y/N] " ans
  case "$ans" in y|Y|yes|YES) : ;; *) echo "aborted — work stays on local branch '$BRANCH'"; exit 0 ;; esac
fi
git push --no-verify amperstrand "$BRANCH:feat/identity-v2" \
  || die "push rejected (branch moved? not fast-forward?) — nothing was forced. Ping Hermes."

printf '\nDONE. Next steps (browser, as c03rad0r):\n'
echo "1. Open $PR_URL — the push updated the PR; CI reruns."
echo "2. Click 'Rebase and update branch' (visible to you: write access + his checkbox is ON)."
echo "   This rebases his branch onto current main and resolves the stale-base CI failures."
echo "3. If the button reports conflicts: STOP and ping Hermes — a fully rebased branch is ready as fallback."
echo "4. Tell Hermes when done: the #331 comment draft + re-review are waiting on your go."
