#!/usr/bin/env bash

TUI_WIDTH=100
TUI_MODE="repositories"
TUI_FOCUS="actions"
TUI_ACTION_INDEX=0
TUI_REPOSITORY_INDEX=0
TUI_SNAPSHOT_INDEX=0
TUI_PATH_KIND="include"
TUI_PATH_INCLUDE_INDEX=0
TUI_PATH_EXCLUDE_INDEX=0
TUI_STATUS="Ready"
TUI_LOG=""
TUI_SNAPSHOTS_JSON=""
TUI_SNAPSHOTS_TSV=""
TUI_SNAPSHOTS_LOADED=0
TUI_REPOSITORIES_TSV=""
TUI_REMOTE_READY="unknown"
TUI_REPOSITORY_READY="unknown"
TUI_KEY=""
TUI_PASSWORD_VALUE=""
TUI_SCREEN_ACTIVE=0
TUI_MODAL_ACTIVE=0
TUI_STTY_STATE=""
TUI_CLEANED_UP=0
TUI_COLOR_RESET=$'\033[0m'
TUI_COLOR_DIM=$'\033[2m'
TUI_COLOR_ITALIC=$'\033[3m'
TUI_COLOR_FOCUS=$'\033[38;5;154m'
TUI_COLOR_BORDER=$'\033[37m'
TUI_COLOR_HEADER=$'\033[1;38;5;208m'
TUI_COLOR_SELECTED=$'\033[7m'
TUI_COLOR_CONTROL=$'\033[38;5;51m'
TUI_PATH_PANEL_ROWS=9

