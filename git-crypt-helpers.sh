#!/usr/bin/env bash

function git-crypt-init {
  git-crypt init || return

  local attrs_file=".gitattributes"
  local required_line=".gitattributes !filter !diff"

  if [ ! -f "$attrs_file" ]; then
    printf '%s\n' "$required_line" >"$attrs_file"
    return
  fi

  if ! grep -Fqx "$required_line" "$attrs_file"; then
    printf '%s\n' "$required_line" >>"$attrs_file"
  fi
}

function git-crypt-init-gh-actions {
  local action_file
  local workflow
  local tmp_file
  local workflow_count=0

  action_file=".github/actions/git-crypt-unlock/action.yml"

  mkdir -p ".github/actions/git-crypt-unlock" ".github/workflows" || return 1

  cat >"$action_file" <<'EOF'
name: git-crypt unlock
description: Unlock git-crypt data using the GITCRYPT_KEY secret
inputs:
  gitcrypt_key:
    description: Base64 encoded git-crypt key
    required: true
runs:
  using: composite
  steps:
    - name: Decode git-crypt key
      shell: bash
      run: |
        set +x
        printf '%s' "${{ inputs.gitcrypt_key }}" | base64 --decode >"$RUNNER_TEMP/git-crypt-key"
    - name: Unlock repository
      shell: bash
      run: |
        set +x
        git-crypt unlock "$RUNNER_TEMP/git-crypt-key"
        rm -f "$RUNNER_TEMP/git-crypt-key"
EOF

  shopt -s nullglob
  for workflow in .github/workflows/*.yml .github/workflows/*.yaml; do
    workflow_count=$((workflow_count + 1))
    tmp_file="${workflow}.tmp"

    awk '
      function indent_len(line,    m) {
        match(line, /^ */)
        return RLENGTH
      }
      function print_unlock(indent) {
        print indent "- name: Unlock with git-crypt"
        print indent "  uses: ./.github/actions/git-crypt-unlock"
        print indent "  with:"
        print indent "    gitcrypt_key: ${{ secrets.GITCRYPT_KEY }}"
      }
      {
        if (in_checkout) {
          current_indent = indent_len($0)

          if ($0 !~ /^[[:space:]]*$/ && current_indent <= checkout_indent_len) {
            if ($0 !~ /^[[:space:]]*-[[:space:]]+uses:[[:space:]]+\.\/\.github\/actions\/git-crypt-unlock([[:space:]]|$)/) {
              print_unlock(checkout_indent)
            }
            in_checkout = 0
          }
        }

        print

        if ($0 ~ /^([[:space:]]*)-[[:space:]]+uses:[[:space:]]+actions\/checkout@/) {
          match($0, /^([[:space:]]*)-[[:space:]]+uses:[[:space:]]+actions\/checkout@/, m)
          checkout_indent = m[1]
          checkout_indent_len = length(checkout_indent)
          in_checkout = 1
        }
      }
      END {
        if (in_checkout) {
          print_unlock(checkout_indent)
        }
      }
    ' "$workflow" >"$tmp_file" && mv "$tmp_file" "$workflow"
  done
  shopt -u nullglob

  if [ "$workflow_count" -eq 0 ]; then
    printf 'No workflow files found in .github/workflows; created %s\n' "$action_file"
  fi
}

function git-crypt-set-gh-secret {
  local repo
  local status=0
  local xtrace_was_on=0
  local update_actions=1

  if [ "${1:-}" = "--no-actions" ]; then
    update_actions=0
  fi

  case $- in
    *x*)
      xtrace_was_on=1
      set +x
      ;;
  esac

  if ! gh auth status >/dev/null 2>&1; then
    printf 'gh is not authenticated. Run: gh auth login\n' >&2
    status=1
  else
    repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')" || status=1
  fi

  if [ "$status" -eq 0 ]; then
    if ! (set -o pipefail; git-crypt export-key - | base64 | tr -d '\n' | gh secret set GITCRYPT_KEY --repo "$repo"); then
      status=1
    fi
  fi

  if [ "$status" -eq 0 ] && [ "$update_actions" -eq 1 ]; then
    git-crypt-init-gh-actions || status=1
  fi

  if [ "$xtrace_was_on" -eq 1 ]; then
    set -x
  fi

  return "$status"
}

