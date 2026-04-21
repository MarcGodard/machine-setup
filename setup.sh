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
MISSING_PKGS=()
rpm -q pcsc-lite-ccid   &>/dev/null || MISSING_PKGS+=(pcsc-lite-ccid)
rpm -q gnupg2-scdaemon  &>/dev/null || MISSING_PKGS+=(gnupg2-scdaemon)
rpm -q pass             &>/dev/null || MISSING_PKGS+=(pass)

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
  info "Installing: ${MISSING_PKGS[*]}"
  rpm-ostree install "${MISSING_PKGS[@]}"

  echo
  echo "========================================"
  echo "  REBOOT REQUIRED"
  echo "========================================"
  echo
  info "Packages staged. After rebooting, re-run:"
  echo
  echo "    bash ~/machine-setup/setup.sh"
  echo
  info "Then plug in your YubiKey and you will be ready to clone dotfiles."
  echo
  exit 0
fi

ok "pcsc-lite-ccid and gnupg2-scdaemon installed."

# ---------------------------------------------------------------------------
# Pass 2: YubiKey + GitHub SSH setup
# ---------------------------------------------------------------------------

# GPG_TTY must be set so pinentry-curses can prompt for PIN after a reboot.
# Without this, gpg-agent fails immediately instead of asking for the PIN.
export GPG_TTY=$(tty)
export SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket 2>/dev/null || true)

# 1. Start pcscd
info "Starting pcscd..."
sudo systemctl start pcscd 2>/dev/null || true
ok "pcscd running."

# 2. Kill stale gpg-agent and relaunch with SSH support
info "Launching gpg-agent..."
gpgconf --kill scdaemon  2>/dev/null || true
gpgconf --kill gpg-agent 2>/dev/null || true

mkdir -p "$HOME/.gnupg" && chmod 700 "$HOME/.gnupg"

# Find scdaemon — ask rpm first, then fall back to known paths
SCDAEMON=$(rpm -ql gnupg2-scdaemon 2>/dev/null | grep -m1 '/scdaemon$' || true)
if [[ -z "$SCDAEMON" ]]; then
  for p in /usr/libexec/scdaemon /usr/lib/gnupg2/scdaemon /usr/lib/gnupg/scdaemon /usr/bin/scdaemon; do
    [[ -x "$p" ]] && SCDAEMON="$p" && break
  done
fi
[[ -n "$SCDAEMON" ]] || die "scdaemon not found — install gnupg2-scdaemon and try again"
ok "scdaemon found at $SCDAEMON"

grep -q "enable-ssh-support" "$HOME/.gnupg/gpg-agent.conf" 2>/dev/null \
  || echo "enable-ssh-support" >> "$HOME/.gnupg/gpg-agent.conf"
# Tell gpg-agent exactly where scdaemon is — avoids "No SmartCard daemon" errors
grep -q "scdaemon-program" "$HOME/.gnupg/gpg-agent.conf" 2>/dev/null \
  || echo "scdaemon-program $SCDAEMON" >> "$HOME/.gnupg/gpg-agent.conf"
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
# Always prompt and connect the physical card — even if the key stub is
# already in the agent, scdaemon hasn't talked to the card since the last
# reboot and SSH signing will fail immediately without this warm-up.
echo
info "Insert your YubiKey now."
read -rp "  Press Enter when ready... " _

# Restart scdaemon so it connects fresh to pcscd
gpgconf --kill scdaemon 2>/dev/null || true
sleep 1

# Wait for card to be detected
card_ok=false
for i in $(seq 1 5); do
  if gpg --card-status &>/dev/null 2>&1; then
    card_ok=true
    break
  fi
  sleep 1
done

if ! $card_ok; then
  warn "YubiKey not detected after 5 attempts."
  sudo systemctl status pcscd --no-pager -l 2>/dev/null | tail -5 || true
  gpg --card-status 2>&1 | tail -5 || true
  die "Check the YubiKey is fully inserted and pcscd is running, then re-run setup.sh"
fi
ok "YubiKey card connected."

# Learn the card and populate sshcontrol if not already done
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
  || die "SSH key not visible. Try: sudo systemctl restart pcscd && gpg --card-status"

ok "YubiKey linked — SSH key visible in agent."

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
mkdir -p "$HOME/.ssh/controlmasters" && chmod 700 "$HOME/.ssh/controlmasters"
if ! grep -A5 "Host github.com" "$HOME/.ssh/config" 2>/dev/null | grep -q "ControlMaster"; then
  cat >> "$HOME/.ssh/config" << SSHEOF

Host github.com
    ControlMaster auto
    ControlPath $HOME/.ssh/controlmasters/%r@%h:%p
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
warn "These env vars are only set inside this script. Run in your shell before cloning:"
echo
echo "    export GPG_TTY=\$(tty)"
echo "    export SSH_AUTH_SOCK=\$(gpgconf --list-dirs agent-ssh-socket)"
echo "    gpg-connect-agent updatestartuptty /bye"
echo
info "Then clone your dotfiles and run bootstrap:"
echo
echo "    git clone git@github.com:MarcGodard/dotfiles.git ~/.dotfiles"
echo "    bash ~/.dotfiles/bootstrap.sh"
echo