tui_require_dependencies() {
  local -a missing=()
  local command_name

  for command_name in jq; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      missing+=("$command_name")
    fi
  done

  if ((${#missing[@]} > 0)); then
    log_error "Missing TUI dependencies: ${missing[*]}"
    log_info "Install them with:"
    log_info "  sudo pacman -S --needed ${missing[*]}"
    log_info "  sudo apt-get install ${missing[*]}"
    log_info "  sudo dnf install ${missing[*]}"
    exit 1
  fi
}

tui_cli() {
  "$CUSTOS_BIN" "$@"
}

tui_enter_screen() {
  TUI_CLEANED_UP=0

  if [[ -t 1 ]]; then
    printf '\033[?1049h\033[?25l\033[2J\033[H'
    TUI_SCREEN_ACTIVE=1
  fi

  if TUI_STTY_STATE="$({ stty -g </dev/tty; } 2>/dev/null)"; then
    stty -echo </dev/tty 2>/dev/null || true
  else
    TUI_STTY_STATE=""
  fi
}

tui_exit_screen() {
  [[ "$TUI_CLEANED_UP" == "0" ]] || return 0
  TUI_CLEANED_UP=1

  if [[ -n "$TUI_STTY_STATE" && -e /dev/tty ]]; then
    stty "$TUI_STTY_STATE" </dev/tty 2>/dev/null || stty sane </dev/tty 2>/dev/null || true
    TUI_STTY_STATE=""
  fi

  if [[ "$TUI_SCREEN_ACTIVE" == "1" ]]; then
    printf '\033[0m\033[?25h\033[?1049l'
    TUI_SCREEN_ACTIVE=0
  fi
}

tui_clear() {
  printf '\033[H'
}

tui_clear_line() {
  printf '\033[2K'
}

tui_config_exists() {
  [[ -f "$CUSTOS_CONFIG" ]]
}

tui_repeat() {
  local char="$1" count="$2"
  local i
  for ((i = 0; i < count; i++)); do
    printf '%s' "$char"
  done
}

tui_trim() {
  local value="$1" max="$2"
  if ((${#value} > max)); then
    printf '%s…' "${value:0:$((max - 1))}"
  else
    printf '%s' "$value"
  fi
}

tui_box_top() {
  local title="$1" focused="$2"
  local color="$TUI_COLOR_BORDER"
  [[ "$focused" == "1" ]] && color="$TUI_COLOR_FOCUS"

  local title_text=" $title "
  local fill=$((TUI_WIDTH - ${#title_text} - 2))
  tui_clear_line
  printf '%s┌%s%s%s┐%s\n' "$color" "$title_text" "$(tui_repeat "─" "$fill")" "$TUI_COLOR_RESET" "$TUI_COLOR_RESET"
}

tui_box_bottom() {
  local focused="$1"
  local color="$TUI_COLOR_BORDER"
  [[ "$focused" == "1" ]] && color="$TUI_COLOR_FOCUS"
  tui_clear_line
  printf '%s└%s┘%s\n' "$color" "$(tui_repeat "─" "$((TUI_WIDTH - 2))")" "$TUI_COLOR_RESET"
}

tui_box_line() {
  local text="$1" focused="$2"
  local color="$TUI_COLOR_BORDER"
  [[ "$focused" == "1" ]] && color="$TUI_COLOR_FOCUS"

  local inner_width=$((TUI_WIDTH - 4))
  text="$(tui_trim "$text" "$inner_width")"
  tui_clear_line
  printf '%s│%s %-*s %s│%s\n' "$color" "$TUI_COLOR_RESET" "$inner_width" "$text" "$color" "$TUI_COLOR_RESET"
}

tui_box_colored_line() {
  local text="$1" focused="$2" text_color="$3"
  local color="$TUI_COLOR_BORDER"
  [[ "$focused" == "1" ]] && color="$TUI_COLOR_FOCUS"

  local inner_width=$((TUI_WIDTH - 4))
  text="$(tui_trim "$text" "$inner_width")"
  tui_clear_line
  printf '%s│%s %s%-*s%s %s│%s\n' "$color" "$TUI_COLOR_RESET" "$text_color" "$inner_width" "$text" "$TUI_COLOR_RESET" "$color" "$TUI_COLOR_RESET"
}

tui_box_blank_lines() {
  local count="$1" focused="$2"
  local i
  for ((i = 0; i < count; i++)); do
    tui_box_line "" "$focused"
  done
}

tui_modal() {
  local title="$1"
  shift
  local message="$*"
  tui_clear_line
  printf '\n'
  tui_box_top "$title" 1
  while IFS= read -r line; do
    tui_box_line "$line" 1
  done <<<"$message"
  tui_box_bottom 1
}

tui_render_modal() {
  local title="$1"
  shift
  TUI_MODAL_ACTIVE=1
  tui_render
  TUI_MODAL_ACTIVE=0
  tui_modal "$title" "$@"
}

tui_render_loading() {
  local message="$1" frame="$2"
  tui_render_modal "Loading" "$message  $frame"
}

tui_has_selected_snapshot() {
  [[ -n "$TUI_SNAPSHOTS_TSV" ]]
}

tui_load_repositories() {
  if ! tui_config_exists; then
    TUI_REPOSITORIES_TSV=""
    return 0
  fi
  TUI_REPOSITORIES_TSV="$(config_jobs_list)"
}

tui_selected_repository() {
  tui_load_repositories
  [[ -n "$TUI_REPOSITORIES_TSV" ]] || return 1
  sed -n "$((TUI_REPOSITORY_INDEX + 1))p" <<<"$TUI_REPOSITORIES_TSV" | awk -F'\t' '{ print $1 }'
}

tui_select_repository() {
  local job_id="$1"
  export CUSTOS_JOB="$job_id"
  TUI_REMOTE_READY="unknown"
  TUI_REPOSITORY_READY="unknown"
  TUI_SNAPSHOTS_JSON=""
  TUI_SNAPSHOTS_TSV=""
  TUI_SNAPSHOTS_LOADED=0
}

tui_path_values() {
  local kind="$1"
  tui_config_exists || return 0
  config_job_get ".paths.$kind[]?" || true
}

tui_path_count() {
  local kind="$1"
  tui_config_exists || {
    printf '0'
    return 0
  }
  config_job_get ".paths.$kind | length"
}

tui_path_index() {
  case "$1" in
    include) printf '%s' "$TUI_PATH_INCLUDE_INDEX" ;;
    exclude) printf '%s' "$TUI_PATH_EXCLUDE_INDEX" ;;
  esac
}

tui_set_path_index() {
  local kind="$1" value="$2"
  case "$kind" in
    include) TUI_PATH_INCLUDE_INDEX="$value" ;;
    exclude) TUI_PATH_EXCLUDE_INDEX="$value" ;;
  esac
}

tui_clamp_path_index() {
  local kind="$1" count index
  count="$(tui_path_count "$kind")"
  index="$(tui_path_index "$kind")"
  ((count <= 0)) && {
    tui_set_path_index "$kind" 0
    return 0
  }
  ((index < 0)) && index=0
  ((index >= count)) && index=$((count - 1))
  tui_set_path_index "$kind" "$index"
}

tui_selected_path() {
  local kind="$TUI_PATH_KIND" index
  tui_clamp_path_index "$kind"
  index="$(tui_path_index "$kind")"
  tui_path_values "$kind" | sed -n "$((index + 1))p"
}

tui_read_key() {
  TUI_KEY=""
  if [[ -n "${CUSTOS_TUI_KEYS:-}" ]]; then
    TUI_KEY="${CUSTOS_TUI_KEYS:0:1}"
    CUSTOS_TUI_KEYS="${CUSTOS_TUI_KEYS:1}"
    return 0
  fi

  local key
  IFS= read -rsn1 key </dev/tty || return 1
  if [[ "$key" == $'\033' ]]; then
    local rest
    IFS= read -rsn2 -t 0.1 rest </dev/tty || true
    key+="$rest"
  fi
  TUI_KEY="$key"
}

tui_read_line() {
  local prompt="$1"
  local value=""
  if [[ -n "${CUSTOS_TUI_INPUT:-}" ]]; then
    value="$CUSTOS_TUI_INPUT"
    CUSTOS_TUI_INPUT=""
    printf '%s' "$value"
    return 0
  fi

  printf '%s' "$prompt" >/dev/tty
  IFS= read -r value </dev/tty || return 1
  printf '%s' "$value"
}

tui_read_password() {
  local prompt="$1"
  TUI_PASSWORD_VALUE=""
  if [[ -n "${CUSTOS_TUI_PASSWORD:-}" ]]; then
    if [[ "$CUSTOS_TUI_PASSWORD" == *$'\n'* ]]; then
      TUI_PASSWORD_VALUE="${CUSTOS_TUI_PASSWORD%%$'\n'*}"
      CUSTOS_TUI_PASSWORD="${CUSTOS_TUI_PASSWORD#*$'\n'}"
    else
      TUI_PASSWORD_VALUE="$CUSTOS_TUI_PASSWORD"
      CUSTOS_TUI_PASSWORD=""
    fi
    return 0
  fi

  printf '%s' "$prompt" >/dev/tty
  IFS= read -rs TUI_PASSWORD_VALUE </dev/tty || return 1
  printf '\n' >/dev/tty
}

tui_confirm() {
  local message="$1"
  local answer
  tui_render_modal "Confirm" "$message"$'\n\n'"Press y to confirm, any other key to cancel."
  tui_read_key || true
  answer="$TUI_KEY"
  [[ "$answer" == "y" || "$answer" == "Y" ]]
}

tui_config_summary_lines() {
  if ! tui_config_exists; then
    cat <<'SUMMARY'
No local config found
Remote not connected for custos yet
Use actions below to connect Google Drive or restore/create config
SUMMARY
    return 0
  fi

  local profile job_id job_name remote_type remote_name remote_path include_count exclude_count
  profile="$(jq -r '.profile // "default"' "$CUSTOS_CONFIG")"
  job_id="$(config_current_job_id)"
  job_name="$(config_job_get_optional '.name')"
  remote_type="$(config_job_get_optional '.remote.type')"
  remote_name="$(config_job_get_optional '.remote.name')"
  remote_path="$(config_job_get_optional '.remote.path')"
  include_count="$(config_job_get '.paths.include | length')"
  exclude_count="$(config_job_get '.paths.exclude | length')"

  cat <<SUMMARY
Profile      $profile
Job          $job_name ($job_id)
Remote       $remote_type / ${remote_name}:${remote_path}
Includes     $include_count paths
Excludes     $exclude_count patterns
Config       $CUSTOS_CONFIG
SUMMARY
}

tui_actions() {
  if [[ "$TUI_MODE" == "repositories" ]] && tui_config_exists; then
    cat <<'ACTIONS'
Connect selected repository
Add repository
Restore config from remote
Doctor
Quit
ACTIONS
    return 0
  fi

  if [[ "$TUI_MODE" == "paths" ]]; then
    cat <<'ACTIONS'
Add include
Add exclude
Remove selected path
Back to snapshots
Quit
ACTIONS
    return 0
  fi

  if ! tui_config_exists; then
    cat <<'ACTIONS'
Connect Google Drive
Restore config from remote
Create new config
Doctor
Quit
ACTIONS
    return 0
  fi

  if [[ "$TUI_REMOTE_READY" == "0" ]]; then
    cat <<'ACTIONS'
Connect Google Drive
Restore config from remote
Doctor
Quit
ACTIONS
    return 0
  fi

  if [[ "$TUI_REPOSITORY_READY" == "0" ]]; then
    cat <<'ACTIONS'
Setup repository
Restore config from remote
Doctor
Quit
ACTIONS
    return 0
  fi

  if [[ "$TUI_SNAPSHOTS_LOADED" != "1" ]]; then
    cat <<'ACTIONS'
Connect repository
Restore config from remote
Doctor
Quit
ACTIONS
    return 0
  fi

  printf '%s\n' "Backup now"
  if tui_has_selected_snapshot; then
    printf '%s\n' "Restore selected snapshot"
    printf '%s\n' "Browse selected snapshot"
  fi
  cat <<'ACTIONS'
Back to repositories
Refresh snapshots
Manage paths
Check repository
Setup repository
Prune repository
Unlock stale locks
Restore config from remote
Quit
ACTIONS
}

tui_load_actions() {
  mapfile -t TUI_ACTIONS < <(tui_actions)
  if ((${#TUI_ACTIONS[@]} == 0)); then
    TUI_ACTIONS=("Quit")
  fi
  if ((TUI_ACTION_INDEX >= ${#TUI_ACTIONS[@]})); then
    TUI_ACTION_INDEX=$((${#TUI_ACTIONS[@]} - 1))
  fi
}

tui_render_config() {
  local focused=0
  [[ "$TUI_MODAL_ACTIVE" != "1" && "$TUI_FOCUS" == "config" ]] && focused=1
  tui_box_top "Config" "$focused"
  while IFS= read -r line; do
    tui_box_line "$line" "$focused"
  done < <(tui_config_summary_lines)
  tui_box_blank_lines 1 "$focused"
  tui_box_bottom "$focused"
}

tui_snapshot_lines() {
  if ! tui_config_exists; then
    cat <<'SNAPS'
No config yet
Connect Google Drive, then restore or create config
SNAPS
    return 0
  fi

  if [[ "$TUI_SNAPSHOTS_LOADED" != "1" ]]; then
    cat <<'SNAPS'
Snapshots not loaded
Use "Refresh snapshots" after repository setup
SNAPS
    return 0
  fi

  if [[ -z "$TUI_SNAPSHOTS_TSV" ]]; then
    cat <<'SNAPS'
No snapshots found
Run a backup to create the first snapshot
SNAPS
    return 0
  fi

  printf '%-2s %-10s %-32s %-16s %s\n' "" "ID" "Created" "Host" "Paths"
  local i=0 line id time host paths display marker
  while IFS=$'\t' read -r id time host paths; do
    marker=" "
    [[ "$i" == "$TUI_SNAPSHOT_INDEX" ]] && marker=">"
    display="$(printf '%-2s %-10s %-32s %-16s %s' "$marker" "$id" "$(tui_trim "$time" 32)" "$host" "$paths")"
    printf '%s\n' "$display"
    i=$((i + 1))
  done <<<"$TUI_SNAPSHOTS_TSV"
}

tui_render_snapshots() {
  local focused=0 count=0
  [[ "$TUI_MODAL_ACTIVE" != "1" && "$TUI_FOCUS" == "snapshots" ]] && focused=1
  tui_box_top "Snapshots" "$focused"
  while IFS= read -r line; do
    if [[ "$focused" == "1" && "$TUI_SNAPSHOTS_LOADED" == "1" && -n "$TUI_SNAPSHOTS_TSV" && "$count" == "0" ]]; then
      tui_box_colored_line "$line" "$focused" "$TUI_COLOR_HEADER"
    elif [[ "$TUI_MODAL_ACTIVE" != "1" && "$TUI_FOCUS" == "snapshots" && "$line" == "> "* ]]; then
      tui_box_colored_line "$line" "$focused" "$TUI_COLOR_SELECTED"
    else
      tui_box_line "$line" "$focused"
    fi
    count=$((count + 1))
    ((count >= 8)) && break
  done < <(tui_snapshot_lines)
  ((count < 8)) && tui_box_blank_lines $((8 - count)) "$focused"
  tui_box_bottom "$focused"
}

tui_repository_lines() {
  if ! tui_config_exists; then
    cat <<'REPOS'
No config yet
Connect Google Drive, then restore or create config
REPOS
    return 0
  fi

  tui_load_repositories
  if [[ -z "$TUI_REPOSITORIES_TSV" ]]; then
    cat <<'REPOS'
No repositories configured
Add a repository to start backing up
REPOS
    return 0
  fi

  printf '%-2s %-16s %-22s %-12s %s\n' "" "ID" "Name" "Remote" "Path"
  local i=0 id name remote path default marker display
  while IFS=$'\t' read -r id name remote path default; do
    marker=" "
    [[ "$i" == "$TUI_REPOSITORY_INDEX" ]] && marker=">"
    [[ "$default" == "default" ]] && name="$name *"
    display="$(printf '%-2s %-16s %-22s %-12s %s' "$marker" "$id" "$(tui_trim "$name" 22)" "$remote" "$path")"
    printf '%s\n' "$display"
    i=$((i + 1))
  done <<<"$TUI_REPOSITORIES_TSV"
}

tui_render_repositories() {
  local focused=0 count=0
  [[ "$TUI_MODAL_ACTIVE" != "1" && "$TUI_FOCUS" == "repositories" ]] && focused=1
  tui_box_top "Repositories" "$focused"
  while IFS= read -r line; do
    if [[ "$focused" == "1" && "$count" == "0" && -n "$TUI_REPOSITORIES_TSV" ]]; then
      tui_box_colored_line "$line" "$focused" "$TUI_COLOR_HEADER"
    elif [[ "$focused" == "1" && "$line" == "> "* ]]; then
      tui_box_colored_line "$line" "$focused" "$TUI_COLOR_SELECTED"
    else
      tui_box_line "$line" "$focused"
    fi
    count=$((count + 1))
    ((count >= 8)) && break
  done < <(tui_repository_lines)
  ((count < 8)) && tui_box_blank_lines $((8 - count)) "$focused"
  tui_box_bottom "$focused"
}

tui_path_panel_width() {
  printf '%s' 49
}

tui_path_panel_inner_width() {
  printf '%s' 45
}

tui_path_panel_page_size() {
  printf '%s' $((TUI_PATH_PANEL_ROWS * 2))
}

tui_path_panel_color() {
  local kind="$1"
  if [[ "$TUI_MODAL_ACTIVE" != "1" && "$TUI_FOCUS" == "paths" && "$TUI_PATH_KIND" == "$kind" ]]; then
    printf '%s' "$TUI_COLOR_FOCUS"
  else
    printf '%s' "$TUI_COLOR_BORDER"
  fi
}

tui_path_panel_top_segment() {
  local title="$1" kind="$2"
  local width title_text fill color
  width="$(tui_path_panel_width)"
  title_text=" $title "
  fill=$((width - ${#title_text} - 2))
  color="$(tui_path_panel_color "$kind")"
  printf '%s┌%s%s┐%s' "$color" "$title_text" "$(tui_repeat "─" "$fill")" "$TUI_COLOR_RESET"
}

tui_path_panel_bottom_segment() {
  local kind="$1" width color
  width="$(tui_path_panel_width)"
  color="$(tui_path_panel_color "$kind")"
  printf '%s└%s┘%s' "$color" "$(tui_repeat "─" "$((width - 2))")" "$TUI_COLOR_RESET"
}

tui_path_cell_for_index() {
  local kind="$1" item_index="$2" value marker selected
  local index count

  count="$(tui_path_count "$kind")"
  index="$(tui_path_index "$kind")"

  if ((item_index >= count)); then
    value=""
  else
    value="$(tui_path_values "$kind" | sed -n "$((item_index + 1))p")"
  fi

  marker=" "
  selected=0
  if [[ "$TUI_FOCUS" == "paths" && "$kind" == "$TUI_PATH_KIND" && "$item_index" == "$index" && "$count" != "0" ]]; then
    marker=">"
    selected=1
  fi

  TUI_PATH_CELL_SELECTED="$selected"
  TUI_PATH_CELL_MARKER="$marker"
  TUI_PATH_CELL_VALUE="$(tui_trim "$value" 20)"
}

tui_path_panel_line_segment() {
  local kind="$1" row="$2" count index page_size start left_index right_index color
  local left_selected left_marker left_value right_selected right_marker right_value left_content right_content
  color="$(tui_path_panel_color "$kind")"
  count="$(tui_path_count "$kind")"
  index="$(tui_path_index "$kind")"
  page_size="$(tui_path_panel_page_size)"
  start=$(((index / page_size) * page_size))

  left_index=$((start + row))
  right_index=$((start + TUI_PATH_PANEL_ROWS + row))

  if ((row == 0 && count == 0)); then
    left_selected=0
    left_marker=" "
    left_value="No ${kind} paths"
    right_selected=0
    right_marker=" "
    right_value=""
  else
    tui_path_cell_for_index "$kind" "$left_index"
    left_selected="$TUI_PATH_CELL_SELECTED"
    left_marker="$TUI_PATH_CELL_MARKER"
    left_value="$TUI_PATH_CELL_VALUE"
    tui_path_cell_for_index "$kind" "$right_index"
    right_selected="$TUI_PATH_CELL_SELECTED"
    right_marker="$TUI_PATH_CELL_MARKER"
    right_value="$TUI_PATH_CELL_VALUE"
  fi

  left_content="$(printf '%s %-20s' "$left_marker" "$left_value")"
  right_content="$(printf '%s %-20s' "$right_marker" "$right_value")"

  printf '%s│%s ' "$color" "$TUI_COLOR_RESET"
  if [[ "$left_selected" == "1" ]]; then
    printf '%s%-22s%s' "$TUI_COLOR_SELECTED" "$left_content" "$TUI_COLOR_RESET"
  else
    printf '%-22s' "$left_content"
  fi
  printf ' '
  if [[ "$right_selected" == "1" ]]; then
    printf '%s%-22s%s' "$TUI_COLOR_SELECTED" "$right_content" "$TUI_COLOR_RESET"
  else
    printf '%-22s' "$right_content"
  fi
  printf ' %s│%s' "$color" "$TUI_COLOR_RESET"
}

tui_render_paths() {
  local row

  tui_clamp_path_index include
  tui_clamp_path_index exclude

  tui_clear_line
  tui_path_panel_top_segment "Include paths" include
  printf '  '
  tui_path_panel_top_segment "Exclude paths" exclude
  printf '\n'

  for ((row = 0; row < TUI_PATH_PANEL_ROWS; row++)); do
    tui_clear_line
    tui_path_panel_line_segment include "$row"
    printf '  '
    tui_path_panel_line_segment exclude "$row"
    printf '\n'
  done

  tui_clear_line
  tui_path_panel_bottom_segment include
  printf '  '
  tui_path_panel_bottom_segment exclude
  printf '\n'
}

tui_render_middle_pane() {
  case "$TUI_MODE" in
    paths) tui_render_paths ;;
    repositories) tui_render_repositories ;;
    *) tui_render_snapshots ;;
  esac
}

tui_render_actions() {
  local focused=0 i
  [[ "$TUI_MODAL_ACTIVE" != "1" && "$TUI_FOCUS" == "actions" ]] && focused=1
  tui_load_actions
  tui_box_top "Actions" "$focused"
  for i in "${!TUI_ACTIONS[@]}"; do
    local line="  ${TUI_ACTIONS[$i]}"
    if [[ "$TUI_MODAL_ACTIVE" != "1" && "$TUI_FOCUS" == "actions" && "$i" == "$TUI_ACTION_INDEX" ]]; then
      line="> ${TUI_ACTIONS[$i]}"
      tui_box_colored_line "$line" "$focused" "$TUI_COLOR_SELECTED"
    else
      tui_box_line "$line" "$focused"
    fi
    ((i >= 11)) && break
  done
  if ((${#TUI_ACTIONS[@]} < 12)); then
    tui_box_blank_lines $((12 - ${#TUI_ACTIONS[@]})) "$focused"
  fi
  tui_box_bottom "$focused"
}

tui_render_status() {
  local count=0
  if [[ -n "$TUI_LOG" ]]; then
    while IFS= read -r line; do
      tui_clear_line
      printf '%s\n' "$(tui_trim "$line" "$TUI_WIDTH")"
      count=$((count + 1))
      ((count >= 3)) && break
    done < <(tail -n 3 <<<"$TUI_LOG")
  fi
  tui_clear_line
  printf '%sLast action:%s %s\n' "$TUI_COLOR_CONTROL" "$TUI_COLOR_RESET" "$(tui_trim "$TUI_STATUS" "$((TUI_WIDTH - 13))")"
  tui_clear_line
  if [[ "$TUI_MODE" == "paths" ]]; then
    printf '%sTab%s focus  %s↑/↓%s move  %s←/→%s column  %sEnter%s remove  %sq%s quit%s\n' \
      "$TUI_COLOR_CONTROL" "$TUI_COLOR_RESET" \
      "$TUI_COLOR_CONTROL" "$TUI_COLOR_RESET" \
      "$TUI_COLOR_CONTROL" "$TUI_COLOR_RESET" \
      "$TUI_COLOR_CONTROL" "$TUI_COLOR_RESET" \
      "$TUI_COLOR_CONTROL" "$TUI_COLOR_RESET" "$TUI_COLOR_RESET"
  else
    printf '%sTab%s focus  %s↑/↓%s move in focused pane  %sEnter%s select  %sr%s refresh  %sq%s quit%s\n' \
      "$TUI_COLOR_CONTROL" "$TUI_COLOR_RESET" \
      "$TUI_COLOR_CONTROL" "$TUI_COLOR_RESET" \
      "$TUI_COLOR_CONTROL" "$TUI_COLOR_RESET" \
      "$TUI_COLOR_CONTROL" "$TUI_COLOR_RESET" \
      "$TUI_COLOR_CONTROL" "$TUI_COLOR_RESET" "$TUI_COLOR_RESET"
  fi
}

tui_render_title() {
  tui_clear_line
  printf '%s%s   ______           __             %s\n' "$TUI_COLOR_ITALIC" "$TUI_COLOR_FOCUS" "$TUI_COLOR_RESET"
  tui_clear_line
  printf '%s%s  / ____/_  _______/ /_____  _____%s\n' "$TUI_COLOR_ITALIC" "$TUI_COLOR_FOCUS" "$TUI_COLOR_RESET"
  tui_clear_line
  printf '%s%s / /   / / / / ___/ __/ __ \\/ ___/%s\n' "$TUI_COLOR_ITALIC" "$TUI_COLOR_FOCUS" "$TUI_COLOR_RESET"
  tui_clear_line
  printf '%s%s/ /___/ /_/ (__  ) /_/ /_/ (__  ) %s\n' "$TUI_COLOR_ITALIC" "$TUI_COLOR_FOCUS" "$TUI_COLOR_RESET"
  tui_clear_line
  printf '%s%s\\____/\\__,_/____/\\__/\\____/____/  %s\n' "$TUI_COLOR_ITALIC" "$TUI_COLOR_FOCUS" "$TUI_COLOR_RESET"
}

tui_render_frame() {
  tui_clear
  tui_render_title
  tui_clear_line
  printf '\n'
  tui_render_config
  tui_clear_line
  printf '\n'
  tui_render_middle_pane
  tui_clear_line
  printf '\n'
  tui_render_actions
  tui_clear_line
  printf '\n'
  tui_render_status
  printf '\033[J'
}

tui_render() {
  local frame
  frame="$(tui_render_frame)"
  printf '\033[?2026h%s\033[?2026l' "$frame"
}

tui_password_command_available() {
  local status_output mode available

  if [[ -n "${RESTIC_PASSWORD:-}" ]]; then
    return 0
  fi

  status_output="$(tui_cli password status 2>/dev/null || true)"
  mode="$(awk -F': ' '/^mode:/ { print $2; exit }' <<<"$status_output")"
  available="$(awk -F': ' '/^available:/ { print $2; exit }' <<<"$status_output")"

  if [[ "$mode" == "command" && "$available" != "no" ]]; then
    return 0
  fi

  return 1
}

tui_probe_remote_state() {
  local remote_type remote_name

  tui_config_exists || return 0

  remote_type="$(config_job_get_optional '.remote.type')"
  remote_name="$(config_job_get_optional '.remote.name' | sed 's/:$//')"
  [[ -n "$remote_name" ]] || remote_name="gdrive"

  if [[ "$remote_type" != "google-drive" ]]; then
    TUI_REMOTE_READY="1"
    return 0
  fi

  if ! command -v rclone >/dev/null 2>&1; then
    TUI_REMOTE_READY="0"
    TUI_STATUS="rclone is not installed. Use Doctor for details."
    return 0
  fi

  if rclone listremotes 2>/dev/null | grep -Fxq "${remote_name}:"; then
    TUI_REMOTE_READY="1"
    return 0
  fi

  TUI_REMOTE_READY="0"
  TUI_REPOSITORY_READY="0"
  TUI_STATUS="Google Drive is not connected. Use Connect Google Drive."
}

tui_repository_config_exists() {
  local remote_type remote_name remote_path

  tui_config_exists || return 1

  remote_type="$(config_job_get_optional '.remote.type')"
  if [[ "$remote_type" != "google-drive" ]]; then
    return 0
  fi

  remote_name="$(config_job_get_optional '.remote.name' | sed 's/:$//')"
  remote_path="$(config_job_get_optional '.remote.path')"
  [[ -n "$remote_name" ]] || remote_name="gdrive"

  rclone lsf "${remote_name}:${remote_path}" --files-only 2>/dev/null | grep -Fxq "config"
}

tui_probe_repository_state() {
  tui_config_exists || return 0
  [[ "$TUI_REMOTE_READY" != "0" ]] || return 0

  if ! tui_repository_config_exists; then
    TUI_REPOSITORY_READY="0"
    TUI_STATUS="Repository is not initialized. Use Setup repository."
    return 0
  fi

  TUI_REPOSITORY_READY="1"
  TUI_STATUS="Repository is configured. Use Connect repository."
}

tui_prompt_session_password() {
  local message="${1:-Enter the repository password for this TUI session.}"

  tui_config_exists || return 0
  tui_password_command_available && return 0

  TUI_STATUS="Waiting for repository password"
  tui_render_modal "Repository Password" "$message"$'\n\n'"This password is kept only in this running TUI."
  tui_read_password "Password> " || return 1
  if [[ -z "$TUI_PASSWORD_VALUE" ]]; then
    TUI_STATUS="Repository password not set"
    return 1
  fi
  export RESTIC_PASSWORD="$TUI_PASSWORD_VALUE"
  TUI_STATUS="Repository password set for this session"
}

tui_prompt_new_repository_password() {
  local first second

  while true; do
    TUI_STATUS="Waiting for new repository password"
    tui_render_modal "New Repository Password" "Create the password for this backup repository."$'\n\n'"You will need this password to restore your backups. It cannot be recovered if lost."
    tui_read_password "New password> " || return 1
    first="$TUI_PASSWORD_VALUE"

    if [[ -z "$first" ]]; then
      TUI_STATUS="Repository password cannot be empty"
      tui_render_modal "New Repository Password" "Repository password cannot be empty."$'\n\n'"Press any key to try again."
      tui_read_key || true
      continue
    fi

    TUI_STATUS="Waiting for password confirmation"
    tui_render_modal "Confirm Repository Password" "Enter the new repository password again."
    tui_read_password "Confirm password> " || return 1
    second="$TUI_PASSWORD_VALUE"

    if [[ "$first" == "$second" ]]; then
      export RESTIC_PASSWORD="$first"
      TUI_STATUS="Repository password set for this session"
      return 0
    fi

    TUI_STATUS="Repository passwords did not match"
    tui_render_modal "Password Mismatch" "The two repository passwords did not match."$'\n\n'"Press any key to try again."
    tui_read_key || true
  done
}

tui_bootstrap_snapshots() {
  local first_prompt=1

  tui_config_exists || return 0
  [[ "$TUI_REMOTE_READY" != "0" ]] || return 0
  if [[ "$TUI_REPOSITORY_READY" == "0" ]]; then
    return 0
  fi

  if tui_password_command_available; then
    tui_refresh_snapshots || true
    return 0
  fi

  while true; do
    if ((first_prompt == 0)); then
      TUI_STATUS="Repository password did not work"
    fi

    if ! tui_prompt_session_password "$([[ "$first_prompt" == "0" ]] && printf 'Repository password did not work. Try again.' || printf 'Enter the repository password for this TUI session.')"; then
      return 1
    fi

    if tui_refresh_snapshots; then
      return 0
    fi

    unset RESTIC_PASSWORD
    first_prompt=0
  done
}

tui_password_env_prefix() {
  if tui_password_command_available; then
    return 0
  fi

  tui_bootstrap_snapshots
}

tui_capture() {
  local output status
  output="$("$@" 2>&1)" && status=0 || status=$?
  TUI_LOG="$output"
  return "$status"
}

tui_capture_repo() {
  tui_password_env_prefix || return 1
  tui_capture tui_cli "$@"
}

tui_capture_with_loading() {
  local label="$1"
  shift

  local output_file pid status i=0 frame
  local -a frames=("|" "/" "-" "\\")

  TUI_STATUS="$label..."
  output_file="$(mktemp)"
  "$@" >"$output_file" 2>&1 &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    frame="${frames[$((i % ${#frames[@]}))]}"
    tui_render_loading "$label" "$frame"
    i=$((i + 1))
    sleep 0.25
  done

  wait "$pid" && status=0 || status=$?
  TUI_LOG="$(cat "$output_file")"
  rm -f "$output_file"
  return "$status"
}

tui_capture_repo_with_loading() {
  local label="$1"
  shift

  tui_password_env_prefix || return 1
  tui_capture_with_loading "$label" tui_cli "$@"
}

tui_fetch_snapshots_with_loading() {
  local output_file error_file pid status i=0 frame
  local -a frames=("|" "/" "-" "\\")

  output_file="$(mktemp)"
  error_file="$(mktemp)"
  tui_cli snapshots --json >"$output_file" 2>"$error_file" &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    frame="${frames[$((i % ${#frames[@]}))]}"
    tui_render_loading "Loading snapshots" "$frame"
    i=$((i + 1))
    sleep 0.12
  done

  wait "$pid" && status=0 || status=$?
  TUI_SNAPSHOTS_JSON="$(cat "$output_file")"
  TUI_LOG="$(cat "$error_file")"
  rm -f "$output_file" "$error_file"
  return "$status"
}

tui_refresh_snapshots() {
  local parse_error

  if [[ "$TUI_REMOTE_READY" == "0" ]]; then
    TUI_STATUS="Google Drive is not connected. Use Connect Google Drive."
    return 1
  fi

  if [[ "$TUI_REPOSITORY_READY" == "0" ]]; then
    TUI_STATUS="Repository is not initialized. Use Setup repository."
    return 1
  fi

  TUI_STATUS="Loading snapshots..."
  tui_render_loading "Loading snapshots" "|"
  if ! tui_password_env_prefix; then
    TUI_STATUS="Snapshot refresh cancelled"
    return 1
  fi

  if ! tui_fetch_snapshots_with_loading; then
    TUI_STATUS="Could not load snapshots"
    return 1
  fi

  if ! TUI_SNAPSHOTS_TSV="$(jq -r '
    def readable_time:
      . as $raw
      | try (
          capture("^(?<date>[0-9]{4}-[0-9]{2}-[0-9]{2})T(?<clock>[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\\.[0-9]+)?(?<zone>Z|[+-][0-9]{2}:?[0-9]{2})?$")
          | "\(.date) \(.clock) \((.zone // "") | sub("Z"; "UTC"))"
        ) catch ($raw // "unknown");

    sort_by(.time)
    | reverse
    | .[]
    | [
        ((.short_id // (.id // "")[0:8])),
        (.time | readable_time),
        (.hostname // "unknown"),
        (((.paths // []) | length) | tostring)
      ]
      | @tsv
  ' <<<"$TUI_SNAPSHOTS_JSON" 2>&1)"; then
    parse_error="$TUI_SNAPSHOTS_TSV"
    TUI_SNAPSHOTS_TSV=""
    TUI_SNAPSHOTS_LOADED=0
    TUI_STATUS="Snapshot output was not valid JSON"
    TUI_LOG="$parse_error"
    return 1
  fi

  TUI_SNAPSHOTS_LOADED=1
  TUI_SNAPSHOT_INDEX=0
  TUI_STATUS="Snapshots loaded"
}

tui_selected_snapshot() {
  [[ -n "$TUI_SNAPSHOTS_TSV" ]] || return 1
  sed -n "$((TUI_SNAPSHOT_INDEX + 1))p" <<<"$TUI_SNAPSHOTS_TSV" | awk -F'\t' '{ print $1 }'
}

tui_backup_delta_summary() {
  local repository_delta scan_summary

  repository_delta="$(
    awk '
      BEGIN { IGNORECASE = 1 }
      /would add.*repository|would be added.*repository|added to the repository/ {
        line = $0
      }
      END {
        print line
      }
    ' <<<"$TUI_LOG"
  )"

  scan_summary="$(
    awk '
      /processed/ {
        line = $0
      }
      END {
        print line
      }
    ' <<<"$TUI_LOG"
  )"

  if [[ -n "$repository_delta" ]]; then
    printf '%s' "$repository_delta"
    if [[ -n "$scan_summary" ]]; then
      printf '\n(%s)' "$scan_summary"
    fi
  else
    printf 'Dry-run repository add estimate unavailable.'
    if [[ -n "$scan_summary" ]]; then
      printf '\n(%s)' "$scan_summary"
    fi
  fi
}

tui_action_backup() {
  local dry_run_summary backup_log

  if tui_confirm "Run backup dry-run first?"; then
    if tui_capture_with_loading "Running backup dry-run" tui_cli backup --dry-run; then
      dry_run_summary="$(tui_backup_delta_summary)"
      TUI_STATUS="Dry-run complete. $dry_run_summary"
    else
      TUI_STATUS="Dry-run failed"
      return 1
    fi
  fi

  if tui_confirm "Start backup now?"$'\n\n'"${dry_run_summary:-Time estimate unavailable before upload; Restic will report progress while running.}"; then
    if tui_capture_repo_with_loading "Running backup" backup; then
      backup_log="$TUI_LOG"
      if tui_refresh_snapshots; then
        TUI_LOG="$backup_log"
        TUI_STATUS="Backup complete; snapshots refreshed."
      else
        TUI_LOG="$backup_log"
        TUI_STATUS="Backup complete; snapshot refresh failed."
      fi
    else
      TUI_STATUS="Backup failed"
    fi
  fi
}

tui_action_restore_selected() {
  local snapshot
  snapshot="$(tui_selected_snapshot)" || {
    TUI_STATUS="No snapshot selected"
    return 1
  }

  if tui_confirm "Restore selected snapshot to staging directory?"; then
    if tui_capture_repo restore "$snapshot" --yes; then
      TUI_STATUS="Restore complete"
    else
      TUI_STATUS="Restore failed"
    fi
  fi
}

tui_action_browse_selected() {
  local snapshot
  snapshot="$(tui_selected_snapshot)" || {
    TUI_STATUS="No snapshot selected"
    return 1
  }

  if tui_capture_repo ls "$snapshot"; then
    TUI_STATUS="Snapshot contents loaded"
  else
    TUI_STATUS="Could not browse snapshot"
  fi
}

tui_action_manage_paths() {
  TUI_MODE="paths"
  TUI_FOCUS="paths"
  TUI_ACTION_INDEX=0
  tui_clamp_path_index include
  tui_clamp_path_index exclude
  TUI_STATUS="Path management open"
}

tui_action_back_to_repositories() {
  TUI_MODE="repositories"
  TUI_FOCUS="actions"
  TUI_ACTION_INDEX=0
  TUI_STATUS="Repository list restored"
}

tui_action_back_to_snapshots() {
  TUI_MODE="snapshots"
  TUI_FOCUS="actions"
  TUI_ACTION_INDEX=0
  TUI_STATUS="Snapshot view restored"
}

tui_action_connect_selected_repository() {
  local job_id
  job_id="$(tui_selected_repository)" || {
    TUI_STATUS="No repository selected"
    return 1
  }

  tui_select_repository "$job_id"
  TUI_STATUS="Checking repository $job_id..."
  tui_render_loading "Checking repository $job_id" "|"
  tui_probe_remote_state
  if [[ "$TUI_REMOTE_READY" != "0" ]]; then
    tui_render_loading "Checking repository storage" "/"
  fi
  tui_probe_repository_state
  if [[ "$TUI_REMOTE_READY" == "0" || "$TUI_REPOSITORY_READY" == "0" ]]; then
    TUI_STATUS="Repository $job_id needs setup"
    TUI_MODE="snapshots"
    TUI_FOCUS="actions"
    TUI_ACTION_INDEX=0
    return 1
  fi

  if tui_bootstrap_snapshots; then
    TUI_MODE="snapshots"
    TUI_FOCUS="actions"
    TUI_ACTION_INDEX=0
  fi
}

tui_action_add_repository() {
  local id source remote
  tui_render_modal "Add Repository" "Enter a short repository id."
  id="$(tui_read_line "ID> ")" || return 1
  [[ -n "$id" ]] || {
    TUI_STATUS="Repository add cancelled"
    return 0
  }
  tui_render_modal "Add Repository" "Enter the source path to back up."
  source="$(tui_read_line "Source> ")" || return 1
  tui_render_modal "Add Repository" "Enter the remote path, for example gdrive:backups/home."
  remote="$(tui_read_line "Remote> ")" || return 1
  if [[ -z "$source" || -z "$remote" ]]; then
    TUI_STATUS="Repository add cancelled"
    return 0
  fi

  if tui_capture tui_cli jobs add "$id" --source "$source" --remote "$remote"; then
    tui_load_repositories
    TUI_STATUS="Repository added"
  else
    TUI_STATUS="Repository add failed"
  fi
}

tui_action_add_path() {
  local kind="$1" label value
  case "$kind" in
    include) label="Include" ;;
    exclude) label="Exclude" ;;
    *) return 1 ;;
  esac

  tui_render_modal "Add $label" "Enter the $kind path or pattern to add."
  value="$(tui_read_line "$label> ")" || return 1
  if [[ -z "$value" ]]; then
    TUI_STATUS="Path add cancelled"
    return 0
  fi

  if tui_capture tui_cli paths "$kind" add "$value"; then
    TUI_PATH_KIND="$kind"
    tui_set_path_index "$kind" "$(($(tui_path_count "$kind") - 1))"
    tui_clamp_path_index "$kind"
    TUI_STATUS="$label path added"
  else
    TUI_STATUS="$label path add failed"
  fi
}

tui_action_remove_selected_path() {
  local kind="$TUI_PATH_KIND" value label
  value="$(tui_selected_path)"
  if [[ -z "$value" ]]; then
    TUI_STATUS="No path selected"
    return 1
  fi

  case "$kind" in
    include) label="include" ;;
    exclude) label="exclude" ;;
    *) return 1 ;;
  esac

  if tui_confirm "Remove $label path?"$'\n\n'"$value"; then
    if tui_capture tui_cli paths "$kind" remove "$value"; then
      tui_clamp_path_index "$kind"
      TUI_STATUS="Path removed"
    else
      TUI_STATUS="Path remove failed"
    fi
  else
    TUI_STATUS="Path remove cancelled"
  fi
}

tui_action_setup_repository() {
  if [[ "$TUI_REMOTE_READY" == "0" ]]; then
    TUI_STATUS="Google Drive is not connected. Use Connect Google Drive."
    return 1
  fi

  if [[ "$TUI_REPOSITORY_READY" == "0" ]] && ! tui_prompt_new_repository_password; then
    TUI_STATUS="Repository setup cancelled"
    return 1
  fi

  if tui_capture_with_loading "Initializing repository" tui_cli init; then
    TUI_REPOSITORY_READY="1"
    TUI_STATUS="Repository initialized"
    tui_refresh_snapshots || true
  else
    TUI_STATUS="Repository setup failed"
    return 1
  fi
}

tui_activate_action() {
  tui_load_actions
  local action="${TUI_ACTIONS[$TUI_ACTION_INDEX]}"

  case "$action" in
    "Connect Google Drive")
      if tui_capture_with_loading "Connecting Google Drive" tui_cli remote setup; then
        TUI_REMOTE_READY="1"
        TUI_STATUS="Google Drive connected"
        tui_probe_repository_state
      else
        TUI_STATUS="Remote setup failed"
      fi
      ;;
    "Connect selected repository") tui_action_connect_selected_repository ;;
    "Add repository") tui_action_add_repository ;;
    "Connect repository") tui_bootstrap_snapshots ;;
    "Restore config from remote")
      if tui_confirm "Restore config from remote? This can overwrite local config."; then
        if tui_capture_with_loading "Restoring config from remote" tui_cli config restore --yes; then
          tui_probe_remote_state
          tui_probe_repository_state
          TUI_STATUS="Config restored"
        else
          TUI_STATUS="Config restore failed"
        fi
      else
        TUI_STATUS="Config restore cancelled"
      fi
      ;;
    "Create new config")
      tui_capture tui_cli config show && TUI_STATUS="Config created" || TUI_STATUS="Config creation failed"
      ;;
    "Doctor")
      tui_capture tui_cli doctor && TUI_STATUS="Doctor passed" || TUI_STATUS="Doctor found issues"
      ;;
    "Backup now") tui_action_backup ;;
    "Restore selected snapshot") tui_action_restore_selected ;;
    "Browse selected snapshot") tui_action_browse_selected ;;
    "Refresh snapshots") tui_refresh_snapshots ;;
    "Manage paths") tui_action_manage_paths ;;
    "Add include") tui_action_add_path include ;;
    "Add exclude") tui_action_add_path exclude ;;
    "Remove selected path") tui_action_remove_selected_path ;;
    "Back to snapshots") tui_action_back_to_snapshots ;;
    "Back to repositories") tui_action_back_to_repositories ;;
    "Check repository")
      tui_capture_repo_with_loading "Checking repository" check && TUI_STATUS="Repository check passed" || TUI_STATUS="Repository check failed"
      ;;
    "Setup repository") tui_action_setup_repository ;;
    "Prune repository")
      tui_confirm "Prune unreferenced repository data?" &&
        tui_capture_repo_with_loading "Pruning repository" prune && TUI_STATUS="Prune complete" || TUI_STATUS="Prune cancelled or failed"
      ;;
    "Unlock stale locks")
      tui_confirm "Unlock stale repository locks?" &&
        tui_capture_repo unlock && TUI_STATUS="Unlock complete" || TUI_STATUS="Unlock cancelled or failed"
      ;;
    "Quit") return 2 ;;
  esac
}

