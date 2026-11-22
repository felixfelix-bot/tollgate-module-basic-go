#!/usr/bin/env python3
"""Regtest consensus cross-check for LUD-25 v2 (head fd80cdd) — bearerc + timelock.

WHAT THIS PROVES, AND WHAT IT DOES NOT
--------------------------------------
Proves: Bitcoin Core v31.1.0's SCRIPT INTERPRETER, reached over RPC
(`testmempoolaccept`), accepts or refuses each spend exactly where LUD-25 says it
should — given the canonical spend transaction and its prevout. That is a real
Core ruling and it is the load-bearing claim.

Does NOT prove: that Core agrees with our SIG_HASH math. `testmempoolaccept` is
given the prevout scriptPubKey and amount, so Core recomputes the sighash itself
from the witness we hand it. A wrong sighash therefore shows up as a refusal,
which is precisely the signal we want — but an ACCEPT only means "Core agrees",
not "our reimplementation in pure Python is right for other inputs". The Python
verifier is a separate check (`test_vectors_v2.py` / `rev2_check.py`).

Method: mine a real P2TR output to each note's Q, then submit the canonical spend
to `testmempoolaccept`. The prevout txid is therefore a REAL one, not LUD-25's
synthetic `tagged_hash("LNURLcash/mint", domain)`.

Stdlib only. Talks to a local regtest node on 127.0.0.1:18443.
"""
import json
import os
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
POC2 = os.path.join(HERE, "poc-v2")
OUT = os.path.join(HERE, "out")
os.makedirs(OUT, exist_ok=True)
sys.path.insert(0, POC2)

from lnurlcash import note as v2                      # noqa: E402
from lnurlcash import bech32m, secp                   # noqa: E402
from lnurlcash.note import tapleaf_hash, taproot_output_key  # noqa: E402
from lnurlcash.bctx import (                          # noqa: E402
    Tx, TxIn, TxOut, taproot_sighash, SIGHASH_DEFAULT, compact_size,
)

BTC = os.path.expanduser("~/.local/toolchain/btc/bin")
# Own port + own datadir: the shared 18443 node is another lane's and may
# vanish mid-run (it did). Never restart a node you did not start.
RPC = 18444
WALLET = "rig"
DATADIR = os.path.expanduser("~/.hermes/profiles/manager/cache/scratch/btc-lud25v2")
DOMAIN = "mint.example"
# A STANDARD output for the spend's own output. A bare OP_TRUE (0x51) is
# nonstandard, so Core rejects the transaction with reject-reason
# "scriptpubkey" before it ever evaluates the input script — which is exactly
# the false negative this constant fixes. A fresh P2WPKH-sized push is enough.
SINK_SPK = bytes.fromhex("0014") + b"\x11" * 20
# BIP-341's NUMS internal key H, and the schnorr_pubkey helper name in this POC.
NUMS_X = "50929b74c1a04954b78b4b6035e97a5e078a5a0f28ec96d547bfee9ace803ac0"

LOG = []


def emit(s=""):
    print(s)
    LOG.append(s)


def cli(*args, wallet=True):
    base = [os.path.join(BTC, "bitcoin-cli"), "-regtest", "-rpcport=%d" % RPC,
            "-datadir=" + DATADIR, "-rpcuser=rig", "-rpcpassword=rig"]
    if wallet:
        base.append("-rpcwallet=" + WALLET)
    p = subprocess.run(base + [str(a) for a in args],
                       capture_output=True, text=True, timeout=120)
    if p.returncode != 0:
        raise RuntimeError("cli %s -> %s" % (" ".join(map(str, args)), p.stderr.strip()))
    out = p.stdout.strip()
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return out


def taproot_address(Q: bytes, hrp="bcrt"):
    """bech32m segwit v1 address for a 32-byte output key (BIP-350)."""
    return bech32m.encode(hrp, [1] + bech32m.convertbits(Q, 8, 5))


def sats(x):
    return int(round(float(x) * 100000000))


def fund_p2tr(Q: bytes, amount_btc="0.001"):
    """Send to a real P2TR output; return (txid_bytes_le, vout, spk, amount_sat)."""
    addr = taproot_address(Q)
    txid = cli("sendtoaddress", addr, amount_btc)
    blk_hash = cli("generatetoaddress", 1, cli("getnewaddress", "mine", "bech32"))[0]
    blk = cli("getblock", blk_hash, "2")
    want = bytes([0x51, 0x20]) + Q
    for tx in blk["tx"]:
        if tx["txid"] == txid:
            for n, v in enumerate(tx["vout"]):
                if bytes.fromhex(v["scriptPubKey"]["hex"]) == want:
                    return bytes.fromhex(txid)[::-1], n, want, sats(v["value"])
    raise RuntimeError("no output paying Q in %s (block %s)" % (txid, blk_hash))


