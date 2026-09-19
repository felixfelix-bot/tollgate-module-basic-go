package main

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// This file pins the --json contract of the ssl subcommands and of
// `upstream connect`, and the exit status of a declined ssl confirmation.
//
// Before this change `ssl apply|remove|status` did not read jsonOutput at all:
// `--json` printed the human-readable text and was silently ignored. Declining
// any of the five ssl confirmation prompts printed "Aborted." and returned nil,
// i.e. exit 0 — the same "nothing happened, but the caller cannot tell" hazard
// as a cancelled `wallet drain cashu` (#375) and a cancelled `network private
// disable` (see exit_status_json_test.go). `upstream connect` streamed prose
// through sendCommandStreaming() and ignored the flag too.
//
// The contract implemented here:
//
//	ssl status        (read-only)       -> exit 0 always; the state and any
//	                                       read/parse failure are in the JSON
//	ssl apply/remove  (state-changing)  -> exit 1 on failure, exit 2 when the
//	                                       confirmation was declined, 0 on success
//	upstream connect  (state-changing)  -> one JSON object per line (JSON Lines)
//	                                       for every progress and result object
//	                                       the service sends; exit 1 on
//	                                       success:false or an unreachable service
//
// The ssl commands never talk to the TollGate service socket, so they are not in
// the stateChangingJSONCommands / readOnlyJSONCommands tables of
// exit_status_json_test.go: those tables assert on the service being
// unreachable, which is meaningless for a command that reads local files.
//
// Do NOT add t.Parallel() to any test here: sslDir/backupDir/certDest/keyDest,
// the runCommand seam, SocketPath and os.Stdin/Stdout are package-global state
// these tests deliberately swap.

// redirectSSLPaths points every ssl path at a scratch directory for the
// duration of the test, so no test can read or write /etc/tollgate/ssl.
func redirectSSLPaths(t *testing.T) string {
	t.Helper()

	previousDir, previousBackup := sslDir, backupDir
	previousCert, previousKey := certDest, keyDest

	root := t.TempDir()
	sslDir = filepath.Join(root, "ssl")
	backupDir = filepath.Join(sslDir, "backup")
	certDest = filepath.Join(sslDir, "server.crt")
	keyDest = filepath.Join(sslDir, "server.key")

	t.Cleanup(func() {
		sslDir, backupDir, certDest, keyDest = previousDir, previousBackup, previousCert, previousKey
	})
	return root
}

// routerCommandStub records the uci and init-script invocations the ssl flows
// make.
type routerCommandStub struct {
	mu    sync.Mutex
	calls []string
}

func (s *routerCommandStub) record(call string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls = append(s.calls, call)
}

// all returns every recorded call.
func (s *routerCommandStub) all() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.calls...)
}

// stateChanging returns the recorded calls that would change router state
// (uci writes, commits and init-script runs), i.e. everything except the plain
// `uci -q get` reads a command performs while it is still only describing what
// it would do.
func (s *routerCommandStub) stateChanging() []string {
	var out []string
	for _, call := range s.all() {
		if strings.Contains(call, "uci -q get ") {
			continue
		}
		out = append(out, call)
	}
	return out
}

// stubRouterCommands answers the uci reads and init-script calls the ssl flows
// make, so they can run to completion on a workstation: there is no `uci`
// binary, no /etc/init.d/uhttpd and no /etc/tollgate/ssl here, and the test
// asserts on the CLI's own behaviour rather than on a router.
func stubRouterCommands(t *testing.T) *routerCommandStub {
	t.Helper()

	stub := &routerCommandStub{}
	previous := runCommand
	runCommand = func(name string, args ...string) (string, error) {
		call := strings.TrimSpace(name + " " + strings.Join(args, " "))
		stub.record(call)

		switch call {
		case "uci -q get network.lan.ipaddr":
			return "192.168.1.1", nil
		case "uci -q get system.@system[0].hostname":
			return "testrouter", nil
		}
		return "", nil
	}
	t.Cleanup(func() { runCommand = previous })

	return stub
}

