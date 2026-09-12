package cli

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"sync"
	"testing"

	"github.com/OpenTollGate/tollgate-module-basic-go/src/merchant"
)

// This file covers the wallet-drain defects reported in
// https://github.com/OpenTollGate/tollgate-module-basic-go/issues/375.
//
// drainFakeMerchant reproduces the wallet bookkeeping described in that report:
//
//   - GetAllMintBalances() reports a per *registry entry* snapshot in which
//     every registered entry for one physical mint reports the balance of the
//     shared proof pool. That is why a stale trailing-slash duplicate entry
//     reported 50 sats even though it holds no proofs of its own.
//   - DrainMint(entry) resolves the entry to the pool it wraps, so the first
//     entry drained spends the pool and every other entry for the same mint
//     then fails with "no balance available for mint <entry>".
//
// This models the observed symptom at the CLI boundary. It deliberately does
// not claim more about gonuts internals than the bug report and the on-router
// forensics support.

type drainFakeMerchant struct {
	*namedMerchant

	mu sync.Mutex
	// registry is exactly what GetAllMintBalances() reports.
	registry map[string]uint64
	// pool is the shared proof balance per physical mint, keyed by the
	// trailing-slash-insensitive mint identity.
	pool map[string]uint64
	// broken mints fail to drain even while they still hold balance. Keyed by
	// mint identity, so it fails every entry of that mint.
	broken map[string]error
	// brokenEntry fails exactly ONE registry entry (keyed by the URL as
	// registered), while its siblings for the same mint still work. That is the
	// "the URL registered first happens to be unreachable" case: the drain must
	// still try the sibling rather than declaring the mint failed.
	brokenEntry map[string]error
	// emptyEntry wins the swap but hands back no token — the shape a wallet
	// library bug would take. Keyed by the URL as registered.
	emptyEntry map[string]bool
	calls      []string
}

func newDrainFakeMerchant(registry, pool map[string]uint64, broken map[string]error) *drainFakeMerchant {
	return &drainFakeMerchant{
		namedMerchant: &namedMerchant{name: "drain-fake"},
		registry:      registry,
		pool:          pool,
		broken:        broken,
	}
}

func (m *drainFakeMerchant) GetAllMintBalances() map[string]uint64 {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make(map[string]uint64, len(m.registry))
	for k, v := range m.registry {
		out[k] = v
	}
	return out
}

func (m *drainFakeMerchant) DrainMint(mintURL string) (string, uint64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	m.calls = append(m.calls, mintURL)

	if err, isBroken := m.brokenEntry[mintURL]; isBroken {
		return "", 0, err
	}
	key := fakeCanonicalMint(mintURL)
	if err, isBroken := m.broken[key]; isBroken {
		return "", 0, err
	}
	balance := m.pool[key]
	if balance == 0 {
		return "", 0, fmt.Errorf("no balance available for mint %s", mintURL)
	}
	if m.emptyEntry[mintURL] {
		// The swap succeeded and spent the proofs, but the library returned no
		// token material: the tokens must NOT be reported as drained.
		m.pool[key] = 0
		return "", 0, nil
	}
	m.pool[key] = 0
	return fmt.Sprintf("cashuB-fake-%d", balance), balance, nil
}

// breakEntry makes exactly one registry entry fail to drain while its siblings
// for the same mint keep working.
func (m *drainFakeMerchant) breakEntry(entry string, err error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.brokenEntry == nil {
		m.brokenEntry = map[string]error{}
	}
	m.brokenEntry[entry] = err
}

// returnEmptyToken makes exactly one registry entry consume the pool and answer
// with an empty token instead of the drained proofs.
func (m *drainFakeMerchant) returnEmptyToken(entry string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.emptyEntry == nil {
		m.emptyEntry = map[string]bool{}
	}
	m.emptyEntry[entry] = true
}

// heldBalance is the total satoshi value still held by the fake wallet.
func (m *drainFakeMerchant) heldBalance() uint64 {
	m.mu.Lock()
	defer m.mu.Unlock()
	var total uint64
	for _, v := range m.pool {
		total += v
	}
	return total
}

// drainCallsFor returns how many times an entry of the given mint was drained.
func (m *drainFakeMerchant) drainCallsFor(mintURL string) int {
	m.mu.Lock()
	defer m.mu.Unlock()
	want := fakeCanonicalMint(mintURL)
	count := 0
	for _, call := range m.calls {
		if fakeCanonicalMint(call) == want {
			count++
		}
	}
	return count
}

