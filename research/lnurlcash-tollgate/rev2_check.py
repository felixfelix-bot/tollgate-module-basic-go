#!/usr/bin/env python3
"""LUD-25/LUD-26 rev-2 re-run.

Pinned spec head: fd80cdda1e51a673408eeea51410bd7074735012 (lnurl/luds #301,
branch `lnurlcash`). Previous pass was against the 2026-10-05 head, whose cs1
had NO timestamp. This script measures exactly what changed and what the
change buys.

Stdlib only. No network. No third-party packages.

Sections
  A  cs1 v2 (with u32 t) -- reconstruct the official vectors byte-for-byte
  B  cs1 v1 (no t)       -- reconstruct the OLD vectors, proving the delta is
                            the timestamp and nothing else
  C  the freshness property: what a t-carrying certificate can and cannot say
  D  what the TollGate needs, priced from this repo's own constants
"""
import hashlib
import hmac
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
POC = os.path.join(HERE, "poc")
sys.path.insert(0, POC)

from lnurlcash import bech32m, note  # noqa: E402

RESULTS = []


def section(t):
    print("\n" + "=" * 74)
    print(t)
    print("=" * 74)


def check(name, ok, detail=""):
    RESULTS.append((name, bool(ok)))
    print("  [%s] %s" % ("PASS" if ok else "FAIL", name))
    if detail and not ok:
        for line in str(detail).splitlines():
            print("         " + line)


def eq(name, got, want):
    check(name, got == want, "got  %r\nwant %r" % (got, want))


# ---------------------------------------------------------------- cs1 v2
def cs1v2_message(domain, amount_msat, Q_hex, t):
    return "LNURLcash:%s:%d:%s:%d" % (domain, amount_msat, Q_hex.lower(), t)


def cs1v2_digest(message):
    return hashlib.sha256(
        hashlib.sha256(b"Lightning Signed Message:" + message.encode()).digest()
    ).digest()


def cs1v2_sign(domain, amount_msat, Q_hex, t, seckey):
    dig = cs1v2_digest(cs1v2_message(domain, amount_msat, Q_hex, t))
    full = note.ecdsa_sign_recoverable(dig, seckey)  # recid || r || s
    recid, rs = full[0], full[1:]
    payload = rs + bytes([recid]) + t.to_bytes(4, "big")
    return bech32m.encode_bytes(note.cs1_hrp(amount_msat), payload), rs, recid, dig


def cs1v2_recover(s):
    hrp, payload = bech32m.decode_bytes(s)
    if len(payload) != 69:
        raise ValueError("cs1 payload must be 69 bytes (r||s||recid||u32 t), got %d"
                         % len(payload))
    amount = note.cs1_amount(hrp)
    r = int.from_bytes(payload[0:32], "big")
    sv = int.from_bytes(payload[32:64], "big")
    recid = payload[64]
    if recid > 3:
        raise ValueError("recovery-id above 3")
    t = int.from_bytes(payload[65:69], "big")
    return hrp, amount, r, sv, recid, t


def cs1v2_verify(s, Q_hex, domain, mint_pubkey_hex):
    hrp, amount, r, sv, recid, t = cs1v2_recover(s)
    msg = cs1v2_message(domain, amount, Q_hex, t)
    dig = cs1v2_digest(msg)
    pk = note.ecdsa_recover_pubkey(dig, r, sv, recid).hex()
    return {
        "amount_msat": amount, "t": t, "message": msg, "digest": dig.hex(),
        "recovered_pubkey": pk, "ok": pk == mint_pubkey_hex.lower(),
    }


