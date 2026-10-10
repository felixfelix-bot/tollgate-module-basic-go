#!/usr/bin/env bash
# enable-org-ci-runner.sh
#
# Register a self-hosted GitHub Actions runner for an ORGANISATION, so CI and
# especially the OpenWrt builds execute on the VPS instead of a metered home
# connection.
#
# Run from a machine that can (a) authenticate to GitHub as an ORG OWNER and
# (b) SSH to the runner host.
#
#   curl -fsSL <url> | bash
#
# Overrides:
#   ORG=OpenTollGate
#   RUNNER_HOST=debian@<vps-ip-or-ula>      (default: vps3 hermes-nvme)
#   RUNNER_NAME=openTollGate-vps3-01
#   RUNNER_LABELS=self-hosted,linux,x64,openwrt-builder
#   SSH_KEY=~/.ssh/id_hermes_vps
#   SSH_JUMP=user@<mesh-jump-host>          (required if you have no NetBird route)
#   GH_TOKEN=<org-owner-pat>   (otherwise uses the active `gh` account)
#
# Self-gating: dies on the first red, never half-registers.

set -euo pipefail

ORG="${ORG:-OpenTollGate}"
RUNNER_HOST="${RUNNER_HOST:-debian@fdb8:d8ff:833c:6814:5865:55ac:3c98:afd9}"  # vps3 hermes-nvme (allows :22 on the mesh iface)
RUNNER_NAME="${RUNNER_NAME:-openTollGate-vps3-01}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,x64,openwrt-builder}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_hermes_vps}"
SVC="actions.runner.${ORG}.${RUNNER_NAME}.service"

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=12)
[[ -n "${SSH_JUMP:-}" ]] && SSH_OPTS+=(-J "$SSH_JUMP")
[[ -r "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

bold() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*" >&2; }
die()  { bad "$*"; exit 1; }

# --------------------------------------------------------------- 0. preflight
bold "preflight"
command -v gh  >/dev/null || die "gh CLI not found. Install it and re-run."
command -v ssh >/dev/null || die "ssh not found."
ACTIVE_USER="$(gh api user --jq .login 2>/dev/null || true)"
[[ -n "$ACTIVE_USER" ]] || die "no GitHub auth. Run 'gh auth login', or re-run as:
         GH_TOKEN=<org-owner-pat> bash -c \"\$(curl -fsSL <url>)\""
ok "authenticated as: $ACTIVE_USER"

# ------------------------------------------- 1. DIAGNOSE the org Actions policy
bold "diagnosing org Actions policy (usually the real reason runs never start)"
PERMS="$(gh api "/orgs/$ORG/actions/permissions" 2>&1 || true)"
if [[ "$PERMS" == *'"message"'* ]]; then
  bad "cannot read the org Actions policy:"; sed 's/^/       /' <<<"$PERMS"
  die "this account is NOT an owner/admin of $ORG (or the token lacks admin:org).
       Re-run with an org-owner credential:
         GH_TOKEN=<owner-pat> bash -c \"\$(curl -fsSL <url>)\""
fi
echo "$PERMS" | jq -C . 2>/dev/null || echo "$PERMS"
if [[ "$(jq -r '.enabled // empty' <<<"$PERMS" 2>/dev/null)" == "false" ]]; then
  die "Actions are DISABLED for $ORG; no runner can help. Enable them first:
         gh api -X PUT /orgs/$ORG/actions/permissions -f enabled=true -f allowed_actions=all"
fi
ok "Actions enabled for $ORG"

# ------------------------------------------------------- 2. reach the host
bold "reaching runner host: $RUNNER_HOST"
HOSTINFO="$(ssh "${SSH_OPTS[@]}" "$RUNNER_HOST" \
  'uname -m; nproc; df -Pk / | tail -1 | awk "{print \$4}"' 2>&1)" || {
  bad "cannot SSH to $RUNNER_HOST"; sed 's/^/       /' <<<"$HOSTINFO"
  warn "the runner host is on the NetBird mesh (ULA fdb8:…/fdfd:…) — you need a mesh route."
  warn "from a machine WITHOUT the mesh, hop through one that has it:  SSH_JUMP=user@<mesh-jump-host>"
  die "fix access to the host (check the mesh/VPN is up) and re-run."; }
ARCH_RAW="$(sed -n 1p <<<"$HOSTINFO")"
NPROC="$(sed -n 2p <<<"$HOSTINFO")"
FREE_GB=$(( $(sed -n 3p <<<"$HOSTINFO") / 1024 / 1024 ))
case "$ARCH_RAW" in
  x86_64|amd64)  RUNNER_ARCH=x64   ;;
  aarch64|arm64) RUNNER_ARCH=arm64 ;;
  *) die "unsupported runner arch: $ARCH_RAW" ;;
