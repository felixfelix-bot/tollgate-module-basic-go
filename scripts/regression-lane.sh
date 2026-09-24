#!/usr/bin/env bash
#
# Regression lanes for tollgate-wrt — ONE entry point for humans, agents and CI.
#
#   scripts/regression-lane.sh --lane all            # module lane + cloud lab
#   scripts/regression-lane.sh --lane module         # built artifact + real browser
#   scripts/regression-lane.sh --lane cloud-lab      # docker compose mint+router+client
#
# Options:
#   --artifact DIR   use an already-staged artifact instead of building one
#   --out DIR        evidence directory (default: a fresh dir under HP_TMPDIR)
#   --skip-portal    module lane: module checks only (no browser)
#   --require-docker cloud-lab lane: a missing docker/compose is a FAIL, not a SKIP
#   --keep           keep the cloud-lab containers and the work dir for inspection
#
# WHAT THE LANES COVER (see REGRESSION.md for the full inventory and the honest
# list of what NOTHING automates):
#
#   module     stages an extracted-package-shaped artifact from this checkout
#              (tests/happy-path/stage-artifact.sh) and runs
#              `tests/happy-path/run.sh` against it: module API contract
#              (kind:10021, /whoami, /balance, /usage, /session-state, the
#              /ln-invoice no-quote 400 status-poll contract), enforcement (no gate
#              on an unredeemable token, gate opens on a recognised payment —
#              proven from the fake-ndsctl log), and the guest SPA purchase UI in
#              a real browser against the live module.
#              Needs: go, node+npm (pinned), python3 with playwright chromium.
#
#   cloud-lab  tests/cloud-lab/ docker-compose lane: a real cdk-mintd mint, the
#              real module binary in a container (fake ndsctl for the gate), and a
#              python client. Covers payment end to end, mint-failure/degraded
#              recovery, and (opt-in) the two-router reseller chain.
#              Needs: docker + the compose plugin.
#
# OUTPUT: one machine-readable line per lane, then a summary.
#   LANE <module|cloud-lab> <PASS|FAIL|SKIP> <detail>
#   LANES total=N pass=N fail=N skip=N
# Exit status: non-zero when a lane that RAN failed. A SKIP is not a failure
# unless --require-docker was passed (that is the shape the release gate uses).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

LANE="all"
ARTIFACT=""
OUT=""
SKIP_PORTAL=0
REQUIRE_DOCKER=0
KEEP=0
CLOUD_LAB_TESTS="test_smoke_payment.py"

usage() { sed -n '3,45p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --lane)          LANE="${2:-}"; shift 2 ;;
        --artifact)      ARTIFACT="${2:-}"; shift 2 ;;
        --out)           OUT="${2:-}"; shift 2 ;;
        --skip-portal)   SKIP_PORTAL=1; shift ;;
        --tests)         CLOUD_LAB_TESTS="${2:-}"; shift 2 ;;
        --require-docker) REQUIRE_DOCKER=1; shift ;;
        --keep)          KEEP=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$LANE" in
    all|module|cloud-lab) ;;
    *) echo "ERROR: --lane must be one of all|module|cloud-lab (got '$LANE')" >&2; exit 2 ;;
esac

# /tmp on this fleet is a small tmpfs: never stage an artifact or extract a
# package there.
TMP_PARENT="${HP_TMPDIR:-/var/tmp}"
WORK="$(mktemp -d "$TMP_PARENT/tg-regression.XXXXXX")" || exit 1
EVIDENCE="${OUT:-$WORK/evidence}"
mkdir -p "$EVIDENCE" || exit 1

TOTAL=0; PASSED=0; FAILED_N=0; SKIPPED=0
FAILED_LANES=""

lane() {  # lane <name> <PASS|FAIL|SKIP> <detail>
    local name="$1" status="$2"; shift 2
    local detail="${*:-}"
    TOTAL=$((TOTAL + 1))
    case "$status" in
        PASS) PASSED=$((PASSED + 1)) ;;
        SKIP) SKIPPED=$((SKIPPED + 1)) ;;
        FAIL) FAILED_N=$((FAILED_N + 1)); FAILED_LANES="$FAILED_LANES $name" ;;
    esac
    printf 'LANE %s %s %s\n' "$name" "$status" "$detail"
}

