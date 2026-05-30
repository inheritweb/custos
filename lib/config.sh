#!/usr/bin/env bash

OMARCHY_BACKUP_CONFIG="${OMARCHY_BACKUP_CONFIG:-$HOME/.config/omarchy-backup/config.json}"
OMARCHY_BACKUP_STATE_DIR="${OMARCHY_BACKUP_STATE_DIR:-$HOME/.local/state/omarchy-backup}"
OMARCHY_BACKUP_REPOSITORY_CONFIG_PATH="/.omarchy-backup/config.json"

config_ensure_exists() {
  if [[ -f "$OMARCHY_BACKUP_CONFIG" ]]; then
    return 0
  fi

  local config_dir
  config_dir="$(dirname -- "$OMARCHY_BACKUP_CONFIG")"
  mkdir -p "$config_dir"

  cat >"$OMARCHY_BACKUP_CONFIG" <<'JSON'
{
  "version": 1,
  "profile": "default",
  "remote": {
    "type": "google-drive",
    "name": "gdrive",
    "path": "backups/home"
  },
  "repository": {
    "name": "desktop",
    "hostname": "auto"
  },
  "paths": {
    "include": [
      "~/Documents",
      "~/Pictures",
      "~/.ssh",
      "~/.gnupg",
      "~/.password-store"
    ],
    "exclude": [
      "**/node_modules",
      "**/.next",
      "**/dist",
      "**/.turbo",
      "**/.cache",
      "**/.venv",
      "**/target",
      "**/*.iso"
    ]
  },
  "retention": {
    "daily": 7,
    "weekly": 4,
    "monthly": 6
  }
}
JSON
  log_info "Created default config at $OMARCHY_BACKUP_CONFIG"
}

config_print() {
  config_ensure_exists
  jq . "$OMARCHY_BACKUP_CONFIG"
}

config_get() {
  local query="$1"
  config_ensure_exists
  jq -er "$query" "$OMARCHY_BACKUP_CONFIG"
}

config_get_optional() {
  local query="$1"
  config_ensure_exists
  jq -r "$query // empty" "$OMARCHY_BACKUP_CONFIG"
}

config_validate() {
  config_ensure_exists

  jq -e '
    .version == 1 and
    (.remote.type | type == "string") and
    (.remote.path | type == "string") and
    (.paths.include | type == "array") and
    (.paths.exclude | type == "array") and
    (.retention.daily | type == "number") and
    (.retention.weekly | type == "number") and
    (.retention.monthly | type == "number")
  ' "$OMARCHY_BACKUP_CONFIG" >/dev/null || die "Invalid config: $OMARCHY_BACKUP_CONFIG"
}

config_expand_path() {
  local path="$1"
  case "$path" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s/%s\n' "$HOME" "${path#"~/"}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

config_compact_home_path() {
  local path="$1"
  case "$path" in
    "$HOME") printf '~\n' ;;
    "$HOME"/*) printf '~/%s\n' "${path#"$HOME"/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

config_include_paths() {
  config_ensure_exists
  jq -r '.paths.include[]' "$OMARCHY_BACKUP_CONFIG" | while IFS= read -r path; do
    config_expand_path "$path"
  done
}

config_exclude_patterns() {
  config_ensure_exists
  jq -r '.paths.exclude[]' "$OMARCHY_BACKUP_CONFIG"
}

config_paths_list() {
  config_ensure_exists

  printf 'Include paths:\n'
  jq -r '.paths.include[] | "  - " + .' "$OMARCHY_BACKUP_CONFIG"
  printf 'Exclude patterns:\n'
  jq -r '.paths.exclude[] | "  - " + .' "$OMARCHY_BACKUP_CONFIG"
}

config_paths_add() {
  local kind="$1"
  local value="$2"
  local tmp_file

  [[ "$kind" == "include" || "$kind" == "exclude" ]] || die "Path kind must be include or exclude"
  [[ -n "$value" ]] || die "Path value cannot be empty"

  value="$(config_compact_home_path "$value")"

  config_ensure_exists
  tmp_file="$(mktemp)"

  jq --arg value "$value" --arg kind "$kind" '
    .paths[$kind] = ((.paths[$kind] + [$value]) | unique)
  ' "$OMARCHY_BACKUP_CONFIG" >"$tmp_file"
  mv "$tmp_file" "$OMARCHY_BACKUP_CONFIG"
}

config_paths_remove() {
  local kind="$1"
  local value="$2"
  local tmp_file

  [[ "$kind" == "include" || "$kind" == "exclude" ]] || die "Path kind must be include or exclude"
  [[ -n "$value" ]] || die "Path value cannot be empty"

  value="$(config_compact_home_path "$value")"

  config_ensure_exists
  tmp_file="$(mktemp)"

  jq --arg value "$value" --arg kind "$kind" '
    .paths[$kind] = (.paths[$kind] | map(select(. != $value)))
  ' "$OMARCHY_BACKUP_CONFIG" >"$tmp_file"
  mv "$tmp_file" "$OMARCHY_BACKUP_CONFIG"
}

config_password_command() {
  if [[ ! -f "$OMARCHY_BACKUP_CONFIG" ]]; then
    return 0
  fi

  config_get_optional '.secrets.passwordCommand'
}

config_hostname() {
  local configured
  configured="$(config_get_optional '.repository.hostname')"
  if [[ -z "$configured" || "$configured" == "auto" ]]; then
    hostname
  else
    printf '%s\n' "$configured"
  fi
}

config_repository_export_path() {
  printf '%s/repository-config%s\n' "$OMARCHY_BACKUP_STATE_DIR" "$OMARCHY_BACKUP_REPOSITORY_CONFIG_PATH"
}

config_export_for_repository() {
  config_ensure_exists

  local export_path export_dir
  export_path="$(config_repository_export_path)"
  export_dir="$(dirname -- "$export_path")"
  mkdir -p "$export_dir"

  jq '
    del(.secrets)
    | .metadata.omarchyBackupExportedAt = now | .metadata.omarchyBackupConfigPath = "'"$OMARCHY_BACKUP_CONFIG"'"
  ' "$OMARCHY_BACKUP_CONFIG" >"$export_path" || return 1

  printf '%s\n' "$export_path"
}
