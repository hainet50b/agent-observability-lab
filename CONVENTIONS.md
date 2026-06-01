# Agent Observability Lab — Conventions

How code is written in this project. Read before implementing.

## Tech Stack

This is an infrastructure / demo repository, not an application codebase. The "code" is container orchestration and glue scripting.

- **Docker + Docker Compose** — every stack is defined as a `docker-compose.yml` and runs with `docker compose up` (the unit of delivery is a running stack, not a binary). Pin image versions explicitly (`image: …:<version>`); never rely on `latest`.
- **POSIX shell (`sh`/`bash`)** — smoke tests, health waits, and verification queries under each stack's `scripts/`. Keep scripts portable and dependency-light (`curl`, `jq`).

## Test Pattern

There is no unit-test framework here. "Tests" are smoke / integration checks written as shell scripts that follow the **3A pattern**:

- **Arrange** — bring the stack up and wait for health.
- **Act** — explicitly perform the action under test (e.g. send telemetry, query an index). The Act step must be visible in the script body, not hidden in a helper.
- **Assert** — verify the outcome (service healthy, expected index exists, documents present) and exit non-zero on failure.

## Lint / Format / Test Commands

The commands below must pass before a task is marked complete in `PRD.md`. Run from the repository root.

```sh
# Validate every stack's compose file (required gate — always available with Docker).
for d in stacks/*/; do (cd "$d" && docker compose config -q); done

# Lint shell scripts if shellcheck is installed (skipped silently if absent).
command -v shellcheck >/dev/null 2>&1 && find stacks -name '*.sh' -print0 | xargs -0 -r shellcheck

# Run any stack smoke tests that exist (each must exit 0).
for f in stacks/*/scripts/smoke-test.sh; do [ -x "$f" ] && "$f"; done
```

## Commit Messages

Subject line: present-imperative, ≤ 72 characters. Body optional and free-form. The implementation LLM has discretion on wording — no template, no enforced prefixes.

## File and Identifier Naming

- Stack directories under `stacks/` are **kebab-case** and name the agent + backend they exercise (e.g. `claude-code-elastic`).
- Within a stack: `docker-compose.yml` at the stack root, service config under `config/`, scripts under `scripts/`, and any importable backend assets in their own dir (e.g. `kibana/` for Kibana saved objects).
- Compose service names are lowercase, matching the component (e.g. `kibana`, `apm-server`).
- Shell scripts are kebab-case with a `.sh` extension (e.g. `smoke-test.sh`).
