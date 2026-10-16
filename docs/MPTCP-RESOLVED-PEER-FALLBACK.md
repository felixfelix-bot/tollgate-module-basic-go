# RESOLVED: the peer listener was plain TCP, not MPTCP

Date: 2026-10-16 (Ralph loop iteration 20)
**This is the root cause of the entire "no ADD_ADDR" failure. It was a test-harness
defect on the peer, not a router, tunnel, firewall, or configuration problem.**

## The defect

`mptcpize run iperf3 -c ...` on the CLIENT makes the client's socket MPTCP. But
the **listener** on the peer must ALSO be started under `mptcpize`:

```sh
# WRONG -- listener stays plain TCP:
iperf3 -s -p 5201

# RIGHT -- listener becomes MPTCP:
mptcpize run iperf3 -s -p 5201
```

`mptcpize` works via `LD_PRELOAD`; installing the package does NOT convert an
already-running process, and does not convert a listener started without it.

## Why this produced exactly the symptoms observed

When the client's SYN carried `MP_CAPABLE` but the listener's socket was plain
TCP, the peer answered with an ordinary SYN-ACK and **MPTCP fell back to regular
TCP**. A fallback connection has no MPTCP path manager, so:

- the router **never generated an ADD_ADDR** (`AddAddrTx` frozen at 54) -- there
  was no multipath connection to attach one to;
- the peer **never received one** (`MPTcpExtAddAddr = 0`);
- `ip mptcp monitor` showed only `CLOSED`;
- yet subflow-related counters appeared to move (`MPJoinSynRx`, then
  `MPJoinNoTokenFound`) because the router attempted joins against a
  non-multipath peer.

The counters that would have identified this immediately:

```
peer: MPTcpExtMPCapableSYNACKRX = 0     <- the peer NEVER sent an MPTCP SYN-ACK
peer: ps aux | grep iperf3              -> "iperf3 -s -p 5201"  (no mptcpize)
```

## Proof of the fix

After restarting the peer listener as `mptcpize run iperf3 -s -p 5201`, verified
as MPTCP by `ss -Mltn` showing `mptcp LISTEN 0 4096 *:5201`:

```
BEFORE                              AFTER
MPTcpExtAddAddrTx      54      ->   56        <- the router now ANNOUNCES
MPTcpExtMPJoinSynAckRx  0      ->   2         <- the peer completes the handshake
```

`ip mptcp monitor` on the router, live during a transfer:

```
[     ESTABLISHED] token=ed024a1a saddr4=10.2.1.122 daddr4=23.182.128.51
[  SF_ESTABLISHED] token=ed024a1a locid=2 saddr4=10.99.97.2 daddr4=23.182.128.51
                                                  ^^^^^^^^^^^ THE TUNNEL ADDRESS
```

**`SF_ESTABLISHED` with `saddr4=10.99.97.2` is the subflow running over the
WireGuard tunnel.** That is the mechanism this entire effort was built to
achieve: an advertised address the peer can reach, reached.

## The lesson, stated plainly

Every measurement in this investigation was valid for what it measured, but the
**system under test was not in the configuration I believed it was**. A fallback
connection behaves plausibly right up until you check whether MPTCP capability
was negotiated. The single counter that settles it is
`MPCapableSYNACKRX` on the responder -- if the peer never sends an MPTCP
SYN-ACK, nothing downstream can possibly work, and no amount of router-side
debugging will show it.

Recorded because it cost many iterations: **verify the far end is genuinely
multipath-capable before diagnosing anything else.** Check
`ss -Mltn` on the listener.

## Corrected status of every prior claim

| Earlier claim | Correction |
|---|---|
| "No ADD_ADDR generated -- kernel path-manager limitation" | **Wrong.** It was MPTCP fallback caused by a plain-TCP listener. The path manager is fine. |
| "Kernel 6.6.93 announcement paths may be disabled" | **Unfounded.** No kernel rebuild is needed. |
| "Interface-scoping hypothesis" | Falsified, as recorded -- and now moot. |
| Scheduler limitation (`MPTCP-SCHEDULER-LIMIT.md`) | **Still true and still separate:** this kernel really does ship only the `default` scheduler. It was never the cause of *this* symptom. |
| Tunnel design | **Validated.** The tunnel subflow established. The three device-found defects (wg bind, route egress, firewall acceptance) remain real fixes. |

## Next step

With a genuinely multipath peer, re-run the aggregation measurement. The earlier
"no multiplier" conclusion was drawn against a fallback connection and must be
re-measured. Ceiling expectation is unchanged at **1.2-1.3x, not 2x**, but it has
NOT yet been honestly measured.
