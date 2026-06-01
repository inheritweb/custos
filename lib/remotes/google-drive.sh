#!/usr/bin/env bash

remote_name() {
  config_job_get_optional '.remote.name' | sed 's/:$//'
}

remote_path() {
  config_job_get '.remote.path'
}

remote_setup() {
  local name
  name="$(remote_name)"
  [[ -n "$name" ]] || name="gdrive"

  if rclone listremotes | grep -Fxq "${name}:"; then
    log_success "Found rclone remote: ${name}:"
  else
    if [[ "${CUSTOS_DRY_RUN:-0}" == "1" ]]; then
      log_info "Dry run: would create Google Drive remote: ${name}:"
      return 0
    fi

    log_warn "No rclone remote named ${name}: found"
    log_info "Creating Google Drive remote: ${name}:"
    log_info "A browser-based Google authorization flow may open."
    rclone config create "$name" drive >/dev/null
  fi

  remote_check
}

remote_check() {
  local name path
  name="$(remote_name)"
  path="$(remote_path)"
  [[ -n "$name" ]] || name="gdrive"

  if [[ "${CUSTOS_DRY_RUN:-0}" == "1" ]]; then
    log_info "Dry run: skipping rclone remote check for ${name}:${path}"
    return 0
  fi

  rclone listremotes | grep -Fxq "${name}:" || die "Missing rclone remote: ${name}:"
  rclone mkdir "${name}:${path}" >/dev/null
  rclone lsd "${name}:${path%/*}" >/dev/null || die "Google Drive remote is not readable: ${name}:${path}"
}

remote_repository_url() {
  local name path
  name="$(remote_name)"
  path="$(remote_path)"
  [[ -n "$name" ]] || name="gdrive"
  printf 'rclone:%s:%s\n' "$name" "$path"
}

remote_config_path() {
  local path
  path="$(remote_path)"
  printf '%s/.custos/config.json\n' "$path"
}

remote_config_upload() {
  local source_file="$1"
  local name config_path

  [[ -f "$source_file" ]] || die "Config export does not exist: $source_file"

  name="$(remote_name)"
  config_path="$(remote_config_path)"
  [[ -n "$name" ]] || name="gdrive"

  if [[ "${CUSTOS_DRY_RUN:-0}" == "1" ]]; then
    log_info "Dry run: would upload config to ${name}:${config_path}"
    return 0
  fi

  rclone copyto "$source_file" "${name}:${config_path}" >/dev/null
  log_success "Stored config bootstrap at ${name}:${config_path}"
}

remote_config_download() {
  local destination_file="$1"
  local name config_path destination_dir

  name="$(remote_name)"
  config_path="$(remote_config_path)"
  [[ -n "$name" ]] || name="gdrive"

  destination_dir="$(dirname -- "$destination_file")"
  mkdir -p "$destination_dir"

  rclone copyto "${name}:${config_path}" "$destination_file" >/dev/null
}
