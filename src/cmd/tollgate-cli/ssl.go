package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/spf13/cobra"
)

var (
	sslDir    = "/etc/tollgate/ssl"
	backupDir = sslDir + "/backup"
	certDest  = sslDir + "/server.crt"
	keyDest   = sslDir + "/server.key"
)

var sslYesFlag bool

// runCommand runs an external command (uci, the init scripts) and returns its
// combined output. It is a variable so tests can drive the ssl flows without a
// router: there is no `uci` binary, no /etc/init.d/uhttpd and no
// /etc/tollgate/ssl on a workstation.
var runCommand = func(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func runCommandChecked(name string, args ...string) error {
	out, err := runCommand(name, args...)
	if err != nil {
		return fmt.Errorf("%s %s: %s: %w", name, strings.Join(args, " "), strings.TrimSpace(out), err)
	}
	return nil
}

// sslProgress collects the human-readable progress lines of the ssl command
// currently running when --json was requested. They become the `progress` array
// of the JSON payload instead of being mixed into it as prose. It is reset at
// the start of every ssl command.
var sslProgress []string

// sslPrintf and sslPrintln write the human-readable progress of the ssl
// commands. Under --json they are silent on stdout and the line is collected
// for the JSON payload instead, so `--json` prints exactly one JSON object.
func sslPrintf(format string, args ...interface{}) {
	sslEmit(fmt.Sprintf(format, args...))
}

func sslPrintln(args ...interface{}) {
	sslEmit(fmt.Sprintln(args...))
}

func sslEmit(text string) {
	if jsonOutput {
		sslProgress = append(sslProgress, strings.Split(strings.TrimRight(text, "\n"), "\n")...)
		return
	}
	fmt.Fprint(os.Stdout, text)
}

// sslResult is the --json payload of `tollgate ssl apply` and `ssl remove`.
//
// These commands change router state, so the exit status carries the outcome
// too: 0 = applied or reverted, 1 = attempted and failed, 2 = the confirmation
// was declined and nothing changed (then `cancelled` is true and `changed`
// false). `changed` is true as soon as the run has modified router state, so a
// run that failed part-way reports `changed:true` together with
// `success:false`. `progress` holds the same lines the human-readable mode
// prints.
type sslResult struct {
	Success   bool     `json:"success"`
	Action    string   `json:"action"`
	Mode      string   `json:"mode,omitempty"`
	Domain    string   `json:"domain,omitempty"`
	Cert      string   `json:"cert"`
	Key       string   `json:"key"`
	BackupDir string   `json:"backup_dir"`
	Changed   bool     `json:"changed"`
	Cancelled bool     `json:"cancelled,omitempty"`
	Progress  []string `json:"progress,omitempty"`
	Error     string   `json:"error,omitempty"`
	Timestamp string   `json:"timestamp"`
}

// sslReport accumulates the outcome of one `ssl apply` / `ssl remove` run.
type sslReport struct {
	action    string
	mode      string
	domain    string
	changed   bool
	cancelled bool
}

func newSSLReport(action string) *sslReport {
	sslProgress = nil
	return &sslReport{action: action}
}

// abort records a declined confirmation and returns the cancelled exit status,
// the same contract as a cancelled `wallet drain cashu` (#375) and a cancelled
// `network private disable`: the caller must be able to tell that nothing
// happened.
func (r *sslReport) abort() error {
	sslPrintln("Aborted.")
	r.cancelled = true
	r.changed = false
	return errCancelled
}

// finish reports the run. The human-readable progress was already written as it
// happened; under --json the whole outcome becomes one JSON object on stdout.
func (r *sslReport) finish(err error) error {
	if !jsonOutput {
		return err
	}

	result := sslResult{
		Success:   err == nil,
		Action:    r.action,
		Mode:      r.mode,
		Domain:    r.domain,
		Cert:      certDest,
		Key:       keyDest,
		BackupDir: backupDir,
		Changed:   r.changed,
		Cancelled: r.cancelled || errors.Is(err, errCancelled),
		Progress:  sslProgress,
		Timestamp: time.Now().Format(time.RFC3339),
	}
	if err != nil {
		result.Error = err.Error()
	}
	if printErr := printJSON(result); printErr != nil {
		return printErr
	}
	return err
}

// sslStatusResult is the --json payload of `tollgate ssl status`.
//
// ssl status is read-only and does not talk to the TollGate service, so it
// always exits 0 -- the read-only rule in docs/operator-guide.md: the state,
// including a certificate that is installed but cannot be read or parsed, is
// reported in this object.
type sslStatusResult struct {
	Success       bool     `json:"success"`
	Configured    bool     `json:"configured"`
	Mode          string   `json:"mode,omitempty"`
	Domain        string   `json:"domain,omitempty"`
	Cert          string   `json:"cert"`
	Key           string   `json:"key"`
	Subject       string   `json:"subject,omitempty"`
	Issuer        string   `json:"issuer,omitempty"`
	NotBefore     string   `json:"not_before,omitempty"`
	NotAfter      string   `json:"not_after,omitempty"`
	DaysRemaining *int     `json:"days_remaining,omitempty"`
	Expired       bool     `json:"expired,omitempty"`
	SANs          []string `json:"san,omitempty"`
	Error         string   `json:"error,omitempty"`
	Timestamp     string   `json:"timestamp"`
}

func (r sslStatusResult) finish() error {
	if !jsonOutput {
		return nil
	}
	sslProgress = nil
	return printJSON(r)
}

var sslCmd = &cobra.Command{
	Use:   "ssl",
	Short: "SSL/TLS certificate management",
	Long:  "Manage SSL certificates for the TollGate LuCI admin interface",
}

var sslApplyCmd = &cobra.Command{
	Use:   "apply [<cert-file> [key-file]]",
	Short: "Apply an SSL certificate",
	Long: `Apply an SSL certificate for HTTPS access.

Without arguments, generates a self-signed certificate for the router's hostname.
With a single PEM file, splits combined cert+key.
With two files, uses separate cert and key files.

With --json the outcome is reported as a single JSON object on stdout instead of
the human-readable progress, and the exit status reports it too: 0 = applied,
1 = the apply was attempted and failed, 2 = the confirmation was declined and
nothing changed.`,
	Args: cobra.MaximumNArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		return sslApply(args)
	},
}

