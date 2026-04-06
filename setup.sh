#!/usr/bin/env bash
# setup.sh — Pre-bootstrap YubiKey + GitHub SSH setup
#
# Run this once on a fresh Fedora Atomic machine before cloning your dotfiles.
# It sets up gpg-agent, links the YubiKey, and opens a persistent SSH connection
# to GitHub so the dotfiles bootstrap can clone private repos without issues.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/MarcGodard/machine-setup/main/setup.sh | bash
#   # or after cloning:
#   bash setup.sh

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-/dev/stdin}")" 2>/dev/null && pwd || echo "$HOME")"
PUBKEY="$SCRIPT_DIR/pubkey.asc"

# ---------------------------------------------------------------------------
# 1. Derive fingerprint from the public key file
# ---------------------------------------------------------------------------
if [[ ! -f "$PUBKEY" ]]; then
  # Fallback: fetch from the repo if run via curl
  info "Fetching public key..."
  curl -fsSL https://raw.githubusercontent.com/MarcGodard/machine-setup/main/pubkey.asc \
    -o /tmp/pubkey.asc
  PUBKEY=/tmp/pubkey.asc
fi

KEY_FPR=$(gpg --with-colons --import-options show-only --import "$PUBKEY" 2>/dev/null \
  | awk -F: '/^fpr/{print $10; exit}')
[[ -n "$KEY_FPR" ]] || die "Could not read fingerprint from $PUBKEY"

# ---------------------------------------------------------------------------
# 2. Start pcscd (smartcard daemon)
# ---------------------------------------------------------------------------
info "Starting pcscd..."
if ! rpm -q pcsc-lite-ccid &>/dev/null; then
  die "pcsc-lite-ccid is not installed. Run bootstrap Pass 1 first, then reboot, then re-run this script."
fi
sudo systemctl start pcscd 2>/dev/null || true
ok "pcscd running."

# ---------------------------------------------------------------------------
# 3. Kill any stale gpg-agent and relaunch with SSH support
# ---------------------------------------------------------------------------
info "Launching gpg-agent..."
gpgconf --kill scdaemon  2>/dev/null || true
gpgconf --kill gpg-agent 2>/dev/null || true

# Ensure enable-ssh-support is set before launching
mkdir -p "$HOME/.gnupg" && chmod 700 "$HOME/.gnupg"
if ! grep -q "enable-ssh-support" "$HOME/.gnupg/gpg-agent.conf" 2>/dev/null; then
  echo "enable-ssh-support" >> "$HOME/.gnupg/gpg-agent.conf"
fi
if ! grep -q "disable-ccid" "$HOME/.gnupg/scdaemon.conf" 2>/dev/null; then
  echo "disable-ccid" >> "$HOME/.gnupg/scdaemon.conf"
fi

gpgconf --launch gpg-agent 2>/dev/null || true

# Wait for socket
SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket)
export SSH_AUTH_SOCK
for i in $(seq 1 10); do
  [[ -S "$SSH_AUTH_SOCK" ]] && break
  sleep 0.3
done
[[ -S "$SSH_AUTH_SOCK" ]] || die "gpg-agent socket never appeared at $SSH_AUTH_SOCK"
ok "gpg-agent ready. SSH_AUTH_SOCK=$SSH_AUTH_SOCK"

# ---------------------------------------------------------------------------
# 4. Import public key
# ---------------------------------------------------------------------------
if gpg --list-keys "$KEY_FPR" &>/dev/null; then
  ok "GPG public key already imported."
else
  info "Importing GPG public key..."
  gpg --import "$PUBKEY"
  ok "GPG public key imported ($KEY_FPR)."
fi

# ---------------------------------------------------------------------------
# 5. Link YubiKey card
# ---------------------------------------------------------------------------
if ssh-add -L &>/dev/null 2>&1; then
  ok "YubiKey already linked — SSH key visible in agent."
