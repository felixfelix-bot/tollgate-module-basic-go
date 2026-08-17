# TollGate v0.7.0 (tollgate-wrt)

**Released**: pending — this is the pre-tag release draft. The date is
set here when the `v0.7.0` tag is cut after the E2E gate passes.

<!-- markdownlint-disable MD013 -->

v0.7.0 makes the gate real and the router harder to attack. The
headline fix: on OpenWrt 24.10, NoDogSplash's enforcement chain sat
behind fw4's accept rule, so authenticated clients were never actually
filtered — this release ships an nftables enforcement bridge that
finally enforces sessions at the fw4 layer. A new deterministic
identity layer derives the router's CGNAT IPv4, per-interface MACs,
and BIP39 passwords from the merchant key using NIP-06 and HKDF. The
Cashu wallet was un-bricked twice over (a swap-counter race and a V2
keyset truncation could each permanently break swaps), Lightning
quotes now survive restarts, and profit-share payouts no longer
stall when one recipient is offline. Around that core: a deep
security-hardening pass (audit-driven SSRF closures, the backend API
port firewalled to LAN, RFC 1918 isolation, a dependency CVE sweep),
a `sats` → `sat` config migration, and operator tooling in the form
of man pages and a full operator guide.

## At a glance

- **Sessions are actually enforced on OpenWrt 24.10**: a new
  nftables bridge (`20-nds-enforce.nft`) gates forwarded traffic on
  the NDS marks at fw4 priority -1.
- **Deterministic identity**: 12-word NIP-06 seed, HKDF-separated
  derivation of the router IPv4, per-interface MACs, and root/Wi-Fi
  passwords, exposed via `GET /identity` and a loopback-only
  `POST /identity/reveal-seed`.
- **Wallet-brick fixes**: the gonuts swap-counter race (permanent
  "already signed" rejection) and the V2 keyset truncation are both
  fixed; a Cashu compatibility matrix now documents and tests the
  token-format × keyset-version grid.
- **Lightning quotes survive restarts**: quotes persist to
  `quotes.json`; paid-but-restarted invoices no longer strand users
  on "Waiting for payment".
- **Security hardening**: TOCTOU-safe SSRF dialing, LNURL callback
  validation, RFC 1918 isolation from upstream networks, UCI input
  validation, `0600` config files, sanitized errors, payment-endpoint
  rate limiting, 1 MB response caps, and a `x/crypto`/`x/net` CVE
  sweep clearing 65 Dependabot alerts.
- **Backend API (port 2121) is now LAN-only** — WAN and upstream
  clients can no longer probe it.
- **Merchant resilience**: owner-first profit-share payouts,
  degraded mode when wallet init fails, `mint-rate-limited` error
  mapping with retry, and rejection of P2PK/HTLC-locked tokens.
- **Operators**: `man tollgate` on the router, a full operator guide,
  and a configurable post-payment redirect with auth delay.

## What's new

### Enforcement that actually enforces

