#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154

set -u

marker_suffix='.managed'
failed=0
confirm_all=0
logs_endpoint=''
traces_endpoint=''
metrics_endpoint=''
es_url=''
es_api_key=''
timeout_ms=''
capture_user_prompt_enabled=''
capture_user_prompt_content=''
capture_tool_call_enabled=''
capture_tool_call_content=''
with_hooks=0
with_telemetry=0
hooks_stage=''

managed_config::log() { printf '[managed-config] %s\n' "$*" >&2; }

managed_config::die() {
  managed_config::log "FATAL: $*"
  exit 1
}

managed_config::require_adapter() {
  [ -n "${agent:-}" ] || managed_config::die "adapter did not set agent"
  command -v managed_config::manifest >/dev/null 2>&1 || managed_config::die "adapter did not define managed_config::manifest()"
}

managed_config::detect_os() {
  case "$(uname -s 2>/dev/null)" in
  Linux) os=linux ;;
  Darwin) os=macos ;;
  *) managed_config::die "unsupported OS on this shell: $(uname -s 2>/dev/null) — use the .ps1 entry on Windows" ;;
  esac
}

managed_config::parse_args() {
  while [ "$#" -gt 0 ]; do
    case $1 in
    --logs-endpoint)
      [ "$#" -ge 2 ] || managed_config::die "--logs-endpoint needs a value"
      logs_endpoint=$2
      shift 2
      ;;
    --traces-endpoint)
      [ "$#" -ge 2 ] || managed_config::die "--traces-endpoint needs a value"
      traces_endpoint=$2
      shift 2
      ;;
    --metrics-endpoint)
      [ "$#" -ge 2 ] || managed_config::die "--metrics-endpoint needs a value"
      metrics_endpoint=$2
      shift 2
      ;;
    --otlp-api-key)
      [ "$#" -ge 2 ] || managed_config::die "--otlp-api-key needs a value"
      otlp_api_key=$2
      shift 2
      ;;
    --es-url)
      [ "$#" -ge 2 ] || managed_config::die "--es-url needs a value"
      es_url=$2
      shift 2
      ;;
    --es-api-key)
      [ "$#" -ge 2 ] || managed_config::die "--es-api-key needs a value"
      es_api_key=$2
      shift 2
      ;;
    --timeout-ms)
      [ "$#" -ge 2 ] || managed_config::die "--timeout-ms needs a value"
      timeout_ms=$2
      shift 2
      ;;
    --capture-user-prompt-enabled)
      [ "$#" -ge 2 ] || managed_config::die "--capture-user-prompt-enabled needs a value"
      capture_user_prompt_enabled=$2
      shift 2
      ;;
    --capture-user-prompt-content)
      [ "$#" -ge 2 ] || managed_config::die "--capture-user-prompt-content needs a value"
      capture_user_prompt_content=$2
      shift 2
      ;;
    --capture-tool-call-enabled)
      [ "$#" -ge 2 ] || managed_config::die "--capture-tool-call-enabled needs a value"
      capture_tool_call_enabled=$2
      shift 2
      ;;
    --capture-tool-call-content)
      [ "$#" -ge 2 ] || managed_config::die "--capture-tool-call-content needs a value"
      capture_tool_call_content=$2
      shift 2
      ;;
    --with-hooks)
      with_hooks=1
      shift
      ;;
    *) managed_config::die "unknown argument: $1" ;;
    esac
  done
}

managed_config::require_tty() {
  if ! { : </dev/tty; } 2>/dev/null; then
    managed_config::die "no controlling TTY — placement is always interactive (there is no --yes); nothing was changed"
  fi
}

managed_config::confirm() {
  [ "$confirm_all" -eq 1 ] && return 0
  local reply
  printf '%s [y/a/N] ' "$1" >&2
  IFS= read -r reply </dev/tty || managed_config::die "aborted (EOF on confirm); nothing was changed"
  case $reply in
  a | A | all | ALL)
    confirm_all=1
    return 0
    ;;
  y | Y | yes | YES) return 0 ;;
  *)
    managed_config::log "declined — skipping"
    return 1
    ;;
  esac
}

