<!-- markdownlint-disable MD013 -->

# The TollGate v1 client contract

**Scope.** What a *client* (Android app, Debian agent, anything that is not a router)
must do to discover a v1 TollGate and buy internet from it. Extracted from the
implementation in this repository and the protocol repo, not from memory. Every claim
below carries a `file:line` or a command's output.

**Sources of truth, in precedence order**

| Order | Source | What it is authoritative for |
|---|---|---|
| 1 | `OpenTollGate/tollgate-module-basic-go` (this tree, `main` @ `eb12d7f8`) | the bytes on the wire, today |
| 2 | `OpenTollGate/tollgate` protocol docs (`HTTP-01/02/03`, `TIP-01/02`) | what a spec-compliant peer must accept |
| 3 | `OpenTollGate/tollgate` `corpus/` (v1, updated 2026-10-16) | recorded request/response vectors with per-vector verdicts |

Where 1 and 2 disagree, the divergence is called out explicitly — a client that
implements only the spec will still fail against a real router.

**Terminology.** "client" = the customer device. "module" = the Go daemon on the router
(`tollgate`, serving `:2121`). "step" = the pricing quantum: `step_size` units of the
advertised `metric`.

---

## 1. The four things a client does

```
            ┌─────────────────────────────────────────────────────────┐
  discover  │  GET  http://<gw>:2121/            → kind:10021 advert   │
            │  (or: 802.11 vendor IE / SSID prefix as a *hint*)       │
            ├─────────────────────────────────────────────────────────┤
  identity  │  GET  http://<gw>:2121/whoami      → "mac=xx:..:xx"      │
            ├─────────────────────────────────────────────────────────┤
  fund      │  POST http://<gw>:2121/ln-invoice  → bolt11 + quote      │
            │  …pay bolt11…                                           │
            │  GET  http://<gw>:2121/ln-invoice?quote=<id> → access    │
            │  (or arrive already holding ecash from the advertised    │
            │   mint and skip this whole block)                        │
            ├─────────────────────────────────────────────────────────┤
  buy       │  POST http://<gw>:2121/  text/plain, raw cashu token     │
            │  → 200 kind:1022 session  |  400 kind:21023 notice       │
            └─────────────────────────────────────────────────────────┘
```

**The load-bearing constraint:** there is no authentication anywhere. The purchase is
authorised by the *bearer instrument in the body* and attributed by the *source IP of
the connection*. A client cannot name itself. That single fact drives most of the
design consequences in §5.

---

## 2. Advertisement — `GET /` and `kind:10021`

### 2.1 Transport

| Property | Value | Cite |
|---|---|---|
| Port | `2121` (plain HTTP) | `src/main.go:463` (`apiListenAddr = ":2121"`) |
| Method | `GET` (any non-POST verb reaches the advertisement) | `src/main.go:1316-1322` (`HandleRoot`) |
| Content-Type | exactly `application/json`, no charset | `src/main.go:1138`; pinned by `src/e2e_test.go:29-38` |
| Body | one serialized, **signed** Nostr event, `kind: 10021` | `src/merchant/merchant.go:1992`, signed at `:2021` |
| Mux behaviour | `/` is a catch-all — any unregistered GET path returns the advert | `corpus/http/http01-discovery.json` (`endpoint` field) |
| Rate limit | per-IP, default 10 req/min, burst 10, shared with `POST /`, 429 + `Retry-After` | `src/main.go:45-59`, `:62-119` |

### 2.2 Tag grammar (exactly what the module emits)

```
["metric",            "<milliseconds|bytes>"]
["step_size",         "<uint64>"]
["tips",              "1", "2"]
["price_per_step",    "cashu", "<price>", "<unit>", "<mint_url>", "<min_steps>"]   × N mints
```

Emitted at `src/merchant/merchant.go:1991-2009`; one `price_per_step` per *advertised*
mint (`:2002-2008`, loop over `tracker.GetAdvertisedMintConfigs()` at `:1989`).

