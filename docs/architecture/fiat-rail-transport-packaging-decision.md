# Fiat-rail placement: FIPS transport, router edge, one package per unit

**Decided:** 2026-10-26, on the operator's directive that the mint, pecan and the
PayPal bridge are deployed as IaC, are individually packaged, and are reachable
over the FIPS mesh so their physical location does not matter.

**Status:** accepted; packaging feasibility for `pecan` is still open (see
"Open items").

## Decision

1. **Transport is FIPS, not a public hostname.** The mint, pecan and the bridge
   may run on any fleet node with a FIPS identity. The router addresses them by
   mesh address. No public IP, no DNS, no port-forward, and no dependency on
   NAT hole-punching beyond what the mesh already does.
2. **No inbound connection from the public internet is required — and none is
   allowed for this rail.** Consequently **PayPal webhooks are not used**:
   settlement is confirmed by server-side capture on the buyer's return plus a
   polling reconciliation against `GET /v2/checkout/orders/{id}` and its captures.
   *Correction to a common assumption:* FIPS does not make PayPal a mesh member;
   a public webhook endpoint would reintroduce exactly the ingress this decision
   removes.
3. **The router is the only customer-facing surface.** A pre-auth client has no
   `fips0`, so the funding page must be served by the router and reverse-proxied
   to the bridge over the mesh. FIPS makes the *backend* location-independent;
   it does not extend to the customer's phone.
4. **One unit = one package = one Ansible role.** `cdk-mintd`, `pecan` and the
   bridge each ship as their own package with their own init and state
   directory. No monolithic "fiat rail" package. Routers are not Ansible hosts
   in this fleet: the convention is a controller-side role that pushes the
   package over ssh (`playbook-router.yml` → `roles/61-openwrt-tollgate`), so
   "Ansible installs it on a router" means that pattern, not `hosts: router`.

## Why

- **The mesh is the cheapest way to remove the hostname from the threat model.**
  No public listener means no scanner, no certificate renewal for a public name,
  and no dependence on the operator's ISP handing out a reachable address.
- **Every service on this mesh needs three things, and each one has a measured
  failure mode.** Read `fips-service-port-admission` before packaging anything:
  - `fips0` is **IPv6-only**: a service bound to `0.0.0.0` accepts nothing from a
    peer (the peer gets RST). Bind `::` with `IPV6_V6ONLY=0`.
  - The **destination** must admit the port via a drop-in under
    `/etc/fips/fips.d/<svc>.nft` inside `table inet fips`, then
    `systemctl reload fips-firewall`. `/etc/fips/fips.nft` is the vendor
    baseline and is overwritten on upgrade — never edit it.
  - An **unregistered port is dropped at the source** with no RST and no ICMPv6,
    so the symptom is a pure timeout. Every service needs a *cross-node* connect
    proof, not a localhost check.
- **Architecture limit, stated up front:** the FIPS OpenWrt package exists for
  `aarch64_cortex-a53` and `x86_64` only (MIPS is excluded — no 64-bit atomics).
  A MIPS router cannot join the mesh, so it cannot use this transport at all.
- **Packaging the units separately is what makes the location choice reversible.**
  Moving the mint from one host to another becomes an inventory change plus a
  role run, not a rewrite.

## Consequences

- The router gains a proxy route (`/funding` → bridge over `fips0`) and must
  handle the pre-auth allowlist for whatever the buyer's browser genuinely needs
  (at minimum the PayPal asset domains, if the buyer approves payment on the
  captive device rather than on cellular).
- Every packaged service must be able to listen dual-stack; a package that
  hardcodes `0.0.0.0` is not deployable on the mesh.
- Secrets for these units come from OpenBao (`secret/data/fleet/{paypal,pecan,mint}`)
  with a local fallback — see `fiat-rail-secret-custody-decision.md`. The vault
  is a rotation path, never a boot dependency.
- Putting a unit on a router becomes *possible*. It stays *inadvisable* for the
  mint: signing keys would live on a device a customer can physically hold, and
  the flash/DB endurance argues against it. Packaging makes the option
  available; this ADR does not endorse it.

## Rejected alternatives

- **Public HTTPS name for the mint and bridge.** Rejected: it reinstates the
  public listener this design removes, and it is not needed once the mesh exists.
- **Webhook-driven settlement.** Rejected: it requires public ingress and breaks
  the "it can live anywhere" property. Polling is sufficient for a
  minutes-scale purchase.
- **Docker-only deployment.** Rejected: pecan's compose stack cannot run on an
  OpenWrt router, and Docker on a field router is a second runtime to secure.
  A native build is the requirement; whether it is achievable is the open item.
- **A single `fiat-rail` package.** Rejected: the three units have different
  lifecycles, failure modes and secrets; bundling them couples a mint upgrade to
  a bridge restart.

## Open items

- **`pecan` native build** (spike `t_7cc13ed2`): if it cannot be built without
  Docker, "pecan on a router" is false and pecan stays a container on a Docker
  host. This ADR must then be read as applying to the mint and the bridge only.
- Router-side seed encryption is tracked in
  `router-wallet-seed-at-rest-decision.md`.
