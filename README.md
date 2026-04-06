# machine-setup

Public entry point for a fresh Fedora Atomic machine. Sets up the YubiKey
and GitHub SSH access so you can clone a private dotfiles repo and run bootstrap.

## Usage

### Step 1 — Clone and run (no YubiKey needed yet)

```bash
git clone https://github.com/MarcGodard/machine-setup.git ~/machine-setup
bash ~/machine-setup/setup.sh
```

If `pcsc-lite-ccid` (the YubiKey CCID driver) is not installed, the script
stages it via `rpm-ostree` and exits with a reboot prompt.

### Step 2 — Reboot

```bash
systemctl reboot
```

### Step 3 — Re-run with YubiKey inserted

```bash
bash ~/machine-setup/setup.sh
```

This time it links the YubiKey to gpg-agent, opens a persistent SSH
ControlMaster connection to GitHub (touch the key once when prompted),
and prints the commands to clone your dotfiles.

### Step 4 — Clone dotfiles and run bootstrap

```bash
git clone git@github.com:MarcGodard/dotfiles.git ~/.dotfiles
bash ~/.dotfiles/bootstrap.sh
```

Bootstrap detects the open ControlMaster connection and skips any further
YubiKey prompts for SSH.

---

## Full sequence at a glance

```
Fresh Fedora Atomic install
          ↓
git clone https://github.com/MarcGodard/machine-setup.git ~/machine-setup
bash ~/machine-setup/setup.sh        ← stages pcsc-lite-ccid, exits
          ↓
systemctl reboot
          ↓
bash ~/machine-setup/setup.sh        ← links YubiKey, touch once
          ↓
git clone git@github.com:MarcGodard/dotfiles.git ~/.dotfiles
bash ~/.dotfiles/bootstrap.sh        ← full system setup, no more touches
```

## Files

| File | Purpose |
|------|---------|
| `setup.sh` | Pre-bootstrap setup script |
| `pubkey.asc` | GPG public key (imported automatically) |
| `known_hosts` | GitHub SSH host keys (added to `~/.ssh/known_hosts`) |