def spend_hex(prev_txid_le, vout, locktime, sequence, witness_items, value_sat, spk):
    """Serialise a witness spend of that prevout, SIGHASH_DEFAULT, one output."""
    tx = Tx(version=2,
            ins=[TxIn(prev_txid_le, vout, sequence, b"")],
            outs=[TxOut(value_sat - 1000, SINK_SPK)],  # standard sink; fee 1000 sat
            locktime=locktime)
    return tx, tx.serialize_with_witness([witness_items]).hex()


def testmempoolaccept(rawhex):
    r = cli("testmempoolaccept", json.dumps([rawhex]))
    e = r[0] if isinstance(r, list) else r
    return bool(e.get("allowed")), e.get("reject-reason") or e.get("reject-reason-detail") or ""


# ---------------------------------------------------------------- cases
def case_bearer():
    emit("=" * 78)
    emit("CASE 1  bearer note: cw1 script-path spend (OP_SHA256 <h> OP_EQUAL)")
    emit("=" * 78)
    preimage = bytes.fromhex("11" * 32)
    n = v2.bearer_note(preimage)
    Q = bytes.fromhex(n["Q"])
    lt, seq, script, control, wit = v2.decode_cw1(n["cw1"])
    emit("Q            = %s" % n["Q"])
    emit("leaf         = %s" % n["leaf"])
    emit("locktime=%d sequence=%#x witness=[%d bytes]" % (lt, seq, len(wit[0])))

    txid, vout, spk, val = fund_p2tr(Q)
    emit("funded       = txid %s vout %d value %d sat" % (txid[::-1].hex(), vout, val))
    emit("spk          = %s  (Core calls this witness_v1_taproot)" % spk.hex())
    assert spk.hex() == (bytes([0x51, 0x20]) + Q).hex(), "spk mismatch"

    tx, raw = spend_hex(txid, vout, lt, seq, wit + [script, control], val, spk)
    ok, reason = testmempoolaccept(raw)
    emit("testmempoolaccept(correct preimage) -> allowed=%s %s" % (ok, reason))
    emit("EXPECT: allowed=True")

    # negative: wrong preimage must be refused by Core
    bad_pre = bytes.fromhex("22" * 32)
    _, raw_bad = spend_hex(txid, vout, lt, seq, [bad_pre, script, control], val, spk)
    ok_bad, reason_bad = testmempoolaccept(raw_bad)
    emit("testmempoolaccept(wrong preimage)   -> allowed=%s %s" % (ok_bad, reason_bad))
    emit("EXPECT: allowed=False (OP_EQUAL fails)")
    return (ok, not ok_bad)


