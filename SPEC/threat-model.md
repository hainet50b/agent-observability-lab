# Threat model and audit coverage

This document records why the lab grows a local-sidecar variant
(`claude-otelcol-elastic`, future `codex-otelcol-elastic`, …) of every
direct stack, and what that variant does and does **not** solve. It exists
because the same question keeps coming back — *"can't a user just disable
VPN to evade audit?"* — and the honest answer shapes the lab's scope.

## Two threat models

Telemetry-as-audit serves two very different goals; conflating them produces
bad designs.

- **(A) Non-adversarial / network reliability.** The user is not trying to
  hide. Their network is flaky: VPN drops, mobile work, travel, lunch break
  with the laptop closed. The audit goal is *completeness* — every session
  eventually lands in the backend, no permanent loss when the path is
  temporarily broken.
- **(B) Adversarial / audit evasion.** The user actively wants their
  activity not recorded — disables VPN, kills the agent process, edits
  config, deletes the sidecar binary or its queue, formats the disk. The
  audit goal is *tamper resistance*.

## What telemetry can and cannot do

Telemetry is a **cooperation contract** between the agent and the backend.
It can solve (A) ruggedly. It cannot solve (B) — every component below the
audit boundary is under the user's control, and any client-side persistence
can be tampered with by a user with local privileges. Trying to harden (B)
inside the telemetry layer is a category mistake; (B) lives in the
OS / device / network layer (MDM-managed device with EDR process-start
logging, always-on VPN policy that disables networking when the VPN is off,
sealed write paths owned by a daemon the user cannot stop).

This lab explicitly **takes (A) as in-scope and (B) as out-of-scope**. If
(B) becomes a requirement, the answer is not a richer telemetry stack — it
is a separate endpoint-security project that observes the agent from
outside.

## The direct hook → Elasticsearch audit path

The agent-audit stacks (`*-elastic-audit`) capture prompts and tool calls with
**agent hooks** that POST straight to Elasticsearch (`logs-agent_audit.*`) — a
different mechanism from the OTel telemetry path above. The same (A)/(B)
boundary applies (it is an (A) tool), but the hook path sits on a **lower
floor** than the OTel sidecar, so its limits must be stated explicitly or it
will be mistaken for a tamper-proof audit trail — which it is not. Mistaking it
for one is worse than having no audit: decisions get made on data that is
incomplete and forgeable.

The hook-audit's specific bypass / failure surface:

- **The audited party owns the hook config.** Hooks load from user/project
  layers the user controls. Claude Code's `--dangerously-skip-permissions`
  silently disables PreToolUse/PostToolUse hooks (the audit records nothing) and
  `disableAllHooks` can drop even managed hooks; Codex hooks are off with
  `[features].hooks = false` unless pinned, and a user can launch with a
  different `CODEX_HOME`, or no audit config at all. Auditing someone with
  config they control is not a control.
- **Fail-open is silent.** Delivery is deliberately fail-open (an unreachable
  destination must not delay the agent), so blocking the endpoint — hosts file,
  firewall, offline — drops all audit with no local gap signal.
- **Out-of-agent activity is invisible.** Anything not flowing through the
  instrumented agent with hooks loaded — a raw API call, a different tool, an
  uninstrumented build — is never seen.
- **No integrity.** The hook builds and POSTs the document; the lab stores
  plaintext with no signing or hash-chain. A user with local privileges can
  suppress or forge. Tamper-evidence needs server-side anchoring the client
  cannot rewrite, and is moot while capture itself is bypassable.
- **Endpoint credential.** The `create_doc` key is on every workstation. It
  cannot delete or overwrite others' documents, but it can **inject forged**
  audit documents, and it is a key-sprawl / rotation liability.
- **Untrusted attribution.** Provider identity is read from the local
  `auth.json` JWT **without signature verification**; the account / email / org
  claims are self-asserted and forgeable locally.
- **Non-adversarial gaps too.** Hook timeouts drop late deliveries, only events
  the agent emits with a registered hook are captured, and a hand-edited
  lab-placed config still feeds the agent at runtime — placement is marker-aware
  and fail-if-foreign on *writes*, but it does not police later local edits.

The correct control for (B) / compliance evidence is **capture above the user's
machine**, at a trust boundary they do not own: provider-side enterprise audit
(Anthropic's Compliance API, ChatGPT Enterprise's compliance stack) or OS / EDR
/ network observation outside the agent. A richer hook-audit is not a path to
(B) — the same category mistake as hardening telemetry for (B).