tui_move_selection() {
  local direction="$1"
  case "$TUI_FOCUS" in
    actions)
      tui_load_actions
      TUI_ACTION_INDEX=$((TUI_ACTION_INDEX + direction))
      ((TUI_ACTION_INDEX < 0)) && TUI_ACTION_INDEX=0
      ((TUI_ACTION_INDEX >= ${#TUI_ACTIONS[@]})) && TUI_ACTION_INDEX=$((${#TUI_ACTIONS[@]} - 1))
      ;;
    snapshots)
      local count=0
      [[ -n "$TUI_SNAPSHOTS_TSV" ]] && count="$(wc -l <<<"$TUI_SNAPSHOTS_TSV")"
      ((count == 0)) && return 0
      TUI_SNAPSHOT_INDEX=$((TUI_SNAPSHOT_INDEX + direction))
      ((TUI_SNAPSHOT_INDEX < 0)) && TUI_SNAPSHOT_INDEX=0
      ((TUI_SNAPSHOT_INDEX >= count)) && TUI_SNAPSHOT_INDEX=$((count - 1))
      ;;
    repositories)
      tui_load_repositories
      local count=0
      [[ -n "$TUI_REPOSITORIES_TSV" ]] && count="$(wc -l <<<"$TUI_REPOSITORIES_TSV")"
      ((count == 0)) && return 0
      TUI_REPOSITORY_INDEX=$((TUI_REPOSITORY_INDEX + direction))
      ((TUI_REPOSITORY_INDEX < 0)) && TUI_REPOSITORY_INDEX=0
      ((TUI_REPOSITORY_INDEX >= count)) && TUI_REPOSITORY_INDEX=$((count - 1))
      ;;
    paths)
      local count index
      count="$(tui_path_count "$TUI_PATH_KIND")"
      ((count == 0)) && return 0
      index="$(tui_path_index "$TUI_PATH_KIND")"
      index=$((index + direction))
      ((index < 0)) && index=0
      ((index >= count)) && index=$((count - 1))
      tui_set_path_index "$TUI_PATH_KIND" "$index"
      ;;
  esac
  return 0
}

