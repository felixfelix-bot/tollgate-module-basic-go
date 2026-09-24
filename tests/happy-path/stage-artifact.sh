#!/usr/bin/env bash
#
# Stage an extracted-package-shaped artifact for the happy-path suite from THIS
# checkout, so the suite can run on a commit that has no published package yet.
#
#   tests/happy-path/stage-artifact.sh --out DIR [--skip-bundle] [--no-cli]
#
# Produces (the two paths the suite asserts on, plus the CLI for payload parity):
#
#   <out>/usr/bin/tollgate-wrt                        module binary, linux/amd64, static
#   <out>/usr/bin/tollgate                            CLI binary (same payload path)
#   <out>/etc/tollgate/tollgate-captive-portal-site/  guest SPA, built from the portal
#                                                     commit pinned in
#                                                     packaging/build-inputs.json
#
# WHY THIS EXISTS: tests/happy-path/run.sh asserts on the bytes a user would
# install — the module binary and the captive-portal bundle inside the package.
# In CI there is no published package for the commit under test, so the lane has
# to build one. This stages the same payload paths the .ipk/.apk carry, using the
# repo's own canonical builders (`packaging/build-env.sh` for the ldflags and pin
# checks, `packaging/portal-build.sh` for the bundle) rather than a second copy
# of them — so a pin change or an ldflag change lands in one place.
#
# x86_64 ON PURPOSE: the suite runs the artifact's binary on the machine that
# builds it. Release-architecture bytes (and their reproducibility) are
# scripts/repro-test.sh's and the packaging lanes' job, not this lane's.
#
# Exit 0 = the artifact is complete and the suite can run against it.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

OUT=""
SKIP_BUNDLE=0
BUILD_CLI=1

usage() { sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --out)          OUT="${2:-}"; shift 2 ;;
        --skip-bundle)  SKIP_BUNDLE=1; shift ;;
        --no-cli)       BUILD_CLI=0; shift ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ -z "$OUT" ]; then
    echo "ERROR: --out DIR is required" >&2
    exit 2
fi
mkdir -p "$OUT" || exit 1
OUT="$(cd "$OUT" && pwd)"

# build-env.sh owns the pinned inputs, SOURCE_DATE_EPOCH and the ldflags. It
# refuses to run without jq, and it dies when the tree has no readable git
# history — both are loud on purpose; do not paper over them here.
#
# TG_ROOT must be exported first: build-env.sh derives it from $0, which is
# correct only for callers that live in packaging/. Sourced from here it would
# resolve to tests/ and look for tests/packaging/build-inputs.json.
TG_ROOT="$REPO_ROOT"
export TG_ROOT
# shellcheck source=../../packaging/build-env.sh
. "$REPO_ROOT/packaging/build-env.sh" || exit 1

PKG_VERSION="${PKG_VERSION:-$(cat "$REPO_ROOT/VERSION" 2>/dev/null || echo 0.0.0)}"
LDFLAGS="$(go_ldflags "$PKG_VERSION")" || exit 1
ACTIVE_GO="$(go version 2>/dev/null | awk '{print $3}' | sed 's/^go//')"
if [ "$ACTIVE_GO" != "$GO_VERSION" ]; then
    # Not fatal: this lane checks behaviour, not byte-identity (the repro lane
    # owns the exact-patch requirement). Say it, so a green run is attributable.
    echo "NOTE: go $ACTIVE_GO != pinned $GO_VERSION (packaging/build-inputs.json);" >&2
    echo "      this lane tests behaviour, so it proceeds — the repro lane is the byte gate." >&2
fi

echo "=== staging artifact: $OUT (version $PKG_VERSION, go ${ACTIVE_GO:-unknown}) ==="
mkdir -p "$OUT/usr/bin"

echo "--- module binary (usr/bin/tollgate-wrt) ---"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -C src -o "$OUT/usr/bin/tollgate-wrt" \
    -trimpath -buildvcs=false -ldflags="$LDFLAGS" main.go || exit 1

if [ "$BUILD_CLI" = "1" ]; then
    echo "--- CLI binary (usr/bin/tollgate) ---"
    CLI_LDFLAGS="$(cli_ldflags "$PKG_VERSION")" || exit 1
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
        go build -C src/cmd/tollgate-cli -o "$OUT/usr/bin/tollgate" \
        -trimpath -buildvcs=false -ldflags="$CLI_LDFLAGS" || exit 1
fi

if [ "$SKIP_BUNDLE" = "1" ]; then
    echo "NOTE: --skip-bundle — no portal bundle staged; tests/happy-path/run.sh" >&2
    echo "      will report artifact:portal-bundle FAIL and skip the browser checks." >&2
else
    # The bundle comes from packaging/portal-build.sh: it enforces the
    # portal.commit pin, verifies the pinned node/npm, and refuses a pinned tree
    # that cannot produce the whole bundle. Reimplementing that here would be a
    # second, drifting definition of "the bundle".
    #
    # PORTAL_DIR must NOT live under /tmp: a checked-out portal tree plus its
    # node_modules does not fit the small tmpfs quota this fleet runs with.
    PORTAL_SRC="${TG_PORTAL_SRC:-/var/tmp/tollgate-portal-src}"
    echo "--- guest SPA (etc/tollgate/tollgate-captive-portal-site) from the pinned portal commit ---"
    echo "    portal source: $PORTAL_SRC"
    OUTPUT_DIR="$OUT/etc/tollgate/tollgate-captive-portal-site" \
    ADMIN_OUTPUT_DIR="$OUT/www/tollgate" \
    PORTAL_DIR="$PORTAL_SRC" \
        bash packaging/portal-build.sh || exit 1
fi

echo "=== staged artifact ==="
FAILED=0
for f in usr/bin/tollgate-wrt etc/tollgate/tollgate-captive-portal-site/splash.html; do
    if [ -e "$OUT/$f" ]; then
        printf '  ok    %s (%s bytes)\n' "$f" "$(stat -c %s "$OUT/$f" 2>/dev/null || echo '?')"
    else
        printf '  MISSING %s\n' "$f"
        [ "$SKIP_BUNDLE" = "1" ] && [ "$f" = "etc/tollgate/tollgate-captive-portal-site/splash.html" ] && continue
        FAILED=1
    fi
done
if [ -f "$OUT/usr/bin/tollgate-wrt" ]; then
    echo "  module binary sha256: $(sha256sum "$OUT/usr/bin/tollgate-wrt" | cut -c1-32)…"
fi
if [ -d "$OUT/etc/tollgate/tollgate-captive-portal-site/assets" ]; then
    echo "  portal bundles: $(ls "$OUT/etc/tollgate/tollgate-captive-portal-site/assets"/index-*.js 2>/dev/null | wc -l) index-*.js"
fi
[ "$FAILED" = "0" ] || { echo "ERROR: artifact incomplete" >&2; exit 1; }
echo "ARTIFACT DIR $OUT"
