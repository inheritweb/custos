#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT_DIR/bin/omarchy-backup"
TMP_DIR="$(mktemp -d)"
FAKE_BIN="$TMP_DIR/bin"
RESTIC_LOG="$TMP_DIR/restic.log"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/restic" <<'SH'
#!/usr/bin/env bash
{
  printf 'RESTIC_PASSWORD=%s\n' "${RESTIC_PASSWORD-}"
  printf 'RESTIC_PASSWORD_COMMAND=%s\n' "${RESTIC_PASSWORD_COMMAND-}"
  printf 'ARGS:'
  printf ' %q' "$@"
  printf '\n'
} >>"${RESTIC_LOG:?}"

if [[ "${FAIL_RESTIC:-0}" == "1" ]]; then
  exit 12
fi

if [[ -n "${EXPECT_RESTIC_PASSWORD:-}" && "${RESTIC_PASSWORD-}" != "$EXPECT_RESTIC_PASSWORD" ]]; then
  printf 'Fatal: wrong password\n' >&2
  exit 12
fi

for arg in "$@"; do
  if [[ "$arg" == "backup" ]]; then
    if printf '%s\n' "$*" | grep -Fq -- '--dry-run'; then
      printf 'would add to the repository: 42 MiB (18 MiB stored)\n'
      printf 'processed 12 files, 42 MiB in 0:01\n'
    else
      printf 'Files:          12 new,     0 changed,     0 unmodified\n'
      printf 'Added to the repository: 18 MiB (42 MiB stored)\n'
    fi
    exit 0
  fi

  if [[ "$arg" == "snapshots" ]]; then
    if [[ "${RESTIC_REPOSITORY_MISSING:-0}" == "1" ]]; then
      printf 'Fatal: repository does not exist: unable to open config file: <config/> does not exist\n' >&2
      exit 12
    fi
    if [[ -n "${RESTIC_SNAPSHOTS_JSON:-}" ]]; then
      printf '%s\n' "$RESTIC_SNAPSHOTS_JSON"
      exit 0
    fi
    printf '[]\n'
    exit 0
  fi
done

exit 0
SH

cat >"$FAKE_BIN/rclone" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  listremotes)
    if [[ "${RCLONE_NO_REMOTES:-0}" == "1" ]]; then
      exit 0
    fi
    printf 'gdrive:\n'
    ;;
  mkdir|lsd)
    ;;
  lsf)
    if [[ "${RCLONE_REPOSITORY_CONFIG_MISSING:-0}" == "1" ]]; then
      exit 0
    fi
    printf 'config\n'
    ;;
  copyto)
    printf 'RCLONE_COPYTO: %q %q\n' "${2:-}" "${3:-}" >>"${RCLONE_LOG:?}"
    if [[ "${2:-}" == *":backups/home/.omarchy-backup/config.json" && -n "${RCLONE_FAKE_DOWNLOAD_CONFIG:-}" ]]; then
      cp "$RCLONE_FAKE_DOWNLOAD_CONFIG" "${3:-}"
    fi
    ;;
  config)
    if [[ "${2:-}" == "create" ]]; then
      printf 'token = should-not-leak-to-output\n'
      exit 0
    fi
    exit 1
    ;;
esac
SH

chmod +x "$FAKE_BIN/restic" "$FAKE_BIN/rclone"

export PATH="$FAKE_BIN:/usr/bin:/bin"
export RESTIC_LOG
export RCLONE_LOG="$TMP_DIR/rclone.log"
export OMARCHY_BACKUP_STATE_DIR="$TMP_DIR/state"

pass_count=0

run_test() {
  local name="$1"
  shift

  printf 'test: %s\n' "$name"
  "$@"
  pass_count=$((pass_count + 1))
}

assert_contains() {
  local file="$1"
  local expected="$2"

  if ! grep -Fq -- "$expected" "$file"; then
    printf 'Expected to find:\n%s\n\nIn file:\n%s\n\nActual content:\n' "$expected" "$file" >&2
    sed -n '1,220p' "$file" >&2
    return 1
  fi
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"

  if grep -Fq -- "$unexpected" "$file"; then
    printf 'Did not expect to find:\n%s\n\nIn file:\n%s\n\nActual content:\n' "$unexpected" "$file" >&2
    sed -n '1,220p' "$file" >&2
    return 1
  fi
}

make_config() {
  local config="$1"
  OMARCHY_BACKUP_CONFIG="$config" "$CLI" config show >/dev/null
}