// fakeCanonicalMint is a test-local mint identity: scheme/host case-folded and
// a trailing slash on the path ignored, which is the identity NUT-01/NUT-02
// give a mint. It is intentionally independent of the production helper so the
// tests assert on the contract rather than re-using the code under test.
func fakeCanonicalMint(raw string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return strings.ToLower(strings.TrimRight(raw, "/"))
	}
	return strings.ToLower(u.Scheme) + "://" + strings.ToLower(u.Host) + strings.TrimRight(u.Path, "/")
}

// drainWire is the JSON an orchestrator actually consumes from
// `tollgate --json wallet drain cashu`.
type drainWire struct {
	Success bool `json:"success"`
	Data    *struct {
		Success bool `json:"success"`
		Tokens  []struct {
			MintURL string `json:"mint_url"`
			Balance uint64 `json:"balance_sats"`
			Token   string `json:"token"`
		} `json:"tokens"`
		Total    uint64   `json:"total_sats"`
		Merged   []string `json:"merged_entries"`
		SaveTo   string   `json:"save_to_file"`
		Failures []struct {
			MintURL string `json:"mint_url"`
			Error   string `json:"error"`
		} `json:"failures"`
	} `json:"data"`
}

func decodeDrainResponse(t *testing.T, resp CLIResponse) drainWire {
	t.Helper()
	raw, err := json.Marshal(resp)
	if err != nil {
		t.Fatalf("marshal drain response: %v", err)
	}
	t.Logf("drain response wire form: %s", raw)

	var wire drainWire
	if err := json.Unmarshal(raw, &wire); err != nil {
		t.Fatalf("unmarshal drain response: %v", err)
	}
	if wire.Data == nil {
		t.Fatalf("drain response carries no data payload at all; a token produced by a completed swap would be lost (raw: %s)", raw)
	}
	return wire
}

func newDrainTestServer(m *drainFakeMerchant) *CLIServer {
	return NewCLIServer(nil, merchant.NewMutexMerchantProvider(m), nil, nil, nil)
}

func tokenTotal(w drainWire) uint64 {
	var total uint64
	for _, tok := range w.Data.Tokens {
		total += tok.Balance
	}
	return total
}

// TestCashuDrain_DuplicateMintEntry_ReportsProducedToken reproduces defect 2 of
// issue #375: the wallet has two registry entries for one physical mint (the
// correct URL and a stale trailing-slash duplicate left over from a
// config-side URL correction). Draining must produce exactly one token for the
// mint and must never destroy it, whichever entry holds the proofs.
func TestCashuDrain_DuplicateMintEntry_ReportsProducedToken(t *testing.T) {
	const good = "https://mint.example/Bitcoin"
	const stale = good + "/"

	fake := newDrainFakeMerchant(
		// Both registry entries report the shared pool balance, exactly as the
		// reporter observed on the router.
		map[string]uint64{good: 50, stale: 50},
		map[string]uint64{fakeCanonicalMint(good): 50},
		nil,
	)

	before := fake.heldBalance()
	resp := newDrainTestServer(fake).handleCashuDrain(nil)
	after := fake.heldBalance()
	wire := decodeDrainResponse(t, resp)

	if len(wire.Data.Tokens) != 1 {
		t.Fatalf("want exactly 1 drained token for the mint, got %d (the swap was already submitted to the mint when the second entry failed; dropping the token destroys the funds)", len(wire.Data.Tokens))
	}
	token := wire.Data.Tokens[0]
	if fakeCanonicalMint(token.MintURL) != fakeCanonicalMint(good) {
		t.Errorf("token mint_url = %q, want the drained mint", token.MintURL)
	}
	if token.Balance != 50 {
		t.Errorf("token balance = %d, want 50", token.Balance)
	}
	if token.Token == "" {
		t.Error("token string is empty: nothing recoverable was reported")
	}
	if wire.Data.Total != 50 {
		t.Errorf("total_sats = %d, want 50", wire.Data.Total)
	}
	if !wire.Success {
		t.Errorf("a duplicate registry entry must not turn a completed drain into a failed command: success=false, failures=%+v", wire.Data.Failures)
	}
	if len(wire.Data.Failures) != 0 {
		t.Errorf("duplicate registry entries are not per-mint failures, got %+v", wire.Data.Failures)
	}
	// The entry that was not drained must be reported as merged, so an operator
	// can see WHY one of the two entries they have configured produced no
	// token of its own.
	if len(wire.Data.Merged) != 1 || fakeCanonicalMint(wire.Data.Merged[0]) != fakeCanonicalMint(stale) {
		t.Errorf("merged_entries = %v, want exactly the undrained duplicate entry %q", wire.Data.Merged, stale)
	}
	if calls := fake.drainCallsFor(good); calls != 1 {
		t.Errorf("drained the mint %d times; a duplicate registry entry must be drained exactly once", calls)
	}
	if delta := before - after; tokenTotal(wire) != delta {
		t.Errorf("wallet dropped %d sats but only %d sats worth of tokens were reported", delta, tokenTotal(wire))
	}
}

