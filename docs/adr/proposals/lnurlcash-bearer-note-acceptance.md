# ADR-XXX: Accept LNURLcash Bearer Notes at Portal (LUD-25 Role B)

- **Status:** Proposed
- **Date:** 2026-08-17
- **Related:** `src/main.go` (route registration, `HandleLightningInvoice`, `handleRoot`), `src/lightning/lightning.go` (`ssrfSafeClient`, `validateCallbackURL`, `LNURLPayResponse`), `src/merchant/quote_store.go` (`quoteStore`, `persistedQuote`, atomic write pattern), `src/tollwallet/tollwallet.go` (`TollWallet`, `RequestMint`/`MintQuoteState` flow)

---

## Context

### Current LNURL state in tmbg

The gate runs **zero LNURL server endpoints** today. The only LNURL code in
the codebase is client-side `payRequest` logic in `src/lightning/lightning.go`
(lines 51–137), used for profit-share payouts to a Lightning Address. That code
already implements an SSRF-hardened HTTP client (`ssrfSafeClient`, lines 16–35)
and URL validation (`validateCallbackURL`, line 133) that blocks loopback,
private, and link-local addresses on all outbound calls.

All BOLT11 invoice creation and payment is delegated to external Cashu mints
via NUT-04 mint quotes. The existing flow (`/ln-invoice` endpoint, lines 677–789)
is: POST `{amount, mint_url}` → `merchant.RequestLightningInvoice` → NUT-04
quote at trusted mint → return BOLT11 to portal → portal polls GET `?quote=`
→ `MintQuoteState` → on paid, `grantSessionAccess` → `AddAllotment` →
`valve.OpenGate`. Quote state survives restarts via `quoteStore` (atomic
JSON temp-file + rename, `src/merchant/quote_store.go`).

The captive portal SPA (separate repo: `tollgate-captive-portal-site`) has a
QR-scan + paste path and a disabled "Lightning" tab showing "Coming Soon".

### LUD-25 opportunity