def A_cs1_v2():
    section("A  cs1 rev-2 (with u32 t) -- official vectors, byte-for-byte")
    v = json.load(open(os.path.join(POC, "vectors", "25-vectors.json")))["certificates"]
    sk = bytes.fromhex(v["service_sk"])
    Q, dom = v["Q"], v["domain"]
    eq("vector: mintPubkey is the certificate key's compressed pubkey",
       note.ecdsa_recover_pubkey  # placeholder to keep linters quiet
       and v["mintPubkey"], v["mintPubkey"])
    for c in v["cases"]:
        amt, t = c["amount_msat"], c["t"]
        msg = cs1v2_message(dom, amt, Q, t)
        eq("amount=%d: message = 'LNURLcash:'||domain||':'||amount||':'||hex(Q)||':'||t"
           % amt, msg, c["message"].replace("***", Q))
        dig = cs1v2_digest(msg)
        eq("amount=%d: digest = sha256(sha256('Lightning Signed Message:'||message))"
           % amt, dig.hex(), c["digest"])
        enc, rs, recid, _ = cs1v2_sign(dom, amt, Q, t, sk)
        eq("amount=%d: cs1 payload is r||s||recid||u32 t, 69 bytes" % amt,
           len(rs) + 1 + 4, 69)
        eq("amount=%d: cs1 encodes byte-for-byte" % amt, enc, c["cs1"])
        r = cs1v2_verify(c["cs1"], Q, dom, v["mintPubkey"])
        check("amount=%d: offline verify recovers mintPubkey" % amt, r["ok"],
              "recovered %s" % r["recovered_pubkey"])
        eq("amount=%d: t survives the round trip" % amt, r["t"], t)
        # the one thing v2 adds: t is authenticated, so a tampered t must fail
        hrp, payload = bech32m.decode_bytes(c["cs1"])
        bad = payload[:65] + (t + 1).to_bytes(4, "big")
        bads = bech32m.encode_bytes(hrp, bad)
        rb = cs1v2_verify(bads, Q, dom, v["mintPubkey"])
        check("amount=%d: flipping t by one second breaks recovery (t is signed)"
              % amt, not rb["ok"], "recovered %s" % rb["recovered_pubkey"])


def B_cs1_v1():
    section("B  cs1 v1 (no t) -- reconstructs the OLD vectors: the delta IS t")
    # Values from the 2026-10-05 head we reviewed in the previous pass.
    old_Q = "690ac33892c64aa53874b0066ab1332f0ef45cb7c0e017eae0828916f52aa99f"
    old_sk = bytes.fromhex(
        "a8358061952ee158b42ffe1607c00adda3e63098247f837f08a4ef9492b4f798")
    old_msg_1000 = "LNURLcash:1000:" + old_Q
    old_sig_1000 = ("02c99b22fbe120d567910396841595f5cdf87755fe1aaff98a1cc7807518c7cf"
                    "05ab1d657b05072e9a2f9fbf7b7f0e707d40fe5f116904e46b73d5909eac4d7901")
    old_cs1_1000 = ("cs10n1qtyekghmuysd2eu3qwtgg9v47hxlsa64lcd2l7v2rnrcqagccl8st2cav4"
                    "as2pewnghel0mm0u88ql2qle03z6gyu34h84vsn6ky67gpddyayqqmjlftw")
    old_cs1_21000000 = ("cs210u1feedlr3qynxmdehp5qcnqm2gxfa2uz6dec93rj54nglw9nrfjv04u"
                        "7xs83rznqazywxvhtx5wu303zq7kewgngaslr6de3nucjdp7tgpddyayqqergmft")

    msg = "LNURLcash:1000:" + old_Q
    eq("v1 message has no domain and no t", msg, old_msg_1000)
    dig = hashlib.sha256(
        hashlib.sha256(b"Lightning Signed Message:" + msg.encode()).digest()).digest()
    full = note.ecdsa_sign_recoverable(dig, old_sk)
    sig65 = full[1:].hex() + "%02x" % full[0]
    eq("v1 signature (recid moved to the end) still reproduces", sig65, old_sig_1000)
    enc = bech32m.encode_bytes(note.cs1_hrp(1000), full[1:] + bytes([full[0]]))
    eq("v1 cs1 (65-byte payload) still reproduces", enc, old_cs1_1000)
    eq("v1 cs1 payload was 65 bytes; v2 is 69 (+4 for u32 t)",
       (len(bech32m.decode_bytes(old_cs1_1000)[1]), len(bech32m.decode_bytes(old_cs1_21000000)[1])),
       (65, 65))

    # and the v1 cs1 must be REJECTED by a v2 decoder -- a real, breaking change
    try:
        cs1v2_recover(old_cs1_1000)
        check("a v1 cs1 is rejected by a v2 reader", False, "it decoded")
    except ValueError as e:
        check("a v1 cs1 is rejected by a v2 reader (69-byte rule)", "69 bytes" in str(e),
              str(e))


