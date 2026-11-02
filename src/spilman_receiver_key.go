package main

// The payee's Spilman receiver key: what it advertises, and what it will accept.
//
// # Why this is derived, not generated
//
// A Spilman channel is addressed to a receiver key, and settlement requires signing
// with it. This helper does not wire a settlement signer. If that key changes,
// every channel opened before it changed becomes
// uncloseable — the funding is already at the mint and only that key can release it.
// So the key must come from material that already survives a restart.
//
// This module already persists exactly such material: `identities.json` holds an
// owned `merchant` private key (config_manager_identities.go), created once on first
// boot and reused forever. Deriving the Spilman receiver key from it means:
//
//   - no new file, no new permission story, no new backup obligation;
//   - it cannot silently rotate, because the merchant identity does not;
//   - restoring the router's identity (which an operator already must do) restores
//     the ability to settle its channels.
//
// # Why a DOMAIN-TAGGED derivation instead of the raw merchant key
//
// The receiver pubkey is published in cleartext on `/spilman/params`. Using the
// merchant key directly would make that endpoint an oracle for the router's Nostr
// identity: the compressed secp256k1 key shares its x-coordinate with the x-only
// npub, so anyone could link "this router's payment rail" to "this router's Nostr
// pubkey" and to the Lightning address beside it.
//
// Deriving with a fixed domain tag gives an unlinkable key that is still a pure
// function of the persisted identity — stable across restarts, unrelated to the
// npub, and impossible to confuse with the merchant key itself.

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"

	"github.com/btcsuite/btcd/btcec/v2"
)

// spilmanReceiverKeyTag is the domain separator for the derivation.
//
// It is part of the key's definition: changing this string changes every router's
// receiver key, which orphans every open channel. Treat it as a constant of the
// protocol, not a naming choice.
const spilmanReceiverKeyTag = "tollgate/spilman/receiver/v2"

// deriveReceiverKey derives the Spilman receiver private key from the payee's
// merchant secret.
//
// Deterministic: the same valid merchant key always yields the same receiver
// key, which is the whole point. A merchant key that is not a valid secp256k1
// scalar is an error rather than a silent zero.
func deriveReceiverKey(merchantPrivHex string) (*btcec.PrivateKey, error) {
	raw, err := hex.DecodeString(strings.TrimSpace(merchantPrivHex))
	if err != nil {
		return nil, fmt.Errorf("merchant private key is not hex: %w", err)
	}
	if len(raw) != 32 {
		return nil, fmt.Errorf("merchant private key must be 32 bytes, got %d", len(raw))
	}
	// Reject invalid inputs before any conversion that could reduce modulo N.
	var merchantScalar btcec.ModNScalar
	if overflow := merchantScalar.SetByteSlice(raw); overflow || merchantScalar.IsZero() {
		return nil, fmt.Errorf("merchant private key must be a nonzero scalar below the curve order")
	}
	// HMAC key is the persisted SECRET, never its publicly advertised pubkey.
	// v2 intentionally breaks compatibility with the compromised public v1 derivation.
	h := hmac.New(sha256.New, raw)
	h.Write([]byte(spilmanReceiverKeyTag))
	tagged := h.Sum(nil)
	// Fail closed for the negligible out-of-range output case; never reduce.
	scalar := new(btcec.ModNScalar)
	if overflow := scalar.SetByteSlice(tagged); overflow || scalar.IsZero() {
		return nil, fmt.Errorf("derived receiver scalar is out of range; refusing to guess")
	}
	var priv btcec.PrivateKey
	priv.Key = *scalar
	return &priv, nil
}

// spilmanReceiverPubkeyHex returns the compressed-hex receiver pubkey this payee
// advertises and accepts, or "" when no merchant identity is available.
//
// "" is the fail-closed answer and it must NOT be papered over: a payee with no key
// cannot sign a close, so it must not advertise one, and it must not accept a
// channel. Callers distinguish "" from a real key and refuse.
func spilmanReceiverPubkeyHex() string {
	if configManager == nil {
		return ""
	}
	identities := configManager.GetIdentities()
	if identities == nil {
		return ""
	}
	owned, err := identities.GetOwnedIdentity("merchant")
	if err != nil || owned == nil {
		return ""
	}
	priv, err := deriveReceiverKey(owned.PrivateKey)
	if err != nil {
		mainLogger.WithError(err).Error("spilman: cannot derive the receiver key")
		return ""
	}
	return hex.EncodeToString(priv.PubKey().SerializeCompressed())
}

// requireOwnReceiverKey refuses a registration addressed to a key this payee does
// not hold.
//
// # Why this is a refusal and not a warning
//
// The channel is already funded at the mint when this runs. Accepting it means the
// payee has taken responsibility for value it can never release, and the payer sees
// a successful registration right up until the close fails. There is no partial
// success worth having here.
//
// # The keyless case
//
// No merchant identity means no key to compare against, and therefore no honest way
// to say "yes". It refuses for the same reason: a payee that cannot sign a close must
// not accept a channel.
func requireOwnReceiverKey(offered string) error {
	ours := spilmanReceiverPubkeyHex()
	if ours == "" {
		return fmt.Errorf("this payee has no receiver key and cannot settle a channel; " +
			"refusing the registration rather than stranding the funding")
	}
	if !strings.EqualFold(strings.TrimSpace(offered), ours) {
		return fmt.Errorf("receiver_pubkey %q is not this payee's (%s); a channel for "+
			"another key can never be settled here", offered, ours)
	}
	return nil
}
