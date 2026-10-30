<!-- markdownlint-disable MD013 -->

# CLIENT-P0 — recon: reuse audit, v1 contract, test-rail state

**Card:** kanban `t_f7caea69` · **Branch:** `pr/client-recon` · **Date:** 2026-10-30
**Status:** recon complete. No product code, no new repo, no router changes, no writes
outside this worktree except a throwaway scratch copy (see §1.4).

Companion deliverable: [`docs/client/v1-client-contract.md`](docs/client/v1-client-contract.md).

Every claim below is cited to a `file:line` or to a command's output. Claims I could not
verify are labelled **UNVERIFIED**.

---

## 0. Headline

| Question the card asked | Answer |
|---|---|
| Can we reuse `tollgate-android` as the Android client? | **REUSE-PARTS.** The crate does **not compile** against current `tollgate-rs`, implements the wrong protocol end to end, and its JNI layer is scaffolding for FIPS TUN plumbing that no v1 router speaks. The Compose shell, the UniFFI wiring pattern, and the CI shape survive. The protocol/wallet layer is a rewrite. |
| Is the v1 contract implementable from source? | **Yes**, and it is smaller than expected: 3 routes to buy, 4 to observe, no auth. The two real traps are identity-from-socket (§3) and the `price_unit` validation gap. |
| Are the test rails usable? | **1 of 3 today.** labgrid is live and local to this host (the card's premise was wrong — see §3.2). DQ05 emulator is viable only after a disk reclaim. The Debian shell can be built and exercised on this host and on two fleet nodes right now. |

---

## 1. Reuse audit — `OpenTollGate/tollgate-android`

Cloned to `~/repos/tollgate-android` (public, MIT). `HEAD = d71d6cd`
("feat(phase2): JNI bootstrap layer (#8)"), 49 tracked files, 3.5 months stale relative to
its own dependency.

### 1.1 What `tollgate-mobile` actually implements

`tollgate-mobile/src/lib.rs` (669 lines) is a **faithful port of `tollgate-net`'s
`client.rs` for the TollGate v2 / `tollgate-rs` CBOR protocol**. Its own module docs say
so and name the v1 protocol it deliberately does *not* speak:

- `lib.rs:1-26` — "replaces the JS captive-portal SPA (`tollgate-captive-portal-site`,
  **TollGate v1: NIP-01 kind 10021 over HTTP :2121**) with a fully-native app that speaks
  the **TollGate v2** CBOR protocol implemented by `tollgate-rs`."
- Transport: `POST <base>/tollgate/v1/exchange`, `Content-Type: application/cbor`,
  length-prefixed frames — `lib.rs:222-239`.
- Message types used: `Announce`, `PriceSheet`, `BootstrapToken`, `BootstrapAck`,
  `MeteringReport`, `Reject` — `lib.rs:44-47`, decoded at `:241-286`.
- Unit hard-coded to `"bytes"`, pricing scaled by 1000 — `lib.rs:216-218`.
- Payment is a **stub**: `build_bootstrap_token` (`lib.rs:446-481`) fabricates a
  syntactically-valid `cashuA` token with a filler signature (`c = G`, keyset
  `009a1f293253e41e`) and its own doc comment says "the proof's keyset/secret/signature
  are filler… Real-wallet integration is pending upstream". That token would be refused
  by any real mint and by our module's `Receive` immediately.

**v2-specific and useless to us:** every line above. Spilman channels, CBOR framing,
`Announce`/`PriceSheet` handshakes, `MeteringReport` drift settlement. Our routers speak
none of it — `src/main.go:463` binds plain HTTP `:2121` and `src/merchant/merchant.go:1992`
emits a kind-10021 Nostr JSON event.

### 1.2 The UniFFI surface

Exported from `lib.rs:519-669`, all on one object `TollgateMobileNode`:

| Kind | Name | Signature | Useful for v1? |
|---|---|---|---|
| constructor | `new` | `(data_dir: String) -> Arc<Self>` | **yes** — pattern only |
| method | `pubkey_hex` | `() -> String` | pattern only |
| method | `data_dir` | `() -> String` | pattern only |
| method | `detect` | `(base_url: String) -> Detected` | **no** — CBOR exchange |
| method | `pay` | `(base_url, mint_url, amount_sat) -> Paid` | **no** — CBOR + fake token |
| method | `start_consume` | `(base_url, mint_url, amount_sat, topup_sat, interval_ms, max_polls) -> ()` | **no** |
| method | `poll_event` | `(timeout_ms) -> Option<ConsumeEvent>` | **no** |
| method | `stop_consume` | `() -> ()` | pattern only |
| record | `PriceView` | `{per_second, per_unit}` | no (v2 pricing model) |
| record | `Detected` | `{pubkey_hex, unit, version, price}` | shape is right, fields are v2 |
| record | `Paid` | `{peer_pubkey_hex, accepted, reason, price}` | shape is close |
| record | `ConsumeEvent` | 9 fields, all v2 metering | no |
| record | `ReportSummary` | `{elapsed_ms, delivered, received}` | no |
| enum | `TollgateError` | `Network / Protocol / Rejected / Other` | **yes** — keep this taxonomy |

The seam is real but the payload is wrong. `TollgateError`'s four variants map cleanly
onto the v1 refusals (§5.3 of the contract): `Rejected{reason}` ≈ a kind-21023 notice,
`Network` ≈ transport failure, `Protocol` ≈ a 415/405 client bug, `Other` ≈ everything
else. That enum plus the `#[uniffi::Object]` + owned-tokio-runtime + `poll_event` polling
idiom is the reusable skeleton.

### 1.3 `jni.rs` — what it is, and why it is not a seam

`tollgate-mobile/src/jni.rs` (704 lines) is **FIPS TUN plumbing**, not a protocol layer:

- `Java_org_opentollgate_android_NativeCore_{deliverPacket,startMeshTun,stopMeshTun,nextOutboundPacket,getPeers,getAdverts}` — `jni.rs:64-212`
- global `OnceLock`s for JavaVM, two packet channels and a TUN fd — `jni.rs:17-31`
- `nextOutboundPacket` returns `null` with `"Not yet implemented - needs FIPS node tun_rx integration"` — `jni.rs:150-162`
- `serialize_advert_views_to_json` returns `vec![]` with `TODO: Access actual advert_views via BLE bridge` — `jni.rs:279-308`
- the whole module is `#[cfg(feature = "fips")]` (`lib.rs:30-31`), and FIPS v0.4 does not
  cross-compile to Android (`Cargo.toml:33-36`)

So on a default build **none of this is compiled**. It is a half-finished second FFI
surface (raw JNI alongside UniFFI, both exported from the same `.so`) that duplicates the
UniFFI object with worse ergonomics. **Delete it in a v1 rewrite** — a v1 client has no mesh
TUN, no packet channels, and no need for `JNI_OnLoad` when UniFFI already owns the boundary.

### 1.4 Build reality — measured, not assumed

**The crate does not build. Anywhere. Against any dependency set.**

Reproduce (I did, in a scratch copy — `~/.hermes/profiles/worker-tollgate/cache/scratch/tg-android-build-1`):

```
$ cd ~/repos/tollgate-android && cargo metadata --no-deps
error: failed to load manifest for workspace member `tollgate-mobile`
Caused by: failed to read `/home/c03rad0r/repos/tollgate-rs/crates/tollgate-protocol/Cargo.toml`
           No such file or directory
```

`Cargo.toml:31-32` pins `tollgate-protocol` and `tollgate-core` to
**absolute paths under `/home/c03rad0r`** — the original author's machine. On this host
(`whoami` → `c08r4d0r`, `hostname` → `x280`) those paths do not exist.

Three further blockers found before Rust code is even reached:

| # | Blocker | Evidence |
|---|---|---|
| 1 | `reference/fips` is a **gitignored local entity that is not in the repo** — here it is a symlink to `~/repos/fips-upstream`, so the path resolves only on a machine that has that checkout | `.gitignore:20-22`; `git ls-files reference` → empty; `Cargo.toml:37` requires it |
| 2 | the path dep names a package `fips`, but upstream publishes the crate as `fips-mesh` (lib name still `fips`) | `cargo check` → `error: no matching package named 'fips' found … help: package 'fips-mesh' exists at …`; `~/repos/fips-upstream/Cargo.toml:1-7,33-34` |
| 3 | `fips-upstream` carries its own `[workspace]`, so nesting it under `reference/fips` gives *two* workspace roots | `cargo metadata` → `error: multiple workspace roots found in the same workspace` |

