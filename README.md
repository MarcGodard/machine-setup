# machine-setup

> **Public repo.** Safe to clone on a fresh machine before any SSH keys are set up.

Public entry point for a fresh Fedora Atomic machine. Sets up the YubiKey
and GitHub SSH access so you can clone the private dotfiles repo and run bootstrap.

Works for both laptop/desktop and server. The difference:
- **Laptop/desktop** — YubiKey stays connected, used daily for SSH, git signing, pass decryption
- **Server** — YubiKey used during initial setup only, then unplugged. All services run without it.

## Usage

### Laptop / Desktop

#### Step 1 — Clone and run (no YubiKey needed yet)

```bash
git clone https://github.com/MarcGodard/machine-setup.git ~/machine-setup
bash ~/machine-setup/setup.sh
```

If any of `pcsc-lite-ccid` (the YubiKey CCID driver), `pcsc-tools`,
`gnupg2-scdaemon`, or `pass` is not installed, the script stages the missing
packages via `rpm-ostree` and exits with a reboot prompt. `pass` is staged
this early because `dotfiles/server/generate-env.sh` depends on it to read
secrets before the rest of the stack exists.

#### Step 2 — Reboot

```bash
systemctl reboot
```

#### Step 3 — Re-run with YubiKey inserted

```bash
bash ~/machine-setup/setup.sh
```

This time it links the YubiKey to gpg-agent, opens a persistent SSH
ControlMaster connection to GitHub (touch the key once when prompted),
and prints the commands to clone your dotfiles.

#### Step 4 — Clone dotfiles and run bootstrap

```bash
git clone git@github.com:MarcGodard/dotfiles.git ~/.dotfiles
bash ~/.dotfiles/bootstrap.sh
```

Bootstrap detects the open ControlMaster connection and skips any further
YubiKey prompts for SSH.

---

### Server

The server setup is identical up front — same `setup.sh`, same YubiKey touch.
After bootstrap completes, the YubiKey can be unplugged. Docker, ZFS, and all
containers run indefinitely without it. The YubiKey is only needed again if you
reinstall or need to decrypt something from the pass store manually.

#### Step 1 — Clone and run (no YubiKey needed yet)

```bash
git clone https://github.com/MarcGodard/machine-setup.git ~/machine-setup
bash ~/machine-setup/setup.sh
```

#### Step 2 — Reboot

```bash
systemctl reboot
```

#### Step 3 — Re-run with YubiKey inserted

```bash
bash ~/machine-setup/setup.sh
```

#### Step 4 — Clone dotfiles and run bootstrap

```bash
git clone git@github.com:MarcGodard/dotfiles.git ~/.dotfiles
bash ~/.dotfiles/bootstrap.sh --server
```

Bootstrap must run first: it layers the `zfs` CLI (OpenZFS repo) that
`setup-zfs.sh` needs and clones the pass store that `generate-env.sh` reads.
The first run stages packages and reboots; re-run it after the reboot as it
instructs.

#### Step 5 — ZFS datasets and server env, then re-run bootstrap

```bash
bash ~/.dotfiles/server/setup-zfs.sh          # import pools, create appsPool/docker
bash ~/.dotfiles/server/generate-env.sh       # pull secrets from pass, generate server/.env
bash ~/.dotfiles/bootstrap.sh --server        # re-run: Docker data root on ZFS, start containers
```

#### Step 6 — Unplug YubiKey

The server is now self-contained. All services run without the YubiKey.

---

## Full sequence at a glance

**Laptop / Desktop:**
```
Fresh Fedora Atomic install
          ↓
git clone https://github.com/MarcGodard/machine-setup.git ~/machine-setup
bash ~/machine-setup/setup.sh        ← stages YubiKey + pass packages, exits
          ↓
systemctl reboot
          ↓
bash ~/machine-setup/setup.sh        ← links YubiKey, touch once
          ↓
git clone git@github.com:MarcGodard/dotfiles.git ~/.dotfiles
bash ~/.dotfiles/bootstrap.sh        ← full system setup, no more touches
```

**Server:**
```
Fresh Fedora Atomic install
          ↓
git clone https://github.com/MarcGodard/machine-setup.git ~/machine-setup
bash ~/machine-setup/setup.sh        ← stages YubiKey + pass packages, exits
          ↓
systemctl reboot
          ↓
bash ~/machine-setup/setup.sh        ← links YubiKey, touch once
          ↓
git clone git@github.com:MarcGodard/dotfiles.git ~/.dotfiles
bash ~/.dotfiles/bootstrap.sh --server           ← layers zfs CLI + clones pass store, reboots; re-run after reboot
          ↓
bash ~/.dotfiles/server/setup-zfs.sh             ← import pools, create Docker dataset on appsPool
bash ~/.dotfiles/server/generate-env.sh          ← pull secrets from pass into server/.env
bash ~/.dotfiles/bootstrap.sh --server           ← re-run: Docker data root on ZFS, start containers
          ↓
Unplug YubiKey — server runs without it
```

---

## First-time YubiKey setup

Do this **once** on your existing dev/setup machine before ever running `setup.sh` on a fresh machine. Skip if the YubiKey is already configured.

The YubiKey acts as your SSH key and GPG encryption key. Two GPG subkeys must be generated and moved onto the card:

| Subkey | Usage | YubiKey slot |
|--------|-------|-------------|
| `[E]` Encrypt | `pass` store decryption | Slot 2 |
| `[A]` Authenticate | SSH to GitHub and servers | Slot 3 |