def case_timelock():
    emit()
    emit("=" * 78)
    emit("CASE 2  timelock note: <T> CLTV DROP <pk> CHECKSIG")
    emit("=" * 78)
    v = json.load(open(os.path.join(HERE, "poc", "vectors", "25-vectors.json")))["timelock_note"]
    T = v["T"]
    sk = bytes.fromhex(v["sk"])
    leaf = bytes.fromhex(v["leaf"])
    control = bytes.fromhex(v["control_block"])
    emit("T            = %d" % T)
    emit("leaf         = %s" % v["leaf"])

    # recompute Q from the leaf + control so we fund what the script commits to
    from lnurlcash.note import tapleaf_hash, taproot_output_key
    root = tapleaf_hash(leaf, 0xC0)
    Q, parity = taproot_output_key(control[1:33], root)
    emit("Q (recomputed)= %s  parity=%d" % (Q.hex(), parity))

    txid, vout, spk, val = fund_p2tr(Q)
    emit("funded       = txid %s vout %d value %d sat" % (txid[::-1].hex(), vout, val))

    results = []
    for claim, label in ((T, "locktime = T (due)"), (T - 1, "locktime = T-1 (not due)")):
        # sign the canonical-style spend: version 2, one input, one output
        tx = Tx(version=2,
                ins=[TxIn(txid, vout, 0xfffffffe, b"")],
                outs=[TxOut(val - 1000, SINK_SPK)],
                locktime=claim)
        prevouts = [(val, spk)]
        msg = taproot_sighash(tx, 0, prevouts, hash_type=SIGHASH_DEFAULT)
        sig = secp.schnorr_sign(msg, sk, aux_rand=b"\x00" * 32)
        _, raw = spend_hex(txid, vout, claim, 0xfffffffe, [sig, leaf, control], val, spk)
        ok, reason = testmempoolaccept(raw)
        emit("claim nLockTime=%-11d -> allowed=%-5s %s" % (claim, ok, reason))
        results.append((claim, ok))
    emit()
    emit("EXPECT: T due -> allowed=True ; T-1 -> allowed=False (CLTV refuses)")
    emit()
    emit("NOTE ON WHAT THIS IS: the node is at wall-clock time far past any T we")
    emit("can set without parking the chain, so CLTV is evaluated against the")
    emit("node's MEDIAN-TIME-PAST. A T in the future is refused by CLTV itself,")
    emit("which is a CONSENSUS refusal. That is exactly the distinction LUD-25's")
    emit("warning draws: SERVICE may refuse a not-yet-due claim by policy, but a")
    emit("CHAIN refuses it by rule -- and only the chain ruling is trustless.")
    due_ok = dict(results).get(T, False)
    past_ok = dict(results).get(T - 1, False)

    # ---- a leaf whose T is IN THE PAST, so finality does not mask CLTV ----
    # The vector's T (1800000000) is 2027, so every spend is "non-final" before
    # CLTV is even reached. That IS a consensus refusal, but it is not the
    # CLTV ruling. Rebuild the same leaf shape with T in the past.
    emit()
    emit("-- same leaf shape, T in the PAST (so finality cannot mask CLTV) --")
    TP = 1600000000
    SKP = bytes.fromhex("19f49017fb2e30f0d4deb83d14eacd2715abc95dd8ca3d8e063af35a833047de")
    pk = secp.xonly_pubkey(secp.point_mul(int.from_bytes(SKP, "big"), secp.G))
    leaf_p = (bytes([0x04]) + TP.to_bytes(4, "little") + b"\xb1\x75"
              + bytes([0x20]) + pk + b"\xac")
    root_p = tapleaf_hash(leaf_p, 0xC0)
    Qp, par_p = taproot_output_key(bytes.fromhex(NUMS_X), root_p)
    ctrl_p = bytes([0xC0 | par_p]) + bytes.fromhex(NUMS_X)
    emit("T'           = %d (past)  leaf=%s" % (TP, leaf_p.hex()))
    txid2, vout2, spk2, val2 = fund_p2tr(Qp)
    emit("funded       = %s vout %d value %d sat" % (txid2[::-1].hex(), vout2, val2))
    out2 = []
    for claim in (TP, TP - 1):
        tx2 = Tx(version=2, ins=[TxIn(txid2, vout2, 0xfffffffe, b"")],
                 outs=[TxOut(val2 - 1000, SINK_SPK)], locktime=claim)
        # BIP-342 ext_flag=1: a SCRIPT-PATH signature commits the tapleaf hash,
        # the key version and the codeseparator position. Omitting these gives a
        # key-path-shaped digest and Core refuses with "Invalid Schnorr signature"
        # -- which is exactly what happened before this line was fixed.
        msg2 = taproot_sighash(tx2, 0, [(val2, spk2)], hash_type=SIGHASH_DEFAULT,
                               ext_flag=1, tapleaf_hash=tapleaf_hash(leaf_p, 0xC0),
                               key_version=0, codesep_pos=0xFFFFFFFF)
        sig2 = secp.schnorr_sign(msg2, SKP, aux_rand=b"\x00" * 32)
        _, raw2 = spend_hex(txid2, vout2, claim, 0xfffffffe, [sig2, leaf_p, ctrl_p],
                            val2, spk2)
        ok2, reason2 = testmempoolaccept(raw2)
        emit("claim nLockTime=%-11d -> allowed=%-5s %s" % (claim, ok2, reason2))
        out2.append((claim, ok2))
    emit("EXPECT: T' due -> allowed=True ; T'-1 -> allowed=False (CLTV refuses,")
    emit("        'Script evaluated without error but finished with a false top stack')")
    cltv_ok = dict(out2).get(TP, False)
    # Core must REFUSE the not-yet-due claim, i.e. allowed must be False.
    cltv_refused = not dict(out2).get(TP - 1, True)
    return (True, True), results, (cltv_ok, cltv_refused)


def main():
    emit("CONSENSUS CROSS-CHECK  LUD-25/26 @ fd80cdd (v2)")
    emit("host=%s  core=%s  chain=regtest  node=127.0.0.1:%d"
         % (os.uname().nodename, cli("getnetworkinfo")["subversion"], RPC))
    emit("height=%d" % cli("getblockcount"))
    wallets = [w["name"] if isinstance(w, dict) else w for w in cli("listwallets", wallet=False)]
    if WALLET not in wallets:
        try:
            cli("createwallet", WALLET, "false", "false", "", "false", "true")
        except RuntimeError as e:
            emit("createwallet: %s" % e)
    emit("wallet=%s balance=%s" % (WALLET, cli("getbalance")))
    emit()

    b = case_bearer()
    _, _, cltv = case_timelock()

    emit()
    emit("=" * 78)
    emit("SUMMARY")
    emit("=" * 78)
    emit("bearer note: Core ACCEPTED the real preimage and REFUSED a wrong one  -> %s"
         % ("CONFIRMED" if all(b) else "NOT CONFIRMED"))
    emit("timelock   : CLTV due -> allowed=%s ; not-due -> refused=%s  -> %s"
         % (cltv[0], cltv[1], "CONFIRMED" if (cltv[0] and cltv[1]) else "NOT CONFIRMED"))
    ok = all(b) and cltv[0] and cltv[1]
    emit()
    emit("VERDICT: %s" % ("Core's interpreter confirms the v2 spend shapes."
                          if ok else "Core DID NOT confirm — do not claim consensus."))
    open(os.path.join(OUT, "CONSENSUS-V2.txt"), "w").write("\n".join(LOG) + "\n")
    print("\nwrote " + os.path.join(OUT, "CONSENSUS-V2.txt"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
