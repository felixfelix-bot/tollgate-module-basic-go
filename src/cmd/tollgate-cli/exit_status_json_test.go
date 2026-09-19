package main

import (
	"encoding/json"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// This file audits and pins the process exit status of every `--json` code path
// in the CLI, the way drain_cashu_test.go pinned it for `wallet drain cashu`
// (#375). The defect it covers: sendCommandRaw() printed a `success: false`
// payload and then exited 0, so an orchestrator that reads only the exit status
// could not tell that nothing had happened.
//
// The contract implemented here, command by command:
//
//	state-changing commands (--json):
//	    success:false payload        -> exit 1
//	    service unreachable          -> exit 1
//	read-only commands (--json):
//	    success:false payload        -> exit 0 (the JSON payload carries the
//	                                    failure; the human-readable mode keeps
//	                                    exiting 1 for the same payload)
//	    service unreachable          -> exit 1
//
// Read-only payload failures deliberately keep exit 0: they move no state, and
// a `jq`-style pipeline is expected to inspect `success`/`error` rather than the
// exit status. Every command exits non-zero when the service cannot be reached,
// because in that case even a read-only command produced no answer at all.
//
// The classification is also visible at each call site: state-changing commands
// use sendCommandStateChanging(), read-only commands use sendCommandAndDisplay().
//
// Do NOT add t.Parallel() to any test here: SocketPath, os.Stdin/Stdout/Stderr,
// the package-level cobra flag variables and the serviceCommand seam are all
// process-global state these tests deliberately swap.

type jsonCommandCase struct {
	name string
	args []string
}

// stateChangingJSONCommands is every subcommand whose --json path must exit
// non-zero when the service answers success:false.
var stateChangingJSONCommands = []jsonCommandCase{
	{"wallet fund", []string{"wallet", "fund", "cashuB-fake-token"}},
	{"wallet drain cashu", []string{"wallet", "drain", "cashu"}},
	{"network private enable", []string{"network", "private", "enable"}},
	{"network private disable", []string{"network", "private", "disable"}},
	{"network private rename", []string{"network", "private", "rename", "NewSSID"}},
	{"network private set-password", []string{"network", "private", "set-password", "correct-horse-battery"}},
	{"upstream remove", []string{"upstream", "remove", "SomeSSID"}},
	{"upstream connect", []string{"upstream", "connect", "SomeSSID", "some-passphrase"}},
	{"config set", []string{"config", "set", "metric", "milliseconds"}},
	{"config save", []string{"config", "save", `{"config_version":"v0.0.7"}`}},
	{"config save-identities", []string{"config", "save-identities", `{"config_version":"v0.0.1"}`}},
}

// readOnlyJSONCommands is every subcommand whose --json path reports a
// success:false payload in the JSON and keeps exit 0, but still exits non-zero
// when the service is unreachable.
var readOnlyJSONCommands = []jsonCommandCase{
	{"wallet balance", []string{"wallet", "balance"}},
	{"wallet info", []string{"wallet", "info"}},
	{"status", []string{"status"}},
	{"network private status", []string{"network", "private", "status"}},
	{"version", []string{"version"}},
	{"upstream scan", []string{"upstream", "scan"}},
	{"upstream list", []string{"upstream", "list"}},
	{"upstream known", []string{"upstream", "known"}},
	{"config get", []string{"config", "get"}},
	{"config schema", []string{"config", "schema"}},
	{"health", []string{"health"}},
}

func jsonArgs(args []string) []string {
	return append([]string{"--json"}, args...)
}

// stubServiceAnsweringWith installs a stub service that answers every request
// with `success:false` and the given error text.
func stubServiceAnsweringWith(t *testing.T, success bool, errText string) {
	t.Helper()
	startFakeTollGateService(t, func(msg CLIMessage) *CLIResponse {
		return &CLIResponse{
			Success:   success,
			Error:     errText,
			Timestamp: time.Now(),
		}
	})
}

// pointSocketAtMissingPath makes the CLI talk to a socket nothing is listening
// on, which is what an orchestrator sees when the TollGate service is stopped.
func pointSocketAtMissingPath(t *testing.T) {
	t.Helper()
	previous := SocketPath
	SocketPath = filepath.Join(t.TempDir(), "no-service-here.sock")
	t.Cleanup(func() { SocketPath = previous })
}

// assertJSONFailurePayload checks that stdout is the service's JSON response,
// unchanged: a single JSON object carrying success:false and the error text.
func assertJSONFailurePayload(t *testing.T, stdout string) {
	t.Helper()

	var parsed map[string]interface{}
	if err := json.Unmarshal([]byte(strings.TrimSpace(stdout)), &parsed); err != nil {
		t.Fatalf("--json output is not a single JSON object (shape must not change): %v\nstdout=%q", err, stdout)
	}
	if success, _ := parsed["success"].(bool); success {
		t.Errorf("--json payload claims success:true on a failed command: %s", stdout)
	}
	if _, ok := parsed["error"]; !ok {
		t.Errorf("--json payload has no error field: %s", stdout)
	}
}

func TestJSON_StateChangingCommand_FailureExitsNonZero(t *testing.T) {
	const errText = "stub: the service refused the command"

	for _, tc := range stateChangingJSONCommands {
		t.Run(tc.name, func(t *testing.T) {
			stubServiceAnsweringWith(t, false, errText)

			stdout, _, err := runCLIInProcess(t, "", jsonArgs(tc.args)...)
			if err == nil {
				t.Fatalf("`%s --json` exited 0 on a success:false payload, so an orchestrator reading only the exit status cannot tell that nothing happened: stdout=%s", tc.name, stdout)
			}
			if code := exitCodeFor(err); code != exitCodeFailure {
				t.Errorf("`%s --json` exit code = %d, want %d (attempted and failed)", tc.name, code, exitCodeFailure)
			}
			assertJSONFailurePayload(t, stdout)
			if !strings.Contains(stdout, errText) {
				t.Errorf("`%s --json` must print the service's error text, stdout=%s", tc.name, stdout)
			}
		})
	}
}

func TestJSON_StateChangingCommand_UnreachableExitsNonZero(t *testing.T) {
	for _, tc := range stateChangingJSONCommands {
		t.Run(tc.name, func(t *testing.T) {
			pointSocketAtMissingPath(t)

			stdout, _, err := runCLIInProcess(t, "", jsonArgs(tc.args)...)
			if err == nil {
				t.Fatalf("`%s --json` exited 0 with no service listening, so a script cannot tell that nothing happened: stdout=%s", tc.name, stdout)
			}
			if code := exitCodeFor(err); code != exitCodeFailure {
				t.Errorf("`%s --json` exit code = %d, want %d", tc.name, code, exitCodeFailure)
			}
			assertJSONFailurePayload(t, stdout)
		})
	}
}

func TestJSON_StateChangingCommand_SuccessExitsZero(t *testing.T) {
	for _, tc := range stateChangingJSONCommands {
		t.Run(tc.name, func(t *testing.T) {
			stubServiceAnsweringWith(t, true, "")

			stdout, _, err := runCLIInProcess(t, "", jsonArgs(tc.args)...)
			if err != nil {
				t.Fatalf("`%s --json` exited non-zero on a successful command: %v\nstdout=%s", tc.name, err, stdout)
			}
			var parsed map[string]interface{}
			if err := json.Unmarshal([]byte(strings.TrimSpace(stdout)), &parsed); err != nil {
				t.Fatalf("`%s --json` output is not a JSON object: %v\nstdout=%q", tc.name, err, stdout)
			}
			if success, _ := parsed["success"].(bool); !success {
				t.Errorf("`%s --json` payload lost success:true: %s", tc.name, stdout)
			}
		})
	}
}

// TestJSON_ReadOnlyCommand_FailurePayloadKeepsExitZero pins the deliberate
// read-only decision: the failure is reported inside the JSON payload and the
// exit status stays 0, so `tollgate --json status | jq .success` pipelines keep
// working. If this decision is ever reversed, reverse this test with it.
func TestJSON_ReadOnlyCommand_FailurePayloadKeepsExitZero(t *testing.T) {
	const errText = "stub: the service could not answer the query"

	for _, tc := range readOnlyJSONCommands {
		t.Run(tc.name, func(t *testing.T) {
			stubServiceAnsweringWith(t, false, errText)

			stdout, _, err := runCLIInProcess(t, "", jsonArgs(tc.args)...)
			if err != nil {
				t.Fatalf("`%s --json` exited non-zero on a success:false payload; the read-only contract is exit 0 with the failure in the JSON (documented in docs/operator-guide.md): %v", tc.name, err)
			}
			assertJSONFailurePayload(t, stdout)
		})
	}
}

func TestJSON_ReadOnlyCommand_UnreachableExitsNonZero(t *testing.T) {
	for _, tc := range readOnlyJSONCommands {
		t.Run(tc.name, func(t *testing.T) {
			pointSocketAtMissingPath(t)

			stdout, _, err := runCLIInProcess(t, "", jsonArgs(tc.args)...)
			if err == nil {
				t.Fatalf("`%s --json` exited 0 with no service listening, so a monitoring script cannot tell the service is down: stdout=%s", tc.name, stdout)
			}
			if code := exitCodeFor(err); code != exitCodeFailure {
				t.Errorf("`%s --json` exit code = %d, want %d", tc.name, code, exitCodeFailure)
			}
			assertJSONFailurePayload(t, stdout)
		})
	}
}

// stubServiceCommand makes the start/stop/restart commands run a stub binary
// instead of /etc/init.d/*, so these tests can exercise the failure path
// without starting, stopping or requiring the real router services.
func stubServiceCommand(t *testing.T, script string) {
	t.Helper()
	previous := serviceCommand
	serviceCommand = func(name string, args ...string) *exec.Cmd {
		return exec.Command("sh", "-c", script)
	}
	t.Cleanup(func() { serviceCommand = previous })
}

func TestJSON_ServiceCommand_FailureExitsNonZero(t *testing.T) {
	// A stub that exits non-zero, like an init script that could not stop the
	// service it was asked to stop.
	stubServiceCommand(t, "exit 3")

	for _, action := range []string{"start", "stop", "restart"} {
		t.Run(action, func(t *testing.T) {
			stdout, _, err := runCLIInProcess(t, "", "--json", action)
			if err == nil {
				t.Fatalf("`%s --json` exited 0 although the init script failed: stdout=%s", action, stdout)
			}
			if code := exitCodeFor(err); code != exitCodeFailure {
				t.Errorf("`%s --json` exit code = %d, want %d", action, code, exitCodeFailure)
			}
			assertJSONFailurePayload(t, stdout)
		})
	}
}

func TestJSON_ServiceCommand_SuccessExitsZero(t *testing.T) {
	stubServiceCommand(t, "exit 0")

	for _, action := range []string{"start", "stop", "restart"} {
		t.Run(action, func(t *testing.T) {
			stdout, _, err := runCLIInProcess(t, "", "--json", action)
			if err != nil {
				t.Fatalf("`%s --json` exited non-zero although the init script succeeded: %v\nstdout=%s", action, err, stdout)
			}
			var parsed map[string]interface{}
			if err := json.Unmarshal([]byte(strings.TrimSpace(stdout)), &parsed); err != nil {
				t.Fatalf("`%s --json` output is not a JSON object: %v\nstdout=%q", action, err, stdout)
			}
			if success, _ := parsed["success"].(bool); !success {
				t.Errorf("`%s --json` payload lost success:true: %s", action, stdout)
			}
		})
	}
}

// TestPrivateDisable_WithoutAnswer_CancelIsNotReportedAsSuccess covers the one
// other destructive command with a confirmation prompt: declining it (or having
// no terminal to answer with, the way `ssh router 'tollgate network private
// disable'` runs) must not look like a successful disable.
func TestPrivateDisable_WithoutAnswer_CancelIsNotReportedAsSuccess(t *testing.T) {
	for _, stdin := range []string{"n\n", ""} {
		name := "answered n"
		if stdin == "" {
			name = "no answer (no tty)"
		}
		t.Run(name, func(t *testing.T) {
			svc := startFakeTollGateService(t, func(msg CLIMessage) *CLIResponse {
				t.Fatalf("a cancelled `network private disable` must not reach the service, got %+v", msg)
				return nil
			})

			stdout, _, err := runCLIInProcess(t, stdin, "network", "private", "disable")
			if err == nil {
				t.Fatalf("a cancelled `network private disable` exited 0, so a script cannot tell the private network is still up: stdout=%s", stdout)
			}
			if code := exitCodeFor(err); code != exitCodeCancelled {
				t.Errorf("cancelled `network private disable` exit code = %d, want %d (cancelled, nothing changed)", code, exitCodeCancelled)
			}
			if !strings.Contains(stdout, "Operation cancelled.") {
				t.Errorf("the cancellation must still be reported, stdout=%s", stdout)
			}
			if requests := svc.receivedRequests(); len(requests) != 0 {
				t.Errorf("a cancelled disable sent %d request(s) to the service: %+v", len(requests), requests)
			}
		})
	}
}
