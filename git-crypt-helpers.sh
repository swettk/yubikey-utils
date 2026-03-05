#!/usr/bin/env bash

function _git-crypt-ensure-line-in-file {
  local line="$1"
  local file="$2"

  touch "$file"
  if ! grep -Fxq "$line" "$file"; then
    printf '%s\n' "$line" >> "$file"
  fi
}

function git-crypt-install-helpers {
  local source_file="${1:-}"
  local shell_rc="${2:-}"
  local target_file="$HOME/.git-crypt-helpers.sh"
  local source_line="[ -f \"\$HOME/.git-crypt-helpers.sh\" ] && source \"\$HOME/.git-crypt-helpers.sh\""

  if [ -z "$source_file" ]; then
    printf 'Usage: git-crypt-install-helpers <source-file> [shell-rc]\n' >&2
    return 1
  fi

  if [ ! -f "$source_file" ]; then
    printf 'git-crypt helpers source file not found: %s\n' "$source_file" >&2
    return 1
  fi

  if [ -z "$shell_rc" ]; then
    case "${SHELL:-/bin/bash}" in
      */zsh)  shell_rc="$HOME/.zshrc" ;;
      */bash) shell_rc="$HOME/.bashrc" ;;
      *)      shell_rc="$HOME/.profile" ;;
    esac
  fi

  cp "$source_file" "$target_file"
  chmod 600 "$target_file"

  _git-crypt-ensure-line-in-file "$source_line" "$shell_rc"

  echo "Installed git-crypt helpers at $target_file"
  echo "Added helper source line to $shell_rc"
}

function git-crypt-setup-gpg-agent {
  local shell_rc="${1:-}"
  local os_name="${2:-$(uname -s)}"
  local gnupg_dir="$HOME/.gnupg"
  local gpg_agent_conf="$gnupg_dir/gpg-agent.conf"
  local pinentry_path

  if [ -z "$shell_rc" ]; then
    case "${SHELL:-/bin/bash}" in
      */zsh)  shell_rc="$HOME/.zshrc" ;;
      */bash) shell_rc="$HOME/.bashrc" ;;
      *)      shell_rc="$HOME/.profile" ;;
    esac
  fi

  mkdir -p "$gnupg_dir"
  chmod 700 "$gnupg_dir"

  if [ "$os_name" = "Darwin" ]; then
    pinentry_path="$(command -v pinentry-mac 2>/dev/null || echo /opt/homebrew/bin/pinentry-mac)"
  else
    pinentry_path="$(command -v pinentry-gnome3 2>/dev/null || command -v pinentry-curses 2>/dev/null || echo /usr/bin/pinentry-gnome3)"
  fi

  touch "$gpg_agent_conf"
  chmod 600 "$gpg_agent_conf"
  _git-crypt-ensure-line-in-file "enable-ssh-support" "$gpg_agent_conf"
  _git-crypt-ensure-line-in-file "default-cache-ttl 600" "$gpg_agent_conf"
  _git-crypt-ensure-line-in-file "max-cache-ttl 7200" "$gpg_agent_conf"
  _git-crypt-ensure-line-in-file "default-cache-ttl-ssh 600" "$gpg_agent_conf"
  _git-crypt-ensure-line-in-file "max-cache-ttl-ssh 7200" "$gpg_agent_conf"
  _git-crypt-ensure-line-in-file "pinentry-program ${pinentry_path}" "$gpg_agent_conf"

  _git-crypt-ensure-line-in-file "export GPG_TTY=\$(tty)" "$shell_rc"
  _git-crypt-ensure-line-in-file "gpgconf --launch gpg-agent" "$shell_rc"
  _git-crypt-ensure-line-in-file "export SSH_AUTH_SOCK=\$(gpgconf --list-dirs agent-ssh-socket)" "$shell_rc"

  gpgconf --kill gpg-agent || true
  gpgconf --launch gpg-agent
  gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1 || true

  echo "Configured gpg-agent with ssh support."
  echo "Reload your shell to pick up SSH_AUTH_SOCK from $shell_rc"
}

