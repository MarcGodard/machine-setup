# machine-setup

> **Public repo.** Safe to clone on a fresh machine before any SSH keys are set up.

Public entry point for a fresh Fedora Atomic machine. Sets up the YubiKey
and GitHub SSH access so you can clone the private dotfiles repo and run bootstrap.

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

---

## YubiKey PINs

| PIN | Value | Used for |
|-----|-------|---------|
| PIN | `123456` | GPG operations (sign, auth, decrypt) |
| Admin PIN | `12345678` | Admin operations (`keytocard`, reset, change PIN) |

The card locks after 3 wrong PIN attempts. Reset with `ykman openpgp access reset-pin` (requires Admin PIN) or `gpg --card-edit` then `passwd`.

---

## Troubleshooting

### "YubiKey not detected" on Pass 2

1. Confirm the key is fully inserted
2. Check pcscd: `sudo systemctl status pcscd`
3. Restart scdaemon: `gpgconf --kill scdaemon && gpg --card-status`

On Fedora Atomic, `gnupg2-scdaemon` is a separate package. If `gpg --card-status` fails with "No SmartCard daemon", re-run `setup.sh` — it will detect and install the missing package.

### SSH to GitHub fails immediately (no touch prompt)

The env vars set inside `setup.sh` do not persist to your shell after the script exits. Run these manually before cloning:

```bash
export GPG_TTY=$(tty)
export SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket)
gpg-connect-agent updatestartuptty /bye
```

Then test: `ssh -T git@github.com`

### "Could not confirm GitHub authentication" but Ready

The ControlMaster check uses a specific socket path. Run `ssh -T git@github.com` manually — if it succeeds (touch, then "Hi username!"), the connection is working. The warning is cosmetic.

### `pass show` fails / GPG decryption error after bootstrap

The encryption subkey `[E]` must be on the YubiKey. Check with `gpg --card-status` — the Encryption slot must not show `[none]`. If it does, move the key to the card from a machine that has the private key (see dotfiles README troubleshooting).