else
  echo
  info "Insert your YubiKey if not already plugged in."
  read -rp "  Press Enter when ready... " _

  if ! gpg --card-status &>/dev/null 2>&1; then
    die "YubiKey not detected. Check it is inserted and pcscd is running."
  fi

  gpg-connect-agent "scd serialno" "learn --force" /bye 2>/dev/null || true

  # Explicitly add auth subkey keygrip to sshcontrol
  KEYGRIP=$(gpg --with-keygrip --list-keys "$KEY_FPR" 2>/dev/null \
    | awk '/\[A\]/{found=1} found && /Keygrip/{print $3; exit}')

  if [[ -n "$KEYGRIP" ]]; then
    SSHCONTROL="$HOME/.gnupg/sshcontrol"
    touch "$SSHCONTROL"
    if ! grep -q "^$KEYGRIP" "$SSHCONTROL"; then
      echo "$KEYGRIP" >> "$SSHCONTROL"
    fi
    gpg-connect-agent reloadagent /bye &>/dev/null || true
  fi

  if ssh-add -L &>/dev/null 2>&1; then
    ok "YubiKey linked — SSH key visible in agent."
  else
    die "YubiKey linked but SSH key still not visible. Try: sudo systemctl restart pcscd && gpg --card-status"
  fi
fi

# ---------------------------------------------------------------------------
# 6. Pre-populate ~/.ssh/known_hosts with GitHub keys
# ---------------------------------------------------------------------------
KNOWN_HOSTS_SRC="$SCRIPT_DIR/known_hosts"
if [[ ! -f "$KNOWN_HOSTS_SRC" ]]; then
  curl -fsSL https://raw.githubusercontent.com/MarcGodard/machine-setup/main/known_hosts \
    -o /tmp/known_hosts
  KNOWN_HOSTS_SRC=/tmp/known_hosts
fi

mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
KNOWN_HOSTS="$HOME/.ssh/known_hosts"
touch "$KNOWN_HOSTS"

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  host=$(echo "$line" | awk '{print $1}')
  key=$(echo "$line" | awk '{print $3}')
  if ! grep -qF "$key" "$KNOWN_HOSTS" 2>/dev/null; then
    echo "$line" >> "$KNOWN_HOSTS"
  fi
done < "$KNOWN_HOSTS_SRC"
ok "GitHub host keys added to ~/.ssh/known_hosts."

# ---------------------------------------------------------------------------
# 7. Establish SSH ControlMaster connection to GitHub
#    (one touch here — dotfiles bootstrap reuses this connection)
# ---------------------------------------------------------------------------
# Ensure ControlMaster config exists for this session
mkdir -p "$HOME/.ssh"
SSH_CONF="$HOME/.ssh/config"
touch "$SSH_CONF" && chmod 600 "$SSH_CONF"
if ! grep -q "ControlMaster" "$SSH_CONF" 2>/dev/null || \
   ! grep -A5 "Host github.com" "$SSH_CONF" 2>/dev/null | grep -q "ControlMaster"; then
  cat >> "$SSH_CONF" << 'SSHEOF'

# Added by machine-setup — ControlMaster keeps one authenticated connection
# alive so multiple git operations only need one YubiKey touch.
Host github.com
    ControlMaster auto
    ControlPath /tmp/ssh-cm-%r@%h:%p
    ControlPersist 60m
SSHEOF
  ok "ControlMaster config added to ~/.ssh/config."
fi

echo
info ">>> Touch your YubiKey now to authenticate with GitHub <<<"
info "    (one touch here covers all git clones during bootstrap)"
echo

if ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
  ok "GitHub SSH authenticated. ControlMaster connection is live."
else
  warn "GitHub returned an unexpected response — but the connection may still work."
  warn "Run 'ssh -T git@github.com' to verify manually."
fi

# ---------------------------------------------------------------------------
# Done — print next steps
# ---------------------------------------------------------------------------
echo
echo "========================================"
echo "  Setup complete"
echo "========================================"
echo
info "Next steps:"
echo
echo "  1. Clone your dotfiles:"
echo "       git clone git@github.com:MarcGodard/dotfiles.git ~/.dotfiles"
echo
echo "  2. Run bootstrap:"
echo "       bash ~/.dotfiles/bootstrap.sh"
echo
info "The GitHub SSH connection stays open for 60 min — no more YubiKey touches needed."
echo