function _git-crypt-require-cmd {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    return 1
  fi
}

function _git-crypt-parse-encrypted-files {
  local line
  local trimmed
  local file

  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [ -z "$trimmed" ] && continue

    if [[ "$trimmed" == encrypted:* ]]; then
      file="${trimmed#encrypted:}"
      file="${file#"${file%%[![:space:]]*}"}"
    else
      file="$trimmed"
    fi

    [ -n "$file" ] && printf '%s\n' "$file"
  done < <(git-crypt status -e)
}

function git-crypt-rekey {
  local skip_unlock=0
  local gh_secret_mode="prompt"
  local gh_repo
  local update_gh_secret_reply
  local -a recipient_files
  local -a recipients
  local -a encrypted_files
  local arg
  local file
  local basename_value
  local recipient

  _git-crypt-require-cmd git || return 1
  _git-crypt-require-cmd git-crypt || return 1
  _git-crypt-require-cmd gpg || return 1

  for arg in "$@"; do
    case "$arg" in
      --no-unlock)
        skip_unlock=1
        ;;
      --update-gh-secret)
        gh_secret_mode="yes"
        ;;
      --no-update-gh-secret)
        gh_secret_mode="no"
        ;;
      *)
        printf 'Unknown option: %s\n' "$arg" >&2
        printf 'Usage: git-crypt-rekey [--no-unlock] [--update-gh-secret|--no-update-gh-secret]\n' >&2
        return 1
        ;;
    esac
  done

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'Run this function from inside a git repository\n' >&2
    return 1
  fi

  if [ ! -d .git-crypt/keys/default/0 ]; then
    printf 'No key recipients found in .git-crypt/keys/default/0\n' >&2
    return 1
  fi

  shopt -s nullglob
  recipient_files=(.git-crypt/keys/default/0/*.gpg)
  shopt -u nullglob

  if [ "${#recipient_files[@]}" -eq 0 ]; then
    printf 'No recipient key files found in .git-crypt/keys/default/0\n' >&2
    return 1
  fi

  recipients=()
  for file in "${recipient_files[@]}"; do
    basename_value="${file##*/}"
    recipients+=("${basename_value%.gpg}")
  done

  if [ "$skip_unlock" -eq 0 ]; then
    printf 'Unlocking repository...\n'
    git-crypt unlock || return 1
  fi

  printf 'Generating a new git-crypt symmetric key...\n'
  rm -f .git/git-crypt/keys/default
  git-crypt init || return 1

  printf 'Re-encrypting key for %d recipient(s)...\n' "${#recipients[@]}"
  mkdir -p .git-crypt/keys/default/0 || return 1
  for recipient in "${recipients[@]}"; do
    if ! gpg --batch --yes --trust-model always --encrypt -r "$recipient" \
      < .git/git-crypt/keys/default \
      > ".git-crypt/keys/default/0/${recipient}.gpg"; then
      printf 'Failed to encrypt symmetric key for recipient: %s\n' "$recipient" >&2
      return 1
    fi
  done

  mapfile -t encrypted_files < <(_git-crypt-parse-encrypted-files)

  if [ "${#encrypted_files[@]}" -eq 0 ]; then
    printf 'No encrypted files found; recipient keys were rotated.\n'
    return 0
  fi

  printf 'Re-encrypting %d tracked file(s)...\n' "${#encrypted_files[@]}"
  git rm --cached -- "${encrypted_files[@]}" || return 1
  git add -- "${encrypted_files[@]}" || return 1

  if [ "$gh_secret_mode" != "no" ] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh_repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)"

    if [ -n "$gh_repo" ]; then
      if [ "$gh_secret_mode" = "yes" ]; then
        printf 'Updating GITCRYPT_KEY in GitHub for %s...\n' "$gh_repo"
        git-crypt-set-gh-secret --no-actions || return 1
      elif [ -t 0 ]; then
        printf 'Update GITCRYPT_KEY in GitHub for %s now? [y/N]: ' "$gh_repo"
        IFS= read -r update_gh_secret_reply

        case "$update_gh_secret_reply" in
          [Yy]|[Yy][Ee][Ss])
            printf 'Updating GITCRYPT_KEY in GitHub...\n'
            git-crypt-set-gh-secret --no-actions || return 1
            ;;
        esac
      fi
    fi
  fi

  printf 'Done. Review changes with git status and git diff --cached.\n'
}