// writeSSLBackupState puts the ssl directory into the state `ssl apply` leaves
// behind, so `ssl remove` can be driven without running apply first.
func writeSSLBackupState(t *testing.T, mode, domain string, withCert bool) {
	t.Helper()

	if err := os.MkdirAll(backupDir, 0755); err != nil {
		t.Fatalf("create backup dir: %v", err)
	}
	for name, content := range map[string]string{"ssl.mode": mode, "ssl.domain": domain} {
		if err := os.WriteFile(filepath.Join(backupDir, name), []byte(content+"\n"), 0644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}

	if !withCert {
		return
	}
	certPEM, keyPEM := makeTestCertPEM(t)
	if err := os.WriteFile(certDest, certPEM, 0644); err != nil {
		t.Fatalf("write cert: %v", err)
	}
	if err := os.WriteFile(keyDest, keyPEM, 0600); err != nil {
		t.Fatalf("write key: %v", err)
	}
}

// parseJSONObject requires stdout to be exactly one JSON object: a --json run
// that also printed human-readable progress lines fails here.
func parseJSONObject(t *testing.T, stdout string) map[string]interface{} {
	t.Helper()

	var parsed map[string]interface{}
	if err := json.Unmarshal([]byte(strings.TrimSpace(stdout)), &parsed); err != nil {
		t.Fatalf("stdout is not a single JSON object: %v\nstdout=%q", err, stdout)
	}
	return parsed
}

// parseJSONLines requires every non-empty stdout line to be a JSON object and
// returns them in order.
func parseJSONLines(t *testing.T, stdout string) []map[string]interface{} {
	t.Helper()

	var objects []map[string]interface{}
	for _, line := range strings.Split(strings.TrimSpace(stdout), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var obj map[string]interface{}
		if err := json.Unmarshal([]byte(line), &obj); err != nil {
			t.Fatalf("stdout is not JSON Lines: line %q: %v\nstdout=%q", line, err, stdout)
		}
		objects = append(objects, obj)
	}
	return objects
}

func jsonBoolField(t *testing.T, obj map[string]interface{}, key string) bool {
	t.Helper()

	value, ok := obj[key]
	if !ok {
		return false
	}
	boolean, ok := value.(bool)
	if !ok {
		t.Fatalf("JSON field %q is %T, want bool: %v", key, value, obj)
	}
	return boolean
}

func jsonStringField(t *testing.T, obj map[string]interface{}, key string) string {
	t.Helper()

	value, ok := obj[key]
	if !ok {
		t.Fatalf("JSON payload has no %q field: %v", key, obj)
	}
	str, ok := value.(string)
	if !ok {
		t.Fatalf("JSON field %q is %T, want string: %v", key, value, obj)
	}
	return str
}

// startStreamingStubService answers one connection with a whole stream of
// responses, the way the service answers `upstream connect` on the wire.
func startStreamingStubService(t *testing.T, respond func(CLIMessage) []*CLIResponse) {
	t.Helper()

	socketDir, err := os.MkdirTemp("", "tgsock-stream")
	if err != nil {
		t.Fatalf("temp dir for stub socket: %v", err)
	}
	t.Cleanup(func() { os.RemoveAll(socketDir) })

	// Keep the path short: a unix socket path is capped at ~100 bytes.
	socketPath := filepath.Join(socketDir, "s.sock")
	ln, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("listen on stub socket %s: %v", socketPath, err)
	}

	previousSocketPath := SocketPath
	SocketPath = socketPath
	t.Cleanup(func() {
		SocketPath = previousSocketPath
		ln.Close()
	})

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()

				line, err := bufio.NewReaderSize(c, 8192).ReadBytes('\n')
				if err != nil {
					return
				}
				var msg CLIMessage
				if err := json.Unmarshal(line, &msg); err != nil {
					return
				}

				for _, response := range respond(msg) {
					data, err := json.Marshal(response)
					if err != nil {
						return
					}
					if _, err := c.Write(append(data, '\n')); err != nil {
						return
					}
				}
			}(conn)
		}
	}()
}