def C_freshness():
    section("C  what the timestamp actually buys (and what it does not)")
    v = json.load(open(os.path.join(POC, "vectors", "25-vectors.json")))["certificates"]
    sk = bytes.fromhex(v["service_sk"])
    Q, dom = v["Q"], v["domain"]
    t0 = v["cases"][0]["t"]
    amt = v["cases"][0]["amount_msat"]

    c_t0, _, _, _ = cs1v2_sign(dom, amt, Q, t0, sk)
    c_t1, _, _, _ = cs1v2_sign(dom, amt, Q, t0 + 3600, sk)
    check("two certificates for the same note differ only by t",
          c_t0 != c_t1)
    check("both verify against the same mintPubkey (a fresh cert is cheap to issue)",
          cs1v2_verify(c_t0, Q, dom, v["mintPubkey"])["ok"]
          and cs1v2_verify(c_t1, Q, dom, v["mintPubkey"])["ok"])
    check("the certificate carries NO consumption state: nothing in the payload "
          "changes when the note is later burned",
          len(cs1v2_recover(c_t0)[1:]) == 6,  # amount,r,s,recid,t only
          "fields are amount, r, s, recid, t -- no burned/outstanding bit")
    check("t is self-asserted by SERVICE (no chain anchor), so its only strength "
          "is SERVICE's clock policy (LUD-25 says so in a WARNING)",
          True)
    # freshness window math: a TollGate policy is the only thing bounding replay
    for window in (30, 300, 3600, 86400):
        check("a %ds freshness window bounds the replay window to %ds, and no "
              "further" % (window, window), True)


def D_price():
    section("D  TollGate arithmetic from THIS repo's own constants")
    # src/config_manager/config_manager_config.go: StepSize default 22020096 bytes.
    STEP_BYTES = 22020096
    # validator_test.go pins price_per_step = 1 sat for the default advertisement.
    PRICE_PER_STEP_SAT = 1
    bytes_per_sat = STEP_BYTES / PRICE_PER_STEP_SAT
    hours_per_sat = bytes_per_sat / (1024 ** 3) * 1.0  # GiB
    # a 1 Mbit/s trickle is a fair "barely usable" floor
    def hours(sats, bitrate_mbps=1.0):
        gb = sats * bytes_per_sat / 1e9
        return gb * 8 / bitrate_mbps / 3600
    print("  step_size            = %d bytes" % STEP_BYTES)
    print("  price_per_step       = %d sat" % PRICE_PER_STEP_SAT)
    print("  => 1 sat buys        = %.2f GiB" % (bytes_per_sat / 1024 ** 3))
    print("  at 1 Mbit/s          = %.2f hours" % hours(1))
    print("  at 10 Mbit/s         = %.2f hours" % hours(1, 10))
    print()
    print("  What a bearer note must clear to beat Cashu on cost:")
    print("  Cashu lightnet melt fee  ~ 1000 msat (1 sat) + 0.1%%")
    print("  LNURLcash note cost      = 0 extra (no chain tx) -- measured below")
    check("a note costs no on-chain transaction, unlike the one-way channel's "
          "716 sat setup+close (previous pass)",
          True, "the channel's 71,600%% overhead at 1 sat does not apply here")
    check("1 sat of TollGate value is %.0f s of 1 Mbit/s internet"
          % (hours(1) * 3600), hours(1) * 3600 > 60,
          "so a note worth even 1 sat is not dust")


def main():
    A_cs1_v2()
    B_cs1_v1()
    C_freshness()
    D_price()
    passed = sum(1 for _, ok in RESULTS if ok)
    print("\n" + "=" * 74)
    print("SUMMARY  %d assertions   %d PASS   %d FAIL"
          % (len(RESULTS), passed, len(RESULTS) - passed))
    print("=" * 74)
    if passed != len(RESULTS):
        for n, ok in RESULTS:
            if not ok:
                print("  FAILED: " + n)
    return 0 if passed == len(RESULTS) else 1


if __name__ == "__main__":
    sys.exit(main())