function _git-crypt-base64-decode {
  if base64 --decode >/dev/null 2>&1 <<<""; then
    base64 --decode
  else
    base64 -D
  fi
}

function _git-crypt-normalize-token {
  printf '%s' "$1" | tr -cd '[:alnum:]' | tr '[:lower:]' '[:upper:]'
}

function _git-crypt-short-fingerprint {
  local normalized
  local short

  normalized="$(_git-crypt-normalize-token "$1")"

  if [ "${#normalized}" -gt 8 ]; then
    short="${normalized: -8}"
  else
    short="$normalized"
  fi

  if [ "${#short}" -gt 4 ]; then
    printf '%s-%s\n' "${short:0:4}" "${short:4}"
  else
    printf '%s\n' "$short"
  fi
}

function git-crypt-share-key {
  local -a key_rows
  local selected
  local uid
  local fingerprint
  local armored_key
  local encoded_key
  local share_string
  local short_fingerprint
  local idx
  local choice

  if ! command -v gpg >/dev/null 2>&1; then
    printf 'gpg is not installed or not in PATH\n' >&2
    return 1
  fi

  mapfile -t key_rows < <(
    gpg --list-secret-keys --with-colons --fingerprint 2>/dev/null | awk -F: '
      $1 == "sec" {
        current_fpr = ""
        printed_uid = 0
        next
      }

      $1 == "fpr" && current_fpr == "" {
        current_fpr = $10
        next
      }

      $1 == "uid" && current_fpr != "" && printed_uid == 0 {
        uid = $10
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", uid)
        if (uid != "") {
          print uid "\t" current_fpr
          printed_uid = 1
        }
      }
    '
  )

  if [ "${#key_rows[@]}" -eq 0 ]; then
    printf 'No GPG secret keys found in keyring\n' >&2
    return 1
  fi

  if [ "${#key_rows[@]}" -eq 1 ]; then
    selected="${key_rows[0]}"
  elif command -v fzf >/dev/null 2>&1; then
    if ! selected="$({ printf '%s\n' "${key_rows[@]}"; } | fzf --height=40% --reverse --prompt='Select key to share (Esc to cancel)> ')"; then
      printf 'Selection cancelled\n'
      return 0
    fi
  else
    printf 'Multiple secret keys found:\n'
    for idx in "${!key_rows[@]}"; do
      uid="${key_rows[$idx]%%$'\t'*}"
      fingerprint="${key_rows[$idx]#*$'\t'}"
      printf '  %d) %s [%s]\n' "$((idx + 1))" "$uid" "$(_git-crypt-short-fingerprint "$fingerprint")"
    done

    printf 'Select key number (blank to cancel): '
    IFS= read -r choice

    if [ -z "$choice" ]; then
      printf 'Selection cancelled\n'
      return 0
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#key_rows[@]}" ]; then
      printf 'Invalid selection\n' >&2
      return 1
    fi

    selected="${key_rows[$((choice - 1))]}"
  fi

  uid="${selected%%$'\t'*}"
  fingerprint="${selected#*$'\t'}"

  if ! armored_key="$(gpg --armor --export "$fingerprint" 2>/dev/null)"; then
    printf 'Failed to export selected key\n' >&2
    return 1
  fi

  encoded_key="$(printf '%s' "$armored_key" | base64 | tr -d '\n')"
  share_string="GPGSHARE1:${fingerprint}:${encoded_key}"
  short_fingerprint="$(_git-crypt-short-fingerprint "$fingerprint")"

  printf 'Share this string with the other user:\n\n%s\n\n' "$share_string"
  printf 'Verbal confirmation code: %s\n' "$short_fingerprint"
  printf 'Selected key: %s\n' "$uid"
}

