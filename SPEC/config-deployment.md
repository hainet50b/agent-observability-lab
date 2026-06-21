# Configuration deployment

How the lab puts an agent's configuration in place. The unit is a **config bundle** deployed to a **(target, scope)**; the same bundle definition serves local development, an arbitrary project directory, and org-enforced managed placement.

## The bundle

A deployed bundle is **self-contained** — everything the agent needs at runtime, materialized together, never referencing back into the repo:

- telemetry config (the `env` / `[otel]` block pointing at the backend's full per-signal OTLP endpoints),
- MCP config (**`local`-scope only** — not materialized in the `project` or `managed` bundles),
- hook **registration** (`settings.local.json` `hooks` / `config.toml` `[hooks]` / managed `requirements.toml`),
- the audit delivery config (`agent-audit.conf`),
- the hook **scripts and their library** themselves (`agent-audit.{sh,ps1}` + the shared core + the per-agent adapter).

**Materialize, don't reference.** Each deployment is a frozen **copy**. Editing a component source or template then changes only **future** deployments, never a live one — which fixes a real coupling in the current in-place model, where editing a script under `components/` silently altered every stack's runtime behaviour at once. (The shared hook core stays a single source in the repo; deployment copies it into each bundle.)

## Scopes

Three scopes, selected by `--scope` (default **`local`**):

- **`local`** — a user-scope deployment to the **stack's own directory**. **Rejects `--target`** (use `project` to deploy into a directory). Materializes the full bundle, **including** the Elasticsearch MCP. Safe, scriptable, no confirmation.
- **`project`** — a user-scope deployment into an arbitrary directory; **requires `--target <dir>`** — e.g. a user's real project, to see what telemetry/audit their everyday work would emit. Materializes the full bundle **except** the Elasticsearch MCP: the MCP is a local-only lab-exploration convenience and is not injected into foreign projects, keeping their footprint minimal. Safe, scriptable, no confirmation.
- **`managed`** — org-enforced placement at the machine-global system paths, highest precedence. `--target` is not applicable. This is the **deploy-only, human-gated, never-overwrite** model in `SPEC/claude-code-managed-config.md` and `SPEC/codex-cli-managed-config.md` "Placement in this lab" (interactive, no `--yes`, non-TTY aborts, fail-loud, sidecar provenance marker, mandatory teardown). Dangerous and manual by design. A managed deploy can carry **telemetry, hooks, or both**: `setup-managed` requires at least one of (all three OTLP endpoints) or `--with-hooks`, and renders only what is present — see [Managed materialize](#managed-materialize).

## Placement is marker-aware and fail-if-foreign — across all scopes

Every bundle file the lab writes carries a **per-file provenance sidecar** `<target>.lab-managed`, in one shared format across all scopes — four lines `agent=`, `endpoint=`, `placed_at=` (UTC ISO8601), `target=`. `endpoint` is the deploy's data-plane endpoint, threaded from `setup-config`: for telemetry deploys the OTLP base (the `apm_server` / `otel_collector` endpoint), for audit deploys the audit ES url. It is what teardown matches on to recognize its own work.

`managed` placement is **interactive** (confirm each file, non-TTY aborts) via `components/agents/shared/managed-config/`. `local` and `project` are **non-interactive** (safe, scriptable, no prompt, no `--yes`) via a shared, non-interactive helper `components/agents/shared/config-place/` reused by every render script and by local/project teardown. Both share the same marker format and the same fail-if-foreign rule. The per-bundle-file rule for `local`/`project`:

- **target absent** → write the rendered content, then write the sidecar marker.
- **target exists with a lab marker whose `endpoint` matches this deploy** → it is ours: overwrite (for Codex's single `config.toml`, append the lab section, skipping a section already present). Idempotent and updatable.
- **target exists with no lab marker, or a marker whose `endpoint` differs** → **fail loud** (non-zero, clear message). Never merge, append, or overwrite. Nothing is written, so there is nothing to roll back; a file that copies bundle assets next to a marked file (the hook scripts beside `settings.local.json` / `config.toml`) performs the foreign check **before** copying anything.

This replaces the older permissive behaviour (env-merge into an existing `settings.local.json`, create-if-absent skips, and blind `[hooks]`/`[mcp_servers]` appends), which could silently corrupt a user's pre-existing assets.

**Codex's single `config.toml`.** Codex keeps `[otel]`, `[[hooks.*]]`, and `[mcp_servers.*]` in one file. The first lab section written in a run (otel for telemetry, hooks for audit) **creates and marks** the file (or fails if a pre-existing file is unmarked); later sections in the same run **append** onto the now-marked file. A re-run is idempotent: each section is skipped if its sentinel table header is already present.

## Teardown — all scopes

`setup-config --teardown` is valid for every scope (`local` resolves the target to the stack dir; `project` requires `--target`, like `project` deploy; `managed` takes neither).

- **`managed`** → the existing **interactive** teardown (`teardown-managed`), unchanged. For the audit stacks, `--scope managed --teardown` runs `teardown-managed --with-hooks`, removing the host hook bundle (and, for a combined telemetry+hooks deploy, the telemetry config); teardown enumerates every candidate target, and one that was never placed is a harmless no-op.
- **`local` / `project`** → **non-interactive**: remove each bundle file that carries a lab marker whose `endpoint` matches this deploy, plus its marker (and the copied `hooks/` tree when the hook-bearing file was lab-owned). Any target **lacking a lab marker, or carrying a different endpoint, is refused** and left untouched, and the run ends non-zero. Only ever removes lab-marked files.

## Backend vs config

Two concerns, kept separate:

- **`setup-backend`** — wait for the (already-up) backend to be healthy, then load its assets (ES pipelines / templates / ILM, Kibana saved objects). Docker lifecycle (up/down) is the **user's**, via plain `docker compose up -d` / `docker compose down`; setup does not run it. It polls Elasticsearch/Kibana with a bounded timeout and fails fast if the stack is not up.
- **`setup-config`** — deploy a bundle to a `(target, scope)`. **Backend-independent**: it can run with no backend (e.g. managed placement onto a host whose backend is elsewhere or already running).

`setup.sh` is retained as their **composition** (`setup-backend` then `setup-config`) and forwards `--scope` / `--target` unchanged (a `project`-scope run is just `--scope project --target <dir>` flowing through to `setup-config`). `--scope` defaults to `local`. The backend must already be up (`docker compose up -d`) before running it. Managed-only **without** a backend is the standalone **`setup-config --scope managed`**.

## setup.conf — two planes

Each stack's `setup.conf` is the single source for the values the setup scripts read, grouped into two clearly commented planes:

- **Control plane** (all stacks): `elasticsearch.url` and `kibana.url` — the backend endpoints `setup-backend` waits on and loads assets into. The **Elasticsearch MCP reuses `elasticsearch.url`** (there is no separate MCP key).
- **Agent data plane** (where the agent ships data): the key differs by stack kind.
  - **Telemetry stacks** carry an OTLP base from which `setup-config` builds the three `/v1/{logs,traces,metrics}` URLs, keyed after the backing service each stack ships to: the APM-Server stacks (`claude-code-elastic`, `codex-cli-elastic`) carry **`telemetry.apm_server.endpoint`** (`:8200`), the Collector stack (`claude-code-otelcol-elastic`) carries **`telemetry.otel_collector.endpoint`** (`:4318`). The key names the actual backing service rather than a generic `otlp` (the architecture is already exposed via the control-plane `elasticsearch.url` / `kibana.url`).
  - **Audit stacks** (`claude-code-elastic-audit`, `codex-cli-elastic-audit`) carry the **required** `agent_audit.*` keys — `agent_audit.elasticsearch.url`, `agent_audit.elasticsearch.timeout_ms`, and `agent_audit.capture.{user_prompt,tool_call}.{enabled,content}` — read fail-fast (no fallback to `elasticsearch.url`). See [`agent-audit.md`](agent-audit.md).

**Secret values are never in `setup.conf`.** Each lives only in a gitignored **`setup.local.conf`** (covered by `**/setup.local.conf`), and each stack that has one ships a committed **`setup.local.conf.example`** with an empty value; absent file or key → empty, no error (read symmetrically across stacks — the sh side uses `IFS= read` + a literal prefix-strip so a trailing `=` in a base64 key is preserved). Two symmetric secrets:

- **Audit stacks** — `agent_audit.elasticsearch.api_key`, threaded to the audit hook config. See [`agent-audit.md`](agent-audit.md).
- **Telemetry stacks** — an optional api_key keyed after the backing service (the APM-Server stacks carry **`telemetry.apm_server.api_key`**, the Collector stack **`telemetry.otel_collector.api_key`**), threaded through `setup-config` → `setup-telemetry` → `render-otel` into the agent's OTLP exporter config. When set, the agent sends **`Authorization: ApiKey <key>`** on its OTLP exports (Claude via `OTEL_EXPORTER_OTLP_HEADERS` in the settings `env` block; Codex via the per-exporter `headers` table in `[otel.*.otlp-http]`). When **absent the rendered otel config is byte-identical to a no-key run** — no header line is emitted — which suits the local demo APM Server / Collector, whose auth is disabled.

## Managed materialize

What a managed deployment materializes depends on what it enforces. `setup-managed` makes the three OTLP endpoints **and** `--with-hooks` independently optional, requiring **at least one** of (all three OTLP endpoints) or `--with-hooks` (which also requires `--es-url`); it dies "nothing to place" if neither. Three combinations result:

- **Telemetry-only (config-only).** Claude's `managed-settings.json` `env` and Codex's `managed_config.toml` `[otel]` are **self-contained config files** — no scripts to materialize. This is the low-risk baseline, driven by the telemetry stacks. Telemetry rendering happens **only** when the OTLP endpoints are present, byte-identical to before.
- **Hooks-only (audit).** Driven by the audit stacks (`--with-hooks --es-url <agent_audit.elasticsearch.url>`, no OTLP endpoints), this materializes the **hook scripts** to a stable host location and points the managed config at them, with **no telemetry config emitted**: Claude's `managed-settings.json` carries only its `_comment` plus the `hooks` block (**no `env`**); Codex places **only `requirements.toml`** (pinning `[features].hooks` and the hook tables) and **does not place `managed_config.toml`** at all — with no telemetry that file would be just a comment. Codex has a first-class **`managed_dir`**; Claude has **no such convention**, so the lab picks a location (a `hooks/` dir beside `managed-settings.json`) and must confirm **on a real host** that an absolute hook `command` path works (the macOS space / Windows `Program Files` caveats).
- **Combined (telemetry + hooks).** Passing the OTLP endpoints **and** `--with-hooks` carries both: the rendered telemetry config plus the hook bundle and registration.

**Marker endpoint for an audit-only deploy.** The provenance marker and ownership check key on the **logs OTLP endpoint** for a telemetry deploy; an audit-only deploy has none, so `setup-managed` keys them on the **audit ES url** (`--es-url`) instead — the deploy's actual data-plane endpoint — so `place`/`teardown` and the marker stay meaningful. (`teardown` carries no endpoints and enumerates every candidate target; an unplaced one is a harmless no-op.)

## Sensitive content

Pointing any deployment — a real project via `--scope project`, or a managed host — at the lab backend flows that machine's prompts and tool I/O into the lab's Elasticsearch. That is the point of the lab, but it is also sensitive: don't run secret-bearing sessions against it. This caveat lives here and in the stack READMEs; the scripts do **not** emit it at runtime.
