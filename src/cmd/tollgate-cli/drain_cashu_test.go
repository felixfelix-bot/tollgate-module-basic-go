package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// This file covers defect 1 of
// https://github.com/OpenTollGate/tollgate-module-basic-go/issues/375:
// `tollgate wallet drain cashu` printed "Operation cancelled." and exited 0
// when run without a PTY (the normal way an orchestrator, cron job or CI calls
// it over ssh), so no caller could tell that nothing had happened. No --yes /
// --force flag existed to skip the prompt non-interactively either.
//
// The tests here build the real CLI and run it as a child process, because the
// defect is about the *process exit code*, which an in-process call cannot
// observe. They only exercise paths that cancel before the CLI contacts the
// service, so they can never drain a real wallet on a machine that happens to
// be running a live TollGate service.
//
// Do NOT add t.Parallel() to any test in this file: SocketPath, os.Stdin/Stdout
// /Stderr and the package-level cobra flag variables are process-global state
// that these tests deliberately swap.

var (
	buildOnce    sync.Once
	builtCLIPath string
	buildErr     error
)

// buildCLIUnderTest compiles the CLI once per test binary.
func buildCLIUnderTest(t *testing.T) string {
	t.Helper()

	buildOnce.Do(func() {
		dir, err := os.MkdirTemp("", "tollgate-cli-drain-test")
		if err != nil {
			buildErr = err
			return
		}
		bin := filepath.Join(dir, "tollgate")
		cmd := exec.Command("go", "build", "-o", bin, ".")
		out, err := cmd.CombinedOutput()
		if err != nil {
			buildErr = err
			t.Logf("go build output: %s", out)
			return
		}
		builtCLIPath = bin
	})
	if buildErr != nil {
		t.Fatalf("building the CLI under test: %v", buildErr)
	}
	return builtCLIPath
}

// runCLIProcess runs the CLI with stdin closed (that is: no PTY and no piped
// input, which is what `ssh host 'tollgate wallet drain cashu'` looks like).
func runCLIProcess(t *testing.T, args ...string) (string, string, int) {
	t.Helper()

	cmd := exec.Command(buildCLIUnderTest(t), args...)
	// A nil Stdin gives the child /dev/null: every read returns EOF, exactly
	// like an ssh session with no terminal attached.
	cmd.Stdin = nil
	var stdout, stderr strings.Builder
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()

	code := 0
	if exitErr, ok := err.(*exec.ExitError); ok {
		code = exitErr.ExitCode()
	} else if err != nil {
		t.Fatalf("running %v: %v", args, err)
	}
	return stdout.String(), stderr.String(), code
}

func TestDrainCashu_WithoutTTY_CancelIsNotReportedAsSuccess(t *testing.T) {
	stdout, stderr, code := runCLIProcess(t, "wallet", "drain", "cashu")

	if !strings.Contains(stdout+stderr, "Operation cancelled.") {
		t.Fatalf("expected the cancellation to be reported, got stdout=%q stderr=%q", stdout, stderr)
	}
	if code == 0 {
		t.Fatalf("a drain that did NOT happen exited 0: an orchestrator cannot tell this from a completed drain (stdout=%q)", stdout)
	}
	if code != exitCodeCancelled {
		t.Errorf("cancelled drain exited %d, want the documented %d for \"cancelled, no funds moved\"", code, exitCodeCancelled)
	}
}

func TestDrainCashu_OffersNonInteractiveConfirmationFlag(t *testing.T) {
	stdout, _, code := runCLIProcess(t, "wallet", "drain", "cashu", "--help")
	if code != 0 {
		t.Fatalf("`wallet drain cashu --help` exited %d", code)
	}

	hasYes := strings.Contains(stdout, "--yes") || strings.Contains(stdout, "-y,")
	if !hasYes {
		t.Fatalf("no non-interactive confirmation flag is offered; automation is forced onto --json, which is the flag that loses funds (#375)\nhelp output:\n%s", stdout)
	}
}

// fakeTollGateService is a stub of the TollGate service socket. It records the
// messages the CLI sends and answers with a canned response.
type fakeTollGateService struct {
	ln      net.Listener
	respond func(CLIMessage) *CLIResponse

	mu       sync.Mutex
	requests []CLIMessage
}

