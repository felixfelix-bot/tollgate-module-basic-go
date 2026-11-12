package paymentjournal

import (
	"math"
	"testing"
	"time"
)

// FinalizeOutgoing is the checked route for the monetary terminal transition:
// it rechecks the period budget with the ACTUAL fee before recording it, so a
// fee that does not fit cannot poison the wallet's budget.
//
// Without it, Advance lets a caller write any uint64 as ActualFeeMSat with no
// Budget argument. outgoingCostLocked then counts that number for resolved
// sends, so a single absurd fee refuses every later Prepare for the wallet.
//
// Over-reserve is still allowed when it FITS the budget (that is the documented
// intent in TestVerifiedActualFeeOverReserveIsDurableAndExhaustsBudget).
func TestFinalizeOutgoingRechecksBudgetWithActualFee(t *testing.T) {
	budget := Budget{LimitMSat: 1101}
	s, _ := openTest(t)
	op, err := s.Prepare(intent("finalize-over-reserve"), budget)
	if err != nil {
		t.Fatal(err)
	}
	if op, err = s.SubmitOutgoing(op.ID, op.Version, budget); err != nil {
		t.Fatal(err)
	}
	// Over-reserve but within the limit: must be accepted and recorded truthfully.
	op, err = s.FinalizeOutgoing(op.ID, op.Version, 101, budget)
	if err != nil {
		t.Fatalf("over-reserve fee within budget was refused: %v", err)
	}
	if op.ActualFeeMSat != 101 {
		t.Fatalf("fee not recorded truthfully: got %d want 101", op.ActualFeeMSat)
	}
	if op.State != Paid {
		t.Fatalf("state = %s, want paid", op.State)
	}
}

func TestFinalizeOutgoingRefusesFeeThatExceedsBudget(t *testing.T) {
	budget := Budget{LimitMSat: 1101}
	s, _ := openTest(t)
	op, err := s.Prepare(intent("finalize-absurd-fee"), budget)
	if err != nil {
		t.Fatal(err)
	}
	if op, err = s.SubmitOutgoing(op.ID, op.Version, budget); err != nil {
		t.Fatal(err)
	}
	if _, err = s.FinalizeOutgoing(op.ID, op.Version, math.MaxInt64, budget); err == nil {
		t.Fatal("an absurd actual fee was accepted; it can permanently exhaust the wallet budget")
	}
	// The refused fee must not have been recorded. outgoingCostLocked counts
	// ActualFeeMSat for resolved sends, so a poisoned journalled cost is exactly
	// how one bad fee refuses every later send for the wallet.
	cost, err := s.outgoingCostLocked("wallet-a", time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if cost != 1100 {
		t.Fatalf("journal cost after refused fee = %d, want 1100 (the reserve, unpoisoned)", cost)
	}
}

// The refusal must be about the fee, not about the state: the same operation
// finalizes fine with a fee that fits.
func TestFinalizeOutgoingRefusalIsFeeSpecific(t *testing.T) {
	budget := Budget{LimitMSat: 1101}
	s, _ := openTest(t)
	op, err := s.Prepare(intent("finalize-specific"), budget)
	if err != nil {
		t.Fatal(err)
	}
	if op, err = s.SubmitOutgoing(op.ID, op.Version, budget); err != nil {
		t.Fatal(err)
	}
	if _, err = s.FinalizeOutgoing(op.ID, op.Version, math.MaxInt64, budget); err == nil {
		t.Fatal("absurd fee accepted")
	}
	if _, err = s.FinalizeOutgoing(op.ID, op.Version, 1, budget); err != nil {
		t.Fatalf("same operation refused with a sane fee: %v", err)
	}
}
