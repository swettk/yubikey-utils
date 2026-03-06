# AGENTS.md - yubikey-utils

## Purpose
Guide for coding agents working in this repository.
Context: Bash-based YubiKey/GPG automation with security-sensitive, hardware-dependent flows.
Prefer minimal, explicit, backward-compatible edits.

## Agent Quickstart
1. Confirm you are in repo root (`pwd` should end in `yubikey-utils`).
2. Read the full function you will touch before editing — especially security-critical or interactive logic.
3. Keep diffs small; preserve CLI names and behavior unless change is requested.
4. Never commit secrets or populate `setup_variables` in tracked changes.
5. Validate touched scripts: `shellcheck setup-yubikey openvault.bash gpg-helpers.sh`.
6. Run a quick check when possible: `source ./gpg-helpers.sh && test-git-config`.
7. If hardware-dependent checks cannot run, explicitly note what was not verified.

## Repository Layout
```
setup-yubikey      Main CLI entrypoint and workflow orchestrator (#!/bin/bash)
setup_variables    User-editable secrets/config — must stay empty in git (no shebang)
gpg-helpers.sh     Sourceable git-crypt/GPG helper functions (#!/usr/bin/env bash)
openvault.bash     Sourceable LUKS lock/unlock helpers (#!/bin/bash)
README.md          User/operator documentation
```

## Cursor / Copilot Rule Files
No additional rule files are present. If any are added later, treat them as
higher-priority instructions and update this file.

## Build / Run / Lint / Test

### Build
No build step. No package manager. Pure shell scripts.

### Run
```bash
./setup-yubikey <command>
```
Commands: `init`, `init-ez`, `reset-yubikey`, `generate-master`, `setup-key-ez`,
`keys-to-card`, `keys-to-user`, `enable-hmac`, `setup-gpg-agent`,
`setup-gpg-helpers`, `setup-vars`, `oneshot`, `help`.

### Lint
```bash
shellcheck setup-yubikey openvault.bash gpg-helpers.sh
```
No `.shellcheckrc` exists. No lint wrapper script.

### Test
No formal test framework. Testing is command-based and partly hardware-dependent.

**Single quick validation (no GPG key needed):**
```bash
source ./gpg-helpers.sh && test-git-config
```

**GPG signing test (requires key material):**
```bash
source ./gpg-helpers.sh && test-gpg-signing
```

**End-to-end sandbox test (requires git-crypt, gpg; creates temp keys):**
```bash
source ./gpg-helpers.sh && gpg-test-sandbox
```

**Diagnostics (checks commands, git-crypt state, GPG keys, agent sockets):**
```bash
source ./gpg-helpers.sh && gpg-doctor
```

**Recommended pre-PR verification:**
```bash
shellcheck setup-yubikey openvault.bash gpg-helpers.sh
source ./gpg-helpers.sh && test-git-config
```

## Platform and Runtime Constraints
- OS detected via `uname -s`, stored in `OS`. Supported: Ubuntu Linux and macOS.
- LUKS (`cryptsetup`) flows are Linux-only; macOS code paths should exit/return early.
- Do not run top-level scripts with `sudo`; scripts escalate when needed.
- `sleep` calls between GPG/YubiKey/scdaemon operations are intentional — preserve them.

## Code Style Guidelines

### Language and Shebangs
- Use Bash. Keep shebang consistent with the file being edited:
  - `setup-yubikey`, `openvault.bash`: `#!/bin/bash`
  - `gpg-helpers.sh`: `#!/usr/bin/env bash`

### Strict Mode
- `setup-yubikey` activates `set -euo pipefail` after sourcing config and validating variables.
- `gpg-helpers.sh` does NOT set strict mode at top level (it is sourced into user shells).
  Strict mode is used inside the `gpg-test-sandbox` subshell and generated test scripts.
- Respect existing strict-mode boundaries. Use `|| true` only for intentionally non-fatal commands.