function git-crypt-import-shared-key {
  local share_string
  local payload
  local sender_fingerprint
  local encoded_key
  local armored_key
  local imported_fingerprint
  local imported_uid
  local spoken_code
  local expected_code
  local normalized_spoken
  local normalized_expected

  if ! command -v gpg >/dev/null 2>&1; then
    printf 'gpg is not installed or not in PATH\n' >&2
    return 1
  fi

  if [ "$#" -gt 0 ]; then
    share_string="$1"
  else
    printf 'Paste shared key string: '
    IFS= read -r share_string
  fi

  if [ -z "$share_string" ]; then
    printf 'No shared key string provided\n' >&2
    return 1
  fi

  if [[ "$share_string" != GPGSHARE1:* ]]; then
    printf 'Invalid shared key format\n' >&2
    return 1
  fi

  payload="${share_string#GPGSHARE1:}"
  sender_fingerprint="${payload%%:*}"
  encoded_key="${payload#*:}"

  if [ "$payload" = "$encoded_key" ] || [ -z "$sender_fingerprint" ] || [ -z "$encoded_key" ]; then
    printf 'Invalid shared key format\n' >&2
    return 1
  fi

  sender_fingerprint="$(_git-crypt-normalize-token "$sender_fingerprint")"

  if [ -z "$sender_fingerprint" ]; then
    printf 'Invalid fingerprint in shared key\n' >&2
    return 1
  fi

  if ! armored_key="$(printf '%s' "$encoded_key" | _git-crypt-base64-decode 2>/dev/null)"; then
    printf 'Failed to decode shared key data\n' >&2
    return 1
  fi

  imported_fingerprint="$({
    printf '%s' "$armored_key" | gpg --import-options show-only --dry-run --with-colons --import 2>/dev/null
  } | awk -F: '$1 == "fpr" { print $10; exit }')"

  imported_uid="$({
    printf '%s' "$armored_key" | gpg --import-options show-only --dry-run --with-colons --import 2>/dev/null
  } | awk -F: '$1 == "uid" { print $10; exit }')"

  imported_fingerprint="$(_git-crypt-normalize-token "$imported_fingerprint")"

  if [ -z "$imported_fingerprint" ]; then
    printf 'Could not read fingerprint from shared key data\n' >&2
    return 1
  fi

  if [ "$imported_fingerprint" != "$sender_fingerprint" ]; then
    printf 'Fingerprint mismatch between payload and key data\n' >&2
    return 1
  fi

  expected_code="$(_git-crypt-short-fingerprint "$sender_fingerprint")"
  normalized_expected="$(_git-crypt-normalize-token "$expected_code")"

  printf 'Key to import: %s\n' "$imported_uid"
  printf 'Enter verbally confirmed fingerprint code: '
  IFS= read -r spoken_code

  normalized_spoken="$(_git-crypt-normalize-token "$spoken_code")"

  if [ "$normalized_spoken" != "$normalized_expected" ]; then
    printf 'Fingerprint confirmation failed; key not imported\n' >&2
    return 1
  fi

  if ! printf '%s' "$armored_key" | gpg --import; then
    printf 'Failed to import key\n' >&2
    return 1
  fi

  printf 'Imported key fingerprint: %s\n' "$sender_fingerprint"
}

