// Package conformance holds the library-agnostic wallet conformance suite:
// the assertions that ANY Cashu wallet backend must satisfy to be usable
// behind tollwallet.WalletPort.
//
// WHY IT IS ITS OWN PACKAGE (T16, research/wallet-migration): this package
// must be importable and runnable without the concrete wallet library. Its
// import graph is deliberately confined to the standard library plus the
// dependency-free port package, so an adapter for a different library (cdk-go,
// nucula, …) can run the exact same suite with a handful of glue lines:
//
//	conformance.RunPortConformance(t, conformance.Fixture{
//	    Name: "cdk",
//	    NewWallet: func(t *testing.T, dir, mintURL string, mode conformance.MintMode) (port.WalletPort, error) {
//	        return cdkwallet.New(dir, []string{mintURL}) // returns port.WalletPort
//	    },
//	})
//
// Everything here is expressed in terms of the port contract and the Cashu
// wire format — never in terms of a library's types. The suite's discriminative
// power is demonstrated by running it against the real gonuts adapter (see
// src/tollwallet/port_conformance_glue_test.go); the scripted FakeWallet in
// fake.go exists so the suite can also run with zero library dependencies.
package conformance
