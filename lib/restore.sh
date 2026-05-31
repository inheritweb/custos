#!/usr/bin/env bash

restore_default_target() {
  local snapshot="$1"
  printf '%s/Restored/custos/%s\n' "$HOME" "$snapshot"
}

restore_confirm() {
  local prompt="$1"
  printf '%s [y/N] ' "$prompt" >&2
  local answer
  read -r answer
  [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "yes" || "$answer" == "YES" ]]
}

restore_run() {
  local snapshot="" path="" target="" original=0 dry_run=0 yes=0

  while (($#)); do
    case "$1" in
      --target)
        shift
        (($#)) || die "--target requires a path"
        target="$(config_expand_path "$1")"
        shift
        ;;
      --original)
        original=1
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --yes|-y)
        yes=1
        shift
        ;;
      -*)
        die "Unknown restore option: $1"
        ;;
      *)
        if [[ -z "$snapshot" ]]; then
          snapshot="$1"
        elif [[ -z "$path" ]]; then
          path="$(config_expand_path "$1")"
        else
          die "Unexpected restore argument: $1"
        fi
        shift
        ;;
    esac
  done

  [[ -n "$snapshot" ]] || die "Usage: custos restore <snapshot> [path] [--target <path>|--original]"

  if ((original)); then
    target="/"
  elif [[ -z "$target" ]]; then
    target="$(restore_default_target "$snapshot")"
  fi

  local -a args=("$snapshot" --target "$target")
  if [[ -n "$path" ]]; then
    args+=(--include "$path")
  fi
  if ((dry_run)); then
    args+=(--dry-run)
  fi

  log_info "Snapshot: $snapshot"
  if [[ -n "$path" ]]; then
    log_info "Path filter: $path"
  fi
  log_info "Restore target: $target"

  if ((original)); then
    log_warn "Restoring to original locations can overwrite local files."
  fi

  if ((!yes)); then
    restore_confirm "Continue with restore?" || die "Restore cancelled"
  fi

  mkdir -p "$target"
  restic_restore "${args[@]}"
}