function git-crypt-setup-ssh-forwarding {
  local shell_rc="${1:-}"
  local os_name="${2:-$(uname -s)}"
  local ssh_dir="$HOME/.ssh"
  local ssh_config="$ssh_dir/config"
  local agent_ssh_socket
  local agent_extra_socket

  git-crypt-setup-gpg-agent "$shell_rc" "$os_name" || return 1

  agent_ssh_socket="$(gpgconf --list-dirs agent-ssh-socket)"
  agent_extra_socket="$(gpgconf --list-dirs agent-extra-socket)"

  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"
  touch "$ssh_config"
  chmod 600 "$ssh_config"

  if ! grep -Fq '# >>> yubikey-work forwarding >>>' "$ssh_config"; then
    cat << EOF >> "$ssh_config"

# >>> yubikey-work forwarding >>>
Host *
  ForwardAgent yes
  IdentityAgent ${agent_ssh_socket}
  StreamLocalBindUnlink yes
  RemoteForward ~/.gnupg/S.gpg-agent ${agent_extra_socket}
# <<< yubikey-work forwarding <<<
EOF
  fi

  echo "Configured ssh forwarding in $ssh_config"
  echo "Use ssh -A <host> to forward your YubiKey-backed ssh key."
}

function git-crypt-copy-remote-gpg-stubs {
  local remote_host="${1:-}"
  local key_identity="${2:-}"
  local remote_gnupg_dir=".gnupg"
  local temp_public
  local temp_stubs

  if [ -z "$remote_host" ]; then
    printf 'Usage: git-crypt-copy-remote-gpg-stubs <user@host> [email-or-keyid]\n' >&2
    return 1
  fi

  if [ -z "$key_identity" ]; then
    key_identity="$(gpg --list-options show-only-fpr-mbox --list-secret-keys 2>/dev/null | awk 'NR==1 {print $1}')"
  fi

  if [ -z "$key_identity" ]; then
    printf 'Could not determine GPG key identity. Pass email or key id as argument 2.\n' >&2
    return 1
  fi

  if gpg --list-secret-keys --keyid-format LONG "$key_identity" 2>/dev/null | grep -q '^sec\s'; then
    printf 'Refusing to copy because local keyring appears to include full secret keys.\n' >&2
    printf 'Use a stub-only keyring (for example after ./setup_yubikey keys-to-user).\n' >&2
    return 1
  fi

  temp_public="$(mktemp "${TMPDIR:-/tmp}/gpg-pubkey.XXXXXX.asc")"
  temp_stubs="$(mktemp "${TMPDIR:-/tmp}/gpg-stubs.XXXXXX.asc")"

  if ! gpg --armor --export "$key_identity" > "$temp_public"; then
    rm -f "$temp_public" "$temp_stubs"
    return 1
  fi

  if ! gpg --armor --export-secret-subkeys "$key_identity" > "$temp_stubs"; then
    rm -f "$temp_public" "$temp_stubs"
    return 1
  fi

  ssh "$remote_host" "mkdir -p '$remote_gnupg_dir' && chmod 700 '$remote_gnupg_dir'" || {
    rm -f "$temp_public" "$temp_stubs"
    return 1
  }

  scp "$temp_public" "$temp_stubs" "$remote_host:$remote_gnupg_dir/" || {
    rm -f "$temp_public" "$temp_stubs"
    return 1
  }

  ssh "$remote_host" "gpg --batch --import '$remote_gnupg_dir/$(basename "$temp_public")' '$remote_gnupg_dir/$(basename "$temp_stubs")' && rm -f '$remote_gnupg_dir/$(basename "$temp_public")' '$remote_gnupg_dir/$(basename "$temp_stubs")'" || {
    rm -f "$temp_public" "$temp_stubs"
    return 1
  }

  rm -f "$temp_public" "$temp_stubs"

  echo "Copied and imported gpg public key + subkey stubs on $remote_host"
  echo "Now connect with: ssh -A $remote_host"
}

function copy-remote-gpg-stubs {
  git-crypt-copy-remote-gpg-stubs "$@"
}

function git-crypt-export-gpg-pubkey {
  local pubkey_dir="${1:-$HOME/Documents/myPublicKeys}"
  local key_identity="${2:-}"
  local pubkey_file

  mkdir -p "$pubkey_dir"
  pubkey_file="$pubkey_dir/gpg.pubkey"

  if [ -n "$key_identity" ]; then
    gpg --armor --export "$key_identity" > "$pubkey_file"
  else
    gpg --armor --export > "$pubkey_file"
  fi

  printf 'Exported GPG public key to %s\n' "$pubkey_file"
}

function export-gpg-pubkey {
  git-crypt-export-gpg-pubkey "$@"
}