func TestSSLStatus_JSON_NotConfigured(t *testing.T) {
	redirectSSLPaths(t)

	stdout, _, err := runCLIInProcess(t, "", "--json", "ssl", "status")
	if err != nil {
		t.Fatalf("`ssl status --json` exited non-zero with no certificate configured: a read-only command reports the state in the JSON (see docs/operator-guide.md)\n%v\nstdout=%s", err, stdout)
	}

	obj := parseJSONObject(t, stdout)
	if !jsonBoolField(t, obj, "success") {
		t.Errorf("`ssl status --json` reported success:false for the ordinary \"no certificate yet\" state: %s", stdout)
	}
	if jsonBoolField(t, obj, "configured") {
		t.Errorf("`ssl status --json` claims a certificate is configured, but none was installed: %s", stdout)
	}
	if got := jsonStringField(t, obj, "cert"); got != certDest {
		t.Errorf("`ssl status --json` cert field = %q, want %q", got, certDest)
	}
}

func TestSSLStatus_JSON_Configured(t *testing.T) {
	redirectSSLPaths(t)
	writeSSLBackupState(t, "self-signed", "test.local", true)

	stdout, _, err := runCLIInProcess(t, "", "--json", "ssl", "status")
	if err != nil {
		t.Fatalf("`ssl status --json` exited non-zero on a configured router: %v\nstdout=%s", err, stdout)
	}

	obj := parseJSONObject(t, stdout)
	if !jsonBoolField(t, obj, "success") {
		t.Errorf("`ssl status --json` reported success:false although the certificate is readable: %s", stdout)
	}
	if !jsonBoolField(t, obj, "configured") {
		t.Errorf("`ssl status --json` did not report the installed certificate: %s", stdout)
	}
	if got := jsonStringField(t, obj, "mode"); got != "self-signed" {
		t.Errorf("mode = %q, want %q", got, "self-signed")
	}
	if got := jsonStringField(t, obj, "domain"); got != "test.local" {
		t.Errorf("domain = %q, want %q", got, "test.local")
	}
	if got := jsonStringField(t, obj, "not_after"); got == "" {
		t.Error("not_after is empty; the certificate expiry has to be machine-readable")
	}
	if _, ok := obj["days_remaining"]; !ok {
		t.Errorf("days_remaining is missing: %s", stdout)
	}
	if !strings.Contains(jsonStringField(t, obj, "subject"), "test.local") {
		t.Errorf("subject = %q, want it to carry the certificate subject", jsonStringField(t, obj, "subject"))
	}
}

