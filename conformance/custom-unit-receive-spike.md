# SPIKE — custom-unit (`eur-cent`) receive through the merchant wallet

**Verdict: NEEDS-3-CHANGES.** The merchant wallet **cannot** complete a receive of a
non-sat unit today, and the failure is localized and cheap to fix — but it is not a
configuration problem, so no amount of `price_unit` config makes it work.

What was measured, and where it stops:

| Layer | `sat` (control) | `eur-cent` (spike) | Verdict |
|---|---|---|---|
| Local mint issues the unit | ✅ | ✅ | works |
| Token decode into the module | ✅ | ✅ | works — unit is silently dropped, not rejected |
| Accepted-mint check | ✅ | ✅ | works |
| Mint probe / keyset listing | ✅ | ✅ | works — 2 keysets returned |
| **Wallet backend holds a non-sat unit** | ✅ | ❌ | **fails here** — gonuts pins `cashu.Sat` at construction |
| Fee precheck (`SwapFeeSats`) | not exercised (fee 0) | not exercised (fee 0) | **unverified** |
| Receive / swap | ✅ | ❌ `Input unit must match output` | fails |
| `calculateAllotment` | ✅ 6000000 ms | not reached | **unverified** (division runs on raw amount, unit-blind) |
| Session grant | ✅ HTTP 200, kind 1022 | ❌ HTTP 400, kind 21023 | fails |

The one-line answer to the card's question: **the in-process gonuts wallet cannot hold a
non-sat unit, but the CDK engine can — verified end to end, offline, at both ends.**

---

## 1. The measured failure (reproducible)

Same mint, same config, same harness, same MAC, single variable = `price_unit` +
token unit. Mint is `cdk-mintd 0.18.2` on `127.0.0.1:3368`, configured with a
`fakewallet` backend for **both** units, so it serves one sat keyset and one
`eur-cent` keyset at one URL:

```
$ curl -s http://127.0.0.1:3368/v1/keysets
{"keysets":[
 {"id":"015301ebbd309721e8d14f4808a006f3ffba60ab100932093b7f3dbe5bde4f8470",
  "unit":"sat","active":true,"input_fee_ppk":0},
 {"id":"013ef3f25202233b9d8aa3545589f314ab6419fc5af3dc9b67063247b2ec189a51",
  "unit":"eur-cent","active":true,"input_fee_ppk":0}]}
```

Using a dual-unit mint deliberately isolates the unit question from the
"unknown mint" question: the `eur-cent` token's mint URL **is** the accepted mint.

Mint config (`mint-dual.toml`, both backends, no fees, no delay — no real money):

```toml
[info]
url = "http://127.0.0.1:3368"
listen_host = "127.0.0.1"
listen_port = 3368
mnemonic = "file:.../seed-dual.txt"
[database]
engine = "sqlite"
[[payment_backend]]
backend = "fakewallet"
unit = "sat"
[[payment_backend]]
backend = "fakewallet"
unit = "eur-cent"
[fake_wallet]
fee_percent = 0.0
reserve_fee_min = 0
min_delay_time = 0
max_delay_time = 0
supported_units = ["sat", "eur-cent"]
```

Module: `tollgate-wrt`, host mode, `TOLLGATE_TEST_CONFIG_DIR=<dir>`, fake `ndsctl`
on `PATH` (the `tests/cloud-lab/` harness shape), `accepted_mints[0].url =
http://127.0.0.1:3368`, `price_per_step = 1`, `step_size = 60000`, `metric =
milliseconds`, one client MAC seeded into `/tmp/dhcp.leases`.

### 1a. Control: `price_unit: "sat"` + a 100-sat token → session granted

```
2026/10/27 01:45:58 mint probe: url=http://127.0.0.1:3368/v1/keysets status=200 keysets=2 elapsed=2.800215ms ok=true
2026/10/27 01:45:58 Accepted Mints: [{http://127.0.0.1:3368 0 0 999999 999999 1 sat 1}]
2026/10/27 01:45:58 Wallet Balance: 0
```

