# Configuration deployment

How the lab puts an agent's configuration in place. The unit is a **config bundle** deployed to a **(target, scope)**; one bundle definition serves local development, an arbitrary project directory, and org-enforced managed placement.

The deployment tool is **`agent-config`**, a Rust CLI at `components/agent-config/` run via `cargo run` (the lab assumes a Rust toolchain, not prebuilt binaries). Each agent's bundle — which templates render into which files, per scope and per OS — is declared in one function per agent (`src/agents/claude.rs`, `src/agents/codex.rs`); the placement rules below live in `src/place.rs`. Subcommands: `render` (write a bundle tree to a directory), `place` / `teardown` (deploy to / remove from a live target), `bundle` (zip archives per scope × OS with a version ledger — see [Bundles](#bundles)).

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
| **`managed`** | n/a | no | no | **yes** — confirm each file (or `a` = yes-to-all), non-TTY aborts, no `--yes` | interactive |

- **`local`** — user-scope deployment to the **stack's own directory**. Full bundle **including** the Elasticsearch MCP. For a Codex stack it also links the user's `~/.codex/auth.json` into the relocated `CODEX_HOME` (a `local`-only convenience: symlink, or copy with a staleness warning; no-op if the source is absent or the target exists), so the provider-identity source is present without a fresh `codex login`. (Claude has no auth-link. The link is a placement-time act, so it is never part of a rendered or bundled tree.)
- **`project`** — user-scope deployment into an arbitrary directory (a user's real project, to see what telemetry/audit their everyday work would emit). Full bundle **except** the MCP — a local-only lab-exploration convenience, not injected into foreign projects, keeping their footprint minimal.
- **`managed`** — org-enforced placement at machine-global system paths, highest precedence. Follows the **deploy-only, human-gated, never-overwrite** model in [Managed placement](#managed-placement-deploy-only-human-gated) below. Dangerous and manual by design. A managed deploy can carry **telemetry, hooks, or both** — see [Managed materialize](#managed-materialize).

## Placement is marker-aware and fail-if-foreign — across all scopes

Every bundle file the lab writes carries a **per-file provenance sidecar** `<target>.managed`, one shared format across all scopes — five lines `tool=`, `agent=`, `endpoint=`, `placed_at=` (UTC ISO8601), `target=`. `tool=` names the **owning distribution** (`agent-observability-lab` here; other distributions use their own slug), because a managed root is machine-global and can hold bundles from more than one owner; `agent=` names the agent, which does not distinguish them. `endpoint` is the deploy's data-plane endpoint, computed once per deploy from `agent-config.toml`: for a single-concern `local`/`project` deploy the concern's own endpoint (the OTLP base for telemetry, the audit ES url for audit); a deploy carrying **both** concerns, and every **`managed`** deploy, writes a composite `telemetry=…;audit=…` value (managed uses the full logs OTLP endpoint in the telemetry half; the unused half stays empty). It is what teardown matches on to recognize its own work, and keying every file of one deploy on the same value is what lets telemetry + audit **co-own** the shared `settings.local.json` / `config.toml`.

`managed` placement is **interactive** (confirm each file — or answer `a` once to accept the rest — non-TTY aborts; the `a` shortcut is still interactive, not a `--yes` bypass). `local` and `project` are **non-interactive**, and every marked target is ownership-checked **before anything is written** (a foreign file aborts the whole deploy untouched). Both paths live in `components/agent-config/src/place.rs` and share the marker format and the fail-if-foreign rule. The per-bundle-file rule for `local`/`project`:

| Target state | Action |
|---|---|
| **absent** | write rendered content, then write the sidecar marker |
| **lab marker, `endpoint` matches** | ours — write, **merging only this concern's own key** (Claude `settings.local.json`: set `.env` or `.hooks`, preserving sibling lab keys so the two concerns co-own one home; Codex `config.toml`: append the section, skipping one already present). Idempotent, updatable |
| **no lab marker, or `endpoint` differs** | **fail loud** (non-zero, clear message); never merge/append/overwrite |

Nothing is written on the fail path, so there is nothing to roll back; the foreign check runs over every marked target **before** the first byte is copied. The merge/append is strictly **marker-gated** — it only ever edits a file this tool already owns (matching marker) and fails loud on a foreign one. That is unlike the older permissive behaviour, which merged/skipped/appended into a target **regardless of ownership** (env-merge into any existing `settings.local.json`, create-if-absent skips, blind `[hooks]`/`[mcp_servers]` appends) and could silently corrupt a user's pre-existing assets.

**Codex's single `config.toml`.** Codex keeps `[otel]`, `[[hooks.*]]`, and `[mcp_servers.*]` in one file. The first lab section written in a run (otel for telemetry, hooks for audit) **creates and marks** the file (or fails if a pre-existing file is unmarked); later sections in the same run **append** onto the now-marked file. A re-run is idempotent: each section is skipped if its sentinel table header is already present.

The materialized agent home also gets a **self-ignore `.gitignore` = `*`**, placed as a normal bundle file (marker-keyed on the deploy endpoint, foreign-refused), so a `project` deploy never dirties the host project's git tree.

## Managed placement (deploy-only, human-gated)

Managed config is **machine-global, admin-owned, highest-precedence** — it cannot be isolated per-stack the way `local` / `project` deploys isolate user config. It does not need a stack of its own: it is an **agent-scoped capability** — templates under `components/agents/<agent>/` plus the OS-path-aware bundle definition and interactive placement in `components/agent-config/` — that **any** stack can opt into at setup, regardless of backend (managed config is agent-side; the backend is irrelevant). This placement model is agent-agnostic; only the file format, paths, and what is enforceable differ per agent ([`claude-managed-config.md`](claude-managed-config.md), [`codex-managed-config.md`](codex-managed-config.md)).

It is deliberately a **guarded manual deploy, not part of the automated suite.** Exercising managed config means writing host-global, admin-owned, highest-precedence files that affect **every** agent on the machine and cannot be overridden by a user — too dangerous to drive mechanically. So the lab **does not mechanically verify it**: no verify script, no containerized harness, and **no auto-confirm.** Placement is the deliverable; that enforcement takes effect is confirmed by observation and documented, never by an automated assertion.

Placement is **always interactive:**

- An opt-in (`--scope managed`) selects the *attempt*; the **confirm itself cannot be bypassed** — there is no `--yes`.
- **Non-TTY / EOF aborts** (never default-yes), so automation (headless agents, CI) can never place managed config even if it reaches the step.
- A permission error **fails loud** — print the path and the privileged/manual command — rather than fail-open (unlike the audit hook: the operator asked for this write, so a failure must be seen).

### Never overwrite; track provenance; provide teardown

Managed config is a host **singleton** per file, and the path may already hold the operator's **real organization's** MDM-pushed managed config. Clobbering that is a real-world security incident, not a lab inconvenience — so the lab **never overwrites a file it does not own.** (Claude is the exception to the singleton framing: its target is a lab-named **fragment** in a drop-in directory, so the lab coexists with a foreign `managed-settings.json` rather than contending for it — and therefore no longer detects one. See [`claude-managed-config.md`](claude-managed-config.md) "Placement & teardown".) Placement records the sidecar provenance marker beside the managed file (agent / endpoint / placed-at / target — the shared format above, with the managed composite `endpoint`). Ownership is keyed on the **endpoint** — what the host is enforced *toward* — not a stack name (a managed deploy is a host act, not a per-stack one):

| Existing file | Verdict |
| --- | --- |
| none | place after confirm, write the marker |
| lab-placed, same endpoint, same content | no-op (already placed) |
| lab-placed, same endpoint, changed content | update after explicit confirm |
| lab-placed, **different endpoint** | refuse — "this host already enforces &lt;endpoint&gt;; run teardown first" |
| present with **no lab marker** (foreign / real org config) | **hard refuse — never touch it** |

A **teardown script is mandatory** — the counterpart to placement, since a host-global change otherwise persists after the experiment (the machine stays enforced). Teardown removes **only** files the marker confirms the lab placed (restoring the host), **refuses to remove a foreign file**, and is itself interactive + fail-loud (no `--yes`).

## Teardown — all scopes

`agent-config teardown` is valid for every scope (`local` resolves the target to the stack dir; `project` requires `--target`, like `project` deploy; `managed` takes neither).

- **`managed`** → **interactive** teardown: it enumerates every candidate target the stack's `agent-config.toml` could have placed (hook bundle, settings fragment / `requirements.toml`, and always Codex's `managed_config.toml`), confirms each marker-bearing file, and treats one never placed as a harmless no-op.
- **`local` / `project`** → **non-interactive**: remove each bundle file carrying a lab marker whose `endpoint` matches this deploy, plus its marker (and the copied `hooks/` tree when the hook-bearing file was lab-owned, the linked Codex `auth.json` when lab-placed, and the agent home's self-ignore `.gitignore`). A target **lacking a lab marker is a benign skip** — left untouched, no error — because it is the user's own file, not the lab's (e.g. a `codex login` `auth.json`, or a project's own `.mcp.json`; these are never placed in `project` scope). A target carrying a **different** deploy's `endpoint` is **refused and the run ends non-zero** (it belongs to another deploy). Only ever removes lab-marked files.

## Backend vs config

Two concerns, kept separate:

- **`provision`** (`scripts/provision.{sh,ps1}`) — a thin wrapper that joins the stack's compose network and runs `ghcr.io/hainet50b/espalier` `apply --group <stack> --yes` against the espalier project at `components/backends/` (targets, groups, and dependency edges live in its `espalier.toml`). Health waiting, ordering, and selection are the tool's; the wrapper only names the group. Docker lifecycle (up/down) is the **user's**, via plain `docker compose up -d` / `docker compose down`; setup does not run it. `scripts/provision-standalone.{sh,ps1}` — rendered by `espalier render-script`, payloads embedded, `curl`-only — are the equally supported no-Docker path; they read `ESPALIER_ELASTICSEARCH_URL` / `ESPALIER_KIBANA_URL` (and optional `ESPALIER_ELASTICSEARCH_API_KEY`) at run time and are regenerated whenever assets change.
- **`agent-config place`** — deploy a bundle to a `(target, scope)`. **Backend-independent**: can run with no backend (e.g. managed placement onto a host whose backend is elsewhere or already running).

`setup.sh` is their **composition** (`provision` then `agent-config place`) and forwards `--scope` / `--target` unchanged (a `project`-scope run is just `--scope project --target <dir>` flowing through). `--scope` defaults to `local`; the backend must already be up (`docker compose up -d`) before running it. Managed-only **without** a backend is the standalone **`agent-config place --scope managed`**.

## Two config files — one per plane

Each stack splits its configuration by consumer: the **espalier project** (`components/backends/espalier.toml`, shared by all stacks) carries the backend control plane — targets, per-stack groups, dependency edges — and **`agent-config.toml`** (TOML) carries the agent data plane read by the `agent-config` CLI. The CLI deserializes the TOML into typed structures with unknown keys rejected (serde `deny_unknown_fields`) — a typo or a misplaced key is an error, not a silent no-op — and logs the resolved concerns (`telemetry=on audit=off`) at the start of every run:

| Plane | Key(s) | Stacks |
|---|---|---|
| **Control plane** | `espalier.toml` `[targets.local]` — in-network endpoints (`http://elasticsearch:9200`, `http://kibana:5601`) the espalier container provisions into; `[groups.<stack>]` names each stack's selection. The Elasticsearch MCP has **no key of its own**: its template carries a fixed container-reachable endpoint (`host.docker.internal:9200` — the same ES, addressed from inside the MCP container) placed verbatim | all |
| **Agent data plane** — telemetry | `telemetry.apm_server.endpoint` (`:8200`) | `claude-elastic`, `codex-elastic` |
| **Agent data plane** — audit | **required** `agent_audit.elasticsearch.{url,timeout_ms}` + `agent_audit.capture.{user_prompt,tool_call}.{enabled,content}`, read fail-fast (no fallback to `elasticsearch.url`) | `claude-elastic-audit`, `codex-elastic-audit` |

`agent-config` builds the three `/v1/{logs,traces,metrics}` URLs from the telemetry OTLP base. The data-plane key names the actual backing service rather than a generic `otlp` (the architecture is already exposed via the control-plane `elasticsearch.url` / `kibana.url`). Audit details: see [`agent-audit.md`](agent-audit.md).

**Secret values are never in a committed conf.** Each lives only in a gitignored **`agent-config.local.toml`** (covered by `**/agent-config.local.toml`); each stack with one ships a committed **`agent-config.local.toml.example`** with an empty value. The overlay is looked up **beside `agent-config.toml`** by default; `--local-conf <file>` points the CLI at another secrets file (runtime wiring, so it lives on the command line, not in the committed conf — an explicitly named file that is missing is an error, while the absent default is not). Absent default file → empty key, no error. The overlay is the same typed vocabulary: only the two `api_key` fields are accepted, and an `api_key` in the committed conf is rejected as an unknown key. Two symmetric secrets:

| Stacks | Secret key | Threaded to | Rendered header |
|---|---|---|---|
| Audit | `agent_audit.elasticsearch.api_key` | the audit hook config | (see [`agent-audit.md`](agent-audit.md)) |
| Telemetry | `telemetry.apm_server.api_key` | the rendered telemetry config | `Authorization: ApiKey <key>` on OTLP exports |

For telemetry, Claude sends the header via `OTEL_EXPORTER_OTLP_HEADERS` in the settings `env` block; Codex via the per-exporter `headers` table in `[otel.*.otlp-http]`. When **absent the rendered otel config is byte-identical to a no-key run** — no header line emitted — which suits the local demo APM Server, whose auth is disabled.

## Managed materialize

A managed deploy carries telemetry, hooks, or both, driven by which concerns the stack's `agent-config.toml` declares (a `[telemetry]` and/or an `[agent_audit]` table; a conf with neither fails at load). Three combinations:

| Combination | Driven by | Claude `managed-settings.d/10-agent-observability-lab.json` | Codex |
|---|---|---|---|
| **Telemetry-only** (config-only) | telemetry stacks (telemetry keys only) | `env` (telemetry) only | `managed_config.toml` `[otel]` only |
| **Hooks-only** (audit) | audit stacks (`agent_audit.*` keys only) | `_comment` + `hooks` block, **no `env`** | **only `requirements.toml`** (pins `[features].hooks`, hook tables); **no `managed_config.toml`** |
| **Combined** (telemetry + hooks) | both key groups in one conf | `env` + `hooks` | `managed_config.toml` `[otel]` + `requirements.toml` |

- **Config-only files have no scripts to materialize** — Claude's `env` and Codex's `[otel]` are self-contained. Telemetry rendering happens **only** when the OTLP endpoints are present, byte-identical to before.
- **Hooks** materialize the **hook scripts** to a stable host location and point the managed config at them. Codex has a first-class **`managed_dir`**; Claude has **no such convention**, so the lab picks a `hooks/` dir at the managed root (beside `managed-settings.d/`) and must confirm **on a real host** that an absolute hook `command` path works (the macOS space / Windows `Program Files` caveats). For **both** agents the bundle goes one level deeper, into an **owner-scoped** `hooks/<tool>/` — the managed root is machine-global, and two distributions of this tooling would otherwise write the same `hooks/agent-audit.{sh,ps1}` and collide. Fragment names are derived from the same `tool` slug, so one constant governs every owner-scoped path.
- For hooks-only, Codex omits `managed_config.toml` because with no telemetry it would be just a comment.

**Managed marker endpoint.** A managed deploy keys the provenance marker on the composite `telemetry=<logs OTLP endpoint>;audit=<audit ES url>` value (see [Placement is marker-aware](#placement-is-marker-aware-and-fail-if-foreign--across-all-scopes)) — a telemetry-only deploy leaves the audit half empty, an audit-only deploy the telemetry half — so `place`/`teardown` and the marker stay meaningful for every combination. (`teardown` carries no endpoints and enumerates every candidate target; an unplaced one is a harmless no-op.)

## Bundles

`agent-config bundle` writes the same rendered bundles as **zip archives**, one cell per **scope × OS** (managed and local by default; every cell with an explicit `--scope`/`--os` filter), named `<owner>-<agent>-<scope>-<os>-<version>.zip` under the stack's `dist/`. Versioning: a content-only sha256 **cell hash** (file bytes + relative paths, ordering-stable, version file excluded) is compared against the committed **`bundle-versions.conf`** ledger beside `agent-config.toml`; only changed cells mint a new `YYYYMMDD-NNNN` version (UTC date), unchanged cells are skipped (`--all` re-emits them), and stale archives of a re-emitted cell are replaced. Each archive carries a `<owner>.version` file — at the managed root for managed cells, inside the agent home for user-scope cells.

`local`/`project` placement bakes **absolute target paths** into the rendered content (hook commands, the seal cert path), so those bundles are **target-specific by construction**: a `local` cell bakes the stack directory of the machine that cut it, and a `project` cell requires `--target` at bundle time (without one it is skipped, loudly). Only `managed` bundles are host-portable — their roots are fixed per OS. All rendered output is LF regardless of the rendering host.

## Sensitive content

Pointing any deployment — a real project via `--scope project`, or a managed host — at the lab backend flows that machine's prompts and tool I/O into the lab's Elasticsearch. That is the point of the lab, but it is also sensitive: don't run secret-bearing sessions against it. This caveat lives here and in the stack READMEs; the scripts do **not** emit it at runtime.