function git-crypt-add-gpg-user-interactive {
  local -a key_rows
  local selected
  local user_id

  if ! command -v gpg >/dev/null 2>&1; then
    printf 'gpg is not installed or not in PATH\n' >&2
    return 1
  fi

  if ! command -v git-crypt >/dev/null 2>&1; then
    printf 'git-crypt is not installed or not in PATH\n' >&2
    return 1
  fi

  if ! command -v fzf >/dev/null 2>&1; then
    printf 'fzf is required for interactive selection. Install fzf and try again.\n' >&2
    return 1
  fi

  mapfile -t key_rows < <(
    gpg --list-keys --with-colons --fingerprint 2>/dev/null | awk -F: '
      $1 == "pub" {
        current_fpr = ""
        next
      }

      $1 == "fpr" && current_fpr == "" {
        current_fpr = $10
        next
      }

      $1 == "uid" && current_fpr != "" {
        uid = $10
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", uid)
        if (uid != "") {
          print uid "\t" current_fpr
        }
      }
    '
  )

  if [ "${#key_rows[@]}" -eq 0 ]; then
    printf 'No GPG public keys found in keyring\n' >&2
    return 1
  fi

  if ! selected="$(
    printf '%s\n' "${key_rows[@]}" | fzf --height=40% --reverse --prompt='Select GPG user (Esc to cancel)> '
  )"; then
    printf 'Selection cancelled\n'
    return 0
  fi

  user_id="${selected#*$'\t'}"

  if [ -z "$user_id" ]; then
    printf 'Could not determine selected USER_ID\n' >&2
    return 1
  fi

  git-crypt add-gpg-user "$user_id"
}

