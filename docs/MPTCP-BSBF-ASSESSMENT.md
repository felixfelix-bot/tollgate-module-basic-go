# BSBF endpoints: assessment (what they are, and whether to test against them)

Date: 2026-10-17
Trigger: operator asked whether we can test against the BSBF endpoints listed in
the pasted search result.

## Correction first: there are no public BSBF test endpoints

The pasted text describes a **self-hosted project with install scripts**, not a
multi-tenant service with a testing API. Verified by fetching each URL:

| URL | What it actually returns |
|---|---|
| `srv.bondingshouldbefree.org` | 128-line **server** bash installer |
| `cld.bondingshouldbefree.org` | Linux client installer |
| `owrt.bondingshouldbefree.org` | 50-line **OpenWrt** client installer |

Licence on all three: **`SPDX-License-Identifier: AGPL-3.0-or-later`**
(Copyright 2025-2026 Chester A. Unal). This **corrects an older note of ours
that recorded BSBF as GPL-2.0-only**. AGPL-3.0-or-later is compatible with
TollGate's GPL-3.0 lineage, and the "interoperate, do not vendor" posture still
stands for a simpler reason: the client is a packaged systemd/apk component with
its own server-side counterpart, so there is nothing to vendor into a Go module.

## The architecture, decoded from the installers

**Server** (`srv` + `resources-server/`):
- installs `bash`, `nodejs`, and **Xray**;
- `bsbf-mptcp-configuration.service` generates one Xray inbound **per client**;
- `bsbf-add-client` writes that inbound with
  `streamSettings.sockopt.tcpMptcp = true` and a **per-client `PORT` set to
  `CLIENT_ID`**, so each client has its own server port;
- `bsbf-add-client-api.service` exposes an add-client API; `bsbf-list-client`
  enumerates clients.

**Client** (`owrt` + `resources-client/`):
- `apk add kmod-ifb kmod-nft-tproxy` then `apk add bsbf-bonding` (official feed);
- writes `/etc/bsbf/bsbf-bonding.conf` with `server_ipv4`, `server_port`, `uuid`;
- `bsbf-mptcp` (176 lines) is the interface watcher: every interval it
  - reads **default routes that carry a `metric`**,
  - de-duplicates routes for one interface,
  - extracts interfaces from those routes,
  - per-interface connectivity-check with `fping -I "$IFACE" 5.196.67.207`,
  - adds/removes MPTCP endpoints for the supported interfaces,
  - sets `ip mp limits set subflows 8`.

## The important architectural difference from what we built

BSBF is a **proxy-terminated** design: Xray runs on both ends with
`tcpMptcp` on the inbound, and traffic is proxied (client tproxy → Xray →
server Xray → freedom). MPTCP aggregation therefore happens on the **proxied**
byte stream, and the client needs **no routable address of its own** — the
server never has to connect back to the client.

Our tunnel design instead advertised a **reachable tunnel address** and let the
kernel's path manager form subflows directly. That is why ours needed
`ADD_ADDR` to work, and why it was so sensitive to the peer being genuinely
multipath-capable.

**Consequence worth stating plainly: BSBF's approach is structurally more
robust than ours for a NAT-ed client, because it removes the
peer-connects-back-to-you requirement entirely.**

## A key requirement we can now check

`bsbf-mptcp` selects endpoints from **default routes that have a `metric`**. A
router with a single unmetriced default route yields **no endpoints at all**
(`routes` empty → `ip mp e f` → flush and continue). This directly explains the
earlier finding in our own notes that BSBF's check "DROPS the lan1 endpoint": the
interface was reachable but not present as a metriced default route.

For any BSBF test on our lab we therefore need **mwan3-style multiple default
routes with distinct metrics**, not just two interfaces with addresses.

## Recommendation

1. **Do not treat BSBF as "endpoints to test against"** — there are none. It is
   a self-hosted stack, and testing it means standing up the server on our VPS.
2. **That is worth doing**, because it is the one design in this space that is
   proven to aggregate (our own earlier measurement: eth-only 13.3, wifi-only
   16.5, **bonded 19.4 Mbit/s ≈ 1.17x**) and it needs no routable client
   address.
3. The VPS is suitable: Debian 13 with systemd and node present. **Port 443/udp
   is already held by Caddy** — the BSBF server generates its own per-client
   ports, so we must confirm it does not assume 443 before installing, and must
   not disturb Caddy.
4. Prerequisite on the router side: multiple **metriced** default routes, or the
   client watcher will select nothing.

## What this changes about our own work

Nothing is invalidated, but the honest framing sharpens:

- our **subflow-over-tunnel result stands** (`SF_ESTABLISHED` on a tunnel
  address) and is a genuine kernel-MPTCP multipath demonstration;
- our **no-multiplier** result is now joined by a real alternative design that
  DID aggregate on this same box at ~1.17x — which is consistent with the
  1.2-1.3x ceiling and suggests the ceiling is a property of the paths, not of
  our implementation;
- the comparison is therefore worth running, and the BSBF server on our VPS is
  the way to run it.