var sslRemoveCmd = &cobra.Command{
	Use:   "remove",
	Short: "Remove SSL configuration",
	Long: `Revert SSL changes made by 'ssl apply', restoring previous state.

With --json the outcome is reported as a single JSON object on stdout instead of
the human-readable progress, and the exit status reports it too: 0 = reverted,
1 = the revert was attempted and failed, 2 = the confirmation was declined and
nothing changed.`,
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		return sslRemove()
	},
}

var sslStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show SSL status",
	Long: `Display current SSL certificate configuration and status.

With --json the state is reported as a single JSON object on stdout (success,
configured, mode, domain, cert, key and the parsed certificate fields). It is a
read-only command, so it always exits 0 and reports a certificate it cannot read
or parse inside that object.`,
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		return sslStatus()
	},
}

func init() {
	sslApplyCmd.Flags().BoolVarP(&sslYesFlag, "yes", "y", false, "Skip confirmation prompt")
	sslRemoveCmd.Flags().BoolVarP(&sslYesFlag, "yes", "y", false, "Skip confirmation prompt")
	sslCmd.AddCommand(sslApplyCmd, sslRemoveCmd, sslStatusCmd)
	rootCmd.AddCommand(sslCmd)
}

func confirmOrYes(msg string) bool {
	if sslYesFlag {
		return true
	}
	return askConfirmation(msg)
}

func sslApply(args []string) error {
	report := newSSLReport("apply")
	return report.finish(sslApplyRun(report, args))
}

func sslApplyRun(report *sslReport, args []string) error {
	cleanupStaleTempDirs()

	lanIP, err := uciGet("network.lan.ipaddr")
	if err != nil || lanIP == "" {
		return fmt.Errorf("cannot determine LAN IP (network.lan.ipaddr)")
	}

	if _, err := os.Stat(backupDir); err == nil {
		sslPrintln("WARNING: SSL backup already exists (SSL may already be applied).")
		sslPrintln("  Run 'tollgate ssl remove' first to cleanly revert.")
		if !confirmOrYes("Overwrite backup and re-apply?") {
			return report.abort()
		}
	}

	if len(args) == 0 {
		return sslApplySelfSigned(report, lanIP)
	}
	return sslApplyRealCert(report, args, lanIP)
}