// startFakeTollGateService points the CLI at a stub service for the duration of
// the test, so no test can ever talk to a real TollGate (and drain a real
// wallet) by accident.
func startFakeTollGateService(t *testing.T, respond func(CLIMessage) *CLIResponse) *fakeTollGateService {
	t.Helper()

	socketDir, err := os.MkdirTemp("", "tgsock")
	if err != nil {
		t.Fatalf("temp dir for stub socket: %v", err)
	}
	t.Cleanup(func() { os.RemoveAll(socketDir) })

	// Keep the path short: a unix socket path is capped at ~100 bytes and the
	// test name alone can exceed that under a deep TMPDIR.
	socketPath := filepath.Join(socketDir, "s.sock")
	ln, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("listen on stub socket %s: %v", socketPath, err)
	}

	svc := &fakeTollGateService{ln: ln, respond: respond}

	previousSocketPath := SocketPath
	SocketPath = socketPath
	t.Cleanup(func() {
		SocketPath = previousSocketPath
		ln.Close()
	})

	go svc.serve()
	return svc
}

func (s *fakeTollGateService) serve() {
	for {
		conn, err := s.ln.Accept()
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

			s.mu.Lock()
			s.requests = append(s.requests, msg)
			s.mu.Unlock()

			data, err := json.Marshal(s.respond(msg))
			if err != nil {
				return
			}
			if _, err := c.Write(append(data, '\n')); err != nil {
				// A truncated response would otherwise surface as a confusing
				// unmarshal failure inside the CLI under test.
				fmt.Fprintf(os.Stderr, "stub service: write response: %v\n", err)
				return
			}
		}(conn)
	}
}

func (s *fakeTollGateService) receivedRequests() []CLIMessage {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]CLIMessage(nil), s.requests...)
}

// runCLIInProcess executes the CLI in this process with the given stdin, so the
// command's own behaviour (prompt handling, token rendering, error) can be
// asserted without spawning a binary.
func runCLIInProcess(t *testing.T, stdin string, args ...string) (string, string, error) {
	t.Helper()

	// cobra writes its flags into package-level variables that outlive a single
	// Execute call, so reset the ones these commands read. Any new flag added to
	// drainCashuCmd or the ssl commands (and read by them) must be reset here
	// too.
	jsonOutput = false
	drainCashuYes = false
	sslYesFlag = false

	stdinFile, err := os.CreateTemp(t.TempDir(), "stdin")
	if err != nil {
		t.Fatalf("stdin temp file: %v", err)
	}
	if _, err := stdinFile.WriteString(stdin); err != nil {
		t.Fatalf("write stdin: %v", err)
	}
	if _, err := stdinFile.Seek(0, io.SeekStart); err != nil {
		t.Fatalf("seek stdin: %v", err)
	}

	stdoutR, stdoutW, err := os.Pipe()
	if err != nil {
		t.Fatalf("stdout pipe: %v", err)
	}
	stderrR, stderrW, err := os.Pipe()
	if err != nil {
		t.Fatalf("stderr pipe: %v", err)
	}

	previousStdin, previousStdout, previousStderr := os.Stdin, os.Stdout, os.Stderr
	os.Stdin, os.Stdout, os.Stderr = stdinFile, stdoutW, stderrW
	defer func() {
		os.Stdin, os.Stdout, os.Stderr = previousStdin, previousStdout, previousStderr
	}()

	type pipedOutput struct {
		data []byte
		err  error
	}
	stdoutDone := make(chan pipedOutput, 1)
	stderrDone := make(chan pipedOutput, 1)
	go func() { b, err := io.ReadAll(stdoutR); stdoutDone <- pipedOutput{b, err} }()
	go func() { b, err := io.ReadAll(stderrR); stderrDone <- pipedOutput{b, err} }()

	rootCmd.SetArgs(args)
	execErr := rootCmd.Execute()

	stdoutW.Close()
	stderrW.Close()
	stdoutResult := <-stdoutDone
	stderrResult := <-stderrDone

	if stdoutResult.err != nil {
		t.Fatalf("read stdout: %v", stdoutResult.err)
	}
	if stderrResult.err != nil {
		t.Fatalf("read stderr: %v", stderrResult.err)
	}

	return string(stdoutResult.data), string(stderrResult.data), execErr
}