After patching all of the above locally (path → `~/repos/tollgate-rs`, `package = "fips-mesh"`,
`exclude = ["reference/fips"]`), `cargo metadata` succeeds and the real failure surfaces:

```
$ cargo test -p tollgate-mobile --no-run
tollgate-mobile/src/lib.rs:45: error[E0432]: unresolved imports
  `tollgate_protocol::{BootstrapAck, BootstrapToken, MessageType, MeteringReport,
   PriceSheet, PublicKey, decode_frames, peek_type}`
tollgate-mobile/src/lib.rs:46: error[E0603]: module `frame` is private
tollgate-mobile/src/lib.rs:295: error[E0599]: no method named `public_key` on `Announce`
tollgate-mobile/src/lib.rs:244: error[E0599]: no associated function `new` on `Announce`
…
error: could not compile `tollgate-mobile` (lib) due to 11 previous errors
```

**11 hard compile errors against the current `tollgate-rs` API.** The reason is
architectural, not cosmetic: `tollgate-rs` **rewrote its protocol** after this client was
written. `git log -S'BootstrapAck'` in `~/repos/tollgate-rs` finds the commits that
removed it (`797b2e0` "Rebuild protocol and core from the voucher design docs",
`361dd97` "Redesign the protocol around vouchers and prepaid grants",
`c2d504b`…), and today's `crates/tollgate-protocol/src/lib.rs:33-40` exports
`Accept, Announce, Balance, ChannelClose, ChannelReady, ChannelUpdate, CloseAck,
CloseReason, Disconnect, Offer, RefusedUpdate, Reject, RolloverInit, RolloverReady,
TopUp, TopUpReject` — vouchers and channels, with no `BootstrapAck`, no
`BootstrapToken`, no `MeteringReport`, no `PriceSheet`, and no
`/tollgate/v1/exchange` route anywhere in the tree (`grep -rn 'tollgate/v1/exchange'` →
no matches).

Even `Announce` changed shape: it now carries `{version, pubkey: PubKey, unit: String,
capabilities: u32}` (`message.rs:11-20`) where the client calls
`Announce::new(PROTOCOL_VERSION, pubkey, UNIT, 0).encode()` and `announce.public_key()`.

**The Android/Gradle project.** Coherent as a *project*, non-functional as a *build* here:

| Check | Result | Evidence |
|---|---|---|
| `./gradlew --version` | works — Gradle 8.13, JVM 25.0.4.1 | command output |
| `./gradlew projects` | **fails**: `What went wrong: 25.0.4.1` | command output |
| Root cause | AGP 8.7.3 does not support JDK 25; project targets JVM 17 | `android/gradle/libs.versions.toml:2` (`agp = "8.7.3"`), `android/app/build.gradle.kts:65-70` (`VERSION_17`) |
| Available JDKs | **only** `java-25-openjdk-amd64` / `java-1.25.0-openjdk-amd64` | `ls /usr/lib/jvm/` |
| Android SDK / NDK / adb | **absent on this host** | `command -v sdkmanager adb` → nothing; `ls /opt/android* ~/Android` → absent |
| Project structure | coherent — 1 module `:app`, version catalog, wrapper jar present, `namespace org.opentollgate.android`, `compileSdk 35`, `minSdk 26`, `abiFilters arm64-v8a` | `android/settings.gradle.kts`, `android/app/build.gradle.kts:32-46`, `gradle/wrapper/gradle-wrapper.*` |
| Kotlin ↔ Rust wiring | coherent — `TollgateViewModel` imports `uniffi.tollgate_mobile.TollgateMobileNode` and drives detect/pay/consume | `android/app/src/main/kotlin/org/opentollgate/android/TollgateViewModel.kt:31`, `:48`, `:96-140` |

So: **Gradle configuration is coherent; the toolchain to run it is not installed here, and
installing it is explicitly out of scope for this card.** A JDK 17 + SDK 35 + NDK 27
install would make `./gradlew assembleDebug` plausible — that is an `apt`/`sdkmanager` job,
not a code job.

