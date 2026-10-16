# Root cause: the router sends no ADD_ADDR at all

Date: 2026-10-16 (Ralph loop iteration 18)
Question: after the tunnels work and both tunnel addresses are registered as
`signal subflow` endpoints, why does the peer still never open a subflow
(`MPJoinSynAckRx` stays 0)?

## Answer: `AddAddrTx` does not move. The router announces nothing.

Measured on the router across a completed 15-second transfer
(4.15 Mbit/s, `MPJoinSynRx` rising):

```
                          BEFORE   AFTER
MPTcpExtAddAddr              2        2
MPTcpExtAddAddrTx           54       54     <- ZERO new announcements
MPTcpExtAddAddrTxDrop        0        0     <- and none dropped
MPTcpExtAddAddrDrop          0        0
```

`AddAddrTx` unchanged with `AddAddrTxDrop = 0` is the decisive pair: the router
is not failing to transmit an ADD_ADDR, it is **never generating one**.

`ip mptcp monitor` confirms from the other side: the only events emitted during
the transfer are `CLOSED`. No `ADD_ADDR`, and no subflow establishment.

## Why this eliminates the earlier hypotheses

Every previous explanation is now ruled out by direct measurement:

| Hypothesis | Status |
|---|---|
| NAT-ed addresses unreachable by peer | **fixed** -- tunnels work, peer pings both tunnel addrs at 0% loss |
| Firewall rejecting tunnel traffic | **fixed** -- fw4 accept rule rendered; verified 0% loss |
| `wg set ... bind` invalid | **fixed** -- replaced with fwmark + policy routing |
| Route naming the tunnel instead of the uplink | **fixed** -- `Nexthop has invalid gateway` resolved |
| Peer refuses ADD_ADDR (`add_addr_accepted`) | peer is set to 4; and no ADD_ADDR is even sent, so this cannot be the cause |
| Scheduler cannot spread | **not the cause** -- no subflow exists to schedule |

The failure is upstream of all of these: **the local path manager does not
announce.**

## What this means

`signal subflow` on an endpoint tells the kernel "advertise this address". The
endpoints ARE registered correctly:

```
10.99.98.2 id 11 signal subflow dev mptcp-wan1
10.99.97.2 id 12 signal subflow dev mptcp-wan2
```

Yet no ADD_ADDR is generated. That points at the local path-manager decision
logic, not at the configuration surface. Candidate causes, none yet tested:

1. **The announcement is tied to the interface the connection ingressed on.**
   The MPTCP connection arrives over the *uplink* (lan1/phy0-sta0), while the
   new endpoints sit on *tunnel* interfaces (mptcp-wan1/2). A path manager that
   only announces addresses on the same interface as the connection would
   announce nothing here -- which matches the observation exactly.
2. **`AddAddrTx = 54` is historical**, from the earlier direct-uplink
   experiments, and the current endpoint set is being filtered before
   announcement.

Hypothesis 1 is the most likely and is testable: attach the tunnel endpoints to
the same interface the connection uses, or verify whether the path manager
scopes announcements per-interface.

## Honest status of the whole tunnel effort

**Proven:** the tunnel design works as designed. Two tunnels, distinct keypairs,
each pinned to its own uplink with fwmark + policy routing; both handshake, both
carry traffic, both tunnel addresses are reachable from the peer at 0% loss.
Three real defects were found and fixed by running it on hardware (`wg bind`,
route egress, firewall acceptance) -- none of which any unit test could see.

**Not proven:** a working MPTCP subflow over the tunnels, and therefore no
aggregation. The blocker has moved from addressing to the local path manager's
announcement behaviour, which is a kernel-behaviour question rather than a
configuration one.