test_default_config_has_no_password_command() {
  local config="$TMP_DIR/default-config.json"
  local output="$TMP_DIR/default-config.out"

  OMARCHY_BACKUP_CONFIG="$config" "$CLI" config show >"$output"

  assert_contains "$output" '"version": 1'
  assert_not_contains "$output" 'passwordCommand'
}

test_default_paths_are_project_neutral() {
  local config="$TMP_DIR/default-paths.json"
  local output="$TMP_DIR/default-paths.out"

  OMARCHY_BACKUP_CONFIG="$config" "$CLI" config show >"$output"

  assert_contains "$output" '"~/Documents"'
  assert_contains "$output" '"~/Pictures"'
  assert_contains "$output" '"**/*.iso"'
  assert_not_contains "$output" '"~/development"'
  assert_not_contains "$output" '"**/build"'
}

test_password_status_defaults_to_interactive() {
  local config="$TMP_DIR/password-status.json"
  local output="$TMP_DIR/password-status.out"

  make_config "$config"
  OMARCHY_BACKUP_CONFIG="$config" "$CLI" password status >"$output"

  assert_contains "$output" 'mode: interactive'
  assert_contains "$output" 'ask for the repository password when needed'
}

test_paths_commands_add_remove_and_dedupe() {
  local config="$TMP_DIR/paths.json"
  local output="$TMP_DIR/paths.out"

  make_config "$config"

  OMARCHY_BACKUP_CONFIG="$config" "$CLI" paths include add '~/Projects' >/dev/null
  OMARCHY_BACKUP_CONFIG="$config" "$CLI" paths include add '~/Projects' >/dev/null
  OMARCHY_BACKUP_CONFIG="$config" "$CLI" paths exclude add '**/coverage' >/dev/null
  OMARCHY_BACKUP_CONFIG="$config" "$CLI" paths list >"$output"

  assert_contains "$output" '  - ~/Projects'
  assert_contains "$output" '  - **/coverage'

  local include_count
  include_count="$(jq '[.paths.include[] | select(. == "~/Projects")] | length' "$config")"
  if [[ "$include_count" != "1" ]]; then
    printf 'Expected ~/Projects to appear once, got %s\n' "$include_count" >&2
    return 1
  fi

  OMARCHY_BACKUP_CONFIG="$config" "$CLI" paths include remove '~/Projects' >/dev/null
  OMARCHY_BACKUP_CONFIG="$config" "$CLI" paths exclude remove '**/coverage' >/dev/null
  OMARCHY_BACKUP_CONFIG="$config" "$CLI" paths list >"$output"

  assert_not_contains "$output" '  - ~/Projects'
  assert_not_contains "$output" '  - **/coverage'
}

test_paths_commands_compact_home_to_tilde() {
  local config="$TMP_DIR/paths-tilde.json"
  local output="$TMP_DIR/paths-tilde.out"

  make_config "$config"

  OMARCHY_BACKUP_CONFIG="$config" "$CLI" paths include add "$HOME/Projects" >/dev/null
  OMARCHY_BACKUP_CONFIG="$config" "$CLI" paths exclude add "$HOME/Projects/cache" >/dev/null
  OMARCHY_BACKUP_CONFIG="$config" "$CLI" paths list >"$output"

  assert_contains "$output" '  - ~/Projects'
  assert_contains "$output" '  - ~/Projects/cache'
  assert_not_contains "$output" "$HOME/Projects"

  OMARCHY_BACKUP_CONFIG="$config" "$CLI" paths include remove "$HOME/Projects" >/dev/null
  OMARCHY_BACKUP_CONFIG="$config" "$CLI" paths exclude remove "$HOME/Projects/cache" >/dev/null
  OMARCHY_BACKUP_CONFIG="$config" "$CLI" paths list >"$output"

  assert_not_contains "$output" '  - ~/Projects'
  assert_not_contains "$output" '  - ~/Projects/cache'
}

test_backup_dry_run_announces_interactive_password() {
  local config="$TMP_DIR/backup-dry-run.json"
  local output="$TMP_DIR/backup-dry-run.out"
  local existing_path="$TMP_DIR/existing-include"
  local missing_path="$TMP_DIR/missing-include"

  make_config "$config"
  mkdir -p "$existing_path"
  jq --arg existing "$existing_path" --arg missing "$missing_path" '
    .paths.include = [$existing, $missing]
  ' "$config" >"$TMP_DIR/backup-dry-run.next"
  mv "$TMP_DIR/backup-dry-run.next" "$config"

  OMARCHY_BACKUP_CONFIG="$config" OMARCHY_BACKUP_DRY_RUN=1 "$CLI" backup --dry-run >"$output" 2>&1

  assert_contains "$output" 'Repository password is not stored.'
  assert_contains "$output" "Skipping missing include path: $missing_path"
  assert_contains "$output" 'restic --repo rclone:gdrive:backups/home backup'
  assert_contains "$output" ' --host '
  assert_not_contains "$output" '--hostname'
  assert_not_contains "$output" "$missing_path --"
}

