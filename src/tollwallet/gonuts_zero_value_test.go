// LIBRARY-SPECIFIC TEST SET (T16, wallet-migration).
//
// These tests assert behaviour of the concrete gonuts-tollgate wallet that the
// library-agnostic WalletPort contract cannot express, and they are kept apart
// from the adapter-general suite in src/tollwallet/conformance (which imports no
// wallet library at all). Reason per file below.
//
// Split list / evidence: research/wallet-migration/03-baseline/interchangeability.md
//
// Reason: they construct the gonuts adapter's zero value (a *TollWallet with a
// nil *wallet.Wallet) directly. The library-independent half of the same
// contract — "a degraded adapter returns ErrWalletNotInitialized instead of
// panicking, and Shutdown stays safe" — is asserted for every adapter by the
// conformance suite's lifecycle_contract/uninitialized_wallet_returns_sentinel
// case, which runs against this adapter too.
package tollwallet

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestShutdown_NilWallet_NoPanic(t *testing.T) {
	w := &TollWallet{wallet: nil}
	err := w.Shutdown()
	assert.NoError(t, err)
}

func TestGetMintQuoteState_NilWallet_ReturnsError(t *testing.T) {
	w := &TollWallet{wallet: nil}
	resp, err := w.GetMintQuoteState("quote-id")
	assert.Nil(t, resp)
	assert.ErrorIs(t, err, ErrWalletNotInitialized,
		"GetMintQuoteState on an uninitialized wallet must return ErrWalletNotInitialized, not panic")
}