func sslApplySelfSigned(report *sslReport, lanIP string) error {
	hostname, err := uciGet("system.@system[0].hostname")
	if err != nil || hostname == "" {
		hostname = "TollGate"
	}
	domain := hostname + ".lan"
	report.mode = "self-signed"
	report.domain = domain

	sslPrintf("Generating self-signed certificate for %s...\n", domain)

	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return fmt.Errorf("failed to generate RSA key: %w", err)
	}

	serialNumber, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))

	tmpl := &x509.Certificate{
		SerialNumber: serialNumber,
		Subject:      pkix.Name{CommonName: domain},
		NotBefore:    time.Now(),
		NotAfter:     time.Now().Add(3650 * 24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:     []string{domain, hostname},
		IPAddresses:  []net.IP{net.ParseIP(lanIP)},
	}

	certDER, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return fmt.Errorf("failed to create certificate: %w", err)
	}

	workDir, err := os.MkdirTemp("", "tollgate-ssl-*")
	if err != nil {
		return fmt.Errorf("failed to create temp dir: %w", err)
	}
	defer os.RemoveAll(workDir)

	certFile := filepath.Join(workDir, "cert.pem")
	keyFile := filepath.Join(workDir, "key.pem")

	if err := writePEM(certFile, "CERTIFICATE", certDER); err != nil {
		return err
	}
	if err := writePEM(keyFile, "RSA PRIVATE KEY", x509.MarshalPKCS1PrivateKey(key)); err != nil {
		return err
	}

	sslPrintln()
	sslPrintln("Certificate details:")
	sslPrintf("  Domain : %s (self-signed)\n", domain)
	sslPrintln("  Expires: 10 years")
	sslPrintf("  LAN IP : %s\n", lanIP)
	sslPrintln()
	sslPrintln("  NOTE: Self-signed certs are NOT trusted by browsers or RFC 8908 clients.")
	sslPrintln("  The captive portal will continue using HTTP interception.")
	sslPrintln("  LuCI admin will be accessible via HTTPS with a browser warning.")
	sslPrintln()

	sslPrintln("Changes to apply:")
	sslPrintf("  [1] Install self-signed cert+key to %s/\n", sslDir)
	sslPrintf("  [2] uhttpd: set cert='%s' key='%s'\n", certDest, keyDest)
	sslPrintln("  [3] nodogsplash: allow tcp port 443 so clients can reach uhttpd HTTPS")
	sslPrintln()

	if !confirmOrYes("Apply all?") {
		return report.abort()
	}

	if err := sslBackup("self-signed", domain, lanIP); err != nil {
		return fmt.Errorf("backup failed: %w", err)
	}
	report.changed = true

	if err := sslInstallCerts(certFile, keyFile); err != nil {
		return err
	}
	sslPrintln("[1] Self-signed certificate installed.")

	if err := configureUhttpd(); err != nil {
		return err
	}
	sslPrintln("[2] uhttpd configured.")

	if err := allowPort443(); err != nil {
		return err
	}
	sslPrintln("[3] nodogsplash firewall updated.")

	if err := reloadServices(false); err != nil {
		return err
	}

	sslPrintln()
	sslPrintf("Done. Self-signed HTTPS enabled for %s\n", domain)
	sslPrintln()
	sslPrintf("  Portal URL: http://%s/ (NoDogSplash, HTTP only)\n", domain)
	sslPrintf("  LuCI URL:   https://%s/ (uhttpd, HTTPS, self-signed)\n", domain)
	sslPrintln()
	sslPrintln("To revert: tollgate ssl remove")
	return nil
}