// chdirToTempDir runs the test in a scratch directory so a drain written to a
// relative filename cannot touch the developer's checkout.
func chdirToTempDir(t *testing.T) string {
	t.Helper()

	workDir := t.TempDir()
	previousWorkDir, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	if err := os.Chdir(workDir); err != nil {
		t.Fatalf("chdir: %v", err)
	}
	t.Cleanup(func() { os.Chdir(previousWorkDir) })
	return workDir
}

// drainServiceResponse builds the wire response a service sends for a drain
// where `drained` succeeded and `failed` did not.
func drainServiceResponse(msg CLIMessage, drained []map[string]interface{}, failed []map[string]interface{}) *CLIResponse {
	var total uint64
	for _, tok := range drained {
		if balance, ok := tok["balance_sats"].(uint64); ok {
			total += balance
		}
	}

	result := map[string]interface{}{
		"success":    len(failed) == 0,
		"tokens":     drained,
		"total_sats": total,
	}
	if len(failed) > 0 {
		result["failures"] = failed
	}
	if filename := msg.Flags["save_to_file"]; filename != "" {
		result["save_to_file"] = filename
	}

	resp := &CLIResponse{
		Success:   len(failed) == 0,
		Data:      result,
		Timestamp: time.Now(),
	}
	if len(failed) == 0 {
		resp.Message = fmt.Sprintf("Successfully drained %d sats from %d mints", total, len(drained))
	} else {
		resp.Message = fmt.Sprintf("Partially drained %d sats from %d mints; %d mint(s) failed", total, len(drained), len(failed))
		resp.Error = fmt.Sprintf("failed to drain %d mint(s): %s: no balance available - %d sats from %d mint(s) WERE drained; those tokens are included in this response and must be stored before retrying", len(failed), failed[0]["mint_url"], total, len(drained))
	}
	return resp
}

func TestDrainCashu_YesFlag_SkipsPromptAndPersistsTokens(t *testing.T) {
	const token = "cashuB-yes-flag-token"
	const mint = "https://mint.example/Bitcoin"

	svc := startFakeTollGateService(t, func(msg CLIMessage) *CLIResponse {
		return drainServiceResponse(msg, []map[string]interface{}{
			{"mint_url": mint, "balance_sats": uint64(50), "token": token},
		}, nil)
	})

	workDir := chdirToTempDir(t)

	stdout, _, err := runCLIInProcess(t, "", "wallet", "drain", "cashu", "--yes")
	if err != nil {
		t.Fatalf("`wallet drain cashu --yes` failed: %v\nstdout: %s", err, stdout)
	}
	if strings.Contains(stdout, "Are you sure you want to drain the wallet?") {
		t.Errorf("--yes must skip the confirmation prompt, stdout: %s", stdout)
	}

	requests := svc.receivedRequests()
	if len(requests) != 1 {
		t.Fatalf("expected exactly 1 drain request, got %d", len(requests))
	}
	if requests[0].Command != "wallet" || len(requests[0].Args) != 2 || requests[0].Args[1] != "cashu" {
		t.Errorf("unexpected request: %+v", requests[0])
	}

	filename := requests[0].Flags["save_to_file"]
	if filename == "" {
		t.Fatal("the drain request carried no save_to_file flag, so nothing would be persisted")
	}

	saved, err := os.ReadFile(filepath.Join(workDir, filename))
	if err != nil {
		t.Fatalf("drain token file was not written: %v", err)
	}
	if !strings.Contains(string(saved), token) {
		t.Errorf("the drained token is not in %s: %s", filename, saved)
	}
}

