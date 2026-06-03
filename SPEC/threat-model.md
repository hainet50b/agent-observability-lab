# Threat model and audit coverage

This document records why the lab grows a local-sidecar variant
(`claude-code-otelcol-elastic`, future `codex-otelcol-elastic`, …) of every
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

## Where this leaves the lab

- The first stack **`claude-code-elastic`** is **direct** (no sidecar) — it
  exercises the (A)-with-loss case and is the smallest working end-to-end
  demo. Audit coverage is "VPN-connected sessions only", and this must be
  documented openly to whoever consumes the data.
- The planned **`claude-code-otelcol-elastic`** adds the sidecar — it is the
  (A)-solved reference implementation, and the working artifact when
  discussing fleet rollout with IT / MDM / SecOps / legal.
- Anything beyond (A) — tamper resistance, audit enforcement, always-on VPN
  policy — is **out of scope for this lab** and belongs to endpoint-security
  tooling outside it.