esac
ok "host: $ARCH_RAW, ${NPROC} cores, ${FREE_GB} GB free"
(( FREE_GB >= 6 )) || die "only ${FREE_GB} GB free on the runner host; need >= 6 GB."

# ------------------------------------------------------- 3. registration token
bold "requesting an org registration token"
TOKEN="$(gh api -X POST "/orgs/$ORG/actions/runners/registration-token" --jq .token 2>/dev/null || true)"
[[ -n "$TOKEN" ]] || die "could not mint a registration token — not an org owner/admin of $ORG."
ok "token minted (ephemeral, ~1 h)"

# ------------------------------------------------------- 4. install + configure
bold "installing the runner on the host"
# shellcheck disable=SC2087  # unquoted on purpose: ${ORG}/${TOKEN}/${RUNNER_*} expand locally
ssh "${SSH_OPTS[@]}" "$RUNNER_HOST" 'bash -s' <<REMOTE
set -euo pipefail
cd "\$HOME"
mkdir -p actions-runner && cd actions-runner
VER="\$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed 's/^v//')"
TARBALL="actions-runner-linux-${RUNNER_ARCH}-\${VER}.tar.gz"
echo "  runner version: \$VER"
if [ ! -f "\$TARBALL" ]; then
  curl -fSL --retry 3 -o "\$TARBALL" "https://github.com/actions/runner/releases/download/v\${VER}/\${TARBALL}"
fi
# integrity: GitHub exposes the digest on the RELEASE ASSET (the release notes
# body does NOT carry hashes) — use that, and fail closed when it is present.
DIGEST="\$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
  | jq -r --arg t "\$TARBALL" '.assets[]|select(.name==\$t)|.digest' | head -1)"
GOT="\$(sha256sum "\$TARBALL" | awk '{print \$1}')"
if [ -n "\$DIGEST" ] && [ "\$DIGEST" != "null" ]; then
  EXP="\${DIGEST#sha256:}"
  [ "\$EXP" = "\$GOT" ] || { echo "  SHA256 MISMATCH expected=\$EXP got=\$GOT"; exit 1; }
  echo "  sha256 verified against the release asset digest"
else
  echo "  WARNING: no asset digest published; got \$GOT"
fi
tar xzf "\$TARBALL"
./config.sh --unattended --replace \
  --url "https://github.com/${ORG}" --token "${TOKEN}" \
  --name "${RUNNER_NAME}" --labels "${RUNNER_LABELS}" --work "_work" >/dev/null
# Prefer the shipped svc.sh; recent tarballs omit it, so fall back to a unit.
if [ -x ./svc.sh ]; then
  sudo ./svc.sh install "\$USER" >/dev/null
  sudo ./svc.sh start          >/dev/null
else
  echo "  svc.sh absent — installing a systemd unit directly"
  sudo tee "/etc/systemd/system/${SVC}" >/dev/null <<UNIT
[Unit]
Description=GitHub Actions Runner (${RUNNER_NAME})
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=\$HOME/actions-runner/run.sh
WorkingDirectory=\$HOME/actions-runner
User=\$USER
KillMode=process
KillSignal=SIGTERM
TimeoutStopSec=5min
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now "${SVC}" >/dev/null 2>&1 || true
fi
sleep 4
echo "  service state: \$(systemctl is-active "${SVC}" 2>/dev/null || echo unknown)"
REMOTE
ok "runner configured on the host"

# ------------------------------------------------- 5. verify from GitHub's side
bold "verifying from GitHub (not the script's own claim)"
LINE=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  LINE="$(gh api "/orgs/$ORG/actions/runners" \
    --jq ".runners[]|select(.name==\"$RUNNER_NAME\")|\"\\(.status)/\\(.busy)\"" 2>/dev/null || true)"
  [[ -n "$LINE" ]] && break
  sleep 3
done
[[ -n "$LINE" ]] || die "runner never appeared in the org list — check: ssh $RUNNER_HOST 'journalctl -u $SVC -n 50'"
echo "  org runner list: $RUNNER_NAME -> $LINE"
[[ "$LINE" == online/* ]] || die "registered but NOT online ($LINE)"
ok "runner is ONLINE"

bold "done"
cat <<EOM
  org    : $ORG
  runner : $RUNNER_NAME   labels: $RUNNER_LABELS
  host   : $RUNNER_HOST
  next   : workflows still say 'runs-on: ubuntu-latest'. Retarget the build jobs:
             runs-on: [self-hosted, openwrt-builder]
EOM
