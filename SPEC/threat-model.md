# Threat model and audit coverage

This document records the audit-coverage boundaries of the lab's two
acquisition paths — OTel telemetry and hook audit. It exists because the
same question keeps coming back — *"can't a user just disable VPN to evade
audit?"* — and the honest answer shapes the lab's scope.

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
  config, deletes local telemetry state, formats the disk. The audit goal
  is *tamper resistance*.

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

The direct audit path captures prompts and tool calls with
**agent hooks** that POST straight to Elasticsearch (`logs-agent_audit.*`) — a
different mechanism from the OTel telemetry path above. The same (A)/(B)
boundary applies (it is an (A) tool), but the hook path sits on a **lower
floor** than the OTel telemetry path, so its limits must be stated explicitly or it
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
`allow_managed_hooks_only`; Claude's managed-tier `hooks` block) so casual
disablement is blocked; **detect absence centrally** ("no audit from device X
for Y minutes" against the fleet roster) to catch fail-open / disablement after
the fact; and keep the ingest credential per-device, create-only, and rotatable
(or front it with a gateway that holds the key). Do **not** invest in at-rest
encryption / sealing / tamper-evidence of the captured body before the capture
itself is non-bypassable — that hardens the confidentiality of a record that can
still be dropped or forged, which is polishing a foundation with a hole in it.

In one line: the hook-audit answers *"what did cooperative users do?"* — never
*"prove a motivated user did not evade it."*

## The (A) gap in the direct telemetry path

Claude Code (and other OTel-emitting agents) use the OpenTelemetry SDK's
OTLP exporter, which buffers **in memory only**. If the network is down at
flush time, the batch is retried for a short window and then lost on process
exit — so even the cooperative (A) case has a loss window on a flaky link,
and this cannot be fixed at the agent layer without an upstream change.

Closing that window requires infrastructure **below the agent** — a
same-host relay with a durable on-disk queue — plus the fleet rollout that
entails (MDM installation, managed config pointing the agent at it,
PII-at-rest and device-secret handling, and observing the relay itself).
The lab once prototyped that pattern and has since **removed it** to stay
converged on acquisition methods and data formats; git history holds the
working reference. Treat durable transport as deployment infrastructure
outside the lab's scope.

## Where this leaves the lab

- The telemetry path is **direct**
  (agent → APM Server) — the (A)-with-loss posture. Audit coverage is
  "connected sessions only", and this must be documented openly to whoever
  consumes the data.
- Anything beyond (A) — tamper resistance, audit enforcement, always-on VPN
  policy — is **out of scope for this lab** and belongs to endpoint-security
  tooling outside it.
