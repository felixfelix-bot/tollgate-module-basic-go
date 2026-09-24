# REGRESSION.md — what actually runs, and what still only a human can do

Tests protect a release only if something **executes** them. This file is the
inventory for `tollgate-module-basic-go`: every lane that runs, where it runs,
the exact command, what it covers — and, at the end, the honest list of things
**nothing** automates.

For the release decision ("which lanes must be green before a feed bump"), see
[RELEASE-GATE.md](RELEASE-GATE.md). That is the single place that states the
gate; this file does not restate it.

## The one command

```bash
make regression            # module lane + cloud lab, one command
```

`make regression` is the same entry point CI runs
(`.ngit/act/workflows/regression.yml` calls `scripts/regression-lane.sh`
directly, with the same arguments). One definition per lane, no lane-local
command list that can drift from what a human runs.

```bash
make regression-module                          # no docker needed
make regression-cloud-lab                       # needs docker + the compose plugin
bash scripts/regression-lane.sh --lane module --artifact DIR --out EVIDENCE
```

Output is machine-readable — one line per lane, then a summary:

```
LANE module PASS HPRESULT total=23 pass=23 fail=0 skip=0 known=0 (log: …)
LANE cloud-lab SKIP docker compose plugin missing
LANES total=2 pass=1 fail=0 skip=1
LANEEVIDENCE /var/tmp/tg-regression.XXXXXX/evidence
```

A lane that **ran** and failed makes the command exit non-zero. A lane that
could not run says so with a named reason (`SKIP`); pass `--require-docker` to
the cloud-lab lane to make that a failure instead — that is the shape the
release gate uses.

## Lane inventory

| Lane | Engine | Triggered by | What it covers |
| --- | --- | --- | --- |
| `.ngit/act/workflows/test.yml` | **ngit CI** (Nostr) | push to `main`, PRs | the module matrix Go tests, the `testenv` main-package test, `js-schema-lint`, the spec-quote drift check, build purity, dependency/import-path checks |
| `.ngit/act/workflows/go-test.yml` | ngit CI | push to `main`, PRs | the AGENTS.md pre-PR gate: `gofmt -l .`, `go vet ./...`, `go build ./...`, `go test -race -count=1 -tags testenv ./...` |
| `.ngit/act/workflows/repro-check.yml` | ngit CI | push to `main`, PRs | byte-identical rebuild of both binaries in two independent clean roots (**RED on `main` — see below**) |
| `.ngit/act/workflows/regression.yml` *(new)* | ngit CI | push to `main`, PRs | **job `happy-path`**: stages an artifact from the commit under test and runs `tests/happy-path/run.sh` against it — module API contract, enforcement, and the guest SPA in a real browser. **job `cloud-lab`**: the `tests/cloud-lab` docker-compose lab |
| `.ngit/act/workflows/build-package-*.yml`, `build-package-announce.yml`, `verify-publication.yml` | ngit CI | push to `main` (stage 1), manual replay for the shards/announce, `verify/<version>/<channel>` ref for the gate | the release build → Blossom mirror → kind-1063 announce → publication gate chain (`scripts/ngit-ci-release.sh`) |
| `make go-battery` → `scripts/go-battery.sh` | any host (Go) | human / agent | the pre-PR Go gate across **all 16** nested modules (`./...` from `src/` reaches only the root module) |
| `make regression-module` | any host (Go, node+npm, python3+Playwright) | human / agent / CI | `tests/happy-path/run.sh` on an artifact staged from **this checkout**: kind-10021 advert, `/whoami`, `/balance`, `/usage`, `/session-state`, the `/ln-invoice` no-quote 400 status-poll contract, no gate on an unredeemable token, gate opens on a recognised payment (asserted from the fake-`ndsctl` log), and the portal purchase/expired/renewal flow in a real browser |
| `make regression-cloud-lab` | host with docker + compose | human / agent / CI | `tests/cloud-lab`: a real `cdk-mintd` (FakeWallet) mint, the real module binary in a container with the fake-`ndsctl` seam, and a python client — payment end to end, mint-failure/degraded recovery, rejection safety, keyset rotation, swap fees, two-router reseller autopay |
| `make reproducibility-test T=ipk\|apk\|portal\|binaries ARCH=…` → `scripts/repro-test.sh` | build host with docker | human / agent | byte-identical rebuild of a package target in two clean roots |
| `make reproducibility-variance` | host with `reprotest` | human / agent | rebuilds under hostile environment variation (umask, TZ, locales, ordering) |

The portal's own lanes are described in the portal repository's `REGRESSION.md`
(`tollgate-captive-portal-site`): the guest SPA has a vitest unit suite and a
Playwright browser lane, and the module's happy-path lane drives the *shipped*
bundle in a browser as well.

### What the module lane really proves (and what it fakes)

The artifact staged by `tests/happy-path/stage-artifact.sh` carries the same two
payload paths the `.ipk`/`.apk` ship — the module binary and the bundle built
from the portal commit pinned in `packaging/build-inputs.json` — and the suite
then:

* boots the **real** `tollgate-wrt` binary natively (no container needed: the
  staged build is static x86_64), with `tests/cloud-lab/fake-ndsctl.sh` on
  `PATH` as the one enforcement seam;
* talks to an **offline Python stub mint** (`tests/happy-path/stubs/stub_mint.py`)
  — never a real mint, never real ecash, no secret, no spend;
* drives the **real** portal bundle in Chromium against the live module
  (`tests/happy-path/stubs/portal_drive.py`, served on `127.0.0.2` on purpose —
  the bundle has a `hostname === "localhost"` dev-mock branch that would bypass
  the real code path).