POST of a signed kind-21000 event carrying a 100-sat token:

```
--- POST http://127.0.0.1:2121 ---
{"kind":1022,...,"tags":[["device-identifier","mac","02:00:00:00:00:20"],
 ["allotment","6000000"],["metric","milliseconds"],["start-time","1793061994"]],...}
HTTP 200
```

`/tmp/ndsctl.log`: `2026-10-27T00:46:34Z AUTH 02:00:00:00:00:20` — the gate opened.
Full money path: decode → accepted-mint → swap → allotment → session → gate. Green.

### 1b. Spike: `price_unit: "eur-cent"` + a 100-`eur-cent` token → swap rejected

Identical run, only the mint entry and the token differ:

```
2026/10/27 01:47:34 mint probe: url=http://127.0.0.1:3368/v1/keysets status=200 keysets=2 elapsed=1.510457ms ok=true
2026/10/27 01:47:34 Accepted Mints: [{http://127.0.0.1:3368 0 0 999999 999999 1 eur-cent 1}]
2026/10/27 01:47:34 Wallet Balance: 0
...
2026/10/27 01:48:06 PurchaseSession: calling Receive for mint=http://127.0.0.1:3368 token_amount=100 mac=02:00:00:00:00:20
2026/10/27 01:48:06 PurchaseSession: Receive completed, amount=0, err=could not swap proofs: Input unit must match output
2026/10/27 01:48:06 MarkUnreachable: reachable set changed (mint=http://127.0.0.1:3368), firing callback
WARN[2026-10-27T01:48:06+01:00] All mints unreachable — downgrading to degraded mode  module=main
```

HTTP response:

```
{"kind":21023,"tags":[["level","error"],["code","payment-processing-failed"],
 ["p","02:00:00:00:00:20"]],
 "content":"Payment processing failed: could not swap proofs: Input unit must match output",...}
HTTP 400
```

Mint side, same event (`mint-dual.log`, line 67 — `00:48:06Z` = `01:48:06` CET):

```
00:48:06.184792Z ERROR post_swap{inputs_count=18}: cdk_axum::router_handlers:
  Could not process swap request: Input unit must match output
```

18 inputs matches the token's 18 proofs exactly, so this is the module's POST, not a
client-side artefact. **The mint did not reject the unit; it rejected the
*mismatch*.** The wallet sent `eur-cent` inputs with `sat` outputs. That is the whole
bug in one line.

**The failed swap cost nothing — measured, not assumed.** The same token string,
submitted afterwards to an independent CDK wallet, still redeemed:

```
$ cdk-cli -w . -u eur-cent receive --allow-untrusted "$(cat token-eur100.clean)"
Received: 100
```

So the mint rejected the swap atomically and left the proofs unspent. The fund-safety
concern here is **ordering**, not loss: a check that can be done locally is instead
delegated to a remote party, and the money path's correctness depends on that remote
party's validation being atomic.

### 1c. Where the mismatch is created

`gonuts-tollgate@v0.13.0/wallet/wallet.go:126` hard-pins the unit at construction:

```go
wallet := &Wallet{db: db, unit: cashu.Sat, masterKey: masterKey, privateKey: privateKey}
```

`w.unit` then selects the **output** keyset for every swap
(`wallet.go:823` `createSwapRequest` → `mint.activeKeyset.Id` via
`getActiveKeyset(tokenMint)`, `wallet.go:846`), while the **inputs** come from the
token as delivered. No code path compares the two before the POST — that comparison
happens at the mint (`cdk-common`, `Input unit must match output`). So a non-sat
token is never refused locally; it is forwarded and refused remotely, after the
note's proofs have been offered to the mint.

This is the fund-safety shape the repo cares about: a *validation that could be done
locally* is not done, and the reject arrives from the network. No funds moved in the
spike (fee 0, mint rejected the swap atomically, proofs remained unspent — verified
by re-spending them, §4), but the ordering is wrong on principle.

---

