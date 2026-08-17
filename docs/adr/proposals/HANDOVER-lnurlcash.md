# HANDOVER-lnurlcash.md — Implementation Handover for `/note-pay` (Phase 1, Role B)

> **This file is a working handover document, not a permanent doc.** It is
> kept on this `docs/adr-lnurlcash` branch only. Do NOT open a PR containing
> this file. The implementing branch (`feat/lnurlcash-note-pay`) must NOT
> carry it (repo AGENTS.md forbids committing planning documents). Read it
> here, then delete it from your staging area.

---

## Mission

Implement **PR1** from
[`docs/adr/proposals/lnurlcash-bearer-note-acceptance.md`](./lnurlcash-bearer-note-acceptance.md)
(on this same branch): a `POST /note-pay` endpoint on the TollGate backend that
accepts an `lnurlw://` bearer-note (or bech32-encoded LNURL withdraw link) from
the captive portal, melts it via LUD-03 against the gate's trusted Cashu mint
(NUT-04), and grants a session on payment — the same funnel as `/ln-invoice`.

The guest pays with **any** LUD-03 withdraw link. No wallet install. Pure
LUD-03 semantics, zero LUD-25 draft-spec dependency.

## Branch setup

```bash
# One-time worktree creation (adjust paths to your machine)
cd ~/repos/tollgate-module-basic-go
git worktree add ~/worktrees/tmbg-lnurlcash -b feat/lnurlcash-note-pay upstream/main

# Then work here:
cd ~/worktrees/tmbg-lnurlcash
```

Branch: `feat/lnurlcash-note-pay`, based on `upstream/main`.

## Implementation breakdown

### Files to create

#### `src/lightning/lnurlw.go` (~150 LOC)

```go
// ParseLNURLw accepts:
//   1. Raw LUD-17 scheme:  lnurlw://host/path?k1=...&amount=...
//   2. Bech32 LNURL:       LNURL1... (uppercase or lowercase) → decodes to
//      an https:// URL whose response has tag "withdrawRequest"
// Returns (issuerBaseURL, k1, declaredAmount, error).
// NOTE: the URL `amount` param is unsigned and ignorable — display
// maxWithdrawable from the informational GET instead.
func ParseLNURLw(raw string) (*url.URL, string, uint64, error)

// WithdrawRequest mirrors LUD-03 withdrawRequest JSON.
type WithdrawRequest struct {
    Tag              string `json:"tag"`               // must be "withdrawRequest"
    Callback         string `json:"callback"`          // validated via validateCallbackURL
    K1               string `json:"k1"`
    DefaultDescription string `json:"defaultDescription"`
    MinWithdrawable  int64  `json:"minWithdrawable"`   // msat
    MaxWithdrawable  int64  `json:"maxWithdrawable"`   // msat — AUTHORITATIVE value
}

// FetchWithdrawRequest does the informational GET: GET <issuerBase>?k1=<k1>
// Must use ssrfSafeClient (SSRF-hardened). Reject tag != "withdrawRequest".
func FetchWithdrawRequest(ctx context.Context, issuer *url.URL, k1 string) (*WithdrawRequest, error)

// MeltNote does the LUD-03 callback: GET <callback>?k1=<k1>&pr=<bolt11>
// Must use ssrfSafeClient. Issuer returns {"status":"OK"} on acceptance
// (payout is async). Treat "ERROR"/non-200 as failure.
func MeltNote(ctx context.Context, callback string, k1, bolt11 string) error
```

Bech32 decode: use existing `btcutil` dependency
(`github.com/btcsuite/btcd/btcutil/bech32`) — already a transitive dep via
gonuts; verify with `go list -m` before adding anything new.

#### `src/lightning/lnurlw_test.go` (~150 LOC)

- `TestParseLNURLw` — raw scheme, bech32 (upper+lower), garbage, wrong tag,
  missing k1, oversized URL.
- `TestFetchWithdrawRequest_SSRF` — `httptest.Server` standing in for issuer;
  assert loopback/private/link-local IPs are rejected even though
  httptest binds loopback (mock the dialer or test `validateCallbackURL`
  directly).
- `TestMeltNote` — fake issuer accepts `?k1=&pr=`, returns `{"status":"OK"}`.
- `TestNotePayBridge` — end-to-end-ish: fake issuer + fake mint quote →
  assert `grantSessionAccess` called (or that the quote record reaches
  "paid" state via the existing monitor).

### Files to modify

#### `src/main.go`

- Register `POST /note-pay` (+ `GET /note-pay?quote=` for status polling)
  alongside the existing `http.HandleFunc` block (lines ~796–819). Wrap in
  `CorsMiddleware(RateLimitMiddleware(HandleNotePay))` — note `/note-pay`
  needs **both** CORS and rate-limit (the `/` endpoint uses both; `/ln-invoice`
  uses only CORS — follow the `/` pattern since the note value flows through
  the body).
- `HandleNotePay` (POST): parse body `{lnurl: string}` (1MB cap via
  `http.MaxBytesReader`, see line 448 pattern) → `ParseLNURLw` →
  `FetchWithdrawRequest` → `RequestLightningInvoice(mac, mintURL,
  maxWithdrawable/1000)` (existing merchant method, returns quote+BOLT11) →
  `MeltNote(callback, k1, bolt11)` → return
  `{status:1, quote:..., state:"pending", max_withdrawable:...}` to portal.
- `handleNotePayGet`: identical shape to `handleLightningInvoiceGet` (lines
  752–789) — poll by quote ID, MAC-bound.

Expected response schema (both POST and GET):

