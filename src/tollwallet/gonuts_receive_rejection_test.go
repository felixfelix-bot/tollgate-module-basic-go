// LIBRARY-SPECIFIC TEST SET (T16, wallet-migration).
//
// These tests assert behaviour of the concrete gonuts-tollgate wallet that the
// library-agnostic WalletPort contract cannot express, and they are kept apart
// from the adapter-general suite in src/tollwallet/conformance (which imports no
// wallet library at all). Reason per file below.
//
// Split list / evidence: research/wallet-migration/03-baseline/interchangeability.md
//
// Reason: the case constructs the concrete *TollWallet with hand-set
// acceptedMints and a nil provider, so it asserts the gonuts adapter's
// rejection ORDER (locked proofs and unaccepted mints are refused before the
// provider is touched). The same contract, expressed through the port, is
// asserted for every adapter by the conformance suite's
// receive_contract/unaccepted_mint_rejected case.
package tollwallet

import (
	"testing"

	"github.com/OpenTollGate/gonuts-tollgate/cashu"
	"github.com/stretchr/testify/assert"
)

// testToken is a minimal cashu.Token used by the concrete-adapter tests below.
type testToken struct {
	mintURL string
}

func (t *testToken) Mint() string               { return t.mintURL }
func (t *testToken) Proofs() cashu.Proofs       { return cashu.Proofs{} }
func (t *testToken) Amount() uint64             { return 100 }
func (t *testToken) Serialize() (string, error) { return "test-token", nil }

func createTestToken(mint string) cashu.Token {
	return &testToken{mintURL: mint}
}

func TestReceive_DirectRejectionOfUnacceptedMint(t *testing.T) {
	// Create a manually constructed TollWallet with fields we control
	tollWallet := &TollWallet{
		// wallet is nil, but we won't use it for this test
		acceptedMints:              []string{"https://accepted-mint.com"},
		allowAndSwapUntrustedMints: false,
	}

	// Create test token from unaccepted mint
	token := createTestToken("https://unaccepted-mint.com")

	// Call the function being tested - should reject before trying to use wallet
	_, err := tollWallet.Receive(token)

	// Assert expectations
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "Token rejected")
}
