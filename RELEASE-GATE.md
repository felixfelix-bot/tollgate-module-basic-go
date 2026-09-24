# RELEASE-GATE.md — the lanes that must be green before a feed bump

This is the **single place** that states the release gate for `tollgate-wrt`.
`REGRESSION.md` (this repo and the portal repo) describes the lanes; this file
says which of them the release decision depends on, in what order, and how the
green is proven.

Two things are operator-only and are never automated — the **release tag** and
the **publish** (`docs/release-process.md`). Everything below is what must be
true *before* the operator is asked to do either.

## The gate, in order

| # | Lane | Where | Green means | How it is proven |
| --- | --- | --- | --- | --- |
| 1 | **Go / contract lanes** — `test.yml` + `go-test.yml` | ngit CI | `success` at the exact commit being released | `ngit ci status <commit>` (signed 9842 events; `.ngit/README.md`) — or `make go-battery` on that commit as the local equivalent |
| 2 | **Happy path on a built artifact** — `regression.yml` job `happy-path` | ngit CI | `LANE module PASS` — `tests/happy-path/run.sh` reported `fail=0` **and** actually ran every check (no silent skip) | the job log (`HPCHECK`/`HPRESULT`/`HPEXIT` lines); locally: `make regression-module` |
| 3 | **Cloud lab** — `regression.yml` job `cloud-lab` | ngit CI (docker) | `LANE cloud-lab PASS` — the `tests/cloud-lab` payment path against a real `cdk-mintd` mint | the job log; locally: `make regression-cloud-lab` (`--require-docker` so a missing docker cannot pass silently) |
| 4 | **Published bytes, not branch bytes** — the happy-path suite against the **extracted release package** | release host / operator window | the suite is green on the artifact that will actually be published (`--artifact` = the extracted `.apk`/`.ipk`), with `--strict` once the release ships `/session-state` and the in-page renewal CTA | the run's `HPRESULT`/`HPEXIT` and the artifact's printed sizes/sha256s (`tests/happy-path/README.md`) |
| 5 | **Feed build** — `FreedomTechFeed/packages` re-pins this commit and re-vendors the portal bundle from the same commit | the feed repo's own CI | the feed's validate/build lane is green and the feed's artifact carries the pinned portal bundle | the feed repo's CI + `docs/release-process.md` §feed |
| 6 | **Publication gate** — `verify-publication` | ngit CI, `verify/<version>/<channel>` ref | every `(arch, format)` in the release matrix has a kind-1063 announcement and every artifact is fetchable from ≥ 2 Blossom mirrors with the announced sha256 | the gate's own output (`scripts/verify_publication.sh`) |

Anything not green in rows 1–3 at the commit being released is a **stop**: do
not ask the operator for a tag, and do not prepare the feed bump. Rows 4–6 are
the release's own steps; each one is the gate for the next.

## Advisory (in the inventory, not in the gate)

* **`repro-check.yml`** (byte-identical rebuild) is **RED on `main`** as of
  2026-09-24 — a real lane with a real failure, and deliberately *not* listed
  above while it is red. A gate that depends on a permanently red lane is a gate
  that gets ignored. It becomes required again the day it is green on `main`.
  (Its verdict is not the same thing as `scripts/repro-test.sh`, which is used
  for a specific target on a build host.)
* **Visual review of the portal UI** — the browser lane captures what rendered;
  whether it looks right is a human judgement, and
  `tollgate-captive-portal-site`'s `visual.spec.mjs` is informational.
* **Cross-architecture behaviour** — the regression lane stages x86_64 because it
  runs the artifact's binary on the CI host. Per-architecture bytes are the
  packaging shards' and `repro-test.sh`'s job; the *behaviour* checks are
  architecture-independent by construction.

## What is never automated (and therefore never a "green lane")

* the **hardware happy path** on a real router (real `ndsctl`, nftables/fw4,
  Wi-Fi, DHCP/ARP) — the manual pass in `docs/release-process.md` is the gate
  for it, and `tests/router-happy-path/` automates the *checking*, not the
  *running*, because it needs a device;
* **real mints and real ecash** — the stub mint and the FakeWallet mint never
  settle a payment against a production mint;
* the **feed bump and publish** — operator actions;
* the **installer path** — `tollgate-installer` resolves the newest feed alpha
  and therefore always lags the branch under test.

## Promoting order (unchanged, restated for clarity)

1. build from the **unmerged branch**, publish a hand-deploy artifact;
2. operator runs the manual hardware pass;
3. merge;
4. prepare the feed bump (portal merges first, feed re-pins atomically);
5. operator publishes.

The lanes above are what makes step 4 defensible instead of hopeful. Where the
promotion order and its rationale live: `docs/release-process.md` and the
`tollgate-development` skill; where a failure is diagnosed: `REGRESSION.md`.
