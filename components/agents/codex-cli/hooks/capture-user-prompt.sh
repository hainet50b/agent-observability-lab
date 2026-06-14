#!/usr/bin/env bash
#
# capture-user-prompt.sh — Codex CLI UserPromptSubmit audit hook (POSIX/bash).
#
# PURPOSE — deliver the canonical Agent Audit user-prompt document. Registered on
# Codex's `UserPromptSubmit` event (see ../scripts/render-hooks.sh and the stack
# setup.sh/.ps1), this fires once per submitted prompt, reshapes Codex's raw hook
# payload into the canonical `agent_audit.user_prompt` JSON document defined in
# SPEC/agent-audit.md, and POSTs it straight to the local Agent Audit data stream
# `logs-agent_audit.user_prompt-default`. Delivery is direct-to-Elasticsearch,
# independent of the OTLP/APM pipeline. It does NOT seal/encrypt: in the lab's
# `mode = "plaintext"` the prompt text is captured in plaintext (a future
# encrypted mode nulls the text and populates encrypted_text — reserved field).
#
# Delivery config (read at run time, NOT hard-coded): the [elasticsearch] / [audit]
# blocks of agent-audit.toml — `url`, `data_stream`, `api_key`, `timeout_ms`, and
# `audit.mode` (see ../agent-audit.template.toml and SPEC/agent-audit.md). Path:
#   $CODEX_AGENT_AUDIT_CONFIG, else ${CODEX_HOME:-$HOME/.codex}/agent-audit.toml
# Launching Codex as `CODEX_HOME=<stack>/.codex codex` (this stack's mechanism)
# makes that <stack>/.codex/agent-audit.toml — the hook process inherits CODEX_HOME
# from the same environment that launched Codex, beside config.toml / hooks.json.
#
# Field mapping (Codex raw payload -> canonical document):
#   .session_id  -> agent_audit.conversation_id   (Codex's session is the convo)
#   .turn_id     -> agent_audit.turn_id
#   .model       -> agent_audit.agent.model
#   .prompt      -> agent_audit.prompt.text  (+ .length = its character count)
#   agent.provider/name are constants ("openai" / "codex-cli").
#   user.* is the workstation login identity, best-effort: Codex's hook payload
#   carries none, so only the runtime OS username is available (user.name);
#   user.id stays null until a richer identity source is wired in (user.email is
#   not used — not consistently available cross-platform; access is restricted at
#   the data stream instead). agent_audit.agent.account.* (id/name/email) and the
#   parallel agent_audit.agent.organization.* (id/name) are the AI-agent PROVIDER
#   account/org, emitted as null until a source supplies them. host.name/
#   host.hostname are the runtime OS hostname (best-effort, both the same value).
#   cwd / transcript_path /
#   permission_mode are intentionally dropped — not part of the audit schema (and
#   cwd is PII), and the mapping is strict, so stray fields must not be emitted.
#
# CONTRACT — must never disturb the Codex session:
#   * Writes NOTHING to stdout. On UserPromptSubmit, stdout can be injected into
#     the model context or alter the prompt; ALL diagnostics go to stderr.
#   * ALWAYS exits 0 (best-effort, fail-open). A missing tool, missing config, an
#     unreachable Elasticsearch, or a parse miss must never block prompt
#     submission — a missing audit document is acceptable (SPEC/agent-audit.md
#     "Delivery and authorization"). The POST uses a very short timeout so an
#     unavailable destination does not noticeably delay agent usage.

set -u

log()   { echo "[capture-user-prompt] $*" >&2; }
done0() { exit 0; }   # every path is success — never block the prompt

config_file=${CODEX_AGENT_AUDIT_CONFIG:-${CODEX_HOME:-$HOME/.codex}/agent-audit.toml}

# Read a flat (non-array, non-inline-table) TOML scalar by key, unquoted. Keys in
# agent-audit.toml are unique across the [elasticsearch] / [audit] sections, so a
# section-agnostic lookup is unambiguous. Comments live on their own lines.
toml_get() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$config_file" 2>/dev/null \
    | head -n1 \
    | sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

