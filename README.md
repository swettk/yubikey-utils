# YubiKey Setup Guide

## Important Note

> **DO NOT** run `setup_yubikey` with `sudo`.
> The script prompts for elevated access only when needed.

## Table of Contents

- [Setup and Initialization](#setup-and-initialization)
  - [Command Reference](#command-reference)
  - [Prepare for Setup](#prepare-for-setup)
  - [Important Note About the USB Flash Drive](#important-note-about-the-usb-flash-drive)
  - [Edit Your Variables](#edit-your-variables)
  - [Initialize the Script](#initialize-the-script)
- [Put Keys on Your YubiKey](#put-keys-on-your-yubikey)
- [Put Keys on Your Computer](#put-keys-on-your-computer)
- [Test That Your Keys Exist](#test-that-your-keys-exist)
- [Add Keys to GitHub/GitLab/Key-Pository](#add-keys-to-githubgitlabkey-pository)
- [Set Up Git Configuration](#set-up-git-configuration)
- [Test SSH Access](#test-ssh-access)
- [Optional: LUKS Container Support](#optional-luks-container-support)
- [FIDO and Other Modes](#fido-and-other-modes)
- [Other Guides](#other-guides)

## Setup and Initialization

### Command Reference

Run any command with:

```bash
./setup_yubikey <command>
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
create-luks-container
setup-git-ez
setup-git-commit-signing
setup-gpg-agent
setup-ssh-forwarding
test-gpg-signing
test-git-config
```

After running `./setup_yubikey setup-git-crypt-helpers`, helper shell functions are available including `copy-remote-gpg-stubs` and `export-gpg-pubkey`.

### Prepare for Setup

- Insert a dedicated USB drive with no important data.
- Format the USB drive.
  - Insert the USB drive.
  - Open the **Disks** application and select the USB drive in the left pane.
  - In the right pane under Volumes, click the gear icon and choose **Format Partition**.
  - Set a **Volume Name** such as `Yubikey Backup`.
  - Leave **Erase** off (erase takes longer).
  - Choose **Internal disk for use with Linux systems only (Ext4)** and click **Next**.
  - Confirm the target device is your USB drive and click **Format**.
- Move the downloaded zip archive to the formatted USB drive.
- Extract files to the USB drive.

### Important Note About the USB Flash Drive

> - Your external flash drive is your backup.
> - You may create multiple copies if needed.
> - Physically secure the drive (and any copies), ideally in a safe location.
> - Store it separately from your YubiKey.
> - Do not carry the backup drive with you.

### Edit Your Variables

- Edit all values in `setup_variables` in the extracted `yubikey-work` directory.
- Your `KEYPIN` is the PIN you will use regularly for authentication.
- Keep `setup_variables` private and never commit populated values.

### Initialize the Script

You must run commands from the same directory as `setup_yubikey`.

Run the quick initialization flow:

```bash
./setup_yubikey init-ez
```

Or run the steps manually:

```bash
./setup_yubikey init
./setup_yubikey generate-master
```

If initialization does not complete cleanly, rerun the command and confirm all prompts finished.

## Put Keys on Your YubiKey

Insert your YubiKey (if not already inserted), then run:

```bash
./setup_yubikey setup-key-ez
```

Or run the steps manually:

```bash
./setup_yubikey reset-yubikey
./setup_yubikey keys-to-card
./setup_yubikey enable-hmac
```

## Put Keys on Your Computer

Run:

```bash
./setup_yubikey keys-to-user
./setup_yubikey setup-gpg-agent
source ~/.bashrc
```

- `keys-to-user` copies key stubs to `~/.gnupg` and sets permissions.
- `setup-gpg-agent` configures and starts `gpg-agent` for SSH support.
- If your shell is zsh, source `~/.zshrc` instead.

## Test That Your Keys Exist

Run:

```bash
gpg --list-keys
ssh-add -L
```

- `gpg --list-keys` lists available keys.
- `ssh-add -L` shows loaded SSH public keys.
- If no SSH key appears, restart your shell session (or reboot) and retry.

## Add Keys to GitHub/GitLab/Key-Pository

- Show SSH public key:

```bash
ssh-add -L | grep card
```

- Copy the key and add it to GitHub/GitLab as a new SSH key.
- Test access (example GitLab host):

```bash
ssh -T git@gitlab.ntrprise.net
```

- Show your GPG public key:

```bash
gpg --armor --export
```

- Copy the key and add it to your profile as a signing key.

## Set Up Git Configuration

Configure global git commit signing with your YubiKey-backed key:

```bash
./setup_yubikey setup-git-ez
```

This flow:
- updates global git name/email/signing settings,
- points git to your signing key,
- prints your current git config,
- runs a signing test.

Or run steps manually:

```bash
./setup_yubikey setup-git-commit-signing
./setup_yubikey test-git-config
./setup_yubikey test-gpg-signing
```

## Test SSH Access

After adding your key to GitLab/GitHub, configure forwarding:

```bash
./setup_yubikey setup-ssh-forwarding
copy-remote-gpg-stubs <user@host>
source ~/.bashrc
ssh -A <host>
```

- `setup-ssh-forwarding` updates your SSH config for agent and GPG socket forwarding.
- `copy-remote-gpg-stubs` imports your public key and subkey stubs on the remote host (from `git-crypt-helpers.sh`, after running `setup-git-crypt-helpers`).
- `ssh -A` forwards your local YubiKey-backed SSH credentials to the remote session.

## YubiKey Setup Is Complete

## Optional: LUKS Container Support

Run:

```bash
./setup_yubikey init
./setup_yubikey create-luks-container
```

- Creates an encrypted LUKS volume (size/location configurable in `setup_variables`).
- Unlock requires both your YubiKey challenge-response and PIN.
- Consider sourcing `openvault.bash` in your shell rc for convenient lock/unlock helpers.
- LUKS flow is Linux-only and exits early on macOS.

## FIDO and Other Modes

- Your YubiKey supports additional MFA modes beyond OpenPGP.
- Strongly consider enabling it for Google Workspace and other identity providers:
  <https://support.google.com/accounts/answer/6103523>

## Other Guides

If you need MFA on AWS CLI, see `AWS-CLI-Setup.md` in this repository.
