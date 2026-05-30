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

for arg in "$@"; do
  if [[ "$arg" == "snapshots" ]]; then
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
    printf 'gdrive:\n'
    ;;
  mkdir|lsd)
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

printf 'ok: %s tests passed\n' "$pass_count"
