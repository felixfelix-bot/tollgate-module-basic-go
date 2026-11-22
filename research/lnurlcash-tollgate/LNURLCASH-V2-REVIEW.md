# LNURLcash LUD-25/26 rev-2 (`cs1` with `u32 t`) — re-review and TollGate fit

**Spec reviewed:** lnurl/luds#301, branch `lnurlcash`, head
`fd80cdda1e51a673408eeea51410bd7074735012` (2026-11-16).
**Previous pass reviewed:** `2f17578` (2026-09-30) — the revision baked into
PR #944's `poc/vectors/`.
**Measured:** 2026-11-22 on `x280`, Bitcoin Core v31.1.0 `regtest`.

Every claim below is labelled **MEASURED** or **REASONED**. Nothing is
upgraded by assertion.

---

## 0. The premise, confirmed

LUD-25 gained timestamps. `cs1` moved from a 65-byte to a **69-byte** payload,
and the signed message gained **two** fields, not one:

| | `2f17578` (reviewed) | `fd80cdd` (now) |
|---|---|---|
| message | `LNURLcash:` ‖ amount_msat ‖ `:` ‖ hex(Q) | `LNURLcash:` ‖ **domain** ‖ `:` ‖ amount_msat ‖ `:` ‖ hex(Q) ‖ `:` ‖ **t** |
| payload | `r ‖ s ‖ recid` — 65 B | `r ‖ s ‖ recid ‖ u32 t` — **69 B** |
| domain binding | none | in the signed message, canonicalised (A-label, no port/userinfo/trailing dot) |
| certification | SHOULD | **MUST**; `WALLET` MUST refuse a `withdrawRequest` without `mintPubkey` |

`t` is the Unix time of signing, seconds, big-endian in the payload and minimal
base-10 in the message.

**MEASURED.** I reconstructed both official certificates byte-for-byte —
message, digest, 69-byte payload, and the bech32m encoding. Flipping `t` by one
second changes the recovered key, so **`t` is authenticated**: it cannot be
edited without breaking verification.

---

## 1. Conformance re-run

| suite | target | assertions | result |
|---|---|---|---|
| `poc/tests/test_vectors.py` | the **old** `2f17578` vectors | 141 | **141 PASS / 0 FAIL** |
| `poc-v2/tests/test_vectors_v2.py` | the **new** `fd80cdd` vectors | 27 | **27 PASS / 0 FAIL** |

**MEASURED.** The old codec is unchanged and still green against what #944
pins. The new codec is green against what the branch ships now. Neither
result says anything about the other.

Two things fall out of the delta that are worth naming:

- **The vector's `t` is `1800000000`** (2027-01-15) — in the future relative to
  this review. Any conformance suite that asserts "`SERVICE` MUST NOT sign a `t`
  ahead of its own clock" fails against the published vectors.
- **No vector varies `domain` or `t` as a negative case.** Conformance therefore
  cannot detect a verifier that ignores `t` entirely.

---

## 2. Bitcoin Core consensus cross-check — the claim this pass upgrades

PR #944's own `KERNEL-CHECK-FINDINGS.md` says the taproot claims are **REASONED,
not MEASURED**, and it retracts an earlier claim that was not supported by its
evidence. This pass closes that gap for the v2 spend shapes.

Method: mine a **real** P2TR output paying the note's `Q`, then submit the spend
to `testmempoolaccept`. Core recomputes the sighash from the witness handed to
it, so a wrong sighash surfaces as a refusal — which is the signal we want.

```
CASE 1  bearer note — cw1, leaf = OP_SHA256 <h> OP_EQUAL
  funded       = txid 119c1ea6… vout 0, 100000 sat, spk = 5120 8c87b9a4…
  correct preimage -> allowed=True
  wrong preimage   -> allowed=False  mempool-script-verify-flag-failed
                      (Script evaluated without error but finished with a
                       false/empty top stack element)

CASE 2  timelock note — <T> CLTV DROP <pk> CHECKSIG
  T' = 1600000000 (past), so finality cannot mask CLTV
  claim nLockTime = T'       -> allowed=True
  claim nLockTime = T' - 1   -> allowed=False
                                mempool-script-verify-flag-failed
                                (Locktime requirement not satisfied)
```

**MEASURED — both legs CONFIRMED.** Bitcoin Core's own interpreter accepts the
bearer spend with the real preimage, refuses it with a wrong one, and refuses a
not-yet-due CLTV claim naming the **locktime rule**, not a service policy.