| Tag | Type | Meaning | Cite |
|---|---|---|---|
| `metric` | `milliseconds` or `bytes` | what `allotment` is denominated in | `merchant.go:1994`; config default `bytes` (`config_manager_config.go:478`) |
| `step_size` | uint64 | units per step; default **22020096** (21 MiB) for `bytes` | `merchant.go:1995`; `config_manager_config.go:476` |
| `tips` | TIP numbers | implemented spec TIPs; module emits exactly `1`, `2` | `merchant.go:1996` |
| `price_per_step[1]` | literal `cashu` | bearer-asset type. **Always `cashu`** — a client must reject anything else | `merchant.go:2004`; spec `TIP-02.md:25` |
| `price_per_step[2]` | uint64 | price for **one step**, in `[3]` units | `merchant.go:2005` |
| `price_per_step[3]` | string | unit label, e.g. `sat` | `merchant.go:2006` |
| `price_per_step[4]` | URL | accepted mint | `merchant.go:2007` |
| `price_per_step[5]` | uint64 | min steps per purchase; `0`/absent MUST be read as `1` | `merchant.go:2008`; spec `TIP-02.md:29`; config normalises to 1 (`config_manager_config.go:138-168`) |

Parser the module itself will accept the advert against: `src/tollgate_protocol/validator.go:82-158`
(`ExtractAdvertisementInfo`), which skips malformed `price_per_step` tags (`:115-117`),
defaults `min_steps` to 1 (`:124-127`), and requires non-empty `metric`, non-zero
`step_size`, ≥1 pricing option (`:146-156`).

### 2.3 What a client may trust, and what it must validate itself

`ValidateAdvertisement` (`validator.go:33-53`) checks **only** kind + signature. There
is no cross-check against anything. Consequently:

| Field | Trustworthy? | Why |
|---|---|---|
| event `pubkey`, `sig` | **yes** — this is the identity anchor | `validator.go:44-50`; `corpus/http/http01-discovery.json` pins `signed: true` |
| `metric` | yes | drives `calculateAllotment` (`merchant.go:2081-2088`); an unsupported value makes the module refuse every purchase |
| `step_size` | yes | `merchant.go:2094`, `:2105` |
| `price_per_step[2]` (price) | yes, it is the number the module divides by | `merchant.go:2074` (`steps := amountSats / mintConfig.PricePerStep`) |
| `price_per_step[4]` (mint) | yes — the module matches it against `AcceptedMints` by normalised URL | `merchant.go:2059-2064` (`MintURLMatches`) |
| `price_per_step[3]` (**unit**) | **NO — unvalidated. A client MUST verify.** | see below |
| `price_per_step[5]` (min_steps) | yes, enforced | `merchant.go:2077-2079` |
| `tips` | advisory only | nothing in the purchase path reads it |

**The `price_unit` gap, precisely.** `MintConfig.PriceUnit` is a free-form string
(`config_manager_config.go:135`), surfaced to the schema as a plain `string` with no
enum (`config_schema.go:78`), defaulted to `"sat"` (`config_manager_config.go:358`),
with one legacy spelling normalised (`"sats"` → `"sat"`, `config_manager_config.go:627-628`).
Nothing anywhere compares it to the mint's actual keyset units. The wallet itself is
sat-only: `GonutsWallet` resolves keysets with `cashu.Sat`
(`tollwallet/gonuts_wallet.go:104,110`) and the cdk adapter mints
`cdk_ffi.CurrencyUnitSat{}` (`tollwallet/cdk_wallet.go:406`). So an operator who writes
`"price_unit": "eur"` gets an advert that promises EUR and a module that only ever
settles sat.

**Client rule (must implement):** fetch `<mint_url>/v1/keysets` (NUT-02) before
trusting a pricing option; accept the option only if `<unit>` maps to `sat` *and* the
mint serves a `sat` keyset. Treat any other unit as **not purchasable** rather than
attempting a conversion — there is no exchange rate in the advert and inventing one
would silently misprice every step.

### 2.4 The unsigned discovery hints (use to select, never to decide)

Two pre-association hints exist beside the signed advert. Both are explicitly
**hints that select candidates for the signed probe**:

1. **SSID prefix** — `TollGate-` (case-insensitive) plus a whitelabel prefix.
   `src/wireless_gateway_manager/brands.go:34`; decision record
   `docs/architecture/discovery-signaling-decision.md:18-20`.
2. **802.11 vendor IE** — OUI `21:21:21`, element type `0x01`, TLV body carrying
   version/flags and optional `mint_url` (0x01), `pubkey` (0x02), `price_per_step`
   (0x03, 2-byte BE), `step_size` (0x04, 2-byte BE).
   `src/wireless_gateway_manager/vendor_element_manager.go:15-34`, encoded at `:38-116`.

