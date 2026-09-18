// LIBRARY-SPECIFIC TEST SET (T16, wallet-migration).
//
// These tests assert behaviour of the concrete gonuts-tollgate wallet that the
// library-agnostic WalletPort contract cannot express, and they are kept apart
// from the adapter-general suite in src/tollwallet/conformance (which imports no
// wallet library at all). Reason per file below.
//
// Split list / evidence: research/wallet-migration/03-baseline/interchangeability.md
//
// Reason: they call hasLockedProofs(cashu.Proofs) — a unit-level assertion on a
// gonuts-typed helper. The library-independent version of the same contract
// ("a token whose secret is a P2PK/HTLC spending condition is refused with
// port.ErrLockedToken") is asserted generically in the conformance suite's
// receive_contract/locked_proof_rejected case, which runs against this adapter
// as well as any future one.
package tollwallet

import (
	"testing"

	"github.com/OpenTollGate/gonuts-tollgate/cashu"
)

func TestHasSpendingCondition_PlainSecret(t *testing.T) {
	proofs := cashu.Proofs{
		{Amount: 1, Secret: "just-a-plain-secret", C: "02abc"},
	}
	if hasLockedProofs(proofs) {
		t.Fatal("plain secret should not be detected as locked")
	}
}

func TestHasSpendingCondition_P2PKSecret(t *testing.T) {
	proofs := cashu.Proofs{
		{Amount: 1, Secret: `["P2PK",{"nonce":"abc123","data":"","tags":[["pubkeys","02abcdef"]]}]`, C: "02abc"},
	}
	if !hasLockedProofs(proofs) {
		t.Fatal("P2PK secret should be detected as locked")
	}
}

func TestHasSpendingCondition_HTLCSecret(t *testing.T) {
	proofs := cashu.Proofs{
		{Amount: 1, Secret: `["HTLC",{"nonce":"abc123","data":"","tags":[["hash_lock","abcdef"]]}]`, C: "02abc"},
	}
	if !hasLockedProofs(proofs) {
		t.Fatal("HTLC secret should be detected as locked")
	}
}

func TestHasSpendingCondition_MixedProofs(t *testing.T) {
	proofs := cashu.Proofs{
		{Amount: 1, Secret: "plain", C: "02abc"},
		{Amount: 2, Secret: `["P2PK",{"nonce":"abc","data":"","tags":[]}]`, C: "02def"},
	}
	if !hasLockedProofs(proofs) {
		t.Fatal("mixed proofs with one P2PK should be detected as locked")
	}
}
