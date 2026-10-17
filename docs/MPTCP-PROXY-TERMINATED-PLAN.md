# Adopting the proxy-terminated shape — implementation plan

Date: 2026-10-17
Decision: `docs/architecture/multi-wan-bonding-decision.md` §A1.2 (D10), PR #979.
Status: plan. The decision is a docs PR awaiting maintainer review; nothing here
starts before it is open (it is) — but nothing here is *merged* until it is.

## What changes, and what does not

**Changes:** the *shape* of the de-aggregation transport. The client initiates
every path and the server terminates; the client therefore needs **no routable
address**. `ADD_ADDR` becomes informative rather than load-bearing.

**Does not change:** the router-side enforcement boundary (the router still only
steers, per D5), the config contract (D7), the tag vocabulary (D6 — the existing
`endpoint` tag already suffices), or the claim discipline (≈1.2–1.3×, D5).

This is deliberately **not** a rewrite of the merged bonding seam. The seam is
uplink-only and correct at its own layer; D10 constrains the *server*'s shape
(rollout step 3), which is where the transport terminates.

## Why the current shape cannot work (the measurement it rests on)

MPTCP builds a second subflow by having the **peer connect back** to an address
the client advertised. On the lab router both uplinks are private (house NAT +
Starlink CGNAT), so:

- the peer's `MPTcpExtAddAddr` stayed **0** — it never received one
- `MPJoinNoTokenFound` climbed (JOIN attempts, no usable token)
- the satellite subflow sat at ~1.7 KB, handshake only, indefinitely

No router-side configuration fixes it. A per-uplink tunnel DOES restore the
reachability the path manager wants (verified: both tunnels handshake, both tunnel
addresses answer the peer at 0% loss, `SF_ESTABLISHED` on a tunnel address) and is
**kept as the supported fallback** — but it still makes the client addressable on
the advertised address, which is the requirement D10 removes.

## Work items

### W1 — Proxy termination on the server (the core of D10)

The server hosts a proxy listener per client; the client dials it. Client-side
there is still exactly one thing to configure: `endpoint=<host:port>`.

- **Metering boundary = transport boundary** (D3 + A1.2). The per-client counter
  and quota sit on the terminating side, so one client's inbound *is* its meter
  key. This removes the mis-attribution class where per-path counters double-count
  a retransmit.
- **Per-client inbound, keyed by client identifier, on a client-specific port**
  (D11). Do **not** assume a shared port: a host already terminating TLS on the
  standard port would collide. The reference shape publishes one inbound per
  client on a client-derived port.
- **`server_port` becomes per-client configuration**, published in the
  advertisement alongside `endpoint`, because the client cannot otherwise
  construct the address it is told to dial. This is a small but real contract
  change and belongs in the advertisement, not in out-of-band setup.
- Enforcement stays **default-deny** with an explicit terminal drop and an
  allow-list ahead of it (D3) — an accept-policy metered chain delivers
  over-quota traffic and looks healthy while doing it.

### W2 — Prove the claim on the router before writing any user-facing text

The one thing that makes D10 worth doing is: **it works behind CGNAT.** So the
first test is not a throughput number, it is reachability.

1. Client behind CGNAT (the lab router's Starlink uplink qualifies), server on a
   public host. Client dials; server never dials the client.
2. Assert a subflow exists **without any inbound reachability to the client** —
   i.e. with no port-forward and no tunnel.
3. Only then measure. Report **ranges over runs**, and word every claim as
   *resilient multi-path, not 2×* (D5). The honest expectation is that the
   aggregate will be unimpressive: the lab's paths are a ~155 ms high-jitter
   satellite link and an unstable wired link, and the path manager correctly
   concentrates on the lower-latency one.

   For reference, the three-run table from the fallback measurement (MB / 10 s):
   StarGate-only 8.68/8.78/6.19, wired-only 2.48/0.83/5.78, both 3.72/–/3.83 —
   within-configuration spread exceeded the between-configuration difference.

### W3 — IaC for the new shape (extend the existing kit, do not fork one)

Extend `tests/mptcp/` in `felixfelix-bot/physical-router-test-automation`
(the kit's own Prime Directive: build on the existing kit). Add, feature-detected
so they skip cleanly when the shape is absent:

- a check that the client is **not** relying on inbound reachability (no
  advertised-address subflow is required to exist)
- a check that the deployed `endpoint` + per-client `server_port` are the pair the
  client actually dials (guards the D11 contract change)
- keep the existing `test_no_mptcp_fallback_before_any_measurement` — it is
  orthogonal and remains the precondition that must pass first

### W4 — Do not vendor the reference stack

D8's prohibition is unchanged (and A1.4 corrects its stated licence: the
`bondingshouldbefree` installers are **AGPL-3.0-or-later**, not GPL-2.0-only).
It is a packaged feed client plus a server-side systemd component; there is no
library to import. Reading it for shape is fine — it is proxy-terminated in the
same way, and it is useful prior art precisely for that reason.

One fact from reading it, recorded so it is not rediscovered: its endpoint
selection reads **default routes carrying a metric**. With no metriced default
route it flushes every endpoint and does nothing — so a lab comparison against it
needs multiple metriced default routes, or an interface that is up will appear to
be "dropped".

## Blocked on infrastructure, not on us

The BSBF server cannot be stood up for comparison right now: `vps2fips`
(23.182.128.51) has lost external connectivity — DNS resolution times out,
GitHub/`example.com` return `000`, `8.8.8.8` and `1.1.1.1` are 100% packet loss,
and its own wg-exit peer (`10.99.99.2`) is unreachable. Its installer fetches
every component from `raw.githubusercontent.com`, so it cannot be provisioned.
A server that cannot reach the internet could not serve clients anyway.

W1–W3 do not depend on that host; any public host with a proxy listener works.

## Sequencing

The docs decision (#979) is open and carries the vocabulary as *text*, so the
other work needs it **open, not merged** (D9). W2 before W1's user-facing text;
W3 lands with whichever of W1/W2 it is testing.