The IE is capped at 255 bytes and silently drops the mint TLV when it will not fit
(`vendor_element_manager.go:64-71`), and drops pricing TLVs under pressure
(`:83-91`) — so **missing pricing in the IE means "unknown", never "free"**. A
non-Android client generally cannot read probe responses at all; the SSID prefix plus a
`:2121` probe is the portable path.

---

## 3. Identity — how the module decides who is paying

### 3.1 The rule

Every client-scoped route resolves the caller from **the connection's source IP**, via
`/tmp/dhcp.leases` then `/proc/net/arp`, canonicalised, with the all-zero sentinel
refused:

- `clientIdentity` → `clientMACFromSocket` → `getMacAddress`
  (`src/main.go:1028-1032`, `:950-964`, `:1034-1066`)
- sentinel `00:00:00:00:00:00` is *never* an identity (`src/main.go:900-905`,
  `isUnknownMAC` `:923-926`)
- lookup sources are package vars (`dhcpLeasePath`, `arpTablePath`,
  `src/main.go:894-896`) so they are test-overridable; production never reassigns them

A client-supplied `mac` — query string or JSON body — **selects nothing**. It is
accepted for wire compatibility and reported back as ignored via
`X-TollGate-Mac-Claim-Ignored`, while `X-TollGate-Client-MAC` carries the address the
module actually used (`src/main.go:966-1022`; both headers CORS-exposed at `:1085-1095`).
Corpus pins this as an identity-spoofing test:
`corpus/http/http02-whoami.json`, vector `http02-whoami/mac-claim-ignored`.

### 3.2 What that means for an app that is not on the LAN

| Situation | Result |
|---|---|
| Client on the TollGate's `br-lan` with a DHCP lease or ARP entry | identity resolves; purchase works |
| Client on the LAN via a **static IP** with no ARP entry yet | refused `device-unresolved`; the purchase route refuses **before** reading the token (`src/main.go:1192-1199`) |
| Client reaching `:2121` through NAT/a proxy/tunnel from outside | **cannot buy.** The module sees the proxy's address, resolves it to the proxy's MAC (or nothing), and grants the session to *that* device. There is no header, token or field that changes this |
| Client that has rotated its private Wi-Fi MAC | arrives as a new device: the paid session stays filed under the old MAC, `/usage` and `/session-state` answer for the old address, and a re-purchase creates a **second** session record (`docs/architecture/session-ticket-decision.md:28-40`) |

**Consequences a client must encode:**

1. The app must be on the same L2/L3 network as the router. Vendor-IE / SSID discovery
   is fine from anywhere, but a purchase is only meaningful from the LAN side.
2. Identity is *not stable across re-association*. Any client that persists a
   "purchased at T, expect allotment X" record must key it on more than the MAC, or
   reconcile with `GET /session-state` after every reconnect.
3. `POST /session/ticket` + `POST /session/rebind` exist to carry a session across a MAC
   rotation, but the decision record is **Proposed and on hold**, so a client must not
   depend on them (`docs/architecture/session-ticket-decision.md:3-9`; routes wired at
   `src/main.go:1949-1958`).

---

## 4. Funding — arrive with ecash, or mint at the gate

### 4.1 The client must already know the mint

There is no route that tells a client "here is a token". The purchase is a **raw Cashu
token in the request body** (NUT-00 serialised, `cashuA…` V3 or `cashuB…` V4), so the
client must hold ecash *before* it POSTs. The mint is chosen by the advert: one
`price_per_step` tag per accepted mint (`merchant.go:2002-2008`), matched by
`MintURLMatches` at allotment time (`merchant.go:2059-2064`).

A token from a mint that is not in the accepted set is refused by the wallet unless
`allowAndSwapUntrustedMints` is on, with the error text
`"Token rejected. Token for mint %s is not accepted…"` (`src/tollwallet/tollwallet.go:306-311`,
error literal at `:308`)
— surfaced to the client as `payment-processing-failed` (see §5.3). **So: pick a mint
from the advert, never one the user happens to hold.**

### 4.2 The Lightning lane: mint a token *at* the gate

`/ln-invoice` lets a client that has no ecash pay a bolt11 invoice and have the module
mint the tokens into its own wallet and grant the session — the client never touches a
token. This is the only path by which a fully cold client can buy.

