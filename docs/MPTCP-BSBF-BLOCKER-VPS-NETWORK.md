# BLOCKER: the BSBF test server cannot be installed — VPS has no internet

Date: 2026-10-17
Context: operator asked whether we can test against the BSBF endpoints. There are
no public test endpoints (see `MPTCP-BSBF-ASSESSMENT.md`), so testing BSBF means
standing up its server ourselves. This is why that cannot be done right now.

## Finding

**`vps2fips` / `testserver2` (23.182.128.51) currently has NO external network
connectivity.** It has lost it since our earlier successful work on it this
session (we installed `iperf3`, `mptcpize`, opened UFW rules and ran transfers).

Evidence, all from the host itself:

```
$ curl -s -o /dev/null -w "%{http_code}" --max-time 10 https://example.com
curl: (28) Resolving timed out after 10000 milliseconds
000

$ getent hosts raw.githubusercontent.com        -> (no output, resolution fails)
$ curl ... https://raw.githubusercontent.com/... -> 000
$ curl ... https://github.com                    -> 000
$ curl ... https://objects.githubusercontent.com -> 000

$ ping -c1 -W3 8.8.8.8     -> 1 packets transmitted, 0 received, 100% packet loss
$ ping -c1 -W3 1.1.1.1     -> 1 packets transmitted, 0 received, 100% packet loss
$ ping -c1 -W3 10.99.99.2  -> 100% packet loss        (its own wg-exit peer!)
```

Routing and DNS configuration are **present but non-functional**:
- `default via 23.182.128.1 dev eth0 proto static`
- eth0 DNS servers `1.1.1.1`, `8.8.8.8`; global resolver `[::1]:5354`, domain `~fips`
- `systemd-resolved` is the configured resolver, and resolution times out

## Why this blocks BSBF specifically

The BSBF server installer fetches **every component** from GitHub:

```
BSBF_RESOURCES="https://raw.githubusercontent.com/bondingshouldbefree/bsbf-resources/refs/heads/main"
curl -s $BSBF_RESOURCES/resources-server/bsbf-add-client -o /usr/local/sbin/bsbf-add-client
curl -s $BSBF_RESOURCES/resources-server/bsbf-add-client-api -o ...
... (7 more fetches, plus apt-get install bash nodejs)
```

With no DNS and no external egress it cannot fetch any of them. `apt-get update`
also hangs, so the `bash`/`nodejs` prerequisites cannot be installed either.

Our own machine CAN reach GitHub (verified: HTTP 200), so the components could be
staged locally and shipped to the host — but the missing egress would still block
the server from serving clients, which is the point of the exercise.

## What is still working on that host

- SSH in/out (we are connected now)
- Our two test WireGuard tunnels are still **up and handshaking**
  (`wgt1` 12 min ago / 173 KiB; `wgt2` 12 min ago / 39 MiB) — so the tunnel
  transport itself is healthy; only the host's *external* path is gone
- `wgexit0` exists but its peer is unreachable

## Honest assessment

This is **not** a defect in our MPTCP work, and it is not something I can fix
from here: it looks like the host lost its WAN/exit path (its own `wg-exit` peer
is unreachable too, so the fleet egress route is down, not just GitHub).

**Needs the operator or the fleet infrastructure owner:** is
`kt1.tx.sovereignhybridcompute.com` / this VPS's WAN path expected to be up, or
has the exit node gone away? Nothing BSBF-related can be tested until the host
can reach the internet.

## What was completed regardless

- **13-check MPTCP lane** in `physical-router-test-automation` (`9fcbdea`),
  including the hardened multipath-peer precondition.
- **BSBF assessment** (`MPTCP-BSBF-ASSESSMENT.md`): architecture decoded from the
  installers, licence corrected to AGPL-3.0-or-later, and the key requirement
  identified — `bsbf-mptcp` selects endpoints from **metriced default routes**,
  so a lab test needs mwan3-style multiple default routes or it selects nothing.
- The BSBF route remains the most promising for a real aggregation number, and
  our own earlier measurement on this box (eth 13.3 / wifi 16.5 / bonded
  19.4 Mbit/s ≈ 1.17x) is consistent with the documented 1.2-1.3x ceiling.