func sslApplyRealCert(report *sslReport, args []string, lanIP string) error {
	certFile := args[0]
	keyFile := ""
	if len(args) == 2 {
		keyFile = args[1]
	}

	if len(args) == 1 {
		cf, kf, err := splitCombinedPEM(certFile)
		if err != nil {
			return err
		}
		defer os.RemoveAll(filepath.Dir(cf))
		certFile = cf
		keyFile = kf
	}

	if _, err := os.Stat(certFile); os.IsNotExist(err) {
		return fmt.Errorf("cert file not found: %s", certFile)
	}
	if _, err := os.Stat(keyFile); os.IsNotExist(err) {
		return fmt.Errorf("key file not found: %s", keyFile)
	}

	certPEM, err := os.ReadFile(certFile)
	if err != nil {
		return fmt.Errorf("cannot read cert file: %w", err)
	}

	block, _ := pem.Decode(certPEM)
	if block == nil || block.Type != "CERTIFICATE" {
		return fmt.Errorf("not a valid PEM certificate: %s", certFile)
	}

	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return fmt.Errorf("failed to parse certificate: %w", err)
	}

	if time.Now().After(cert.NotAfter) {
		sslPrintln("WARNING: certificate has expired!")
		sslPrintln("  Continuing anyway — the cert will be installed but browsers will reject it.")
	}

	domain := extractDomain(cert)
	if domain == "" {
		return fmt.Errorf("could not extract domain from certificate (no SAN or CN found)")
	}
	report.mode = "real-cert"
	report.domain = domain

	sslPrintln()
	sslPrintln("Certificate details:")
	sslPrintf("  Domain : %s\n", domain)
	sslPrintf("  Expires: %s\n", cert.NotAfter.Format("Jan 2 15:04:05 2006 MST"))
	sslPrintf("  SAN    : %s\n", strings.Join(cert.DNSNames, ", "))
	sslPrintf("  LAN IP : %s\n", lanIP)
	sslPrintln()

	sslPrintln("Changes to apply:")
	sslPrintf("  [1] Install cert+key to %s/\n", sslDir)
	sslPrintf("  [2] uhttpd: set cert='%s' key='%s'\n", certDest, keyDest)
	sslPrintf("  [3] dnsmasq: resolve %s -> %s\n", domain, lanIP)
	sslPrintf("  [4] nodogsplash: gatewaydomainname='%s' (portal stays on HTTP port 80)\n", domain)
	sslPrintln("  [5] nodogsplash: allow tcp port 443 so clients can reach uhttpd HTTPS")
	sslPrintln()

	if !confirmOrYes("Apply all?") {
		return report.abort()
	}

	if err := sslBackup("real-cert", domain, lanIP); err != nil {
		return fmt.Errorf("backup failed: %w", err)
	}
	report.changed = true

	if err := sslInstallCerts(certFile, keyFile); err != nil {
		return err
	}
	sslPrintln("[1] Certificate installed.")

	if err := configureUhttpd(); err != nil {
		return err
	}
	sslPrintln("[2] uhttpd configured.")

	if err := configureDnsmasq(domain, lanIP); err != nil {
		return err
	}
	sslPrintf("[3] dnsmasq configured: %s -> %s\n", domain, lanIP)

	if err := configureNodogsplash(domain); err != nil {
		return err
	}
	sslPrintln("[4] nodogsplash configured.")

	if err := allowPort443(); err != nil {
		return err
	}
	sslPrintln("[5] nodogsplash firewall updated.")

	if err := reloadServices(true); err != nil {
		return err
	}

	sslPrintln()
	sslPrintf("Done. HTTPS enabled for %s\n", domain)
	sslPrintln()
	sslPrintf("  Portal URL: http://%s/ (NoDogSplash, HTTP only)\n", domain)
	sslPrintf("  LuCI URL:   https://%s/ (uhttpd, HTTPS)\n", domain)
	sslPrintln()
	sslPrintln("To revert: tollgate ssl remove")
	return nil
}

func sslRemove() error {
	report := newSSLReport("remove")
	return report.finish(sslRemoveRun(report))
}

func sslRemoveRun(report *sslReport) error {
	if _, err := os.Stat(backupDir); os.IsNotExist(err) {
		return fmt.Errorf("no SSL backup found at %s/\n  Either SSL was never applied, or the backup was deleted", backupDir)
	}

	domain := fileRead(backupDir + "/ssl.domain")
	mode := fileRead(backupDir + "/ssl.mode")
	report.mode = mode
	report.domain = domain

	if mode == "self-signed" {
		return sslRemoveSelfSigned(report, domain)
	}
	return sslRemoveRealCert(report, domain)
}

