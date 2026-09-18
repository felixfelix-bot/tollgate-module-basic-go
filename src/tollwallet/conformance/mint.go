package conformance

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// Wire vectors. These are spec artifacts (the Cashu token/keyset wire format),
// not library artifacts: they are frozen literals so the suite can assert what
// an adapter must accept without asking any library to produce them.
const (
	// VectorKeysetID is a NUT-02 V1 keyset id (8 bytes hex, 16 chars).
	VectorKeysetID = "009a1f293253e41e" // pragma: allowlist secret
	// VectorPoint is a valid compressed secp256k1 point (the generator G).
	VectorPoint = "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798" // pragma: allowlist secret
	// VectorMint is the mint URL embedded in the V4 literal vector.
	VectorMint = "https://testmint.example.com"
	// VectorAmount is the amount (in sat) of the single proof in the vectors.
	VectorAmount uint64 = 1

	// V4TokenLiteral is a Cashu V4 token ("cashuB" + base64url CBOR) carrying
	// one 1-sat proof from VectorMint with VectorKeysetID. It was generated
	// once from the spec by a Cashu encoder (see
	// research/wallet-migration/03-baseline/interchangeability.md) and frozen
	// here as a literal so the suite needs no encoder to assert V4 acceptance.
	V4TokenLiteral = "cashuBo2F0gaJhaUgAmh8pMlPkHmFwgaNhYQFhc2d2NC10ZXN0YWNYIQJ5vmZ--dy7rFWgYpXOhwsHApv82y3OKNlZ8oFbFvgXmGFteBxodHRwczovL3Rlc3RtaW50LmV4YW1wbGUuY29tYXVjc2F0" // pragma: allowlist secret gitleaks:allow
)

// V3Token hand-encodes a Cashu V3 token ("cashuA" + base64url JSON) with a
// single proof. The V3 format is plain base64url(JSON) per the Cashu spec, so
// no wallet library is needed to build one.
func V3Token(mint string, amount uint64, secret string) string {
	payload := map[string]any{
		"token": []map[string]any{
			{
				"mint": mint,
				"proofs": []map[string]any{
					{"amount": amount, "id": VectorKeysetID, "secret": secret, "C": VectorPoint}, // pragma: allowlist secret
				},
			},
		},
		"unit": "sat",
	}
	data, err := json.Marshal(payload)
	if err != nil {
		panic(fmt.Sprintf("conformance: marshal V3 token: %v", err))
	}
	return "cashuA" + base64.RawURLEncoding.EncodeToString(data)
}

// MintMode selects how the MintDouble answers the calls a wallet makes while
// the port contract is exercised.
type MintMode int

const (
	// MintModeHealthy serves keys and keysets and answers quote requests.
	MintModeHealthy MintMode = iota
	// MintModeSwapSpent answers POST /v1/swap with HTTP 400 code 3 phrased the
	// CDK way ("inputs have already been spent"). An adapter's Receive MUST map
	// this to port.ErrTokenAlreadySpent.
	MintModeSwapSpent
	// MintModeSwapGenericError answers POST /v1/swap with an unrelated mint
	// failure. Receive MUST NOT map it to ErrTokenAlreadySpent. Negative
	// control against "map every swap failure to already-spent" regressions.
	MintModeSwapGenericError
)

// mintKeysetsJSON is the NUT-01/NUT-02 keys response. The same document is
// served for /v1/keys and /v1/keysets because it carries both the "keys" and
// the "active" fields (the shape proven against the gonuts wallet loader).
const mintKeysetsJSON = `{"keysets":[{"id":"` + VectorKeysetID + `","unit":"sat","active":true,` +
	`"keys":{"1":"` + VectorPoint + `"}}]}`

// MintDouble is a minimal in-process Cashu mint: enough of NUT-01/02 (keys),
// NUT-03 (swap, as a controlled failure), and NUT-04 (mint quote) for a real
// adapter to start up, ask for a quote, and be told its token was already
// spent. It cannot sign, so it deliberately never returns a successful swap or
// mint — a conformance suite that needs real signatures needs a real mint.
type MintDouble struct {
	srv *httptest.Server

	mu        sync.Mutex
	mode      MintMode
	swapCalls int
	t         *testing.T
}

// NewMintDouble starts the double. It is closed automatically at test cleanup.
func NewMintDouble(t *testing.T, mode MintMode) *MintDouble {
	t.Helper()
	m := &MintDouble{mode: mode, t: t}
	m.srv = httptest.NewServer(http.HandlerFunc(m.handle))
	t.Cleanup(m.srv.Close)
	return m
}

// URL is the base URL an adapter should be configured with.
func (m *MintDouble) URL() string { return m.srv.URL }

// SetMode changes the double's behaviour for subsequent calls.
func (m *MintDouble) SetMode(mode MintMode) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.mode = mode
}

// SwapCalls reports how many times /v1/swap was requested, so a case can prove
// the adapter actually reached the mint rather than failing client-side.
func (m *MintDouble) SwapCalls() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.swapCalls
}

func (m *MintDouble) handle(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.URL.Path == "/v1/keys" || r.URL.Path == "/v1/keysets":
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, mintKeysetsJSON)

	case r.URL.Path == "/v1/info":
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"version":"Nutshell/0.16.0","nuts":{"4":{"methods":[["bolt11","sat"]]}}}`)

	case r.URL.Path == "/v1/swap":
		m.mu.Lock()
		m.swapCalls++
		mode := m.mode
		m.mu.Unlock()
		switch mode {
		case MintModeSwapSpent:
			http.Error(w, `{"code":3,"detail":"inputs have already been spent"}`, http.StatusBadRequest)
		case MintModeSwapGenericError:
			http.Error(w, `{"code":1000,"detail":"mint rate limited"}`, http.StatusTooManyRequests)
		default:
			// No signing capability: the key responses are static, so a swap
			// that got this far cannot be completed correctly.
			http.Error(w, `{"code":1000,"detail":"mint double cannot sign"}`, http.StatusBadRequest)
		}

	case r.URL.Path == "/v1/mint/quote/bolt11" || strings.HasPrefix(r.URL.Path, "/v1/mint/quote/bolt11/"):
		// POST /v1/mint/quote/bolt11 → UNPAID; GET .../{quote_id} → PAID, so a
		// caller can observe the NUT-04 state transition through the port.
		state := "UNPAID"
		if r.Method == http.MethodGet || strings.HasPrefix(r.URL.Path, "/v1/mint/quote/bolt11/") {
			state = "PAID"
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"quote":"%s","request":"%s","state":"%s","expiry":%d,"amount":%d}`,
			QuoteID, Bolt11Placeholder, state, QuoteExpiry, QuoteAmount)

	default:
		m.t.Logf("conformance MintDouble: unexpected request %s %s (answering 404)", r.Method, r.URL.Path)
		http.Error(w, `{"code":404,"detail":"not found"}`, http.StatusNotFound)
	}
}

// Quote fixtures served by the double.
const (
	// QuoteID is the mint quote id the double issues.
	QuoteID = "conformance-quote-1"
	// QuoteExpiry is a fixed expiry (unix seconds) far in the future.
	QuoteExpiry = 4000000000
	// QuoteAmount is the quoted amount in sat.
	QuoteAmount uint64 = 1000
	// Bolt11Placeholder is a syntactically bolt11-shaped request. The double
	// cannot produce a real invoice; see MintDouble's doc comment.
	Bolt11Placeholder = "lnbc10u1p3conformanceplaceholder0000000000000000000000000000000000000000"
)
