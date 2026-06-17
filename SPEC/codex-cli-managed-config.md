# Codex CLI managed configuration

How OpenAI Codex CLI lets an administrator push configuration onto a fleet and
**enforce** a subset of it, while leaving the user's own `config.toml` in effect
wherever it does not conflict. This is the reference for the lab's two planned
managed-config validation stacks. It is **Codex-specific**: Claude Code has no
`config.toml` / `requirements.toml` — its org-enforcement surface is
`managed-settings.json`, so the mechanics here do **not** carry over to a
future `claude-code-*` managed stack (only the *idea* does).

Upstream docs (read these for the authoritative key list — this file is the
distilled model and the lab's validation plan):

- Managed configuration — <https://developers.openai.com/codex/enterprise/managed-configuration>
- Advanced configuration (`[otel]`, hooks) — <https://developers.openai.com/codex/config-advanced>
- Configuration reference (`requirements.toml` keys) — <https://developers.openai.com/codex/config-reference>
- Hooks — <https://developers.openai.com/codex/hooks>

## The three layers

Codex resolves configuration from several layers. Three of them are
admin-owned. The crucial distinction for our use case is **defaults** (pushed,
but user-overridable) vs **requirements** (hard constraints the user cannot
bypass).

| Layer | File / source | Nature | User override |
| --- | --- | --- | --- |
| **Managed defaults** | `managed_config.toml` | Starting values applied at launch; re-applied every start | **Yes** — user may change in-session; reverts next launch |
| **Requirements** | `requirements.toml` | Enforced constraints; a conflicting user value is dropped to a compatible one **and the user is notified** | **No** |
| **Cloud requirements** | ChatGPT admin console (Business/Enterprise) | Same format/keys as `requirements.toml`, delivered by sign-in rather than a file | **No** |

So the brief — "push OTLP + hook config by MDM, enforce it, but keep the user's
non-conflicting `config.toml` valid" — maps directly: **put what must be
enforced in `requirements.toml` (or cloud requirements); put pushed-but-soft
defaults in `managed_config.toml`.** A user `config.toml` setting that does not
violate a requirement stays in effect.

## File paths

| Platform | Managed defaults | Requirements |
| --- | --- | --- |
| Linux / macOS | `/etc/codex/managed_config.toml` | `/etc/codex/requirements.toml` |
| Windows | `~/.codex/managed_config.toml` | `%ProgramData%\OpenAI\Codex\requirements.toml` |
| macOS MDM (`com.openai.codex`) | key `config_toml_base64` | key `requirements_toml_base64` |

## Precedence

Configuration resolution, highest first: macOS MDM managed preferences →
system managed files (`/etc/codex` or the Windows paths) → user `config.toml` →
CLI `--config` flags. Managed layers set the starting point, so each run begins
from managed defaults even when the user passes local flags.

Requirements resolution, first match wins per setting: **cloud requirements →
MDM `requirements_toml_base64` → system `requirements.toml`**.

### What `requirements.toml` can enforce

Security-sensitive settings only — e.g. `allowed_approval_policies`,
`allowed_sandbox_modes`, `allowed_permission_profiles`,
`allowed_approvals_reviewers`, `allowed_web_search_modes`, `[features]`,
`[rules]`, `[mcp_servers]`, `[permissions.filesystem]`, `[experimental_network]`,
`[[remote_sandbox_config]]`, `guardian_policy_config`, and **managed hooks**.

**`[otel]` is not in this set.** OTLP/telemetry can be pushed as a *managed
default* (`managed_config.toml`) but cannot be *enforced* via requirements.
Treat telemetry as "defaulted, not enforced" on the local-file layers.

## Hooks across layers

Hooks use **one schema** across every layer; only the delivery format and the
managed-only wrapper fields differ:

- **User / project / session**: a sidecar `hooks.json` (JSON) under `CODEX_HOME`,
  **or** inline `[[hooks.<Event>]]` / `[[hooks.<Event>.hooks]]` tables in
  `config.toml`. The per-hook table body is **identical** to what goes in
  `requirements.toml` — TOML is the shared form, which is why the lab authors
  hooks as TOML (see the migration task in `PRD.md`).
- **Managed**: `[[hooks.<Event>]]` tables in `requirements.toml` (or a managed
  config layer), plus managed-only top-level fields:
  - `managed_dir` / `windows_managed_dir` — directory holding the hook
    **scripts**. Codex validates the path is absolute and exists; it does **not**
    distribute the scripts — MDM/endpoint tooling delivers them there.
  - `allow_managed_hooks_only = true` — skip user/project/session/plugin hooks,
    load only managed hooks. **Only honored in `requirements.toml`** (a no-op in
    `config.toml`). This is the switch that makes managed hooks *exclusive*.

Two behaviors that drive the validation matrix:

- **Sources merge, not replace.** Managed hooks are *added* to user hooks unless
  `allow_managed_hooks_only = true`. Proving "managed-only" therefore requires
  that flag, not merely the presence of a managed hook.
- **Hooks are on by default** and can be disabled with `[features] hooks = false`;
  pin `[features].hooks = true` in `requirements.toml` to stop a user disabling
  them.
- If a single layer carries **both** `hooks.json` and inline `[hooks]`, Codex
  merges them and **warns at startup** — keep one representation per layer.

Managed hooks are marked managed/trusted and cannot be disabled from the user
hook browser.

## Windows: `managed_config.toml` is a weak boundary

`managed_config.toml` on Windows lives at `~/.codex/managed_config.toml` —
user-writable space — and `CODEX_HOME` relocates the user-level directory.
There is **no documented env var to relocate the managed-config search path.**
So on Windows the *defaults* layer is, by design, only a default: a user can
sidestep it. Real enforcement comes from `requirements.toml` at
`%ProgramData%\OpenAI\Codex\requirements.toml` — a fixed system path, not under
`CODEX_HOME`, write-protected from standard users — and, above it, cloud
requirements (no local file at all). **Anything that must be enforced on
Windows belongs in requirements, not managed defaults.**

## Cloud requirements (Business / Enterprise)

Configured at `https://chatgpt.com/codex/settings/managed-configs` using the
same format/keys as `requirements.toml`, delivered by ChatGPT sign-in (CLI, app,
IDE). Best-effort with a local, auth-bound cache: Codex uses a valid unexpired
cache entry, else fetches (with retries); if the fetch fails it continues
**without** the managed-requirements layer. Admins assign requirements
per user group (**first matching group wins**; later groups do not fill unset
fields) with a default fallback policy. This is the only enforcement path that
survives `CODEX_HOME` changes and local-file tampering, since it is not a file.
Out of scope for the lab's local-layer validation; documented here for
completeness.

## Validation design in this lab

Managed config is **machine-global and admin-owned** — it cannot be isolated
per-stack with `CODEX_HOME` the way the existing stacks isolate user config. It
also splits across the two backends the way telemetry and audit already do, so
it is validated as **two backend-transparent stacks** rather than one (and not
by copying managed config into every existing stack — they would collide on the
single machine-global managed layer and need admin to write it):

| Stack | Backend | Validates | Proof of effect |
| --- | --- | --- | --- |
| `codex-cli-requirements` | `elastic-audit` (hook → ES) | `requirements.toml`: managed-hook enforcement, `allow_managed_hooks_only`, `[features].hooks` pin, conflict fallback+notify | audit hooks land in `logs-agent_audit.*` while a competing user `hooks.json` does **not** fire |
| `codex-cli-managed-config` | `elastic` (APM `:8200`) | `managed_config.toml`: `[otel]` defaults applied, and user `config.toml` overriding them | telemetry lands via the already-proven OTLP path; user override changes the effective endpoint |

`[otel]` cannot be validated on `elastic-audit` (no APM/OTLP receiver), so the
managed-defaults/OTel concern sits on the `elastic` backend where the OTLP path
already exists and is smoke-tested; the requirements/hook concern stays on
`elastic-audit`. The OTLP pipeline itself is already proven by
`codex-cli-elastic` — the managed-config stack only adds proof that the **managed
default** is the effective value and that a user override wins where allowed
(ideally read from Codex's effective-config output; confirm such output exists as
the first implementation step, else fall back to observing emission/landing).

Each stack is validated in two phases, since no env var isolates the managed
layer:

- **Phase A — semantics (containerized).** Run Codex inside an ephemeral
  container so `/etc/codex/{managed_config,requirements}.toml` and `managed_dir`
  are container-scoped — no host pollution, real per-stack isolation. Seed a
  deliberately-conflicting user layer to observe fallback+notify and the
  `allow_managed_hooks_only` skip.
- **Phase B — real-OS deployment.** Render to the actual system paths
  (Windows `%ProgramData%`, Linux `/etc/codex`). Admin-only, machine-global,
  not isolated — run deliberately with a documented cleanup; re-run the same
  assertions to confirm real-deployment behavior.

A `claude-code` counterpart is expected later via `managed-settings.json` (a
different mechanism — see the intro).
