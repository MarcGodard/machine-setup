#!/usr/bin/env bash
# setup.sh — Pre-bootstrap YubiKey + GitHub SSH setup
#
# Public entry point for a fresh Fedora Atomic machine.
# Run this BEFORE cloning your private dotfiles repo.
#
# Pass 1 (no YubiKey needed):
#   Installs pcsc-lite-ccid (YubiKey CCID driver) via rpm-ostree and exits.
#   Reboot, then re-run.
#
# Pass 2 (YubiKey required):
#   Links the YubiKey to gpg-agent, opens a persistent SSH ControlMaster
#   connection to GitHub, then prints the commands to clone + run dotfiles.
#
# Usage:
#   git clone https://github.com/MarcGodard/machine-setup.git ~/machine-setup
#   bash ~/machine-setup/setup.sh

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBKEY="$SCRIPT_DIR/pubkey.asc"

echo
echo "=============================="
echo "  Machine Setup"
echo "=============================="
echo

# ---------------------------------------------------------------------------
# Pass 1: Install pcsc-lite-ccid (YubiKey CCID driver) if not present.
# This requires a reboot on Fedora Atomic — re-run setup.sh after reboot.
# ---------------------------------------------------------------------------
if ! rpm -q pcsc-lite-ccid &>/dev/null; then
  info "Installing YubiKey CCID driver (pcsc-lite-ccid)..."
  rpm-ostree install pcsc-lite-ccid

  echo
  echo "========================================"
  echo "  REBOOT REQUIRED"
  echo "========================================"
  echo
  info "pcsc-lite-ccid has been staged. After rebooting, re-run:"
  echo
  echo "    bash ~/machine-setup/setup.sh"
  echo
  info "Then plug in your YubiKey and you will be ready to clone dotfiles."
  echo
  exit 0
fi

ok "pcsc-lite-ccid installed."

# ---------------------------------------------------------------------------
# Pass 2: YubiKey + GitHub SSH setup
# ---------------------------------------------------------------------------

# 1. Start pcscd
info "Starting pcscd..."
sudo systemctl start pcscd 2>/dev/null || true
ok "pcscd running."

# 2. Kill stale gpg-agent and relaunch with SSH support
info "Launching gpg-agent..."
gpgconf --kill scdaemon  2>/dev/null || true
gpgconf --kill gpg-agent 2>/dev/null || true

mkdir -p "$HOME/.gnupg" && chmod 700 "$HOME/.gnupg"
grep -q "enable-ssh-support" "$HOME/.gnupg/gpg-agent.conf" 2>/dev/null \
  || echo "enable-ssh-support" >> "$HOME/.gnupg/gpg-agent.conf"
grep -q "disable-ccid" "$HOME/.gnupg/scdaemon.conf" 2>/dev/null \
  || echo "disable-ccid" >> "$HOME/.gnupg/scdaemon.conf"

gpgconf --launch gpg-agent 2>/dev/null || true

SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket)
export SSH_AUTH_SOCK
for i in $(seq 1 10); do
  [[ -S "$SSH_AUTH_SOCK" ]] && break
  sleep 0.3
done
[[ -S "$SSH_AUTH_SOCK" ]] || die "gpg-agent socket never appeared at $SSH_AUTH_SOCK"
ok "gpg-agent ready."

# 3. Import GPG public key
KEY_FPR=$(gpg --with-colons --import-options show-only --import "$PUBKEY" 2>/dev/null \
  | awk -F: '/^fpr/{print $10; exit}')
[[ -n "$KEY_FPR" ]] || die "Could not read fingerprint from $PUBKEY"

if gpg --list-keys "$KEY_FPR" &>/dev/null; then
  ok "GPG public key already imported."
else
  info "Importing GPG public key..."
  gpg --import "$PUBKEY"
  ok "GPG public key imported."
fi

# 4. Link YubiKey
if ssh-add -L &>/dev/null 2>&1; then
  ok "YubiKey already linked — SSH key visible in agent."
else
  echo
  info "Insert your YubiKey now."
  read -rp "  Press Enter when ready... " _

  # Restart scdaemon so it picks up disable-ccid and connects fresh to pcscd
  gpgconf --kill scdaemon 2>/dev/null || true
  sleep 1

  # Retry card-status a few times — scdaemon takes a moment to start
  card_ok=false
  for i in $(seq 1 5); do
    if gpg --card-status &>/dev/null 2>&1; then
      card_ok=true
      break
    fi
    sleep 1
  done

  if ! $card_ok; then
    echo
    warn "YubiKey not detected after 5 attempts."
    info "Diagnostics:"
    sudo systemctl status pcscd --no-pager -l 2>/dev/null | tail -5 || true
    gpg --card-status 2>&1 | tail -5 || true
    die "Check the YubiKey is fully inserted and pcscd is running, then re-run setup.sh"
  fi

  gpg-connect-agent "scd serialno" "learn --force" /bye 2>/dev/null || true

  KEYGRIP=$(gpg --with-keygrip --list-keys "$KEY_FPR" 2>/dev/null \
    | awk '/\[A\]/{found=1} found && /Keygrip/{print $3; exit}')

  if [[ -n "$KEYGRIP" ]]; then
    touch "$HOME/.gnupg/sshcontrol"
    grep -q "^$KEYGRIP" "$HOME/.gnupg/sshcontrol" 2>/dev/null \
      || echo "$KEYGRIP" >> "$HOME/.gnupg/sshcontrol"
    gpg-connect-agent reloadagent /bye &>/dev/null || true
  fi

  ssh-add -L &>/dev/null 2>&1 \
    || die "YubiKey linked but SSH key not visible. Try: sudo systemctl restart pcscd && gpg --card-status"

  ok "YubiKey linked — SSH key visible in agent."
fi

# 5. Pre-populate ~/.ssh/known_hosts with GitHub keys
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/known_hosts"
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  key=$(echo "$line" | awk '{print $3}')
  grep -qF "$key" "$HOME/.ssh/known_hosts" 2>/dev/null \
    || echo "$line" >> "$HOME/.ssh/known_hosts"
done < "$SCRIPT_DIR/known_hosts"
ok "GitHub host keys in ~/.ssh/known_hosts."

# 6. Add ControlMaster to ~/.ssh/config so one touch covers all clones
mkdir -p "$HOME/.ssh" && touch "$HOME/.ssh/config" && chmod 600 "$HOME/.ssh/config"
if ! grep -A5 "Host github.com" "$HOME/.ssh/config" 2>/dev/null | grep -q "ControlMaster"; then
  cat >> "$HOME/.ssh/config" << 'SSHEOF'

Host github.com
    ControlMaster auto
    ControlPath /tmp/ssh-cm-%r@%h:%p
    ControlPersist 60m
SSHEOF
  ok "SSH ControlMaster configured for github.com."
fi

# 7. Open GitHub SSH connection — one touch here covers all git clones
echo
info ">>> Touch your YubiKey when it flashes to authenticate with GitHub <<<"
echo

if ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
  ok "GitHub SSH authenticated. ControlMaster connection is live for 60 min."
else
  warn "Could not confirm GitHub authentication. Run 'ssh -T git@github.com' to check."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo
echo "=============================="
echo "  Ready"
echo "=============================="
echo
info "Clone your dotfiles and run bootstrap:"
echo
echo "    git clone git@github.com:MarcGodard/dotfiles.git ~/.dotfiles"
echo "    bash ~/.dotfiles/bootstrap.sh"
echo
