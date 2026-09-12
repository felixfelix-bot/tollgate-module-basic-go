package cli

import "time"

// CLIMessage represents communication between CLI client and service
type CLIMessage struct {
	Command   string            `json:"command"`
	Args      []string          `json:"args,omitempty"`
	Flags     map[string]string `json:"flags,omitempty"`
	Timestamp time.Time         `json:"timestamp"`
}

// CLIResponse represents a response from the service
type CLIResponse struct {
	Success   bool        `json:"success"`
	Message   string      `json:"message,omitempty"`
	Data      interface{} `json:"data,omitempty"`
	Error     string      `json:"error,omitempty"`
	Progress  string      `json:"progress,omitempty"`
	Timestamp time.Time   `json:"timestamp"`
}

// WalletInfo represents wallet information
type WalletInfo struct {
	Balance     uint64 `json:"balance_sats"`
	Address     string `json:"address,omitempty"`
	DrainTarget string `json:"drain_target,omitempty"`
}

// CashuToken represents a Cashu token for a specific mint
type CashuToken struct {
	MintURL string `json:"mint_url"`
	Balance uint64 `json:"balance_sats"`
	Token   string `json:"token"`
}

// MintDrainFailure records a mint whose registered entries could not be drained
type MintDrainFailure struct {
	MintURL string `json:"mint_url"`
	Error   string `json:"error"`
}

// WalletDrainResult represents the result of draining a wallet
type WalletDrainResult struct {
	Success bool         `json:"success"`
	Tokens  []CashuToken `json:"tokens"`
	Total   uint64       `json:"total_sats"`
	// Failures lists the mints that could not be drained. Tokens still carries
	// everything that WAS drained, so a partial drain never hides the tokens a
	// completed swap already produced (#375).
	Failures []MintDrainFailure `json:"failures,omitempty"`
	// MergedEntries lists registry entries that describe the same mint as
	// another entry (for example a stale trailing-slash duplicate) and were
	// therefore drained once instead of twice.
	MergedEntries []string `json:"merged_entries,omitempty"`
	// SaveToFile, when requested by the caller, is the file the client writes
	// the tokens to.
	SaveToFile string `json:"save_to_file,omitempty"`
}

// ServiceStatus represents basic service status
type ServiceStatus struct {
	Running   bool   `json:"running"`
	Version   string `json:"version"`
	Uptime    string `json:"uptime"`
	ConfigOK  bool   `json:"config_ok"`
	WalletOK  bool   `json:"wallet_ok"`
	NetworkOK bool   `json:"network_ok"`
}

// PrivateNetworkInfo represents private network configuration
type PrivateNetworkInfo struct {
	SSID     string `json:"ssid"`
	Password string `json:"password"`
	Enabled  bool   `json:"enabled"`
}

type UpstreamNetwork struct {
	SSID         string `json:"ssid"`
	Signal       int    `json:"signal"`
	Channel      string `json:"channel"`
	Encryption   string `json:"encryption"`
	BSSID        string `json:"bssid"`
	Radio        string `json:"radio"`
	IsTollGate   bool   `json:"is_tollgate"`
	PricePerStep int    `json:"price_per_step,omitempty"`
	StepSize     int    `json:"step_size,omitempty"`
}

type UpstreamSTA struct {
	SSID       string `json:"ssid"`
	Status     string `json:"status"`
	Radio      string `json:"radio"`
	Encryption string `json:"encryption"`
}