One more honesty note: the repo's own `docs/PHASE-1-STATUS.md` claims "Host: cargo test
passes (5/5)" and "APK builds for arm64-v8a". Both claims are **false as of today's
dependency graph** — the tests are 5 `mock_gateway` integration tests
(`tollgate-mobile/tests/mock_gateway.rs:107-236`) that cannot compile. Treat that document
as a snapshot of a machine that no longer exists.

### 1.5 Verdict

> **REUSE-PARTS.**

| Component | Verdict | Why |
|---|---|---|
| `android/` Compose shell (7 screens, ViewModel, Compose BOM, navigation) | **keep** | coherent, protocol-agnostic, ~2 500 lines of UI that would otherwise be rewritten; only its node calls change |
| version catalog + wrapper + app module layout | **keep** | correct shape, just needs JDK 17 and the SDK installed |
| `TollgateError` enum + `#[uniffi::Object]` + owned-runtime + `poll_event` idiom | **keep** | the right FFI/threading architecture for Kotlin |
| `.github/workflows` + `justfile` (`test`/`so`/`bindings`/`apk` targets) | **keep** | correct NDK/UniFFI build shape; the recipes' commands are protocol-independent |
| `uniffi-bindgen` sub-crate + `scripts/patch-uniffi-bindings.py` | **keep** | a real UniFFI 0.28.3/Kotlin-2.x workaround that will bite us again |
| `tollgate-mobile/src/lib.rs` detect/pay/consume | **rewrite** | wrong protocol (CBOR v2), plus a fake-token payment stub |
| `tollgate-mobile/src/jni.rs` (704 lines) | **delete** | dead FIPS TUN scaffolding behind a feature that cannot cross-compile to Android |
| `tollgate-mobile/tests/mock_gateway.rs` | **rewrite** | mocks the v2 CBOR gateway; the v1 equivalent is a fake httptest server speaking `:2121` JSON |
| `Cargo.toml` workspace deps | **rewrite** | absolute `/home/c03rad0r` paths, a `fips`/`fips-mesh` name mismatch, a workspace-root collision, and a `tollgate-protocol` that no longer has the API it imports |

Net: the Kotlin half is worth keeping (and worth more than the Rust half), the Rust half
is a template to copy, and no line of the protocol or wallet layer survives.

**Recommendation for the build plan:** start the new core crate in a fresh workspace
(or as a replacement `tollgate-mobile`), vendoring only `TollgateError`,
the UniFFI object idiom, the justfile recipes and the Compose shell. Do **not** try to
make the existing crate compile first — it is pinned to a `tollgate-rs` protocol generation
that was deleted upstream.

---

## 2. The v1 contract

Full deliverable: [`docs/client/v1-client-contract.md`](docs/client/v1-client-contract.md).
Summary of what it establishes, and the four findings that should shape the build:

1. **Three routes to buy, four to observe, no auth anywhere.** `POST /` (raw token),
   `POST /ln-invoice` + `GET /ln-invoice?quote=` (mint at the gate), and
   `GET /` for the advert. `GET /whoami`, `/usage`, `/balance`, `/session-state` for state.
   All identity-scoped routes resolve the caller from the source IP
   (`src/main.go:1028-1032`, `:950-964`).

2. **`price_unit` is advertised but never validated — a client MUST verify it.** This is
   the card's suspicion, confirmed: `MintConfig.PriceUnit` is a free-form `string`
   (`src/config_manager/config_manager_config.go:135`), declared to the schema with no
   enum (`config_schema.go:78`), copied verbatim into the `price_per_step` tag
   (`src/merchant/merchant.go:2006`), and **never compared to the mint's keysets**. The
   wallet is sat-only: `GetMintActiveKeyset(mintURL, cashu.Sat)`
   (`src/tollwallet/gonuts_wallet.go:104,110`) and `cdk_ffi.CurrencyUnitSat{}`
   (`tollwallet/cdk_wallet.go:406`). An operator configuring `"price_unit": "eur"` gets an
   advert promising EUR from a module that only settles sat. Client rule:
   fetch `<mint>/v1/keysets` (NUT-02) and require a `sat` keyset, or refuse the option.