Both must be on the card. If either slot shows `[none]` in `gpg --card-status`, that operation will fail silently.

The current key has no Sign subkey, so the Signature slot (Slot 1) stays
`[none]` and git commit signing is not done through this card. If you ever
add a Sign subkey, move it to Slot 1 the same way.

### Prerequisites

```bash
sudo dnf install gnupg2 yubikey-manager pcsc-lite pcsc-tools
sudo systemctl start pcscd
```

### Step 1 — PINs (optional)

A fresh YubiKey ships with well-known factory default PINs (see Yubico's docs).
Current setup keeps the factory defaults — physical possession of the key is
the security boundary. To change them anyway:

```bash
gpg --card-edit
> passwd
```

Choose option 1 (change PIN) and option 3 (change Admin PIN). If changed, store the new PINs in the pass vault, never in this repo. The card locks after 3 wrong PIN attempts.

### Step 2 — Generate the master key (certify only)

```bash
gpg --expert --full-generate-key
```

- Type: **RSA (set your own capabilities)**
- Toggle capabilities until only **Certify** is selected, then confirm
- Key size: **4096**
- Expiry: **0** (no expiry)
- Fill in name and email

Note the fingerprint printed at the end — you'll need it throughout. Confirm with:

```bash
gpg --list-keys --with-keygrip
```

### Step 3 — Add two subkeys

```bash
gpg --expert --edit-key <fingerprint>
```

Run `addkey` twice, creating one subkey for each role:

**Encrypt subkey:**
```
addkey → RSA (set your own capabilities) → Encrypt only → 4096 → 0
```

**Authenticate subkey:**
```
addkey → RSA (set your own capabilities) → Authenticate only → 4096 → 0
```

Then `save`.

### Step 4 — Move subkeys to the YubiKey

Plug in the YubiKey. Add `allow-loopback-pinentry` to `~/.gnupg/gpg-agent.conf`, then restart the agent:

```bash
echo "allow-loopback-pinentry" >> ~/.gnupg/gpg-agent.conf
gpgconf --kill gpg-agent
```

Then move each subkey. The `keytocard` command asks for your **GPG passphrase** (the one you set in Step 2) first, then the **YubiKey Admin PIN**:

```bash
gpg --pinentry-mode loopback --edit-key <fingerprint>
```

```
key 1          ← select Encrypt subkey (asterisk appears)
keytocard → 2  ← Encryption slot
key 1          ← deselect
key 2
keytocard → 3  ← Authentication slot
save           ← THIS deletes the local private key copies
```

If `keytocard` returns **"Invalid time"**, use a faked timestamp:

```bash
gpg --faked-system-time '20260405T120000!' --edit-key <fingerprint>
```

If `keytocard` returns **"No passphrase given"**, ensure `allow-loopback-pinentry` is in `gpg-agent.conf` and the agent was restarted.

### Step 5 — Verify both slots are filled

```bash
gpg --card-status
```

The Encryption and Authentication slots must show a key fingerprint, **neither should show `[none]`**. The Signature slot showing `[none]` is expected with this key layout. This is the most common mistake: forgetting to move the Encrypt subkey means `pass` decryption will fail on every new machine.

### Step 6 — Export the public key and update both repos

The public key lives in TWO places and both must be regenerated together:

```bash
gpg --armor --export <fingerprint> > ~/Documents/Github/machine-setup/pubkey.asc
gpg --armor --export <fingerprint> > ~/Documents/Github/dotfiles/pubkey.asc
cd ~/Documents/Github/machine-setup && git add pubkey.asc && git commit -m "Update pubkey" && git push
cd ~/Documents/Github/dotfiles && git add pubkey.asc && git commit -m "Update pubkey" && git push
```

If this is a new key, also update `signingkey` in `~/.gitconfig.local` on each
machine. `dotfiles/bootstrap.sh` derives the fingerprint from `pubkey.asc` at
runtime, so no script edits are needed.

> **Duplicate files, keep in sync:** this repo must be standalone before
> dotfiles is cloned, so two files are intentionally duplicated. When one
> changes, update its twin:
>
> - `machine-setup/pubkey.asc` ↔ `dotfiles/pubkey.asc`
> - `machine-setup/known_hosts` ↔ `dotfiles/home/ssh_known_hosts`

### Step 7 — Test SSH

```bash
export SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket)
ssh-add -L    # should show the auth subkey public key
ssh -T git@github.com    # touch YubiKey when it flashes
```

Expected: `Hi MarcGodard! You've successfully authenticated...`

---

## Files

| File | Purpose |
|------|---------|
| `setup.sh` | Pre-bootstrap setup script |
| `pubkey.asc` | GPG public key (imported automatically) |
| `known_hosts` | GitHub SSH host keys (added to `~/.ssh/known_hosts`) |

---

## YubiKey PINs

A fresh YubiKey ships with well-known factory default PINs (see Yubico's
docs). Current setup keeps the factory defaults, so anyone holding the
physical key can use it — possession is the boundary. To change them:
`gpg --card-edit`, then `admin`, then `passwd` (option 1 changes the PIN,
option 3 the Admin PIN). If changed, store the new PINs in the pass vault,
never in this repo (it is public).

| PIN | Used for |
|-----|---------|
| PIN | GPG operations (sign, auth, decrypt) |
| Admin PIN | Admin operations (`keytocard`, reset, change PIN) |

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
