#!/usr/bin/env bash
# Tag the tollgate-wrt pre21 release.
#
# Tag push is the ONLY trigger for the release job (a ~45-minute, 14-arch
# build), so this script does exactly one privileged thing: create the tag on
# the merged commit. Every precondition fails CLOSED, and the script is safe to
# re-run — it exits early if the tag is already there.
#
# Tag name is the PKG_VERSION mirror per the feed's own rule (drop the leading
# 'v', turn '-' into '_'):  v0.6.0-alpha4-pre21  <->  0.6.0_alpha4_pre21
set -uo pipefail

REPO=FreedomTechFeed/packages
COMMIT=dfb0f01fdbb93aa46f1308dfc3c4c50e1fc90fa0
TAG=v0.6.0-alpha4-pre21
WANT_VERSION=0.6.0_alpha4_pre21
WANT_PIN=74cd6f994864d685016b5eb97617c86fd2dbc967
WANT_HASH=3f281ce2c9c28e8c8eaf02567115c62c7b3c7674246c407d45cdf9e97edcb57e
PREV_TAG=v0.6.0-alpha4-pre20

ok()  { printf '  [ok] %s\n' "$*"; }
die() { printf '\nFATAL: %s\n' "$*" >&2; exit 1; }

printf '\n== tollgate-wrt %s  ->  tag %s  on  %s ==\n\n' "$WANT_VERSION" "$TAG" "$REPO"

command -v gh >/dev/null 2>&1 || die "the gh CLI is not installed"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login)"

printf 'authenticated as: '
gh api user --jq .login || die "cannot read the authenticated user"

TIP=$(gh api "repos/$REPO/commits/master" --jq .sha) || die "cannot read $REPO master"
if [ "$TIP" != "$COMMIT" ]; then
  die "master is $TIP but the merged pre21 commit is $COMMIT — master moved since the merge; stop and re-check"
fi
ok "master is the merged pre21 commit ($COMMIT)"

MKDIR_URL="repos/$REPO/contents/net/tollgate-wrt/Makefile?ref=$COMMIT"
MK=$(gh api "$MKDIR_URL" --jq .content | base64 -d)
V=$(printf '%s\n' "$MK" | grep -E '^PKG_VERSION:=' || true)
P=$(printf '%s\n' "$MK" | grep -E '^PKG_SOURCE_VERSION:=' || true)
H=$(printf '%s\n' "$MK" | grep -E '^PKG_HASH:=' || true)

if [ "$V" != "PKG_VERSION:=$WANT_VERSION" ]; then
  die "the Makefile at master says '$V', expected 'PKG_VERSION:=$WANT_VERSION'"
fi
if [ "$P" != "PKG_SOURCE_VERSION:=$WANT_PIN" ]; then
  die "the module pin at master is '$P', expected the pre21 pin"
fi
if [ "$H" != "PKG_HASH:=$WANT_HASH" ]; then
  die "the PKG_HASH at master is '$H', expected the pre21 hash"
fi
ok "$V"
ok "$P"
ok "$H  (matches the tarball hash computed for the pin)"

if gh api "repos/$REPO/git/refs/tags/$TAG" >/dev/null 2>&1; then
  printf '\nTag %s already exists — nothing to do.\n' "$TAG"
  printf 'Release page: https://github.com/%s/releases/tag/%s\n\n' "$REPO" "$TAG"
  exit 0
fi

# Mirror the previous tag's kind rather than assuming: an annotated tag is
# created via git/tags, a lightweight one points straight at the commit.
PTYPE=$(gh api "repos/$REPO/git/refs/tags/$PREV_TAG" --jq .object.type 2>/dev/null || echo commit)

if [ "$PTYPE" = "tag" ]; then
  REFSHA=$(gh api -X POST "repos/$REPO/git/tags" -f tag="$TAG" -f message="tollgate-wrt $WANT_VERSION" -f object="$COMMIT" -f type=commit --jq .sha) || die "could not create the annotated tag object"
  ok "annotated tag object created (same kind as $PREV_TAG)"
else
  REFSHA="$COMMIT"
  ok "lightweight tag (same kind as $PREV_TAG)"
fi

gh api -X POST "repos/$REPO/git/refs" -f ref="refs/tags/$TAG" -f sha="$REFSHA" --jq .ref >/dev/null || die "could not push the tag"

printf '\n[ok] tag %s created at %s\n' "$TAG" "$COMMIT"
printf 'Release page: https://github.com/%s/releases/tag/%s\n' "$REPO" "$TAG"
printf 'Actions:      https://github.com/%s/actions\n\n' "$REPO"

printf 'Waiting for the release workflow to register (a tag push starts a ~45 min, 14-arch build)...\n'
FOUND=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  FOUND=$(gh api "repos/$REPO/actions/runs?per_page=20" --jq "[.workflow_runs[] | select(.head_branch == \"$TAG\")][0].html_url" 2>/dev/null || true)
  if [ -n "$FOUND" ] && [ "$FOUND" != "null" ]; then break; fi
  sleep 12
done

if [ -n "$FOUND" ] && [ "$FOUND" != "null" ]; then
  printf '\n[ok] release run started:\n%s\n\n' "$FOUND"
  printf 'The 14-arch build + offline bundles + SHA256SUMS signing run there.\n'
  printf 'Nothing further is needed from you until it finishes.\n\n'
else
  printf '\nThe tag exists, but no run had registered yet.\n'
  printf 'Check https://github.com/%s/actions within a minute.\n\n' "$REPO"
fi
