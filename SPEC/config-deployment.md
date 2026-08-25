# Configuration deployment

How the lab puts an agent's configuration in place. The unit is a **config bundle** deployed to a **(target, scope)**; one bundle definition serves local development, an arbitrary project directory, and org-enforced managed placement.

The deployment tool is **`agent-config`**, a Rust CLI at `agent-config/` run via `cargo run` (the lab assumes a Rust toolchain, not prebuilt binaries). Each agent's bundle — which templates render into which files, per scope and per OS — is declared in one function per agent (`src/agents/claude.rs`, `src/agents/codex.rs`); the placement rules below live in `src/place.rs`. Subcommands: `render` (write a bundle tree to a directory, or with `--zip`, versioned zip archives per scope × OS — see [Bundles](#bundles)) and `place` / `teardown` (deploy to / remove from a live target). `--agent` takes one or more agents (repeatable or comma-separated: `--agent claude,codex`) and runs the subcommand per agent. `--scope` (default `local`) is single-valued everywhere; `render`'s `--os` is repeatable/comma-separated (default: every OS the scope makes available) — `place`/`teardown` have no `--os`, since they always target the live host. `render` and `place` also take `--concern telemetry,audit` — a pure **content filter** over what the config declares (naming an undeclared concern fails loud; omitting the flag deploys everything declared, which is also how a narrowed deployment is later converged to full) — except `render --zip`, which like `teardown` takes no `--concern`: teardown's ownership test needs none, and archives always carry the full declaration.

## The bundle

A deployed bundle is **self-contained** — everything the agent needs at runtime, materialized together, never referencing back into the repo:

| Part | Notes |
|---|---|
| telemetry config | the `env` / `[otel]` block pointing at the backend's **full per-signal OTLP endpoints** |
| MCP config | the Elasticsearch MCP — **`local` scope only** (not in `project` or `managed` bundles) |
| hook **registration** | `settings.local.json` `hooks` / `config.toml` `[hooks]` / managed `requirements.toml` |
| audit delivery config | `agent-audit.conf` (see [`agent-audit.md`](agent-audit.md)) |
| hook **scripts + library** | `agent-audit.{sh,ps1}` + the shared core + the per-agent adapter |

**Materialize, don't reference.** Each deployment is a frozen **copy**. Editing a component source or template then changes only **future** deployments, never a live one — fixing a real coupling in the older in-place model, where editing a script under `agents/` silently altered every live deployment's runtime behaviour at once. (The shared hook core stays a single source in the repo; deployment copies it into each bundle.)

## Scopes

Selected by `--scope` (default **`local`**). Behaviour per scope:

| Scope | Target | MCP materialized | Codex auth-link | Interactive | Teardown |
|---|---|---|---|---|---|
| **`local`** | **rejected** (target = the config's directory) | **yes** | **yes** (`link-auth`) | no — safe, scriptable, no prompt | non-interactive, marker-matched |
| **`project`** | **required** `--project <name>` (`render`/`place`; resolved against a `[project.<name>]` declaration — see [Two config files](#two-config-files--one-per-plane)); `--target <dir>` (`teardown`) | no | no | no — safe, scriptable, no prompt | non-interactive, marker-matched (`--target` again) |
| **`managed`** | n/a | no | no | **yes** — confirm each file (or `a` = yes-to-all), non-TTY aborts, no `--yes` | interactive |

- **`local`** — user-scope deployment **beside the `--config` file** (the workbench). Full bundle **including** the Elasticsearch MCP. For Codex it also links the user's `~/.codex/auth.json` into the relocated `CODEX_HOME` (a `local`-only convenience: symlink, or copy with a staleness warning; no-op if the source is absent or the target exists), so the provider-identity source is present without a fresh `codex login`. (Claude has no auth-link. The link is a placement-time act, so it is never part of a rendered or bundled tree.)
- **`project`** — user-scope deployment into an arbitrary directory (a user's real project, to see what telemetry/audit their everyday work would emit). Full bundle **except** the MCP — a local-only lab-exploration convenience, not injected into foreign projects, keeping their footprint minimal.
- **`managed`** — org-enforced placement at machine-global system paths, highest precedence. Follows the **deploy-only, human-gated, never-overwrite** model in [Managed placement](#managed-placement-deploy-only-human-gated) below. Dangerous and manual by design. A managed deploy can carry **telemetry, hooks, or both** — see [Managed materialize](#managed-materialize).

**OS candidates.** `render` and `place` share one filter deriving which OSes a `(scope, --project)` selection actually drives: start from every OS → the scope's own availability (`managed`: all three; `local`: the detected host only; `project`: whichever of `linux`/`macos`/`windows` the named `[project.<name>]` declares) → narrow by an explicit `--os` filter, if given (`render` only) → `place` additionally intersects with the detected host, since it only ever deploys live. An empty result is a **loud skip**, not an error — e.g. `--os windows` against a `project` name that declares no `windows` target, or `place --scope project` on a host OS the name doesn't declare.

## Placement is marker-aware and fail-if-foreign — across all scopes

Every bundle file the lab writes carries a **per-file provenance sidecar** `<target>.managed`, one shared format across all scopes — three lines: `executor=` (the ownership key), `placed_at=` (UTC ISO8601) and `target=` (forensic information, written but never matched on). The **executor** names the owning distribution: it is read from the optional `[agent_config] executor` key in `agent-config.toml` (`agent-observability-lab` in this repo's configs; other distributions declare their own) and defaults to the tool's own name, `agent-config`, when undeclared — a managed root is machine-global and can hold bundles from more than one owner, and two undeclared distributions are deliberately indistinguishable. Executor match is the **single ownership test everywhere** (place gate, teardown, managed placement, the hooks-directory sweep): the agent needs no line of its own because the agent home is already in the path, and the deploy's endpoints need none because ownership is about *who placed a file*, not *where it pointed*.

`managed` placement is **interactive** (confirm each file — or answer `a` once to accept the rest — non-TTY aborts; the `a` shortcut is still interactive, not a `--yes` bypass). `local` and `project` are **non-interactive**, and every marked target is ownership-checked **before anything is written** (a foreign file aborts the whole deploy untouched). Both paths live in `agent-config/src/place.rs` and share the marker format and the fail-if-foreign rule. The per-bundle-file rule for `local`/`project`:

| Target state | Action |
|---|---|
| **absent** | write rendered content, then write the sidecar marker |
| **marker with matching `executor`** | ours — write, **merging only this concern's own key** (Claude `settings.local.json`: set `.env` or `.hooks`, preserving sibling lab keys so the two concerns co-own one home; Codex `config.toml`: append the section, skipping one already present). Idempotent, updatable — a config edit followed by a re-place **converges** the deployment, no teardown ritual |
| **no marker, or a different `executor`** | **fail loud** (non-zero, clear message); never merge/append/overwrite |

Nothing is written on the fail path, so there is nothing to roll back; the foreign check runs over every marked target **before** the first byte is copied. The merge/append is strictly **marker-gated** — it only ever edits a file this tool already owns (matching marker) and fails loud on a foreign one. That is unlike the older permissive behaviour, which merged/skipped/appended into a target **regardless of ownership** (env-merge into any existing `settings.local.json`, create-if-absent skips, blind `[hooks]`/`[mcp_servers]` appends) and could silently corrupt a user's pre-existing assets.

**Codex's single `config.toml`.** Codex keeps `[otel]`, `[[hooks.*]]`, and `[mcp_servers.*]` in one file. The first lab section written in a run (otel for telemetry, hooks for audit) **creates and marks** the file (or fails if a pre-existing file is unmarked); later sections in the same run **append** onto the now-marked file. A re-run is idempotent: each section is skipped if its sentinel table header is already present.

The materialized agent home also gets a **self-ignore `.gitignore` = `*`**, placed as a normal bundle file (executor-marked, foreign-refused), so a `project` deploy never dirties the host project's git tree.

## Managed placement (deploy-only, human-gated)

Managed config is **machine-global, admin-owned, highest-precedence** — it cannot be isolated per-workbench the way `local` / `project` deploys isolate user config. It is an **agent-scoped capability** — templates under `agents/<agent>/` plus the OS-path-aware bundle definition and interactive placement in `agent-config/` — that **any** config can opt into, regardless of backend (managed config is agent-side; the backend is irrelevant). This placement model is agent-agnostic; only the file format, paths, and what is enforceable differ per agent ([`claude-managed-config.md`](claude-managed-config.md), [`codex-managed-config.md`](codex-managed-config.md)).

It is deliberately a **guarded manual deploy, not part of the automated suite.** Exercising managed config means writing host-global, admin-owned, highest-precedence files that affect **every** agent on the machine and cannot be overridden by a user — too dangerous to drive mechanically. So the lab **does not mechanically verify it**: no verify script, no containerized harness, and **no auto-confirm.** Placement is the deliverable; that enforcement takes effect is confirmed by observation and documented, never by an automated assertion.

Placement is **always interactive:**

- An opt-in (`--scope managed`) selects the *attempt*; the **confirm itself cannot be bypassed** — there is no `--yes`.
- **Non-TTY / EOF aborts** (never default-yes), so automation (headless agents, CI) can never place managed config even if it reaches the step.
- A permission error **fails loud** — print the path and the privileged/manual command — rather than fail-open (unlike the audit hook: the operator asked for this write, so a failure must be seen).

### Never overwrite; track provenance; provide teardown

Managed config is a host **singleton** per file, and the path may already hold the operator's **real organization's** MDM-pushed managed config. Clobbering that is a real-world security incident, not a lab inconvenience — so the lab **never overwrites a file it does not own.** (Claude is the exception to the singleton framing: its target is a lab-named **fragment** in a drop-in directory, so the lab coexists with a foreign `managed-settings.json` rather than contending for it — and therefore no longer detects one. See [`claude-managed-config.md`](claude-managed-config.md) "Placement & teardown".) Placement records the sidecar provenance marker beside the managed file (the shared three-line format above). Ownership is keyed on the **executor** — who placed the file — with the interactive per-file confirmation carrying the judgment about content:

| Existing file | Verdict |
| --- | --- |
| none | place after confirm, write the marker |
| ours (executor matches), same content | no-op (already placed) |
| ours (executor matches), changed content | update after explicit confirm (diff shown) |
| marked by a **different executor** | refuse — owned by another distribution; its own tooling removes it |
| present with **no marker** (foreign / real org config) | **hard refuse — never touch it** |

A **teardown script is mandatory** — the counterpart to placement, since a host-global change otherwise persists after the experiment (the machine stays enforced). Teardown removes **only** files the marker confirms the lab placed (restoring the host), **refuses to remove a foreign file**, and is itself interactive + fail-loud (no `--yes`).

## Teardown — all scopes

`agent-config teardown` is valid for every scope (`local` resolves the target to the config's directory; `project` requires `--target`, like `project` deploy; `managed` takes neither).

- **`managed`** → **interactive** teardown: it enumerates every candidate target the `agent-config.toml` could have placed (hook bundle, settings fragment / `requirements.toml`, and always Codex's `managed_config.toml`), confirms each marker-bearing file, and treats one never placed as a harmless no-op.
- **`local` / `project`** → **non-interactive**: remove each bundle file carrying a marker with this config's `executor`, plus its marker (and the copied `hooks/` tree when the hook-bearing file was ours, the linked Codex `auth.json` when we placed it, and the agent home's self-ignore `.gitignore`). A target **lacking a marker is a benign skip** — left untouched, no error — because it is the user's own file, not ours (e.g. a `codex login` `auth.json`, or a project's own `.mcp.json`; these are never placed in `project` scope). A target marked by a **different executor** is **refused and the run ends non-zero** (it belongs to another distribution). Teardown needs no concern or endpoint knowledge — it enumerates every candidate target and removes what the executor test confirms is ours.

## Backend vs config

Two concerns, kept separate:

- **`provision`** — the canonical wrapper is `backends/elastic/provision.{sh,ps1}`: it runs `ghcr.io/hainet50b/espalier` `apply --group elastic --yes` against the espalier project in its own directory (targets, the group, and dependency edges live in its `espalier.toml`), joining the compose network named by `ESPALIER_NETWORK` (default `aol-elastic_default`, the family compose's own network). Health waiting, ordering, and selection are the tool's. Docker lifecycle (up/down) is the **user's**, via plain `docker compose up -d` / `docker compose down`. A generated `provision-standalone.{sh,ps1}` pair — rendered by `espalier render-script`, payloads embedded, `curl`-only — is the equally supported no-Docker path (reads `ESPALIER_ELASTICSEARCH_URL` / `ESPALIER_KIBANA_URL` and optional `ESPALIER_ELASTICSEARCH_API_KEY` at run time); it is regenerated whenever assets change and is currently pending regeneration against the consolidated group.
- **`agent-config place`** — deploy a bundle to a `(target, scope)`. **Backend-independent**: can run with no backend (e.g. managed placement onto a host whose backend is elsewhere or already running).

`setup.sh` is their **composition** (`provision` then `agent-config place`) and forwards `--scope` / `--target` unchanged (a `project`-scope run is just `--scope project --target <dir>` flowing through). `--scope` defaults to `local`; the backend must already be up (`docker compose up -d`) before running it. Managed-only **without** a backend is the standalone **`agent-config place --scope managed`**.

## Two config files — one per plane

Configuration splits by consumer: the **espalier project** (`backends/elastic/espalier.toml`) carries the backend control plane — targets, the single all-assets group, dependency edges — and **`agent-config.toml`** (TOML) carries the agent data plane read by the `agent-config` CLI — plus the tool-directed `[agent_config]` table (`executor`, the ownership name written into provenance markers; defaults to `agent-config` when undeclared, and this repo's configs declare `agent-observability-lab`). The CLI deserializes the TOML into typed structures with unknown keys rejected (serde `deny_unknown_fields`) — a typo or a misplaced key is an error, not a silent no-op — and logs the resolved concerns (`telemetry=on audit=off`) at the start of every run:

| Plane | Key(s) | Concern |
|---|---|---|
| **Control plane** | `espalier.toml` `[targets.local]` — in-network endpoints (`http://elasticsearch:9200`, `http://kibana:5601`) the espalier container provisions into; `[groups.elastic]` is the single all-assets selection. The Elasticsearch MCP has **no key of its own**: its template carries a fixed container-reachable endpoint (`host.docker.internal:9200` — the same ES, addressed from inside the MCP container) placed verbatim | all |
| **Agent data plane** — telemetry | `telemetry.apm_server.endpoint` (`:8200`) | telemetry |
| **Agent data plane** — audit | **required** `agent_audit.elasticsearch.{url,timeout_ms}` + `agent_audit.capture.{user_prompt,tool_call}.{enabled,content}`, read fail-fast (no fallback to `elasticsearch.url`) | audit |
| **Agent data plane** — named project targets | `[project.<name>]` — a flat table keyed by OS (`linux`/`macos`/`windows`) to an absolute target path; `--scope project` resolves `--project <name>` against these instead of taking a raw `--target`. `<name>` must be a safe slug (alnum + `-`): it flows into a ledger key (dot-delimited, see [Bundles](#bundles)) and an archive filename (dash-delimited). A name declared in both the main config and the overlay is a hard load error | all |

`agent-config` builds the three `/v1/{logs,traces,metrics}` URLs from the telemetry OTLP base. The data-plane key names the actual backing service rather than a generic `otlp` (the architecture is already exposed via the control-plane `elasticsearch.url` / `kibana.url`). Audit details: see [`agent-audit.md`](agent-audit.md).

**Secret values are never in a committed conf.** Each lives only in a gitignored **`agent-config.local.toml`** (covered by `**/agent-config.local.toml`); the committed **`agent-config.local.toml.example`** beside the connection file carries the empty-valued template. The overlay is looked up **beside `agent-config.toml`** by default; `--local-conf <file>` points the CLI at another secrets file (runtime wiring, so it lives on the command line, not in the committed conf — an explicitly named file that is missing is an error, while the absent default is not). Absent default file → empty key, no error. For secrets, the overlay is the same typed vocabulary: only the two `api_key` fields are accepted, and an `api_key` in the committed conf is rejected as an unknown key. Two symmetric secrets:

| Concern | Secret key | Threaded to | Rendered header |
|---|---|---|---|
| Audit | `agent_audit.elasticsearch.api_key` | the audit hook config | (see [`agent-audit.md`](agent-audit.md)) |
| Telemetry | `telemetry.apm_server.api_key` | the rendered telemetry config | `Authorization: ApiKey <key>` on OTLP exports |

For telemetry, Claude sends the header via `OTEL_EXPORTER_OTLP_HEADERS` in the settings `env` block; Codex via the per-exporter `headers` table in `[otel.*.otlp-http]`. When **absent the rendered otel config is byte-identical to a no-key run** — no header line emitted — which suits the local demo APM Server, whose auth is disabled.

## Managed materialize

A managed deploy carries telemetry, hooks, or both, driven by which concerns the `agent-config.toml` declares (a `[telemetry]` and/or an `[agent_audit]` table; a conf with neither fails at load). Three combinations:

| Combination | Driven by | Claude `managed-settings.d/10-agent-observability-lab.json` | Codex |
|---|---|---|---|
| **Telemetry-only** (config-only) | telemetry keys only | `env` (telemetry) only | `managed_config.toml` `[otel]` only |
| **Hooks-only** (audit) | `agent_audit.*` keys only | `_comment` + `hooks` block, **no `env`** | **only `requirements.toml`** (pins `[features].hooks`, hook tables); **no `managed_config.toml`** |
| **Combined** (telemetry + hooks) | both key groups in one conf | `env` + `hooks` | `managed_config.toml` `[otel]` + `requirements.toml` |

- **Config-only files have no scripts to materialize** — Claude's `env` and Codex's `[otel]` are self-contained. Telemetry rendering happens **only** when the OTLP endpoints are present, byte-identical to before.
- **Hooks** materialize the **hook scripts** to a stable host location and point the managed config at them. Codex has a first-class **`managed_dir`**; Claude has **no such convention**, so the lab picks a `hooks/` dir at the managed root (beside `managed-settings.d/`) and must confirm **on a real host** that an absolute hook `command` path works (the macOS space / Windows `Program Files` caveats). For **both** agents the bundle goes one level deeper, into an **owner-scoped** `hooks/<tool>/` — the managed root is machine-global, and two distributions of this tooling would otherwise write the same `hooks/agent-audit.{sh,ps1}` and collide. Fragment names are derived from the same `tool` slug, so one constant governs every owner-scoped path.
- For hooks-only, Codex omits `managed_config.toml` because with no telemetry it would be just a comment.

**Managed marker.** A managed deploy writes the same three-line executor marker as every other scope; `teardown` enumerates every candidate target the config could have placed and treats an unplaced one as a harmless no-op.

## Bundles

`agent-config render --zip` writes the same rendered bundles as **zip archives** instead of a plain tree, one cell per **OS** within the single selected `--scope` (default `local`; every OS the scope makes available, narrowed by an explicit `--os` filter — see the shared OS-candidate filter above), named `<owner>-<agent>[-<name>]-<os>-<scope>-<version>.zip` under `dist/` beside the config (or `--out`) — `name` appears only for `project` cells, immediately after `agent`; the rest is exactly the cell's ledger key (below) with dots replaced by dashes, wrapped in `<owner>-...-<scope>-<version>.zip`. `--zip` takes no `--concern` (archives always carry the full declaration). Versioning: a content-only sha256 **cell hash** (file bytes + relative paths, ordering-stable, version and sha256 sidecar files excluded) is compared against a committed version ledger beside `agent-config.toml`; only changed cells mint a new `YYYYMMDD-NNNN` version (UTC date, next sequence within that cell's ledger file), unchanged cells are skipped (`--all` re-emits them), and stale archives of a re-emitted cell are replaced (matched by the fixed `<owner>-<agent>[-<name>]-<os>-<scope>-` prefix, so two `project` cells sharing an OS under different names never collide). Each archive carries a `<owner>.version` file and a `<owner>.sha256` sidecar — one `sha256(bytes)  relpath` line per rendered file (`sha256sum -c` compatible), built from the same per-file manifest the cell hash is derived from — both placed at the managed root for managed cells, inside the agent home for user-scope cells. `render` is the only code path that ever reads or writes a ledger — for every scope, including `managed`; `place` never touches one.

**Version ledgers.** The ledger is split by scope into three files, each committed beside `agent-config.toml`: `<owner>-managed-versions.conf`, `<owner>-local-versions.conf`, `<owner>-project-versions.conf`. Keys are `.version`/`.hash` pairs: managed and local key by `{agent}.{os}` (e.g. `claude.linux`); project keys by `{agent}.{name}.{os}` (e.g. `claude.server-a.linux`, name before OS) — `name` is the declared `--project <name>` (see [Two config files](#two-config-files--one-per-plane)), not derived from a path.

`local`/`project` placement bakes **absolute target paths** into the rendered content (hook commands, the seal cert path), so those bundles are **target-specific by construction**: a `local` cell bakes the config directory of the machine that cut it, and a `project` cell resolves its target from `--project <name>`; an OS the named target doesn't declare is skipped, loudly (the shared OS-candidate filter — see above). Only `managed` bundles are host-portable — their roots are fixed per OS. All rendered output is LF regardless of the rendering host.

## Sensitive content

Pointing any deployment — a real project via `--scope project`, or a managed host — at the lab backend flows that machine's prompts and tool I/O into the lab's Elasticsearch. That is the point of the lab, but it is also sensitive: don't run secret-bearing sessions against it. This caveat lives here and in `README.md`; the scripts do **not** emit it at runtime.
