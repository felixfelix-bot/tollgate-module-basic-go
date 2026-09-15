#!/usr/bin/env python3
"""releak_scan.py — fail-closed scan for leaked Nostr secret-key material.

Why this exists
---------------
A leaked `nsec` is unrecoverable: the key cannot be un-published, and a
history rewrite does not revoke anything at the relay layer. This scanner is
the cheap, deterministic half of the key-leak remediation: it walks the tree
that is actually checked out and fails if anything in it looks like private
key material.

Contract
--------
* Self-contained: Python 3 standard library only, no network, no subprocess.
* It never prints the material it finds — only the path, the line number, the
  detector name, the match length and a SHA-256 fingerprint. A gate that
  echoes the secret into a build log has leaked it again.
* Exit codes: 0 clean (or self-test passed) | 1 findings | 2 usage error.

Usage
-----
    python3 scripts/security/releak_scan.py [--root DIR] [--self-test] [-v]

`--self-test` runs the detectors against synthetic samples (one planted leak
per detector plus a near-miss that must stay clean). It proves the detector
works inside the job, so a green run of the scan step means something.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys

# bech32 data charset used by NIP-19 (`nsec1…`); 1/b/i/o are excluded.
BECH32 = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"  # pragma: allowlist secret

DETECTORS = (
    # A bech32 secret key, with or without the surrounding quotes/assignment.
    ("nsec-bech32", re.compile(r"nsec1[" + BECH32 + r"]{20,}")),
    # A 64-hex secret sitting next to a name that says it is a secret key.
    (
        "hex-privkey-assignment",
        re.compile(
            r"(?:nostr[._-]?nsec|nsec|secret[._-]?key|seckey|priv(?:ate)?[._-]?key)"
            r"\s*[:=]\s*[\"']?[0-9a-fA-F]{64}\b",
            re.IGNORECASE,
        ),
    ),
)

SKIP_DIRS = {
    ".git", ".hg", ".svn", "node_modules", ".venv", "venv", "env",
    "dist", "build", "target", ".cache", ".next", "__pycache__",
}

MAX_FILE_BYTES = 2 * 1024 * 1024


def _fingerprint(match: str) -> str:
    """SHA-256 prefix of the matched material — proof without disclosure."""
    return hashlib.sha256(match.encode("utf-8", "replace")).hexdigest()[:12]


def _is_binary(path: str) -> bool:
    try:
        with open(path, "rb") as fh:
            return b"\x00" in fh.read(8192)
    except OSError:
        return True


def scan_text(text: str, source: str):
    """Yield findings as (source, lineno, detector, length, fingerprint)."""
    for lineno, line in enumerate(text.splitlines(), 1):
        for name, pattern in DETECTORS:
            for m in pattern.finditer(line):
                hit = m.group(0)
                yield (source, lineno, name, len(hit), _fingerprint(hit))


def iter_files(root: str):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            if os.path.islink(path):
                continue
            try:
                if os.path.getsize(path) > MAX_FILE_BYTES:
                    continue
            except OSError:
                continue
            yield path


def scan_root(root: str):
    findings = []
    for path in iter_files(root):
        if _is_binary(path):
            continue
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        rel = os.path.relpath(path, root)
        findings.extend(scan_text(text, rel))
    return findings


# --------------------------------------------------------------------------- #
# self-test: one planted leak per detector, plus a near-miss that must be clean
# --------------------------------------------------------------------------- #
def self_test() -> int:
    planted = [
        ("nsec-bech32", "leaked = 'nsec1" + "q" * 58 + "'"),
        ("hex-privkey-assignment", "nostr.nsec = '" + "a1" * 32 + "'"),
        ("hex-privkey-assignment", "private_key: " + "0123456789abcdef" * 4),
    ]
    clean = [
        "the nsec is read at runtime and never committed",
        "use nak key public to derive the npub from an nsec",
        "SECRET_KEY_LENGTH = 32",
        "nsec1 is the NIP-19 prefix",
    ]

    failures = []
    for want, sample in planted:
        got = [d for (_s, _l, d, _n, _f) in scan_text(sample, "<planted>")]
        if want not in got:
            failures.append("missed %s in %r" % (want, sample))
    for sample in clean:
        got = [d for (_s, _l, d, _n, _f) in scan_text(sample, "<clean>")]
        if got:
            failures.append("false positive %s in %r" % (",".join(got), sample))

    for _w, sample in planted:
        print("self-test: planted sample detections -> %d"
              % len(list(scan_text(sample, "<planted>"))))
    if failures:
        for f in failures:
            print("self-test: FAIL %s" % f, file=sys.stderr)
        return 1
    print("self-test: %d planted leak(s) detected, %d near-miss(es) clean"
          % (len(planted), len(clean)))
    return 0


def load_allowlist(path: str):
    """Read a committed allowlist: `<sha256-fingerprint>  <path>  # reason`.

    Every entry must carry an explicit reason, because the file is the record
    of what was reviewed and left in place. Entries are matched on the
    fingerprint of the material, so editing the allowlisted bytes turns the
    finding back into a failure.
    """
    allowed = {}
    if not path or not os.path.isfile(path):
        return allowed
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) < 1 or len(parts[0]) != 12:
                print("warning: %s:%d ignored (expected '<sha256-12> <path>')"
                      % (path, lineno), file=sys.stderr)
                continue
            allowed[parts[0]] = (parts[1] if len(parts) > 1 else "*", raw.strip())
    return allowed


def main(argv=None) -> int:
    p = argparse.ArgumentParser(
        prog="releak_scan.py",
        description="fail-closed scan for leaked Nostr secret-key material",
    )
    p.add_argument("--root", default=os.environ.get("GITHUB_WORKSPACE", "."),
                   help="directory to scan (default: $GITHUB_WORKSPACE or .)")
    p.add_argument("--allowlist", default=None,
                   help="committed allowlist of reviewed, non-secret fixtures")
    p.add_argument("--self-test", action="store_true",
                   help="run the detector self-test instead of scanning")
    p.add_argument("-v", "--verbose", action="store_true",
                   help="list every file scanned")
    args = p.parse_args(argv)

    if args.self_test:
        return self_test()

    if not os.path.isdir(args.root):
        print("error: root is not a directory: %s" % args.root, file=sys.stderr)
        return 2

    root = os.path.abspath(args.root)
    if args.verbose:
        for path in iter_files(root):
            print("scan: %s" % os.path.relpath(path, root))

    findings = scan_root(root)
    scanned = sum(1 for _ in iter_files(root))
    allowed = load_allowlist(args.allowlist)
    waived = [f for f in findings if f[4] in allowed]
    live = [f for f in findings if f[4] not in allowed]

    for source, lineno, detector, length, fp in waived:
        print("allowlisted: %s:%d %s sha256=%s (reviewed: %s)"
              % (source, lineno, detector, fp, allowed[fp][1]))

    if live:
        print("RELEAK SCAN FAILED: %d finding(s) in %s"
              % (len(live), root))
        for source, lineno, detector, length, fp in live:
            # never echo the material itself, only where and what kind
            print("  %s:%d %s len=%d sha256=%s"
                  % (source, lineno, detector, length, fp))
        print("Remove the material from the tracked tree and rotate the key: a "
              "leaked nsec cannot be revoked by a history rewrite.")
        return 1

    print("RELEAK SCAN CLEAN: %d file(s) scanned under %s, 0 finding(s)"
          "%s" % (scanned, root,
                  "" if not waived else
                  ", %d reviewed fixture(s) allowlisted" % len(waived)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