function git-crypt-setup-git-commit-signing {
  local real_name="${1:-}"
  local email="${2:-}"
  local signing_key

  signing_key="$(gpg --list-secret-keys --keyid-format LONG | grep sec | cut -d ' ' -f4 | cut -c9-)"

  git config --global commit.gpgsign true
  git config --global user.signingkey "$signing_key"
  git config --global user.name "$real_name"
  git config --global user.email "$email"
}

function setup-git-commit-signing {
  git-crypt-setup-git-commit-signing "$@"
}

function git-crypt-key-to-gh {
  git-crypt-import-keys-to-github "${1:-}" "${2:-}"
}

function key-to-gh {
  git-crypt-key-to-gh "$@"
}

function git-crypt-create-luks-container {
  local os_name="${1:-}"
  local luks_path="${2:-}"
  local luks_size_in_gb="${3:-}"
  local keypin="${4:-}"
  local username="${5:-}"
  local group_id="${6:-}"
  local enable_hmac_cmd="${7:-enable_hmac}"

  if [[ "$os_name" == "Darwin" ]]; then
    echo "LUKS containers are not supported on macOS (requires Linux dm-crypt)."
    return 1
  fi

  if [ -f "$luks_path" ]; then
    echo "File Exists for luks container, remove by hand before continue"
    return 1
  fi

  "$enable_hmac_cmd"
  dd of="$luks_path" if=/dev/zero bs=1G count=0 seek="$luks_size_in_gb" 1> /dev/null
  echo -n "$(ykchalresp -2 "$keypin")" | cryptsetup -v --pbkdf pbkdf2 luksFormat "$luks_path"
  echo -n "$(ykchalresp -2 "$keypin")" | sudo cryptsetup open "$luks_path" luks &>/dev/null
  sudo mkfs.ext4 /dev/mapper/luks > /dev/null 2>&1
  sudo fsck /dev/mapper/luks > /dev/null 2>&1
  mkdir -p "$HOME/luks"
  sudo mount /dev/mapper/luks "$HOME/luks"
  sudo chown -R "$username:$group_id" "$HOME/luks"
  echo ""
  echo "*****************************************************************"
  echo "consider including openvault.bash in your shellrc "
  echo "file of choice for easier lock/unlock"
  echo "container is locked based on your hmac key stored in your"
  echo "yubikey and your pin, please make sure this directory"
  echo "is backed up appropriately"
  echo "your luks container is portable, you can back it up or move"
  echo "it between laptops, but it will require a yubikey to open"
  echo "*****************************************************************"
}

function create-luks-container {
  git-crypt-create-luks-container "$@"
}

function git-crypt-test-gpg-signing {
  echo "Begin Signature Test"
  echo "********************"
  gpg --output ~/rc.sig --sign /etc/hosts 1> /dev/null
  gpg --verify ~/rc.sig
  rm -f ~/rc.sig
  echo ""
  echo "Signature Test Complete"
  echo ""
}

function test-gpg-signing {
  git-crypt-test-gpg-signing "$@"
}

function git-crypt-test-git-config {
  echo 'Current Git Config'
  echo "******************"
  echo 'Current Git Name = ' $(git config --get user.name)
  echo 'Current Git Email = ' $(git config --get user.email)
  echo 'Automatically sign commits = ' $(git config --get commit.gpgsign)
  echo ""
}

function test-git-config {
  git-crypt-test-git-config "$@"
}

function git-crypt-setup-git-ez {
  local real_name="${1:-}"
  local email="${2:-}"

  echo "Beginning Express Git Configuration..."
  git-crypt-setup-git-commit-signing "$real_name" "$email"
  sleep 1
  echo "Setup Complete! Testing Configuration..."
  echo ""
  sleep 1
  git-crypt-test-git-config
  sleep 1
  git-crypt-test-gpg-signing
}

function setup-git-ez {
  git-crypt-setup-git-ez "$@"
}

function setup-ssh-forwarding {
  git-crypt-setup-ssh-forwarding "$@"
}

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

