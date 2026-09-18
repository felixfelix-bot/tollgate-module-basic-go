// LIBRARY-AGNOSTIC TEST SET (T16, wallet-migration).
//
// Mint-URL matching is library-independent policy: it decides whether a token's
// mint is accepted, and it is shared by every adapter. No wallet library is
// imported here.
//
// Split list / evidence: research/wallet-migration/03-baseline/interchangeability.md
package tollwallet

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestContains(t *testing.T) {
	t.Run("String exists in slice", func(t *testing.T) {
		slice := []string{"apple", "banana", "orange"}
		result := contains(slice, "banana")
		assert.True(t, result)
	})

	t.Run("String does not exist in slice", func(t *testing.T) {
		slice := []string{"apple", "banana", "orange"}
		result := contains(slice, "grape")
		assert.False(t, result)
	})

	t.Run("Empty slice", func(t *testing.T) {
		slice := []string{}
		result := contains(slice, "apple")
		assert.False(t, result)
	})

	t.Run("Case insensitive match", func(t *testing.T) {
		slice := []string{"https://testnut.cashu.exchange"}
		assert.True(t, contains(slice, "https://Testnut.Cashu.Exchange"))
		assert.True(t, contains(slice, "https://TESTNUT.CASHU.EXCHANGE"))
		assert.True(t, contains(slice, "https://testnut.cashu.exchange"))
	})

	t.Run("Mint URL with different casing", func(t *testing.T) {
		mints := []string{"https://mint1.example.com", "https://mint2.example.com"}
		assert.True(t, contains(mints, "https://MINT1.EXAMPLE.COM"))
		assert.True(t, contains(mints, "https://Mint2.Example.Com"))
		assert.False(t, contains(mints, "https://mint3.example.com"))
	})

	t.Run("Case insensitive host but case sensitive path", func(t *testing.T) {
		mints := []string{"https://mint.minibits.cash/Bitcoin"}
		assert.True(t, contains(mints, "https://MINT.MINIBITS.CASH/Bitcoin"),
			"host case should not matter")
		assert.True(t, contains(mints, "https://mint.minibits.cash/Bitcoin"),
			"exact match should work")
		assert.False(t, contains(mints, "https://mint.minibits.cash/bitcoin"),
			"path is case-sensitive")
		assert.False(t, contains(mints, "https://MINT.MINIBITS.CASH/bitcoin"),
			"even with different host case, path must match exactly")
	})

	t.Run("URL parse failure falls back to exact match", func(t *testing.T) {
		mints := []string{"not-a-url"}
		assert.True(t, contains(mints, "not-a-url"))
		assert.False(t, contains(mints, "NOT-A-URL"),
			"fallback is exact match, not EqualFold")
	})

	t.Run("Empty path matches trailing slash (RFC 3986)", func(t *testing.T) {
		mints := []string{"https://testnut.cashu.exchange"}
		assert.True(t, contains(mints, "https://TESTNUT.CASHU.EXCHANGE"))
		assert.True(t, contains(mints, "https://testnut.cashu.exchange/"),
			"empty path == slash path per RFC 3986")
	})
}
