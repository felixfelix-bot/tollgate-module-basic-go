# Operator Guide

Practical reference for running a TollGate router day-to-day. Every
command below is typed into the router shell over SSH (or a serial
console). The `tollgate` binary ships inside the `tollgate-wrt`
package and talks to the running service over a Unix domain socket at
`/var/run/tollgate.sock`.

> **Prerequisite:** the TollGate service must be running. If it is not,
> commands that route through the socket report
> `failed to communicate with TollGate service`. Start it with
> `tollgate start` (or `/etc/init.d/tollgate-wrt start`).

## Command reference

```
tollgate status                           Service status (uptime, module health)
tollgate start                            Start NoDogSplash + TollGate
tollgate stop                             Stop NoDogSplash + TollGate
tollgate restart                          Restart NoDogSplash + TollGate
tollgate health                           Component health check
tollgate version                          Version + build information
tollgate logs [-n N] [-f]                 TollGate log lines (wraps logread)

tollgate wallet balance                   Total wallet balance (sats)
tollgate wallet info                      Per-mint breakdown
tollgate wallet fund [cashu-token]        Add funds from a Cashu token
tollgate wallet drain cashu               Export ALL funds as Cashu tokens

tollgate network private status           Private Wi-Fi: SSID, password, on/off
tollgate network private enable           Turn private Wi-Fi on (2.4 + 5 GHz)
tollgate network private disable          Turn private Wi-Fi off
tollgate network private rename <ssid>    Change the private SSID
tollgate network private set-password [pw] Change the private password

tollgate upstream scan                    Scan all radios for networks
tollgate upstream connect <SSID> [pass]   Connect to an upstream network
tollgate upstream list                    Show configured upstream STAs
tollgate upstream remove <SSID>           Remove a disabled upstream STA

tollgate config get                       Print current config + identities
tollgate config set <key> <value>         Set one value by dot-path
tollgate config schema                    Print the full config schema
tollgate config save <json>               Replace config.json wholesale
tollgate config save-identities <json>    Replace identities.json wholesale
```

