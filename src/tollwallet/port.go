package tollwallet

// This file is the compatibility shim for the wallet contract that now lives
// in the dependency-free package github.com/OpenTollGate/tollgate-module-basic-go/src/tollwallet/port.
//
// WHY THE CONTRACT MOVED (T16, research/wallet-migration/03-baseline/interchangeability.md):
// the WalletPort interface, its value types and its sentinel errors must be
// importable without the concrete wallet library, otherwise a conformance suite
// (or any future CDK/nucula adapter) cannot depend on the contract without
// transitively depending on gonuts-tollgate. This package's other files import
// gonuts-tollgate unconditionally, so the contract could not stay here.
//
// Every symbol below is a Go type alias (or a re-exported constant/function),
// NOT a copy: package tollwallet.WalletPort and port.WalletPort are the *same*
// type, so merchant code compiled against this package satisfies, and is
// satisfied by, adapters written against the port package directly. Nothing
// about production behaviour changes — see the alias-identity proof in
// src/tollwallet/conformance (TestAliasIdentity*).
//
// Design decisions documented in WIREFORMAT.md:
//   - Token uses an explicit Close() method for CGO lifecycle management
//     (GonutsToken.Close() is a no-op; CdkToken.Close() calls Destroy()).
//   - MintQuoteState uses int underlying type with dual-format JSON:
//     MarshalJSON emits uppercase strings per Cashu NUT-04;
//     UnmarshalJSON accepts both integers (legacy gonuts) and strings.
//   - Existing sentinels ErrTokenAlreadySpent and ErrWalletNotInitialized
//     are defined in the port package and aliased here.

import "github.com/OpenTollGate/tollgate-module-basic-go/src/tollwallet/port"

// Wallet contract types, aliased from the port package.
type (
	// Token is the library-agnostic Cashu token abstraction.
	Token = port.Token
	// MintQuoteState represents the state of a Lightning mint quote (NUT-04).
	MintQuoteState = port.MintQuoteState
	// MintQuote is the library-agnostic Lightning mint quote response (NUT-04).
	MintQuote = port.MintQuote
	// MeltQuote is the library-agnostic Lightning melt quote response (NUT-05).
	MeltQuote = port.MeltQuote
	// MeltResult is the library-agnostic Lightning melt operation result.
	MeltResult = port.MeltResult
	// WalletPort is the library-agnostic Cashu wallet interface.
	WalletPort = port.WalletPort
)

// Mint quote states, aliased from the port package. Because these are aliases,
// the values are identical to port.StateUnpaid and compare equal.
const (
	StateUnpaid  = port.StateUnpaid
	StatePaid    = port.StatePaid
	StateIssued  = port.StateIssued
	StatePending = port.StatePending
	StateUnknown = port.StateUnknown
)

// ParseMintQuoteState converts a string to MintQuoteState (case-insensitive).
// Re-exported from the port package.
func ParseMintQuoteState(s string) (MintQuoteState, error) {
	return port.ParseMintQuoteState(s)
}