3. **Identity is the source socket, so a client must be on the LAN.** A purchase through
   NAT, a proxy or a tunnel grants the session to the proxy's device — there is no header
   or field that changes this (`src/main.go:1180-1199`). A `?mac=` claim is explicitly
   ignored and reported back in `X-TollGate-Mac-Claim-Ignored`
   (`src/main.go:966-1022`), pinned as a corpus vector
   (`~/repos/tollgate/corpus/http/http02-whoami.json`, `http02-whoami/mac-claim-ignored`).
   For a mobile client this also means: **MAC randomisation silently orphans a paid
   session** (`docs/architecture/session-ticket-decision.md:28-40`), and the rebind
   mechanism that would fix it is *Proposed and on hold* (`:3-9`) — not something a client
   may depend on.

4. **A client that pays a Lightning invoice and does not poll gets nothing.** The grant
   only happens inside the status poll (`merchant/lightning.go:364-369` → `:652-706`), so
   "pay and close the app" is a guaranteed loss. Combined with
   `503 code=access-grant-failed` meaning *keep polling, do not pay again*
   (`src/main.go:1849-1857`), the poll loop is not optional UI polish.

The contract document also records **8 spec-vs-implementation divergences** (§7 there) —
chief among them: refusals are always HTTP **400** with a kind-21023 notice (never 402),
the notice `p` tag carries a **MAC** rather than a pubkey, and the session event carries
no `p` tag at all.

### 2.1 The interop corpus is the client's conformance suite

`~/repos/tollgate/corpus/` (corpus_version `v1`, updated 2026-10-16) already pins the
exact surface a client must reproduce: 3 event fixtures, 4 token fixtures with per-stage
lifecycle verdicts, 8 HTTP vector files (`http01-discovery`, `http01-payment` with 15
vectors, `http02-whoami`, `http03-usage`, `http03-balance`, `http03-ln-invoice`,
`session-state`, `uncovered-session-endpoints`), and a manifest naming the reference mint
(cdk-mintd 0.18.1, fakewallet, keyset `01df97b6fb8a572a`). Its stated purpose —
"Every TollGate consumer … must produce the recorded verdicts for these inputs; a
divergence is a filed bug" — makes P1's "recorded-fixture tests" almost free: the fixtures
exist and are versioned.

---

## 3. Test-rail verdicts

### 3.1 Summary table

| lane | usable now? | blocker | what unblocks it |
|---|---|---|---|
| **This host (x280) — Debian agent build + run** | **yes** | none for build/test; 7.3 GB RAM, 73 GB free, load 2.25 (re-measured) | nothing |
| **cobrador** — Debian build/agent | **yes, with care** | load 2.5–3.8 on 4 cores (busy), 26 GB free (89 %) | wait for the current job, or accept slower builds |
| **dq05 (Debian side, not emulator)** | **yes, with care** | 12 GB free (98 %), load 7.0–7.9 on 4 cores (heavily saturated) | free disk before any Rust target dir lands there; verify the occupant first |
| **x240** | **yes for build, needs toolchain** | no `cargo`; 19 GB free (81 %), idle (0.69) | `rustup` install (~1.5 GB) |
| **t440** | **best build node, needs toolchain** | no `cargo`; 78 GB free (45 %), idle (0.50) | `rustup` install |
| **hermes-nvme** | **yes for light work** | no `cargo`; 2 cores, 18 GB free, very idle (0.07) | `rustup` install |
| **testserver2** | **marginal** | no `cargo`; 6.8 GB free (94 %), 2 cores | free disk first |
| **DQ05 Android emulator** | **no** | AVD exists and KVM is present, but 6 GB AVD on a 97 %-full disk, and the Android SDK is on dq05 under `/home/c03rad0r` | free ~20 GB on dq05, then `adb`/`emulator` from `~/Android/Sdk` |
| **labgrid router places** | **yes — coordinator is live and local** | the card's premise was wrong (see §3.2) | nothing; acquire a place when a test needs one |
| **Router at 192.168.50.205 / .219 (`:2121`)** | **no** | the router places ping but **no port answers** (22, 80, 2050, 2121 all closed) | bring the devices up / acquire a labgrid place and console them |

### 3.2 labgrid — the card's premise is wrong, and that is the most useful finding here

