package conformance

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"sync"

	"github.com/OpenTollGate/tollgate-module-basic-go/src/tollwallet/port"
)

// FakeWallet is a scripted, in-memory implementation of port.WalletPort.
//
// IT IS NOT A REFERENCE IMPLEMENTATION AND NOT A SUBSTITUTE FOR TESTING A REAL
// ADAPTER. Its job is to let the conformance suite run with zero wallet-library
// imports (proving the suite itself is library-agnostic and internally
// consistent) and to be the template an adapter author copies when wiring a new
// backend. Real wallets reach the mint over HTTP; this one is told what to do
// via MintMode, mirroring the MintDouble.
type FakeWallet struct {
	mu        sync.Mutex
	mintURL   string
	mode      MintMode
	balance   uint64
	quotes    map[string]uint64
	shutdowns int
	registry  map[string]fakeTokenSpec
}

type fakeTokenSpec struct {
	mint   string
	amount uint64
	secret string
}

type fakeToken struct {
	spec   fakeTokenSpec
	closed int
}

func (t *fakeToken) Mint() string   { return t.spec.mint }
func (t *fakeToken) Amount() uint64 { return t.spec.amount }
func (t *fakeToken) Close()         { t.closed++ }
func (t *fakeToken) Serialize() (string, error) {
	return V3Token(t.spec.mint, t.spec.amount, t.spec.secret), nil
}

// NewFakeWallet returns a double accepting tokens from mintURL. The V4 wire
// vector is registered up front because the double does not implement CBOR;
// V3 tokens are decoded generically (the format is base64url JSON).
func NewFakeWallet(mintURL string, mode MintMode) *FakeWallet {
	return &FakeWallet{
		mintURL:  mintURL,
		mode:     mode,
		quotes:   make(map[string]uint64),
		registry: map[string]fakeTokenSpec{V4TokenLiteral: {mint: VectorMint, amount: VectorAmount, secret: "v4-test"}},
	}
}

func (f *FakeWallet) accepts(mint string) bool {
	return strings.EqualFold(strings.TrimRight(mint, "/"), strings.TrimRight(f.mintURL, "/"))
}

// DecodeToken recognises registered wire vectors and otherwise decodes the V3
// format (base64url JSON) with the standard library.
func (f *FakeWallet) DecodeToken(raw string) (port.Token, error) {
	if raw == "" {
		return nil, fmt.Errorf("FakeWallet.DecodeToken: empty token")
	}
	f.mu.Lock()
	spec, ok := f.registry[raw]
	f.mu.Unlock()
	if ok {
		return &fakeToken{spec: spec}, nil
	}
	if !strings.HasPrefix(raw, "cashuA") {
		return nil, fmt.Errorf("FakeWallet.DecodeToken: unsupported token prefix %q", raw[:min(6, len(raw))])
	}
	blob, err := base64.RawURLEncoding.DecodeString(raw[len("cashuA"):])
	if err != nil {
		return nil, fmt.Errorf("FakeWallet.DecodeToken: base64: %w", err)
	}
	var v3 struct {
		Token []struct {
			Mint   string `json:"mint"`
			Proofs []struct {
				Amount uint64 `json:"amount"`
				Secret string `json:"secret"`
			} `json:"proofs"`
		} `json:"token"`
	}
	if err := json.Unmarshal(blob, &v3); err != nil {
		return nil, fmt.Errorf("FakeWallet.DecodeToken: json: %w", err)
	}
	if len(v3.Token) == 0 {
		return nil, fmt.Errorf("FakeWallet.DecodeToken: no token entries")
	}
	spec = fakeTokenSpec{mint: v3.Token[0].Mint}
	for _, p := range v3.Token[0].Proofs {
		spec.amount += p.Amount
		if p.Secret != "" {
			spec.secret = p.Secret // pragma: allowlist secret
		}
	}
	return &fakeToken{spec: spec}, nil
}

// Receive enforces the same contract order a real adapter must: locked proofs
// are refused before mint acceptance is considered, an unaccepted mint is
// refused, and a mint that reports the inputs as spent maps to the sentinel.
func (f *FakeWallet) Receive(t port.Token) (uint64, error) {
	ft, ok := t.(*fakeToken)
	if !ok {
		return 0, fmt.Errorf("FakeWallet.Receive: unexpected token type %T", t)
	}
	if isLockedSecret(ft.spec.secret) {
		return 0, port.ErrLockedToken
	}
	if !f.accepts(ft.spec.mint) {
		return 0, fmt.Errorf("Token rejected. Token for mint %s is not accepted", ft.spec.mint)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	switch f.mode {
	case MintModeSwapSpent:
		return 0, fmt.Errorf("%w: inputs have already been spent", port.ErrTokenAlreadySpent)
	case MintModeSwapGenericError:
		return 0, fmt.Errorf("swap rejected by mint (HTTP 429, code 1000): mint rate limited")
	}
	f.balance += ft.spec.amount
	return ft.spec.amount, nil
}

func (f *FakeWallet) GetBalance() uint64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.balance
}

