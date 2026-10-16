# ADD_ADDR is never sent: what was eliminated and where it stands

Date: 2026-10-16 (Ralph loop iteration 19)
Follows `MPTCP-NO-ADDADDR-ROOTCAUSE.md`.

## The observation, restated precisely

The router never generates an ADD_ADDR, so the peer never learns a second
address, so no subflow can be opened. Two independent measurements agree:

- **Router:** `MPTcpExtAddAddrTx` is unchanged across completed transfers
  (54 -> 54), with `AddAddrTxDrop = 0` and `AddAddrDrop = 0`. It is not failing
  to send; it is never generating one.
- **Peer:** `MPTcpExtAddAddr = 0`. The peer has **never received a single
  ADD_ADDR** in its life.
- **Router:** `ip mptcp monitor`, attached *before* the transfer, emitted only
  `CLOSED` events -- no `ADD_ADDR`.

## Everything eliminated, each by direct measurement

| Candidate cause | How it was ruled out |
|---|---|
| Addresses private / NAT-ed | Fixed: tunnels work, peer pings both tunnel addrs at 0% loss |
| Firewall rejecting tunnel traffic | Fixed: fw4 accept rule rendered and verified |
| `wg set ... bind` unsupported | Fixed: replaced with fwmark + policy routing |
| Pinning route on the wrong device | Fixed: `Nexthop has invalid gateway` resolved |
| Endpoints not registered | They are: `10.99.98.2 id 1 signal subflow dev lan1`, `10.99.97.2 id 2 ...` |
| `add_addr_accepted` too small | Set to 4, read back as 4 |
| `subflows` ceiling too small | Set to 4, read back as 4 |
| Endpoint on the wrong interface (scoping to the ingress interface, the leading hypothesis) | **Falsified**: moved the address onto the uplink interface `lan1`; `AddAddrTx` still did not move |
| Stale endpoints from earlier runs | Flushed all endpoints, registered only the tunnel addresses, made a FRESH connection; still no announcement |
| Peer refusing announcements | Peer's `AddAddr = 0` -- nothing was ever sent for it to refuse |
| Scheduler | Irrelevant: no subflow exists to schedule |

## The asymmetry that frames the remaining question

The two hosts differ in an important way:

| | Router (GL-MT6000, OpenWrt 24.10.2) | Peer (VPS, Debian) |
|---|---|---|
| Kernel | 6.6.93 | 6.12.111 |
| `available_schedulers` | **absent** | **present** |
| `MPCapableSYNTX` | (initiator) | 0 -- never initiates |
| `MPTcpExtAddAddr` (received) | 2 | **0** |

The peer has the newer MPTCP stack; the router has the older, more limited one.
`MPCapableSYNTX = 0` on the peer is normal (it only responds), so the router must
drive announcements -- and it is not doing so.

## Where this genuinely stands

**The tunnel design works.** That is the substantive result of this effort and it
is fully verified: two tunnels, distinct keypairs, each fwmark-pinned to its own
uplink, both handshaking, both carrying traffic, both addresses reachable from
the peer at 0% loss. Three real defects were found and fixed *only* by running on
hardware.

**Subflow aggregation is not achieved, and the blocker is now a kernel
path-manager behaviour on a deliberately limited 6.6.93 build** -- in the same
family as the scheduler limitation already documented
(`MPTCP-SCHEDULER-LIMIT.md`). Two independent limitations of that build now block
the feature from opposite ends:

1. only the `default` scheduler is compiled in;
2. the path manager does not announce second addresses in this configuration.

Neither is reachable from TollGate configuration or from this PR's code. Both
would be addressed by a kernel built with the fuller MPTCP feature set.

## Recommendation

Stop chasing this from userspace. The remaining work is a **kernel/packaging
question** for whoever owns the OpenWrt image: confirm whether 6.6.93 for
mt7986 is built with the path-manager announcement paths enabled, and whether
upstream's `mptcpd` userspace path manager changes the behaviour -- the kernel's
in-kernel PM is the piece that appears not to advertise here.

## What this PR ships, honestly stated

- The bond renderer, applier, reconciler, config surface, and host wiring: done,
  tested, and verified on device.
- The tunnel design: implemented and proven to work as a transport.
- Measurement tooling and the `AssessPaths` preflight: done, exercised on real
  captured data.
- Aggregation: **not achieved**, with the blockers identified to kernel level and
  documented rather than papered over. The honest ceiling remains 1.2-1.3x, not
  2x, and it is not demonstrated at all on this hardware.