// TestCashuDrain_SiblingEntrySucceedsAfterEntryFailure covers the other half of
// the duplicate-entry case: the entry that is tried FIRST fails for a real
// reason (the URL it names is unreachable), and the sibling entry for the same
// mint is the one that holds the proofs. Abandoning the mint on the first error
// would strand the funds, so the handler must try the sibling.
func TestCashuDrain_SiblingEntrySucceedsAfterEntryFailure(t *testing.T) {
	const good = "https://mint.example/Bitcoin"
	const stale = good + "/"

	fake := newDrainFakeMerchant(
		map[string]uint64{good: 50, stale: 50},
		map[string]uint64{fakeCanonicalMint(good): 50},
		nil,
	)
	// The non-slash entry is the one the handler tries first, and it fails.
	fake.breakEntry(good, errors.New("dial tcp: connection refused"))

	before := fake.heldBalance()
	resp := newDrainTestServer(fake).handleCashuDrain(nil)
	after := fake.heldBalance()
	wire := decodeDrainResponse(t, resp)

	if len(wire.Data.Tokens) != 1 {
		t.Fatalf("a failing first entry must not abandon the mint: want 1 token from the sibling entry, got %d (failures=%+v)", len(wire.Data.Tokens), wire.Data.Failures)
	}
	if wire.Data.Tokens[0].Balance != 50 || wire.Data.Tokens[0].Token == "" {
		t.Errorf("token = %+v, want the 50 sats the sibling entry held", wire.Data.Tokens[0])
	}
	if !wire.Success {
		t.Errorf("the mint WAS drained through its sibling entry, so the command must not report failure: failures=%+v", wire.Data.Failures)
	}
	if calls := fake.drainCallsFor(good); calls != 2 {
		t.Errorf("drained the mint %d times, want 2 (the failing entry, then the sibling)", calls)
	}
	if delta := before - after; tokenTotal(wire) != delta {
		t.Errorf("wallet dropped %d sats but only %d sats worth of tokens were reported", delta, tokenTotal(wire))
	}
}

// TestCashuDrain_EmptyTokenFromMint_IsReportedAsFailure guards the guard: a
// DrainMint that returns no error but also no token material must never be
// recorded as a successful drain, or the mint would be marked done while its
// funds are missing. The swap here did consume the proofs, so the honest report
// is "nothing recovered, this mint failed" — not a success with a token that
// does not exist.
func TestCashuDrain_EmptyTokenFromMint_IsReportedAsFailure(t *testing.T) {
	const first = "https://mint.example/Bitcoin"
	const second = first + "/"

	fake := newDrainFakeMerchant(
		map[string]uint64{first: 50, second: 50},
		map[string]uint64{fakeCanonicalMint(first): 50},
		nil,
	)
	fake.returnEmptyToken(first)

	resp := newDrainTestServer(fake).handleCashuDrain(nil)
	wire := decodeDrainResponse(t, resp)

	if len(wire.Data.Tokens) != 0 {
		t.Fatalf("an empty token must never be reported as a drained token, got %+v", wire.Data.Tokens)
	}
	if wire.Success {
		t.Error("a mint that handed back no token must not be reported as drained")
	}
	if len(wire.Data.Failures) != 1 || !strings.Contains(wire.Data.Failures[0].Error, "no token") {
		t.Errorf("the empty result must be reported as a failure, got %+v", wire.Data.Failures)
	}
	if calls := fake.drainCallsFor(first); calls != 2 {
		t.Errorf("drained the mint %d times, want 2: an empty result must not stop the sibling entry from being tried", calls)
	}
}

// TestCashuDrain_OneMintFails_OtherMintsTokensAreStillReported reproduces the
// funds-loss half of defect 2: a failure on one mint entry must never discard
// or hide a token another mint already produced.
func TestCashuDrain_OneMintFails_OtherMintsTokensAreStillReported(t *testing.T) {
	const ok = "https://good.example"
	const down = "https://broken.example"

	fake := newDrainFakeMerchant(
		map[string]uint64{ok: 40, down: 60},
		map[string]uint64{fakeCanonicalMint(ok): 40, fakeCanonicalMint(down): 60},
		map[string]error{fakeCanonicalMint(down): errors.New("mint unreachable")},
	)

	before := fake.heldBalance()
	resp := newDrainTestServer(fake).handleCashuDrain(nil)
	after := fake.heldBalance()
	wire := decodeDrainResponse(t, resp)

	if len(wire.Data.Tokens) != 1 || wire.Data.Tokens[0].Balance != 40 {
		t.Fatalf("the successful mint's token must be reported even though another mint failed, got %+v", wire.Data.Tokens)
	}
	if wire.Data.Total != 40 {
		t.Errorf("total_sats = %d, want 40", wire.Data.Total)
	}
	if len(wire.Data.Failures) != 1 || !strings.Contains(wire.Data.Failures[0].Error, "mint unreachable") {
		t.Errorf("the failing mint must be reported, got %+v", wire.Data.Failures)
	}
	if wire.Success {
		t.Error("a partially drained wallet must not be reported as a complete success")
	}
	if delta := before - after; tokenTotal(wire) != delta {
		t.Errorf("wallet dropped %d sats but only %d sats worth of tokens were reported", delta, tokenTotal(wire))
	}
}