test_backup_uploads_config_bootstrap() {
  local config="$TMP_DIR/backup-config-bootstrap.json"
  local output="$TMP_DIR/backup-config-bootstrap.out"
  local existing_path="$TMP_DIR/config-bootstrap-include"

  make_config "$config"
  mkdir -p "$existing_path"
  jq --arg existing "$existing_path" '.paths.include = [$existing]' "$config" >"$TMP_DIR/backup-config-bootstrap.next"
  mv "$TMP_DIR/backup-config-bootstrap.next" "$config"
  : >"$RCLONE_LOG"

  OMARCHY_BACKUP_CONFIG="$config" OMARCHY_BACKUP_DRY_RUN=1 "$CLI" backup --dry-run >"$output" 2>&1

  assert_contains "$output" 'Dry run: would upload config to gdrive:backups/home/.omarchy-backup/config.json'
}

test_password_command_is_exported_to_backend() {
  local config="$TMP_DIR/password-command.json"
  local output="$TMP_DIR/password-command.out"

  make_config "$config"
  jq '.secrets.passwordCommand = "printf secret"' "$config" >"$TMP_DIR/password-command.next"
  mv "$TMP_DIR/password-command.next" "$config"
  : >"$RESTIC_LOG"

  OMARCHY_BACKUP_CONFIG="$config" "$CLI" snapshots >"$output" 2>&1

  assert_contains "$output" 'Using configured password command for repository access.'
  assert_contains "$RESTIC_LOG" 'RESTIC_PASSWORD_COMMAND=printf secret'
}

test_environment_password_is_used_for_tui_style_flow() {
  local config="$TMP_DIR/environment-password.json"
  local output="$TMP_DIR/environment-password.out"

  make_config "$config"
  : >"$RESTIC_LOG"

  RESTIC_PASSWORD='from-tui' OMARCHY_BACKUP_CONFIG="$config" "$CLI" snapshots >"$output" 2>&1

  assert_contains "$output" 'Using password supplied by the current environment.'
  assert_contains "$RESTIC_LOG" 'RESTIC_PASSWORD=from-tui'
}

test_failing_password_command_falls_back_to_interactive() {
  local config="$TMP_DIR/failing-password-command.json"
  local output="$TMP_DIR/failing-password-command.out"
  local pass_bin="$FAKE_BIN/pass"

  make_config "$config"
  jq '.secrets.passwordCommand = "pass show restic/omarchy-backup"' "$config" >"$TMP_DIR/failing-password-command.next"
  mv "$TMP_DIR/failing-password-command.next" "$config"

  cat >"$pass_bin" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$pass_bin"
  : >"$RESTIC_LOG"

  OMARCHY_BACKUP_CONFIG="$config" OMARCHY_BACKUP_DRY_RUN=1 "$CLI" snapshots >"$output" 2>&1

  assert_contains "$output" 'Configured backup password command did not return a password.'
  assert_contains "$output" 'Falling back to an interactive repository password prompt.'
  assert_contains "$output" 'restic --repo rclone:gdrive:backups/home snapshots'
  assert_not_contains "$output" 'RESTIC_PASSWORD_COMMAND'
}

test_backend_failure_gets_user_hint() {
  local config="$TMP_DIR/backend-failure.json"
  local output="$TMP_DIR/backend-failure.out"

  make_config "$config"

  if FAIL_RESTIC=1 RESTIC_PASSWORD=test OMARCHY_BACKUP_CONFIG="$config" "$CLI" snapshots >"$output" 2>&1; then
    printf 'Expected snapshots to fail\n' >&2
    return 1
  fi

  assert_contains "$output" 'Repository operation failed.'
  assert_contains "$output" 'check that it matches this repository'
}