function git-crypt-remove-gpg-user {
  local target_user
  local target_file
  local -a recipient_files
  local -a key_rows
  local selected
  local basename_value
  local keep_count
  local display_uid
  local recipient_id
  local is_self
  local matched_user
  local target_normalized
  local candidate_normalized

  _git-crypt-require-cmd git || return 1
  _git-crypt-require-cmd git-crypt || return 1
  _git-crypt-require-cmd gpg || return 1

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'Run this function from inside a git repository\n' >&2
    return 1
  fi

  shopt -s nullglob
  recipient_files=(.git-crypt/keys/default/0/*.gpg)
  shopt -u nullglob

  if [ "${#recipient_files[@]}" -eq 0 ]; then
    printf 'No git-crypt recipients found in .git-crypt/keys/default/0\n' >&2
    return 1
  fi

  key_rows=()
  for target_file in "${recipient_files[@]}"; do
    basename_value="${target_file##*/}"
    recipient_id="${basename_value%.gpg}"

    is_self=0
    if gpg --list-secret-keys --with-colons --fingerprint "$recipient_id" 2>/dev/null | awk -F: '$1 == "sec" { found = 1 } END { exit found ? 0 : 1 }'; then
      is_self=1
    fi

    if [ "$is_self" -eq 1 ]; then
      continue
    fi

    display_uid="$(gpg --list-keys --with-colons --fingerprint "$recipient_id" 2>/dev/null | awk -F: '$1 == "uid" { print $10; exit }')"

    if [ -z "$display_uid" ]; then
      display_uid="[unknown user]"
    fi

    key_rows+=("${display_uid}\t${recipient_id}")
  done

  if [ "$#" -gt 0 ]; then
    target_user="$1"
  else
    _git-crypt-require-cmd fzf || return 1

    if [ "${#key_rows[@]}" -eq 0 ]; then
      printf 'No removable recipients found (only your own key is present)\n' >&2
      return 1
    fi

    if ! selected="$(printf '%s\n' "${key_rows[@]}" | fzf --height=40% --reverse --prompt='Select GPG user to remove (Esc to cancel)> ')"; then
      printf 'Selection cancelled\n'
      return 0
    fi

    target_user="${selected#*$'\t'}"
  fi

  target_file=".git-crypt/keys/default/0/${target_user}.gpg"

  if [ ! -f "$target_file" ]; then
    matched_user=""
    target_normalized="$(_git-crypt-normalize-token "$target_user")"

    for target_file in "${recipient_files[@]}"; do
      basename_value="${target_file##*/}"
      recipient_id="${basename_value%.gpg}"
      candidate_normalized="$(_git-crypt-normalize-token "$recipient_id")"

      if [ "$candidate_normalized" = "$target_normalized" ] || [[ "$candidate_normalized" == *"$target_normalized" ]]; then
        if [ -n "$matched_user" ]; then
          printf 'Recipient identifier is ambiguous: %s\n' "$target_user" >&2
          return 1
        fi
        matched_user="$recipient_id"
      fi
    done

    if [ -z "$matched_user" ]; then
      printf 'Recipient not found: %s\n' "$target_user" >&2
      return 1
    fi

    target_user="$matched_user"
    target_file=".git-crypt/keys/default/0/${target_user}.gpg"
  fi

  if gpg --list-secret-keys --with-colons --fingerprint "$target_user" 2>/dev/null | awk -F: '$1 == "sec" { found = 1 } END { exit found ? 0 : 1 }'; then
    printf 'Refusing to remove your own key: %s\n' "$target_user" >&2
    return 1
  fi

  keep_count=$(( ${#recipient_files[@]} - 1 ))
  if [ "$keep_count" -lt 1 ]; then
    printf 'Refusing to remove the last recipient key\n' >&2
    return 1
  fi

  git-crypt unlock >/dev/null 2>&1 || return 1

  rm -f -- "$target_file" || return 1

  printf 'Removed recipient key for: %s\n' "$target_user"
  printf 'Rotating repository symmetric key to revoke prior access...\n'

  git-crypt-rekey --no-unlock
}

function _git-crypt-first-fingerprint {
  gpg --with-colons --fingerprint "$1" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }'
}

function _git-crypt-generate-test-key {
  local gnupg_home
  local real_name
  local email
  local uid
  local gpg_output

  gnupg_home="$1"
  real_name="$2"
  email="$3"
  uid="${real_name} <${email}>"

  if command -v gpgconf >/dev/null 2>&1; then
    GNUPGHOME="$gnupg_home" gpgconf --launch gpg-agent >/dev/null 2>&1 || true
  fi

  for _ in 1 2 3; do
    if gpg_output="$(GNUPGHOME="$gnupg_home" gpg --batch --pinentry-mode loopback --passphrase '' --quick-gen-key "$uid" default default 0 2>&1)"; then
      return 0
    fi
    sleep 1
  done

  printf 'Failed to generate test key for %s\n%s\n' "$uid" "$gpg_output" >&2

  return 1
}

function git-crypt-test-sandbox {
  (
    set -euo pipefail

    local sandbox_root
    local repo_dir
    local bob_clone
    local alice_home
    local bob_home
    local alice_fpr
    local bob_fpr
    local share_output
    local share_token
    local verbal_code
    local test_secret

    _git-crypt-require-cmd git
    _git-crypt-require-cmd git-crypt
    _git-crypt-require-cmd gpg
    _git-crypt-require-cmd awk
    _git-crypt-require-cmd mktemp

    sandbox_root="${1:-$(mktemp -d "${TMPDIR:-/tmp}/git-crypt-sandbox.XXXXXX")}" 
    mkdir -p "$sandbox_root"

    repo_dir="$sandbox_root/r1"
    bob_clone="$sandbox_root/r2"
    alice_home="$sandbox_root/a"
    bob_home="$sandbox_root/b"
    test_secret="sandbox-secret-v1"

    mkdir -p "$alice_home" "$bob_home"
    chmod 700 "$alice_home" "$bob_home"

    printf 'Creating sandbox in %s\n' "$sandbox_root"

    _git-crypt-generate-test-key "$alice_home" "Alice Example" "alice@example.com"
    _git-crypt-generate-test-key "$bob_home" "Bob Example" "bob@example.com"

    alice_fpr="$(GNUPGHOME="$alice_home" _git-crypt-first-fingerprint "alice@example.com")"
    bob_fpr="$(GNUPGHOME="$bob_home" _git-crypt-first-fingerprint "bob@example.com")"

    if [ -z "$alice_fpr" ] || [ -z "$bob_fpr" ]; then
      printf 'Failed to generate sandbox GPG keys\n' >&2
      exit 1
    fi

    git init "$repo_dir" >/dev/null || exit 1
    (
      cd "$repo_dir"
      git config user.name "Sandbox Tester"
      git config user.email "sandbox@example.com"
      printf 'secret/** filter=git-crypt diff=git-crypt\n' > .gitattributes
      mkdir -p secret
      printf '%s\n' "$test_secret" > secret/data.txt

      GNUPGHOME="$bob_home" gpg --armor --export "$bob_fpr" > "$sandbox_root/bob.pub.asc"
      GNUPGHOME="$alice_home" gpg --import "$sandbox_root/bob.pub.asc" >/dev/null 2>&1
      printf '%s:6:\n' "$bob_fpr" | GNUPGHOME="$alice_home" gpg --import-ownertrust >/dev/null 2>&1

      GNUPGHOME="$alice_home" git-crypt-init || {
        printf 'Failed to initialize git-crypt\n' >&2
        exit 1
      }

      GNUPGHOME="$alice_home" git-crypt add-gpg-user "$alice_fpr" >/dev/null || {
        printf 'Failed to add Alice as git-crypt recipient\n' >&2
        exit 1
      }

      git add .gitattributes secret/data.txt .git-crypt || {
        printf 'Failed to stage initial encrypted files\n' >&2
        exit 1
      }
      git commit -m "Initialize sandbox git-crypt setup" >/dev/null || {
        printf 'Failed to commit initial sandbox setup\n' >&2
        exit 1
      }

      GNUPGHOME="$alice_home" git-crypt add-gpg-user "$bob_fpr" >/dev/null || {
        printf 'Failed to add Bob as git-crypt recipient\n' >&2
        exit 1
      }
    ) || exit 1

    git clone "$repo_dir" "$bob_clone" >/dev/null 2>&1 || exit 1
    (
      cd "$bob_clone"
      GNUPGHOME="$bob_home" git-crypt unlock >/dev/null || {
        printf 'Bob failed to unlock the repository\n' >&2
        exit 1
      }
      if [ "$(<secret/data.txt)" != "$test_secret" ]; then
        printf 'Bob failed to read decrypted secret\n' >&2
        exit 1
      fi
    ) || exit 1

    share_output="$(GNUPGHOME="$bob_home" git-crypt-share-key)"
    share_token="$(printf '%s\n' "$share_output" | awk '/^GPGSHARE1:/{print; exit}')"
    verbal_code="$(printf '%s\n' "$share_output" | awk -F': ' '/^Verbal confirmation code:/{print $2; exit}')"

    if [ -z "$share_token" ] || [ -z "$verbal_code" ]; then
      printf 'Failed to produce share token and verbal code\n' >&2
      exit 1
    fi

    (
      cd "$repo_dir"
      printf '%s\n' "$verbal_code" | GNUPGHOME="$alice_home" git-crypt-import-shared-key "$share_token" >/dev/null
      if ! GNUPGHOME="$alice_home" gpg --list-keys "$bob_fpr" >/dev/null 2>&1; then
        printf 'Shared key import test failed\n' >&2
        exit 1
      fi

      if GNUPGHOME="$alice_home" git-crypt-remove-gpg-user "$alice_fpr" >/dev/null 2>&1; then
        printf 'Self-removal guard failed\n' >&2
        exit 1
      fi

      GNUPGHOME="$alice_home" git-crypt-remove-gpg-user "$bob_fpr" >/dev/null || {
        printf 'Failed to remove Bob recipient\n' >&2
        exit 1
      }

      git add -A
      git commit -m "Revoke bob from sandbox" >/dev/null
    ) || exit 1

    git clone "$repo_dir" "$sandbox_root/r3" >/dev/null 2>&1 || exit 1
    (
      cd "$sandbox_root/r3"
      if GNUPGHOME="$bob_home" git-crypt unlock >/dev/null 2>&1; then
        printf 'Bob can still unlock after revocation\n' >&2
        exit 1
      fi
    ) || exit 1

    printf 'Sandbox E2E test passed\n'
    printf 'Sandbox path: %s\n' "$sandbox_root"
  )
}
