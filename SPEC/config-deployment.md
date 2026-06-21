# Configuration deployment

How the lab puts an agent's configuration in place. The unit is a **config bundle** deployed to a **(target, scope)**; one bundle definition serves local development, an arbitrary project directory, and org-enforced managed placement.

## The bundle

A deployed bundle is **self-contained** — everything the agent needs at runtime, materialized together, never referencing back into the repo:

| Part | Notes |
|---|---|
| telemetry config | the `env` / `[otel]` block pointing at the backend's **full per-signal OTLP endpoints** |
| MCP config | the Elasticsearch MCP — **`local` scope only** (not in `project` or `managed` bundles) |
| hook **registration** | `settings.local.json` `hooks` / `config.toml` `[hooks]` / managed `requirements.toml` |
| audit delivery config | `agent-audit.conf` (see [`agent-audit.md`](agent-audit.md)) |
| hook **scripts + library** | `agent-audit.{sh,ps1}` + the shared core + the per-agent adapter |

**Materialize, don't reference.** Each deployment is a frozen **copy**. Editing a component source or template then changes only **future** deployments, never a live one — fixing a real coupling in the older in-place model, where editing a script under `components/` silently altered every stack's runtime behaviour at once. (The shared hook core stays a single source in the repo; deployment copies it into each bundle.)

## Scopes

Selected by `--scope` (default **`local`**). Behaviour per scope:

| Scope | `--target` | MCP materialized | Codex auth-link | Interactive | Teardown |
|---|---|---|---|---|---|
| **`local`** | **rejected** (target = stack dir) | **yes** | **yes** (`link-auth`) | no — safe, scriptable, no prompt | non-interactive, marker-matched |
| **`project`** | **required** `<dir>` | no | no | no — safe, scriptable, no prompt | non-interactive, marker-matched (`--target` again) |
| **`managed`** | n/a | no | no | **yes** — confirm each file, non-TTY aborts, no `--yes` | interactive (`teardown-managed`) |

