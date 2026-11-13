package paymentjournal

import (
	"math"
	"testing"
	"time"
)

// The journal must never refuse to record spend that already happened, and it
// must never accept a fee no verified response could plausibly report.
//
// Both directions are load-bearing:
//   - refusing a true 1102 against limit 1101 understates spend (recorded 1100)
//     and lets the next payment overspend the real budget;
//   - accepting math.MaxInt64 poisons outgoingCostLocked forever.
func TestAdvanceRecordsVerifiedOverLimitSpend(t *testing.T) {
	budget := Budget{LimitMSat: 1101}
	s, _ := openTest(t)
	op, err := s.Prepare(intent("over-limit-real"), budget)
	if err != nil {
		t.Fatal(err)
	}
	if op, err = s.SubmitOutgoing(op.ID, op.Version, budget); err != nil {
		t.Fatal(err)
	}
	// Verified: principal 1000 + fee 102 = 1102 > limit 1101. Recording it must
	// not be refused, even though it exceeds the period budget.
	op, err = s.Advance(op.ID, op.Version, Paid, 102)
	if err != nil {
		t.Fatalf("a verified 1102 spend against limit 1101 was refused: %v", err)
	}
	if op.ActualFeeMSat != 102 || op.State != Paid {
		t.Fatalf("got fee=%d state=%s, want 102/paid", op.ActualFeeMSat, op.State)
	}
	cost, err := s.outgoingCostLocked("wallet-a", time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if cost != 1102 {
		t.Fatalf("journal records %d, real spend is 1102 — understated", cost)
	}
	// The overspend must not buy another payment.
	if _, perr := s.Prepare(intent("after-overspend"), budget); perr == nil {
		t.Fatal("a further payment prepared although the budget was already exceeded — OVERSPEND")
	}
}

func TestAdvanceRefusesUnverifiedAbsurdFee(t *testing.T) {
	budget := Budget{LimitMSat: 1101}
	s, _ := openTest(t)
	op, err := s.Prepare(intent("absurd-refused"), budget)
	if err != nil {
		t.Fatal(err)
	}
	if op, err = s.SubmitOutgoing(op.ID, op.Version, budget); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Advance(op.ID, op.Version, Paid, math.MaxInt64); err == nil {
		t.Fatal("an unbounded fee was accepted; it poisons the wallet budget permanently")
	}
	cost, err := s.outgoingCostLocked("wallet-a", time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if cost != 1100 {
		t.Fatalf("wallet poisoned by a refused fee: cost=%d, want 1100", cost)
	}
	// The same operation must still finalize with a plausible fee.
	if _, err = s.Advance(op.ID, op.Version, Paid, 102); err != nil {
		t.Fatalf("same operation refused with a plausible fee: %v", err)
	}
}

// Truthful over-limit spend must survive a reopen.
func TestOverLimitSpendSurvivesReopen(t *testing.T) {
	budget := Budget{LimitMSat: 1101}
	s, dir := openTest(t)
	op, err := s.Prepare(intent("over-limit-durable"), budget)
	if err != nil {
		t.Fatal(err)
	}
	if op, err = s.SubmitOutgoing(op.ID, op.Version, budget); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Advance(op.ID, op.Version, Paid, 102); err != nil {
		t.Fatal(err)
	}
	if err = s.Close(); err != nil {
		t.Fatal(err)
	}
	again, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer again.Close()
	got, err := again.Get(op.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.ActualFeeMSat != 102 {
		t.Fatalf("after reopen fee=%d, want 102", got.ActualFeeMSat)
	}
	cost, err := again.outgoingCostLocked("wallet-a", time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if cost != 1102 {
		t.Fatalf("after reopen journal records %d, want 1102", cost)
	}
}

// The ceiling alone is not a sufficient bound: AmountMSat and FeeReserveMSat are
// each capped at MaxInt64, so the sum can reach 2^64-2, which is itself above
// MaxInt64. Recording a fee that large writes an ActualFeeMSat the recovery
// validator rejects, so the journal file can never be opened again — a durable
// denial of the whole store. This is why the MaxInt64 bound must be kept
// alongside the plausibility ceiling.
func TestAdvanceNeverRecordsFeeAboveMaxInt64(t *testing.T) {
	s, dir := openTest(t)
	o := Operation{ID: "max-fee", WalletID: "wallet-a", Direction: Outgoing, Recipient: "r",
		PaymentHash: "000000000000000000000000000000000000000000000000000000000000000b",
		AmountMSat:  math.MaxInt64, FeeReserveMSat: math.MaxInt64}
	op, err := s.Prepare(o, Budget{LimitMSat: math.MaxUint64})
	if err != nil {
		t.Fatal(err)
	}
	if op, err = s.SubmitOutgoing(op.ID, op.Version, Budget{LimitMSat: math.MaxUint64}); err != nil {
		t.Fatal(err)
	}
	fee := uint64(math.MaxInt64) * 2 // 2^64-2: within the ceiling, above MaxInt64
	if _, err = s.Advance(op.ID, op.Version, Paid, fee); err == nil {
		t.Fatalf("recorded ActualFeeMSat=%d (> MaxInt64); the journal is now unopenable", fee)
	}
	// The store must remain openable: a rejected fee must not brick the file.
	if err = s.Close(); err != nil {
		t.Fatal(err)
	}
	again, err := Open(dir)
	if err != nil {
		t.Fatalf("journal bricked by a rejected fee: %v", err)
	}
	defer again.Close()
}

// Incoming operations are unaffected by the outgoing fee ceiling.
func TestIncomingTerminalUnaffectedByFeeCeiling(t *testing.T) {
	s, _ := openTest(t)
	op, _ := s.Prepare(Operation{ID: "in-1", WalletID: "wallet-a", Direction: Incoming,
		AmountMSat: 1000, Recipient: "client-a"}, Budget{})
	op, _ = s.Advance(op.ID, op.Version, Submitted, 0)
	op, _ = s.BindInvoice(op.ID, op.Version, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", []byte("inv"))
	if _, err := s.Advance(op.ID, op.Version, Paid, 0); err != nil {
		t.Fatalf("incoming terminal transition refused: %v", err)
	}
}