test_config_restore_works_without_existing_config() {
  local source_config="$TMP_DIR/source-config.json"
  local restored_config="$TMP_DIR/restored-config.json"
  local output="$TMP_DIR/config-restore.out"

  make_config "$source_config"
  jq '.profile = "restored"' "$source_config" >"$TMP_DIR/source-config.next"
  mv "$TMP_DIR/source-config.next" "$source_config"

  RCLONE_FAKE_DOWNLOAD_CONFIG="$source_config" \
    OMARCHY_BACKUP_CONFIG="$restored_config" \
    "$CLI" config restore --repository rclone:gdrive:backups/home --yes >"$output" 2>&1

  assert_contains "$output" "Restored config to $restored_config"
  assert_contains "$restored_config" '"profile": "restored"'
}

test_missing_dependencies_use_noninteractive_omarchy_command() {
  local config="$TMP_DIR/missing-deps.json"
  local missing_deps_bin="$TMP_DIR/missing-deps-bin"
  local output="$TMP_DIR/missing-deps.out"

  mkdir -p "$missing_deps_bin"
  ln -s /usr/bin/bash "$missing_deps_bin/bash"
  ln -s /usr/bin/dirname "$missing_deps_bin/dirname"
  ln -s /usr/bin/pwd "$missing_deps_bin/pwd"
  ln -s /usr/bin/jq "$missing_deps_bin/jq"

  make_config "$config"

  if PATH="$missing_deps_bin" OMARCHY_BACKUP_CONFIG="$config" "$CLI" backup --dry-run >"$output" 2>&1; then
    printf 'Expected backup to fail with missing dependencies\n' >&2
    return 1
  fi

  assert_contains "$output" 'omarchy pkg add restic rclone'
  assert_not_contains "$output" 'omarchy pkg install'
}

test_remote_setup_suppresses_rclone_token_output() {
  local config="$TMP_DIR/remote-setup.json"
  local output="$TMP_DIR/remote-setup.out"
  local isolated_bin="$TMP_DIR/remote-setup-bin"

  mkdir -p "$isolated_bin"
  cp "$FAKE_BIN/restic" "$isolated_bin/restic"
  cp "$FAKE_BIN/rclone" "$isolated_bin/rclone"
  cat >"$isolated_bin/rclone" <<'SH'
#!/usr/bin/env bash
state_file="${RCLONE_FAKE_STATE:?}"
case "${1:-}" in
  listremotes)
    if [[ -f "$state_file" ]]; then
      printf 'gdrive:\n'
    fi
    exit 0
    ;;
  mkdir|lsd)
    ;;
  config)
    if [[ "${2:-}" == "create" ]]; then
      : >"$state_file"
      printf 'token = should-not-leak-to-output\n'
      exit 0
    fi
    exit 1
    ;;
esac
SH
  chmod +x "$isolated_bin/rclone"

  make_config "$config"

  RCLONE_FAKE_STATE="$TMP_DIR/remote-created" PATH="$isolated_bin:/usr/bin:/bin" OMARCHY_BACKUP_CONFIG="$config" "$CLI" remote setup >"$output" 2>&1

  assert_contains "$output" 'Creating Google Drive remote'
  assert_not_contains "$output" 'should-not-leak-to-output'
}

test_tui_first_run_exit_starts_cleanly() {
  local config="$TMP_DIR/tui-first-run.json"
  local output="$TMP_DIR/tui-first-run.out"

  if ! OMARCHY_BACKUP_TUI_PASSWORD="session-password" OMARCHY_BACKUP_TUI_KEYS="q" OMARCHY_BACKUP_CONFIG="$config" "$CLI" tui >"$output" 2>&1; then
    sed -n '1,220p' "$output" >&2
    return 1
  fi

  assert_contains "$output" "No local config found"
  assert_contains "$output" "Snapshots"
  assert_contains "$output" "Actions"
  assert_contains "$output" "Connect Google Drive"
}

test_tui_configured_exit_starts_cleanly() {
  local config="$TMP_DIR/tui-configured.json"
  local output="$TMP_DIR/tui-configured.out"

  make_config "$config"

  if ! OMARCHY_BACKUP_TUI_PASSWORD="session-password" OMARCHY_BACKUP_TUI_KEYS="q" OMARCHY_BACKUP_CONFIG="$config" "$CLI" tui >"$output" 2>&1; then
    sed -n '1,220p' "$output" >&2
    return 1
  fi

  assert_contains "$output" "Config"
  assert_contains "$output" "Snapshots"
  assert_contains "$output" "Actions"
  assert_contains "$output" "Remote"
  assert_contains "$output" "Connect repository"
  assert_not_contains "$output" "Repository Password"
  assert_not_contains "$output" "Snapshots loaded"
  assert_not_contains "$output" "Browse selected snapshot"
}

