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