func sslRemoveSelfSigned(report *sslReport, domain string) error {
	sslPrintf("Reverting self-signed SSL configuration for: %s\n", domain)
	sslPrintln()
	sslPrintln("Changes to revert:")
	sslPrintf("  [1] Remove self-signed cert+key from %s/\n", sslDir)
	sslPrintln("  [2] uhttpd: restore previous cert configuration")
	sslPrintln("  [3] nodogsplash: remove port 443 allow rule")
	sslPrintln()

	if !confirmOrYes("Revert all?") {
		return report.abort()
	}

	os.Remove(certDest)
	os.Remove(keyDest)
	report.changed = true

	if err := restoreUhttpd(); err != nil {
		return err
	}
	sslPrintln("[1] uhttpd cert reverted.")

	if err := removePort443Allow(); err != nil {
		return err
	}
	sslPrintln("[2] nodogsplash firewall updated.")

	if err := uciCommitChecked("uhttpd"); err != nil {
		return err
	}
	if err := uciCommitChecked("nodogsplash"); err != nil {
		return err
	}
	if err := reloadServices(false); err != nil {
		return err
	}

	os.RemoveAll(backupDir)

	sslPrintln()
	sslPrintln("Done. Self-signed HTTPS removed.")
	sslPrintln("  Portal URL: http://TollGate.lan/")
	return nil
}

func sslRemoveRealCert(report *sslReport, domain string) error {
	sslPrintf("Reverting SSL configuration for: %s\n", domain)
	sslPrintln()
	sslPrintln("Changes to revert:")
	sslPrintf("  [1] Remove cert+key from %s/\n", sslDir)
	sslPrintln("  [2] uhttpd: restore previous cert configuration")
	sslPrintf("  [3] dnsmasq: remove DNS entry for %s\n", domain)
	sslPrintln("  [4] nodogsplash: revert gatewaydomainname and remove port 443 allow")
	sslPrintln()

	if !confirmOrYes("Revert all?") {
		return report.abort()
	}

	os.Remove(certDest)
	os.Remove(keyDest)
	report.changed = true

	if err := restoreUhttpd(); err != nil {
		return err
	}
	sslPrintln("[1] uhttpd cert reverted.")

	if err := removeDnsmasqDomain(domain); err != nil {
		return err
	}
	sslPrintf("[2] Removed dnsmasq entry for %s\n", domain)

	originalDomain := fileRead(backupDir + "/nds.gatewaydomainname")
	if originalDomain == "" {
		originalDomain = "TollGate.lan"
	}
	originalPort := fileRead(backupDir + "/nds.gatewayport")
	if originalPort == "" {
		originalPort = "80"
	}
	if err := uciSetScalar("nodogsplash.@nodogsplash[0].gatewaydomainname", originalDomain); err != nil {
		return err
	}
	if err := uciSetScalar("nodogsplash.@nodogsplash[0].gatewayport", originalPort); err != nil {
		return err
	}
	if err := removePort443Allow(); err != nil {
		return err
	}
	sslPrintf("[3] nodogsplash reverted to %s:%s\n", originalDomain, originalPort)

	if err := uciCommitChecked("uhttpd"); err != nil {
		return err
	}
	if err := uciCommitChecked("dhcp"); err != nil {
		return err
	}
	if err := uciCommitChecked("nodogsplash"); err != nil {
		return err
	}
	if err := reloadServices(true); err != nil {
		return err
	}

	os.RemoveAll(backupDir)

	sslPrintln()
	sslPrintln("Done. HTTPS removed. Portal now served over HTTP.")
	sslPrintf("  Portal URL: http://%s/\n", originalDomain)
	return nil
}

