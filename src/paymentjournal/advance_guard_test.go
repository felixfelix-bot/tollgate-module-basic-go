package paymentjournal

import (
	"math"
	"testing"
	"time"
)

// FinalizeOutgoing being "the only route" for outgoing -> paid must be enforced
// by the state machine, not just documented. Advance takes no Budget, so it must
// refuse the outgoing monetary terminal transition the same way it already
// refuses the outgoing prepared -> submitted transition.
func TestAdvanceRefusesOutgoingTerminalTransition(t *testing.T) {
	budget := Budget{LimitMSat: 1101}
	s, _ := openTest(t)
	op, err := s.Prepare(intent("advance-refuses-paid"), budget)
	if err != nil {
		t.Fatal(err)
	}
	if op, err = s.SubmitOutgoing(op.ID, op.Version, budget); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Advance(op.ID, op.Version, Paid, math.MaxInt64); err == nil {
		t.Fatal("Advance recorded an unbounded ActualFeeMSat for an outgoing operation; " +
			"FinalizeOutgoing is not actually the only route")
	}
	// The refusal must leave the operation untouched and the wallet usable.
	got, err := s.Get(op.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.State != Submitted {
		t.Fatalf("state after refused Advance = %s, want submitted", got.State)
	}
	if got.ActualFeeMSat != 0 {
		t.Fatalf("fee recorded despite refusal: %d", got.ActualFeeMSat)
	}
	if _, err = s.Prepare(intent("wallet-usable"), budget); err == nil {
		t.Fatal("wallet accepted a send that exceeds the remaining headroom")
	}
	cost, err := s.outgoingCostLocked("wallet-a", time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if cost != 1100 {
		t.Fatalf("wallet cost poisoned: %d, want 1100", cost)
	}
}

// unknown -> paid is the primary real-world reconciliation route (after restart
// every submitted becomes unknown), so it must be refused by Advance too.
func TestAdvanceRefusesOutgoingUnknownToPaid(t *testing.T) {
	budget := Budget{LimitMSat: 1101}
	s, _ := openTest(t)
	op, err := s.Prepare(intent("advance-unknown-paid"), budget)
	if err != nil {
		t.Fatal(err)
	}
	if op, err = s.SubmitOutgoing(op.ID, op.Version, budget); err != nil {
		t.Fatal(err)
	}
	if op, err = s.Advance(op.ID, op.Version, Unknown, 0); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Advance(op.ID, op.Version, Paid, math.MaxInt64); err == nil {
		t.Fatal("Advance recorded an unbounded fee for outgoing unknown -> paid")
	}
}

// The guard must not break the legitimate paths: incoming still uses Advance for
// its terminal transitions, and outgoing failure/completion remain available.
func TestAdvanceStillPermitsNonMonetaryOutgoingTransitions(t *testing.T) {
	budget := Budget{LimitMSat: 1101}
	s, _ := openTest(t)
	op, err := s.Prepare(intent("advance-nonmonetary"), budget)
	if err != nil {
		t.Fatal(err)
	}
	if op, err = s.SubmitOutgoing(op.ID, op.Version, budget); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Advance(op.ID, op.Version, Failed, 0); err != nil {
		t.Fatalf("Advance refused a non-monetary outgoing terminal transition: %v", err)
	}
}

// And the checked route must still work for the unknown state it will now own.
func TestFinalizeOutgoingHandlesUnknown(t *testing.T) {
	budget := Budget{LimitMSat: 1101}
	s, _ := openTest(t)
	op, err := s.Prepare(intent("finalize-unknown"), budget)
	if err != nil {
		t.Fatal(err)
	}
	if op, err = s.SubmitOutgoing(op.ID, op.Version, budget); err != nil {
		t.Fatal(err)
	}
	if op, err = s.Advance(op.ID, op.Version, Unknown, 0); err != nil {
		t.Fatal(err)
	}
	op, err = s.FinalizeOutgoing(op.ID, op.Version, 101, budget)
	if err != nil {
		t.Fatalf("FinalizeOutgoing refused unknown -> paid: %v", err)
	}
	if op.ActualFeeMSat != 101 || op.State != Paid {
		t.Fatalf("got fee=%d state=%s, want 101/paid", op.ActualFeeMSat, op.State)
	}
}