- **`local`** — user-scope deployment to the **stack's own directory**. Full bundle **including** the Elasticsearch MCP. For a Codex stack it also links the user's `~/.codex/auth.json` into the relocated `CODEX_HOME` (`link-auth`, a `local`-only convenience: symlink, or copy with a staleness warning; no-op if the source is absent or the target exists), so the provider-identity source is present without a fresh `codex login`. (Claude has no auth-link.)
- **`project`** — user-scope deployment into an arbitrary directory (a user's real project, to see what telemetry/audit their everyday work would emit). Full bundle **except** the MCP — a local-only lab-exploration convenience, not injected into foreign projects, keeping their footprint minimal.
- **`managed`** — org-enforced placement at machine-global system paths, highest precedence. The **deploy-only, human-gated, never-overwrite** model in `SPEC/claude-code-managed-config.md` and `SPEC/codex-cli-managed-config.md` "Placement in this lab" (interactive, no `--yes`, non-TTY aborts, fail-loud, sidecar provenance marker, mandatory teardown). Dangerous and manual by design. A managed deploy can carry **telemetry, hooks, or both** — see [Managed materialize](#managed-materialize).

## Placement is marker-aware and fail-if-foreign — across all scopes

Every bundle file the lab writes carries a **per-file provenance sidecar** `<target>.managed`, one shared format across all scopes — four lines `agent=`, `endpoint=`, `placed_at=` (UTC ISO8601), `target=`. `endpoint` is the deploy's data-plane endpoint, threaded from `setup-config`: for telemetry deploys the OTLP base (the `apm_server` / `otel_collector` endpoint), for audit deploys the audit ES url. It is what teardown matches on to recognize its own work. A render script writes only its **own** concern's key and takes an optional **marker-endpoint override**, so a deploy that materializes both concerns into one agent home can key every file on a single deployment endpoint and let telemetry + audit **co-own** the shared `settings.local.json` / `config.toml`.

`managed` placement is **interactive** (confirm each file, non-TTY aborts) via `components/agents/shared/managed-config/`. `local` and `project` are **non-interactive** via the shared helper `components/agents/shared/config-place/`, reused by every render script and by local/project teardown. Both share the marker format and the fail-if-foreign rule. The per-bundle-file rule for `local`/`project`:

| Target state | Action |
|---|---|
| **absent** | write rendered content, then write the sidecar marker |
| **lab marker, `endpoint` matches** | ours — write, **merging only this concern's own key** (Claude `settings.local.json`: set `.env` or `.hooks`, preserving sibling lab keys so the two concerns co-own one home; Codex `config.toml`: append the section, skipping one already present). Idempotent, updatable |
| **no lab marker, or `endpoint` differs** | **fail loud** (non-zero, clear message); never merge/append/overwrite |

Nothing is written on the fail path, so there is nothing to roll back; a file that copies bundle assets next to a marked file (the hook scripts beside `settings.local.json` / `config.toml`) performs the foreign check **before** copying anything. The merge/append is strictly **marker-gated** — it only ever edits a file this tool already owns (matching marker) and fails loud on a foreign one. That is unlike the older permissive behaviour, which merged/skipped/appended into a target **regardless of ownership** (env-merge into any existing `settings.local.json`, create-if-absent skips, blind `[hooks]`/`[mcp_servers]` appends) and could silently corrupt a user's pre-existing assets.

**Codex's single `config.toml`.** Codex keeps `[otel]`, `[[hooks.*]]`, and `[mcp_servers.*]` in one file. The first lab section written in a run (otel for telemetry, hooks for audit) **creates and marks** the file (or fails if a pre-existing file is unmarked); later sections in the same run **append** onto the now-marked file. A re-run is idempotent: each section is skipped if its sentinel table header is already present.

The materialized agent home also gets a **self-ignore `.gitignore` = `*`**, placed as a normal bundle file (marker-keyed on the deploy endpoint, foreign-refused), so a `project` deploy never dirties the host project's git tree.

## Teardown — all scopes

`setup-config --teardown` is valid for every scope (`local` resolves the target to the stack dir; `project` requires `--target`, like `project` deploy; `managed` takes neither).

- **`managed`** → the existing **interactive** teardown (`teardown-managed`), unchanged. For the audit stacks, `--scope managed --teardown` runs `teardown-managed --with-hooks`, removing the host hook bundle (and, for a combined telemetry+hooks deploy, the telemetry config); teardown enumerates every candidate target, and one never placed is a harmless no-op.
- **`local` / `project`** → **non-interactive**: remove each bundle file carrying a lab marker whose `endpoint` matches this deploy, plus its marker (and the copied `hooks/` tree when the hook-bearing file was lab-owned, the linked Codex `auth.json` when lab-placed, and the agent home's self-ignore `.gitignore`). A target **lacking a lab marker, or carrying a different endpoint, is refused** and left untouched, and the run ends non-zero. Only ever removes lab-marked files.

## Backend vs config

Two concerns, kept separate:

- **`setup-backend`** — wait for the (already-up) backend to be healthy, then load its assets (ES pipelines / templates / ILM, Kibana saved objects). Docker lifecycle (up/down) is the **user's**, via plain `docker compose up -d` / `docker compose down`; setup does not run it. Polls Elasticsearch/Kibana with a bounded timeout and fails fast if the stack is not up.
- **`setup-config`** — deploy a bundle to a `(target, scope)`. **Backend-independent**: can run with no backend (e.g. managed placement onto a host whose backend is elsewhere or already running).

`setup.sh` is their **composition** (`setup-backend` then `setup-config`) and forwards `--scope` / `--target` unchanged (a `project`-scope run is just `--scope project --target <dir>` flowing through). `--scope` defaults to `local`; the backend must already be up (`docker compose up -d`) before running it. Managed-only **without** a backend is the standalone **`setup-config --scope managed`**.

## setup.conf — two planes

Each stack's `setup.conf` is the single source for the values the setup scripts read, in two commented planes:

| Plane | Key(s) | Stacks |
|---|---|---|
| **Control plane** | `elasticsearch.url`, `kibana.url` — endpoints `setup-backend` waits on / loads assets into. **The Elasticsearch MCP reuses `elasticsearch.url`** (no separate MCP key) | all |
| **Agent data plane** — telemetry | `telemetry.apm_server.endpoint` (`:8200`) | `claude-code-elastic`, `codex-cli-elastic` |
| | `telemetry.otel_collector.endpoint` (`:4318`) | `claude-code-otelcol-elastic` |
| **Agent data plane** — audit | **required** `agent_audit.elasticsearch.{url,timeout_ms}` + `agent_audit.capture.{user_prompt,tool_call}.{enabled,content}`, read fail-fast (no fallback to `elasticsearch.url`) | `claude-code-elastic-audit`, `codex-cli-elastic-audit` |

`setup-config` builds the three `/v1/{logs,traces,metrics}` URLs from the telemetry OTLP base. The data-plane key names the actual backing service rather than a generic `otlp` (the architecture is already exposed via the control-plane `elasticsearch.url` / `kibana.url`). Audit details: see [`agent-audit.md`](agent-audit.md).

**Secret values are never in `setup.conf`.** Each lives only in a gitignored **`setup.local.conf`** (covered by `**/setup.local.conf`); each stack with one ships a committed **`setup.local.conf.example`** with an empty value. Absent file or key → empty, no error (read symmetrically across stacks — the sh side uses `IFS= read` + a literal prefix-strip so a trailing `=` in a base64 key is preserved). Two symmetric secrets:

| Stacks | Secret key | Threaded to | Rendered header |
|---|---|---|---|
| Audit | `agent_audit.elasticsearch.api_key` | the audit hook config | (see [`agent-audit.md`](agent-audit.md)) |
| Telemetry (APM) | `telemetry.apm_server.api_key` | `setup-config` → `setup-telemetry` → `render-otel` | `Authorization: ApiKey <key>` on OTLP exports |
| Telemetry (Collector) | `telemetry.otel_collector.api_key` | (same) | (same) |

For telemetry, Claude sends the header via `OTEL_EXPORTER_OTLP_HEADERS` in the settings `env` block; Codex via the per-exporter `headers` table in `[otel.*.otlp-http]`. When **absent the rendered otel config is byte-identical to a no-key run** — no header line emitted — which suits the local demo APM Server / Collector, whose auth is disabled.

## Managed materialize

`setup-managed` makes the three OTLP endpoints **and** `--with-hooks` independently optional, requiring **at least one** of (all three OTLP endpoints) or `--with-hooks` (which also requires `--es-url`); it dies "nothing to place" if neither. Three combinations:

| Combination | Driven by | Claude `managed-settings.json` | Codex |
|---|---|---|---|
| **Telemetry-only** (config-only) | telemetry stacks (OTLP endpoints, no `--with-hooks`) | `env` (telemetry) only | `managed_config.toml` `[otel]` only |
| **Hooks-only** (audit) | audit stacks (`--with-hooks --es-url <audit ES url>`, no OTLP) | `_comment` + `hooks` block, **no `env`** | **only `requirements.toml`** (pins `[features].hooks`, hook tables); **no `managed_config.toml`** |
| **Combined** (telemetry + hooks) | OTLP endpoints **and** `--with-hooks` | `env` + `hooks` | `managed_config.toml` `[otel]` + `requirements.toml` |

- **Config-only files have no scripts to materialize** — Claude's `env` and Codex's `[otel]` are self-contained. Telemetry rendering happens **only** when the OTLP endpoints are present, byte-identical to before.
- **Hooks** materialize the **hook scripts** to a stable host location and point the managed config at them. Codex has a first-class **`managed_dir`**; Claude has **no such convention**, so the lab picks a `hooks/` dir beside `managed-settings.json` and must confirm **on a real host** that an absolute hook `command` path works (the macOS space / Windows `Program Files` caveats).
- For hooks-only, Codex omits `managed_config.toml` because with no telemetry it would be just a comment.

**Marker endpoint for an audit-only deploy.** The provenance marker and ownership check key on the **logs OTLP endpoint** for a telemetry deploy; an audit-only deploy has none, so `setup-managed` keys them on the **audit ES url** (`--es-url`) instead — the deploy's actual data-plane endpoint — so `place`/`teardown` and the marker stay meaningful. (`teardown` carries no endpoints and enumerates every candidate target; an unplaced one is a harmless no-op.)

## Sensitive content

Pointing any deployment — a real project via `--scope project`, or a managed host — at the lab backend flows that machine's prompts and tool I/O into the lab's Elasticsearch. That is the point of the lab, but it is also sensitive: don't run secret-bearing sessions against it. This caveat lives here and in the stack READMEs; the scripts do **not** emit it at runtime.
