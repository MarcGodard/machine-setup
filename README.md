# machine-setup

One-time pre-bootstrap script for a fresh Fedora Atomic machine. Sets up GPG, links the YubiKey, and opens a persistent SSH connection to GitHub so the dotfiles bootstrap can clone private repos without timing issues.

## What it does

1. Starts `pcscd` (smartcard daemon)
2. Launches `gpg-agent` with SSH support
3. Imports the GPG public key
4. Links the YubiKey card (prompts you to insert and touch)
5. Adds GitHub host keys to `~/.ssh/known_hosts`
6. Opens an SSH ControlMaster connection to GitHub (one touch covers all subsequent clones)

## Requirements

- Fedora Atomic (Silverblue, Kinoite, etc.) after first reboot post-install
- YubiKey inserted
- `pcsc-lite-ccid` installed (staged by the dotfiles bootstrap Pass 1 — if you haven't run that yet, run it first, reboot, then come back here)

## Usage

```bash
git clone https://github.com/MarcGodard/machine-setup.git ~/machine-setup
bash ~/machine-setup/setup.sh
```

Or in one line:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MarcGodard/machine-setup/main/setup.sh)
```

After it completes, clone your dotfiles and run bootstrap:

```bash
git clone git@github.com:MarcGodard/dotfiles.git ~/.dotfiles
bash ~/.dotfiles/bootstrap.sh
```

## Files

| File | Purpose |
|------|---------|
| `setup.sh` | Pre-bootstrap setup script |
| `pubkey.asc` | GPG public key (imported automatically by the script) |
| `known_hosts` | GitHub SSH host keys (added to `~/.ssh/known_hosts`) |

## Full setup sequence on a fresh machine

```
Install Fedora Atomic
        ↓
bash ~/.dotfiles/bootstrap.sh   ← Pass 1 (stages packages, symlinks dotfiles)
        ↓
systemctl reboot
        ↓
bash ~/machine-setup/setup.sh   ← links YubiKey, opens GitHub SSH
        ↓
bash ~/.dotfiles/bootstrap.sh   ← Pass 2 (clones pass store, work repos, configures everything)
```
