# Codex CLI managed configuration

How OpenAI Codex CLI lets an administrator push configuration onto a fleet and
**enforce** a subset of it, while leaving the user's own `config.toml` in effect
wherever it does not conflict. In the lab this surface is driven by the audit
stacks' `setup-config --scope managed` (`--with-hooks`); the shared placement
model is owned by [`config-deployment.md`](config-deployment.md). It is
**Codex-specific**: Claude Code has no
`config.toml` / `requirements.toml` — its org-enforcement surface is
`managed-settings.json` ([`claude-code-managed-config.md`](claude-code-managed-config.md)),
so the mechanics here do **not** carry over (only the *idea* does).

Upstream docs (read these for the authoritative key list — this file is the
distilled model):

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

Two behaviors that drive the lab's hook posture:

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

**Lab hook posture (declared explicitly).** The lab's `requirements.toml` states its hook stance in full rather than by omission: **`allow_managed_hooks_only = false`** — the user's own hooks **coexist**; the lab enforces hook *presence*, not exclusivity — plus **`[features].hooks = true`** (the user cannot disable hooks) and the `managed_dir` / `windows_managed_dir` holding the materialized scripts. The hook **tables are single-sourced** in `templates/hooks.template.toml` and **concatenated** into the rendered `requirements.toml` (top-level fields + `[features]` first, the `[[hooks.*]]` arrays last, so the TOML parses), so the managed-scope and user-scope hook definitions never drift.

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

## Placement in this lab (deploy-only, human-gated)

Managed config is **machine-global, admin-owned, highest-precedence** — it cannot be isolated per-stack with `CODEX_HOME` the way the existing stacks isolate user config. But it does not need a stack of its own: it is an **agent-scoped capability** — templates plus an OS-path-aware placement primitive under `components/agents/<agent>/` — that **any** stack can opt into at setup, regardless of backend (managed config is agent-side; the backend is irrelevant). This placement model is itself agent-agnostic; only the file format, paths, and what is enforceable differ per agent.

It is deliberately a **guarded manual deploy, not part of the automated suite.** Exercising managed config means writing host-global, admin-owned, highest-precedence files that affect **every** agent on the machine and cannot be overridden by a user — too dangerous to drive mechanically. So the lab **does not mechanically verify it**: no verify script, no containerized harness, and **no auto-confirm.** Placement is the deliverable; that enforcement takes effect is confirmed by observation and documented, never by an automated assertion.

Placement is **always interactive:**

- An opt-in (`--scope managed` / a `setup.conf` key) selects the *attempt*; the **confirm itself cannot be bypassed** — there is no `--yes`.
- **Non-TTY / EOF aborts** (never default-yes), so automation (Ralph, CI) can never place managed config even if it reaches the step.
- A permission error **fails loud** — print the path and the privileged/manual command — rather than fail-open (unlike the audit hook: the operator asked for this write, so a failure must be seen).

### Never overwrite; track provenance; provide teardown

Managed config is a host **singleton** per file, and the path may already hold the operator's **real organization's** MDM-pushed managed config. Clobbering that is a real-world security incident, not a lab inconvenience — so the lab **never overwrites a file it does not own.** Placement records a **sidecar provenance marker** beside the managed file (which agent / **OTLP endpoint** / when / target the lab placed it). Ownership is keyed on the **endpoint** — what the host is enforced *toward* — not a stack name (a managed deploy is a host act, not a per-stack one):

| Existing file | Verdict |
| --- | --- |
| none | place after confirm, write the marker |
| lab-placed, same endpoint, same content | no-op (already placed) |
| lab-placed, same endpoint, changed content | update after explicit confirm |
| lab-placed, **different endpoint** | refuse — "this host already enforces &lt;endpoint&gt;; run teardown first" |
| present with **no lab marker** (foreign / real org config) | **hard refuse — never touch it** |

A **teardown script is mandatory** — the counterpart to placement, since a host-global change otherwise persists after the experiment (the machine stays enforced). Teardown removes **only** files the marker confirms the lab placed (restoring the host), **refuses to remove a foreign file**, and is itself interactive + fail-loud (no `--yes`).

### What can actually be enforced (state it honestly)

What a deployed managed layer enforces is **agent-specific and must be stated in the templates and the prompt**: Codex enforces via `requirements.toml` (managed hooks, `allow_managed_hooks_only`, `[features].hooks`; the lab keeps it **hook-scoped** — approval/sandbox-policy enforcement, though Codex supports it, is out of scope for an audit/telemetry tool), but **`[otel]`/telemetry is only a managed *default*** (`managed_config.toml`), never enforceable — and on Windows `managed_config.toml` is a weak boundary, so real enforcement lives in `requirements.toml` at `%ProgramData%`.

This shapes what each managed combination materializes: the audit stacks' hooks-only deploy (`--with-hooks`, no OTLP endpoints) places **only `requirements.toml`** — pinning `[features].hooks = true`, `allow_managed_hooks_only = false`, the `managed_dir` / `windows_managed_dir`, and the hook tables — and **no `managed_config.toml`** (with no telemetry that file would be just a comment). A combined telemetry+hooks deploy adds `managed_config.toml` `[otel]`. The full matrix is in [`config-deployment.md`](config-deployment.md) "Managed materialize".

A **claude-code counterpart** uses `managed-settings.json` — a different mechanism that, unlike Codex's `[otel]`, **can** enforce telemetry; it is documented separately (see the intro) and shares this same deploy-only, human-gated, never-overwrite placement model.
