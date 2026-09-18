package conformance

import (
	"testing"

	"github.com/OpenTollGate/tollgate-module-basic-go/src/tollwallet/port"
)

// TestSuiteAgainstFakeWallet runs the whole conformance suite against the
// scripted in-memory double. This is the proof that the SUITE is
// library-agnostic: this package's import graph is the standard library plus
// the dependency-free port package, so a green run here means no assertion in
// the suite needs gonuts-tollgate, cdk-go or nucula.
//
//	cd src/tollwallet && go list -deps ./conformance/... | grep -c gonuts   # 0
//
// The complementary evidence — that the suite actually discriminates a real
// adapter rather than agreeing with a double written to match it — comes from
// running the same suite against the gonuts adapter in
// src/tollwallet/port_conformance_glue_test.go.
func TestSuiteAgainstFakeWallet(t *testing.T) {
	RunPortConformance(t, Fixture{
		Name: "fake",
		NewWallet: func(t *testing.T, _ string, mintURL string, mode MintMode) (port.WalletPort, error) {
			return NewFakeWallet(mintURL, mode), nil
		},
		NewUninitialized: func(t *testing.T) (port.WalletPort, error) {
			return &uninitializedFake{FakeWallet: NewFakeWallet("https://testmint.example.com", MintModeHealthy)}, nil
		},
	})
}

// uninitializedFake is the double's degraded-mode shape: every wallet operation
// must return port.ErrWalletNotInitialized rather than panicking.
type uninitializedFake struct {
	*FakeWallet
}

func (u *uninitializedFake) GetMintQuoteState(string) (port.MintQuoteState, error) {
	return port.StateUnknown, port.ErrWalletNotInitialized
}

func (u *uninitializedFake) Receive(port.Token) (uint64, error) {
	return 0, port.ErrWalletNotInitialized
}
