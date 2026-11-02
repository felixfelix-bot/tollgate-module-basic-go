# Spilman receiver identity and security boundary

The Go receiver key is HMAC-SHA256 with the decoded 32-byte merchant private
scalar as the HMAC key and UTF-8 `tollgate/spilman/receiver/v2` as its message
(no terminator). Inputs must be nonzero and strictly below the secp256k1
order. Neither inputs nor outputs are silently reduced modulo the order;
a zero or out-of-range output fails closed. Hex case and surrounding
whitespace do not change the identity.

The merchant identity is persisted in `identities.json`. Reusing those exact
secret bytes reproduces the receiver key; rotating or losing them changes or
loses that identity. The executable regression restores a synthetic merchant
input from disk; it is not a process-restart or application-startup E2E test.

## Compatibility and funds warning

The previous v1 algorithm hashed the merchant **public** compressed key into
a private scalar. That scalar is publicly computable and must be treated as
compromised. v2 deliberately changes the receiver identity. There is no
fallback to v1 and no automatic migration for already funded v1 channels.
Do not advertise old channels as safe or assume this patch recovers them.
Do not fund channels on this development rail pending settlement and
funding-policy review.

This is a pure local derivation: no irreversible action, durable write,
network request, counter reservation, or compensation occurs here. Repeated
calls/restarts with the same persisted input are idempotent. Funding at the
mint is the external point of no return; this helper does not journal or
recover that transaction. Preserve existing identity and channel records;
recovery/migration of compromised channels needs separate operator review.

## Wiring limitations (not fixed by this change)

- The only production caller of `deriveReceiverKey` is
  `spilmanReceiverPubkeyHex`; HTTP parameters advertise its public key and
  registration compares the offered receiver with that value. No production
  close signer consumes the derived private key.
- `src/spilman/rail_cgo.go` constructs `cgoValidatorHost` without populating
  `receiverPubkey`, so its receiver-policy callback rejects all keys when
  invoked. Its comment claiming caller-supplied identity is not accurate.
- The same host's signing, ECDH and mint-swap callbacks refuse as
  validation-only. Cooperative close and unilateral close data return
  `ErrSellerBridgeUnwired`; the default stub also cannot settle.
- `MintAndKeysetIsAcceptable` returns true. Its comment claims configuration
  policy enforcement in HTTP registration, but that handler only checks the
  receiver before passing supplied mint/keyset/funding data to the rail.
  Do not treat that comment as evidence of trusted mint/keyset policy.

Unit verification of derivation is not proof of settlement safety, cgo-path
integration, router behavior, or crash-safe money movement.
