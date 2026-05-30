#!/usr/bin/env bash

remote_load() {
  local remote_type remote_file
  remote_type="$(config_get '.remote.type')"
  remote_file="$OMARCHY_BACKUP_LIB_DIR/remotes/${remote_type}.sh"

  [[ -f "$remote_file" ]] || die "Unsupported remote type: $remote_type"
  # shellcheck source=/dev/null
  source "$remote_file"
}

restic_prepare_password() {
  local password_command

  unset RESTIC_PASSWORD_COMMAND

  if [[ -n "${RESTIC_PASSWORD:-}" ]]; then
    if [[ "${OMARCHY_BACKUP_PASSWORD_NOTICE_SHOWN:-0}" != "1" ]]; then
      log_info "Using password supplied by the current environment."
      OMARCHY_BACKUP_PASSWORD_NOTICE_SHOWN=1
    fi
    return 0
  fi

  password_command="$(config_password_command)"
  if [[ -n "$password_command" ]]; then
    if ! command -v "${password_command%% *}" >/dev/null 2>&1; then
      if [[ "${OMARCHY_BACKUP_PASSWORD_NOTICE_SHOWN:-0}" != "1" ]]; then
        log_warn "Configured backup password command is unavailable: ${password_command%% *}"
        log_info "Falling back to an interactive repository password prompt."
        OMARCHY_BACKUP_PASSWORD_NOTICE_SHOWN=1
      fi
      unset RESTIC_PASSWORD_COMMAND
      if [[ "${OMARCHY_BACKUP_DRY_RUN:-0}" != "1" ]]; then
        password_prompt_for_backend "Repository password: "
      fi
      return 0
    fi

    if ! bash -lc "$password_command" >/dev/null 2>&1; then
      if [[ "${OMARCHY_BACKUP_PASSWORD_NOTICE_SHOWN:-0}" != "1" ]]; then
        log_warn "Configured backup password command did not return a password."
        log_info "Falling back to an interactive repository password prompt."
        OMARCHY_BACKUP_PASSWORD_NOTICE_SHOWN=1
      fi
      unset RESTIC_PASSWORD_COMMAND
      if [[ "${OMARCHY_BACKUP_DRY_RUN:-0}" != "1" ]]; then
        password_prompt_for_backend "Repository password: "
      fi
      return 0
    fi

    export RESTIC_PASSWORD_COMMAND="$password_command"
    if [[ "${OMARCHY_BACKUP_PASSWORD_NOTICE_SHOWN:-0}" != "1" ]]; then
      log_info "Using configured password command for repository access."
      OMARCHY_BACKUP_PASSWORD_NOTICE_SHOWN=1
    fi
    return 0
  fi

  if [[ "${OMARCHY_BACKUP_PASSWORD_NOTICE_SHOWN:-0}" != "1" ]]; then
    log_info "Repository password is not stored."
    OMARCHY_BACKUP_PASSWORD_NOTICE_SHOWN=1
  fi

  if [[ "${OMARCHY_BACKUP_DRY_RUN:-0}" != "1" ]]; then
    password_prompt_for_backend "Repository password: "
  fi
}

restic_password_mode() {
  if [[ -n "${RESTIC_PASSWORD:-}" ]]; then
    printf 'environment\n'
    return 0
  fi

  local password_command
  password_command="$(config_password_command)"
  if [[ -n "$password_command" ]] && command -v "${password_command%% *}" >/dev/null 2>&1 && bash -lc "$password_command" >/dev/null 2>&1; then
    printf 'command\n'
    return 0
  fi

  printf 'interactive\n'
}

restic_explain_password_prompt() {
  case "$(restic_password_mode)" in
    interactive)
      log_info "Repository password is not stored; you may be prompted for it now."
      ;;
    command)
      log_info "Using configured password command for repository access."
      ;;
    environment)
      log_info "Using password supplied by the current environment."
      ;;
  esac
}

restic_base_args() {
  local repository
  repository="${OMARCHY_BACKUP_REPOSITORY:-$(remote_repository_url)}"
  printf '%s\0' --repo "$repository"
}

