package conformance

import (
	"encoding/json"
	"testing"

	"github.com/OpenTollGate/tollgate-module-basic-go/src/tollwallet/port"
)

// The MintQuoteState wire contract is a PORT contract, not a library one: the
// state travels in the NUT-04 quote JSON and in the persisted quote records, so
// every adapter must speak the same format. These tests live here (not in the
// library-specific set) because they pin values the port package owns.
//
// See src/tollwallet/WIREFORMAT.md for the migration analysis these pin.

func TestMintQuoteStateMarshalJSONEmitsUppercaseStrings(t *testing.T) {
	cases := []struct {
		state port.MintQuoteState
		want  string
	}{
		{port.StateUnpaid, `"UNPAID"`},
		{port.StatePaid, `"PAID"`},
		{port.StateIssued, `"ISSUED"`},
		{port.StatePending, `"PENDING"`},
		{port.StateUnknown, `"UNKNOWN"`},
	}
	for _, tc := range cases {
		got, err := json.Marshal(tc.state)
		if err != nil {
			t.Fatalf("Marshal(%v): %v", tc.state, err)
		}
		if string(got) != tc.want {
			t.Fatalf("Marshal(%d) = %s, want %s", int(tc.state), got, tc.want)
		}
	}
}

func TestMintQuoteStateUnmarshalAcceptsLegacyIntegers(t *testing.T) {
	// Legacy gonuts value-marshaling wrote bare integers (0-4). Production
	// quote records may still contain them, so the port must keep accepting
	// them or an in-flight upgrade would lose paid quotes.
	cases := []struct {
		raw  string
		want port.MintQuoteState
	}{
		{`0`, port.StateUnpaid},
		{`1`, port.StatePaid},
		{`2`, port.StateIssued},
		{`3`, port.StatePending},
		{`4`, port.StateUnknown},
	}
	for _, tc := range cases {
		var got port.MintQuoteState
		if err := json.Unmarshal([]byte(tc.raw), &got); err != nil {
			t.Fatalf("Unmarshal(%s): %v", tc.raw, err)
		}
		if got != tc.want {
			t.Fatalf("Unmarshal(%s) = %v, want %v", tc.raw, got, tc.want)
		}
	}
}

func TestMintQuoteStateUnmarshalAcceptsCanonicalStringsCaseInsensitively(t *testing.T) {
	cases := []struct {
		raw  string
		want port.MintQuoteState
	}{
		{`"UNPAID"`, port.StateUnpaid},
		{`"paid"`, port.StatePaid},
		{`"Paid"`, port.StatePaid},
		{`"issued"`, port.StateIssued},
		{`"PENDING"`, port.StatePending},
		{`"unknown"`, port.StateUnknown},
	}
	for _, tc := range cases {
		var got port.MintQuoteState
		if err := json.Unmarshal([]byte(tc.raw), &got); err != nil {
			t.Fatalf("Unmarshal(%s): %v", tc.raw, err)
		}
		if got != tc.want {
			t.Fatalf("Unmarshal(%s) = %v, want %v", tc.raw, got, tc.want)
		}
	}
}

func TestMintQuoteStateUnmarshalRejectsBadInput(t *testing.T) {
	cases := []struct {
		name string
		raw  string
	}{
		{"integer out of range high", `5`},
		{"integer out of range low", `-1`},
		{"unknown string", `"BOGUS"`},
		{"empty string", `""`},
		{"wrong JSON type", `{}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var got port.MintQuoteState
			if err := json.Unmarshal([]byte(tc.raw), &got); err == nil {
				t.Fatalf("Unmarshal(%s) returned a nil error (got %v)", tc.raw, got)
			}
		})
	}
}

func TestMintQuoteStateStringUnknownIsUppercase(t *testing.T) {
	// gonuts returned lowercase "unknown" for Unknown(4); the port deliberately
	// returns uppercase. This is a spec-compliance cleanup, pinned so the
	// library behaviour cannot leak back in through a refactor.
	if got := port.StateUnknown.String(); got != "UNKNOWN" {
		t.Fatalf("StateUnknown.String() = %q, want %q", got, "UNKNOWN")
	}
	if got := port.MintQuoteState(99).String(); got != "UNKNOWN" {
		t.Fatalf("out-of-range state String() = %q, want %q", got, "UNKNOWN")
	}
}

func TestParseMintQuoteStateRoundTripsEveryState(t *testing.T) {
	for _, s := range []port.MintQuoteState{
		port.StateUnpaid, port.StatePaid, port.StateIssued, port.StatePending, port.StateUnknown,
	} {
		parsed, err := port.ParseMintQuoteState(s.String())
		if err != nil {
			t.Fatalf("ParseMintQuoteState(%q): %v", s.String(), err)
		}
		if parsed != s {
			t.Fatalf("ParseMintQuoteState(%q) = %v, want %v", s.String(), parsed, s)
		}
	}
	if _, err := port.ParseMintQuoteState("NOPE"); err == nil {
		t.Fatal("ParseMintQuoteState(\"NOPE\") returned a nil error")
	}
}

func TestPortSentinelsAreDistinct(t *testing.T) {
	// Adapters match on these; two of them accidentally sharing a value would
	// make errors.Is answer the wrong question in the merchant's payment path.
	sentinels := []struct {
		name string
		err  error
	}{
		{"already-spent", port.ErrTokenAlreadySpent},
		{"locked", port.ErrLockedToken},
		{"not-initialized", port.ErrWalletNotInitialized},
	}
	for i := range sentinels {
		for j := range sentinels {
			if i == j {
				continue
			}
			if sentinels[i].err == sentinels[j].err {
				t.Fatalf("sentinel %s and %s are the same error value", sentinels[i].name, sentinels[j].name)
			}
		}
		if sentinels[i].err.Error() == "" {
			t.Fatalf("sentinel %s has an empty message", sentinels[i].name)
		}
	}
}