func (f *FakeWallet) GetBalanceByMint(mintURL string) uint64 {
	if !f.accepts(mintURL) {
		return 0
	}
	return f.GetBalance()
}

func (f *FakeWallet) GetAllMintBalances() map[string]uint64 {
	return map[string]uint64{f.mintURL: f.GetBalance()}
}

func (f *FakeWallet) SendWithOverpayment(amount uint64, mintURL string, _ uint64, _ uint64) (string, error) {
	if !f.accepts(mintURL) {
		return "", fmt.Errorf("FakeWallet: mint %s not accepted", mintURL)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.balance < amount {
		return "", fmt.Errorf("FakeWallet: insufficient balance %d for %d", f.balance, amount)
	}
	f.balance -= amount
	return V3Token(f.mintURL, amount, "sent"), nil
}

func (f *FakeWallet) Send(amount uint64, mintURL string, _ bool) (port.Token, error) {
	if _, err := f.SendWithOverpayment(amount, mintURL, 0, 0); err != nil {
		return nil, err
	}
	return &fakeToken{spec: fakeTokenSpec{mint: f.mintURL, amount: amount, secret: "sent"}}, nil // pragma: allowlist secret
}

func (f *FakeWallet) Drain(mintURL string) (port.Token, uint64, error) {
	balance := f.GetBalanceByMint(mintURL)
	if balance == 0 {
		return nil, 0, fmt.Errorf("FakeWallet: no balance available for mint %s", mintURL)
	}
	t, err := f.Send(balance, mintURL, false)
	return t, balance, err
}

func (f *FakeWallet) MeltToLightning(string, uint64, uint64, string) error { return nil }

func (f *FakeWallet) RequestMintQuote(amount uint64, mintURL string) (*port.MintQuote, error) {
	if !f.accepts(mintURL) {
		return nil, fmt.Errorf("FakeWallet: mint %s not accepted", mintURL)
	}
	f.mu.Lock()
	f.quotes[QuoteID] = amount
	f.mu.Unlock()
	return &port.MintQuote{
		QuoteID: QuoteID,
		Request: Bolt11Placeholder,
		State:   port.StateUnpaid,
		Amount:  amount,
		Expiry:  QuoteExpiry,
	}, nil
}

func (f *FakeWallet) GetMintQuoteState(quoteID string) (port.MintQuoteState, error) {
	f.mu.Lock()
	_, ok := f.quotes[quoteID]
	f.mu.Unlock()
	if !ok {
		return port.StateUnknown, fmt.Errorf("FakeWallet: unknown quote %q", quoteID)
	}
	return port.StatePaid, nil
}

func (f *FakeWallet) MintTokens(quoteID string) (uint64, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	amount, ok := f.quotes[quoteID]
	if !ok {
		return 0, fmt.Errorf("FakeWallet: unknown quote %q", quoteID)
	}
	f.balance += amount
	return amount, nil
}

func (f *FakeWallet) RequestMeltQuote(invoice, mintURL string) (*port.MeltQuote, error) {
	if !f.accepts(mintURL) {
		return nil, fmt.Errorf("FakeWallet: mint %s not accepted", mintURL)
	}
	return &port.MeltQuote{
		QuoteID:    "conformance-melt-1",
		Amount:     10,
		FeeReserve: 1,
		State:      port.StatePaid,
		Expiry:     QuoteExpiry,
	}, nil
}

func (f *FakeWallet) Melt(quoteID string) (*port.MeltResult, error) {
	if quoteID != "conformance-melt-1" {
		return nil, fmt.Errorf("FakeWallet: unknown melt quote %q", quoteID)
	}
	return &port.MeltResult{QuoteID: quoteID, Paid: true, Preimage: "00"}, nil
}

func (f *FakeWallet) Shutdown() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.shutdowns++
	return nil
}

// isLockedSecret is the documented Cashu spending-condition shape: a JSON
// array whose first element names the condition.
func isLockedSecret(secret string) bool {
	return strings.Contains(secret, `["P2PK"`) || strings.Contains(secret, `["HTLC"`)
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