test_tui_missing_repository_does_not_prompt_for_password() {
  local config="$TMP_DIR/tui-missing-repo.json"
  local output="$TMP_DIR/tui-missing-repo.out"

  make_config "$config"

  if ! RCLONE_REPOSITORY_CONFIG_MISSING=1 RESTIC_REPOSITORY_MISSING=1 OMARCHY_BACKUP_TUI_KEYS="q" OMARCHY_BACKUP_CONFIG="$config" "$CLI" tui >"$output" 2>&1; then
    sed -n '1,260p' "$output" >&2
    return 1
  fi

  assert_contains "$output" "Repository is not initialized. Use Setup repository."
  assert_contains "$output" "Setup repository"
  assert_not_contains "$output" "Repository Password"
  assert_not_contains "$output" "Backup now"
}

test_tui_missing_remote_does_not_prompt_for_password() {
  local config="$TMP_DIR/tui-missing-remote.json"
  local output="$TMP_DIR/tui-missing-remote.out"

  make_config "$config"

  if ! RCLONE_NO_REMOTES=1 OMARCHY_BACKUP_TUI_KEYS="q" OMARCHY_BACKUP_CONFIG="$config" "$CLI" tui >"$output" 2>&1; then
    sed -n '1,260p' "$output" >&2
    return 1
  fi

  assert_contains "$output" "Google Drive is not connected. Use Connect Google Drive."
  assert_contains "$output" "Connect Google Drive"
  assert_not_contains "$output" "Repository Password"
  assert_not_contains "$output" "Backup now"
}

test_tui_setup_repository_confirms_and_reuses_password() {
  local config="$TMP_DIR/tui-setup-repository.json"
  local output="$TMP_DIR/tui-setup-repository.out"
  local snapshots

  make_config "$config"
  snapshots='[{"short_id":"abc12345","time":"2026-05-30T21:32:39+01:00","hostname":"vm","paths":["/home/test"]}]'

  if ! RCLONE_REPOSITORY_CONFIG_MISSING=1 RESTIC_SNAPSHOTS_JSON="$snapshots" OMARCHY_BACKUP_TUI_PASSWORD=$'new-password\nnew-password' OMARCHY_BACKUP_TUI_KEYS=$'\nq' OMARCHY_BACKUP_CONFIG="$config" "$CLI" tui >"$output" 2>&1; then
    sed -n '1,260p' "$output" >&2
    return 1
  fi

  assert_contains "$output" "New Repository Password"
  assert_contains "$output" "Confirm Repository Password"
  assert_contains "$output" "Initializing repository"
  assert_contains "$output" "Snapshots loaded"
  assert_contains "$RESTIC_LOG" "RESTIC_PASSWORD=new-password"
}

test_tui_down_navigation_does_not_exit() {
  local config="$TMP_DIR/tui-navigation.json"
  local output="$TMP_DIR/tui-navigation.out"

  make_config "$config"

  if ! OMARCHY_BACKUP_TUI_PASSWORD="session-password" OMARCHY_BACKUP_TUI_KEYS="jq" OMARCHY_BACKUP_CONFIG="$config" "$CLI" tui >"$output" 2>&1; then
    sed -n '1,220p' "$output" >&2
    return 1
  fi

  assert_contains "$output" "Connect repository"
  assert_not_contains "$output" "Repository operation failed"
}

test_tui_refresh_snapshots_ignores_status_stderr() {
  local config="$TMP_DIR/tui-refresh.json"
  local output="$TMP_DIR/tui-refresh.out"

  make_config "$config"

  if ! OMARCHY_BACKUP_TUI_PASSWORD="test-password" OMARCHY_BACKUP_TUI_KEYS="rq" OMARCHY_BACKUP_CONFIG="$config" "$CLI" tui >"$output" 2>&1; then
    sed -n '1,260p' "$output" >&2
    return 1
  fi

  assert_contains "$output" "Snapshots loaded"
  assert_contains "$output" "No snapshots found"
  assert_not_contains "$output" "jq: parse error"
}

test_tui_restore_config_shows_loading_state() {
  local source_config="$TMP_DIR/tui-restore-source.json"
  local target_config="$TMP_DIR/tui-restore-target.json"
  local output="$TMP_DIR/tui-restore-config.out"

  make_config "$source_config"

  if ! RCLONE_FAKE_DOWNLOAD_CONFIG="$source_config" OMARCHY_BACKUP_TUI_KEYS=$'j\nyq' OMARCHY_BACKUP_CONFIG="$target_config" "$CLI" tui >"$output" 2>&1; then
    sed -n '1,300p' "$output" >&2
    return 1
  fi

  assert_contains "$output" "Restoring config from remote"
  assert_contains "$output" "Config restored"
}

