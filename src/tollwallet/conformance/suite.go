package conformance

import (
	"errors"
	"strings"
	"testing"

	"github.com/OpenTollGate/tollgate-module-basic-go/src/tollwallet/port"
)

// VectorUnacceptedMint is a mint URL no fixture is configured to accept.
const VectorUnacceptedMint = "https://unaccepted.example.com"

// P2PKSecret pins a NUT-10/NUT-11 spending-condition wire vector: a token
// carrying it is not spendable by the gateway and must be refused with
// port.ErrLockedToken.
const P2PKSecret = `["P2PK",{"nonce":"conformance","data":"","tags":[["pubkeys","02abcdef"]]}]` // pragma: allowlist secret

// Fixture describes one wallet adapter under test.
type Fixture struct {
	// Name labels the run (e.g. "gonuts", "cdk", "fake").
	Name string
	// NewWallet returns a fresh adapter bound to mintURL, with dir as its state
	// directory. mode mirrors the MintDouble's behaviour for adapters that are
	// scripted rather than networked (real adapters can ignore it: they learn
	// the mode by talking to the double).
	NewWallet func(t *testing.T, dir string, mintURL string, mode MintMode) (port.WalletPort, error)
	// NewUninitialized optionally returns a zero-value/degraded adapter, used to
	// pin the "return a sentinel, never panic" contract. Nil skips that case.
	NewUninitialized func(t *testing.T) (port.WalletPort, error)
	// SkipMeltReason documents an adapter that does not implement
	// RequestMeltQuote/Melt yet. The melt happy path is then skipped with this
	// text as the reason, and the "returns an error, does not panic" half is
	// still asserted.
	SkipMeltReason string
}

// RunPortConformance runs the full wallet-port contract suite against fx.
//
// Every assertion is expressed through port.WalletPort, the Cashu wire format
// and the port sentinels — never through a library type — so the same suite can
// be pointed at any backend.
func RunPortConformance(t *testing.T, fx Fixture) {
	t.Helper()
	if fx.NewWallet == nil {
		t.Fatalf("conformance: Fixture %q has no NewWallet", fx.Name)
	}
	name := fx.Name
	if name == "" {
		name = "adapter"
	}
	t.Run(name, func(t *testing.T) {
		t.Run("token_contract", func(t *testing.T) { runTokenContract(t, fx) })
		t.Run("receive_contract", func(t *testing.T) { runReceiveContract(t, fx) })
		t.Run("balance_contract", func(t *testing.T) { runBalanceContract(t, fx) })
		t.Run("send_contract", func(t *testing.T) { runSendContract(t, fx) })
		t.Run("mint_quote_contract", func(t *testing.T) { runMintQuoteContract(t, fx) })
		t.Run("melt_contract", func(t *testing.T) { runMeltContract(t, fx) })
		t.Run("lifecycle_contract", func(t *testing.T) { runLifecycleContract(t, fx) })
	})
}

// newWallet builds an adapter against a fresh MintDouble in the given mode.
func newWallet(t *testing.T, fx Fixture, mode MintMode) (port.WalletPort, *MintDouble) {
	t.Helper()
	mint := NewMintDouble(t, mode)
	w, err := fx.NewWallet(t, t.TempDir(), mint.URL(), mode)
	if err != nil {
		t.Fatalf("%s: NewWallet(mint=%s, mode=%v): %v", fx.Name, mint.URL(), mode, err)
	}
	if w == nil {
		t.Fatalf("%s: NewWallet returned a nil wallet", fx.Name)
	}
	t.Cleanup(func() { _ = w.Shutdown() })
	return w, mint
}

func decode(t *testing.T, w port.WalletPort, raw string) port.Token {
	t.Helper()
	tk, err := w.DecodeToken(raw)
	if err != nil {
		t.Fatalf("DecodeToken(%q): %v", truncate(raw), err)
	}
	if tk == nil {
		t.Fatal("DecodeToken returned a nil token with a nil error")
	}
	t.Cleanup(tk.Close)
	return tk
}