tui_move_path_column() {
  [[ "$TUI_MODE" == "paths" && "$TUI_FOCUS" == "paths" ]] || return 0
  case "$TUI_PATH_KIND" in
    include) TUI_PATH_KIND="exclude" ;;
    exclude) TUI_PATH_KIND="include" ;;
  esac
  tui_clamp_path_index "$TUI_PATH_KIND"
}

tui_next_focus() {
  if [[ "$TUI_MODE" == "paths" ]]; then
    case "$TUI_FOCUS" in
      paths)
        if [[ "$TUI_PATH_KIND" == "include" ]]; then
          TUI_PATH_KIND="exclude"
          tui_clamp_path_index "$TUI_PATH_KIND"
        else
          TUI_FOCUS="actions"
        fi
        ;;
      actions)
        TUI_FOCUS="paths"
        TUI_PATH_KIND="include"
        tui_clamp_path_index "$TUI_PATH_KIND"
        ;;
      *)
        TUI_FOCUS="paths"
        TUI_PATH_KIND="include"
        tui_clamp_path_index "$TUI_PATH_KIND"
        ;;
    esac
    return 0
  fi

  if [[ "$TUI_MODE" == "repositories" ]]; then
    case "$TUI_FOCUS" in
      repositories) TUI_FOCUS="actions" ;;
      actions) TUI_FOCUS="repositories" ;;
      *) TUI_FOCUS="repositories" ;;
    esac
    return 0
  fi

  case "$TUI_FOCUS" in
    snapshots) TUI_FOCUS="actions" ;;
    actions) TUI_FOCUS="snapshots" ;;
    *) TUI_FOCUS="actions" ;;
  esac
  return 0
}

