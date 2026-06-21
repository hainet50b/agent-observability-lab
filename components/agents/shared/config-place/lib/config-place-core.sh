#!/usr/bin/env bash
# shellcheck disable=SC2034

# Non-interactive, marker-aware placement for local/project bundle files.
# Reuses the managed-config marker format exactly: a per-file sidecar
# <target>.managed with lines agent=, endpoint=, placed_at=, target=.
# Placement is scriptable with NO prompt and NO --yes (local/project are
# "safe, scriptable, no confirmation" per SPEC); foreign or endpoint-mismatched
# targets fail loud and are never touched.

config_place_marker_suffix='.managed'

config_place::log() { printf '[config-place] %s\n' "$*" >&2; }

config_place::die() {
  config_place::log "FATAL: $*"
  exit 1
}

config_place::marker_field() {
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

config_place::write_marker() {
  local marker=$1 agent=$2 endpoint=$3 target=$4 placed_at
  placed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf 'agent=%s\nendpoint=%s\nplaced_at=%s\ntarget=%s\n' \
    "$agent" "$endpoint" "$placed_at" "$target" >"$marker" ||
    config_place::die "could not write provenance marker $marker"
}

# Returns 0 if the target is ours (lab marker with matching endpoint), 1 if it
# does not exist, and dies loud if it exists foreign / with a different endpoint.
config_place::assert_ours_or_absent() {
  local key=$1 endpoint=$2 target=$3
  local marker="$target$config_place_marker_suffix"
  [ -e "$target" ] || return 1
  [ -f "$marker" ] ||
    config_place::die "$key: REFUSED — $target exists with no provenance marker (not placed by this tool). Never touched."
  local marker_endpoint
  marker_endpoint=$(config_place::marker_field "$marker" endpoint)
  [ "$marker_endpoint" = "$endpoint" ] ||
    config_place::die "$key: REFUSED — $target carries a different endpoint ($marker_endpoint); run teardown first. Not touched."
  return 0
}

# Place a whole rendered file. ABSENT -> write + mark. OURS -> overwrite + mark.
# FOREIGN / mismatch -> die loud (nothing written).
config_place::place_file() {
  local key=$1 agent=$2 endpoint=$3 source=$4 target=$5
  local marker="$target$config_place_marker_suffix"
  config_place::assert_ours_or_absent "$key" "$endpoint" "$target" || true
  mkdir -p "$(dirname -- "$target")"
  cp "$source" "$target" || config_place::die "$key: could not write $target"
  config_place::write_marker "$marker" "$agent" "$endpoint" "$target"
  config_place::log "$key: wrote $target"
}

# Self-ignore a materialized agent-home: place <home>/.gitignore = "*" so the
# surrounding project's git ignores the whole bundle (config + secrets + runtime
# state) without touching the project's own ignore rules. Same marker-aware path
# as place_file, keyed on the deploy endpoint — foreign .gitignore is refused,
# teardown removes the lab-placed one. Idempotent across the render scripts that
# share an agent-home in one deploy (they pass the same endpoint).
config_place::place_self_ignore() {
  local agent=$1 endpoint=$2 home=$3
  local tmp
  tmp=$(mktemp)
  printf '*\n' >"$tmp"
  config_place::place_file 'gitignore' "$agent" "$endpoint" "$tmp" "$home/.gitignore"
  rm -f "$tmp"
}

# Append a rendered section to a shared single-file config (Codex config.toml).
# ABSENT -> create with the block + mark. OURS -> append the block (separated by
# a blank line), or skip when <sentinel> already present (idempotent re-run).
# FOREIGN / mismatch -> die loud (nothing written).
config_place::append_section() {
  local key=$1 agent=$2 endpoint=$3 source=$4 target=$5 sentinel=$6
  local marker="$target$config_place_marker_suffix"
  if config_place::assert_ours_or_absent "$key" "$endpoint" "$target"; then
    if grep -qF "$sentinel" "$target"; then
      config_place::log "$key: already present in $target — no-op."
      return 0
    fi
    printf '\n' >>"$target"
    cat "$source" >>"$target" || config_place::die "$key: could not append to $target"
    config_place::log "$key: appended to $target"
  else
    mkdir -p "$(dirname -- "$target")"
    cat "$source" >"$target" || config_place::die "$key: could not write $target"
    config_place::write_marker "$marker" "$agent" "$endpoint" "$target"
    config_place::log "$key: wrote $target"
  fi
}

# Remove a lab-placed file and its marker. A target with NO lab marker is a
# benign skip (return 0) — it is the user's own file, not ours. A target whose
# marker endpoint DIFFERS is refused (return 1) — it belongs to another deploy.
config_place::remove_file() {
  local key=$1 endpoint=$2 target=$3
  local marker="$target$config_place_marker_suffix"

  if [ ! -e "$target" ] && [ ! -f "$marker" ]; then
    config_place::log "$key: nothing to remove ($target absent)"
    return 0
  fi
  if [ ! -f "$marker" ]; then
    config_place::log "$key: leaving $target — not placed by this tool (your own login/config). Not an error."
    return 0
  fi
  local marker_endpoint
  marker_endpoint=$(config_place::marker_field "$marker" endpoint)
  if [ "$marker_endpoint" != "$endpoint" ]; then
    config_place::log "$key: REFUSED — $target carries a different endpoint ($marker_endpoint). Not removed."
    return 1
  fi
  rm -f "$target" || config_place::die "$key: could not remove $target"
  rm -f "$marker" || config_place::log "$key: removed $target but could not remove marker $marker — remove it manually"
  config_place::log "$key: removed $target and its marker"
  return 0
}
