# Agent Observability Lab — Developer Spec

Internal spec for people (and agents) implementing the lab. User-facing surface lives in `README.md`; coding style in `CONVENTIONS.md`.

## Repository shape

```
agent-observability-lab/
├─ PRD.md / SPEC/ / CONVENTIONS.md / README.md   # repo-wide spec layer (owned by human + conversational LLM)
├─ prompt.md / ralph.sh / ralph.ps1              # Ralph Loop driver
└─ stacks/
   └─ <name>/                                    # one self-contained, `docker compose`-runnable stack per directory
```

Each stack under `stacks/<name>/` is self-contained and must run without reference to any other stack; new agent/backend combinations are added as sibling directories.

Per-stack design (architecture, the signals it collects, how they land in storage) lives in that stack's own `README.md`, keeping each stack self-contained — see `stacks/claude-code-elastic/README.md`.

## Invariants

- **Demo posture, not production.** Stacks run locally with security relaxed and ports bound to localhost; never expose one publicly or point it at sensitive infrastructure.
- **Telemetry can carry sensitive content.** Agent telemetry may include prompt text and tool I/O — treat anything sent to a stack as sensitive: don't run a telemetry-enabled session containing secrets, and never commit captured telemetry into the repo.
- **Stacks stay self-contained.** No cross-stack file references or shared running services.