### Function Declarations
- Always use the `function` keyword: `function name {`, not `name() {`.
- `setup-yubikey`: `snake_case` function names (e.g., `generate_master`, `keys_to_card`).
  Internal helpers prefixed with `_` (e.g., `_prompt_secret_value`).
- `gpg-helpers.sh`: public functions use `gpg-` prefix with kebab-case (e.g., `gpg-setup-git-ez`).
  Internal helpers use `_gpg-` prefix (e.g., `_gpg-require-cmd`).
  Legacy short aliases (e.g., `test-git-config`) are one-line wrappers — do not add new ones.
- `openvault.bash`: `snake_case` (e.g., `unlock_vault`).
- CLI dispatch in `setup-yubikey` maps `kebab-case` strings to `snake_case` functions.

### Variables and Naming
- Uppercase for exported/config constants: `OS`, `PASSPHRASE`, `KEYID`, `GNUPGHOME`.
- Lowercase with `local` for function-scoped variables.
- Declare arrays with `local -a` (e.g., `local -a key_rows`).
- Always use `local` in functions. Avoid leaking variables to global scope.

### Quoting and Substitution
- Quote all variable expansions: `"$var"`, `"${var:-}"`, `"${arr[@]}"`.
- Use `$(...)` for command substitution — never backticks.
- Use `"${var:-default}"` for safe fallbacks under `set -u`.

### Conditionals
- Prefer `[[ ... ]]` in new code.
- Keep existing `[ ... ]` style when making minimal-touch edits unless refactoring nearby code.
- Validate required inputs early; return/exit with a clear error message.

### Output and Logging
- `gpg-helpers.sh` uses `printf` exclusively — follow this in that file.
- `setup-yubikey` and `openvault.bash` use `echo` — follow per-file convention.
- Write error diagnostics to stderr (`>&2`).
- Avoid hiding stderr unless the command produces expected noisy output.

### Error Handling
- Fail fast on unrecoverable states.
- Use `_gpg-require-cmd <cmd> || return 1` to guard required commands in `gpg-helpers.sh`.
- Chain external commands with `|| return 1` for recoverable errors.
- `gpg-test-sandbox` runs in a `( subshell )` with `set -euo pipefail` and uses `exit 1`.
- `gpg-doctor` uses structured `[OK]`/`[WARN]`/`[FAIL]`/`[INFO]` output via `_gpg-doctor-report`.

### Formatting
- 2-space indentation inside functions.
- One logical operation per line when practical.
- Use here-docs (`<< EOF` or `<<'EOF'`) for generated config/script content.
- `case` arms: `pattern)` on its own line, body indented, `;;` to terminate.

### Imports / Sourcing
- Use quoted source paths: `source "$(dirname "$0")/setup_variables"`.
- `setup_variables` must contain assignments only — no commands with side effects.
- Sourceable files (`gpg-helpers.sh`, `openvault.bash`) must be safe to source multiple times.
- `gpg-helpers.sh` detects direct execution via `${BASH_SOURCE[0]} == "$0"` and offers auto-install.

## Security and Secrets
- Never commit passphrases, PINs, reset codes, exported keys, or generated archives.
- Keep `setup_variables` blank in the git-tracked state.
- Avoid echoing sensitive values to terminal, logs, or commit messages.
- `gpg-copy-remote-gpg-stubs` refuses to copy if local keyring has full secret keys — preserve such guards.
- `gpg-gitcrypt-remove-gpg-user` refuses self-removal and last-recipient removal — preserve such guards.
- Be cautious when changing global git config behavior.

## Change Management
- Keep CLI behavior backward compatible unless explicitly changing UX.
- If command names or dispatch change, update the usage text in `setup-yubikey` and `README.md`.
- If user-facing workflow changes, update `README.md`.
- For gpg/scdaemon interactions, preserve cleanup and timing behavior.

## Agent Execution Notes
- Prefer small diffs over broad rewrites.
- Run `shellcheck` on every touched script before finishing.
- If hardware-dependent tests cannot run, state what could not be verified.
- Zsh compatibility: `gpg-share-key` includes `ZSH_VERSION` array-index handling — preserve it.