func runTokenContract(t *testing.T, fx Fixture) {
	w, _ := newWallet(t, fx, MintModeHealthy)

	t.Run("decode_v3_vector", func(t *testing.T) {
		tk := decode(t, w, V3Token(VectorMint, VectorAmount, "v3-contract"))
		if got := tk.Mint(); got != VectorMint {
			t.Fatalf("Mint() = %q, want %q", got, VectorMint)
		}
		if got := tk.Amount(); got != VectorAmount {
			t.Fatalf("Amount() = %d, want %d", got, VectorAmount)
		}
	})

	t.Run("decode_v4_vector", func(t *testing.T) {
		tk := decode(t, w, V4TokenLiteral)
		if got := tk.Mint(); got != VectorMint {
			t.Fatalf("Mint() = %q, want %q", got, VectorMint)
		}
		if got := tk.Amount(); got != VectorAmount {
			t.Fatalf("Amount() = %d, want %d", got, VectorAmount)
		}
	})

	t.Run("decode_rejects_empty_string", func(t *testing.T) {
		if _, err := w.DecodeToken(""); err == nil {
			t.Fatal("DecodeToken(\"\") returned a nil error")
		}
	})

	t.Run("decode_rejects_garbage", func(t *testing.T) {
		if _, err := w.DecodeToken("not-a-cashu-token"); err == nil {
			t.Fatal("DecodeToken(garbage) returned a nil error")
		}
	})

	t.Run("decode_rejects_unknown_prefix", func(t *testing.T) {
		if _, err := w.DecodeToken("cashuZ0000"); err == nil {
			t.Fatal("DecodeToken(cashuZ…) returned a nil error")
		}
	})

	t.Run("serialize_roundtrip", func(t *testing.T) {
		tk := decode(t, w, V3Token(VectorMint, VectorAmount, "roundtrip"))
		s, err := tk.Serialize()
		if err != nil {
			t.Fatalf("Serialize: %v", err)
		}
		if !strings.HasPrefix(s, "cashu") {
			t.Fatalf("Serialize() = %q, want a cashu… prefix", truncate(s))
		}
		again := decode(t, w, s)
		if again.Mint() != tk.Mint() || again.Amount() != tk.Amount() {
			t.Fatalf("round-trip changed the token: mint %q→%q, amount %d→%d",
				tk.Mint(), again.Mint(), tk.Amount(), again.Amount())
		}
	})

	t.Run("close_is_idempotent", func(t *testing.T) {
		tk := decode(t, w, V3Token(VectorMint, VectorAmount, "close"))
		tk.Close()
		tk.Close()
		tk.Close()
	})
}

func runReceiveContract(t *testing.T, fx Fixture) {
	t.Run("unaccepted_mint_rejected", func(t *testing.T) {
		w, _ := newWallet(t, fx, MintModeHealthy)
		tk := decode(t, w, V3Token(VectorUnacceptedMint, 1, "unaccepted"))
		_, err := w.Receive(tk)
		if err == nil {
			t.Fatalf("Receive of a token from %s returned a nil error", VectorUnacceptedMint)
		}
		if errors.Is(err, port.ErrTokenAlreadySpent) {
			t.Fatalf("an unaccepted mint must not be reported as already spent: %v", err)
		}
	})

	t.Run("locked_proof_rejected", func(t *testing.T) {
		w, _ := newWallet(t, fx, MintModeHealthy)
		tk := decode(t, w, V3Token(VectorMint, 1, P2PKSecret))
		_, err := w.Receive(tk)
		if !errors.Is(err, port.ErrLockedToken) {
			t.Fatalf("Receive of a P2PK-locked token: err = %v, want errors.Is(err, port.ErrLockedToken)", err)
		}
	})

	t.Run("spent_token_maps_to_already_spent_sentinel", func(t *testing.T) {
		w, mint := newWallet(t, fx, MintModeSwapSpent)
		tk := decode(t, w, V3Token(mint.URL(), 1, "sentinel-e2e-secret"))
		_, err := w.Receive(tk)
		if !errors.Is(err, port.ErrTokenAlreadySpent) {
			t.Fatalf("mint answered \"inputs have already been spent\"; Receive: err = %v, want errors.Is(err, port.ErrTokenAlreadySpent)", err)
		}
	})

	t.Run("other_swap_failure_is_not_already_spent", func(t *testing.T) {
		w, mint := newWallet(t, fx, MintModeSwapGenericError)
		tk := decode(t, w, V3Token(mint.URL(), 1, "rate-limited"))
		_, err := w.Receive(tk)
		if err == nil {
			t.Fatal("Receive against a failing mint returned a nil error")
		}
		if errors.Is(err, port.ErrTokenAlreadySpent) {
			t.Fatalf("a non-spent mint failure must not be mapped to ErrTokenAlreadySpent: %v", err)
		}
	})
}

func runBalanceContract(t *testing.T, fx Fixture) {
	w, mint := newWallet(t, fx, MintModeHealthy)

	t.Run("fresh_wallet_reports_zero", func(t *testing.T) {
		if got := w.GetBalance(); got != 0 {
			t.Fatalf("GetBalance() = %d, want 0", got)
		}
		if got := w.GetBalanceByMint(mint.URL()); got != 0 {
			t.Fatalf("GetBalanceByMint(%s) = %d, want 0", mint.URL(), got)
		}
		for url, bal := range w.GetAllMintBalances() {
			if bal != 0 {
				t.Fatalf("GetAllMintBalances()[%s] = %d, want 0", url, bal)
			}
		}
	})

	t.Run("unknown_mint_balance_is_zero", func(t *testing.T) {
		if got := w.GetBalanceByMint("https://never-seen.example.com"); got != 0 {
			t.Fatalf("GetBalanceByMint(unknown) = %d, want 0", got)
		}
	})
}

