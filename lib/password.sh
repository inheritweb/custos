#!/usr/bin/env bash

password_setup() {
  local password_command
  password_command="$(config_password_command)"

  if [[ -z "$password_command" ]]; then
    log_info "No stored backup password is configured."
    log_info "Backup commands will ask for the repository password when needed."
    log_info "For unattended backups, add secrets.passwordCommand to: $CUSTOS_CONFIG"
    return 0
  fi

  case "$password_command" in
    "pass show "*)
      local pass_name
      pass_name="${password_command#"pass show "}"

      require_command pass || die "Missing dependency: pass"

      if pass show "$pass_name" >/dev/null 2>&1; then
        log_success "Restic password exists in pass: $pass_name"
        return 0
      fi

      log_info "Creating restic password in pass: $pass_name"
      log_info "You will be prompted to enter the password twice."
      pass insert "$pass_name"
      ;;
    *)
      log_info "Configured password command:"
      log_info "  $password_command"
      log_warn "Automatic setup is only supported for password commands using: pass show <name>"
      log_info "Create the secret using your password manager, then rerun: custos doctor"
      ;;
  esac
}

password_status() {
  local password_command
  password_command="$(config_password_command)"

  if [[ -z "$password_command" ]]; then
    printf 'mode: interactive\n'
    printf 'message: Commands and TUI flows should ask for the repository password when needed.\n'
    return 0
  fi

  printf 'mode: command\n'
  printf 'command: %s\n' "$password_command"

  if bash -lc "$password_command" >/dev/null 2>&1; then
    printf 'available: yes\n'
  else
    printf 'available: no\n'
    return 1
  fi
}

password_export_for_backend() {
  local password="$1"
  export RESTIC_PASSWORD="$password"
}

password_prompt_for_backend() {
  local prompt="${1:-Repository password: }"
  local password=""

  if [[ ! -e /dev/tty ]]; then
    die "Cannot prompt for repository password without a terminal"
  fi

  if ! printf '%s' "$prompt" >/dev/tty 2>/dev/null; then
    die "Cannot prompt for repository password without a terminal"
  fi
  if ! IFS= read -rs password </dev/tty; then
    printf '\n' >/dev/tty 2>/dev/null || true
    die "Repository password prompt was cancelled"
  fi
  printf '\n' >/dev/tty 2>/dev/null || true

  password_export_for_backend "$password"
}

password_check() {
  local password_command
  password_command="$(config_password_command)"

  [[ -n "$password_command" ]] || return 0

  if ! command -v "${password_command%% *}" >/dev/null 2>&1; then
    log_error "Backup password manager is not installed: ${password_command%% *}"
    log_info "Install it with:"
    log_info "  sudo pacman -S --needed ${password_command%% *}"
    log_info "  sudo apt-get install ${password_command%% *}"
    log_info "  sudo dnf install ${password_command%% *}"
    log_info "Or choose a different password command in: $CUSTOS_CONFIG"
    exit 1
  fi

  if ! bash -lc "$password_command" >/dev/null 2>&1; then
    log_error "Restic password is not available from configured password command."
    log_info "Configured command:"
    log_info "  $password_command"
    log_info "Run:"
    log_info "  custos password setup"
    exit 1
  fi
}