cleanup() {
    if [ "$KEEP" != "1" ]; then
        rm -rf "$WORK"
    else
        echo "LANENOTE work dir kept: $WORK"
    fi
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# lane module — the built artifact, the real module binary, a real browser
# ---------------------------------------------------------------------------
run_module_lane() {
    local art="$ARTIFACT"
    if [ -z "$art" ]; then
        art="$WORK/artifact"
        echo "=== lane module: staging an artifact from this checkout ==="
        local stage_args=(--out "$art")
        if ! bash tests/happy-path/stage-artifact.sh "${stage_args[@]}" > "$EVIDENCE/stage-artifact.log" 2>&1; then
            tail -20 "$EVIDENCE/stage-artifact.log" >&2
            lane module FAIL "artifact staging failed (see $EVIDENCE/stage-artifact.log)"
            return
        fi
    fi
    if [ ! -d "$art" ]; then
        lane module FAIL "artifact directory not found: $art"
        return
    fi

    local args=(--artifact "$art" --out "$EVIDENCE/happy-path")
    [ "$SKIP_PORTAL" = "1" ] && args+=(--skip-portal)
    echo "=== lane module: tests/happy-path/run.sh ${args[*]} ==="
    HP_TMPDIR="$TMP_PARENT" bash tests/happy-path/run.sh "${args[@]}" 2>&1 | tee "$EVIDENCE/happy-path.log"
    local rc="${PIPESTATUS[0]}"
    local summary
    summary="$(grep -E '^HPRESULT ' "$EVIDENCE/happy-path.log" | tail -1)"
    if [ "$rc" = "0" ]; then
        lane module PASS "${summary:-exit 0} (log: $EVIDENCE/happy-path.log)"
    else
        lane module FAIL "exit $rc ${summary:-}; failures:$(grep -E '^HPCHECK .* FAIL' "$EVIDENCE/happy-path.log" | awk '{print " " $2}') (log: $EVIDENCE/happy-path.log)"
    fi
}

# ---------------------------------------------------------------------------
# lane cloud-lab — docker compose: real mint, real binary, python client
# ---------------------------------------------------------------------------
docker_preflight() {
    # Echoes the reason it cannot run, or nothing when it can. Every check is
    # named, so a SKIP is attributable instead of mysterious.
    command -v docker >/dev/null 2>&1 || { printf 'docker CLI not on PATH'; return; }
    docker info >/dev/null 2>&1     || { printf 'no reachable docker daemon (docker info failed)'; return; }
    docker compose version >/dev/null 2>&1 || { printf 'docker compose plugin missing'; return; }
    printf ''
}

run_cloud_lab_lane() {
    local why
    why="$(docker_preflight)"
    if [ -n "$why" ]; then
        if [ "$REQUIRE_DOCKER" = "1" ]; then
            lane cloud-lab FAIL "$why (--require-docker)"
        else
            lane cloud-lab SKIP "$why"
        fi
        return
    fi

    cd "$REPO_ROOT/tests/cloud-lab" || { lane cloud-lab FAIL "tests/cloud-lab missing"; return; }
    local compose=(docker compose -p tollgate-regression -f docker-compose.yml)
    local rc=0

    echo "=== lane cloud-lab: building + starting mint and upstream ==="
    if ! "${compose[@]}" up -d --build mint upstream 2>&1 | tee "$EVIDENCE/cloud-lab-up.log"; then
        lane cloud-lab FAIL "docker compose up failed (log: $EVIDENCE/cloud-lab-up.log)"
        [ "$KEEP" = "1" ] || "${compose[@]}" down -v >/dev/null 2>&1
        cd "$REPO_ROOT"; return
    fi

    # The module and the mint publish ports on the host; poll them rather than
    # trusting `compose up` to mean "healthy enough to answer".
    local up=0 i
    for i in $(seq 1 60); do
        if curl -sf -m 3 -o /dev/null http://127.0.0.1:8085/v1/keys \
           && curl -sf -m 3 -o /dev/null http://127.0.0.1:2121/; then
            up=1; break
        fi
        sleep 2
    done
    if [ "$up" != "1" ]; then
        # Say WHY, in the job log and in the evidence dir: `ps` shows a container
        # that exited (and its exit code) while `logs` shows the module refusing
        # to boot. Without this the first real CI run reported only "did not
        # answer within 120s" and the reason died with the act container.
        {
            echo "=== compose ps ==="
            "${compose[@]}" ps -a
            for svc in mint upstream; do
                echo "=== docker logs --tail 60 $svc ==="
                "${compose[@]}" logs --no-color --tail 60 "$svc" 2>&1
            done
        } > "$EVIDENCE/cloud-lab-ps.log" 2>&1 || true
        tail -40 "$EVIDENCE/cloud-lab-ps.log" 2>/dev/null || true
        lane cloud-lab FAIL "mint/upstream did not answer on :8085/:2121 within 120s (log: $EVIDENCE/cloud-lab-ps.log)"
        [ "$KEEP" = "1" ] || "${compose[@]}" down -v >/dev/null 2>&1
        cd "$REPO_ROOT"; return
    fi

    echo "=== lane cloud-lab: client pytest $CLOUD_LAB_TESTS ==="
    # shellcheck disable=SC2086
    "${compose[@]}" run --rm client pytest -sv --tb=short --color=no $CLOUD_LAB_TESTS \
        2>&1 | tee "$EVIDENCE/cloud-lab-tests.log"
    rc="${PIPESTATUS[0]}"

    if [ "$KEEP" != "1" ]; then
        "${compose[@]}" down -v >/dev/null 2>&1 || true
    else
        echo "LANENOTE cloud-lab containers kept (docker compose -p tollgate-regression ps)"
    fi
    cd "$REPO_ROOT"

    if [ "$rc" = "0" ]; then
        lane cloud-lab PASS "pytest $CLOUD_LAB_TESTS exit 0 (log: $EVIDENCE/cloud-lab-tests.log)"
    else
        lane cloud-lab FAIL "pytest exit $rc (log: $EVIDENCE/cloud-lab-tests.log)"
    fi
}

echo "REGRESSION lane=$LANE work=$WORK"
case "$LANE" in
    module)    run_module_lane ;;
    cloud-lab) run_cloud_lab_lane ;;
    all)       run_module_lane; run_cloud_lab_lane ;;
esac

printf '\nLANES total=%d pass=%d fail=%d skip=%d%s\n' \
    "$TOTAL" "$PASSED" "$FAILED_N" "$SKIPPED" \
    "$( [ -n "$FAILED_LANES" ] && printf ' failed:%s' "$FAILED_LANES" )"
if [ -d "$EVIDENCE" ]; then
    echo "LANEEVIDENCE $EVIDENCE"
fi
[ "$FAILED_N" = "0" ] || exit 1
exit 0