tui_main() {
  local key

  tui_require_dependencies
  tui_enter_screen
  trap 'tui_exit_screen' EXIT
  trap 'tui_exit_screen; trap - EXIT; exit 130' INT TERM

  TUI_STATUS="Starting custos..."
  tui_render

  if tui_config_exists; then
    TUI_STATUS="Checking Google Drive connection..."
    tui_render_loading "Checking Google Drive connection" "|"
  fi
  tui_probe_remote_state

  if tui_config_exists && [[ "$TUI_REMOTE_READY" != "0" ]]; then
    TUI_STATUS="Checking repository setup..."
    tui_render_loading "Checking repository setup" "/"
  fi
  tui_probe_repository_state
  if tui_config_exists; then
    TUI_MODE="repositories"
    TUI_FOCUS="actions"
  else
    TUI_FOCUS="actions"
  fi

  while true; do
    tui_load_actions
    tui_render
    tui_read_key || true
    key="$TUI_KEY"

    case "$key" in
      q|Q) break ;;
      r|R)
        if [[ "$TUI_MODE" == "repositories" ]]; then
          tui_action_connect_selected_repository || true
        else
          tui_config_exists && tui_refresh_snapshots
        fi
        ;;
      $'\t') tui_next_focus ;;
      $'\033[A'|k|K) tui_move_selection -1 ;;
      $'\033[B'|j|J) tui_move_selection 1 ;;
      $'\033[D'|h|H) tui_move_path_column ;;
      $'\033[C'|l|L) tui_move_path_column ;;
      "")
        if [[ "$TUI_MODE" == "repositories" && "$TUI_FOCUS" == "repositories" ]]; then
          tui_action_connect_selected_repository || true
        elif [[ "$TUI_MODE" == "paths" && "$TUI_FOCUS" == "paths" ]]; then
          tui_action_remove_selected_path || true
        else
          tui_activate_action || [[ "$?" != "2" ]] || break
        fi
        ;;
      $'\n')
        if [[ "$TUI_MODE" == "repositories" && "$TUI_FOCUS" == "repositories" ]]; then
          tui_action_connect_selected_repository || true
        elif [[ "$TUI_MODE" == "paths" && "$TUI_FOCUS" == "paths" ]]; then
          tui_action_remove_selected_path || true
        else
          tui_activate_action || [[ "$?" != "2" ]] || break
        fi
        ;;
    esac

    if [[ -z "${CUSTOS_TUI_KEYS:-}" && ! -e /dev/tty ]]; then
      break
    fi
  done

  trap - INT TERM EXIT
  tui_exit_screen
  return 0
}
