# YubiKey Setup Guide

> **Do not run `setup-yubikey` with `sudo`.**
> The script prompts for elevated access only when needed.

## Quickstart

From the repository root:

```bash
./setup-yubikey oneshot
```

`oneshot` runs the full guided flow:
- `setup-vars`
- `init-ez`
- `setup-key-ez`
- `setup-gpg-agent`
- `setup-gpg-helpers`

## Platform Support

- **macOS** and **Ubuntu Linux** are supported.
- OS is detected automatically via `uname -s`.
- LUKS container features (`create-luks-container`, `unlock_vault`, `lock_vault`) are Linux-only.

## Command Reference

Run any command with:

```bash
./setup-yubikey <command>
```

Available commands:

```text
init              Install required dependencies
init-ez           init + generate-master quick flow
reset-yubikey     Reset YubiKey applications to factory defaults
generate-master   Generate OpenPGP master key material (Ed25519)
setup-key-ez      reset-yubikey + keys-to-card + enable-hmac combo
keys-to-card      Move generated subkeys to YubiKey slots
keys-to-user      Copy gnupg_home_stubs/ to ~/.gnupg and run setup-gpg-agent
enable-hmac       Configure HMAC challenge-response on YubiKey slot 2
setup-gpg-agent   Configure and start gpg-agent with SSH support
setup-gpg-helpers Install gpg-helpers.sh functions into your shell profile
setup-vars        Interactively write setup_variables (identity and secrets)
oneshot           Full guided flow (see Quickstart)
help              Show command help text
```

## Setup Notes

- `setup-vars` writes `setup_variables` interactively, with hidden/confirmed entry for secrets.
- Keep `setup_variables` private and never commit populated values.
- Keep your backup media physically separate from your YubiKey.

## After Setup

Verify local keys:

```bash
gpg --list-keys
ssh-add -L
```

### Shell Helper Functions

After running `./setup-yubikey setup-gpg-helpers`, the following functions become available in your shell. Legacy short aliases are listed in parentheses where they exist.

#### Git & GPG Setup

| Function | Description |
|---|---|
| `gpg-setup-git-ez` (`setup-git-ez`) | Express git setup: commit signing + config test + signing test |
| `gpg-setup-git-commit-signing` (`setup-git-commit-signing`) | Configure `git config --global` for GPG commit signing |
| `gpg-test-git-config` (`test-git-config`) | Display current git signing config |
| `gpg-test-gpg-signing` (`test-gpg-signing`) | Test GPG signing and verification |

#### Key Management & Sharing

| Function | Description |
|---|---|
| `gpg-export-gpg-pubkey` (`export-gpg-pubkey`) | Export GPG public key to a file |
| `gpg-key-to-gh` (`key-to-gh`) | Upload GPG and SSH public keys to GitHub |
| `gpg-share-key` | Export a GPG public key as a shareable `GPGSHARE1:` string |
| `gpg-import-shared-pubkey` | Import a GPG public key from a `GPGSHARE1:` share string |

#### SSH & Remote

| Function | Description |
|---|---|
| `gpg-setup-ssh-forwarding` (`setup-ssh-forwarding`) | Add commented-out SSH agent forwarding config to `~/.ssh/config` |
| `gpg-copy-remote-gpg-stubs` (`copy-remote-gpg-stubs`) | Copy GPG public key + stubs to a remote host |

#### git-crypt Workflow

| Function | Description |
|---|---|
| `gpg-init` | Initialize `git-crypt` in the current repo |
| `gpg-add-gpg-user-interactive` | Interactively select a GPG key and add it as a `git-crypt` recipient |
| `gpg-gitcrypt-remove-gpg-user` | Remove a `git-crypt` recipient and rotate the symmetric key |
| `gpg-gitcrypt-rekey` | Rotate the `git-crypt` symmetric key for all current recipients |
| `gpg-set-gh-secret` | Push the `git-crypt` key to a GitHub repo secret (`GITCRYPT_KEY`) |
| `gpg-init-gh-actions` | Create a reusable GitHub Action for `git-crypt unlock` |

#### GitHub Actions Runners

| Function | Description |
|---|---|
| `register_gh_repo_runner <hostname>` | Register a self-hosted GitHub Actions runner on a remote Linux host for the current repo |

`register_gh_repo_runner` uses `gh` to generate a registration token, SSHs into the target host, installs the latest GitHub Actions runner, and starts it as a systemd service. Requires `gh`, `git`, and `ssh` locally, and root/sudo on the remote host.

#### Diagnostics

| Function | Description |
|---|---|
| `gpg-doctor` (`gpg-diagnostics`) | Run diagnostics: commands, git-crypt status, GPG keys, agent sockets, GitHub CLI |
| `gpg-test-sandbox` | End-to-end sandbox test of git-crypt init/add/remove/rekey and key sharing |

#### LUKS (Linux only)

| Function | Description |
|---|---|
| `gpg-create-luks-container` (`create-luks-container`) | Create a LUKS-encrypted container using YubiKey HMAC |

The `openvault.bash` script provides `unlock_vault` and `lock_vault` for LUKS containers (Linux only). Source it to use:

```bash
source ./openvault.bash
unlock_vault
lock_vault
```

## License

This project is licensed under the MIT License. See `LICENSE`.