func runSendContract(t *testing.T, fx Fixture) {
	w, mint := newWallet(t, fx, MintModeHealthy)

	t.Run("send_beyond_balance_errors", func(t *testing.T) {
		tk, err := w.Send(1, mint.URL(), false)
		if err == nil {
			t.Fatalf("Send(1) on an empty wallet returned a nil error (token %v)", tk)
		}
		if tk != nil {
			t.Fatalf("Send on an empty wallet returned a non-nil token on error")
		}
	})

	t.Run("drain_empty_mint_errors", func(t *testing.T) {
		tk, amount, err := w.Drain(mint.URL())
		if err == nil {
			t.Fatalf("Drain on an empty wallet returned a nil error (token %v, amount %d)", tk, amount)
		}
		if tk != nil || amount != 0 {
			t.Fatalf("Drain on an empty wallet returned token=%v amount=%d, want nil/0", tk, amount)
		}
	})
}

func runMintQuoteContract(t *testing.T, fx Fixture) {
	w, mint := newWallet(t, fx, MintModeHealthy)

	t.Run("request_quote_returns_unpaid_quote", func(t *testing.T) {
		q, err := w.RequestMintQuote(QuoteAmount, mint.URL())
		if err != nil {
			t.Fatalf("RequestMintQuote: %v", err)
		}
		if q == nil {
			t.Fatal("RequestMintQuote returned a nil quote with a nil error")
		}
		if q.QuoteID == "" {
			t.Fatal("quote.QuoteID is empty")
		}
		if q.State != port.StateUnpaid {
			t.Fatalf("quote.State = %v (%s), want StateUnpaid", q.State, q.State)
		}
		if q.Amount != QuoteAmount {
			t.Fatalf("quote.Amount = %d, want %d", q.Amount, QuoteAmount)
		}
	})

	t.Run("quote_state_transitions_to_paid", func(t *testing.T) {
		q, err := w.RequestMintQuote(QuoteAmount, mint.URL())
		if err != nil {
			t.Fatalf("RequestMintQuote: %v", err)
		}
		state, err := w.GetMintQuoteState(q.QuoteID)
		if err != nil {
			t.Fatalf("GetMintQuoteState(%s): %v", q.QuoteID, err)
		}
		if state != port.StatePaid {
			t.Fatalf("GetMintQuoteState(%s) = %v (%s), want StatePaid", q.QuoteID, state, state)
		}
	})
}

func runMeltContract(t *testing.T, fx Fixture) {
	if fx.SkipMeltReason != "" {
		t.Run("unimplemented_returns_error_not_panic", func(t *testing.T) {
			w, mint := newWallet(t, fx, MintModeHealthy)
			if _, err := w.RequestMeltQuote("lnbc1placeholder", mint.URL()); err == nil {
				t.Fatal("RequestMeltQuote returned a nil error on an adapter that does not implement it")
			}
			if _, err := w.Melt("conformance-melt-1"); err == nil {
				t.Fatal("Melt returned a nil error on an adapter that does not implement it")
			}
		})
		t.Run("happy_path", func(t *testing.T) {
			t.Skipf("adapter does not implement the melt pair yet: %s", fx.SkipMeltReason)
		})
		return
	}

	w, mint := newWallet(t, fx, MintModeHealthy)
	t.Run("request_melt_quote_and_melt", func(t *testing.T) {
		q, err := w.RequestMeltQuote("lnbc1placeholder", mint.URL())
		if err != nil {
			t.Fatalf("RequestMeltQuote: %v", err)
		}
		if q == nil || q.QuoteID == "" {
			t.Fatalf("RequestMeltQuote returned %+v, want a quote with an id", q)
		}
		res, err := w.Melt(q.QuoteID)
		if err != nil {
			t.Fatalf("Melt(%s): %v", q.QuoteID, err)
		}
		if res == nil || !res.Paid {
			t.Fatalf("Melt(%s) = %+v, want a paid result", q.QuoteID, res)
		}
	})
}

func runLifecycleContract(t *testing.T, fx Fixture) {
	t.Run("shutdown_is_idempotent", func(t *testing.T) {
		w, _ := newWallet(t, fx, MintModeHealthy)
		if err := w.Shutdown(); err != nil {
			t.Fatalf("first Shutdown: %v", err)
		}
		if err := w.Shutdown(); err != nil {
			t.Fatalf("second Shutdown: %v", err)
		}
	})

	t.Run("uninitialized_wallet_returns_sentinel", func(t *testing.T) {
		if fx.NewUninitialized == nil {
			t.Skip("fixture does not expose an uninitialized adapter")
		}
		w, err := fx.NewUninitialized(t)
		if err != nil {
			t.Fatalf("NewUninitialized: %v", err)
		}
		if _, err := w.GetMintQuoteState("quote-id"); !errors.Is(err, port.ErrWalletNotInitialized) {
			t.Fatalf("GetMintQuoteState on an uninitialized wallet: err = %v, want errors.Is(err, port.ErrWalletNotInitialized)", err)
		}
		if err := w.Shutdown(); err != nil {
			t.Fatalf("Shutdown on an uninitialized wallet: %v", err)
		}
	})
}

func truncate(s string) string {
	if len(s) <= 40 {
		return s
	}
	return s[:40] + "…"
}