// TestDrainCashu_YesFlag_PartialFailure_PersistsTokensAndExitsNonZero is the
// composed funds-loss scenario of #375 in plain (non --json) mode: the service
// returns success=false but the response still contains the token a completed
// swap produced. The client must print it, write it to the file, and exit
// non-zero so the caller knows the drain did not fully complete.
func TestDrainCashu_YesFlag_PartialFailure_PersistsTokensAndExitsNonZero(t *testing.T) {
	const token = "cashuB-plain-partial-token"
	const good = "https://good.example"
	const stale = "https://stale.example"

	startFakeTollGateService(t, func(msg CLIMessage) *CLIResponse {
		return drainServiceResponse(msg,
			[]map[string]interface{}{
				{"mint_url": good, "balance_sats": uint64(50), "token": token},
			},
			[]map[string]interface{}{
				{"mint_url": stale, "error": "no balance available"},
			},
		)
	})

	workDir := chdirToTempDir(t)

	stdout, stderr, err := runCLIInProcess(t, "", "wallet", "drain", "cashu", "--yes")
	if err == nil {
		t.Fatalf("a partial drain exited 0, so a script cannot tell that funds moved: stdout=%s", stdout)
	}
	if code := exitCodeFor(err); code != exitCodeFailure {
		t.Errorf("partial drain exit code = %d, want %d (attempted and failed)", code, exitCodeFailure)
	}
	if !strings.Contains(stdout, token) {
		t.Errorf("the token produced by the mint that DID drain must be printed so it can be recovered, stdout=%s", stdout)
	}
	if !strings.Contains(stdout, stale) {
		t.Errorf("the mint that failed must be reported to the operator, stdout=%s", stdout)
	}
	if strings.Contains(stdout+stderr, "Are you sure you want to drain the wallet?") {
		t.Errorf("--yes must skip the confirmation prompt, stdout=%s stderr=%s", stdout, stderr)
	}

	// The token file is the durable copy: it must exist and hold the token,
	// even though the command reported failure.
	matches, err := filepath.Glob(filepath.Join(workDir, "wallet_drain_*.txt"))
	if err != nil {
		t.Fatalf("glob drain files: %v", err)
	}
	if len(matches) != 1 {
		t.Fatalf("want exactly one drain token file in %s, got %v", workDir, matches)
	}
	saved, err := os.ReadFile(matches[0])
	if err != nil {
		t.Fatalf("read %s: %v", matches[0], err)
	}
	if !strings.Contains(string(saved), token) {
		t.Errorf("the token produced by the completed swap is not in %s: %s", matches[0], saved)
	}
}

func TestDrainCashu_JSON_PartialFailure_ExitsNonZeroWithRecoverableTokens(t *testing.T) {
	const token = "cashuB-partial-token"

	startFakeTollGateService(t, func(msg CLIMessage) *CLIResponse {
		return drainServiceResponse(msg,
			[]map[string]interface{}{
				{"mint_url": "https://good.example", "balance_sats": uint64(50), "token": token},
			},
			[]map[string]interface{}{
				{"mint_url": "https://stale.example", "error": "no balance available"},
			},
		)
	})

	stdout, _, err := runCLIInProcess(t, "", "--json", "wallet", "drain", "cashu")
	if err == nil {
		t.Fatalf("a partial drain exited 0, so a script cannot tell that funds moved: stdout=%s", stdout)
	}
	if code := exitCodeFor(err); code != exitCodeFailure {
		t.Errorf("exitCodeFor(partial drain error) = %d, want %d", code, exitCodeFailure)
	}
	if !strings.Contains(stdout, token) {
		t.Errorf("the token produced by the mint that DID drain must be emitted so it can be recovered, stdout=%s", stdout)
	}
	if !strings.Contains(stdout, "failures") {
		t.Errorf("the JSON payload must report the mint that failed, stdout=%s", stdout)
	}
	if !strings.Contains(stdout, `"success": false`) {
		t.Errorf("the JSON payload must not look like a success, stdout=%s", stdout)
	}
}

func TestExitCodeFor(t *testing.T) {
	if code := exitCodeFor(nil); code != 0 {
		t.Errorf("exitCodeFor(nil) = %d, want 0", code)
	}
	if code := exitCodeFor(errCancelled); code != exitCodeCancelled {
		t.Errorf("exitCodeFor(errCancelled) = %d, want %d: the documented contract is 2 = cancelled, nothing happened", code, exitCodeCancelled)
	}
	if code := exitCodeFor(errors.New("boom")); code != exitCodeFailure {
		t.Errorf("exitCodeFor(generic error) = %d, want %d: the documented contract is 1 = attempted and failed", code, exitCodeFailure)
	}
}
