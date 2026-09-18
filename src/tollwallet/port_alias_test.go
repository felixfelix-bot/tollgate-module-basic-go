// LIBRARY-AGNOSTIC TEST SET (T16, wallet-migration).
//
// These tests pin that the port.go shim is a set of type ALIASES rather than
// copies. That distinction is load-bearing: if tollwallet.Token were a distinct
// type, merchant code (which imports tollwallet) would no longer satisfy the
// WalletPort interface, and every adapter written against the dependency-free
// port package would be unusable without an adapter layer.
//
// No wallet library is imported here.
//
// Split list / evidence: research/wallet-migration/03-baseline/interchangeability.md
package tollwallet

import (
	"errors"
	"fmt"
	"reflect"
	"testing"

	"github.com/OpenTollGate/tollgate-module-basic-go/src/tollwallet/port"
)

func TestPortAliasesAreIdenticalTypes(t *testing.T) {
	cases := []struct {
		name string
		impl reflect.Type
		port reflect.Type
	}{
		{"Token", reflect.TypeOf((*Token)(nil)).Elem(), reflect.TypeOf((*port.Token)(nil)).Elem()},
		{"WalletPort", reflect.TypeOf((*WalletPort)(nil)).Elem(), reflect.TypeOf((*port.WalletPort)(nil)).Elem()},
		{"MintQuoteState", reflect.TypeOf(MintQuoteState(0)), reflect.TypeOf(port.MintQuoteState(0))},
		{"MintQuote", reflect.TypeOf(MintQuote{}), reflect.TypeOf(port.MintQuote{})},
		{"MeltQuote", reflect.TypeOf(MeltQuote{}), reflect.TypeOf(port.MeltQuote{})},
		{"MeltResult", reflect.TypeOf(MeltResult{}), reflect.TypeOf(port.MeltResult{})},
	}
	for _, tc := range cases {
		if tc.impl != tc.port {
			t.Fatalf("tollwallet.%s is NOT identical to port.%s (%v vs %v): the shim must be an alias, not a copy",
				tc.name, tc.name, tc.impl, tc.port)
		}
	}
}

func TestPortSentinelAliasesPreserveIdentity(t *testing.T) {
	cases := []struct {
		name string
		impl error
		port error
	}{
		{"ErrTokenAlreadySpent", ErrTokenAlreadySpent, port.ErrTokenAlreadySpent},
		{"ErrLockedToken", ErrLockedToken, port.ErrLockedToken},
		{"ErrWalletNotInitialized", ErrWalletNotInitialized, port.ErrWalletNotInitialized},
	}
	for _, tc := range cases {
		if tc.impl != tc.port {
			t.Fatalf("tollwallet.%s is a different error value than port.%s: errors.Is across the seam would break",
				tc.name, tc.name)
		}
	}

	// The point of identity: an error returned by an adapter that wraps the
	// port sentinel must match the tollwallet name merchant code actually uses.
	wrapped := fmt.Errorf("payment failed: %w", port.ErrTokenAlreadySpent)
	if !errors.Is(wrapped, ErrTokenAlreadySpent) {
		t.Fatal("errors.Is(err-wrapping-port-sentinel, ErrTokenAlreadySpent) = false")
	}
}

func TestPortConstantAliasesMatchPortValues(t *testing.T) {
	cases := []struct {
		name string
		impl MintQuoteState
		port port.MintQuoteState
	}{
		{"StateUnpaid", StateUnpaid, port.StateUnpaid},
		{"StatePaid", StatePaid, port.StatePaid},
		{"StateIssued", StateIssued, port.StateIssued},
		{"StatePending", StatePending, port.StatePending},
		{"StateUnknown", StateUnknown, port.StateUnknown},
	}
	for _, tc := range cases {
		if tc.impl != tc.port {
			t.Fatalf("tollwallet.%s = %d, port.%s = %d", tc.name, tc.impl, tc.name, tc.port)
		}
	}
}

func TestParseMintQuoteStateAliasDelegates(t *testing.T) {
	got, err := ParseMintQuoteState("paid")
	if err != nil {
		t.Fatalf("ParseMintQuoteState(paid): %v", err)
	}
	if got != port.StatePaid {
		t.Fatalf("ParseMintQuoteState(paid) = %v, want StatePaid", got)
	}
	if _, err := ParseMintQuoteState("nope"); err == nil {
		t.Fatal("ParseMintQuoteState(nope) returned a nil error")
	}
}
