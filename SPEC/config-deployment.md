# Configuration deployment

How the lab puts an agent's configuration in place. The unit is a **config bundle** deployed to a **(target, scope)**; the same bundle definition serves local development, an arbitrary project directory, and org-enforced managed placement.

## The bundle

A deployed bundle is **self-contained** — everything the agent needs at runtime, materialized together, never referencing back into the repo:

- telemetry config (the `env` / `[otel]` block pointing at the backend's full per-signal OTLP endpoints),
- MCP config,
- hook **registration** (`settings.local.json` `hooks` / `config.toml` `[hooks]` / managed `requirements.toml`),
- the audit delivery config (`agent-audit.conf`),
- the hook **scripts and their library** themselves (`agent-audit.{sh,ps1}` + the shared core + the per-agent adapter).

**Materialize, don't reference.** Each deployment is a frozen **copy**. Editing a component source or template then changes only **future** deployments, never a live one — which fixes a real coupling in the current in-place model, where editing a script under `components/` silently altered every stack's runtime behaviour at once. (The shared hook core stays a single source in the repo; deployment copies it into each bundle.)

## Scopes

Two scopes, selected by `--scope` (default **`local`**):

- **`local`** — a user-scope deployment. With **no `--target`** it goes to the stack's own directory; with **`--target <dir>`** it goes to that directory — e.g. a user's real project, to see what telemetry/audit their everyday work would emit. Both materialize the full bundle. Safe, scriptable, no confirmation.
- **`managed`** — org-enforced placement at the machine-global system paths, highest precedence. This is the **deploy-only, human-gated, never-overwrite** model in `SPEC/claude-code-managed-config.md` and `SPEC/codex-cli-managed-config.md` "Placement in this lab" (interactive, no `--yes`, non-TTY aborts, fail-loud, sidecar provenance marker, mandatory teardown). Dangerous and manual by design.

## Backend vs config

Two concerns, kept separate:

- **`setup-backend`** — bring the backend up (`docker compose up`) and load its assets (ES pipelines / templates / ILM, Kibana saved objects).
- **`setup-config`** — deploy a bundle to a `(target, scope)`. **Backend-independent**: it can run with no backend (e.g. managed placement onto a host whose backend is elsewhere or already running).

`setup.sh` is retained as their **composition** (`setup-backend` then `setup-config`) and forwards `--scope` / `--target`. `--scope` defaults to `local`; **`setup.sh --scope managed` also brings the backend up** (it is the composition). Managed-only **without** a backend is the standalone **`setup-config --scope managed`**.

## Managed materialize is staged

What a managed deployment materializes depends on what it enforces:

- **Config-only (telemetry).** Claude's `managed-settings.json` `env` and Codex's `managed_config.toml` `[otel]` are **self-contained config files** — no scripts to materialize. This is the low-risk baseline and is already in place.
- **Managed audit hooks.** Enforcing the audit hooks requires materializing the **hook scripts** to a stable host location and pointing the managed config at them: Codex has a first-class **`managed_dir`**; Claude has **no such convention**, so the lab picks a location (a `hooks/` dir beside `managed-settings.json`) and must confirm **on a real host** that an absolute hook `command` path works (the macOS space / Windows `Program Files` caveats). Treat managed-with-hooks as the increment after config-only.

## Sensitive content

Pointing any deployment — a real project via `--target`, or a managed host — at the lab backend flows that machine's prompts and tool I/O into the lab's Elasticsearch. That is the point of the lab, but it is also sensitive: don't run secret-bearing sessions against it. This caveat lives here and in the stack READMEs; the scripts do **not** emit it at runtime.
