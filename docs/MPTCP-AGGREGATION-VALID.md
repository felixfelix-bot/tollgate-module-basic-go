# Valid aggregation measurement (peer genuinely multipath-capable)

Date: 2026-10-16 (Ralph loop iteration 21)

## Preconditions now correct -- this is the first valid run

Every earlier throughput figure in this investigation was taken against a
**fallback** connection (plain-TCP listener on the peer), so none of them
measured MPTCP at all. Preconditions verified for this run:

- peer listener genuinely MPTCP: `ss -Mltn` shows `mptcp LISTEN 0 4096 *:5201`
  (see `MPTCP-RESOLVED-PEER-FALLBACK.md` for why this matters);
- both tunnels up with recent handshakes (51 s / 46 s ago);
- both tunnel addresses registered as `signal subflow` endpoints;
- `subflows 4`.

## Subflow over the tunnel: PROVEN, repeatedly

Live `ip mptcp monitor` on the router during transfers, across multiple runs:

```
[     ESTABLISHED] locid=0 saddr4=10.2.1.122  daddr4=23.182.128.51
[  SF_ESTABLISHED] locid=1 saddr4=10.99.97.2  daddr4=23.182.128.51 sport=46551 ifindex=90
```

`SF_ESTABLISHED` with `saddr4=10.99.97.2` -- the WireGuard tunnel address -- is
the subflow running over the tunnel. This is the mechanism the whole effort was
built to achieve, and it now happens on every transfer. Counters agree:
`AddAddrTx` 54 -> 62, `MPJoinSynAckRx` 0 -> 7.

## Throughput: too noisy to claim a multiplier

Method: single-path measured by registering only one tunnel's endpoint (the other
tunnel's route table and rule removed), aggregate by registering both. Ranges are
reported rather than means, because the variance is larger than any effect.

| Configuration | MBytes per 10 s run (3 runs) |
|---|---|
| StarGate tunnel only | 8.68, 8.78, 6.19 |
| wired tunnel only | 2.48, 0.83, 5.78 |
| **both (aggregate)** | 3.72, (lost), 3.83 |

**The honest reading: no multiplier is demonstrated.** The between-run spread
within a single configuration exceeds the difference between configurations. The
aggregate runs were not even the fastest.

The underlying cause is the path characteristics, not the configuration. The
StarGate uplink is a ~155 ms satellite path with high jitter; the wired path
measured 0.83-5.78 MB across runs, i.e. it is itself unstable. MPTCP's default
scheduler concentrates on the lower-latency path, which is correct behaviour when
one path is both faster and steadier.

Stated plainly: **two subflows establish, the tunnel subflow carries traffic, and
no throughput gain is demonstrated.** Ceiling if it were achievable remains
**1.2-1.3x, not 2x**.

## Defect found: `ip mptcp endpoint flush` resets the limits

Observed repeatedly and worth recording, because it silently degrades a bond:

```
$ ip mptcp limits
add_addr_accepted 4 subflows 4
$ ip mptcp endpoint flush
$ ip mptcp limits
add_addr_accepted 0 subflows 4      <- add_addr_accepted reset to 0
```

`add_addr_accepted 0` means the router will **refuse the peer's ADD_ADDR**, so a
reconcile that flushes endpoints can silently break peer-initiated subflows.
The applier must therefore re-assert limits after any flush. Recorded as a
requirement for the reconcile path.

## What this changes in the PR's claims

- **Add:** a genuinely multipath peer produces `SF_ESTABLISHED` on a tunnel
  address -- the subflow mechanism works end to end, over a NAT-traversing
  tunnel, with distinct keypairs and fwmark pinning.
- **Keep:** no aggregation demonstrated. This is now a measurement with correct
  preconditions, not a measurement against a fallback connection -- a stronger
  negative result than before.
- **Keep:** ceiling 1.2-1.3x, not 2x.