func sslStatus() error {
	sslProgress = nil

	mode := fileRead(backupDir + "/ssl.mode")
	domain := fileRead(backupDir + "/ssl.domain")

	result := sslStatusResult{
		Success:   true,
		Mode:      mode,
		Domain:    domain,
		Cert:      certDest,
		Key:       keyDest,
		Timestamp: time.Now().Format(time.RFC3339),
	}

	if _, err := os.Stat(certDest); os.IsNotExist(err) {
		sslPrintln("SSL: not configured")
		sslPrintln("  Run 'tollgate ssl apply' to generate a self-signed certificate")
		sslPrintln("  Run 'tollgate ssl apply <cert> [key]' to install a real certificate")
		return result.finish()
	}

	result.Configured = true
	sslPrintln("SSL: configured")
	sslPrintf("  Mode   : %s\n", mode)
	sslPrintf("  Domain : %s\n", domain)
	sslPrintf("  Cert   : %s\n", certDest)
	sslPrintf("  Key    : %s\n", keyDest)

	certPEM, err := os.ReadFile(certDest)
	if err != nil {
		result.Success = false
		result.Error = fmt.Sprintf("cannot read the installed certificate at %s: %v", certDest, err)
		return result.finish()
	}

	block, _ := pem.Decode(certPEM)
	if block == nil {
		result.Success = false
		result.Error = fmt.Sprintf("cannot parse the installed certificate at %s: no PEM block found", certDest)
		return result.finish()
	}

	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		result.Success = false
		result.Error = fmt.Sprintf("cannot parse the installed certificate at %s: %v", certDest, err)
		return result.finish()
	}

	result.Subject = cert.Subject.String()
	result.Issuer = cert.Issuer.String()
	result.NotBefore = cert.NotBefore.Format("2006-01-02 15:04:05")
	result.NotAfter = cert.NotAfter.Format("2006-01-02 15:04:05")
	result.SANs = cert.DNSNames
	if time.Now().After(cert.NotAfter) {
		result.Expired = true
	} else {
		daysLeft := int(time.Until(cert.NotAfter).Hours() / 24)
		result.DaysRemaining = &daysLeft
	}

	sslPrintf("  Subject: %s\n", cert.Subject)
	sslPrintf("  Issuer : %s\n", cert.Issuer)
	sslPrintf("  NotBefore: %s\n", result.NotBefore)
	sslPrintf("  NotAfter : %s\n", result.NotAfter)
	if result.Expired {
		sslPrintln("  WARNING: certificate has EXPIRED")
	} else {
		sslPrintf("  Days remaining: %d\n", *result.DaysRemaining)
	}
	if len(cert.DNSNames) > 0 {
		sslPrintf("  SAN    : %s\n", strings.Join(cert.DNSNames, ", "))
	}

	return result.finish()
}

func writePEM(path, pemType string, bytes []byte) error {
	f, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("failed to create %s: %w", path, err)
	}
	defer f.Close()
	return pem.Encode(f, &pem.Block{Type: pemType, Bytes: bytes})
}

func splitCombinedPEM(inputPath string) (certFile, keyFile string, err error) {
	data, err := os.ReadFile(inputPath)
	if err != nil {
		return "", "", fmt.Errorf("cannot read file: %w", err)
	}

	var certBlocks, keyBlocks []byte
	remaining := data
	for {
		var block *pem.Block
		block, remaining = pem.Decode(remaining)
		if block == nil {
			break
		}
		switch block.Type {
		case "CERTIFICATE":
			buf := pem.EncodeToMemory(block)
			certBlocks = append(certBlocks, buf...)
		case "PRIVATE KEY", "RSA PRIVATE KEY", "EC PRIVATE KEY":
			buf := pem.EncodeToMemory(block)
			keyBlocks = append(keyBlocks, buf...)
		}
	}

	if len(certBlocks) == 0 && len(keyBlocks) == 0 {
		return "", "", fmt.Errorf("no PEM certificate or key blocks found in: %s", inputPath)
	}
	if len(certBlocks) == 0 {
		return "", "", fmt.Errorf("private key found but no certificate in: %s\n  Provide a cert file as the first argument", inputPath)
	}
	if len(keyBlocks) == 0 {
		return "", "", fmt.Errorf("certificate found but no private key in: %s\n  Provide a key file as the second argument", inputPath)
	}

	workDir, err := os.MkdirTemp("", "tollgate-ssl-split-*")
	if err != nil {
		return "", "", fmt.Errorf("failed to create temp dir: %w", err)
	}

	cf := workDir + "/cert.pem"
	kf := workDir + "/key.pem"
	if err := os.WriteFile(cf, certBlocks, 0644); err != nil {
		return "", "", err
	}
	if err := os.WriteFile(kf, keyBlocks, 0600); err != nil {
		return "", "", err
	}

	return cf, kf, nil
}

func extractDomain(cert *x509.Certificate) string {
	for _, name := range cert.DNSNames {
		if name != "" {
			return name
		}
	}
	if cert.Subject.CommonName != "" {
		return cert.Subject.CommonName
	}
	return ""
}