test_tui_snapshot_rows_are_readable_and_selectable() {
  local config="$TMP_DIR/tui-snapshot-rows.json"
  local output="$TMP_DIR/tui-snapshot-rows.out"
  local snapshots

  make_config "$config"
  snapshots='[
    {
      "short_id": "abcdef12",
      "time": "2026-05-30T10:58:39.632147495+01:00",
      "hostname": "omarchy-test-host",
      "paths": ["/home/test/Documents"]
    }
  ]'

  if ! RESTIC_SNAPSHOTS_JSON="$snapshots" OMARCHY_BACKUP_TUI_PASSWORD="test-password" OMARCHY_BACKUP_TUI_KEYS="rq" OMARCHY_BACKUP_CONFIG="$config" "$CLI" tui >"$output" 2>&1; then
    sed -n '1,300p' "$output" >&2
    return 1
  fi

  assert_contains "$output" "Created"
  assert_contains "$output" ">  abcdef12"
  assert_contains "$output" "2026-05-30 10:58:39 +01:00"
  assert_contains "$output" "Restore selected snapshot"
  assert_contains "$output" "Browse selected snapshot"
  assert_not_contains "$output" $'\033[38;5;208m'
}

test_tui_snapshot_header_is_orange_when_focused() {
  local config="$TMP_DIR/tui-snapshot-focused.json"
  local output="$TMP_DIR/tui-snapshot-focused.out"
  local snapshots

  make_config "$config"
  snapshots='[
    {
      "short_id": "fedcba98",
      "time": "2026-05-30T10:58:39+01:00",
      "hostname": "omarchy-test-host",
      "paths": ["/home/test/Documents"]
    }
  ]'

  if ! RESTIC_SNAPSHOTS_JSON="$snapshots" OMARCHY_BACKUP_TUI_PASSWORD="test-password" OMARCHY_BACKUP_TUI_KEYS=$'\n\tq' OMARCHY_BACKUP_CONFIG="$config" "$CLI" tui >"$output" 2>&1; then
    sed -n '1,300p' "$output" >&2
    return 1
  fi

  assert_contains "$output" $'\033[38;5;208m'
}

test_tui_session_password_bootstraps_snapshots() {
  local config="$TMP_DIR/tui-bootstrap-snapshots.json"
  local output="$TMP_DIR/tui-bootstrap-snapshots.out"
  local snapshots

  make_config "$config"
  snapshots='[
    {
      "short_id": "feedface",
      "time": "2026-05-31T09:12:13+01:00",
      "hostname": "omarchy-test-host",
      "paths": ["/home/test/Documents"]
    }
  ]'

  if ! RESTIC_SNAPSHOTS_JSON="$snapshots" OMARCHY_BACKUP_TUI_PASSWORD="test-password" OMARCHY_BACKUP_TUI_KEYS=$'\nq' OMARCHY_BACKUP_CONFIG="$config" "$CLI" tui >"$output" 2>&1; then
    sed -n '1,300p' "$output" >&2
    return 1
  fi

  assert_contains "$output" "Snapshots loaded"
  assert_contains "$output" ">  feedface"
  assert_contains "$output" "Restore selected snapshot"
}

test_tui_retries_until_session_password_works() {
  local config="$TMP_DIR/tui-password-retry.json"
  local output="$TMP_DIR/tui-password-retry.out"
  local snapshots

  make_config "$config"
  snapshots='[
    {
      "short_id": "1234abcd",
      "time": "2026-05-31T09:12:13+01:00",
      "hostname": "omarchy-test-host",
      "paths": ["/home/test/Documents"]
    }
  ]'

  if ! EXPECT_RESTIC_PASSWORD="right-password" RESTIC_SNAPSHOTS_JSON="$snapshots" OMARCHY_BACKUP_TUI_PASSWORD=$'wrong-password\nright-password' OMARCHY_BACKUP_TUI_KEYS=$'\nq' OMARCHY_BACKUP_CONFIG="$config" "$CLI" tui >"$output" 2>&1; then
    sed -n '1,360p' "$output" >&2
    return 1
  fi

  assert_contains "$output" "wrong password"
  assert_contains "$output" "Repository password did not work"
  assert_contains "$output" "Snapshots loaded"
  assert_contains "$output" ">  1234abcd"
}

