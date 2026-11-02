package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"github.com/btcsuite/btcd/btcec/v2"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// receiverKeyIsStable is the property that makes the whole binding usable: the same
// merchant identity must always yield the same receiver key. A key that varied would
// orphan every channel opened before it changed, which is why this is asserted rather
// than assumed.
func TestDeriveReceiverKeyIsStableAndUnlinkable(t *testing.T) {
	const merchant = "1111111111111111111111111111111111111111111111111111111111111111"
	a, err := deriveReceiverKey(merchant)
	if err != nil {
		t.Fatalf("derive: %v", err)
	}
	b, err := deriveReceiverKey(merchant)
	if err != nil {
		t.Fatalf("derive again: %v", err)
	}
	if !a.PubKey().IsEqual(b.PubKey()) {
		t.Fatal("the same merchant identity produced two different receiver keys; " +
			"every channel opened before a rotation would be uncloseable")
	}

	// Unlinkable: the advertised key must not BE the merchant key, or /spilman/params
	// becomes an oracle for the router's Nostr npub (same x-coordinate).
	merchantRaw, _ := hex.DecodeString(merchant)
	merchantKey, _ := btcec.PrivKeyFromBytes(merchantRaw)
	merchantPub := hex.EncodeToString(merchantKey.PubKey().SerializeCompressed())
	got := hex.EncodeToString(a.PubKey().SerializeCompressed())
	if got == merchantPub {
		t.Fatalf("the receiver key equals the merchant pubkey; advertising it would "+
			"link the rail to the router's identity: %s", got)
	}

	// Different identities must not collide.
	other, err := deriveReceiverKey("2222222222222222222222222222222222222222222222222222222222222222")
	if err != nil {
		t.Fatalf("derive other: %v", err)
	}
	if other.PubKey().IsEqual(a.PubKey()) {
		t.Fatal("two different merchant identities derived the same receiver key")
	}
}

// A malformed merchant key is an error, never a zero or a panic.
func TestDeriveReceiverKeyRefusesGarbage(t *testing.T) {
	for _, bad := range []string{"", "zz", "0011", strings.Repeat("ff", 32)} {
		if _, err := deriveReceiverKey(bad); err == nil {
			t.Error("invalid merchant scalar returned no error")
		}
	}
}

func TestDeriveReceiverKeyRejectsPublicDerivation(t *testing.T) {
	raw := bytes.Repeat([]byte{0x11}, 32)
	merchant, _ := btcec.PrivKeyFromBytes(raw)
	tag := sha256.Sum256([]byte("tollgate/spilman/receiver/v1"))
	h := sha256.New()
	h.Write(tag[:])
	h.Write(tag[:])
	h.Write(merchant.PubKey().SerializeCompressed())
	publicSecret := h.Sum(nil)
	receiver, err := deriveReceiverKey(hex.EncodeToString(raw))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(receiver.Serialize(), publicSecret) {
		t.Fatal("receiver secret is computable from merchant public key")
	}
}
func TestDeriveReceiverKeyHMACContract(t *testing.T) {
	raw := bytes.Repeat([]byte{0x11}, 32)
	mac := hmac.New(sha256.New, raw)
	mac.Write([]byte("tollgate/spilman/receiver/v2"))
	receiver, err := deriveReceiverKey(hex.EncodeToString(raw))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(receiver.Serialize(), mac.Sum(nil)) {
		t.Fatal("receiver does not match secret-keyed v2 HMAC contract")
	}
}
func TestDeriveReceiverKeyScalarBoundaries(t *testing.T) {
	order := btcec.S256().Params().N
	cases := map[string]string{
		"zero":           strings.Repeat("00", 32),
		"order":          fmt.Sprintf("%064x", order),
		"order-plus-one": fmt.Sprintf("%064x", new(big.Int).Add(order, big.NewInt(1))),
		"maximum":        strings.Repeat("ff", 32),
		"short":          strings.Repeat("01", 31),
		"long":           strings.Repeat("01", 33),
	}
	for name, value := range cases {
		t.Run(name, func(t *testing.T) {
			key, err := deriveReceiverKey(value)
			if err == nil || key != nil {
				t.Fatal("invalid scalar must return nil key and error")
			}
		})
	}
	for _, value := range []string{fmt.Sprintf("%064x", 1), fmt.Sprintf("%064x", new(big.Int).Sub(order, big.NewInt(1)))} {
		if _, err := deriveReceiverKey(value); err != nil {
			t.Fatal("valid boundary rejected:", err)
		}
	}
}

// Tests derivation restoration from persisted input, not application startup wiring.
func TestDeriveReceiverKeyRestartIdentity(t *testing.T) {
	path := filepath.Join(t.TempDir(), "merchant-test-key")
	fixture := strings.Repeat("11", 32)
	if err := os.WriteFile(path, []byte(fixture), 0600); err != nil {
		t.Fatal(err)
	}
	before, err := deriveReceiverKey(fixture)
	if err != nil {
		t.Fatal(err)
	}
	restored, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	after, err := deriveReceiverKey(" " + strings.ToUpper(string(restored)) + "\n")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before.Serialize(), after.Serialize()) || !before.PubKey().IsEqual(after.PubKey()) {
		t.Fatal("restored identity changed receiver key")
	}
}