# The canonical document is JSON; shaping arbitrary prompt text safely needs jq.
command -v jq   >/dev/null 2>&1 || { log "jq unavailable — cannot shape audit document; skipping"; done0; }
command -v curl >/dev/null 2>&1 || { log "curl unavailable — cannot deliver audit document; skipping"; done0; }

[ -f "$config_file" ] || { log "no delivery config at $config_file — skipping (run setup.sh)"; done0; }

es_url=$(toml_get url)
data_stream=$(toml_get data_stream)
api_key=$(toml_get api_key)
timeout_ms=$(toml_get timeout_ms)
mode=$(toml_get mode)

[ -n "$es_url" ] && [ -n "$data_stream" ] || { log "config missing url/data_stream — skipping"; done0; }

# timeout_ms (default 300) -> curl --max-time seconds, pure-shell (no awk/bc).
case "$timeout_ms" in ''|*[!0-9]*) timeout_ms=300 ;; esac
max_time=$(printf '%d.%03d' "$((timeout_ms / 1000))" "$((timeout_ms % 1000))")

payload=$(cat)
[ -n "$payload" ] || { log "empty stdin — nothing to capture"; done0; }

ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)

# Best-effort runtime identity (Codex's payload has none).
user_name=${USER:-${USERNAME:-$(id -un 2>/dev/null || echo "")}}

# Best-effort runtime host (ECS host.hostname/host.name). Codex's payload has
# none; use the OS hostname. host.name and host.hostname are the same value here
# (best-effort — ECS permits it); a richer source could split FQDN vs short name.
host_hostname=${HOSTNAME:-}
[ -n "$host_hostname" ] || host_hostname=$(hostname 2>/dev/null || echo "")
[ -n "$host_hostname" ] || host_hostname=${COMPUTERNAME:-}
host_name=$host_hostname

# Reshape raw Codex payload -> canonical agent_audit.user_prompt document. In
# plaintext mode prompt.text carries the prompt; any other mode nulls it (sealing
# into encrypted_text is a later increment) — prompt.length is the true char count
# regardless, so the audit trail still records that a prompt of that size occurred.
record=$(printf '%s' "$payload" \
  | jq -c --arg ts "$ts" --arg uname "$user_name" --arg mode "$mode" \
      --arg hname "$host_name" --arg hhost "$host_hostname" \
      '($mode == "plaintext") as $plain
       | (.prompt // null) as $p
       | {
        "@timestamp": $ts,
        event: { action: "user-prompt", created: $ts, dataset: "agent_audit.user_prompt", kind: "event" },
        user: { id: null, name: (if ($uname | length) > 0 then $uname else null end) },
        host: { name: (if ($hname | length) > 0 then $hname else null end), hostname: (if ($hhost | length) > 0 then $hhost else null end) },
        agent_audit: {
          agent: { provider: "openai", name: "codex-cli", model: (.model // null), account: { id: null, name: null, email: null }, organization: { id: null, name: null } },
          conversation_id: (.session_id // null),
          turn_id: (.turn_id // null),
          prompt: { text: (if $plain then $p else null end), encrypted_text: null, length: (($p // "") | length) }
        }
      }' 2>/dev/null) \
  || { log "payload not valid JSON — cannot shape audit document; skipping"; done0; }

# POST to the data stream's _doc endpoint (auto op_type=create for data streams).
es_target="${es_url%/}/${data_stream}/_doc"
curl_args=(-s -o /dev/null -w '%{http_code}' --max-time "$max_time" \
  -X POST "$es_target" -H 'Content-Type: application/json')
[ -n "$api_key" ] && curl_args+=(-H "Authorization: ApiKey $api_key")
curl_args+=(--data-binary @-)

http_code=$(printf '%s' "$record" | curl "${curl_args[@]}" 2>/dev/null) \
  || { log "POST to $es_target failed (curl error) — prompt proceeds uncaptured"; done0; }

case "$http_code" in
  2*) log "indexed 1 audit document -> $es_target (HTTP $http_code)" ;;
  *)  log "index returned HTTP $http_code (audit doc not stored) — prompt unaffected" ;;
esac
done0
