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

## Command Reference

Run any command with:

```bash
./setup-yubikey <command>
```

Available commands:

```text
init
init-ez
reset-yubikey
generate-master
setup-key-ez
keys-to-card
keys-to-user
enable-hmac
setup-gpg-agent
setup-gpg-helpers
setup-vars
oneshot
help
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

After running `./setup-yubikey setup-gpg-helpers`, helper shell functions become available in your shell profile, including:

- `setup-git-ez`
- `setup-git-commit-signing`
- `test-git-config`
- `test-gpg-signing`
- `setup-ssh-forwarding`
- `copy-remote-gpg-stubs`
- `export-gpg-pubkey`
- `key-to-gh`
- `create-luks-container` (Linux only)

## License

This project is licensed under the MIT License. See `LICENSE`.