func TestSSLStatus_JSON_UnreadableCertificate(t *testing.T) {
	redirectSSLPaths(t)
	if err := os.MkdirAll(sslDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(certDest, []byte("this is not a PEM certificate"), 0644); err != nil {
		t.Fatal(err)
	}

	stdout, _, err := runCLIInProcess(t, "", "--json", "ssl", "status")
	if err != nil {
		t.Fatalf("`ssl status --json` exited non-zero when the installed certificate could not be parsed; the read-only contract keeps exit 0 and puts the failure in the JSON\n%v\nstdout=%s", err, stdout)
	}

	obj := parseJSONObject(t, stdout)
	if jsonBoolField(t, obj, "success") {
		t.Errorf("`ssl status --json` reported success:true although the certificate could not be parsed: %s", stdout)
	}
	if !jsonBoolField(t, obj, "configured") {
		t.Errorf("`ssl status --json` must still report the certificate file it could not parse: %s", stdout)
	}
	if got := jsonStringField(t, obj, "error"); !strings.Contains(got, "certificate") {
		t.Errorf("error = %q, want it to name the unreadable certificate", got)
	}
}

func TestSSLStatus_PlainTextUnchanged(t *testing.T) {
	redirectSSLPaths(t)

	stdout, _, err := runCLIInProcess(t, "", "ssl", "status")
	if err != nil {
		t.Fatalf("`ssl status` exited non-zero: %v\nstdout=%s", err, stdout)
	}
	if !strings.Contains(stdout, "SSL: not configured") {
		t.Errorf("plain-text output changed; want the human-readable status line, got: %s", stdout)
	}
	if strings.HasPrefix(strings.TrimSpace(stdout), "{") {
		t.Errorf("plain-text mode must not print JSON: %s", stdout)
	}
}

func TestSSLApply_JSON_Success(t *testing.T) {
	redirectSSLPaths(t)
	stubRouterCommands(t)

	stdout, _, err := runCLIInProcess(t, "y\n", "--json", "ssl", "apply")
	if err != nil {
		t.Fatalf("`ssl apply --json` exited non-zero on a successful apply: %v\nstdout=%s", err, stdout)
	}

	obj := parseJSONObject(t, stdout)
	if !jsonBoolField(t, obj, "success") {
		t.Errorf("`ssl apply --json` reported success:false after a successful apply: %s", stdout)
	}
	if got := jsonStringField(t, obj, "action"); got != "apply" {
		t.Errorf("action = %q, want %q", got, "apply")
	}
	if got := jsonStringField(t, obj, "mode"); got != "self-signed" {
		t.Errorf("mode = %q, want %q", got, "self-signed")
	}
	if got := jsonStringField(t, obj, "domain"); got != "testrouter.lan" {
		t.Errorf("domain = %q, want %q", got, "testrouter.lan")
	}
	if !jsonBoolField(t, obj, "changed") {
		t.Errorf("changed = false after a successful apply, but the router state was modified: %s", stdout)
	}
	if jsonBoolField(t, obj, "cancelled") {
		t.Errorf("cancelled = true after a confirmed apply: %s", stdout)
	}

	if _, err := os.Stat(certDest); err != nil {
		t.Errorf("`ssl apply --json` did not install the certificate: %v", err)
	}
	if _, err := os.Stat(keyDest); err != nil {
		t.Errorf("`ssl apply --json` did not install the key: %v", err)
	}
	if progress, ok := obj["progress"].([]interface{}); !ok || len(progress) == 0 {
		t.Errorf("the --json payload dropped the human-readable progress detail: %s", stdout)
	}
}

func TestSSLApply_JSON_DeclinedPromptExitsCancelled(t *testing.T) {
	redirectSSLPaths(t)
	stub := stubRouterCommands(t)

	stdout, _, err := runCLIInProcess(t, "n\n", "--json", "ssl", "apply")
	if err == nil {
		t.Fatalf("a declined `ssl apply --json` exited 0, so a script cannot tell that no certificate was installed\nstdout=%s", stdout)
	}
	if code := exitCodeFor(err); code != exitCodeCancelled {
		t.Errorf("declined `ssl apply --json` exit code = %d, want %d (cancelled, nothing changed)", code, exitCodeCancelled)
	}

	obj := parseJSONObject(t, stdout)
	if jsonBoolField(t, obj, "success") {
		t.Errorf("a declined apply reported success:true: %s", stdout)
	}
	if !jsonBoolField(t, obj, "cancelled") {
		t.Errorf("a declined apply must say cancelled:true: %s", stdout)
	}
	if jsonBoolField(t, obj, "changed") {
		t.Errorf("a declined apply must say changed:false: %s", stdout)
	}
	if _, err := os.Stat(certDest); !os.IsNotExist(err) {
		t.Errorf("a declined apply installed a certificate at %s", certDest)
	}
	if calls := stub.stateChanging(); len(calls) != 0 {
		t.Errorf("a declined apply changed router state: %v", calls)
	}
}

func TestSSLApply_DeclinedPromptExitsCancelled_PlainText(t *testing.T) {
	redirectSSLPaths(t)
	stubRouterCommands(t)

	stdout, _, err := runCLIInProcess(t, "n\n", "ssl", "apply")
	if err == nil {
		t.Fatalf("a declined `ssl apply` exited 0, so a script cannot tell that nothing was applied\nstdout=%s", stdout)
	}
	if code := exitCodeFor(err); code != exitCodeCancelled {
		t.Errorf("declined `ssl apply` exit code = %d, want %d", code, exitCodeCancelled)
	}
	if !strings.Contains(stdout, "Aborted.") {
		t.Errorf("the declined prompt must still be reported in plain-text mode, got: %s", stdout)
	}
	if !strings.Contains(stdout, "(y/N)") {
		t.Errorf("in plain-text mode the prompt belongs on stdout with the rest of the interaction, got: %s", stdout)
	}
}

// TestSSLPrompts_JSONModeKeepsStdoutParsable pins where the interactive prompt
// goes: a prompt is a terminal interaction, not output, so under --json it must
// not be spliced into the middle of the JSON document on stdout.
func TestSSLPrompts_JSONModeKeepsStdoutParsable(t *testing.T) {
	redirectSSLPaths(t)
	stubRouterCommands(t)

	stdout, stderr, err := runCLIInProcess(t, "n\n", "--json", "ssl", "apply")
	if err == nil {
		t.Fatalf("a declined `ssl apply --json` exited 0\nstdout=%s", stdout)
	}
	if strings.Contains(stdout, "(y/N)") {
		t.Errorf("the prompt leaked into stdout, so nothing can parse the JSON payload: %q", stdout)
	}
	if !strings.Contains(stderr, "Apply all? (y/N)") {
		t.Errorf("the prompt must still be shown to the operator, on stderr under --json; stderr=%q", stderr)
	}
	parseJSONObject(t, stdout)
}

func TestSSLApply_JSON_DeclinedOverwritePromptExitsCancelled(t *testing.T) {
	redirectSSLPaths(t)
	stub := stubRouterCommands(t)
	writeSSLBackupState(t, "self-signed", "old.lan", true)

	stdout, _, err := runCLIInProcess(t, "n\n", "--json", "ssl", "apply")
	if err == nil {
		t.Fatalf("declining the \"backup already exists\" prompt exited 0, so the caller cannot tell that nothing was re-applied\nstdout=%s", stdout)
	}
	if code := exitCodeFor(err); code != exitCodeCancelled {
		t.Errorf("exit code = %d, want %d (cancelled, nothing changed)", code, exitCodeCancelled)
	}

	obj := parseJSONObject(t, stdout)
	if !jsonBoolField(t, obj, "cancelled") {
		t.Errorf("the payload must say cancelled:true: %s", stdout)
	}
	if jsonBoolField(t, obj, "changed") {
		t.Errorf("the payload must say changed:false: %s", stdout)
	}
	if got := fileRead(backupDir + "/ssl.mode"); got != "self-signed" {
		t.Errorf("the existing backup was modified: ssl.mode = %q", got)
	}
	if calls := stub.stateChanging(); len(calls) != 0 {
		t.Errorf("declining the overwrite prompt still changed router state: %v", calls)
	}
}

func TestSSLApplyRealCert_JSON_DeclinedPromptExitsCancelled(t *testing.T) {
	redirectSSLPaths(t)
	stub := stubRouterCommands(t)

	certPEM, keyPEM := makeTestCertPEM(t)
	srcDir := t.TempDir()
	certFile := filepath.Join(srcDir, "server.crt")
	keyFile := filepath.Join(srcDir, "server.key")
	if err := os.WriteFile(certFile, certPEM, 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keyFile, keyPEM, 0600); err != nil {
		t.Fatal(err)
	}

	stdout, _, err := runCLIInProcess(t, "n\n", "--json", "ssl", "apply", certFile, keyFile)
	if err == nil {
		t.Fatalf("a declined `ssl apply <cert> <key>` exited 0\nstdout=%s", stdout)
	}
	if code := exitCodeFor(err); code != exitCodeCancelled {
		t.Errorf("exit code = %d, want %d (cancelled, nothing changed)", code, exitCodeCancelled)
	}

	obj := parseJSONObject(t, stdout)
	if !jsonBoolField(t, obj, "cancelled") {
		t.Errorf("the payload must say cancelled:true: %s", stdout)
	}
	if _, err := os.Stat(certDest); !os.IsNotExist(err) {
		t.Errorf("a declined apply installed a certificate at %s", certDest)
	}
	if calls := stub.stateChanging(); len(calls) != 0 {
		t.Errorf("a declined apply changed router state: %v", calls)
	}
}

func TestSSLRemoveSelfSigned_JSON_DeclinedPromptExitsCancelled(t *testing.T) {
	redirectSSLPaths(t)
	stub := stubRouterCommands(t)
	writeSSLBackupState(t, "self-signed", "testrouter.lan", true)

	stdout, _, err := runCLIInProcess(t, "n\n", "--json", "ssl", "remove")
	if err == nil {
		t.Fatalf("a declined `ssl remove --json` exited 0, so a script cannot tell that HTTPS is still configured\nstdout=%s", stdout)
	}
	if code := exitCodeFor(err); code != exitCodeCancelled {
		t.Errorf("exit code = %d, want %d (cancelled, nothing changed)", code, exitCodeCancelled)
	}

	obj := parseJSONObject(t, stdout)
	if got := jsonStringField(t, obj, "action"); got != "remove" {
		t.Errorf("action = %q, want %q", got, "remove")
	}
	if !jsonBoolField(t, obj, "cancelled") {
		t.Errorf("the payload must say cancelled:true: %s", stdout)
	}
	if jsonBoolField(t, obj, "changed") {
		t.Errorf("the payload must say changed:false: %s", stdout)
	}
	if _, err := os.Stat(certDest); err != nil {
		t.Errorf("a declined remove deleted the certificate: %v", err)
	}
	if _, err := os.Stat(backupDir); err != nil {
		t.Errorf("a declined remove deleted the backup: %v", err)
	}
	if calls := stub.stateChanging(); len(calls) != 0 {
		t.Errorf("a declined remove changed router state: %v", calls)
	}
}

func TestSSLRemoveRealCert_JSON_DeclinedPromptExitsCancelled(t *testing.T) {
	redirectSSLPaths(t)
	stub := stubRouterCommands(t)
	writeSSLBackupState(t, "real-cert", "testrouter.lan", true)

	stdout, _, err := runCLIInProcess(t, "n\n", "--json", "ssl", "remove")
	if err == nil {
		t.Fatalf("a declined `ssl remove --json` exited 0 for a real certificate\nstdout=%s", stdout)
	}
	if code := exitCodeFor(err); code != exitCodeCancelled {
		t.Errorf("exit code = %d, want %d (cancelled, nothing changed)", code, exitCodeCancelled)
	}

	obj := parseJSONObject(t, stdout)
	if got := jsonStringField(t, obj, "mode"); got != "real-cert" {
		t.Errorf("mode = %q, want %q", got, "real-cert")
	}
	if !jsonBoolField(t, obj, "cancelled") {
		t.Errorf("the payload must say cancelled:true: %s", stdout)
	}
	if _, err := os.Stat(certDest); err != nil {
		t.Errorf("a declined remove deleted the certificate: %v", err)
	}
	if calls := stub.stateChanging(); len(calls) != 0 {
		t.Errorf("a declined remove changed router state: %v", calls)
	}
}

func TestSSLRemove_JSON_Success(t *testing.T) {
	redirectSSLPaths(t)
	stubRouterCommands(t)
	writeSSLBackupState(t, "self-signed", "testrouter.lan", true)

	stdout, _, err := runCLIInProcess(t, "y\n", "--json", "ssl", "remove")
	if err != nil {
		t.Fatalf("`ssl remove --json` exited non-zero on a successful revert: %v\nstdout=%s", err, stdout)
	}

	obj := parseJSONObject(t, stdout)
	if !jsonBoolField(t, obj, "success") {
		t.Errorf("`ssl remove --json` reported success:false after a successful revert: %s", stdout)
	}
	if got := jsonStringField(t, obj, "action"); got != "remove" {
		t.Errorf("action = %q, want %q", got, "remove")
	}
	if !jsonBoolField(t, obj, "changed") {
		t.Errorf("changed = false after a successful revert: %s", stdout)
	}
	if _, err := os.Stat(certDest); !os.IsNotExist(err) {
		t.Errorf("`ssl remove --json` left the certificate in place")
	}
	if _, err := os.Stat(backupDir); !os.IsNotExist(err) {
		t.Errorf("`ssl remove --json` left the backup in place")
	}
}

func TestUpstreamConnect_JSON_StreamsProgressAndResult(t *testing.T) {
	startStreamingStubService(t, func(msg CLIMessage) []*CLIResponse {
		return []*CLIResponse{
			{Progress: "scanning radios", Timestamp: time.Now()},
			{Success: true, Message: "connected to CafeWiFi", Timestamp: time.Now()},
		}
	})

	stdout, _, err := runCLIInProcess(t, "", "--json", "upstream", "connect", "CafeWiFi", "hunter2")
	if err != nil {
		t.Fatalf("`upstream connect --json` exited non-zero on a successful connect: %v\nstdout=%s", err, stdout)
	}

	lines := parseJSONLines(t, stdout)
	if len(lines) != 2 {
		t.Fatalf("want 2 JSON Lines objects (progress, result), got %d: %s", len(lines), stdout)
	}
	if got := jsonStringField(t, lines[0], "progress"); got != "scanning radios" {
		t.Errorf("progress line = %q, want %q", got, "scanning radios")
	}
	if !jsonBoolField(t, lines[1], "success") {
		t.Errorf("the final object must carry the service's success:true: %s", stdout)
	}
	if got := jsonStringField(t, lines[1], "message"); !strings.Contains(got, "CafeWiFi") {
		t.Errorf("the final object lost the service's message: %q", got)
	}
}

func TestUpstreamConnect_JSON_FailureExitsNonZero(t *testing.T) {
	const errText = "stub: no such SSID"

	startStreamingStubService(t, func(msg CLIMessage) []*CLIResponse {
		return []*CLIResponse{
			{Progress: "scanning radios", Timestamp: time.Now()},
			{Success: false, Error: errText, Timestamp: time.Now()},
		}
	})

	stdout, _, err := runCLIInProcess(t, "", "--json", "upstream", "connect", "CafeWiFi")
	if err == nil {
		t.Fatalf("`upstream connect --json` exited 0 on a success:false result, so an orchestrator cannot tell that no upstream was configured\nstdout=%s", stdout)
	}
	if code := exitCodeFor(err); code != exitCodeFailure {
		t.Errorf("exit code = %d, want %d (attempted and failed)", code, exitCodeFailure)
	}

	lines := parseJSONLines(t, stdout)
	if len(lines) != 2 {
		t.Fatalf("want 2 JSON Lines objects, got %d: %s", len(lines), stdout)
	}
	if jsonBoolField(t, lines[1], "success") {
		t.Errorf("the final object must carry success:false: %s", stdout)
	}
	if got := jsonStringField(t, lines[1], "error"); got != errText {
		t.Errorf("the final object lost the service's error: %q", got)
	}
}

func TestUpstreamConnect_JSON_StreamWithoutResultExitsNonZero(t *testing.T) {
	startStreamingStubService(t, func(msg CLIMessage) []*CLIResponse {
		return []*CLIResponse{{Progress: "scanning radios", Timestamp: time.Now()}}
	})

	stdout, _, err := runCLIInProcess(t, "", "--json", "upstream", "connect", "CafeWiFi")
	if err == nil {
		t.Fatalf("`upstream connect --json` exited 0 although the service never sent a result object\nstdout=%s", stdout)
	}
	if code := exitCodeFor(err); code != exitCodeFailure {
		t.Errorf("exit code = %d, want %d", code, exitCodeFailure)
	}

	lines := parseJSONLines(t, stdout)
	if len(lines) != 2 {
		t.Fatalf("want the progress object plus a JSON error object, got %d: %s", len(lines), stdout)
	}
	if jsonBoolField(t, lines[1], "success") {
		t.Errorf("the error object must carry success:false: %s", stdout)
	}
}

func TestUpstreamConnect_JSON_UnreachableExitsNonZero(t *testing.T) {
	pointSocketAtMissingPath(t)

	stdout, _, err := runCLIInProcess(t, "", "--json", "upstream", "connect", "CafeWiFi")
	if err == nil {
		t.Fatalf("`upstream connect --json` exited 0 with no service listening\nstdout=%s", stdout)
	}
	if code := exitCodeFor(err); code != exitCodeFailure {
		t.Errorf("exit code = %d, want %d", code, exitCodeFailure)
	}

	lines := parseJSONLines(t, stdout)
	if len(lines) != 1 {
		t.Fatalf("want a single JSON Lines error object, got %d: %s", len(lines), stdout)
	}
	if jsonBoolField(t, lines[0], "success") {
		t.Errorf("the error object must carry success:false: %s", stdout)
	}
	if got := jsonStringField(t, lines[0], "error"); !strings.Contains(got, "TollGate service") {
		t.Errorf("error = %q, want it to name the unreachable service", got)
	}
}

func TestUpstreamConnect_PlainTextUnchanged(t *testing.T) {
	startStreamingStubService(t, func(msg CLIMessage) []*CLIResponse {
		return []*CLIResponse{
			{Progress: "scanning radios", Timestamp: time.Now()},
			{Success: true, Message: "connected to CafeWiFi", Timestamp: time.Now()},
		}
	})

	stdout, _, err := runCLIInProcess(t, "", "upstream", "connect", "CafeWiFi")
	if err != nil {
		t.Fatalf("`upstream connect` exited non-zero on a successful connect: %v\nstdout=%s", err, stdout)
	}
	if !strings.Contains(stdout, "scanning radios") {
		t.Errorf("plain-text mode dropped the progress line: %s", stdout)
	}
	if strings.HasPrefix(strings.TrimSpace(stdout), "{") {
		t.Errorf("plain-text mode must not print JSON: %s", stdout)
	}
}

// TestSSLAndUpstreamConnect_HelpDocumentsJSON checks the flag contract is
// discoverable in the command's own description. The generated "Global Flags"
// block lists --json for every command, so this looks at the description part
// of the help output only (everything before "Usage:").
func TestSSLAndUpstreamConnect_HelpDocumentsJSON(t *testing.T) {
	for _, args := range [][]string{
		{"ssl", "apply", "--help"},
		{"ssl", "remove", "--help"},
		{"ssl", "status", "--help"},
		{"upstream", "connect", "--help"},
	} {
		t.Run(strings.Join(args, " "), func(t *testing.T) {
			stdout, _, err := runCLIInProcess(t, "", args...)
			if err != nil {
				t.Fatalf("--help exited non-zero: %v\nstdout=%s", err, stdout)
			}

			head, _, found := strings.Cut(stdout, "Usage:")
			if !found {
				t.Fatalf("no Usage: section in the help output: %s", stdout)
			}
			if !strings.Contains(head, "--json") {
				t.Errorf("the command description does not mention --json, so the flag contract is not discoverable:\n%s", head)
			}
		})
	}
}
