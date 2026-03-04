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

  if [ "$status" -eq 0 ]; then
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
  local -a recipient_files
  local -a recipients
  local -a encrypted_files
  local file
  local basename_value
  local recipient

  _git-crypt-require-cmd git || return 1
  _git-crypt-require-cmd git-crypt || return 1
  _git-crypt-require-cmd gpg || return 1

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

  printf 'Unlocking repository...\n'
  git-crypt unlock || return 1

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

  _git-crypt-require-cmd git || return 1
  _git-crypt-require-cmd git-crypt || return 1
  _git-crypt-require-cmd gpg || return 1
  _git-crypt-require-cmd fzf || return 1

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
    printf 'Recipient not found: %s\n' "$target_user" >&2
    return 1
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

  rm -f -- "$target_file" || return 1

  printf 'Removed recipient key for: %s\n' "$target_user"
  printf 'Rotating repository symmetric key to revoke prior access...\n'
  git-crypt-rekey
}