## 2. What already works — the unit is decoded, then dropped

The decode layer is unit-agnostic *and* discards the unit. Probe against the real
token (`cdk-cli decode-token`, plus a tiny Go program calling
`tollwallet.DecodeToken`):

```
$ cdk-cli decode-token "$(cat token-eur100b.txt)"
{ "m": "http://127.0.0.1:3368", "u": "eur-cent", "t": [ { "i": h'013ef3f25202233b', "p": [...] } ] }

$ ./probe token-eur100b.txt
DecodeToken(eur-cent) => OK mint="http://127.0.0.1:3368" amount=100 serialized_len=5358
Token interface has no Unit() method: the unit is not exposed to callers.
```

The token genuinely carries `u: "eur-cent"`; `tollwallet.Token`
(`src/tollwallet/port.go:26`) exposes `Mint()`, `Amount()`, `Serialize()`,
`Secrets()`, `Close()` — **no** `Unit()`, so the unit is unrecoverable downstream
without re-parsing. gonuts' own `cashu.Token` interface
(`cashu/cashu.go:168`) is equally unit-blind, though `TokenV4.Unit` and
`TokenV3.Unit` exist as struct fields (`cashu.go:278`, `cashu.go:190`).

Also note `cashu.NewTokenV4` (`cashu.go:337`) hard-fails on any unit but `Sat`:

```go
if unit != Sat { return TokenV4{}, ErrInvalidUnit }
```

so the fork cannot even *serialize* a non-sat token today — that is why
`src/tollwallet/tollwallet.go:369,418,445` (all `cashu.Sat`) are not merely
cosmetic: `Send`/`Drain`/`SendWithOverpayment` can only ever emit sat tokens.

Config side: `price_unit` is parsed and advertised but never *enforced* anywhere.
Every non-test use is either a literal default (`"sat"`, 8 sites), the `sats`→`sat`
migration (`config_manager_config.go:627-629`), the schema row
(`config_schema.go:78`), or the advertisement tag
(`merchant.go:2006`). Nothing validates the token's unit against
`accepted_mints[].price_unit`, which is why the config accepted `eur-cent` and then
went on to build a sat wallet.

---

## 3. Can CDK hold a non-sat unit? Yes — measured, both directions

This is the part that decides whether the plan is viable at all, so it was executed
rather than read. `cdk-cli 0.18.1` (the sidecar-shaped binary) has a **global unit
flag** and a per-wallet unit. Full cycle on a fresh work dir:

```
$ cdk-cli -w . -u eur-cent receive --allow-untrusted "$(cat token-eur100.txt)"
Received: 100

$ cdk-cli -w . -u eur-cent balance
0: http://127.0.0.1:3368 100 eur-cent
Total balance across all wallets: 100 eur-cent

$ sqlite3 cdk-cli.sqlite "select unit,state,sum(amount) from proof group by unit,state;"
eur-cent|UNSPENT|100

$ cdk-cli -w . -u eur-cent send -a 25 --mint-url http://127.0.0.1:3368
cashuBo2FtdWh0dHA6Ly8xMjcuMC4wLjE6MzM2OGF1aGV1ci1jZW50YXSBomFpSAE-8_JSAiM7...

$ cdk-cli decode-token "<that token>"     # outgoing token
"m": "http://127.0.0.1:3368", "u": "eur-cent"

$ cdk-cli -w . -u eur-cent balance
0: http://127.0.0.1:3368 50 eur-cent
```

So in the CDK engine: **receive, persist (unit-tagged in sqlite), balance, swap, and
send all work for `eur-cent`**, and the emitted token carries the right unit. That is
strictly more than the in-process gonuts backend can do.

### 3a. The unit must be named explicitly — it is NOT inferred

Same receive with no `-u` flag (wallet defaults to `sat`):

```
$ cdk-cli -w . receive --allow-untrusted "$(cat token-eur100.txt)"
Error: Unit unsupported
```