managed_config::marker_field() {
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

managed_config::show_diff() {
  if command -v diff >/dev/null 2>&1; then
    diff -u "$1" "$2" >&2 || true
  else
    managed_config::log "(diff unavailable) existing content differs from the new content"
  fi
}

managed_config::show_content() {
  managed_config::log "content to be written:"
  sed 's/^/  | /' "$1" >&2
}

managed_config::install_file() {
  local source=$1 target=$2 dir mode
  dir=$(dirname -- "$target")
  mkdir -p "$dir" 2>/dev/null ||
    managed_config::die "cannot create $dir — rerun with privileges, e.g.: sudo mkdir -p '$dir'"
  cp "$source" "$target" 2>/dev/null ||
    managed_config::die "cannot write $target (permission denied?) — install it manually with elevated privileges, e.g.: sudo cp '$source' '$target'"
  if [ -x "$source" ]; then mode=755; else mode=644; fi
  chmod "$mode" "$target" 2>/dev/null ||
    managed_config::die "cannot set mode $mode on $target — set it manually, e.g.: sudo chmod $mode '$target'"
}

managed_config::write_marker() {
  local marker=$1 target=$2 placed_at
  placed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf 'agent=%s\nendpoint=%s\nplaced_at=%s\ntarget=%s\n' \
    "$agent" "$logs_endpoint" "$placed_at" "$target" >"$marker" 2>/dev/null
}

managed_config::place_one() {
  local key=$1 source=$2 target=$3
  local marker="$target$marker_suffix"
  [ -f "$source" ] || managed_config::die "$key: source content not found: $source"

  if [ ! -e "$target" ]; then
    managed_config::log "$key: $target does not exist (new file)"
    managed_config::show_content "$source"
    managed_config::confirm "Place $key at $target?" || return 0
    managed_config::install_file "$source" "$target"
    managed_config::write_marker "$marker" "$target" || {
      rm -f "$target" 2>/dev/null
      managed_config::die "$key: could not write provenance marker $marker — rolled back $target so it is not left unmarked"
    }
    managed_config::log "$key: placed $target"
    return 0
  fi

  if [ ! -f "$marker" ]; then
    managed_config::log "$key: REFUSED — $target exists with no provenance marker (not placed by this tool / real-org managed config). Never touched."
    failed=1
    return 0
  fi

  local marker_endpoint
  marker_endpoint=$(managed_config::marker_field "$marker" endpoint)
  if [ "$marker_endpoint" != "$logs_endpoint" ]; then
    managed_config::log "$key: REFUSED — this host already enforces $marker_endpoint; run teardown first."
    failed=1
    return 0
  fi

  if [ "$(cat "$source")" = "$(cat "$target")" ]; then
    managed_config::log "$key: already placed and identical — no-op."
    return 0
  fi

  managed_config::log "$key: $target was placed by managed setup but the content changed:"
  managed_config::show_diff "$target" "$source"
  managed_config::confirm "Update $key at $target?" || return 0
  managed_config::install_file "$source" "$target"
  managed_config::write_marker "$marker" "$target" ||
    managed_config::die "$key: updated $target but could not rewrite marker $marker — remove $target manually"
  managed_config::log "$key: updated $target"
}

managed_config::teardown_one() {
  local key=$1 target=$2
  local marker="$target$marker_suffix"

  if [ ! -e "$target" ] && [ ! -f "$marker" ]; then
    managed_config::log "$key: nothing to remove ($target absent)"
    return 0
  fi

  if [ ! -f "$marker" ]; then
    managed_config::log "$key: REFUSED — $target has no provenance marker (not placed by this tool / real-org config). Not removed."
    failed=1
    return 0
  fi

  local marker_agent marker_endpoint
  marker_agent=$(managed_config::marker_field "$marker" agent)
  marker_endpoint=$(managed_config::marker_field "$marker" endpoint)
  managed_config::confirm "Remove managed $key at $target (agent='$marker_agent' endpoint='$marker_endpoint')?" || return 0
  rm -f "$target" 2>/dev/null ||
    managed_config::die "cannot remove $target (permission denied?) — remove it manually with elevated privileges, e.g.: sudo rm '$target'"
  rm -f "$marker" 2>/dev/null ||
    managed_config::log "$key: removed $target but could not remove marker $marker — remove it manually"
  managed_config::log "$key: removed $target and its marker"
}

managed_config::stage_hooks() {
  local component_dir=$1 es_url_val=$2 es_api_key_val=${3:-}
  local timeout_ms_val=${4:-} up_enabled_val=${5:-} up_content_val=${6:-} tc_enabled_val=${7:-} tc_content_val=${8:-}
  local hooks_src="$component_dir/hooks" core_src="$component_dir/../shared/agent-audit/lib"
  local conf_template="$component_dir/templates/agent-audit.template.conf"
  [ -f "$conf_template" ] || managed_config::die "conf template not found: $conf_template"
  hooks_stage=$(mktemp -d) || managed_config::die "could not create temp staging dir"
  mkdir -p "$hooks_stage/lib"
  cp "$hooks_src/agent-audit.sh" "$hooks_src/agent-audit.ps1" "$hooks_stage/" ||
    managed_config::die "could not stage hook entry scripts"
  cp "$hooks_src/lib/adapter.sh" "$hooks_src/lib/adapter.ps1" "$hooks_stage/lib/" ||
    managed_config::die "could not stage hook adapter"
  cp "$core_src/agent-audit-core.sh" "$core_src/agent-audit-core.ps1" "$hooks_stage/lib/" ||
    managed_config::die "could not stage hook core"
  sed \
    -e "s#@@ES_URL@@#$es_url_val#" \
    -e "s#@@ES_API_KEY@@#$es_api_key_val#" \
    -e "s#@@ES_TIMEOUT_MS@@#$timeout_ms_val#" \
    -e "s#@@CAPTURE_USER_PROMPT_ENABLED@@#$up_enabled_val#" \
    -e "s#@@CAPTURE_USER_PROMPT_CONTENT@@#$up_content_val#" \
    -e "s#@@CAPTURE_TOOL_CALL_ENABLED@@#$tc_enabled_val#" \
    -e "s#@@CAPTURE_TOOL_CALL_CONTENT@@#$tc_content_val#" \
    "$conf_template" >"$hooks_stage/agent-audit.conf" ||
    managed_config::die "could not render agent-audit.conf"
  chmod +x "$hooks_stage/agent-audit.sh"
}

managed_config::hook_manifest_lines() {
  local hooks_target=$1 rel
  for rel in agent-audit.sh agent-audit.ps1 agent-audit.conf \
    lib/adapter.sh lib/adapter.ps1 lib/agent-audit-core.sh lib/agent-audit-core.ps1; do
    printf '%s\t%s\t%s\n' "hook:$rel" "$hooks_stage/$rel" "$hooks_target/$rel"
  done
}

managed_config::place() {
  managed_config::require_adapter
  [ -n "$logs_endpoint" ] || managed_config::die "no endpoint provided"
  managed_config::detect_os
  managed_config::require_tty
  local manifest_lines
  manifest_lines=$(managed_config::manifest "$os" "$@")
  [ -n "$manifest_lines" ] || managed_config::die "manifest empty for os '$os' — nothing to place"
  while IFS=$'\t' read -r key source target; do
    [ -n "${key:-}" ] || continue
    managed_config::place_one "$key" "$source" "$target"
  done <<EOF
$manifest_lines
EOF
  [ "$failed" -eq 0 ] || managed_config::die "one or more managed files were refused (see above); nothing foreign was touched"
}

managed_config::teardown() {
  managed_config::require_adapter
  managed_config::detect_os
  managed_config::require_tty
  local manifest_lines
  manifest_lines=$(managed_config::manifest "$os" "$@")
  [ -n "$manifest_lines" ] || managed_config::die "manifest empty for os '$os' — nothing to remove"
  while IFS=$'\t' read -r key _ target; do
    [ -n "${key:-}" ] || continue
    managed_config::teardown_one "$key" "$target"
  done <<EOF
$manifest_lines
EOF
  [ "$failed" -eq 0 ] || managed_config::die "one or more managed files were refused (see above)"

  local root
  root=$(managed_config::managed_root "$os")
  if [ -d "$root" ]; then
    find "$root" -depth -type d -empty -delete 2>/dev/null || true
    [ -d "$root" ] || managed_config::log "removed empty managed root $root"
  fi
}
