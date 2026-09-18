//go:build !cdk_wallet

// LIBRARY-SPECIFIC GLUE (T16) — gonuts-tollgate.
//
// This file contains no assertions of its own: it is the handful of lines that
// point the library-agnostic conformance suite (src/tollwallet/conformance) at
// the gonuts adapter. It is the evidence that the suite discriminates a real
// backend rather than agreeing with the scripted FakeWallet that was written
// alongside it — a green run of the same suite against a CDK or nucula adapter
// is the other half of that evidence, and needs no new assertions, only this
// file's equivalent.
//
// It is library-specific by construction: it names the gonuts adapter and is
// therefore excluded under the cdk_wallet build tag.
//
// See research/wallet-migration/03-baseline/interchangeability.md.
package tollwallet

import (
	"testing"

	"github.com/OpenTollGate/tollgate-module-basic-go/src/tollwallet/conformance"
	"github.com/OpenTollGate/tollgate-module-basic-go/src/tollwallet/port"
)

// TestGonutsAdapterPassesPortConformance runs the shared wallet-port contract
// suite against the default (gonuts-tollgate) adapter.
func TestGonutsAdapterPassesPortConformance(t *testing.T) {
	conformance.RunPortConformance(t, conformance.Fixture{
		Name: "gonuts",
		NewWallet: func(t *testing.T, dir string, mintURL string, _ conformance.MintMode) (port.WalletPort, error) {
			// The MintDouble carries the behaviour (spent swap, quote states)
			// over HTTP, so the mode argument is ignored here.
			return NewWalletPort(dir, []string{mintURL}, false)
		},
		NewUninitialized: func(t *testing.T) (port.WalletPort, error) {
			// The degraded-mode shape merchant code can actually encounter: a
			// GonutsWallet wrapping a TollWallet whose provider failed to load.
			return &GonutsWallet{inner: &TollWallet{}}, nil
		},
		SkipMeltReason: "GonutsWallet.RequestMeltQuote/Melt return \"not yet wired\"; " +
			"TollWallet exposes only the higher-level MeltToLightning, which needs a " +
			"Lightning address resolver. Wiring the melt pair is a port-completeness " +
			"gap recorded in the T16 split list, not a regression.",
	})
}