The card states "`ai-legion:20408` does not resolve from this host (measured). Find the
live coordinator." Correct that it does not resolve — but **the coordinator does not need
finding: it is running on this host.**

```
$ ps -eo pid,cmd | grep labgrid
4047258 …/labgrid-coordinator -l x280.fips:20408
924263  …/labgrid-exporter -c x280.fips:20408 -n x280 --hostname x280.fips --isolated /etc/labgrid/exporter…
$ ss -lntp | grep 20408
LISTEN 0 4096 [fd36:3c0f:d6f:8029:ea50:958b:672e:bb0]:20408  … users:(("labgrid-coordin",pid=4047258,fd=12))
$ getent hosts x280.fips
fd36:3c0f:d6f:8029:ea50:958b:672e:bb0 x280.fips
```

`ai-legion` is simply the wrong hostname for this deployment; the live form is
**`x280.fips:20408`** (IPv6 link address `fd36:…:bb0`). With that set, the coordinator
answers:

```
$ export LG_COORDINATOR=x280.fips:20408
$ labgrid-client places
archy-vm
comfast
gl-mt3000
tollgate-d8ba
$ labgrid-client who
User  Host  Place  Changed          # nobody holds anything
```

Four places, all `host=x280.fips`, all `acquired: None`:

| Place | Resource | Address | Serial |
|---|---|---|---|
| `gl-mt3000` | NetworkService (ssh:22) + RawSerialPort | 192.168.50.205 | `BG046H5F` |
| `comfast` | NetworkService (ssh:22) + RawSerialPort | 192.168.50.219 | `BG046H14` |
| `archy-vm` | NetworkService (ssh:22) | 10.99.99.1 | — |
| `tollgate-d8ba` | NetworkService (ssh:22) | 10.212.49.1 | — |