test_tui_backup_shows_running_state_and_delta() {
  local config="$TMP_DIR/tui-backup.json"
  local output="$TMP_DIR/tui-backup.out"

  make_config "$config"

  if ! OMARCHY_BACKUP_TUI_PASSWORD="test-password" OMARCHY_BACKUP_TUI_KEYS=$'\n\nyyq' OMARCHY_BACKUP_CONFIG="$config" "$CLI" tui >"$output" 2>&1; then
    sed -n '1,420p' "$output" >&2
    return 1
  fi

  assert_contains "$output" "Running backup dry-run"
  assert_contains "$output" "would add to the repository: 42 MiB (18 MiB stored)"
  assert_contains "$output" "(processed 12 files, 42 MiB in 0:01)"
  assert_contains "$output" "Running backup"
  assert_contains "$output" "Backup complete; snapshots refreshed."
  assert_contains "$output" "Added to the repository: 18 MiB"
}

test_tui_missing_dependencies_use_omarchy_pkg_add() {
  local config="$TMP_DIR/tui-missing-deps.json"
  local tui_bin="$TMP_DIR/tui-missing-bin"
  local output="$TMP_DIR/tui-missing-deps.out"

  mkdir -p "$tui_bin"
  ln -s /usr/bin/bash "$tui_bin/bash"
  ln -s /usr/bin/dirname "$tui_bin/dirname"
  ln -s /usr/bin/pwd "$tui_bin/pwd"

  make_config "$config"

  if PATH="$tui_bin" OMARCHY_BACKUP_CONFIG="$config" "$CLI" tui >"$output" 2>&1; then
    printf 'Expected tui to fail with missing dependencies\n' >&2
    return 1
  fi

  assert_contains "$output" "Missing TUI dependencies"
  assert_contains "$output" "omarchy pkg add jq"
}

test_installer_installs_local_checkout_wrapper() {
  local install_dir="$TMP_DIR/install-root"
  local bin_dir="$TMP_DIR/install-bin"
  local output="$TMP_DIR/install.out"
  local config="$TMP_DIR/installed-config.json"

  OMARCHY_BACKUP_INSTALL_DIR="$install_dir" \
    OMARCHY_BACKUP_BIN_DIR="$bin_dir" \
    "$ROOT_DIR/scripts/install.sh" --no-deps >"$output" 2>&1

  if [[ ! -x "$bin_dir/omarchy-backup" ]]; then
    printf 'Expected installed wrapper at %s\n' "$bin_dir/omarchy-backup" >&2
    return 1
  fi

  OMARCHY_BACKUP_CONFIG="$config" "$bin_dir/omarchy-backup" config show >"$TMP_DIR/installed-config.out"

  assert_contains "$output" "Installed omarchy-backup"
  assert_contains "$TMP_DIR/installed-config.out" '"version": 1'
}

test_uninstall_removes_installed_files_config_and_state() {
  local install_dir="$TMP_DIR/uninstall-root"
  local bin_dir="$TMP_DIR/uninstall-bin"
  local config="$TMP_DIR/uninstall-config/config.json"
  local state_dir="$TMP_DIR/uninstall-state"
  local output="$TMP_DIR/uninstall.out"

  OMARCHY_BACKUP_INSTALL_DIR="$install_dir" \
    OMARCHY_BACKUP_BIN_DIR="$bin_dir" \
    "$ROOT_DIR/scripts/install.sh" --no-deps >"$TMP_DIR/uninstall-install.out" 2>&1

  mkdir -p "$(dirname -- "$config")" "$state_dir"
  printf '{"keep":true}\n' >"$config"
  printf 'state\n' >"$state_dir/keep"

  PATH="$bin_dir:$PATH" \
    OMARCHY_BACKUP_CONFIG="$config" \
    OMARCHY_BACKUP_STATE_DIR="$state_dir" \
    "$bin_dir/omarchy-backup" uninstall --yes >"$output" 2>&1

  if [[ -e "$bin_dir/omarchy-backup" ]]; then
    printf 'Expected wrapper to be removed\n' >&2
    return 1
  fi
  if [[ -e "$install_dir" ]]; then
    printf 'Expected install dir to be removed\n' >&2
    return 1
  fi
  if [[ -e "$config" || -e "$state_dir" ]]; then
    printf 'Expected config and state to be removed by default\n' >&2
    return 1
  fi

  assert_contains "$output" "Uninstalled omarchy-backup"
}