**Create a quote**

```
POST http://<gw>:2121/ln-invoice
Content-Type: application/json
{"amount": 4, "mint_url": "https://mint.example"}

200 {"status":1,"quote":"<id>","invoice":"lnbc…","mint_url":"…","amount":4,
     "expiry":<unix>,"state":"UNPAID","access_granted":false}
```

Handler `src/main.go:1710-1807`; request/response shapes `:1324-1354`. Notes:

- `amount` and one of `mint_url`/`mint` are required, else 400 `"amount and mint_url are required"` (`:1729-1738`)
- body capped at 8 KiB (`:124`, `:1713`); `amount` capped at 1 000 000 sat (`:128`, `:1739-1744`)
- `mint_url` is normalised by the module before use (`merchant/lightning.go:136`), so a
  trailing slash mismatch is not a failure
- the quote is **bound to the socket identity**, not to the body's `mac`
  (`src/main.go:1746-1769`)
- refusals use `writeLightningRefusal` (`src/main.go:423-435`): `{status:0, error, code, retry_after}`
  plus a matching `Retry-After` header. Codes: `device-unresolved` (400),
  `request-too-large` (413), `amount-too-large` (400), `quote-table-full` (429, retry 60),
  `mint-busy-local` (429, retry 2), `starting` (503, retry 5, `startup_gate.go:48-59`)

**Poll the quote**

```
GET http://<gw>:2121/ln-invoice?quote=<id>

200 {"status":1,"quote":"<id>","mint_url":"…","amount":4,"state":"PAID",
     "access_granted":true,"allotment":…,"metric":"bytes"}
```

Handler `src/main.go:1809-1882`. The poll is the **only** thing that triggers the mint +
grant: `GetLightningInvoiceStatus` calls `ensureLightningAccessGranted` when state is
`PAID` or `ISSUED` (`merchant/lightning.go:364-369`), which calls `MintTokens` then
`grantAccessForAmount` (`merchant/lightning.go:652-706`). **A client that pays and never
polls gets no access.** States are the NUT-04 set rendered uppercase
(`tollwallet/port.go:55-82`): `UNPAID`, `PAID`, `ISSUED`, `PENDING`, `UNKNOWN`.

Refusal that matters most: a **paid** quote whose grant failed answers
`503 code=access-grant-failed`, retry 15, "Do NOT pay again — access is retried
automatically" (`src/main.go:1849-1856`). A client must treat that as *keep polling*,
never as *pay again*.

Rate limits: POST only, three stacked quotas (per-client 6/min burst 3, per-source
20/min burst 5, global 2/s burst 5 by default); GET is deliberately unthrottled so a
customer sitting in the poll loop is never cut off (`src/main.go:1699-1708`,
`corpus/http/http03-ln-invoice.json` `rate_limit` field). Merchant-side: 3 active
quotes per MAC, 128 global, per-mint outbound budget (`merchant/lightning.go:63-67`, `:142-162`).

### 4.3 Which unit the ecash must be

**sat.** The wallet resolves keysets with `cashu.Sat` (`tollwallet/gonuts_wallet.go:104,110`)
and the cdk adapter mints sat (`tollwallet/cdk_wallet.go:406`). The token's unit is also
never checked against the advert's `price_unit` — another reason §2.3's rule is the
client's job.

---

## 5. Purchase — `POST /` with a raw token

### 5.1 The request

```
POST http://<gw>:2121/
Content-Type: text/plain
cashuB…
```

| Property | Value | Cite |
|---|---|---|
| Method | `POST` | `src/main.go:1160-1170` (405 otherwise) |
| Content-Type | `text/plain`, `application/json`, or **absent**; anything else → **415** | `src/main.go:1172-1178` |
| Body | the serialized token, ≤ 1 MiB | `src/main.go:1201-1209` |
| Auth | **none** | — |
| Legacy envelope | a `kind:21000` Nostr event with a `payment` tag is also accepted | `src/main.go:1145-1157` (`extractCashuToken`) |
| Identity | from the socket (§3); `mac` param ignored | `src/main.go:1180-1199` |
| Rate limit | same per-IP limiter as `GET /` | `src/main.go:1901-1904` |
| `application/json` body that is *not* a kind-21000 event | treated as a raw token string (`strings.TrimSpace`) | `src/main.go:1156` |

