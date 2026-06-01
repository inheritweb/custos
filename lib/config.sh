#!/usr/bin/env bash

CUSTOS_CONFIG="${CUSTOS_CONFIG:-$HOME/.config/custos/config.json}"
CUSTOS_STATE_DIR="${CUSTOS_STATE_DIR:-$HOME/.local/state/custos}"
CUSTOS_REPOSITORY_CONFIG_PATH="/.custos/config.json"

config_ensure_exists() {
  if [[ -f "$CUSTOS_CONFIG" ]]; then
    config_migrate_if_needed
    return 0
  fi

  local config_dir
  config_dir="$(dirname -- "$CUSTOS_CONFIG")"
  mkdir -p "$config_dir"

  cat >"$CUSTOS_CONFIG" <<'JSON'
{
  "version": 2,
  "profile": "default",
  "defaultJob": "home",
  "jobs": [
    {
      "id": "home",
      "name": "Home",
      "remote": {
        "type": "google-drive",
        "name": "gdrive",
        "path": "backups/home"
      },
      "repository": {
        "hostname": "auto"
      },
      "paths": {
        "include": [
          "~"
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
  ]
}
JSON
  log_info "Created default config at $CUSTOS_CONFIG"
}

config_migrate_if_needed() {
  local version tmp_file
  version="$(jq -r '.version // 1' "$CUSTOS_CONFIG" 2>/dev/null || printf 'unknown')"
  [[ "$version" == "1" ]] || return 0

  tmp_file="$(mktemp)"
  jq '
    {
      version: 2,
      profile: (.profile // "default"),
      defaultJob: ((.repository.name // "home") | ascii_downcase | gsub("[^a-z0-9_-]+"; "-") | sub("^-+"; "") | sub("-+$"; "")),
      jobs: [
        {
          id: ((.repository.name // "home") | ascii_downcase | gsub("[^a-z0-9_-]+"; "-") | sub("^-+"; "") | sub("-+$"; "")),
          name: (.repository.name // "Home"),
          remote: (.remote // {type: "google-drive", name: "gdrive", path: "backups/home"}),
          repository: {
            hostname: (.repository.hostname // "auto")
          },
          paths: {
            include: (.paths.include // ["~"]),
            exclude: (.paths.exclude // [])
          },
          retention: (.retention // {daily: 7, weekly: 4, monthly: 6})
        }
      ],
      secrets: .secrets
    }
    | if .defaultJob == "" then .defaultJob = "home" | .jobs[0].id = "home" else . end
    | if .secrets == null then del(.secrets) else . end
  ' "$CUSTOS_CONFIG" >"$tmp_file" || {
    rm -f "$tmp_file"
    return 1
  }
  mv "$tmp_file" "$CUSTOS_CONFIG"
  log_info "Migrated config to version 2 at $CUSTOS_CONFIG"
}

config_print() {
  config_ensure_exists
  jq . "$CUSTOS_CONFIG"
}

config_get() {
  local query="$1"
  config_ensure_exists
  jq -er "$query" "$CUSTOS_CONFIG"
}

config_get_optional() {
  local query="$1"
  config_ensure_exists
  jq -r "$query // empty" "$CUSTOS_CONFIG"
}

config_validate() {
  config_ensure_exists

  jq -e '
    .version == 2 and
    (.jobs | type == "array") and
    (.jobs | length > 0) and
    (.defaultJob | type == "string") and
    (.defaultJob as $default | any(.jobs[]; .id == $default)) and
    all(.jobs[];
      (.id | type == "string") and
      (.id | length > 0) and
      (.remote.type | type == "string") and
      (.remote.path | type == "string") and
      (.paths.include | type == "array") and
      (.paths.exclude | type == "array") and
      (.retention.daily | type == "number") and
      (.retention.weekly | type == "number") and
      (.retention.monthly | type == "number")
    )
  ' "$CUSTOS_CONFIG" >/dev/null || die "Invalid config: $CUSTOS_CONFIG"
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

config_default_job_id() {
  config_ensure_exists
  jq -r '.defaultJob // .jobs[0].id' "$CUSTOS_CONFIG"
}

config_current_job_id() {
  if [[ -n "${CUSTOS_JOB:-}" ]]; then
    printf '%s\n' "$CUSTOS_JOB"
  else
    config_default_job_id
  fi
}

config_require_job() {
  local job_id="${1:-$(config_current_job_id)}"
  config_ensure_exists
  jq -e --arg job "$job_id" 'any(.jobs[]; .id == $job)' "$CUSTOS_CONFIG" >/dev/null ||
    die "Unknown job: $job_id"
  printf '%s\n' "$job_id"
}

config_job_get() {
  local query="$1" job_id
  job_id="$(config_require_job)"
  jq -er --arg job "$job_id" "(.jobs[] | select(.id == \$job)) | $query" "$CUSTOS_CONFIG"
}

config_job_get_optional() {
  local query="$1" job_id
  job_id="$(config_require_job)"
  jq -r --arg job "$job_id" "((.jobs[] | select(.id == \$job)) | $query) // empty" "$CUSTOS_CONFIG"
}

config_jobs_list() {
  config_ensure_exists
  jq -r '
    .defaultJob as $default
    | .jobs[]
    | [
        .id,
        (.name // .id),
        (.remote.name // "gdrive"),
        .remote.path,
        (if .id == $default then "default" else "" end)
      ]
      | @tsv
  ' "$CUSTOS_CONFIG"
}

config_job_set_default() {
  local job_id="$1" tmp_file
  config_require_job "$job_id" >/dev/null
  tmp_file="$(mktemp)"
  jq --arg job "$job_id" '.defaultJob = $job' "$CUSTOS_CONFIG" >"$tmp_file"
  mv "$tmp_file" "$CUSTOS_CONFIG"
}

config_parse_remote_ref() {
  local ref="$1" default_name="${2:-gdrive}"
  case "$ref" in
    rclone:*:*)
      ref="${ref#rclone:}"
      ;;
  esac
  if [[ "$ref" == *:* ]]; then
    CUSTOS_PARSED_REMOTE_NAME="${ref%%:*}"
    CUSTOS_PARSED_REMOTE_PATH="${ref#*:}"
  else
    CUSTOS_PARSED_REMOTE_NAME="$default_name"
    CUSTOS_PARSED_REMOTE_PATH="$ref"
  fi
  CUSTOS_PARSED_REMOTE_NAME="${CUSTOS_PARSED_REMOTE_NAME%:}"
  [[ -n "$CUSTOS_PARSED_REMOTE_NAME" ]] || CUSTOS_PARSED_REMOTE_NAME="gdrive"
}

config_job_add() {
  local job_id="$1" name="$2" source="$3" remote_ref="$4"
  local remote_name remote_path tmp_file

  [[ -n "$job_id" ]] || die "Job id cannot be empty"
  [[ "$job_id" =~ ^[A-Za-z0-9_-]+$ ]] || die "Job id may only contain letters, numbers, underscore, and dash"
  [[ -n "$source" ]] || die "Job source cannot be empty"
  [[ -n "$remote_ref" ]] || die "Job remote cannot be empty"

  config_ensure_exists
  if jq -e --arg job "$job_id" 'any(.jobs[]; .id == $job)' "$CUSTOS_CONFIG" >/dev/null; then
    die "Job already exists: $job_id"
  fi

  source="$(config_compact_home_path "$source")"
  config_parse_remote_ref "$remote_ref"
  remote_name="$CUSTOS_PARSED_REMOTE_NAME"
  remote_path="$CUSTOS_PARSED_REMOTE_PATH"
  [[ -n "$name" ]] || name="$job_id"

  tmp_file="$(mktemp)"
  jq \
    --arg id "$job_id" \
    --arg name "$name" \
    --arg source "$source" \
    --arg remote_name "$remote_name" \
    --arg remote_path "$remote_path" '
      .jobs += [{
        id: $id,
        name: $name,
        remote: {
          type: "google-drive",
          name: $remote_name,
          path: $remote_path
        },
        repository: {
          hostname: "auto"
        },
        paths: {
          include: [$source],
          exclude: []
        },
        retention: {
          daily: 7,
          weekly: 4,
          monthly: 6
        }
      }]
    ' "$CUSTOS_CONFIG" >"$tmp_file"
  mv "$tmp_file" "$CUSTOS_CONFIG"
}

config_job_remove() {
  local job_id="$1" tmp_file fallback
  config_require_job "$job_id" >/dev/null
  if [[ "$(jq '.jobs | length' "$CUSTOS_CONFIG")" == "1" ]]; then
    die "Cannot remove the only configured job"
  fi

  fallback="$(jq -r --arg job "$job_id" '.jobs[] | select(.id != $job) | .id' "$CUSTOS_CONFIG" | head -n 1)"
  tmp_file="$(mktemp)"
  jq --arg job "$job_id" --arg fallback "$fallback" '
    .jobs = [.jobs[] | select(.id != $job)]
    | if .defaultJob == $job then .defaultJob = $fallback else . end
  ' "$CUSTOS_CONFIG" >"$tmp_file"
  mv "$tmp_file" "$CUSTOS_CONFIG"
}

config_include_paths() {
  config_ensure_exists
  config_job_get '.paths.include[]' | while IFS= read -r path; do
    config_expand_path "$path"
  done
}

config_exclude_patterns() {
  local job_id
  config_ensure_exists
  job_id="$(config_require_job)"
  jq -r --arg job "$job_id" '(.jobs[] | select(.id == $job)) | .paths.exclude[]?' "$CUSTOS_CONFIG"
}

config_paths_list() {
  config_ensure_exists

  printf 'Job: %s\n' "$(config_current_job_id)"
  printf 'Include paths:\n'
  config_job_get '.paths.include[]? | "  - " + .' || true
  printf 'Exclude patterns:\n'
  config_job_get '.paths.exclude[]? | "  - " + .' || true
}

config_paths_add() {
  local kind="$1"
  local value="$2"
  local tmp_file job_id

  [[ "$kind" == "include" || "$kind" == "exclude" ]] || die "Path kind must be include or exclude"
  [[ -n "$value" ]] || die "Path value cannot be empty"

  value="$(config_compact_home_path "$value")"

  config_ensure_exists
  job_id="$(config_require_job)"
  tmp_file="$(mktemp)"

  jq --arg value "$value" --arg kind "$kind" --arg job "$job_id" '
    .jobs = (.jobs | map(if .id == $job then .paths[$kind] = ((.paths[$kind] + [$value]) | unique) else . end))
  ' "$CUSTOS_CONFIG" >"$tmp_file"
  mv "$tmp_file" "$CUSTOS_CONFIG"
}

config_paths_remove() {
  local kind="$1"
  local value="$2"
  local tmp_file job_id

  [[ "$kind" == "include" || "$kind" == "exclude" ]] || die "Path kind must be include or exclude"
  [[ -n "$value" ]] || die "Path value cannot be empty"

  value="$(config_compact_home_path "$value")"

  config_ensure_exists
  job_id="$(config_require_job)"
  tmp_file="$(mktemp)"

  jq --arg value "$value" --arg kind "$kind" --arg job "$job_id" '
    .jobs = (.jobs | map(if .id == $job then .paths[$kind] = (.paths[$kind] | map(select(. != $value))) else . end))
  ' "$CUSTOS_CONFIG" >"$tmp_file"
  mv "$tmp_file" "$CUSTOS_CONFIG"
}

config_password_command() {
  if [[ ! -f "$CUSTOS_CONFIG" ]]; then
    return 0
  fi

  config_get_optional '.secrets.passwordCommand'
}

config_hostname() {
  local configured
  configured="$(config_job_get_optional '.repository.hostname')"
  if [[ -z "$configured" || "$configured" == "auto" ]]; then
    hostname
  else
    printf '%s\n' "$configured"
  fi
}

config_retention_value() {
  local name="$1"
  config_job_get ".retention.$name"
}

config_repository_export_path() {
  local job_id
  job_id="$(config_current_job_id)"
  printf '%s/repository-config/%s%s\n' "$CUSTOS_STATE_DIR" "$job_id" "$CUSTOS_REPOSITORY_CONFIG_PATH"
}

config_export_for_repository() {
  config_ensure_exists

  local export_path export_dir
  export_path="$(config_repository_export_path)"
  export_dir="$(dirname -- "$export_path")"
  mkdir -p "$export_dir"

  jq '
    del(.secrets)
    | .metadata.custosExportedAt = now | .metadata.custosConfigPath = "'"$CUSTOS_CONFIG"'"
  ' "$CUSTOS_CONFIG" >"$export_path" || return 1

  printf '%s\n' "$export_path"
}