and the module's own in-process path shows the same shape the other way round — an
`eur-cent`-only mint makes the *wallet construction* fail before any payment:

```
2026/10/27 00:52:49 mint probe: url=http://127.0.0.1:3348/v1/keysets status=200 keysets=1 ... ok=true
2026/10/27 00:52:49 WARNING: Wallet initialization failed
  (failed to create wallet: error adding new mint: could not find an active keyset for the unit)
  — starting in degraded mode
```

`GetMintActiveKeyset(mintURL, cashu.Sat)` (`gonuts_wallet.go:104`) simply does not
find the `eur-cent` keyset, and `AddMint` (`wallet.go:181`) surfaces
`could not find an active keyset for the unit`. **Unit is a construction parameter,
not a per-token property** — in both engines. That is the design fact this spike
turns on.

---

## 4. The sidecar contract is unit-blind (confirmed) and its daemon does not exist

`src/tollwallet/sidecar.go` drops the unit in exactly the three places the card
predicted, and the token type it builds cannot carry one:

```
216: type tokenJSON struct {
217:   Token  string `json:"token"`
218:   Mint   string `json:"mint"`
219:   Amount uint64 `json:"amount"`      // no unit field
220: }
251: func (s *SidecarWallet) Receive(token Token) (uint64, error) {
257:   s.call("receive", map[string]string{"token": ser}, &amount)   // token only
338:   s.call("request_mint_quote", map[string]any{"amount": amount, "mint_url": mintUrl}, &wire)
```

Important correction to the card's framing: **there is no sidecar daemon source to
point at.** The repository ships the *client* (`sidecar.go`, merged in #395, no build
tag) and a manifest (`src/tollwallet/manifests/cdk.json`), but no server:

- `grep -rln "get_all_mint_balances" ~ --include=*.rs` → **no matches**;
- `~/repos/cdk-go-musl` contains only the uniffi/cgo bindings, no daemon;
- `cdk-walletd` appears only as a *plan* (`docs/architecture/wallet-integration-decision.md:26,63,102`,
  `changelog.d/wallet-policy-cdk-default.changed.md`) and as an init-script *sketch*
  (`research/wallet-migration/experiments/cdk-sidecar/init/cdk-walletd.init` on
  `fork/research/wallet-migration`), whose `PROG=/usr/bin/cdk-walletd` is the
  off-the-shelf `cdk-cli` binary;
- upstream `cashubtc/cdk` has no AF_UNIX server (only `cdk-cln` uses a listener, for
  CLN).

So "where the unit would have to be passed in the daemon" has this answer: **in the
daemon that has not been written, at wallet construction — and the daemon's chosen
unit must be handed to `get_or_create_wallet`, exactly as `cdk-cli` does it today:**

```
crates/cdk-cli/src/main.rs:65    unit: Option<String>,          # global -u flag
crates/cdk-cli/src/main.rs:227   let currency_unit = match args.unit { ... CurrencyUnit::from_str(&unit)? }
crates/cdk-cli/src/main.rs:234   let default_unit = currency_unit.clone().unwrap_or(CurrencyUnit::Sat);
crates/cdk-cli/src/sub_commands/receive.rs:45   pub async fn receive(..., unit: &CurrencyUnit)
crates/cdk-cli/src/sub_commands/receive.rs:170  let wallet = get_or_create_wallet(wallet_repository, &mint_url, unit).await?;
crates/cdk-cli/src/utils.rs:43-53               get_or_create_wallet(repo, mint_url, unit)
```