// TestCashuDrain_SaveToFileIsEchoedOnEveryPath pins the flag echo: the caller's
// requested filename must come back on the wire whether tokens were produced or
// not, so the client never has to guess where its tokens went.
func TestCashuDrain_SaveToFileIsEchoedOnEveryPath(t *testing.T) {
	const mint = "https://mint.example/Bitcoin"
	const filename = "wallet_drain_test.txt"

	// Empty wallet (all balances zero).
	empty := newDrainFakeMerchant(map[string]uint64{mint: 0}, map[string]uint64{}, nil)
	wire := decodeDrainResponse(t, newDrainTestServer(empty).handleCashuDrain(map[string]string{"save_to_file": filename}))
	if !wire.Success || wire.Data.SaveTo != filename {
		t.Errorf("zero-balance drain: success=%v save_to_file=%q, want true/%q", wire.Success, wire.Data.SaveTo, filename)
	}

	// A drain that produced a token.
	holding := newDrainFakeMerchant(map[string]uint64{mint: 50}, map[string]uint64{fakeCanonicalMint(mint): 50}, nil)
	wire = decodeDrainResponse(t, newDrainTestServer(holding).handleCashuDrain(map[string]string{"save_to_file": filename}))
	if !wire.Success || wire.Data.SaveTo != filename {
		t.Errorf("drained wallet: success=%v save_to_file=%q, want true/%q", wire.Success, wire.Data.SaveTo, filename)
	}
}

// TestCashuDrain_AllMintsFail_StillReportsWhy guards the case where nothing was
// drained at all: the caller must get the reason, not a bare success=false.
func TestCashuDrain_AllMintsFail_StillReportsWhy(t *testing.T) {
	const down = "https://broken.example"

	fake := newDrainFakeMerchant(
		map[string]uint64{down: 60},
		map[string]uint64{fakeCanonicalMint(down): 60},
		map[string]error{fakeCanonicalMint(down): errors.New("mint unreachable")},
	)

	resp := newDrainTestServer(fake).handleCashuDrain(nil)
	wire := decodeDrainResponse(t, resp)

	if wire.Success {
		t.Error("a drain where every mint failed must not report success")
	}
	if len(wire.Data.Tokens) != 0 {
		t.Errorf("no tokens should have been produced, got %+v", wire.Data.Tokens)
	}
	if len(wire.Data.Failures) != 1 || !strings.Contains(wire.Data.Failures[0].Error, "mint unreachable") {
		t.Errorf("the failure must be reported, got %+v", wire.Data.Failures)
	}
	if !strings.Contains(resp.Message, "No tokens were drained") {
		t.Errorf("message should say that nothing was drained, got %q", resp.Message)
	}
	if fake.heldBalance() != 60 {
		t.Errorf("a failed drain must leave the balance untouched, balance=%d", fake.heldBalance())
	}
}

// TestCashuDrain_DuplicateEntriesAllFail_ReportsFirstError pins the error the
// operator sees: with two failing entries for one mint, the FIRST failure is
// the root cause and the later "no balance available" is only its consequence.
func TestCashuDrain_DuplicateEntriesAllFail_ReportsFirstError(t *testing.T) {
	const first = "https://mint.example/Bitcoin"
	const second = first + "/"

	fake := newDrainFakeMerchant(
		map[string]uint64{first: 50, second: 50},
		map[string]uint64{fakeCanonicalMint(first): 0},
		nil,
	)
	fake.breakEntry(first, errors.New("mint unreachable"))

	resp := newDrainTestServer(fake).handleCashuDrain(nil)
	wire := decodeDrainResponse(t, resp)

	if len(wire.Data.Failures) != 1 {
		t.Fatalf("want one failure for the mint, got %+v", wire.Data.Failures)
	}
	if got := wire.Data.Failures[0].Error; !strings.Contains(got, "mint unreachable") {
		t.Errorf("failure error = %q, want the FIRST (root cause) error to be reported", got)
	}
	if got := wire.Data.Failures[0].Error; !strings.Contains(got, "2 registry entries") {
		t.Errorf("failure error = %q, want it to mention that both entries failed", got)
	}
}