test_uninstall_can_keep_local_data() {
  local install_dir="$TMP_DIR/uninstall-keep-root"
  local bin_dir="$TMP_DIR/uninstall-keep-bin"
  local config="$TMP_DIR/uninstall-keep-config/config.json"
  local state_dir="$TMP_DIR/uninstall-keep-state"
  local output="$TMP_DIR/uninstall-keep.out"

  OMARCHY_BACKUP_INSTALL_DIR="$install_dir" \
    OMARCHY_BACKUP_BIN_DIR="$bin_dir" \
    "$ROOT_DIR/scripts/install.sh" --no-deps >"$TMP_DIR/uninstall-keep-install.out" 2>&1

  mkdir -p "$(dirname -- "$config")" "$state_dir"
  printf '{"keep":true}\n' >"$config"
  printf 'state\n' >"$state_dir/keep"

  PATH="$bin_dir:$PATH" \
    OMARCHY_BACKUP_CONFIG="$config" \
    OMARCHY_BACKUP_STATE_DIR="$state_dir" \
    "$bin_dir/omarchy-backup" uninstall --yes --keep-local-data >"$output" 2>&1

  if [[ ! -f "$config" || ! -f "$state_dir/keep" ]]; then
    printf 'Expected config and state to be kept with --keep-local-data\n' >&2
    return 1
  fi

  assert_contains "$output" "Local config and state will be kept"
}

test_uninstall_refuses_source_checkout() {
  local output="$TMP_DIR/uninstall-source.out"

  if "$CLI" uninstall --yes >"$output" 2>&1; then
    printf 'Expected source checkout uninstall to fail\n' >&2
    return 1
  fi

  assert_contains "$output" "Refusing to uninstall from a source checkout"
}

run_test "default config has no stored password command" test_default_config_has_no_password_command
run_test "default paths are project-neutral" test_default_paths_are_project_neutral
run_test "password status defaults to interactive" test_password_status_defaults_to_interactive
run_test "paths commands add remove and dedupe" test_paths_commands_add_remove_and_dedupe
run_test "paths commands compact home to tilde" test_paths_commands_compact_home_to_tilde
run_test "backup dry-run announces interactive password" test_backup_dry_run_announces_interactive_password
run_test "backup uploads config bootstrap" test_backup_uploads_config_bootstrap
run_test "configured password command is exported to backend" test_password_command_is_exported_to_backend
run_test "environment password supports TUI-style flow" test_environment_password_is_used_for_tui_style_flow
run_test "failing password command falls back to interactive prompt" test_failing_password_command_falls_back_to_interactive
run_test "backend failure gets a user-facing hint" test_backend_failure_gets_user_hint
run_test "config restore works without existing config" test_config_restore_works_without_existing_config
run_test "missing dependency guidance uses noninteractive Omarchy command" test_missing_dependencies_use_noninteractive_omarchy_command
run_test "remote setup suppresses rclone token output" test_remote_setup_suppresses_rclone_token_output
run_test "tui first-run exit starts cleanly" test_tui_first_run_exit_starts_cleanly
run_test "tui configured exit starts cleanly" test_tui_configured_exit_starts_cleanly
run_test "tui missing repository does not prompt for password" test_tui_missing_repository_does_not_prompt_for_password
run_test "tui missing remote does not prompt for password" test_tui_missing_remote_does_not_prompt_for_password
run_test "tui setup repository confirms and reuses password" test_tui_setup_repository_confirms_and_reuses_password
run_test "tui down navigation does not exit" test_tui_down_navigation_does_not_exit
run_test "tui refresh snapshots ignores status stderr" test_tui_refresh_snapshots_ignores_status_stderr
run_test "tui restore config shows loading state" test_tui_restore_config_shows_loading_state
run_test "tui snapshot rows are readable and selectable" test_tui_snapshot_rows_are_readable_and_selectable
run_test "tui snapshot header is orange when focused" test_tui_snapshot_header_is_orange_when_focused
run_test "tui session password bootstraps snapshots" test_tui_session_password_bootstraps_snapshots
run_test "tui retries until session password works" test_tui_retries_until_session_password_works
run_test "tui backup shows running state and delta" test_tui_backup_shows_running_state_and_delta
run_test "tui missing dependencies use omarchy pkg add" test_tui_missing_dependencies_use_omarchy_pkg_add
run_test "installer installs local checkout wrapper" test_installer_installs_local_checkout_wrapper
run_test "uninstall removes installed files config and state" test_uninstall_removes_installed_files_config_and_state
run_test "uninstall can keep local data" test_uninstall_can_keep_local_data
run_test "uninstall refuses source checkout" test_uninstall_refuses_source_checkout

printf 'ok: %s tests passed\n' "$pass_count"