func sslBackup(mode, domain, lanIP string) error {
	if err := os.MkdirAll(backupDir, 0755); err != nil {
		return fmt.Errorf("failed to create backup dir: %w", err)
	}

	writeBackupFile(backupDir+"/uhttpd.cert", uciGetOrEmpty("uhttpd.main.cert"))
	writeBackupFile(backupDir+"/uhttpd.key", uciGetOrEmpty("uhttpd.main.key"))
	writeBackupFile(backupDir+"/nds.gatewaydomainname", uciGetOrEmpty("nodogsplash.@nodogsplash[0].gatewaydomainname"))
	writeBackupFile(backupDir+"/nds.gatewayport", uciGetOrEmpty("nodogsplash.@nodogsplash[0].gatewayport"))
	writeBackupFile(backupDir+"/ssl.domain", domain)
	writeBackupFile(backupDir+"/ssl.lan_ip", lanIP)
	writeBackupFile(backupDir+"/ssl.mode", mode)

	out, _ := runCommand("uci", "show", "dhcp")
	lines := filterLines(out, "=domain")
	writeBackupFile(backupDir+"/dnsmasq.domains", strings.Join(lines, "\n"))

	sslPrintf("Backup saved to %s/\n", backupDir)
	return nil
}

func sslInstallCerts(certFile, keyFile string) error {
	if err := os.MkdirAll(sslDir, 0755); err != nil {
		return fmt.Errorf("failed to create SSL dir: %w", err)
	}

	if err := copyFile(certFile, certDest); err != nil {
		return fmt.Errorf("failed to install cert: %w", err)
	}
	if err := copyFile(keyFile, keyDest); err != nil {
		return fmt.Errorf("failed to install key: %w", err)
	}
	os.Chmod(keyDest, 0600)
	os.Chmod(certDest, 0644)
	return nil
}

func configureUhttpd() error {
	if err := uciSetScalar("uhttpd.main.cert", certDest); err != nil {
		return err
	}
	if err := uciSetScalar("uhttpd.main.key", keyDest); err != nil {
		return err
	}

	listenHTTPS := uciGetList("uhttpd.main.listen_https")
	if !listContains(listenHTTPS, "0.0.0.0:443") {
		if err := runCommandChecked("uci", "add_list", "uhttpd.main.listen_https=0.0.0.0:443"); err != nil {
			return err
		}
	}
	if !listContains(listenHTTPS, "[::]:443") {
		if err := runCommandChecked("uci", "add_list", "uhttpd.main.listen_https=[::]:443"); err != nil {
			return err
		}
	}
	return uciCommitChecked("uhttpd")
}

func configureDnsmasq(domain, lanIP string) error {
	if err := removeDnsmasqDomainIfExists(domain); err != nil {
		return err
	}

	if err := runCommandChecked("uci", "add", "dhcp", "domain"); err != nil {
		return err
	}
	if err := uciSetScalar("dhcp.@domain[-1].name", domain); err != nil {
		return err
	}
	if err := uciSetScalar("dhcp.@domain[-1].ip", lanIP); err != nil {
		return err
	}
	return uciCommitChecked("dhcp")
}

func configureNodogsplash(domain string) error {
	if err := uciSetScalar("nodogsplash.@nodogsplash[0].gatewaydomainname", domain); err != nil {
		return err
	}
	return uciCommitChecked("nodogsplash")
}

func allowPort443() error {
	ndsUsers := uciGetList("nodogsplash.@nodogsplash[0].users_to_router")
	if !listContains(ndsUsers, "allow tcp port 443") {
		if err := runCommandChecked("uci", "add_list", "nodogsplash.@nodogsplash[0].users_to_router=allow tcp port 443"); err != nil {
			return err
		}
	}
	return uciCommitChecked("nodogsplash")
}

func removePort443Allow() error {
	return runCommandChecked("uci", "-q", "del_list", "nodogsplash.@nodogsplash[0].users_to_router=allow tcp port 443")
}

func removeDnsmasqDomain(domain string) error {
	if err := removeDnsmasqDomainIfExists(domain); err != nil {
		return err
	}
	return uciCommitChecked("dhcp")
}