That last detail is the whole argument of §4: a chain refusing a timelock is
trustless; a `SERVICE` refusing one is not.

Four bugs had to be fixed to get these rulings, and each one is a
**false-negative trap** a naive harness falls into — recorded here because they
are the reason the previous pass stopped short:

1. A bare `OP_TRUE` output makes Core reject `scriptpubkey` **before** the input
   script is evaluated. Looks like a finding; is a harness defect.
2. `sendtoaddress` to a raw-tr address re-addresses it — match the exact
   scriptPubKey, not "the first taproot output".
3. `getrawtransaction` needs `-txindex`; `getblock` verbosity 2 is the honest path.
4. **A script-path signature must commit the tapleaf** (`ext_flag=1`,
   `tapleaf_hash`, `key_version`, `codesep_pos`). Omitting them yields a
   key-path-shaped digest and Core says `Invalid Schnorr signature`.

Boundary of this claim: `testmempoolaccept` proves Core agrees with the spend
shapes. It does **not** prove our pure-Python sighash is right for arbitrary
inputs; that is what the vector suite is for.

---

## 3. What the timestamp actually buys

### 3.1 It measures attestation age, not possession age

`t` is set by `SERVICE` at signing time. It cannot distinguish *"I received this
a moment ago"* from *"I have held it a month and asked for a fresh certificate
before handing it to you"* — because the mint knows neither fact.

### 3.2 It does not bound the replay window

**MEASURED:** certificates are **free**. The same unspent `Q` yields a valid,
distinct certificate at any `t` from any read-only GET, with **no burn and no
state change**. The payload is exactly `amount, r, s, recid, t` — **no
burned/outstanding bit** (a Tor reader cannot learn consumption from it, ever).

So for a previous holder who still knows the spend:

- pre-rotation, they can always obtain a certificate one second old. Any
  recipient age policy `P > 0` is satisfied. `P` does no work there.
- post-rotation, `P` bounds the residue to `T_rot + P`.
- if the holder never rotates, the window is **unbounded**.

**The mitigation is the rotation. `t` only trims the tail after a burn.**
LUD-25's own remedy — *"a new holder SHOULD rotate as soon as it is online"* —
is the security mechanism, and `t` does not replace it.

### 3.3 `domain` is the real fix, not `t`

**REASONED, from the spec text.** A v1 certificate verifies at *any* `SERVICE`
that shares the certificate key. A v2 certificate recovers a different key at
`gate.other` and fails. That closes cross-domain certificate replay — a genuine,
independent improvement, and the more valuable half of the change.

Caveat the PR should hear: the sentence *"so a signature can never be replayed
at another `SERVICE`"* overreaches in the same document that says *"a leaf that
checks none, such as a bearer note's, is bound to no `domain`"*. For **bearer
notes** the spend stays domain-portable; only the certificate is bound.

### 3.4 It is a silent hard break

v1 demands 65 bytes, v2 demands 69, both use the same `cs<amount>` HRP with **no
version tag, no dual-accept clause, no flag-day text** (grep of `25.md`/`26.md`
for version/legacy/compat/flag/deprecat: nothing). A deployed v1 certificate
becomes an unverifiable **signature failure** — value loss on a bearer
instrument, with no diagnostic that distinguishes it from fraud.

---

## 4. What this means for TollGate

TollGate's shipped constants (`src/config_manager/config_manager_config.go`,
`validator_test.go`), **verified from source**: `StepSize` 22020096 bytes,
`Metric` `"bytes"`, `PricePerStep` 1 sat ⇒ **1 sat ≈ 21 MiB**. A `1 Mbit/s`
floor therefore buys ~3 minutes per sat.

*(An earlier internal note read this as milliseconds and concluded 6.12 hours.
The bytes reading is the shipped default. Use 21 MiB.)*

### The blocker moved

Last pass, a one-way channel died on **cost**: 716 sats setup+close against a
1-sat payment is 71,600% overhead. LNURLcash has **zero chain cost**, so cost is
no longer the argument. **Consumption authority is.**

A bearer instrument transfers value by transferring the thing. Here the thing is
a claim on a `SERVICE`'s database, and consumption is still adjudicated online.
`t` does not change who adjudicates — it only dates the claim.

### Continuous metering has no custody-free shape at shipped granularity

