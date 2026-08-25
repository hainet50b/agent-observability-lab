# Agent Observability Lab — Conventions

How code is written in this project. Read before implementing.

## Tech Stack

This is an infrastructure / demo repository, not an application codebase. The "code" is container orchestration and glue scripting.

- **Docker + Docker Compose** — the backend is defined as a `docker-compose.yml` per family and runs with `docker compose up` (the unit of delivery is a running backend, not a binary). Pin image versions explicitly (`image: …:<version>`); never rely on `latest`.
- **Rust (`agent-config/`)** — the config renderer/deployer CLI. Built and run via `cargo run` (a Rust toolchain is assumed; no prebuilt binaries). Keep it `cargo fmt`-formatted, `cargo clippy`-clean, and covered by `cargo test` (golden fixtures pin the rendered bytes).
- **POSIX shell (`sh`/`bash`)** — the operational checks under `backends/elastic/` (`smoke-test.sh`, `verify-*`), plus the runtime audit hooks under `agents/*/hooks/`. Keep scripts portable and dependency-light (`curl`, `jq`); `shfmt`-formatted and `shellcheck`-clean. (Backend provisioning is espalier's: thin `provision.{sh,ps1}` wrappers plus generated `provision-standalone.{sh,ps1}` — regenerate the latter with `espalier render-script` when assets change, never edit them.)
- **PowerShell (`pwsh`)** — each `.sh` script ships a `.ps1` mirror with identical behaviour for Windows hosts; keep the pair in sync and `PSScriptAnalyzer`-clean. `.ps1` files carry **no shebang**: PowerShell does not honour one, these scripts are always invoked via `powershell`/`pwsh -File` or `&` (never executed directly), and a `#!/usr/bin/env pwsh` line both is dead and misleadingly implies a PS7 requirement where Windows fleets run `powershell.exe` (5.1).

## Comments and leanness

**Leanness comes first, so a comment is the exception, not the habit** — be deliberately conservative about adding one, and prefer to let the code or config speak for itself rather than annotate it. The default is no comment.

Aim for code and scripts that are **self-explanatory so a comment is unnecessary** — clear names and obvious structure carry the meaning. Reach for a comment only when the code genuinely cannot: a non-obvious **why** (a constraint, a gotcha, a deliberate deviation), never to restate the **what** the code already shows.

Keep every artifact **as lean as possible so its load-bearing parts stand out** — cut incidental scaffolding and decorative or drive-by comments that bury (and drift from) the essential lines, so a reader can see at a glance which code actually does the work. This applies doubly to generated / rendered artifacts and data files (rendered configs, saved-object NDJSON, a JSON template's `_comment`): a comment baked into a template propagates into every rendered output and into users' files. Keep durable rationale at its single source — the template once, or `SPEC/` — never copied across artifacts.

## Test Pattern

The Rust crate carries real unit / golden tests (`cargo test`); everything else is smoke / integration checks written as shell scripts that follow the **3A pattern**:

- **Arrange** — bring the backend up and wait for health.
- **Act** — explicitly perform the action under test (e.g. send telemetry, query an index). The Act step must be visible in the script body, not hidden in a helper.
- **Assert** — verify the outcome (service healthy, expected index exists, documents present) and exit non-zero on failure.

## Pass Gate

`.ralph/gate.sh` / `.ralph/gate.ps1` are the executable, authoritative pass gate — a change must pass it before commit, and Ralph re-runs it at integration. They are the single source for the actual commands; don't duplicate command blocks here, read/edit the scripts directly when the checks change.

- **Compose validate** — always runs (`docker compose ... config -q` per backend).
- **Rust suite** (`agent-config/`) — `cargo fmt --check` / `clippy` / `test`; runs only when `agent-config/` changed.
- **Shell / PowerShell lint** — `shfmt -d` / `shellcheck` / `PSScriptAnalyzer`; always runs when the tools are installed.
- **Backend smoke test** — `backends/elastic/smoke-test.sh`; runs only when `backends/elastic/` changed (a SKIP from an unreachable daemon counts as failure on such a change, not a pass).

While implementing, fix findings with the mutating forms — `cargo fmt` (no `--check`), `shfmt -w`, PowerShell's `Invoke-Formatter` — then re-run the gate, which stays check-only.

The `backends/elastic/verify-*` scripts are manual tools, not part of the gate: each exercises a **placed** workbench (pass its directory, or set `AOL_WORKBENCH`) end to end against the live backend.

## Commit Messages

Subject line: present-imperative, ≤ 72 characters. Body optional and free-form. The implementation LLM has discretion on wording — no template, no enforced prefixes.

## File and Identifier Naming

- Backend families under `backends/` are **kebab-case** (e.g. `elastic`); within one, each service fragment dir holds its `docker-compose.yml`, service config, and the assets that service consumes.
- Compose service names are lowercase, matching the service (e.g. `kibana`, `apm-server`).
- Shell scripts are kebab-case with a `.sh` extension (e.g. `smoke-test.sh`).
