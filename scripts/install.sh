#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="${CUSTOS_REPO_OWNER:-inheritweb}"
REPO_NAME="${CUSTOS_REPO_NAME:-custos}"
REPO_REF="${CUSTOS_REF:-main}"
INSTALL_DIR="${CUSTOS_INSTALL_DIR:-$HOME/.local/share/custos}"
BIN_DIR="${CUSTOS_BIN_DIR:-$HOME/.local/bin}"
DRY_RUN=0

usage() {
  cat <<USAGE
Usage:
  install.sh [options]

Options:
  --dry-run             Print what would happen without changing files
  --ref <ref>           Git ref to install (default: $REPO_REF)
  --install-dir <path>  Install project files here (default: $INSTALL_DIR)
  --bin-dir <path>      Install command wrapper here (default: $BIN_DIR)
  -h, --help            Show this help

Environment:
  CUSTOS_REF
  CUSTOS_INSTALL_DIR
  CUSTOS_BIN_DIR
USAGE
}

log() {
  printf 'info: %s\n' "$*" >&2
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'dry-run:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  "$@"
}

require_command() {
  command -v "$1" >/dev/null 2>&1
}

parse_args() {
  while (($#)); do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --ref)
        [[ $# -ge 2 ]] || die "--ref requires a value"
        REPO_REF="$2"
        shift 2
        ;;
      --install-dir)
        [[ $# -ge 2 ]] || die "--install-dir requires a value"
        INSTALL_DIR="$2"
        shift 2
        ;;
      --bin-dir)
        [[ $# -ge 2 ]] || die "--bin-dir requires a value"
        BIN_DIR="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

fetch_source() {
  local destination="$1"
  local archive_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/${REPO_REF}.tar.gz"

  require_command curl || die "Missing dependency: curl"
  require_command tar || die "Missing dependency: tar"

  log "Downloading ${REPO_OWNER}/${REPO_NAME}@${REPO_REF}"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'dry-run: curl -fsSL %q | tar -xz -C %q --strip-components=1\n' "$archive_url" "$destination"
    return 0
  fi

  mkdir -p "$destination"
  curl -fsSL "$archive_url" | tar -xz -C "$destination" --strip-components=1
}

install_files() {
  local source_dir="$1"

  log "Installing files to $INSTALL_DIR"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'dry-run: mkdir -p %q %q\n' "$INSTALL_DIR" "$BIN_DIR"
    printf 'dry-run: copy project bin to %q\n' "$INSTALL_DIR/"
    printf 'dry-run: copy project lib to %q\n' "$INSTALL_DIR/"
    [[ -d "$source_dir/examples" ]] && printf 'dry-run: copy project examples to %q\n' "$INSTALL_DIR/"
    [[ -f "$source_dir/README.md" ]] && printf 'dry-run: copy project README.md to %q\n' "$INSTALL_DIR/"
    [[ -f "$source_dir/LICENSE" ]] && printf 'dry-run: copy project LICENSE to %q\n' "$INSTALL_DIR/"
    return 0
  fi

  mkdir -p "$INSTALL_DIR" "$BIN_DIR"
  cp -R "$source_dir/bin" "$INSTALL_DIR/"
  cp -R "$source_dir/lib" "$INSTALL_DIR/"
  if [[ -d "$source_dir/examples" ]]; then
    cp -R "$source_dir/examples" "$INSTALL_DIR/"
  fi
  if [[ -f "$source_dir/README.md" ]]; then
    cp "$source_dir/README.md" "$INSTALL_DIR/"
  fi
  if [[ -f "$source_dir/LICENSE" ]]; then
    cp "$source_dir/LICENSE" "$INSTALL_DIR/"
  fi
}

install_wrapper() {
  local wrapper="$BIN_DIR/custos"

  log "Installing command wrapper to $wrapper"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'dry-run: write wrapper %q\n' "$wrapper"
    return 0
  fi

  cat >"$wrapper" <<WRAPPER
#!/usr/bin/env bash
export CUSTOS_LIB_DIR="${INSTALL_DIR}/lib"
export CUSTOS_BIN="${INSTALL_DIR}/bin/custos"
exec "${INSTALL_DIR}/bin/custos" "\$@"
WRAPPER
  chmod +x "$wrapper"
}

install_from_checkout() {
  local script_dir source_dir
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  source_dir="$(cd -- "$script_dir/.." && pwd)"

  [[ -f "$source_dir/bin/custos" && -d "$source_dir/lib" ]] || return 1
  install_files "$source_dir"
}

install_from_github() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap "rm -rf '$tmp_dir'" EXIT
  fetch_source "$tmp_dir/source"
  install_files "$tmp_dir/source"
}

main() {
  parse_args "$@"

  if ! install_from_checkout; then
    install_from_github
  fi

  install_wrapper
  log "Installed custos."
  log "Dependencies are not installed by this script; run: custos doctor"
  log "Run: custos doctor"
}

main "$@"