Config truth is local and readable: `/etc/labgrid/places.yaml` and
`/etc/labgrid/exporter.yaml` (the coordinator is "dedicated to this registry; sync removes
unlisted places" per the `places.yaml` header). Reads only — **no place was acquired, no
state mutated.**

**Read-only reachability probe (allowed by the card, and worth recording because it
contradicts the registry):**

```
$ ping -c1 192.168.50.205 / 192.168.50.219   → both reachable, ~1 ms, ARP REACHABLE
$ nc -z -w2 <ip> {22,80,2050,2121}            → ALL CLOSED on both
$ ping 10.99.99.1 / 10.212.49.1               → unreachable
```

So the two GL devices are powered, on the LAN and answering ARP, but **nothing is
listening** — no sshd, no uhttpd, no `:2121`. They are either mid-flash, in a broken boot,
or their services are down. Opening a `:2121` probe against them is therefore impossible
today; that is a lab-state fact, not a client problem. `archy-vm` and `tollgate-d8ba` sit
on bridges that are `linkdown` in this host's routing table
(`ip route`: `10.99.100.0/24 … linkdown`, `192.168.1.0/24 … linkdown`).

**One nearby live rig exists but is out of scope:** a QEMU OpenWrt guest is up (1 h 50 m,
85 MB RSS, `tg-poc-br` bridge at `10.99.99.2/24`, tap `tg-poc-tap`, MAC
`52:54:00:12:34:56`) — `/home/c08r4d0r/tollgate-virtual-lab-2410/`. Its bridge is the same
`10.99.99.0/24` the `archy-vm` place tags, which is why that place will not answer from
here. Another rail owns it; **I did not touch it** and did not probe its `:2121`.

### 3.3 DQ05 emulator — the real state, measured

Two different things live on dq05 and the card conflates them. Both were checked.

**The host (dq05 / `c03rad0r-DQ05proplus`):**

```
load   5.52 6.47 7.25      (4 cores)
mem    10 GB total, 5 GB used, 5 GB available
disk   468G, 428G used, 16G free → 97 %
kvm    /dev/kvm present
adb    ~/Android/Sdk/platform-tools/adb devices  →  (empty)
avd    ~/.android/avd/wa-dev.avd  (6.0 GB)  target=android-34
sdk    ~/Android/Sdk/{build-tools,cmdline-tools,emulator,licenses,ndk}  present
system-images: android-34 present
```

The only `qemu-system-x86_64` on dq05 is `-name maas` (a snap LXD VM), not an emulator
(`pgrep -a qemu-system` output). So **no Android guest is running**, and the SDK + AVD are
installed — which contradicts the earlier reading that "the existing guest is
single-owner state". The single-owner constraint still applies to the *LXD/MAAS* VM, but
the Android lane itself is idle.

**On this host (x280), which is what the card's DQ05 note was actually describing:**

```
uptime      up 5 days, 16 h, load 2.25/2.54/3.04 on 8 cores  (re-measured at commit; was 3.49/3.48/2.69)
mem         7.3 GB total, ~2 GB available
disk        247G, 163G used, 73G free → 70 %
qemu        3709670  qemu-system-x86_64 … (the OpenWrt lab VM, 1 h 50 m, 85 MB RSS)
adb         not installed        `command -v adb emulator` → nothing
avd         ~/.android/avd → absent
sdk         ~/Android/Sdk, /opt/android* → absent
```

**Verdict: a second AVD is NOT viable on x280** (no SDK, no `adb`, 2.4 GB available RAM)
**and is viable on dq05 after a disk reclaim** — the AVD, the system image and an AVD
snapshot want roughly 15–20 GB, and dq05 has 16 GB free at 97 %. What must be freed first,
in order: (a) `~/.android/avd/wa-dev.avd` is 6 GB and can be recreated, (b) Rust/Cargo
target dirs and Gradle caches on dq05, (c) any stale system images under
`~/Android/Sdk/system-images`. **Nothing was booted, torn down or touched.**

### 3.4 Fleet — measured per node

```
$ for h in cobrador dq05 x240 t440 hermes-nvme testserver2; do ssh … $h 'uname -m; nproc; df -h /' ; done
```

| Node | Arch | Cores | Disk free | Load (1/5/15) | `cargo` | `gcc` | Verdict |
|---|---|---|---|---|---|---|---|
| **x280** (this host) | x86_64 | 8 | **73 G** (70 %) | 2.25 / 2.54 / 3.04 | `cargo 1.99.1` | yes | **primary** — build + test the core and the agent here |
| **cobrador** | x86_64 | 4 | 26 G (89 %) | 2.49 / 3.02 / 3.82 | `/usr/bin/cargo` | yes | usable — busy; good for a soak/second-opinion build |
| **t440** | x86_64 | 4 | **78 G** (45 %) | 0.50 / 0.72 / 0.76 | **none** | yes | **best spare** — install rustup, then it is the cleanest runner |
| **x240** | x86_64 | 4 | 19 G (81 %) | 0.69 / 0.51 / 0.48 | **none** | yes | usable after rustup; tight disk |
| **hermes-nvme** | x86_64 | 2 | 18 G (86 %) | 0.07 / 0.10 / 0.09 | **none** | yes | usable for light jobs only (2 cores) |
| **dq05** | x86_64 | 4 | 12 G (**98 %**) | 7.04 / 7.81 / 7.90 | `/usr/bin/cargo` | yes | **only after a disk reclaim** — and it is the emulator host, so disk is the shared scarce resource |
| **testserver2** | x86_64 | 2 | 6.8 G (94 %) | 1.81 / 2.09 / 1.97 | **none** | yes | marginal — not recommended |

All seven are `x86_64`, so the Debian agent's native build target is the same everywhere; no
cross-compilation is needed for the fleet lane. (mips/mipsel/arm targets matter for the
*router* package, not for the client.)

Note: none of these are ARM, so the fleet cannot exercise an ARM-only code path — if the
agent will run on ARM SBCs that needs a separate lane. **UNVERIFIED** whether any fleet
node is ARM; all six queried report `x86_64`.

---

## 4. What this changes about the plan

| Plan assumption | Recon finding | Effect |
|---|---|---|
| §1.1 "reuse the Rust/Kotlin scaffold and the FIPS plumbing" | the Rust scaffold does not compile and its FIPS plumbing is dead code behind a feature that cannot target Android (`lib.rs:30-31`, `Cargo.toml:33-36`) | keep the *Kotlin* scaffold, not the FIPS plumbing; treat the Rust crate as a template |
| §1.3 "labgrid: need the live coordinator address" | the coordinator is local (`x280.fips:20408`) and answers; the blocker is that the two GL routers answer ARP but nothing else | P3/P5 unblocking is a *router-state* task, not a DNS task |
| §1.3 "DQ05 emulator not viable, guest up 3 days" | on dq05 there is **no** Android guest and the SDK/AVD are installed; the 3-day guest was the OpenWrt VM on **x280** | the emulator lane is one disk-reclaim away, not blocked |
| §2 "one wallet implementation for both shells (Rust cdk)" | untouched by this recon, but note the module is sat-only (`gonuts_wallet.go:104`, `cdk_wallet.go:406`) and v1 clients must match that | keep cdk; enforce sat |
| §3 scoring "normalize price_per_step / step_size" | sound — but the advertised `price_unit` cannot be trusted (`merchant.go:2006` + no keyset check) | scoring must key on the *validated* mint unit, not the advert's label |

---

## 5. Explicitly not done (card scope walls)

- No product code, no new repo, no PR, no `gh` write.
- No router access beyond `ping` and `nc` against addresses already in the lab registry;
  `:2121` was **not** reachable on any of them, so no advert was captured live.
- No labgrid place acquired, no emulator booted or torn down, no guest touched.
- No toolchain installed (no rustup on the cargo-less nodes, no JDK 17, no Android SDK).
- The scratch build copy at
  `~/.hermes/profiles/worker-tollgate/cache/scratch/tg-android-build-1` is disposable and
  carries four local patches (path, `package = "fips-mesh"`, `exclude`, and the fips clone)
  that exist only to prove the compile failure is real and not a setup artefact.

---

## 6. How these citations were verified

Every `file:line` in this document and in `docs/client/v1-client-contract.md` was
re-resolved mechanically against **this worktree at `eb12d7f8`** (not against the primary
checkout, which carries another card's uncommitted edits to `merchant.go` / `tollwallet/`
and shifts every line number below `merchant.go:1490` by about +49). The checker opened
each cited file at each cited line and printed it; `bad=0`.

Consequences worth recording, because a later reader will otherwise re-derive them:

- **Line numbers are pinned to a commit, not to a file path.** Any change to
  `src/merchant/merchant.go` invalidates roughly 40 citations in the contract document.
  Prefer symbol names when quoting these to a human; the numbers are for the diff.
- Anchors that exist only in the *uncommitted* primary tree (the `#257`/`#480` keyset
  recovery work in `src/tollwallet/keyset_recovery*.go`, `src/merchant/keyset_recovery.go`,
  `src/go.work`) are **not** part of this recon and are not cited. A client built today
  must target `eb12d7f8`'s behaviour.
- `~/repos/tollgate-rs` was read at `5b5e045` (`0.1.0-rc.2`), `~/repos/fips-upstream` at
  `6c3e1c84`, `~/repos/tollgate-android` at `d71d6cd`.

The two rail facts that are *time-varying* (host load, free disk) were re-measured at
commit time and are marked as such; everything else is a property of a file.

---

## 7. Recommended next cards

1. **CLIENT-P1 — core crate, greenfield.** `tollgate-client-core` with discovery, advert
   parse (validate `price_unit` against `<mint>/v1/keysets`), scoring, policy. Conformance
   harness driven by `~/repos/tollgate/corpus/` fixtures. Builds on x280/t440.
2. **CLIENT-P2 — wallet + purchase.** cdk wallet, mint quote → swap → token → `POST /`,
   NUT-07 reconciliation, the §5.3 refusal table as the test matrix. Crash lanes in
   `tests/cloud-lab/`.
3. **LAB — router state.** `gl-mt3000` and `comfast` answer ARP but run no services
   (`nc` all closed). Diagnose over their serial ports (`BG046H5F`, `BG046H14`) before any
   client is tested against real hardware.
4. **DQ05 — disk reclaim** (~20 GB) so the emulator lane in P4 is real.

---

*Sources: `~/repos/tollgate-android` @ `d71d6cd`; `~/repos/tollgate-rs` @ `5b5e045`;
`~/repos/fips-upstream` @ `6c3e1c84`; this worktree @ `eb12d7f8`;
`~/repos/tollgate` protocol docs + `corpus/` (v1); `/etc/labgrid/{places,exporter}.yaml`;
command output as quoted inline.*
