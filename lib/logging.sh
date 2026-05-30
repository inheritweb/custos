#!/usr/bin/env bash

log_info() {
  printf 'info: %s\n' "$*" >&2
}

log_success() {
  printf 'ok: %s\n' "$*" >&2
}

log_warn() {
  printf 'warning: %s\n' "$*" >&2
}

log_error() {
  printf 'error: %s\n' "$*" >&2
}

die() {
  log_error "$*"
  exit 1
}