restic_run() {
  restic_prepare_password

  local -a base_args
  mapfile -d '' -t base_args < <(restic_base_args)

  if [[ "${OMARCHY_BACKUP_DRY_RUN:-0}" == "1" ]]; then
    printf 'restic' >&2
    printf ' %q' "${base_args[@]}" "$@" >&2
    printf '\n' >&2
    return 0
  fi

  restic "${base_args[@]}" "$@"
}

restic_run_with_prompt_notice() {
  if ! restic_run "$@"; then
    log_error "Repository operation failed."
    log_info "If you were prompted for a password, check that it matches this repository."
    return 1
  fi
}

restic_require_initialized() {
  if [[ "${OMARCHY_BACKUP_DRY_RUN:-0}" == "1" ]]; then
    return 0
  fi

  restic_prepare_password

  local -a base_args
  local error_file
  mapfile -d '' -t base_args < <(restic_base_args)
  error_file="$(mktemp)"

  if restic "${base_args[@]}" snapshots --json >/dev/null 2>"$error_file"; then
    rm -f "$error_file"
    return 0
  fi

  if grep -Eiq 'repository does not exist|unable to open config file|Is there a repository' "$error_file"; then
    cat "$error_file" >&2
    rm -f "$error_file"
    log_error "Restic repository is not initialized at $(remote_repository_url)"
    log_info "Run:"
    log_info "  omarchy-backup setup"
    log_info "or:"
    log_info "  omarchy-backup init"
    return 1
  fi

  cat "$error_file" >&2
  rm -f "$error_file"
  log_error "Could not access Restic repository."
  return 1
}

restic_init() {
  if restic_run snapshots --json >/dev/null 2>&1; then
    log_success "Restic repository already initialized"
    return 0
  fi

  if ! restic_run init; then
    log_error "Repository initialization failed."
    log_info "For a new repository, use the password you want for this backup repository."
    return 1
  fi
}

restic_backup() {
  local dry_run=0
  local -a backup_args includes excludes

  while (($#)); do
    case "$1" in
      --dry-run)
        dry_run=1
        shift
        ;;
      *)
        die "Unknown backup option: $1"
        ;;
    esac
  done

  mapfile -t includes < <(config_include_paths)
  mapfile -t excludes < <(config_exclude_patterns)

  ((${#includes[@]} > 0)) || die "No include paths configured"

  restic_require_initialized

  local config_export_path
  config_export_path="$(config_export_for_repository)"
  remote_config_upload "$config_export_path"

  backup_args=(backup --one-file-system --host "$(config_hostname)")
  if ((dry_run)); then
    backup_args+=(--dry-run)
  fi

  local pattern
  for pattern in "${excludes[@]}"; do
    backup_args+=(--exclude "$pattern")
  done

  local -a existing_includes=()
  local include_path
  for include_path in "${includes[@]}"; do
    if [[ -e "$include_path" ]]; then
      existing_includes+=("$include_path")
    else
      log_info "Skipping missing include path: $(config_compact_home_path "$include_path")"
    fi
  done

  ((${#existing_includes[@]} > 0)) || die "No configured include paths exist on this machine"

  backup_args+=("${existing_includes[@]}")
  restic_run_with_prompt_notice "${backup_args[@]}"
}

restic_snapshots() {
  restic_run_with_prompt_notice snapshots "$@"
}

restic_ls() {
  (($# >= 1)) || die "Usage: omarchy-backup ls <snapshot> [path]"
  restic_run_with_prompt_notice ls "$@"
}

restic_restore() {
  restic_run_with_prompt_notice restore "$@"
}

restic_check() {
  restic_run_with_prompt_notice check "$@"
}

restic_forget() {
  local dry_run=0
  while (($#)); do
    case "$1" in
      --dry-run)
        dry_run=1
        shift
        ;;
      *)
        die "Unknown forget option: $1"
        ;;
    esac
  done

  local daily weekly monthly
  daily="$(config_get '.retention.daily')"
  weekly="$(config_get '.retention.weekly')"
  monthly="$(config_get '.retention.monthly')"

  local -a args=(forget --keep-daily "$daily" --keep-weekly "$weekly" --keep-monthly "$monthly")
  if ((dry_run)); then
    args+=(--dry-run)
  fi
  restic_run_with_prompt_notice "${args[@]}"
}

restic_prune() {
  restic_run_with_prompt_notice prune "$@"
}

restic_unlock() {
  restic_run_with_prompt_notice unlock "$@"
}
