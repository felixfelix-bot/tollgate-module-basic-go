# Tunnel-per-uplink: device verification (partial, honestly reported)

Date: 2026-10-16 (Ralph loop iteration 16)
Design: run the MPTCP peer on a fleet VPS and give each router uplink its own
WireGuard tunnel, so the advertised subflow address is reachable by the peer.

## What the device run PROVED

**1. `wg set ... bind` does not exist — my first implementation was wrong.**
This is the highest-value finding, because it came only from running the render
on real hardware:

```
$ wg set mptcp-wan1 private-key /tmp/router.key
$ wg set mptcp-wan1 peer <key> endpoint 23.182.128.51:51901 \
        allowed-ips 0.0.0.0/0 persistent-keepalive 25 bind 192.168.2.15
Invalid argument: bind

$ wg set --help
Usage: wg set <interface> [listen-port <port>] [fwmark <mark>]
           [private-key <file path>] [peer <base64 public key> [...]
           [endpoint <ip>:<port>] [persistent-keepalive <n>]
           [allowed-ips <...>] ]
```

There is **no per-peer source-address binding**. Pinning a tunnel to one uplink
requires **`fwmark` + policy routing** instead. The renderer was rewritten
accordingly; a test now asserts `bind` can never be emitted again.

**2. The corrected plan applies cleanly.** After the fix, on the router:
```
interface: mptcp-wan1
  listening port: 51820
  fwmark: 0x2001
interface: mptcp-wan2
  listening port: 51821
  fwmark: 0x2002

ip rule: from all fwmark 0x2001 lookup 201
ip rule: from all fwmark 0x2002 lookup 202
```

**3. The routing route must name the UNDERLAY, not the tunnel.** A first attempt
rendered `via <gw> dev <tunnel>`, which the kernel rejected:
```
Error: Nexthop has invalid gateway.
```
Routing a tunnel's own encrypted traffic out its own device is a loop. The route
now names the uplink (`dev lan1`, `dev phy0-sta0`) and applies successfully.
A test pins this.

**4. Prerequisites are genuinely stock.** `kmod-wireguard` (6.6.93-r1) and
`wireguard-tools` (1.0.20210914-r4) installed from the official OpenWrt feeds,
version-matched to the running kernel.

## What was NOT proven

**The tunnel did not complete a handshake in my test harness.**
`wg show all transfer` reported `0 0` on both interfaces, and `tcpdump` on the
VPS captured **zero** UDP packets on either port. So the encrypted traffic never
left the router.

Diagnosis is incomplete. Known defects in the HARNESS (not necessarily the
renderer):

- I initially gave **both tunnels the same private key**, so they presented one
  identity to two peer entries. Each tunnel needs its own keypair; the harness
  was mid-correction when this run stopped.
- The VPS side used two network namespaces with separate listeners; that
  topology was chosen for convenience and has not been validated as correct for
  WireGuard peer resolution.

I am explicitly NOT claiming the tunnel design works end-to-end. What is proven
is that the render is syntactically valid, applies without error, installs the
expected fwmark/rule/route state, and that the two design bugs found by running
it are fixed.

## Why this is still worth shipping

The `bind` bug would have made every attempt fail identically in the field, with
an error a user could not act on. Finding it required the device; no unit test
could see it, because the unit test was written against the same wrong assumption
as the implementation. The `Nexthop has invalid gateway` bug is the same class.

## Next step to close this out

Re-run with a distinct keypair per tunnel and a single-namespace VPS
configuration, then confirm `wg show` reports a handshake and non-zero transfer,
and that both tunnel addresses appear in `ip mptcp endpoint show`.