The Rust engine already models unit as a first-class wallet key
(`cdk-0.18.2/src/wallet/mod.rs:136` "A [`Wallet`] is for a single mint and single
unit", `:151` `pub unit: CurrencyUnit`, builder `:128` `pub fn unit(...)`), so the
daemon work is contract plumbing, not engine work.

The in-process CDK adapter pins sat at one line — the same bug, different backend:

```
src/tollwallet/cdk_wallet.go:404   cdk_ffi.NewWallet(mintUrl, cdk_ffi.CurrencyUnitSat{}, ...)
```

---

## 5. Patch list (NEEDS-3-CHANGES)

Three changes, in dependency order. **None were implemented — this card is
investigation only.**

**P1 — `tollwallet`: make the unit observable and carried.**
- `src/tollwallet/port.go:26` — add `Unit() string` to the `Token` interface.
- `src/tollwallet/gonuts_wallet.go:42-59` — implement it: `TokenV4.Unit` /
  `TokenV3.Unit` are already there (`cashu/cashu.go:278,190`); V4 -> `u`, V3 -> `unit`.
- `src/tollwallet/sidecar.go:216-220` — add `Unit string \`json:"unit"\`` to
  `tokenJSON` and populate `sidecarToken` from it; `sidecar.go:257` then stays
  correct as-is (the token already carries its unit) but the *field* must exist for
  P2's guard and for callers.
- `src/tollwallet/tollwallet.go:369,418,445` — thread the real unit into
  `cashu.NewTokenV4` instead of the literal `cashu.Sat` (requires the gonuts fork
  change below, since `NewTokenV4` rejects non-sat at `cashu/cashu.go:338`).

**P2 — `gonuts-tollgate` (fork first, then bump): make the wallet's unit a
parameter and fail closed locally.**
- `wallet/wallet.go:126` — `unit: cashu.Sat` becomes a `Config` field, honoured at
  `LoadWallet` (`:79`); this is the single line that decides every swap's output
  keyset (`:823,836,846`).
- `wallet/wallet.go:632` (`Receive`) — before building the swap, compare
  `token`'s unit against `w.unit` and return a typed error
  (`ErrUnitMismatch`) **locally**. Today the mismatch is only discovered by the mint
  (`Input unit must match output`, measured §1b), i.e. after the proofs are exposed
  in a swap request. This is the fund-safety fix the card's ordering rule demands.
- `cashu/cashu.go:337-340` — lift the `unit != Sat` rejection in `NewTokenV4`
  (and `NewTokenV3`, `:199`) so non-sat tokens can be serialized.
- `wallet/restore.go:75` — the `keyset.Unit != cashu.Sat.String()` filter must
  compare against `w.unit.String()`, or restore silently skips the wallet's own
  proofs.

**P3 — `merchant`: bind the token's unit to the mint's configured `price_unit`.**
- `src/merchant/merchant.go:1493` (`PurchaseSession`) — after `DecodeToken`
  (`:1507`) and before the swap-fee precheck (`:1522`), reject a token whose
  `Unit()` differs from the matched `MintConfig.PriceUnit` with a
  `payment-error-unit-mismatch` notice. **Must run before `Receive`**, per the
  "validate locally before irreversible operations" rule; today the first unit
  check happens at the mint.
- `src/merchant/merchant.go:2056-2074` (`calculateAllotment`) — the parameter is
  named `amountSats` and divides the raw `uint64` by `price_per_step`; it must take
  the unit (or a pre-validated amount) so a `eur-cent` figure is never silently
  priced as sats. The arithmetic is identical, but the *name and the absence of a
  guard* are how a cross-unit price bug would land.
- `src/merchant/merchant.go:1523-1526` — the below-swap-fee notice hardcodes `"sat"`
  twice in its format string (`"%d sat ... charges a %d sat swap fee"`); with a
  non-sat mint it would print a false unit to the customer.

**Sidecar contract (follows P1/P2, needed only for the router path):** the daemon
must (a) be written at all, (b) take the unit at start-up or per-wallet, and (c) add
`unit` to the `receive` / `send` / `request_mint_quote` request shapes *only if* the
daemon is to serve more than one unit per socket. If one daemon serves one unit (the
CDK model: one wallet per (mint, unit)), the contract needs no `unit` field at all —
the socket's unit is fixed at spawn, and P1's `tokenJSON.Unit` is enough to let the
Go side guard locally. **Recommend the one-unit-per-socket form: it needs zero RPC
schema change.**

---

## 6. Honesty: what was NOT tested

- **Sidecar / `cdk-walletd` end to end: untested, impossible.** No daemon exists to
  run. Everything in §3 was measured with `cdk-cli` directly, which is the *engine*
  the daemon would embed — not the daemon.
- **Fee precheck (`SwapFeeSats`) with a non-sat unit: unverified.** The local mint
  charged `input_fee_ppk = 0`, so the precheck's `fee > 0` branch never fired in
  either run. `gonuts_wallet.go:104,110` pins `cashu.Sat` for the fee keyset lookup,
  so a fee-bearing `eur-cent` keyset would very likely yield "fee unknown" and fall
  through to `Receive` — but that is an inference, not an observation.
- **`calculateAllotment` for `eur-cent`: unverified.** It is only reached after a
  successful `Receive` (`merchant.go:1779`), and `Receive` never succeeded for
  `eur-cent`. The code is unit-blind by construction (§5 P3), so the *risk* is
  reasoned, not measured.
- **Persistence / crash consistency for a non-sat wallet: unverified.** The CDK
  sqlite rows are correctly unit-tagged (§3), but no kill/restart was exercised at a
  transaction boundary — that belongs to the `tests/cloud-lab/` lanes, not this spike.
- **In-process CDK (`-tags cdk_wallet`): untested.** `cdk_ffi.CurrencyUnitSat{}` at
  `cdk_wallet.go:404` makes the same pin, so the expectation is the same failure, but
  it was not run (glibc/cgo build out of scope here).
- **Router / aarch64 musl:** not touched, per the card's constraints. Sidecar build
  size and mipsel remain as recorded on `fork/research/wallet-migration`.

## 7. Reproduce

All artefacts under
`~/.hermes/profiles/worker-tollgate/cache/scratch/unit-spike/` (not committed):

| File | What |
|---|---|
| `mint-dual.toml`, `data-dual/`, `mint-dual.log` | the dual-unit local mint |
| `tg-sat/config.json`, `sat-ctl.log` | control run, `price_unit: sat` |
| `tg-eur/config.json`, `eur-ctl.log` | spike run, `price_unit: eur-cent` |
| `token-sat100.txt`, `token-eur100b.txt` | the two payment tokens |
| `post-fail/` | re-redeem of the module-rejected token (proof: nothing was lost) |
| `cust2/cdk-cli.sqlite` | CDK wallet holding `eur-cent` (unit-tagged proofs) |
| `send-eur25.decoded` | outgoing `eur-cent` token decode |
| `bin/pay.sh`, `bin/ndsctl`, `bin/tollgate-wrt` | the headless payment harness |
| `decode.py`, `probe/` | token decoding probes |

```bash
D=~/.hermes/profiles/worker-tollgate/cache/scratch/unit-spike
cd $D && cdk-mintd -w ./data-dual                     # both units at :3368
TOLLGATE_TEST_CONFIG_DIR=$D/tg-eur PATH=$D/bin:$PATH $D/bin/tollgate-wrt
bash $D/bin/pay.sh $D/token-eur100.clean 02:00:00:00:00:20 http://127.0.0.1:2121
```

Swap `tg-eur` -> `tg-sat` and `token-eur100.clean` -> `token-sat100.clean` for the
control.

## 8. Answer to the card's question

> can the merchant wallet hold a NON-sat unit (eur-cent)?

- **As shipped (in-process gonuts): no.** It builds a sat wallet unconditionally
  (`wallet.go:126`) and the resulting swap is rejected by the mint
  (`Input unit must match output`), measured end to end through the module's own
  money path in host mode.
- **With CDK: yes.** `cdk-cli` receives, stores, sends and re-serializes `eur-cent`
  correctly on a real local mint — the engine is not the obstacle.
- **What it takes:** three changes (P1–P3 above), no engine work, no Rust rebuild
  needed for the *host* path. The router path additionally needs the daemon that
  was always missing — one unit per socket keeps the RPC schema unchanged.

**NEEDS-3-CHANGES.**
