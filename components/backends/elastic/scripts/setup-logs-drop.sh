#!/usr/bin/env bash
#
# setup-logs-drop.sh — drop high-volume Codex CLI streaming-delta event docs.
#
# Codex CLI emits one event document per streamed model fragment. The three
# `event_kind`s `response.output_text.delta`,
# `response.function_call_arguments.delta` and
# `response.custom_tool_call_input.delta` are content-free incremental fragments
# (the complete value lands on the terminal `.done` event; Codex's export strips
# conversation content from them entirely) and together account for ~91% of the
# event/`log_only` stream. This installs the sanctioned drop hook: a `drop`
# processor in the **`logs-apm.app@custom`** ingest pipeline, which the managed
# `logs-apm.app@default-pipeline` already calls with
# `ignore_missing_pipeline: true` — so creating the pipeline activates it.
#
# The drop is gated on `service.name == 'codex_cli_rs'` because
# `logs-apm.app@custom` is shared across every producer (claude-code, codex_cli_rs,
# smoke-test, future agents); matching on `event_kind` alone would also hit any
# other producer that happened to emit the same value. `ctx.labels?.event_kind`
# uses null-safe navigation: `event_kind` is absent on the valuable events
# (`codex.user_prompt`, `codex.tool_result`, `response.completed`, …) and
# `null == '…'` is safely false, so those documents are kept. The list is an
# explicit allowlist (not `endsWith('.delta')`): a wildcard would blindly drop
# unverified or future `.delta` kinds (refusal, reasoning-summary, …).
#
# No content is lost: per-turn token counts survive on `response.completed`, and
# latency survives in metrics (`codex.turn.ttft.duration_ms`,
# `codex.turn.e2e_duration_ms`); metrics are not dropped.
#
# Idempotent: a PUT replaces the pipeline definition, so re-running is safe.
#
# Prerequisites: curl, jq. Override the Elasticsearch base URL with ES_URL if you
# publish a different port than the default below.
#
#   ES_URL=http://localhost:9200  scripts/setup-logs-drop.sh
#
# Run from anywhere — it locates its own component directory like the others.

set -euo pipefail

ES_URL=${ES_URL:-http://localhost:9200}
PIPELINE=logs-apm.app@custom
PIPELINE_FILE=elasticsearch/logs-drop.pipeline.json

# Resolve and enter the component root (parent of this scripts/ directory) so the
# elasticsearch/ path resolves regardless of the caller's cwd.
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
cd "$COMPONENT_DIR"

skip() {
  echo "SKIP: $*"
  exit 0
}
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v curl > /dev/null 2>&1 || skip "curl not found"
command -v jq > /dev/null 2>&1 || skip "jq not found"

# The pipeline body (a drop that fires only on Codex CLI streaming-delta docs;
# other producers and events fall through unchanged) is the single source of
# truth shared with setup-logs-drop.ps1.
[ -f "$PIPELINE_FILE" ] || fail "pipeline body not found: $COMPONENT_DIR/$PIPELINE_FILE"

echo "[setup] installing ingest pipeline '$PIPELINE' on $ES_URL…"
result=$(curl -s -w '\n%{http_code}' -X PUT "$ES_URL/_ingest/pipeline/$PIPELINE" \
  -H 'Content-Type: application/json' --data "@$PIPELINE_FILE") || fail "request to Elasticsearch failed"

code=$(echo "$result" | tail -n1)
body=$(echo "$result" | sed '$d')

echo "$body" | jq . 2> /dev/null || echo "$body"

case "$code" in
  2*) : ;;
  *) fail "PUT _ingest/pipeline/$PIPELINE returned HTTP $code (expected 2xx)" ;;
esac

acknowledged=$(echo "$body" | jq -r '.acknowledged // false')
[ "$acknowledged" = true ] || fail "pipeline PUT not acknowledged"

echo "[setup] pipeline '$PIPELINE' installed ✓"
echo
echo "PASS: Codex CLI streaming-delta event docs (service.name=codex_cli_rs) are now"
echo "dropped at ingest. Run a Codex turn (see ../README.md) and confirm the"
echo "response.*.delta docs no longer land in logs-apm.app.codex_cli_rs-default."