Body cap and media-type gate fire **before** the token is read, so a rejected request
consumes nothing. The identity gate also fires before the body is read — deliberately,
because "the token is received before the gate is opened" (`src/main.go:1187-1191`).

**A `kind:21000` envelope's signature is not validated** — the module logs
`"Parsed nostr event (signature not validated)"` (`src/main.go:1231`). Do not send one;
a raw token is simpler and is the path the spec prefers (`TIP-02.md:47-53`).

### 5.2 Success — `200` + `kind:1022`

```
200 application/json
{"kind":1022,"pubkey":"<gateway>","created_at":…,"tags":[
   ["device-identifier","mac","<the MAC the grant was applied to>"],
   ["allotment","<uint64>"],
   ["metric","<bytes|milliseconds>"],
   ["start-time","<unix>"]],
 "content":"","id":"…","sig":"…"}
```

`src/main.go:1257-1265` (only non-21023 responses get 200); built at
`src/merchant/merchant.go:2119-2157`. **There is no `p` tag** on the raw-token flow by
design — the customer has no Nostr identity and `p` is defined as a pubkey
(`merchant.go:2113-2118`). A client must read `device-identifier` and compare it with its
own address; a mismatch means the grant went to a different device.

Corpus pins both token formats: `http01-post/raw-v3-valid-fullservice` and
`.../raw-v4-valid-fullservice` (`corpus/http/http01-payment.json`).

### 5.3 Refusal — `400` + `kind:21023` notice

```
400 application/json
{"kind":21023,"pubkey":"<gateway>","created_at":…,"tags":[
   ["level","error"],["code","<code>"],["p","<mac>"]],
 "content":"<human message>","id":"…","sig":"…"}
```

Built at `src/merchant/merchant.go:2260-2291`. Status is **400, not 402** — spec allows
either (`HTTP-01.md:14`); the module uses 400 and the shipped portal keys off the code,
not the status (`tollgate-captive-portal-site/src/helpers/cashu.js:326-337`). Note the
`p` tag here carries the **MAC**, not a pubkey, which is a deliberate deviation from
`TIP-01.md:68` — treat it as a device identifier on this route.

**Complete code set the money route can return** (all verified by grep against `merchant.go`):

| Code | HTTP | Meaning | Retry? | Cite |
|---|---|---|---|---|
| `device-unresolved` | 400 | source IP → no MAC | fix the network, then yes | `main.go:907-917`, `:1192-1198` |
| `invalid-mac-address` | 400 | resolved but malformed | no | `merchant.go:1497-1505` |
| `payment-error-invalid-token` | 400 | token did not decode | no | `merchant.go:1507-1515` |
| `payment-error-below-swap-fee` | 400 | value ≤ mint's swap fee | no — bigger token | `merchant.go:1522-1528`, `:1748-1752` |
| `client-not-registered` | 400 | NDS does not know the MAC and this is not a renewal | reconnect, then yes | `merchant.go:1554-1561` |
| `payment-duplicate-inflight` | 400 | same note already in flight | **no** — wait | `merchant.go:1574-1582` |
| `payment-received-grant-pending` | 400 | note already received; grant owed/retried | **no — do not pay again** | `merchant.go:1619-1624`, `:1804` |
| `payment-outcome-unknown` | 400 | mint never answered a request it may have processed | **no — do not resend the note** | `merchant.go:1607-1612`, `:1691`, `:1739` |
| `payment-error-token-spent` | 400 | mint says already spent | no | `merchant.go:1730-1732` |
| `mint-rate-limited` | 400 | mint answered 429 | yes, with backoff | `merchant.go:1745-1747` |
| `payment-error-keyset-expired` | 400 | proofs on a retired keyset, unrecoverable | no — new token | `merchant.go:1753-1757` |
| `payment-error-mint-unreachable` | 400 | mint down | yes | `merchant.go:1758-1762` |
| `payment-processing-failed` | 400 | anything else (incl. mint-not-accepted) | no | `merchant.go:1763-1765` |
| `session-error` | 400 | allotment maths failed (unmatched mint, `price_per_step == 0`, below min steps, unknown metric) | no | `merchant.go:1781-1786`, `:2059-2088` |
| `service-unavailable` | 400 | degraded mode: no reachable mint; **token not consumed** | yes later | `merchant/merchant_degraded.go:196` |
| `starting` | 503 | merchant still constructing; `Retry-After: 5` | yes | `startup_gate.go:145-146` |