It is not a substitute for hardware: no kernel, no nftables/fw4, no conntrack,
no real `ndsctl`, no Wi-Fi, no DHCP/ARP. Those stay with
`physical-router-test-automation` and the hardware harness below.

### Toolchains: the lane runs on the host it is on

`tests/happy-path/stage-artifact.sh` stages with whatever Go, node and npm the
host has, printing a `NOTE:` when either differs from the pin in
`packaging/build-inputs.json` (measured 2026-09-24 on this fleet: host node
`v22.22.1` / npm `9.2.0` against the manifest's `22.17.0` / `10.9.2`). That is
deliberate — this lane checks behaviour, and byte-identity belongs to the repro
lane — but it means a green run here says nothing about the shipped bytes. The
ngit CI job resolves both toolchains from the manifest, so a CI green is a
pinned-toolchain green, while a local green is a behaviour green on the host's
toolchain. `packaging/`'s own guard is untouched: a packaging or release build
still refuses a mismatched toolchain.

### The two failures the first CI run of this lane surfaced (fixed 2026-09-24)

The lane ran on the coordinator for the first time on 2026-09-24 and failed BOTH
jobs for environment reasons the lane itself had never been able to see:

* **`cloud-lab` — the lab's inputs were bind-mounted from the checkout.** A bind
  source is resolved by the DOCKER DAEMON, not by the CLI: in an `act` job the
  CLI is inside the act container while the daemon is the host's, so
  `./configs/upstream-config.json` arrived as an empty DIRECTORY and the module
  refused to boot (`read /etc/tollgate/config.json: is a directory`). The lab
  configs are now **baked into the image** (`tests/cloud-lab/Dockerfile.tollgate`
  + `lab-entrypoint.sh`, selected per service by `LAB_CONFIG`/`LAB_LEASES`), and
  the client's `/tests` directory is staged to the daemon on demand by
  `tests/cloud-lab/stage-checkout.sh` (a probe, then `tar` over stdin through
  `docker run -i`, so no shared filesystem is assumed). Locally both are no-ops.
* **`happy-path` — the suite had no identity source of its own.** The module
  resolves a caller's MAC from the socket (`dhcpLeasePath`, then `/proc/net/arp`),
  and the suite relied on the operator having seeded `/tmp/dhcp.leases` by hand —
  true on this fleet, false in a container, where `api:whoami` answered an empty
  `mac` and `POST /ln-invoice` returned 400 `device-unresolved` (20/23). Section 1b
  of `tests/happy-path/run.sh` now seeds the fixture itself and restores the host's
  file on exit, with `api:whoami-unresolved-client-not-keyed` as the control.

### Reading a result

* **ngit CI** publishes signed results to Nostr — there is no web URL. Read them
  with the CLI: `ngit ci status <commit>` (per-workflow conclusions), or the raw
  kind-9842 events from `wss://relay.ngit.dev` / `wss://gitnostr.com`.
* The coordinator's identity matters: results are signed by whoever ran them
  (`.ngit/README.md` documents the policy). A `timed_out` from someone else's
  coordinator is that operator's environment limit, not a defect in the commit.
* `repro-check.yml` is currently **RED on `main`** (last results: failure at
  `refs/heads/main`, e.g. 2026-09-24 11:27 UTC). It is in the inventory as a
  real lane, not as a green one: treat its verdict as advisory until it is
  fixed, and do not read a release as gated on it (see RELEASE-GATE.md for the
  lanes that *are* required).

## What NOTHING automates

Be explicit about this list — it is where regressions still escape.

| Not automated | Why | Who owns it |
| --- | --- | --- |
| **The hardware happy path on a real router** (install, captive redirect on real silicon, real `ndsctl`/nftables enforcement, Wi-Fi association, DHCP/ARP) | needs a physical MT3000 and root on it; the fleet's harness for it (`tests/router-happy-path/`, build-identity + captive-chain + API shapes) lives on the fork branch `pr/router-happy-path-harness` and is **manual-only** | operator, per `docs/release-process.md` |
| **Real mints and real ecash** | the module lane uses an offline stub mint and the cloud lab uses `cdk-mintd` with the FakeWallet backend; no payment is ever settled against a production mint | operator (hardware pass) |
| **The feed bump / publish** | publishing to a shared feed is an operator action — an agent prepares, the operator ships (`docs/release-process.md`) | operator |
| **Visual review of the portal UI** | screenshots are captured by the browser lane, but a human decides whether the rendered result is *right*; `tests/e2e/visual.spec.mjs` on the portal side is informational | human reviewer |
| **The installer path** | `tollgate-installer` resolves the newest **feed** alpha, so it always lags the branch artifact; an installer run is not a test of a branch | operator |
| **Cross-architecture behaviour in the regression lane** | the regression lane stages an x86_64 artifact (it runs the binary on the CI host). Release-architecture bytes are the packaging lanes' and `repro-test.sh`'s job | packaging lanes |
| **GitHub Actions** | dead for this org: workflow runs sit `queued` indefinitely (module repo: `Graph Update` runs queued for 17 h; portal repo: last CI run 2026-07-28). `.github/workflows/` is kept for the day Actions returns, and anything that must run today is ported to `.ngit/act/workflows/` | infra |

## History: why this file exists

Until 2026-09-24 the repository had a happy-path suite (`tests/happy-path/`)
and a cloud lab (`tests/cloud-lab/`) that **nothing executed**: the happy-path
gate written into `.github/workflows/build-package.yml` could not run (Actions
dead), and ngit CI reads `.ngit/act/workflows/` only, where no lane ran either
suite. The portal's browser lane was additionally broken at module load, so the
portal merges of 2026-09-23 were never CI-verified. `.ngit/act/workflows/regression.yml`
plus `scripts/regression-lane.sh` are the fix: one command, two engines, real
execution.