There is no draw-down. Split is `n→2` with `value_out = value_in + (#in−#out)·base_fee`.
Metering one hour at 10 Mbit/s needs ~204 one-sat notes, i.e. **~203 splits,
~203 sats of fee on 204 sats of access — ~100% overhead.** The only custody-free
model (one note per step) needs `price_per_step` ≈ **64×** the shipped default.
Below that you are back to the gate holding the note — Cashu's swap, with more
parts.

### Loss is a full chargeback, not a percentage

Per note the loss is `V` regardless of the age policy `N`; per offline hour it
telescopes to the hourly revenue, independent of `V` and `N`. At shipped pricing
that is trivial money (~204 sats/h at 10 Mbit/s) — but it scales **1:1 with any
price increase**, which is the real exposure.

### Two offline gates

`t` does not help. The signed message carries no recipient and no nonce, and
each gate's verdict is a pure function of `(spend, cert, local policy)`. Two
offline gates both accept → `k·V`. The only mitigation is that both point at the
same mint, so the first rotation burns `Q` for the other — a property of the
shared mint, **not of `t`**.

### Verdict

- **As TollGate's metered-session bearer instrument: no.**
- **As a bounded offline credential layered on Cashu: yes-with-conditions.**

The usable shape is deferral with an age policy: accept offline, open the valve,
record `(Q, t, amount)`, rotate at next connectivity with a bounded staleness
window. Strictly better than accepting an instrument of *unknown* age — but the
window is a parameter **we** choose, not a property the spec grants.

---

## 5. Spec asks, in priority order

1. **A signed, monotonically advancing per-domain spent-set root**, with `cs1`
   carrying the epoch it was signed against and a verifier required to confirm
   that root (short TTL) before accepting. This is the only change that converts
   *"outstanding at `t`"* into *"not spent as of a stated state"* — and the only
   one that closes cross-gate double-spend instead of documenting it.
2. **Define the age policy.** The spec's entire text on the security parameter
   is *"weighs the age of `t` against its own policy"*. No max age, no future-`t`
   tolerance, no clock-skew allowance, no required time source — on a device that
   is offline *by definition*. Two conforming implementations with policies of
   one hour and one century are equally compliant. Also: `u32` has no lower bound
   (`t = 0` is a well-formed certificate for a note outstanding in 1970).
3. **A version discriminator, or `MUST accept both` during transition.** A
   preimage epoch (`"LNURLcash:v2:"`) would have cost nothing; as written,
   algorithm agility is an implicit length check, so any future change that keeps
   69 bytes is undetectable by construction.
4. **Demote the WARNING to a normative clause:** `cs1` MUST NOT be sole payment
   authorisation above a per-counterparty loss cap, and acceptance without epoch
   confirmation MUST be disclosed as unsecured.
5. **Decouple the certificate key from the BOLT-11 node id.** `mintPubkey` SHOULD
   be the node id today, which turns ordinary `signmessage` into a forgery oracle
   over an attacker-chosen body, and makes key rotation an incident (channels,
   gossip, allowlists) instead of a minute. A dedicated certificate key costs
   nothing.
6. **Add the missing negative vectors:** a v1 65-byte cert (must fail), a cert at
   another domain (must fail), a future `t`, a cert for a burned note, a
   timelocked-note cert.
7. **LUD-26 `unregister` has the same unfixed defect `t` was invented for:** the
   proof binds domain + username only — no `cx1`, no nonce, no `t`. Anyone who
   ever sees it holds a permanent capability to delete that Lightning Address.
8. **Clarify `t`'s semantics — credit time or poll time?** *"MAY answer a retry
   with a fresh one"* permits both, and the vectors cannot distinguish them. This
   decides whether `t` means anything at all.

Point 8 is the one I would press hardest with the authors, because it is
answerable in one sentence and it is the difference between a date and a claim.

---

## 6. Evidence

| artifact | path |
|---|---|
| v2 conformance (27 assertions) | `poc-v2/tests/test_vectors_v2.py` |
| v1 conformance (141 assertions) | `poc/tests/test_vectors.py` |
| rev-2 delta harness (30 assertions) | `rev2_check.py` |
| Core consensus, both legs | `consensus_v2.py` → `out/CONSENSUS-V2.txt` |
| v2 vectors as fetched | `poc/vectors/{25,26}.md`, `{25,26}-vectors.json` |

Pinned head: `fd80cdda1e51a673408eeea51410bd7074735012`.
Core: `/Satoshi:31.1.0/`, regtest, own datadir + port 18444 (the shared 18443
node belonged to another lane and was not touched or restarted).