function git-crypt-import-keys-to-github {
  local email="${1:-}"
  local real_name="${2:-}"
  local tmpdir
  local gpg_pub
  local ssh_pub
  local ssh_keys
  local selected_ssh_key
  local host_short
  local today
  local gpg_title
  local ssh_title

  _git-crypt-require-cmd gh || return 1
  _git-crypt-require-cmd gpg || return 1
  _git-crypt-require-cmd ssh-add || return 1
  _git-crypt-require-cmd mktemp || return 1

  if ! gh auth status -h github.com >/dev/null 2>&1; then
    printf 'GitHub CLI is not authenticated for github.com. Run: gh auth login\n' >&2
    return 1
  fi

  if [ -z "$email" ]; then
    email="$(git config --global --get user.email 2>/dev/null || true)"
  fi

  if [ -z "$real_name" ]; then
    real_name="$(git config --global --get user.name 2>/dev/null || true)"
  fi

  tmpdir="$(mktemp -d)"
  gpg_pub="$tmpdir/gpg.pub"
  ssh_pub="$tmpdir/ssh.pub"

  if [ -n "$email" ]; then
    gpg --armor --export "$email" > "$gpg_pub"
  else
    gpg --armor --export > "$gpg_pub"
  fi

  if [ ! -s "$gpg_pub" ]; then
    rm -rf "$tmpdir"
    printf 'Unable to export a GPG public key%s\n' "${email:+ for $email}." >&2
    return 1
  fi

  if ! ssh_keys="$(ssh-add -L 2>/dev/null)"; then
    rm -rf "$tmpdir"
    printf 'Unable to read SSH public keys from ssh-agent\n' >&2
    printf 'Run setup-ssh-forwarding and ensure your YubiKey auth key is loaded\n' >&2
    return 1
  fi

  if [ -z "$ssh_keys" ] || [[ "$ssh_keys" == *"The agent has no identities"* ]]; then
    rm -rf "$tmpdir"
    printf 'No SSH public keys found in ssh-agent\n' >&2
    printf 'Run setup-ssh-forwarding and ensure your YubiKey auth key is loaded\n' >&2
    return 1
  fi

  selected_ssh_key="$(printf '%s\n' "$ssh_keys" | awk '/cardno|card|[Yy]ubi[Kk]ey/ { print; found = 1; exit } END { if (!found) print "" }')"
  if [ -z "$selected_ssh_key" ]; then
    selected_ssh_key="$(printf '%s\n' "$ssh_keys" | awk 'NF { print; exit }')"
  fi

  if [ -z "$selected_ssh_key" ]; then
    rm -rf "$tmpdir"
    printf 'Unable to determine an SSH public key to upload\n' >&2
    return 1
  fi

  printf '%s\n' "$selected_ssh_key" > "$ssh_pub"

  host_short="$(hostname -s 2>/dev/null || hostname)"
  today="$(date +%Y-%m-%d)"

  if [ -z "$real_name" ]; then
    real_name="${email:-$(whoami)}"
  fi

  gpg_title="${real_name} yubikey ${today}"
  ssh_title="${real_name}@${host_short} yubikey ${today}"

  printf 'Publishing GPG key to GitHub...\n'
  if ! gh gpg-key add "$gpg_pub" --title "$gpg_title"; then
    rm -rf "$tmpdir"
    return 1
  fi

  printf 'Publishing SSH key to GitHub...\n'
  if ! gh ssh-key add "$ssh_pub" --title "$ssh_title"; then
    rm -rf "$tmpdir"
    return 1
  fi

  rm -rf "$tmpdir"
  printf 'Published GPG and SSH public keys to GitHub\n'
}

function _git-crypt-require-cmd {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    return 1
  fi
}

function _git-crypt-doctor-report {
  local level="$1"
  local message="$2"

  case "$level" in
    ok)
      printf '[OK] %s\n' "$message"
      ;;
    warn)
      printf '[WARN] %s\n' "$message"
      ;;
    fail)
      printf '[FAIL] %s\n' "$message"
      ;;
    info)
      printf '[INFO] %s\n' "$message"
      ;;
    *)
      printf '[?] %s\n' "$message"
      ;;
  esac
}

