# AGENTS.md

Agent Observability Lab — a hands-on lab wiring coding agents (Claude Code,
Codex) to observability backends: telemetry over OTLP/APM and tool-call audit
over hooks → Elasticsearch.

## Source of truth

The implementation is the source of truth. Documents record intent and
context but can lag behind the code; when a document and the tree disagree,
trust the tree and fix the document. Do not act on a documented claim you
have not verified against the current code.

## Orientation

- `agent-config/` — mechanism: the Rust CLI that renders, places, tears
  down, and bundles agent config — one declarative bundle definition per
  agent under `src/agents/`; the content it embeds lives in `agents/`
- `agents/` — policy, agent side: everything delivered to an agent's machine
  (per-agent config templates + runtime hooks, `shared/` = the shared hook
  core)
- `backends/` — backend side: one self-contained directory per backend
  family. `elastic/` holds the service fragments (compose + config + the
  ES/Kibana assets they consume), the espalier project (`espalier.toml`),
  the `provision.{sh,ps1}` wrappers, the connection file
  (`agent-config.toml`) agents wire up from, and the operational checks
  (`smoke-test.sh`, `verify-*`); its `docker-compose.yml` (project name
  `aol-elastic`) is the runnable composition
- `workbench/` — gitignored; per-experiment directories users create by
  copying the connection file and running `agent-config place` (see
  `README.md`)
- `README.md` — user-facing entry point
- `SPEC/` — reference notes that are hard to re-derive from code (telemetry
  field mappings, threat model, config-deployment invariants). Consult when
  relevant; verify before relying on details.
- `CONVENTIONS.md` — code style and the lint / format / test commands
- `PRD.md` — What / Why + open Tasks; `.ralph/` / `ralph.sh` / `ralph.ps1` —
  run machinery: run contract (`prompt.md`), pass gate (`gate.sh` /
  `gate.ps1`), repo knobs (`env.sh` / `env.ps1`), and the one-shot runner

## Working here

- Docs follow implementation: when a change makes a README or SPEC section
  stale, update it in the same change — or say explicitly that it is stale.

## Harness

This project uses a harness derived from **Ralph Loop**. It separates spec
(human + conversational LLM) from implementation (an implementation agent).

- **Spec and implementation are separate concerns.** Spec belongs to the
  human and the conversational LLM. Implementation belongs to the
  implementation agent. Do not blur the two.
- **Completed PRD tasks are history.** Items marked `[x]` in `PRD.md` are
  immutable. Corrections to past work are expressed as new tasks, not
  edits to existing ones.
- **Spec is a reference, not a contract**, same as the "Source of truth"
  section above. The exceptions: `PRD.md`'s What / Why and open Tasks are
  the project's binding intent; the executable pass gate (`.ralph/gate.sh`
  / `.ralph/gate.ps1`) remains each run's pass condition; and files under
  `SPEC/contracts/` are interface contracts — promises to parties outside
  this repo — that bind the interfaces they describe (implementation
  internals stay free). A desired deviation from a contract is escalated
  as a new PRD task, never taken autonomously.
- **Act naturally, not formulaically.** Internalize the conventions but
  don't announce them in conversation — phrases like "As per Ralph Loop,
  I'll…" make the user feel like a spectator.

### Running implementation work

When the human asks for implementation (or uses the historical "run Ralph"
shorthand), kick the runner instead of writing the code yourself:

- Run `./ralph.sh` (or `.\ralph.ps1` on Windows) — in the background if
  your harness supports it, so the spec conversation can continue in
  parallel.
- One run = one working set: the implementation agent selects a coherent
  group of open `PRD.md` tasks, lands them commit by commit, reports, and
  exits.
- The implementation agent picks the working set itself; to steer it, pass
  guidance as arguments: `./ralph.sh "focus on the parser tasks"`.
  Guidance selects among open tasks, never adds scope.
- **The integration branch stays yours while a run is in flight** — each
  run works in its own worktree and is integrated back afterwards. Edit
  `PRD.md` and the spec layer freely; commit promptly.
- The runner never resolves anything: a rebase conflict or a red gate
  leaves the run's worktree in place and reports — the next move is yours
  and the human's, either fixing directly or sending a run into that
  worktree (`--resume <run-id>` also re-enters interrupted or paused
  runs).
- Repo defaults (agent/model via `RALPH_CMD`, caches) live in
  `.ralph/env.sh` / `.ralph/env.ps1`; the invoking environment overrides
  them, so a single hard run can be escalated to a stronger model.
- Parallel runs are supported. When you are orchestrating, assigning each
  run a disjoint working set via guidance is the primary mode; the
  per-task claim protocol (`.ralph/claims/`, enforced at integration) is
  the backstop that keeps self-selecting runs off each other's tasks.
- Relay the substance of the run's report to the human and decide together
  whether to kick the next run.

`ralph.sh` / `ralph.ps1` owns the one-shot run lifecycle: the charter,
claims, worktree, gate, integration, and escalation. Keep the entire run
lifecycle off the conversation loop so the spec conversation does not
block on implementation or integration. Writing the implementation
yourself in the spec conversation is not an engine swap.

PRD's Tasks section is managed jointly with the human. Spec-layer updates
(`PRD.md` What/Why, `SPEC/`, `README.md`) are owned by the human and you;
the implementation agent is never asked to update them, which preserves
the spec/implementation separation principle above.