NDS 5.0.2 on OpenWrt 24.10 inserts its enforcement chain in
`ip filter FORWARD` (iptables-nft), but fw4's `inet fw4 forward`
chain (priority 0) accepted forwarded traffic first — the NDS chain
matched zero packets, and authenticated clients were never actually
gated ([#283](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/283),
[#286](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/286)).
The new `/etc/nftables.d/20-nds-enforce.nft` include hooks
`inet fw4 forward` at priority -1 and acts on the NDS marks set in
mangle PREROUTING: pre-authenticated traffic is dropped,
trusted/authenticated traffic is accepted, and unmarked traffic to
the WAN is rejected, forcing clients into the captive portal. The
rules load on boot and on every firewall reload, survive NDS
restarts, and WAN detection is portable rather than tied to a fixed
interface name
([#297](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/297)).
`SETUP_VERSION` is bumped to `v0.5.1` so reinstalling the package
applies the new setup.

Router-to-router autopay also tracks usage correctly now: after a
payment is accepted upstream, the downstream router triggers a
port-80 request so NoDogSplash creates the client session — without
it, usage always read 0 and the gate never closed when the allotment
ran out ([#347](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/347)).
The trigger is SSRF-validated
([#315](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/315)).

### Deterministic identity: NIP-06 + HKDF + RevealSeed

A new `src/identity` package derives a router's network identity
from the merchant key
([#331](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/331)):

- a stable IPv4 in the RFC 6598 CGNAT range (the `.1` host),
- per-interface, locally-administered MACs for `br-lan`, `wlan0`,
  and `wlan1`,
- root and Wi-Fi passwords as 6-word BIP39 phrases, and
- a 12-word NIP-06 mnemonic (`m/44'/1237'/0'/0/0`) with a recovery
  flow via `DeriveFromMnemonic`.

All derivations use HKDF (RFC 5869) with per-attribute domain
separation rather than raw hash concatenation. The new HTTP API is
additive: `GET /identity` returns only non-sensitive data (npub,
IPv4, MACs), while `POST /identity/reveal-seed` returns the key and
derived passwords and is restricted to loopback, POST-only, and
body-size limited. If `identities.json` is missing or malformed the
routes simply are not registered and everything else boots normally.

### Wallet and payment reliability

- **Two wallet-bricking bugs fixed.** A swap-counter race in
  gonuts-tollgate v0.7.1 left the counter stuck after any transient
  mint failure, after which every retry was rejected with NUT-02
  10002 ("blinded message already signed") — permanently, with no
  self-recovery
  ([#266](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/266)).
  Separately, 33-byte V2 keyset IDs were silently truncated to 8
  bytes in the NUT-13 derivation path, breaking every swap against
  CDK 0.16+ mints with V2-only keysets
  ([#281](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/281)).
  Both are fixed (gonuts v0.7.6), V4 short keyset IDs now resolve to
  full IDs (gonuts v0.8.0)
  ([#286](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/286)),
  and a Cashu compatibility matrix documents and tests all
  V3/V4 × V1/V2 combinations
  ([#281](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/281)).
- **Locked tokens are rejected.** Tokens carrying P2PK or HTLC
  spending conditions can never be spent by the gateway; receiving
  them now fails with a clear error instead of granting free access
  (fixes #324)
  ([#330](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/330)).
- **Lightning quotes persist across restarts** (`quotes.json` in the
  wallet directory), with race-free, fsync-before-rename writes — a
  paid invoice settled while the process was down still grants access
  ([#248](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/248),
  [#269](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/269)).
- **Mint 429s are mapped to `mint-rate-limited`** with retry instead
  of a generic "payment failed"
  ([#346](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/346)).
- **Owner-first profit-share payouts**: every recipient's LNURL is
  probed up front, the owner must be paid before any dev split, and
  an offline maintainer neither faults the mint nor blocks the
  others — their share is retained for the next cycle (resolves #27)
  ([#168](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/168)).
- **Degraded mode on wallet-init failure**: a mint that answers
  `/v1/info` but errors on keysets puts the merchant in degraded
  mode instead of crash-looping
  ([#298](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/298)).

### Security hardening

Most of these came out of the #177 audit and a dedicated hardening
pass:

- **TOCTOU-safe SSRF validation**: the LNURL-payer fetch validates
  the resolved IP at TCP-dial time via a custom `DialContext`,
  closing the DNS-rebinding window; the previously unvalidated
  `/.well-known/lnurlp/` fetch is covered too
  ([#245](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/245)).
- **LNURL callback URLs are validated** against loopback, RFC 1918,
  link-local (including `169.254.169.254` cloud metadata), and
  unspecified addresses
  ([#198](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/198)).
- **RFC 1918 isolation**: authenticated WiFi clients are blocked
  from private networks behind the upstream link at both the fw4 and
  NoDogSplash layers
  ([#234](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/234)).
- **The backend API port (2121) is firewalled to LAN interfaces**;
  loopback is still allowed, and the captive-portal payment flow is
  unchanged
  ([#345](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/345)).
- **Payment-endpoint rate limiting**: 10 requests/minute per IP with
  `429` + `Retry-After`; configurable via `TOLLGATE_RATE_LIMIT_RPM`
  for busier resellers
  ([#274](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/274),
  [#338](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/338)).
- **UCI keys/values reject control characters**, preventing config
  corruption and argument injection (closes #220)
  ([#222](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/222)).
- **Config files are `0600`** instead of `0644`
  ([#221](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/221)).
- **Error responses are sanitized** — internal details stay in the
  server log, not the JSON body
  ([#202](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/202)).
- **All HTTP response reads are capped at 1 MB**, preventing OOM on
  resource-constrained routers
  ([#274](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/274)).
- **Dependency CVE sweep**: `golang.org/x/crypto` v0.38.0 → v0.54.0
  and `golang.org/x/net` v0.40.0 → v0.57.0 clear all 65 open
  Dependabot alerts (28 critical, 8 high, 29 medium)
  ([#223](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/223)).

### For operators

- **`man tollgate` works on the router**: section-8 man pages for
  the whole CLI tree are generated from the cobra commands and
  installed to `/usr/share/man/man8/`
  ([#187](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/187)).
- **A full operator guide** (`docs/operator-guide.md`) covers every
  CLI subcommand with examples and troubleshooting
  ([#188](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/188)).
- **Post-payment redirect**: new `auth_delay_seconds` and
  `redirect_url` upstream Wi-Fi settings let the portal show a
  welcome page before the gate opens
  ([#200](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/200)).
- **AP setup recovers on reinstall/upgrade**: missing APs are
  recreated, the SSID is preserved (fixes #103, #173)
  ([#216](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/216)).

## Behavior changes worth flagging

These affect operators on upgrade.

- **The backend API on port 2121 is reachable from the LAN (and
  loopback) only.** WAN-side and upstream clients can no longer
  probe it directly; the CLI (Unix socket) and the captive-portal
  payment flow are unaffected
  ([#345](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/345)).
- **Reinstalling/upgrading runs the full setup again.** `SETUP_VERSION`
  moves to `v0.5.1` so the new firewall and enforcement files are
  applied ([#283](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/283)),
  and the setup-done flag is now version-gated with always-run
  wireless verification ([#216](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/216)).
- **`price_unit` migrates from `sats` to `sat`** (NUT-00) in place on
  first load; the migration also runs on configs with an invalid
  `profit_share` (defaults are restored, then migration proceeds)
  ([#310](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/310)).
- **Advertisements list all configured mints**, not only currently
  reachable ones, so portal pricing no longer disappears when a mint
  flaps ([#286](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/286),
  [#310](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/310)).
- **`/usage` returns `200` with `-1/-1` when there is no session**,
  per spec and in parity with the Rust implementation — monitors
  keying on the old `500` must be updated
  ([#316](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/316)).
- **The payment endpoint is rate-limited by default** (10 req/min/IP,
  `429` + `Retry-After`). Busy resellers can raise it with
  `TOLLGATE_RATE_LIMIT_RPM`
  ([#274](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/274),
  [#338](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/338)).
- **Minified captive-portal assets are no longer committed** — they
  are built from the portal repo via `make portal-build`
  (`PORTAL_REF` pins a ref). Packagers building from a git checkout
  must run this step
  ([#335](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/335)).

## Notable bug fixes

The [CHANGELOG](CHANGELOG.md) has the exhaustive list. The
operator-relevant subset, beyond the items above:

- **Mint URL fuzzy matching** in allotment calculation — tokens whose
  mint URL differs by a trailing slash or host case no longer consume
  sats without granting access (fixes #250, #251)
  ([#252](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/252)).
- **`/usage` gained CORS** like every other endpoint
  ([#195](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/195)).
- **`GetMintQuoteState` on a nil wallet returns an error** instead of
  panicking
  ([#259](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/259)).
- **Package builds work again**: dangling `firewall-tollgate`
  references that broke every `.ipk`/`.apk` build since #196 were
  removed from the Makefile, the build workflow, and the sysupgrade
  keep list
  ([#237](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/237),
  [#238](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/238)).
- **Protocol compliance**: notice event codes map to TIP-01 spec
  codes, and the non-existent TIP-03/TIP-04 were dropped from the
  advertisement `tips` tag
  ([#240](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/240)).
- **NIP-94 release events actually publish now** — the old CI step
  created kind-1 notes instead of publishing the signed 1063 events
  ([#230](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/230)).

## Upgrade notes

Operator-actionable items moving from v0.5.0 to v0.7.0:

- **Let the reinstall run the full setup.** `SETUP_VERSION` bumps to
  `v0.5.1` so the new enforcement and firewall files land; missing
  APs are recreated and the existing SSID is kept. Restart the
  service after upgrading.
- **Nothing to do for the `sats` → `sat` migration** — it happens in
  place on first load and preserves your settings.
- **If anything on the WAN side talked to port 2121, move it to the
  CLI or LAN.** The API is now LAN-only.
- **Busy resellers**: consider `TOLLGATE_RATE_LIMIT_RPM=30` (or
  higher) if legitimate client traffic can exceed 10 payments/minute
  per IP.
- **Building from source**: run `make portal-build` before packaging;
  the minified portal assets are no longer in the repository.
- **Pick the right package format**: `.apk` for OpenWrt 25.x,
  `.ipk` for OpenWrt 24.10 and earlier.

## Getting v0.7.0

- **Pre-built packages and firmware**:
  [releases.tollgate.me](https://releases.tollgate.me) — the release
  manager for firmware images and package builds.
- **Nostr**: releases are announced as NIP-94 file-metadata events on
  the project relays, with multiple Blossom mirror URLs per artifact.
- **OpenWrt 25.x**: `apk add --allow-untrusted tollgate-wrt-<version>.apk`
- **OpenWrt 24.10 and earlier**: `opkg install tollgate-wrt_<version>_<arch>.ipk`
- **From source**: [scripts/build-sdk-package.sh](scripts/build-sdk-package.sh)
  cross-compiles the binaries (Go 1.25 per [src/go.mod](src/go.mod))
  and stages the canonical [packaging/](packaging/) recipe into the
  OpenWrt SDK, producing either format.

The full per-PR changelog lives in [CHANGELOG.md](CHANGELOG.md).
Issues and discussion at
[github.com/OpenTollGate/tollgate-module-basic-go](https://github.com/OpenTollGate/tollgate-module-basic-go).

## Contributors

Thanks to everyone who contributed code, packaging work, bug reports,
or reviews to this release:
[@c03rad0r](https://github.com/c03rad0r),
[@Amperstrand](https://github.com/Amperstrand),
[@Origami74](https://github.com/Origami74),
[@felixfelix-bot](https://github.com/felixfelix-bot),
[@mvanhorn](https://github.com/mvanhorn), and Alex Xie.
