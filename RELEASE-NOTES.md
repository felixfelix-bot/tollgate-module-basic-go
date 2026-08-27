# TollGate v0.6.0 (tollgate-wrt)

**Released**: 2026-08-27

<!-- markdownlint-disable MD013 -->

v0.6.0 is the security-and-identity release. The headline theme is
defense-in-depth: a coordinated security audit (cashu-audit Layer 3,
prta #86, and the SEC-AUDIT chain) closed a cluster of payment,
network, and data-exposure holes, and the dependency tree was aligned
onto the upstream `OpenTollGate/gonuts-tollgate` module. Around that
core, identity handling was rebuilt on NIP-06 + HKDF with a
seed-reveal flow, the captive portal was decoupled from NoDogSplash
onto its own uhttpd instance, and a discovery logger plus a safe
`exec.Command` wrapper laid groundwork for the reseller roadmap.

## At a glance

- **Security audit sweep**: CORS wildcard removed, SSRF guards on
  post-payment NDS triggers and upstream gateway probes, 1 MB cap on
  all HTTP response body reads, backend API firewall restricted to LAN,
  spending-condition-locked (P2PK/HTLC) tokens rejected, and a
  deployment backup containing live credentials purged from history.
- **Identity v2**: unified NIP-06 + HKDF derivation with a
  `RevealSeed` flow, replacing the earlier identity package.
- **Captive portal decoupled from NoDogSplash**: a dedicated uhttpd
  instance on port 2051 serves the SPA; NDS pre-auth now returns a
  tiny stub that redirects to it.
- **Dependency alignment**: all modules build against upstream
  `OpenTollGate/gonuts-tollgate` v0.11.1 (fork `replace` dropped).
- **Discovery logger**: structured scan history for TollGate AP
  analysis, with a `tollgate-cli upstream known` summary.
- **Safe exec wrapper**: new `src/sysexec/` package for context,
  timeout, and retry around `exec.Command`.
- **WalletPort interface**: `GonutsWallet` adapter plus token-flow
  tests, and NUT-00 `hash_to_curve` cross-implementation vectors.

## What's new

### Security audit sweep

A multi-layer audit (cashu-audit Layer 3, prta #86, and the SEC-AUDIT
chain) drove a broad hardening pass:

- **CORS wildcard removed.** `CorsMiddleware` no longer falls back to
  `Access-Control-Allow-Origin: *`; the origin is echoed only for
  local/private origins and for pages served by the router itself on
  another port, with `Vary: Origin` added on echo. A wildcard would
  have let any website read API responses from a browser on the
  TollGate network. POSTs with unsupported content types now return
  415 instead of 400
  ([#349](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/349)).
- **Spending-condition validation.** `tollwallet.Receive()` now rejects
  tokens with P2PK or HTLC locks (`ErrLockedToken`), preventing an
  attacker from getting free access with tokens the gateway can never
  spend
  ([#330](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/330)).
- **SSRF guards.** The post-payment NDS session trigger validates the
  upstream `GatewayIP` before issuing its port-80 GET, and the TollGate
  prober rejects loopback, unspecified, and link-local addresses
  ([#315](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/315),
  [#196](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/196)).
- **1 MB response-body cap.** All `io.ReadAll` calls on HTTP response
  bodies now use `io.LimitReader`, preventing OOM crashes on
  resource-constrained routers
  ([#274](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/274)).
- **Backend API firewall.** A new nftables include restricts the
  backend API (port 2121) to LAN interfaces; WAN-side and upstream
  clients can no longer probe it directly
  ([#345](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/345)).
- **Deployment backup purged.** A directory containing the merchant
  private identity key, an ecash `wallet.db`, and spendable recovery
  tokens was accidentally committed and has been removed from history;
  incident details and key-rotation tracking in
  [SECURITY.md](SECURITY.md) and
  [#364](https://github.com/OpenTollGate/tollgate-module-basic-go/issues/364).

### Identity v2

Identity handling was rebuilt on a unified NIP-06 + HKDF derivation
with a `RevealSeed` flow
([#331](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/331)).
The new package consolidates the earlier identity work and adds a
POST-only seed-reveal endpoint with loopback enforcement.

### Captive portal decoupled from NoDogSplash

The SPA is no longer served through nodogsplash. A dedicated uhttpd
instance on port 2051 serves the portal directly, and NDS pre-auth now
returns a tiny stub page (well under 1 KB) that redirects clients to
it
([#348](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/348)).
This fixes NDS error-page rendering for clients it cannot map to a MAC
and keeps pre-auth responses small. The stub's `<noscript>` fallback
link also handles CIDR-notation LAN IPs correctly.

### Dependency alignment

All modules now build against upstream
`OpenTollGate/gonuts-tollgate` v0.11.1; the felixfelix-bot fork
`replace` directive was dropped
([#361](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/361)).
This follows the earlier module rename (Origami74 → OpenTollGate) and
the v0.7.4 → v0.11.1 bump chain that fixed the swap-counter race, V2
keyset crashes, and mint 429 handling.

### Discovery logger and safe exec

- **Discovery logger.** Background scan cycles now log every discovered
  AP (BSSID, SSID, signal, radio, TollGate flag, price/step) to
  `/etc/tollgate/discovery_log.jsonl`, with an in-memory registry and a
  new `tollgate-cli upstream known` summary
  ([#312](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/312)).
- **Safe exec wrapper.** New `src/sysexec/` package provides a testable
  `Runner` interface with context, timeout, structured logging, and
  retry for `exec.Command` — the foundation for refactoring the 37
  existing call sites
  ([#265](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/265)).

### WalletPort and token-flow tests

`src/tollwallet` gained a `WalletPort` interface with a `GonutsWallet`
adapter and token-flow tests
([#299](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/299)),
plus NUT-00 `hash_to_curve` cross-implementation vectors pinned
byte-for-byte against the canonical set
([#351](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/351)).

## Behavior changes worth flagging

These affect operators on upgrade.

- **Captive portal now served on port 2051.** The SPA loads from a
  dedicated uhttpd instance; NoDogSplash pre-auth returns a redirect
  stub. The NDS `users_to_router` allow list includes port 2051.
- **Setup version bumped to v0.6.2.** Reinstall/upgrade triggers a full
  setup rerun on already-deployed routers, installing the stub and
  portal instance alongside prior configuration. Existing
  management-WiFi credentials are preserved.
- **Management-WiFi password in setup log.** `setup_private_network()`
  writes the generated `private_key` to `/tmp/tollgate-setup.log`,
  which is now created with mode 600.
- **Backend API restricted to LAN.** Port 2121 is no longer reachable
  from WAN or upstream interfaces.

## Notable bug fixes

The [CHANGELOG](CHANGELOG.md) has the exhaustive list. The
operator-relevant subset:

- **Client MAC from request body/query.** The backend now accepts a
  `mac` field in Lightning and Cashu payment requests, and a `mac`
  query param for invoice polling and `/whoami`, so the splash page can
  pass the real client MAC instead of relying on IP-based ARP/DHCP
  lookup behind the reverse proxy
  ([#358](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/358)).
- **Mint 429 error mapping.** A rate-limited mint now returns
  `mint-rate-limited` with a user-friendly message instead of a generic
  payment failure
  ([#346](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/346)).
- **Lightning quote persistence.** Quotes are persisted to disk and
  survive restarts; a data race and crash-safety gap in the persistence
  path were fixed
  ([#248](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/248),
  [#269](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/269)).
- **`Fund()` token decode.** Now uses generic `DecodeToken` (V4 then
  V3) instead of V4-only
  ([#330](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/330)).
- **Upgrade no longer rotates management-WiFi credentials.**
  `setup_private_network()` reuses an existing private SSID/PSK.
- **Dead firewall include removed.** The `firewall-tollgate` include
  file was silently rejected by fw4; rules are now created via UCI named
  sections
  ([#196](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/196)).

## Upgrade notes

Operator-actionable items moving from v0.5.0 to v0.6.0:

- **Expect the portal on port 2051** after upgrade; NoDogSplash
  pre-auth now redirects to it.
- **A setup rerun will occur** (setup version bumped to v0.6.2). Your
  management-WiFi credentials are preserved.
- **The backend API is now LAN-only.** If you relied on reaching port
  2121 from outside the LAN, that path is closed.
- **Rotate any credentials** if you ever pulled a build between the
  deploy-backup exposure and its purge (see
  [SECURITY.md](SECURITY.md)).

## Getting v0.6.0

- **Pre-built packages and firmware**:
  [releases.tollgate.me](https://releases.tollgate.me) — the release
  manager for firmware images and package builds.
- **Nostr**: releases are announced as NIP-94 file-metadata events on
  the project relays, with multiple Blossom mirror URLs per artifact.
- **OpenWrt 25.x**: `apk add --allow-untrusted tollgate-wrt-<version>.apk`
- **OpenWrt 24.10 and earlier**: `opkg install tollgate-wrt_<version>_<arch>.ipk`
- **From source**: [scripts/build-sdk-package.sh](scripts/build-sdk-package.sh)
  cross-compiles the binaries (Go version per [src/go.mod](src/go.mod))
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
[@Origami74](https://github.com/Origami74), and Alex Xie.
