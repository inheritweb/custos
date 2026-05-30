#!/usr/bin/env bash

status_show() {
  require_runtime_dependencies
  config_validate
  remote_load

  local repository
  repository="$(remote_repository_url)"

  printf 'Config: %s\n' "$OMARCHY_BACKUP_CONFIG"
  printf 'Repository: %s\n' "$repository"
  printf 'Remote type: %s\n' "$(config_get '.remote.type')"
  printf 'Hostname: %s\n' "$(config_hostname)"
  printf 'Protected paths:\n'
  config_include_paths | sed 's/^/  - /'

  local snapshots_json snapshot_count latest
  if snapshots_json="$(restic_run snapshots --json 2>/dev/null)"; then
    snapshot_count="$(jq 'length' <<<"$snapshots_json")"
    latest="$(jq -r 'sort_by(.time) | last | .time // "none"' <<<"$snapshots_json")"
    printf 'Snapshots: %s\n' "$snapshot_count"
    printf 'Latest snapshot: %s\n' "$latest"
    printf 'Status: reachable\n'
  else
    printf 'Snapshots: unavailable\n'
    printf 'Latest snapshot: unavailable\n'
    printf 'Status: unavailable\n'
    return 1
  fi
}
