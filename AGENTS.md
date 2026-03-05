# AGENTS.md - yubikey-work

## Purpose
This guide is for coding agents working in this repository.
Project context: Bash-based YubiKey/GPG automation with security-sensitive flows.
Prefer minimal, explicit, backward-compatible edits.

## Agent Quickstart (30 seconds)
1. Confirm you are in repo root: `pwd` should end in `yubikey-work`.
2. Read `setup_yubikey` and the exact function(s) you will touch before editing.
3. Keep diffs small; preserve CLI names and behavior unless change is requested.
4. Never commit secrets or populate `setup_variables` in tracked changes.
5. Validate touched scripts with `shellcheck setup_yubikey openvault.bash gpg-helpers.sh`.
6. Run one quick check when possible: `source ./gpg-helpers.sh && test-git-config`.
7. If hardware-dependent checks cannot run, explicitly note what was not verified.

## Repository Layout
`setup_yubikey` - main CLI entrypoint and workflow orchestrator.
`setup_variables` - user-editable secrets/config (must stay empty in git).
`openvault.bash` - sourceable LUKS lock/unlock helpers.
`gpg-helpers.sh` - reusable git-crypt helper functions.
`README.md` - user/operator documentation.

## Cursor / Copilot Rule Files
No additional rule files are currently present:
- `.cursorrules` not found
- `.cursor/rules/` not found
- `.github/copilot-instructions.md` not found

If any are added later, treat them as higher-priority instructions and update this file.

## Build / Run / Lint / Test

## Build
There is no build step and no package manager for this repo.

## Run
Run from repository root:

```bash
./setup_yubikey <command>
```

Current commands:

```text
init, init-ez, reset-yubikey, generate-master, setup-key-ez, keys-to-card,
keys-to-user, enable-hmac, setup-gpg-agent, setup-gpg-helpers
```

## Lint
No lint wrapper is configured. Use shellcheck directly:

```bash
shellcheck setup_yubikey openvault.bash gpg-helpers.sh
```

## Test
No formal unit/integration test framework is configured.
Testing is command-based and partly environment/hardware dependent.

Quick validations:

```bash
source ./gpg-helpers.sh
test-git-config
# or
test-gpg-signing
```

Single-test equivalent (run one check only):

```bash
source ./gpg-helpers.sh && test-git-config
# or
source ./gpg-helpers.sh && test-gpg-signing
```

`gpg-helpers.sh` includes an end-to-end sandbox function:

```bash
source ./gpg-helpers.sh
gpg-test-sandbox
```

Recommended pre-PR verification:

```bash
shellcheck setup_yubikey openvault.bash gpg-helpers.sh
source ./gpg-helpers.sh && test-git-config
```

Run `test-gpg-signing` only where GPG key material is configured.

## Platform and Runtime Constraints
- OS is detected via `uname -s` and stored as `OS`.
- Supported: Ubuntu Linux and macOS.
- LUKS (`cryptsetup`) flow is Linux-only; macOS should exit early.
- Do not run top-level scripts with `sudo`; scripts escalate when needed.

## Code Style Guidelines

## Language
- Use Bash.
- Keep shebang style consistent with touched file (`#!/bin/bash` or `#!/usr/bin/env bash`).

## Strict Mode and Safety
- Respect existing `set -euo pipefail` behavior.
- Assume unset variables are errors once strict mode is active.
- Use `|| true` only for intentionally non-fatal commands.

## Imports / Sourcing
- Prefer quoted source paths in new edits, e.g. `source "$(dirname "$0")/setup_variables"`.
- `setup_variables` should contain assignments only (no side-effect commands).
- Sourceable helper files should be safe to source multiple times.

## Formatting
- 2-space indentation inside functions.
- One logical operation per line when practical.
- Use here-docs for generated config/script content.

## Naming
- `setup_yubikey` internals use `snake_case` functions.
- User-facing CLI subcommands use `kebab-case` in dispatch.
- `gpg-helpers.sh` public functions intentionally use `gpg-*` names.
- Internal helper functions in that file use `_gpg-*` prefix.
- Use uppercase for exported/config constants; lowercase for local temporaries.

## Types and Data Handling (Bash)
- Treat values as strings unless integer arithmetic is required.
- Use `local` in functions.
- Use arrays for lists (`"${arr[@]}"`) instead of word-splitting strings.
- Prefer `$(...)` command substitution (never backticks).
- Quote variable expansions: `"$var"`, `"${var:-}"`, `"${arr[@]}"`.

## Conditionals and Validation
- Prefer `[[ ... ]]` in new code.
- Keep existing `[ ... ]` style when doing minimal-touch edits unless refactoring nearby code.
- Validate required inputs early and return/exit with clear messages.

## Error Handling and Logging
- Fail fast on unrecoverable states.
- Write error diagnostics to stderr.
- Avoid hiding stderr unless expected noisy output is unhelpful.
- Preserve interactive timing (`sleep`) in GPG/YubiKey automation sections.

## Security and Secrets
- Never commit passphrases, PINs, reset codes, exported keys, or generated archives.
- Keep `setup_variables` blank in git-tracked state.
- Avoid echoing sensitive values to terminal, logs, or commit messages.
- Be cautious when changing global git config behavior.

## Change Management
- Keep CLI behavior backward compatible unless explicitly changing UX.
- If command names/dispatch change, update usage text in `setup_yubikey`.
- If user-facing workflow changes, update `README.md`.
- For gpg/scdaemon interactions, preserve cleanup behavior.

## Agent Execution Notes
- Read the full function/block before editing security-critical or interactive logic.
- Prefer small diffs over broad rewrites.
- Run `shellcheck` on touched scripts before finishing.
- If hardware-dependent tests cannot run, state what could not be verified.