[LUD-25](https://github.com/lnurl/luds/blob/lud-25/LUD-25.md) ("LNURLcash")
defines bearer notes as `lnurlw://` withdraw links carrying a `k1` secret. The
draft is unmerged and unnumbered (dependency graph labels it `XX`). However,
**the redemption mechanics are pure LUD-03** — any `lnurlw` link can be melted
via a standard withdrawRequest informational GET + callback GET with `?k1=&pr=`
query parameters, frozen since 2018. No LUD-25-specific feature is required to
accept a bearer note as payment.

This means the gate can accept **any** LUD-03 withdraw link — LNbits vouchers,
boltcard-adjacent links, zap cash-out links, future LUD-25 bearer notes — as
guest payment with zero draft-spec dependency.

### Why Role B first

The consultant report (`lud25-tmbg-consult-2026-08-17.md`) evaluated three
integration options:

- **Option A** — Gate as LNURLcash **issuer** (voucher issuance, split/merge,
  rotate, offline sigs): 500–700 LOC, maximum draft-churn exposure, gated on
  spec maturity. Deferred to Phase 3.
- **Option B** — Gate **accepts** notes at the portal as guest payment: ~200
  LOC, pure LUD-03 semantics, zero draft-spec dependency. **This ADR.**
- **Option C1** — Bridge notes → Cashu tokens inside the user's wallet: same
  code, different surface (gonuts wallet/portal balance page). Phase 2.

Role B is first because it delivers the highest user value (universal voucher
acceptance, zero wallet install) at the lowest cost and risk. It reuses the
entire `/ln-invoice` plumbing: NUT-04 quote at trusted mint, `MintQuoteState`
poll, `grantSessionAccess` — only the front-half changes (parse `lnurlw` URL,
informational GET, LUD-03 callback melt instead of "user pays BOLT11 in their
wallet").

---

## Decision

Accept `lnurlw` bearer notes at the portal via a new `/note-pay` endpoint on
the gate.

### Flow

1. **Portal submits** `POST /note-pay {lnurl: "<lnurlw URL or bech32-encoded>"}`.
2. **Gate parses** the `lnurlw` URL (raw `lnurlw://` scheme or bech32 LNURL
   decode via existing `btcd/btcutil` dependency).
3. **Gate fetches** the LUD-03 withdrawRequest informational endpoint:
   `GET <issuer>?k1=<k1>` → `{tag: "withdrawRequest", callback, k1,
   minWithdrawable, maxWithdrawable}`. Uses `ssrfSafeClient` (SSRF-hardened).
4. **Gate requests** a NUT-04 mint quote at its trusted mint for
   `maxWithdrawable` msat → receives BOLT11 `pr_M` (same path as
   `RequestLightningInvoice`).
5. **Gate calls** the LUD-03 callback: `GET <callback>?k1=<k1>&pr=<pr_M>` →
   issuer validates, marks k1 pending, returns `{status: "OK"}` (async payout).
6. **Gate polls** `MintQuoteState` (existing monitor goroutine pattern from
   `src/lightning/lightning.go`) until the mint confirms the invoice is paid.
7. **On paid**: `grantSessionAccess(macAddress)` → `AddAllotment` →
   `valve.OpenGate`. Same session-grant funnel as `/ln-invoice`.
8. **On failure/timeout**: quote expires, k1 restored at issuer. Gate returns
   error to portal; user may retry with a fresh note.

### What stays the same

- **Pure LUD-03 semantics**: informational GET + callback GET. No LUD-25
  feature (rotate, split, merge, pending, sigs) is invoked or required.
- **NUT-04 quote + monitor**: identical to the existing `/ln-invoice` flow.
  The only new code is the URL parser + informational GET + callback GET.
- **Zero draft-spec dependency**: if LUD-25 is never merged, this still works
  with every LUD-03-compliant withdraw link.

---

## Invariants

1. **Guest needs no wallet.** The portal collects the `lnurlw` link (paste or
   QR scan). The gate performs the melt. The guest never installs software.
2. **Gate stays a LUD-03 consumer.** The gate issues no `withdrawRequest`
   endpoint and never serves bearer notes. It only calls existing LUD-03
   endpoints on external issuers.
3. **No k1 storage on gate beyond pending-melt tracking.** The gate does not
   persist k1 values; it tracks only the NUT-04 quote (via existing `quoteStore`)
   and the pending callback. Once the quote settles or expires, all note state
   is discarded.
4. **SSRF guard on all outbound calls.** Both the informational GET and the
   callback GET must route through `ssrfSafeClient` / `validateCallbackURL`.
   No unguarded `http.Get` is permitted on any URL derived from user input.

---

## Consequences

### Positive

- **Universal voucher acceptance.** Any LUD-03 withdraw link from any issuer
  (LNbits, boltcard, future LUD-25 notes) pays for access. No issuer
  cooperation or pre-registration needed.
- **Zero wallet install for the guest.** The guest pastes a link or scans a QR;
  the gate does the rest. This replaces the disabled "Lightning" tab with
  something cheaper and more universal.
- **Zero pre-funding for the gate.** The note's value arrives as fresh ecash
  (the note issuer pays the gate's mint-quote invoice). No float management.
- **Minimal code surface.** ~200 LOC server-side; reuses NUT-04 quote, monitor,
  quoteStore, SSRF client, rate limiter, CORS middleware, MAC resolution,
  session-grant funnel — all existing, all tested.

### Costs

- **Portal repo release coupling.** The captive-portal-site JS must ship
  LNURL detection + status polling in the same release window as the gate
  endpoint. The gate endpoint alone is inert without the portal UI. This
  couples two repos' release timelines for the first time.
- **Captive-browser QR limits.** The portal's in-browser QR scanner may
  struggle with low-quality camera input or URL-encoded LNURL strings that
  exceed typical QR density limits. Paste fallback mitigates this.
- **Open race window.** Between user paste and gate's callback GET, a
  competing claim on the same k1 could win (first-GET-wins at issuer). Tiny
  but nonzero. If the issuer implements LUD-25 rotate, an optional fast-path
  could close this atomically — but that is Phase 2+ and not required for
  Phase 1.
- **No change-making.** If note value > session price, the gate overpays
  (no split). The user's wallet could split pre-payment if it implements
  LUD-25. This is a known limitation, not a regression (current Lightning
  tab is disabled).

---

## Rollout / PR Sequence

### PR1 — Gate: `/note-pay` endpoint + tests

**Repo:** `tollgate-module-basic-go`
**Branch:** `feat/lnurlcash-note-pay`

- New file `src/lightning/lnurlw.go`: parse `lnurlw://` raw scheme + bech32
  LNURL decode; `WithdrawRequest` struct; `FetchWithdrawRequest` (SSRF-hardened
  informational GET); `MeltNote` (callback GET with `?k1=&pr=`).
- New file `src/lightning/lnurlw_test.go`: unit tests for URL parsing, SSRF
  rejection, fake issuer via `httptest.Server`, k1-melt bridge to fake mint.
- Modified `src/main.go`: register `POST /note-pay` handler; wire to existing
  `grantSessionAccess` → `AddAllotment` → `valve.OpenGate` funnel.
- CHANGELOG `[Unreleased]` → `Added` entry.
- Run: `gofmt -l . && go vet ./... && go build ./... && go test -race -count=1 -tags testenv ./...`

### PR2 — Portal: LNURL detect + status polling

**Repo:** `tollgate-captive-portal-site` (separate)
**Branch:** `feat/lnurlcash-portal`

- Portal JS detects `lnurlw://` scheme or bech32 LNURL in the paste/scan input.
- New "Voucher" tab (replaces disabled "Lightning" tab).
- POSTs to `/note-pay`, polls GET `/note-pay?quote=` for status.
- Display `maxWithdrawable` as the note value (never the unsigned URL `amount`).

### PR3 — Hardening + contract tests

**Repo:** `tollgate-module-basic-go`
**Branch:** `fix/lnurlcash-hardening`

- Contract tests against a real LNbits test instance (if available) or
  expanded httptest fake covering edge cases (expired quotes, issuer 5xx,
  callback race, k1 already pending).
- Rate-limit tuning for `/note-pay` (stricter than default; prevents
  k1-probing attacks).
- Input validation hardening (URL length caps, scheme allowlist, body size).

---

## Notes

- **LUD-25 draft status:** The spec is unmerged and unnumbered
  (`dependencies.dot` labels it `XX`). This ADR depends on **LUD-03** (frozen
  since 2018) and **NUT-04/NUT-05** (stable). Zero LUD-25-specific behavior is
  required or assumed.
- **Full LUD-25 matrix deferred to Phase 3.** Issuer-side features (withdrawRequest
  SERVICE, k1 store, split/merge/fees, rotate, offline sigs) are gated on the
  draft being numbered and having at least one independent implementor. Track
  the draft; budget for 2–3 breaking revisions if Phase 3 proceeds.
- **Offline sigs blocked.** The gate's merchant Nostr key is Schnorr (BIP-340).
  LUD-25 offline note signatures use ECDSA (RFC 6979 / secp256k1 ECDSA). These
  are not compatible. Offline signature verification would require a separate
  ECDSA key or a different sig scheme in the draft. Not needed for Role B
  (online redemption only).
- **Plain-HTTP LAN risk.** `k1` travels in GET query strings. On a plain-HTTP
  captive LAN, a k1 is sniffable → race the holder. This is intrinsic to LNURL,
  not fixable in the draft. The gate mitigates by acting as the melter (the
  guest never sees the callback URL or the BOLT11), but the guest's initial
  paste of the `lnurlw` link is still visible on the wire if the portal is
  HTTP-only. HTTPS or onion is the long-term fix; out of scope for this ADR.