func removeDnsmasqDomainIfExists(domain string) error {
	out, _ := runCommand("uci", "show", "dhcp")
	lines := filterLines(out, "=domain")
	for _, line := range lines {
		dotParts := strings.SplitN(line, ".", 2)
		if len(dotParts) < 2 {
			continue
		}
		eqParts := strings.SplitN(dotParts[1], "=", 2)
		if len(eqParts) < 1 {
			continue
		}
		idx := eqParts[0]
		name := uciGetOrEmpty("dhcp." + idx + ".name")
		if name == domain {
			return runCommandChecked("uci", "-q", "delete", "dhcp."+idx)
		}
	}
	return nil
}

func restoreUhttpd() error {
	prevCert := fileRead(backupDir + "/uhttpd.cert")
	prevKey := fileRead(backupDir + "/uhttpd.key")
	restored := false

	if prevCert != "" {
		if _, err := os.Stat(prevCert); err == nil {
			if err := uciSetScalar("uhttpd.main.cert", prevCert); err != nil {
				return err
			}
			restored = true
		}
	}
	if prevKey != "" {
		if _, err := os.Stat(prevKey); err == nil {
			if err := uciSetScalar("uhttpd.main.key", prevKey); err != nil {
				return err
			}
			restored = true
		}
	}

	if !restored {
		if _, err := os.Stat("/etc/uhttpd.crt"); err == nil {
			if _, err := os.Stat("/etc/uhttpd.key"); err == nil {
				if err := uciSetScalar("uhttpd.main.cert", "/etc/uhttpd.crt"); err != nil {
					return err
				}
				if err := uciSetScalar("uhttpd.main.key", "/etc/uhttpd.key"); err != nil {
					return err
				}
				return nil
			}
		}
		if err := runCommandChecked("uci", "-q", "delete", "uhttpd.main.cert"); err != nil {
			return err
		}
		if err := runCommandChecked("uci", "-q", "delete", "uhttpd.main.key"); err != nil {
			return err
		}
		if err := runCommandChecked("uci", "-q", "delete", "uhttpd.main.listen_https"); err != nil {
			return err
		}
	}
	return nil
}

func reloadServices(realCert bool) error {
	if err := runCommandChecked("/etc/init.d/uhttpd", "reload"); err != nil {
		return fmt.Errorf("failed to reload uhttpd: %w", err)
	}
	if realCert {
		if err := runCommandChecked("/etc/init.d/dnsmasq", "reload"); err != nil {
			return fmt.Errorf("failed to reload dnsmasq: %w", err)
		}
	}
	if err := runCommandChecked("/etc/init.d/nodogsplash", "restart"); err != nil {
		return fmt.Errorf("failed to restart nodogsplash: %w", err)
	}
	return nil
}

func cleanupStaleTempDirs() {
	matches, _ := filepath.Glob(os.TempDir() + "/tollgate-ssl-*")
	for _, m := range matches {
		os.RemoveAll(m)
	}
	matches, _ = filepath.Glob(os.TempDir() + "/tollgate-ssl-split-*")
	for _, m := range matches {
		os.RemoveAll(m)
	}
}

func fileRead(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

func writeBackupFile(path, content string) {
	if content != "" {
		os.WriteFile(path, []byte(content+"\n"), 0644)
	}
}

func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0644)
}

func filterLines(input, contains string) []string {
	var result []string
	for _, line := range strings.Split(input, "\n") {
		if strings.Contains(line, contains) {
			result = append(result, line)
		}
	}
	return result
}

func uciGet(key string) (string, error) {
	out, err := runCommand("uci", "-q", "get", key)
	return strings.TrimSpace(out), err
}

func uciGetOrEmpty(key string) string {
	out, _ := uciGet(key)
	return out
}

func uciGetList(key string) []string {
	out := uciGetOrEmpty(key)
	if out == "" {
		return nil
	}
	var result []string
	for _, field := range strings.Fields(out) {
		cleaned := strings.Trim(field, "'")
		if cleaned != "" {
			result = append(result, cleaned)
		}
	}
	return result
}

func listContains(list []string, value string) bool {
	for _, item := range list {
		if item == value {
			return true
		}
	}
	return false
}

func uciSetScalar(key, value string) error {
	return runCommandChecked("uci", "set", key+"="+value)
}

func uciCommitChecked(config string) error {
	return runCommandChecked("uci", "commit", config)
}
