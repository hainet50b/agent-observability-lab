# Claude Code managed configuration

How Claude Code lets an administrator push and **enforce** configuration onto a fleet. Claude Code has no `config.toml` / `requirements.toml`; its org-enforcement surface is `managed-settings.json` **plus the `managed-settings.d/` drop-in directory beside it**. The mechanics here are **Claude-specific** and do not carry over from Codex's two-file model (`SPEC/codex-managed-config.md`) — only the *idea*, and the lab's deploy-only placement model, are shared.

Upstream docs (read these for the authoritative key list — this file is the distilled model):

- Settings & precedence — <https://code.claude.com/docs/en/settings>
- Server-managed settings (admin-console delivery) — <https://code.claude.com/docs/en/server-managed-settings>
- Monitoring / telemetry (`OTEL_*`, `CLAUDE_CODE_ENABLE_TELEMETRY`) — <https://code.claude.com/docs/en/monitoring-usage>

## One authoritative tier (not Codex's defaults/requirements split)

Codex separates *defaults* (`managed_config.toml`, user-overridable) from *requirements* (`requirements.toml`, enforced). Claude Code has **one** managed tier. It uses the **same JSON schema** as a normal `settings.json`, but at the managed tier it sits at **highest precedence and cannot be overridden** by the user, the project, or CLI flags. So there is no "soft default" tier — whatever is placed there is *enforced*. This makes it simpler than Codex but also blunter: every key is a hard constraint.

One tier does not mean one file. The tier is delivered over several **mutually exclusive** channels (see [Precedence](#precedence)), and the file channel itself accepts **multiple fragments** (see below).

## File paths

| Platform | Managed root |
| --- | --- |
| macOS | `/Library/Application Support/ClaudeCode/` |
| Linux / WSL | `/etc/claude-code/` |
| Windows | `C:\Program Files\ClaudeCode\` |

Each root holds `managed-settings.json` and the drop-in directory `managed-settings.d/`. All are machine-global, admin-owned, fixed system paths — there is no env var that relocates the managed search path (unlike `CODEX_HOME` for Codex's *user* layer, which never reaches managed anyway). Two deployment gotchas: the Windows path is under **`Program Files`** (writing there needs admin rights) — the legacy **`C:\ProgramData\ClaudeCode\` is no longer read as of Claude Code v2.1.75**, so a file placed there is silently ignored; and the macOS path contains a **space** (`Application Support`), so any tool that places a file or points a hook `command` at a script beside it must quote paths.

## Drop-in fragments (`managed-settings.d/`)

Upstream frames the directory as letting "separate teams deploy independent policy fragments without coordinating edits to a single file" — which is what lets the lab coexist with an organization's own managed policy instead of contending for one file. Merging follows the systemd convention: `managed-settings.json` is merged first as the base, then every `*.json` in `managed-settings.d/` is sorted **alphabetically** and merged on top. **Scalars — later file wins. Arrays — concatenated and de-duplicated. Objects — deep-merged.** Hidden files starting with `.` are ignored.

What that implies for shared ownership of the directory:

- A numeric filename prefix (`10-`, `50-`) is the only ordering control, and it settles **scalar** conflicts only.
- Array-valued keys **union**, so any fragment can widen a `permissions.allow`, `sandbox.network.allowedDomains` or `allowedMcpServers` list another fragment wrote. The managed-only locks (`allowManagedPermissionRulesOnly`, `allowManagedDomainsOnly`, …) separate *managed* from *user/project*; they do **not** rank fragments against each other. Isolation between fragments is write access to the directory plus a key-ownership convention — not a mechanism.
- `hooks` deep-merges and its arrays concatenate, so fragments' hooks **coexist**. This is what makes an audit-hook fragment safe to add beside unrelated org policy.
- `fallbackModel` is the documented exception: it does not merge — the highest-precedence file defining it supplies the entire chain.
- **Every `*.json` in the directory is loaded as policy.** The lab's sidecar provenance marker is `<target>.managed`; inside this directory that suffix is load-bearing, not merely descriptive.

## Precedence

Highest first: **the managed tier** → CLI arguments → project-local `.claude/settings.local.json` → project-shared `.claude/settings.json` → user `~/.claude/settings.json`. Managed values win on conflict; the user cannot override them, and a managed-registered hook cannot be removed by the user.

Inside the managed tier the delivery channels do **not** merge. Server-managed settings (pushed from the claude.ai admin console at sign-in) are consulted first, and if they deliver **any** keys at all, every endpoint-managed source is ignored — MDM policies, `managed-settings.json`, and the whole `managed-settings.d/` directory alike. A configured `policyHelper` preempts all of them. So a fleet whose organization drives Claude Code from the admin console cannot also be configured through the lab's fragment: the two are mutually exclusive, and the loss is silent.

## What it can enforce

The full settings schema, at highest precedence — notably:

- **`env`** — environment variables, including **telemetry**: `CLAUDE_CODE_ENABLE_TELEMETRY=1` plus the `OTEL_*` exporters. This is the **key asymmetry with Codex**, whose `[otel]` can only be a managed *default* (never enforced): on Claude Code, **telemetry can be forced on org-wide** and the user cannot turn it off.
- **`permissions`** — `allow` / `deny` / `ask` rules and `defaultMode`, plus guards like `disableBypassPermissionsMode`.
- **`hooks`** — a hook registered here is enforced: it sits at the managed layer, so the user cannot remove or disable *that* hook. **The lab does not make hooks exclusive** — it leaves `allowManagedHooksOnly` at its default (off / `false`) so the user's own hooks still load and merge alongside the managed ones; the only enforcement intended is "the managed hook cannot be turned off," not "only managed hooks may run." (`allowManagedHooksOnly: true` would block all user/project hooks — deliberately *not* used.)

(See the upstream settings doc for the exhaustive key list. Two hook caveats are **not** documented and must be confirmed once on a real host before relying on them: whether a hook `command` accepts an **absolute path** to a script placed outside any project, and how a path with a space/`Program Files` is invoked on each OS.)

## Placement & teardown (shared model)

Placement and removal follow the **same deploy-only, human-gated, never-overwrite model** documented in `SPEC/config-deployment.md` "Managed placement": an agent-scoped capability any stack opts into, **no mechanical verification**, an **always-interactive** prompt with **no `--yes`** (non-TTY aborts; permission errors fail loud), and the lab **never overwrites a file it does not own** — provenance is tracked by a sidecar marker and a mandatory teardown removes only lab-placed files.

The Claude-specific surface is a single **drop-in fragment**, `managed-settings.d/10-agent-observability-lab.json`, under the managed root above; the lab never targets `managed-settings.json` itself. The hook bundle it registers lives in the matching owner-scoped `hooks/agent-observability-lab/` — both names come from the config's declared `executor`, so nothing this repo writes into a machine-global root shares a path with another distribution of the same tooling. That is what lets a host already enforced by the operator's **real organization** accept the lab's fragment without contention. The trade is that the singleton no longer acts as a tripwire: a foreign `managed-settings.json`, and any other fragment in the directory, is neither inspected nor refused, because the marker check covers only the lab's own target. The never-overwrite guarantee still holds for that target — the "this host is already enforced, stop" signal does not.

Teardown removes the fragment and its marker, then prunes `managed-settings.d/` only when it is left empty, so another owner's fragment keeps the directory alive.