```json
{
  "status": 1,
  "quote": "<quote-id>",
  "state": "pending|paid|expired|failed",
  "max_withdrawable": 21000,
  "access_granted": false,
  "allotment": 0,
  "error": ""
}
```

#### `src/lightning/lightning.go` (minor)

- Export `ValidateCallbackURL` (currently `validateCallbackURL`, line 133) so
  `lnurlw.go` can use it. No behavior change; just rename + wrap.

#### `CHANGELOG.md`

`[Unreleased]` → `### Added`:

```markdown
- **LNURL withdraw-link (lnurlw) payment at portal.** New `POST /note-pay`
  endpoint accepts any LUD-03 withdraw link (LNbits voucher, boltcard-adjacent,
  future LUD-25 bearer note) as guest payment. The gate melts the note via
  its trusted Cashu mint (NUT-04) and grants a session on settlement — same
  funnel as `/ln-invoice`. No wallet install required for the guest.
  ([#N](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/N))
```

(Fill in `#N` when the PR number is known; the maintainer rewrites final
commit messages anyway.)

## Constraints

- **`GOTMPDIR=/tmp`** — `go test` writes temp files; on some mounts the
  default TMPDIR is not writable or is noexec. `export GOTMPDIR=/tmp` before
  running any `go` command.
- **Go tooling from `src/`** — all `gofmt`/`go vet`/`go build`/`go test`
  commands run from `src/`, NOT the repo root. The `go.mod` lives in `src/`.
- **No AI attribution** — no `Co-Authored-By:`, no "Generated with" footers,
  in commits or PR bodies. See AGENTS.md.
- **CHANGELOG `[Unreleased]` entry required** — see template above.
- **AGENTS.md rules apply in full:**
  - One logical change per PR (this is one endpoint + its tests — do not
    sneak in refactors).
  - No planning docs committed (`HANDOVER-lnurlcash.md` stays on
    `docs/adr-lnurlcash` branch, NOT on `feat/lnurlcash-note-pay`).
  - gofmt+vet+build+test before PR (exact command below).
- **Pre-push:** run from `src/`:

  ```bash
  export GOTMPDIR=/tmp
  gofmt -l .          # must print nothing
  go vet ./...
  go build ./...
  go test -race -count=1 -tags testenv ./...
  ```

## What NOT to implement (Phase 3 — do not build)

- **No issuing/minting** — the gate never serves a `withdrawRequest`
  endpoint, never creates bearer notes.
- **No split/merge** — the gate cannot make change on a note.
- **No rotate** — even if the issuer advertises LUD-25 rotate, Phase 1
  does not use it. Optional fast-path is Phase 2+.
- **No offline signature verification** — the gate's merchant Nostr key is
  Schnorr (BIP-340), LUD-25 offline sigs are ECDSA (RFC 6979). Blocked.
- **No standalone bridge service** — the melt runs inside the gate, using
  the guest's pasted link. Never collect k1 in a third-party service
  (custodial-by-necessity, see consultant report §1 Option C2).
- **No BOLT11 local decode** — not needed for this flow (only LUD-21 verify
  would need it, which is optional and out of scope).

## Testing

- **Unit tests for:** URL parse (raw + bech32), SSRF rejection, k1-melt
  bridge, quote-state transitions.
- **Fake issuer:** `httptest.Server` responding to `GET ?k1=` with a valid
  `withdrawRequest` JSON, and to the callback with `{"status":"OK"}`.
- **Fake mint:** stub `merchant.GetMerchant().RequestLightningInvoice` — or
  use the existing test seam if one exists in `src/merchant/` tests.
- **Command** (from `src/`, with `GOTMPDIR=/tmp`):

  ```bash
  go test -race -count=1 -tags testenv ./...
  ```

## Existing code references (read these first)

| What | Where | Why |
|---|---|---|
| Route registration + middleware wrapping | `src/main.go:796–819` | Where to add `/note-pay` |
| `HandleLightningInvoice` (POST+GET pattern) | `src/main.go:677–789` | Copy this shape for `HandleNotePay` |
| Body parse with 1MB cap | `src/main.go:448` (`http.MaxBytesReader`) | Reuse for `/note-pay` POST |
| `getMacAddress` | `src/main.go` (search `func getMacAddress`) | MAC from IP, binds quote to device |
| SSRF-safe HTTP client | `src/lightning/lightning.go:16–35` (`ssrfSafeClient`) | ALL outbound GETs must use this |
| Callback URL validation | `src/lightning/lightning.go:133` (`validateCallbackURL`) | Export + reuse for callback |
| Existing LNURL client (payRequest) | `src/lightning/lightning.go:51–137` | Pattern for informational GET + response structs |
| Quote persistence pattern | `src/merchant/quote_store.go` (`quoteStore`, `persistedQuote`) | Atomic JSON write (temp+rename); reuse for note-pay quotes |
| Mint quote flow | `src/tollwallet/tollwallet.go` (via `wallet.RequestMint` / `wallet.MintQuoteState` in gonuts) | The NUT-04 quote lifecycle you're bridging into |
| `grantSessionAccess` funnel | `src/main.go` / `src/merchant/` (search `grantSessionAccess`) | Session grant on paid — same as `/ln-invoice` |

## Consultant report

Full adversarial analysis: `~/reports/lud25-tmbg-consult-2026-08-17.md`
(local to the manager workstation — not in any repo). Key sections for
implementation: §2 (bridge mechanics, step-by-step), §4 traps (esp. #1
plain-HTTP LAN, #3 unsigned amount, #5 pending-DoS — the gate side of all
three is mitigated by using `ssrfSafeClient`, trusting only
`maxWithdrawable`, and rate-limiting `/note-pay`).
