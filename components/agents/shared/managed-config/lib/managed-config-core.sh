#!/usr/bin/env bash
# shellcheck disable=SC2154

set -u

mc_marker_suffix='.lab-managed'
mc_failed=0
mc_stack=''
mc_endpoint=''

mc_log() { printf '[managed-config] %s\n' "$*" >&2; }

mc_die() {
  mc_log "FATAL: $*"
  exit 1
}

mc_require_adapter() {
  [ -n "${mc_agent:-}" ] || mc_die "adapter did not set mc_agent"
  command -v mc_manifest >/dev/null 2>&1 || mc_die "adapter did not define mc_manifest()"
}

mc_detect_os() {
  case "$(uname -s 2>/dev/null)" in
  Linux) mc_os=linux ;;
  Darwin) mc_os=macos ;;
  *) mc_die "unsupported OS on this shell: $(uname -s 2>/dev/null) — use the .ps1 entry on Windows" ;;
  esac
}

mc_parse_args() {
  while [ "$#" -gt 0 ]; do
    case $1 in
    --stack)
      [ "$#" -ge 2 ] || mc_die "--stack needs a value"
      mc_stack=$2
      shift 2
      ;;
    --endpoint)
      [ "$#" -ge 2 ] || mc_die "--endpoint needs a value"
      mc_endpoint=$2
      shift 2
      ;;
    *) mc_die "unknown argument: $1" ;;
    esac
  done
}

mc_require_tty() {
  if ! { : </dev/tty; } 2>/dev/null; then
    mc_die "no controlling TTY — placement is always interactive (there is no --yes); nothing was changed"
  fi
}

mc_confirm() {
  local reply
  printf '%s [y/N] ' "$1" >&2
  IFS= read -r reply </dev/tty || mc_die "aborted (EOF on confirm); nothing was changed"
  case $reply in
  y | Y | yes | YES) return 0 ;;
  *)
    mc_log "declined — skipping"
    return 1
    ;;
  esac
}

mc_marker_field() {
  [ -f "$1" ] || return 0
  local k v
  while IFS='=' read -r k v || [ -n "$k" ]; do
    if [ "$k" = "$2" ]; then
      printf '%s' "${v%$'\r'}"
      return 0
    fi
  done <"$1"
  return 0
}

mc_show_diff() {
  if command -v diff >/dev/null 2>&1; then
    diff -u "$1" "$2" >&2 || true
  else
    mc_log "(diff unavailable) existing content differs from the new content"
  fi
}

mc_show_content() {
  mc_log "content to be written:"
  sed 's/^/  | /' "$1" >&2
}

mc_install_file() {
  local source=$1 target=$2 dir
  dir=$(dirname -- "$target")
  mkdir -p "$dir" 2>/dev/null ||
    mc_die "cannot create $dir — rerun with privileges, e.g.: sudo mkdir -p '$dir'"
  cp "$source" "$target" 2>/dev/null ||
    mc_die "cannot write $target (permission denied?) — install it manually with elevated privileges, e.g.: sudo cp '$source' '$target'"
}

mc_write_marker() {
  local marker=$1 target=$2 placed_at
  placed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf 'agent=%s\nstack=%s\nendpoint=%s\nplaced_at=%s\ntarget=%s\n' \
    "$mc_agent" "$mc_stack" "$mc_endpoint" "$placed_at" "$target" >"$marker" 2>/dev/null ||
    mc_die "placed $target but could not write provenance marker $marker — remove $target manually"
}

mc_place_one() {
  local key=$1 source=$2 target=$3
  local marker="$target$mc_marker_suffix"
  [ -f "$source" ] || mc_die "$key: source content not found: $source"

  if [ ! -e "$target" ]; then
    mc_log "$key: $target does not exist (new file)"
    mc_show_content "$source"
    mc_confirm "Place $key at $target?" || return 0
    mc_install_file "$source" "$target"
    mc_write_marker "$marker" "$target"
    mc_log "$key: placed $target"
    return 0
  fi

  if [ ! -f "$marker" ]; then
    mc_log "$key: REFUSED — $target exists with no lab marker (foreign / real-org managed config). Never touched."
    mc_failed=1
    return 0
  fi

  local marker_stack
  marker_stack=$(mc_marker_field "$marker" stack)
  if [ "$marker_stack" != "$mc_stack" ]; then
    mc_log "$key: REFUSED — $target is held by stack '$marker_stack'; run its teardown first."
    mc_failed=1
    return 0
  fi

  if [ "$(cat "$source")" = "$(cat "$target")" ]; then
    mc_log "$key: already placed by this stack and identical — no-op."
    return 0
  fi

  mc_log "$key: $target was placed by this stack but the content changed:"
  mc_show_diff "$target" "$source"
  mc_confirm "Update $key at $target?" || return 0
  mc_install_file "$source" "$target"
  mc_write_marker "$marker" "$target"
  mc_log "$key: updated $target"
}

mc_teardown_one() {
  local key=$1 target=$2
  local marker="$target$mc_marker_suffix"

  if [ ! -e "$target" ] && [ ! -f "$marker" ]; then
    mc_log "$key: nothing to remove ($target absent)"
    return 0
  fi

  if [ ! -f "$marker" ]; then
    mc_log "$key: REFUSED — $target has no lab marker (foreign / real-org config). Not removed."
    mc_failed=1
    return 0
  fi

  local marker_agent marker_stack
  marker_agent=$(mc_marker_field "$marker" agent)
  marker_stack=$(mc_marker_field "$marker" stack)
  mc_confirm "Remove lab-placed $key at $target (agent='$marker_agent' stack='$marker_stack')?" || return 0
  rm -f "$target" 2>/dev/null ||
    mc_die "cannot remove $target (permission denied?) — remove it manually with elevated privileges, e.g.: sudo rm '$target'"
  rm -f "$marker" 2>/dev/null ||
    mc_log "$key: removed $target but could not remove marker $marker — remove it manually"
  mc_log "$key: removed $target and its marker"
}

mc_place() {
  mc_require_adapter
  [ -n "$mc_stack" ] || mc_die "no --stack provided"
  mc_detect_os
  mc_require_tty
  local manifest_lines
  manifest_lines=$(mc_manifest "$mc_os")
  [ -n "$manifest_lines" ] || mc_die "manifest empty for os '$mc_os' — nothing to place"
  while IFS=$'\t' read -r key source target; do
    [ -n "${key:-}" ] || continue
    mc_place_one "$key" "$source" "$target"
  done <<EOF
$manifest_lines
EOF
  [ "$mc_failed" -eq 0 ] || mc_die "one or more managed files were refused (see above); nothing foreign was touched"
}

mc_teardown() {
  mc_require_adapter
  mc_detect_os
  mc_require_tty
  local manifest_lines
  manifest_lines=$(mc_manifest "$mc_os")
  [ -n "$manifest_lines" ] || mc_die "manifest empty for os '$mc_os' — nothing to remove"
  while IFS=$'\t' read -r key _ target; do
    [ -n "${key:-}" ] || continue
    mc_teardown_one "$key" "$target"
  done <<EOF
$manifest_lines
EOF
  [ "$mc_failed" -eq 0 ] || mc_die "one or more managed files were refused (see above)"
}