Corpus vectors for the observable ones: `http01-post/spent-token`,
`.../raw-garbage-fullservice`, `.../device-unresolved`, `.../unsupported-media-type` (415),
`.../body-over-1mib` (`invalid-request`), `.../non-post-method` (405 empty body),
`.../legacy-envelope-no-payment-tag` (`invalid-event`),
`.../legacy-envelope-other-kind` (`payment-error-invalid-token`),
`.../valid-token-degraded-not-consumed` (`service-unavailable`).

Two extra codes exist that only `main.go` emits around the body: `invalid-request`
(oversized body, `main.go:1206`) and `invalid-event` (kind-21000 without a `payment`
tag, `main.go:1235`).

### 5.4 The crash-safety rules a client must respect

The module implements these on its side; a client that violates them can still lose money.

1. **Never resend a note whose outcome was ambiguous.** `payment-outcome-unknown` and
   `payment-received-grant-pending` mean the mint *may* have taken it. Resending
   produces `payment-error-token-spent` and the value is gone
   (`merchant.go:1656-1691`, `:1733-1744`; repository rule in `AGENTS.md`).
2. **Persist intent before POSTing.** The module does this on its side
   (`beginReceiveIntent`, `merchant.go:1584-1629`; journal `merchant/journal_durability.go`).
   A client that has no durable record of which token it sent cannot tell a
   `payment-outcome-unknown` from a network drop on its own side.
3. **`payment-duplicate-inflight` is a local refusal — no Receive was sent**
   (`merchant.go:1574-1575`). Safe to wait and retry *the same* note after the window.
4. **Reconcile with NUT-07 before regenerating anything.** On any ambiguity, ask the
   mint's `/v1/checkstate` what actually happened rather than minting a replacement.
5. **The mint's swap fee eats the first sats.** `amount <= fee` is refused up front
   (`merchant.go:1522-1528`); the allotment is computed from the **post-swap** amount
   (`merchant.go:1779`, `amountAfterSwap`), not the token face value. A client
   estimating "how many steps will N sats buy" must subtract the fee.

---

## 6. Post-purchase observability

| Route | Request | Response | Cite |
|---|---|---|---|
| `GET /whoami` | — | `text/plain; charset=utf-8`, `mac=<canonical MAC>` | `main.go:1112-1128`; `HTTP-02.md:5-22` |
| `GET /usage` | — | `text/plain`, `<used>/<allotment>` or `-1/-1` | `main.go:1289-1314`; `HTTP-03.md:5-14` |
| `GET /balance` | — | JSON `{status, session_active, metric, usage, allotment, remaining, start_time, mac}`; `remaining = max(allotment-usage,0)` | `main.go:1610-1688`; `corpus/http/http03-balance.json` |
| `GET /session-state` | — | JSON `{status, mac, state}`; `state ∈ none\|active\|expired` | `main.go:1391-1428`; constants `merchant/merchant.go:74-80` |

Notes that bite:

- `/usage` returns **`-1/-1` for both "never bought" and "just ran out"** — the reason
  `/session-state` exists (`main.go:1383-1389`). A client that shows "no session" from
  `/usage` alone will tell an exhausted customer they have never paid.
- `/balance` answers `200 {status:1, session_active:false}` rather than an error when the
  client cannot be resolved (`main.go:1624-1631`) — so `session_active:false` is also the
  unidentifiable-client answer. Cross-check `mac`/`X-TollGate-Client-MAC`.
- `/usage` and `/session-state` are behind `requireStarted`; `/whoami` is deliberately not
  (`main.go:1895-1904`).
- All four are identity-scoped from the socket, same rule as the purchase.

---

## 7. Divergences between the spec repo and this module

Recorded so a client does not "fix" the module's behaviour by trusting the doc.