Within budget, what raises the floor without reaching (B): **pin the hooks**
through the managed layer (Codex `requirements.toml` `[features].hooks = true` +
`allow_managed_hooks_only`; Claude `managed-settings.json`) so casual
disablement is blocked; **detect absence centrally** ("no audit from device X
for Y minutes" against the fleet roster) to catch fail-open / disablement after
the fact; and keep the ingest credential per-device, create-only, and rotatable
(or front it with a gateway that holds the key). Do **not** invest in at-rest
encryption / sealing / tamper-evidence of the captured body before the capture
itself is non-bypassable — that hardens the confidentiality of a record that can
still be dropped or forged, which is polishing a foundation with a hole in it.

In one line: the hook-audit answers *"what did cooperative users do?"* — never
*"prove a motivated user did not evade it."*

## Solving (A): local sidecar with persistent queue

Claude Code (and other OTel-emitting agents) use the OpenTelemetry SDK's
OTLP exporter, which buffers **in memory only**. If the network is down at
flush time, the batch is retried for a short window and then lost on process
exit. The OpenTelemetry JS SDK has no built-in disk-persistent exporter
today, and Claude Code exposes no hook for one — so this cannot be solved at
the agent layer without an upstream change.

The standard remedy is to insert a local **OpenTelemetry Collector** as a
same-host sidecar:

```
Agent ──OTLP(localhost:4318)──▶ Collector ──OTLP──▶ Backend
                                  │
                                  └─ file_storage extension + sending_queue
                                     (durable on-disk queue per exporter)
```

The Collector's `file_storage` extension, combined with the OTLP exporter's
`sending_queue.storage`, persists every batch to disk before retry. When
the network comes back, the queue drains. The queue is **per-exporter**, so
when the same Collector fans out to multiple backends, one backend being
unreachable does not back-pressure the others.

The agent points at `localhost:4318` — always reachable — so its export
path never fails as long as the local Collector is up. The local Collector
is what this lab's `*-otelcol-*` stacks demonstrate.

## What this still costs to deploy at fleet scale

The Collector approach is technically off-the-shelf, but rolling it out to
every employee's machine is the hard part. The honest list:

- **Installation:** MDM-pushed (Intune on Windows, Jamf / Kandji on macOS)
  as a system service (`Windows Service` / `LaunchDaemon`). Zero user UI.
- **Pointing the agent at the sidecar:** for Claude Code, this is the
  `managed-settings.json` mechanism (highest precedence — user cannot
  override) distributed by the same MDM. For Codex and other agents, each
  has its own enforcement story.
- **PII at rest on the device:** with content gates on
  (`OTEL_LOG_USER_PROMPTS`, `OTEL_LOG_TOOL_CONTENT`,
  `OTEL_LOG_RAW_API_BODIES`), the on-disk `file_storage` queue contains
  prompt text and tool I/O. Disk encryption, queue size / retention caps,
  end-of-life device handling become legal / privacy concerns, not just
  technical ones.
- **Secrets on the device:** the Collector's auth to the central backend
  (API key, mTLS cert) must be system-owned, user-unreadable, and
  rotatable.
- **Multi-OS:** Windows + macOS at minimum, each with its own packaging
  and service-management story.
- **Self-observation:** a sidecar that dies silently is an audit hole. A
  heartbeat metric or "no telemetry from device X for Y minutes" alert is
  mandatory, not optional.

Treat the sidecar rollout as a cross-functional project
(Observability + IT/MDM + SecOps + legal/privacy), not as the Observability
team's solo work.

## Observing the sidecar itself

A sidecar that dies silently is an audit hole, so the Collector must be
observable too. This splits into two responsibilities on **two sides**, which
are complementary — not alternatives:

- **Edge side — the Collector reports its own health.** An OpenTelemetry
  Collector emits its own internal telemetry (`otelcol_exporter_queue_size`,
  `otelcol_exporter_send_failed_*`, `otelcol_receiver_accepted_*`, `process_*`
  CPU/memory, …) via the **`service.telemetry`** subsystem — which is a
  *separate path* from the data pipelines that carry the agent's telemetry, so
  the Collector's self-metrics do **not** ride the agent payload's
  `file_storage` queue. This is the standard, natural configuration: point
  `service.telemetry.metrics` at the same backend over OTLP. The single most
  useful signal is `otelcol_exporter_queue_size` — a growing persistent queue
  means the link to the central backend is failing while the agent keeps
  working locally. This lab's `*-otelcol-*` stacks demonstrate this edge side.
- **Central side — detect the *absence* of an edge.** Edge self-telemetry only
  arrives when the edge can reach the center. When the VPN is down, the
  Collector is dead, or the laptop is powered off, the central backend receives
  **nothing** from that host — by definition no edge mechanism can self-report
  that condition. The only way to catch a host that has gone silent is to
  detect it **centrally**: alert on "no telemetry from device X for Y minutes"
  (heartbeat-absence) against the expected fleet inventory. This is an operator
  responsibility on the central backend, **out of scope for the lab to
  implement** (it needs the real fleet roster and alerting policy), but it is
  the load-bearing half of sidecar observability and is recorded here so it is
  not mistaken for something the edge configuration solves.

In short: the edge can tell you *how* it is doing while it is reachable; only
the center can tell you *that* an edge has gone dark. Build both.

## Where this leaves the lab

- The first stack **`claude-elastic`** is **direct** (no sidecar) — it
  exercises the (A)-with-loss case and is the smallest working end-to-end
  demo. Audit coverage is "VPN-connected sessions only", and this must be
  documented openly to whoever consumes the data.
- The planned **`claude-otelcol-elastic`** adds the sidecar — it is the
  (A)-solved reference implementation, and the working artifact when
  discussing fleet rollout with IT / MDM / SecOps / legal.
- Anything beyond (A) — tamper resistance, audit enforcement, always-on VPN
  policy — is **out of scope for this lab** and belongs to endpoint-security
  tooling outside it.
