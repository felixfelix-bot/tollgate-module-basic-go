# Fiat-rail secret custody: the vault is the rotation path, never the boot path

**Decided:** 2026-10-26, for the PayPal-funded custom-unit Cashu rail
(plan: `PLAN-paypal-custom-unit-rail.md`, path B — pecan + a `eur-cent` mint).

**Status:** accepted. Applies to any service this project deploys: `cdk-mintd`,
`pecan`, the PayPal bridge, and the router-side edge.

## Decision

1. **Three custody tiers, and only one of them is a dependency.**

   | Asset | Authoritative copy | Operational copy | Never |
   |---|---|---|---|
   | `cdk-mintd` seed (mnemonic) | offline escrow, Shamir-split | OpenBao KV (rotation + automation) | vault-only |
   | router wallet mnemonic | the router's own flash (`0600`) | OpenBao KV (device-keyed path) | required at boot |
   | PayPal client secret | PayPal dashboard | OpenBao KV | on the router |
   | pecan admin credentials | pecan's own store | OpenBao KV | in the portal bundle |
   | backup passphrase (age/restic) | offline escrow | OpenBao KV | beside the repository |

2. **No service may fail to start because OpenBao is unreachable, sealed, or has
   an expired AppRole.** The vault is the *rotation* path and the *audit* path.
   Every consumer keeps a local fallback (systemd credential / `0600` file
   outside the vault) that is sufficient to boot and serve.
3. **OpenBao holds small secrets only.** Credentials, seed copies, passphrases.
   Bulk or growing data (the mint's SQLite, keyset tables, ledgers) never goes
   into KV.
4. **Unseal material is never stored in OpenBao.** Shamir shares live offline,
   geographically separated. Storing them in the vault they unseal is circular.

## Why

- **Measured on this fleet:** OpenBao 2.6.2, `initialized: true`, `sealed:
  false`, AppRole login succeeds unattended (`role: fleet-node-x280`,
  `policies: [default, fleet-node-x280]`). The pattern — env → AppRole login →
  `GET /v1/secret/data/fleet/*` — already works with no unseal step, so the
  marginal cost of using it here is a policy path plus a loader, not a new
  system.
- **A boot-path dependency on the vault converts a vault outage into a payment
  outage.** On the router that is worse than elsewhere: a field device that
  reboots where the mesh does not come up cannot sell connectivity at all. That
  is a self-inflicted denial of the money path.
- **The restart trap is measured, not hypothetical.** A service that resolved a
  secret once at startup holds the only readable copy in process memory; when
  its AppRole later dies, restarting it is fatal (observed 2026-10-18 on
  `fiat-cvm`: login `403`, token nowhere on disk). Any design here must be
  restart-safe: the credential has to be re-resolvable *before* a restart, and
  a fallback must exist when it is not.
- **Vault data is encrypted by a barrier key protected by the unseal keys.**
  Losing or rotating the unseal material incorrectly loses the copy. That is why
  the mint seed's authoritative copy cannot be vault-only.

## Backups: yes — with these rules

OpenBao is a good place for **key material and passphrases**, and a bad place
for **datasets**.

- **KV v2, versioned:** `secret/data/fleet/mint/seed`,
  `secret/data/fleet/router-wallet/<device-code>`,
  `secret/data/fleet/paypal`, `secret/data/fleet/pecan`,
  `secret/data/fleet/backup/passphrase`. Do **not** set
  `delete_version_after` on the seed path — an accidental overwrite must be
  recoverable by reading a previous version.
- **The mint database is not a vault object.** Snapshot it consistently
  (`sqlite3 <db> ".backup <tmp>"` — never copy a live SQLite file), encrypt
  client-side with `age` (or restic), and push to a repository. The passphrase
  lives in OpenBao; the ciphertext never does.
- **The database is a security asset, not just convenience.** With CDK the
  spent-proof set lives in the mint DB. Restoring an older snapshot silently
  **rewinds double-spend protection**: notes spent after the snapshot look
  unspent again. So the seed alone is not a restore — and a DB rollback is a
  security event with a value window, not a routine recovery. Keep the RPO
  small (frequent consistent snapshots), record the snapshot time next to every
  restore, and if the rollback window is non-trivial, treat it as a keyset-rotation
  decision rather than pretending the rollback was clean.
- **3-2-1 still applies:** vault copy + encrypted off-box repository + offline
  escrow of the seed. Any one of the three may be lost without losing the rail.
- **A backup that was never restored is not a backup.** Required drill, recorded
  as evidence: restore the snapshot on a *different* host, start `cdk-mintd`
  against it, and assert `GET /v1/keysets` returns the **same keyset IDs** as
  production. Also assert the nostr identity pubkey matches.
- **Retention is a producer setting, not a deletion spree.** The snapshot job
  owns `RETENTION_DAYS`; shrinking it is a separate change made only after the
  off-box copy is verified. A directory that exists is not evidence that a
  backup exists.

## Consequences

- Adding a secret is a two-sided change: write the KV path **and** extend the
  node policy. Extending `fleet-node-x280` is an admin/operator action — from a
  node a valid login returns `403` on the read and there is no `sudo` path.
  Extend, never replace; other services share that policy.
- Each consumer needs an explicit "vault unavailable" behaviour. Default:
  start from the local fallback, log loudly, and surface a health line — do not
  crash-loop.
- A stolen vault snapshot without the unseal shares is useless. **Root on the
  vault host is full compromise** — the vault does not defend against that, and
  no ADR should pretend it does.

## Rejected alternatives

- **Router fetches its seed from the vault at boot.** Rejected: turns a mesh or
  vault outage into "the router cannot take payments", on a device whose job is
  to work when the network is broken.
- **Vault as the only copy of the mint seed.** Rejected: a barrier-key mistake,
  a lost unseal share, or a bad rotation destroys the issuer's ability to redeem
  outstanding ecash — a liability event, not an inconvenience.
- **Storing the mint SQLite in KV.** Rejected: wrong tool; bloats the raft
  backend and has no consistent-snapshot semantics.