| # | Spec says | Module does | Where |
|---|---|---|---|
| 1 | invalid payment "MAY use 402 or 400" | always **400**, never 402; `415` for media type, `405` for method, `503` for starting | `main.go:1172-1178`, `:1259`, `startup_gate.go:145` |
| 2 | notice `p` tag is "customer pubkey" | carries the **MAC** on the money route | `TIP-01.md:68` vs `merchant.go:2283-2285` |
| 3 | session event has optional `p` | never emitted on the raw-token flow | `TIP-01.md:45` vs `merchant.go:2113-2118` |
| 4 | `price_per_step[3]` is "unit or currency" | free-form string, never validated against the mint | `TIP-02.md:27` vs `config_manager_config.go:135` |
| 5 | TIP-01 defines an advert-level `min_steps` | not emitted at all; only the per-mint `[5]` field | `TIP-01.md:21` vs `merchant.go:1991-2009` |
| 6 | `GET /usage` has no state distinction | `-1/-1` conflates never/expired; `/session-state` is the disambiguator (spec gap ticketed as tollgate#24) | `corpus/http/session-state.json` `spec_status` |
| 7 | WIFI-01 (beacon advertisement) is "RESERVED" | implemented as an 802.11 vendor IE, OUI `21:21:21` | `WIFI-01.md:5` vs `vendor_element_manager.go:15-34` |
| 8 | `/balance`, `/ln-invoice`, `/session-state` are not in the protocol repo | served by this module; pinned by the corpus instead | `corpus/http/http03-*.json`, `session-state.json` |

---

## 8. Minimal client algorithm

```
1  probe:  GET http://<gw>:2121/            (timeout ≤ 2 s, expect application/json)
2  parse:  kind==10021, verify sig, extract metric/step_size/price_per_step[]
3  filter: for each price_per_step:
             asset == "cashu"
             AND unit is sat (verify against <mint>/v1/keysets — §2.3)
             AND mint reachable
           → candidate plans, cost_per_step = price / step_size
4  choose: policy (price cap, min_steps, reliability history) → one plan
5  fund:   if wallet has < needed sats on that mint:
             POST /ln-invoice {amount, mint_url} → pay bolt11 → poll GET until
             state in {PAID,ISSUED} AND access_granted   (this path needs no token)
           else:
             send = mint.swap(needed sats on <mint>) → serialized cashuB
6  buy:    persist {mint, amount, token_id, attempt_at}
           POST /  Content-Type: text/plain  body=<token>
7  branch: 200 → parse kind:1022, confirm device-identifier == own MAC, done
           400 code in {outcome-unknown, received-grant-pending} → DO NOT RESEND;
               poll GET /balance + /session-state until active or expired
           400 code in {token-spent, keyset-expired} → value lost, surface it
           400 code in {mint-rate-limited, mint-unreachable, service-unavailable}
               → backoff, resend the SAME token only if the mint never answered
                 (check NUT-07 first)
           415/405/413 → a client bug, never retry
8  monitor: poll GET /session-state (+ /balance) every N s; on `expired`, go to 4
```

Step 5's two branches are genuinely different products: the Lightning lane never gives
the client a token and the token lane never gives the client an invoice. A client that
implements only one is half a client.

---

## 9. Open questions a build must resolve (not answerable from source)

| # | Question | Why it blocks |
|---|---|---|
| 1 | Is there any v1 discovery that works *outside* the LAN (relay-published 10021)? | the module only serves the advert on `:2121`; `NOSTR-01.md` reserves `:4242` for a relay but the module runs no relay |
| 2 | What should a client do when `device-identifier` ≠ its own MAC after a 200? | the module grants to the socket; a mismatch means a proxy/NAT path, and the value is already spent |
| 3 | Is `price_unit` ever intended to be non-sat? | the whole wallet is sat-only, so today it is a misconfiguration trap, not a feature |
| 4 | Should the client trust the advert's `pubkey` across purchases (pinning)? | nothing in the corpus defines a rotation story |

---

*References: `src/main.go`, `src/merchant/merchant.go`, `src/merchant/lightning.go`,
`src/merchant/merchant_degraded.go`, `src/tollgate_protocol/validator.go`,
`src/tollwallet/*`, `src/config_manager/config_manager_config.go`,
`src/wireless_gateway_manager/{brands,vendor_element_manager}.go`,
`docs/architecture/{discovery-signaling,session-ticket,nodogsplash-port-2121}-*.md`;
`~/repos/tollgate/{HTTP-01,HTTP-02,HTTP-03,TIP-01,TIP-02,NOSTR-01,WIFI-01}.md` and
`~/repos/tollgate/corpus/**`.*