function git-crypt-doctor {
  local failures=0
  local warnings=0
  local in_repo=0
  local gpg_secret_count=0
  local recipient_count=0
  local encrypted_count=0
  local agent_ssh_socket
  local agent_extra_socket
  local cmd
  local -a required_cmds
  local -a recipient_files

  required_cmds=(git git-crypt gpg awk mktemp base64)

  printf 'Running git-crypt diagnostics...\n'

  for cmd in "${required_cmds[@]}"; do
    if command -v "$cmd" >/dev/null 2>&1; then
      _git-crypt-doctor-report ok "Found command: $cmd"
    else
      _git-crypt-doctor-report fail "Missing command: $cmd"
      failures=$((failures + 1))
    fi
  done

  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    in_repo=1
    _git-crypt-doctor-report ok "Inside a git repository"
  else
    _git-crypt-doctor-report warn "Not inside a git repository (repo checks skipped)"
    warnings=$((warnings + 1))
  fi

  if [ "$in_repo" -eq 1 ]; then
    if [ -d .git-crypt/keys/default/0 ]; then
      shopt -s nullglob
      recipient_files=(.git-crypt/keys/default/0/*.gpg)
      shopt -u nullglob
      recipient_count="${#recipient_files[@]}"

      if [ "$recipient_count" -gt 0 ]; then
        _git-crypt-doctor-report ok "Found $recipient_count git-crypt recipient key file(s)"
      else
        _git-crypt-doctor-report warn "No recipient key files found in .git-crypt/keys/default/0"
        warnings=$((warnings + 1))
      fi
    else
      _git-crypt-doctor-report warn "git-crypt recipient directory missing (.git-crypt/keys/default/0)"
      warnings=$((warnings + 1))
    fi

    if [ -f .gitattributes ] && grep -Eq 'filter=git-crypt|diff=git-crypt' .gitattributes; then
      _git-crypt-doctor-report ok "Detected git-crypt rules in .gitattributes"
    else
      _git-crypt-doctor-report warn "No git-crypt rules found in .gitattributes"
      warnings=$((warnings + 1))
    fi

    if encrypted_count="$(git-crypt status -e 2>/dev/null | awk 'NF { count++ } END { print count + 0 }')"; then
      _git-crypt-doctor-report info "git-crypt status reports $encrypted_count encrypted tracked file(s)"
    else
      _git-crypt-doctor-report warn "Failed to run git-crypt status -e"
      warnings=$((warnings + 1))
    fi
  fi

  if gpg_secret_count="$(gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '$1 == "sec" { count++ } END { print count + 0 }')"; then
    if [ "$gpg_secret_count" -gt 0 ]; then
      _git-crypt-doctor-report ok "Found $gpg_secret_count local GPG secret key(s)"
    else
      _git-crypt-doctor-report warn "No local GPG secret keys found"
      warnings=$((warnings + 1))
    fi
  else
    _git-crypt-doctor-report fail "Unable to list GPG secret keys"
    failures=$((failures + 1))
  fi

  if command -v gpgconf >/dev/null 2>&1; then
    agent_ssh_socket="$(gpgconf --list-dirs agent-ssh-socket 2>/dev/null)"
    agent_extra_socket="$(gpgconf --list-dirs agent-extra-socket 2>/dev/null)"

    if [ -n "$agent_ssh_socket" ]; then
      _git-crypt-doctor-report info "gpg-agent ssh socket path: $agent_ssh_socket"
    else
      _git-crypt-doctor-report warn "Could not determine gpg-agent ssh socket path"
      warnings=$((warnings + 1))
    fi

    if [ -n "$agent_extra_socket" ]; then
      _git-crypt-doctor-report info "gpg-agent extra socket path: $agent_extra_socket"
    else
      _git-crypt-doctor-report warn "Could not determine gpg-agent extra socket path"
      warnings=$((warnings + 1))
    fi
  else
    _git-crypt-doctor-report warn "gpgconf not found; skipping gpg-agent socket checks"
    warnings=$((warnings + 1))
  fi

  if [ -n "${GPG_TTY:-}" ]; then
    _git-crypt-doctor-report ok "GPG_TTY is set"
  else
    _git-crypt-doctor-report warn "GPG_TTY is not set in current shell"
    warnings=$((warnings + 1))
  fi

  if command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then
      _git-crypt-doctor-report ok "GitHub CLI authenticated"
    else
      _git-crypt-doctor-report warn "GitHub CLI installed but not authenticated"
      warnings=$((warnings + 1))
    fi
  else
    _git-crypt-doctor-report info "GitHub CLI not installed (only needed for GITCRYPT_KEY secret automation)"
  fi

  printf 'Diagnostics complete: %d failure(s), %d warning(s)\n' "$failures" "$warnings"

  if [ "$failures" -gt 0 ]; then
    return 1
  fi

  return 0
}

function git-crypt-diagnostics {
  git-crypt-doctor "$@"
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

function _git-crypt-test-forwarding-features {
  local sandbox_root="$1"
  local test_home="$sandbox_root/forwarding-home"
  local fake_bin="$sandbox_root/forwarding-bin"
  local shell_rc="$test_home/.bashrc"
  local call_log="$sandbox_root/forwarding-calls.log"
  local gpg_agent_conf="$test_home/.gnupg/gpg-agent.conf"
  local ssh_config="$test_home/.ssh/config"
  local gpg_tty_count

  mkdir -p "$test_home" "$fake_bin"
  : > "$call_log"

  cat > "$fake_bin/gpgconf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "--list-dirs" ]; then
  if [ "${2:-}" = "agent-ssh-socket" ]; then
    printf '/tmp/test-agent-ssh.sock\n'
    exit 0
  fi
  if [ "${2:-}" = "agent-extra-socket" ]; then
    printf '/tmp/test-agent-extra.sock\n'
    exit 0
  fi
fi
exit 0
EOF

  cat > "$fake_bin/gpg-connect-agent" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "$fake_bin/gpg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "--list-options" ] && [ "${2:-}" = "show-only-fpr-mbox" ]; then
  printf 'stub@example.com\n'
  exit 0
fi
if [ "${1:-}" = "--list-secret-keys" ]; then
  printf 'ssb   ed25519/FAKEKEY 2024-01-01 [A]\n'
  exit 0
fi
if [ "${1:-}" = "--armor" ] && [ "${2:-}" = "--export" ]; then
  printf 'PUBLIC-KEY\n'
  exit 0
fi
if [ "${1:-}" = "--armor" ] && [ "${2:-}" = "--export-secret-subkeys" ]; then
  printf 'SUBKEY-STUBS\n'
  exit 0
fi
exit 0
EOF

  cat > "$fake_bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh %s\n' "$*" >> "$FAKE_CALL_LOG"
exit 0
EOF

  cat > "$fake_bin/scp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'scp %s\n' "$*" >> "$FAKE_CALL_LOG"
exit 0
EOF

  chmod +x "$fake_bin/gpgconf" "$fake_bin/gpg-connect-agent" "$fake_bin/gpg" "$fake_bin/ssh" "$fake_bin/scp"

  HOME="$test_home" PATH="$fake_bin:$PATH" SHELL=/bin/bash \
    git-crypt-setup-gpg-agent "$shell_rc" Linux

  [ -f "$gpg_agent_conf" ] || {
    printf 'Forwarding test failed: gpg-agent.conf not created\n' >&2
    return 1
  }

  grep -Fqx 'enable-ssh-support' "$gpg_agent_conf" || {
    printf 'Forwarding test failed: enable-ssh-support missing\n' >&2
    return 1
  }

  grep -Eq '^pinentry-program ' "$gpg_agent_conf" || {
    printf 'Forwarding test failed: pinentry-program missing\n' >&2
    return 1
  }

  HOME="$test_home" PATH="$fake_bin:$PATH" SHELL=/bin/bash \
    git-crypt-setup-gpg-agent "$shell_rc" Linux

  gpg_tty_count="$(grep -Fxc "export GPG_TTY=\$(tty)" "$shell_rc")"
  [ "$gpg_tty_count" -eq 1 ] || {
    printf 'Forwarding test failed: shell rc lines are not idempotent\n' >&2
    return 1
  }

  HOME="$test_home" PATH="$fake_bin:$PATH" SHELL=/bin/bash \
    git-crypt-setup-ssh-forwarding "$shell_rc" Linux

  [ -f "$ssh_config" ] || {
    printf 'Forwarding test failed: ssh config not created\n' >&2
    return 1
  }

  grep -Fqx '  IdentityAgent /tmp/test-agent-ssh.sock' "$ssh_config" || {
    printf 'Forwarding test failed: IdentityAgent line missing\n' >&2
    return 1
  }

  grep -Fqx '  RemoteForward ~/.gnupg/S.gpg-agent /tmp/test-agent-extra.sock' "$ssh_config" || {
    printf 'Forwarding test failed: RemoteForward line missing\n' >&2
    return 1
  }

  HOME="$test_home" PATH="$fake_bin:$PATH" SHELL=/bin/bash FAKE_CALL_LOG="$call_log" \
    git-crypt-copy-remote-gpg-stubs "tester@example-host" "stub@example.com"

  grep -Fq 'scp ' "$call_log" || {
    printf 'Forwarding test failed: scp was not called\n' >&2
    return 1
  }

  grep -Fq 'ssh tester@example-host gpg --batch --import' "$call_log" || {
    printf 'Forwarding test failed: remote gpg import was not called\n' >&2
    return 1
  }
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

    _git-crypt-test-forwarding-features "$sandbox_root" || exit 1

    printf 'Sandbox E2E test passed\n'
    printf 'Sandbox path: %s\n' "$sandbox_root"
  )
}