Every command accepts the global `--json` (`-j`) flag for
machine-readable output. See [JSON output](#json-output) below.

## Service management

### Status

```sh
tollgate status
```

Reports whether the service is running, its version and uptime, and
whether the config, wallet, and upstream-network subsystems are
healthy:

```
running: true
version: v0.5.0
uptime: 4h12m
config_ok: true
wallet_ok: true
network_ok: true
```

`network_ok` reflects the upstream connectivity probe, not the private
Wi-Fi radio state.

### Start / stop / restart

```sh
tollgate start     # starts NoDogSplash first, then tollgate-wrt
tollgate stop      # stops tollgate-wrt first, then NoDogSplash
tollgate restart   # restarts both in start order
```

These wrap the OpenWrt init scripts
(`/etc/init.d/nodogsplash`, `/etc/init.d/tollgate-wrt`). Stopping the
service does **not** kick off connected customers immediately —
NoDogSplash keeps existing authorisations until their MAC entries
expire — but no new sessions can be purchased while the service is
down.

### Health

```sh
tollgate health
```

A lighter check than `status`: prints `status: ok`, the config/wallet
flags, and uptime. If the socket is unreachable it reports
`Service not reachable` and exits non-zero, making it suitable for a
monitoring cron job:

```sh
# example: alert if the service is down
tollgate health >/dev/null 2>&1 || echo "TollGate is DOWN on $(date)"
```

### Version

```sh
tollgate version
```

```
TollGate Version
version: v0.5.0
commit: a1b2c3d
build_time: 2026-07-03T10:00:00Z
go_version: go1.23.0
openwrt_version: OpenWrt 24.10.0
```

### Logs

```sh
tollgate logs            # all TollGate log lines
tollgate logs -n 50      # last 50 lines
tollgate logs -f         # follow (like tail -f)
tollgate logs -n 100 -f  # last 100, then follow
```

This wraps `logread -e tollgate`, so it captures every line the
service writes via syslog. For a raw, unfiltered view of everything
on the router (useful when debugging NoDogSplash or DHCP alongside
TollGate), use `logread` directly:

```sh
logread -f
```

## Wallet operations

The wallet holds Cashu ecash across one or more mints. Customers pay
into it; the payout routine sweeps profits to configured Lightning
addresses on a per-mint schedule.

### Check balance

```sh
tollgate wallet balance
```

```
Total wallet balance: 1284 sats
```

This is the sum across **all** mints that currently hold funds,
including mints no longer listed in `accepted_mints`.

### Detailed wallet info

```sh
tollgate wallet info
```

```
Wallet info - Total: 1284 sats across 2 mints
  mint_balances:
    https://mint.coinos.io: 900
    https://mint.minibits.cash: 384
  mint_count: 2
  total_balance: 1284
```

Only mints with a non-zero balance are shown. Use this when you need
to see *where* the funds sit (e.g. before draining or when
investigating a per-mint payout failure).

### Fund the wallet

```sh
# with the token as an argument
tollgate wallet fund cashuA...

# or interactively (the CLI prompts and reads from stdin)
tollgate wallet fund
Paste your Cashu token: <paste token>
```

The token is sent to the service, which decodes it, swaps it with the
mint to verify the proofs are unspent, and stores the new proofs. On
success:

```
Successfully funded wallet with 500 sats
```

This is the same receive path customer payments take, so it also
works for topping up from an external Cashu wallet.

### Drain funds

```sh
tollgate wallet drain cashu
```

**This removes ALL funds from the wallet.** The CLI prints a warning
and asks for confirmation:

```
⚠️  WARNING: Draining the wallet will remove ALL funds from the wallet!
The funds will be converted to Cashu tokens that will be saved to a file.
Once drained, the tokens are OUT of the wallet and must be stored securely.

Are you sure you want to drain the wallet? (y/N):
```

After confirmation, every mint with a balance is drained into a
separate Cashu token. The tokens are written to a timestamped file
(`wallet_drain_2026-07-05_14-30-00.txt`) in the current directory and
also printed to the terminal:

```
Wallet Drain Results:
====================
Total drained: 1284 sats

✓ Tokens saved to: wallet_drain_2026-07-05_14-30-00.txt

Token 1:
  Mint: https://mint.coinos.io
  Balance: 900 sats
  Token: cashuA...

Token 2:
  Mint: https://mint.minibits.cash
  Balance: 384 sats
  Token: cashuA...
```

Treat the output file as cash — anyone who reads a token string can
spend it. Copy it somewhere safe and delete the plaintext once
redeemed.

### Drain funds non-interactively

`--yes` (or `-y`) skips the confirmation prompt but keeps the
plain-text output and the token file:

```sh
tollgate wallet drain cashu --yes
```

Without it the prompt reads stdin, so `ssh router 'tollgate wallet
drain cashu'` (no terminal, no piped answer) cancels the drain. The
exit status tells a script what happened:

- `0` — drained, or there was nothing to drain.
- `1` — the drain was attempted and failed, including a partial drain.
- `2` — cancelled: no funds were moved.

A failure on one mint never hides what another mint already drained.
The tokens that were produced are printed and written to the file
*before* the error is reported, the response carries a `failures` list,
and the command still exits non-zero:

```
Partially drained 900 sats from 1 mints; 1 mint(s) failed
...
Mints that could NOT be drained:
  https://mint.minibits.cash/Bitcoin/: no balance available
```

A mint that is registered twice under URLs differing only by a trailing
slash (`.../Bitcoin` and `.../Bitcoin/`) is one mint: it is drained
once, and the duplicate entry is reported in `merged_entries` instead of
being drained a second time and failing.

> Lightning drain (`tollgate wallet drain lightning`) is not yet
> implemented; only `cashu` is supported.

## Private network management

The private Wi-Fi is the network *you* (the operator) connect to,
distinct from the captive-portal guest network. Commands operate on
both the 2.4 GHz (`radio0`) and 5 GHz (`radio1`) private interfaces
simultaneously. If the router only has one radio, the 5 GHz steps log
a warning and are skipped.

### View current settings

```sh
tollgate network private status
```

```
Private Network Configuration
=============================
SSID:     MyTollGate
Password: correct-horse-battery-09
Status:   Enabled
```

### Enable / disable

```sh
tollgate network private enable
tollgate network private disable
```

Disabling shows a lockout warning and requires confirmation, because
turning off the private Wi-Fi can cut off your only wireless access to
the router:

```
⚠️  WARNING: Disabling the private network may lock you out of the router!
Make sure you have another way to access the router (e.g., via the public
network or physical access).

Are you sure you want to disable the private network? (y/N):
```

Declining that prompt (or having no terminal to answer it with, the way
`ssh router 'tollgate network private disable'` runs) prints
`Operation cancelled.` and exits `2`: nothing was disabled, and a
script must not read that as success. With `--json` the prompt is
skipped entirely, and a `success:false` payload exits `1` like every
other state-changing command.

### Rename the SSID

```sh
tollgate network private rename MyNewNetwork
```

Changes the SSID on both radios and reloads wireless immediately. Any
device currently connected to the old SSID will be disconnected.

### Change the password

```sh
# set a specific password (must be 8–63 characters for WPA2)
tollgate network private set-password "my-new-password"

# generate a random human-readable password instead
tollgate network private set-password
```

When no password is given, a random one is generated in the form
`Word-Word-Word-NN` (e.g. `Alpha-Bravo-Charlie-42`) using a
cryptographic random source. The new password is printed back so you
can record it:

```
Private network password changed successfully
  new_password: Alpha-Bravo-Charlie-42
```

## Upstream WiFi management

Upstream Wi-Fi is how the router reaches the internet — either from
an ISP router, a mobile hotspot, or another TollGate in reseller
mode. See [docs/wireless_gateway_manager.md](wireless_gateway_manager.md)
for the background daemon that automates this; the commands below are
for manual control.

### Scan

```sh
tollgate upstream scan
```

Scans all radios and lists visible networks sorted by signal:

```
SSID                             Signal    Ch     Encryption           Radio
--------------------------------------------------------------------------------
HomeFibre                        -42 dBm   36     WPA2                radio1
TollGate-Cafe                    -55 dBm   6      WPA2                radio0
OpenGuest                        -67 dBm   11     none                radio0
```

### Connect

```sh
tollgate upstream connect HomeFibre "my-wifi-password"
tollgate upstream connect OpenGuest        # no password needed for open networks
```

Connection runs as a **streaming** operation with live progress so you
can see where it stalls:

```
  [1/7] Enabling radios...
  [2/7] Scanning for 'HomeFibre'...
  [3/7] Found 'HomeFibre' (-42 dBm on radio1) encryption=psk2
  [4/7] Setting up wwan interface...
  [5/7] Creating STA upstream_homefibre on radio1...
  [6/7] Switching upstream... waiting for DHCP
  [7/7] Connected to 'HomeFibre' via upstream_homefibre (-42 dBm on radio1)
```

The command picks the radio with the best signal for the target SSID,
creates a STA interface, and switches the upstream to it. The previous
upstream (if any) is disabled but kept in config as a fallback
candidate. After a manual connect, the background connectivity-check
daemon is **paused** for `manual_pause_seconds` (default 120 s) so it
does not immediately fight your choice.

If the SSID is not found in the scan, you get
`SSID '<name>' not found in scan` — scan again or move closer.

### List configured upstreams

```sh
tollgate upstream list
```

```
SSID                STATUS     RADIO      ENCRYPTION
-------------------------------------------------------
HomeFibre           ACTIVE     radio1     psk2
OldUpstream         disabled   radio0     psk2
```

`ACTIVE` is the interface currently providing upstream; `disabled`
entries are retained as fallback candidates.

### Remove an upstream

```sh
tollgate upstream remove OldUpstream
```

Removes a **disabled** STA section from the wireless config. Active
upstreams cannot be removed — disable or switch away first. This is
housekeeping: removing an entry does not affect connectivity, it just
stops the daemon from ever considering that SSID again.

## Configuration management

TollGate stores its configuration in `/etc/tollgate/config.json` and
identities in `/etc/tollgate/identities.json`. See the
[Configuration](../README.md#configuration) section of the README for
the full schema and an abridged example.

### View configuration

```sh
tollgate config get
```

Prints both the current config and identities. The output mirrors
what is on disk after the last successful save/reload.

### Set a single value

```sh
tollgate config set <key> <value>
```

Keys are **dot-paths** into the JSON document. The change is validated
against the schema and persisted to disk immediately:

```sh
tollgate config set metric milliseconds        # sell time instead of data
tollgate config set step_size 44040192         # adjust the billing unit
tollgate config set accepted_mints.0.price_per_step 2   # index into an array
tollgate config set show_setup false           # booleans accepted as-is
```

The CLI confirms the write, then reminds you to restart:

```
Set metric = milliseconds (restart tollgate-wrt to apply)
```

Most `config set` changes take effect only after
`tollgate restart` (or `/etc/init.d/tollgate-wrt restart`), because
the running service reads the file at startup.

### Inspect the schema

```sh
tollgate config schema
```

Outputs the full machine-readable schema for both `config` and
`identities` — every field, its type, default, and validation rules.
Use this to discover valid keys and values before calling
`config set`.

### Replace the entire config

```sh
tollgate config save '{"config_version":"v0.0.7","metric":"bytes",...}'
tollgate config save-identities '{"identities":[...]}'
```

These write the complete JSON document in one shot. The config
variant validates required fields (`config_version`, `metric`,
`step_size`, `accepted_mints`, `profit_share`) and checks that
`profit_share` factors sum correctly before writing. Prefer
`config set` for individual changes; use `save` only when provisioning
a router from a known-good template.

Both commands reload the in-memory config after writing, but a restart
is still needed for the change to take full effect.

## JSON output

Every command accepts a global `--json` (or `-j`) flag. With it, the
CLI emits structured JSON instead of the human-readable tables, and
destructive commands (`wallet drain cashu`,
`network private disable`) **skip their confirmation prompts** and act
immediately — this is intentional, so the flag can drive automation:

```sh
# script-friendly balance check
tollgate --json wallet balance

# drain without a prompt (tokens go to stdout, no file is written)
tollgate --json wallet drain cashu

# health probe for a monitoring loop
tollgate --json health
```

The JSON object always goes to **stdout**. What the CLI itself has to
say about a failure (`Error: …` and the command's usage line) goes to
stderr, so `tollgate --json … | jq …` stays parseable either way.

### Exit status with --json

There are two rules, by command class:

| Command class | `success:false` payload | service unreachable |
| --- | --- | --- |
| state-changing | exit `1` | exit `1` |
| read-only | exit `0` (the failure is in the JSON) | exit `1` |

**State-changing commands** — `wallet fund`, `wallet drain cashu`,
`network private enable` / `disable` / `rename` / `set-password`,
`upstream remove`, `config set` / `save` / `save-identities`, and
`start` / `stop` / `restart`. A `success:false` payload exits `1`: a
caller that checks only the exit status must never mistake "nothing
changed" for "the change was applied". The JSON payload is whatever the
service sent, unchanged.

**Read-only commands** — `wallet balance`, `wallet info`, `status`,
`network private status`, `version`, `upstream scan` / `list` / `known`,
`config get`, `config schema`, and `health`. A `success:false` payload
keeps exit `0`, so `tollgate --json status | jq .success` pipelines keep
working; read `.success` and `.error` instead of the exit status.

**Unreachable service** — every command, read-only included, exits
non-zero, because then not even a failed answer was produced. The JSON
still carries a `success: false` object with an `error` field rather
than prose on stderr, so a wrapper script can parse the failure and a
script that only checks the exit status is not misled either.

In plain (non `--json`) mode the rules are the same except that a
read-only failure also exits `1`, because there is no JSON payload to
carry the error.

For `wallet drain cashu` specifically: a `success: false` response
(including a partial drain) exits `1`, and any tokens that *were*
produced are part of the JSON payload under `data.tokens` together with
a `data.failures` list. Nothing is silently dropped. Note that `--json`
writes no token file; use `--yes` when you want the file output.

### ssl commands and `upstream connect`

`ssl status`, `ssl apply` and `ssl remove` never talk to the TollGate
socket: they read and write `/etc/tollgate/ssl` and the uhttpd /
dnsmasq / nodogsplash configuration directly. They used to ignore
`--json` completely; that gap is closed:

| Command | `--json` payload | exit status |
| --- | --- | --- |
| `ssl status` | one object: `success`, `configured`, `mode`, `domain`, `cert`, `key`, `subject`, `issuer`, `not_before`, `not_after`, `days_remaining`, `expired`, `san` | always `0` — read-only; a certificate that cannot be read or parsed is reported as `success:false` with an `error` field |
| `ssl apply`, `ssl remove` | one object: `success`, `action`, `mode`, `domain`, `cert`, `key`, `backup_dir`, `changed`, `cancelled`, `progress[]`, `error` | `0` applied/reverted, `1` attempted and failed, `2` the confirmation was declined (`cancelled:true`, `changed:false`, nothing was touched) |
| `upstream connect` | one JSON object per line (JSON Lines): every progress object the service sends, then its result object | `0` connected, `1` on `success:false` or an unreachable service |

For `ssl apply` / `ssl remove`, `progress` carries the same lines the
human-readable mode prints, so nothing is lost by using `--json`.
`changed` is `true` as soon as the run has modified router state, so a
run that failed part-way reports `changed:true` together with
`success:false`; read `error` (and the exit status) for the outcome.

Interactive confirmations are a terminal interaction rather than
output: under `--json` the prompt is written to **stderr**, so stdout
stays parseable. For non-interactive use either pass `--yes` (`-y`) or
redirect stdin from `/dev/null`, which declines the prompt and exits
`2` — the same contract as a cancelled `wallet drain cashu`.

## Troubleshooting

### "failed to communicate with TollGate service"

The Unix socket `/var/run/tollgate.sock` is not accepting
connections. The service is either stopped or crashed.

```sh
tollgate start                                    # or:
/etc/init.d/tollgate-wrt restart
tollgate health                                   # verify it came back
```

If it keeps crashing, check the logs:

```sh
tollgate logs -n 100
logread -e tollgate -f
```

### QR scanner says "make sure you have a camera"

The captive-portal QR scanner needs a **secure context** (HTTPS or
`localhost`) to access the camera via `getUserMedia()`. Captive
portals are served over plain HTTP, so browsers such as Brave and
Firefox on Linux block camera access entirely.

Workaround: skip the scanner and **paste the Cashu token manually**
into the portal input field, or fund the wallet from the router shell
with `tollgate wallet fund <token>`. On Chrome/Edge the scanner
usually works; on the routers where SSL/HTTPS is configured for the
captive portal domain, camera access may also succeed.

### Mint connectivity / payouts not happening

Payouts run on a per-mint timer and only fire when the balance exceeds
`min_payout_amount`. If payouts seem stuck:

```sh
tollgate wallet info                              # is there a balance to pay out?
tollgate config get                               # check payout thresholds per mint
logread -e tollgate | grep -i payout              # look for payout errors
logread -e tollgate | grep -i "Could not find"    # missing identity / Lightning addr
```

Common causes: the mint is unreachable (network issue), the profit
share references an identity not in `identities.json`, or the balance
is below `min_payout_amount` / `min_balance`.

### Private Wi-Fi not visible after enable

```sh
tollgate network private status                   # confirm it says Enabled
wifi reload                                       # force a wireless reload
logread -e hostapd                                # check the AP daemon
```

If the 5 GHz interface is in client (STA) mode for an upstream, it
cannot also serve as a private AP — this is a hardware limitation of
single-radio setups, not a bug.

### Upstream connect fails at "waiting for DHCP"

The STA interface was created and switched to, but the upstream router
did not hand out a lease within the DHCP timeout
(`dhcp_timeout_seconds`, default 180 s).

```sh
tollgate upstream scan                            # is the SSID still visible?
logread -e odhcp                                  # DHCP client logs
```

Try moving closer to the access point, verifying the password, or
checking that the upstream router is not out of DHCP leases.
