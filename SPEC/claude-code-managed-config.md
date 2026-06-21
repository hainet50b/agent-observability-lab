# Claude Code managed configuration

How Claude Code lets an administrator push and **enforce** configuration onto a fleet. Claude Code has no `config.toml` / `requirements.toml`; its org-enforcement surface is a single `managed-settings.json`. The mechanics here are **Claude-specific** and do not carry over from Codex's two-file model (`SPEC/codex-cli-managed-config.md`) — only the *idea*, and the lab's deploy-only placement model, are shared.

Upstream docs (read these for the authoritative key list — this file is the distilled model):

- Settings & precedence — <https://code.claude.com/docs/en/settings>
- Monitoring / telemetry (`OTEL_*`, `CLAUDE_CODE_ENABLE_TELEMETRY`) — <https://code.claude.com/docs/en/monitoring-usage>

## One authoritative layer (not Codex's defaults/requirements split)

Codex separates *defaults* (`managed_config.toml`, user-overridable) from *requirements* (`requirements.toml`, enforced). Claude Code has **one** managed layer: `managed-settings.json`. It uses the **same JSON schema** as a normal `settings.json`, but at the managed layer it sits at **highest precedence and cannot be overridden** by the user, the project, or CLI flags. So there is no "soft default" tier — whatever is placed in `managed-settings.json` is *enforced*. This makes it simpler than Codex but also blunter: every key here is a hard constraint.

## File paths

| Platform | Path |
| --- | --- |
| macOS | `/Library/Application Support/ClaudeCode/managed-settings.json` |
| Linux / WSL | `/etc/claude-code/managed-settings.json` |
| Windows | `C:\Program Files\ClaudeCode\managed-settings.json` |

All are machine-global, admin-owned, fixed system paths — there is no env var that relocates the managed-settings search path (unlike `CODEX_HOME` for Codex's *user* layer, which never reaches managed anyway). Two deployment gotchas: the Windows path is under **`Program Files`** (writing there needs admin rights) — the legacy **`C:\ProgramData\ClaudeCode\managed-settings.json` is no longer read as of Claude Code v2.1.75**, so a file placed there is silently ignored; and the macOS path contains a **space** (`Application Support`), so any tool that places the file or points a hook `command` at a script beside it must quote paths.

## Precedence

Highest first: **`managed-settings.json`** → CLI arguments → project-local `.claude/settings.local.json` → project-shared `.claude/settings.json` → user `~/.claude/settings.json`. Managed values win on conflict; the user cannot override them, and a managed-registered hook cannot be removed by the user.

## What it can enforce

The full settings schema, at highest precedence — notably:

- **`env`** — environment variables, including **telemetry**: `CLAUDE_CODE_ENABLE_TELEMETRY=1` plus the `OTEL_*` exporters. This is the **key asymmetry with Codex**, whose `[otel]` can only be a managed *default* (never enforced): on Claude Code, **telemetry can be forced on org-wide** and the user cannot turn it off.
- **`permissions`** — `allow` / `deny` / `ask` rules and `defaultMode`, plus guards like `disableBypassPermissionsMode`.
- **`hooks`** — a hook registered here is enforced: it sits at the managed layer, so the user cannot remove or disable *that* hook. **The lab does not make hooks exclusive** — it leaves `allowManagedHooksOnly` at its default (off / `false`) so the user's own hooks still load and merge alongside the managed ones; the only enforcement intended is "the managed hook cannot be turned off," not "only managed hooks may run." (`allowManagedHooksOnly: true` would block all user/project hooks — deliberately *not* used.)

(See the upstream settings doc for the exhaustive key list. Two hook caveats are **not** documented and must be confirmed once on a real host before relying on them: whether a hook `command` accepts an **absolute path** to a script placed outside any project, and how a path with a space/`Program Files` is invoked on each OS.)

## Placement & teardown (shared model)

Placement and removal follow the **same deploy-only, human-gated, never-overwrite model** documented in `SPEC/codex-cli-managed-config.md` "Placement in this lab": an agent-scoped capability any stack opts into, **no mechanical verification**, an **always-interactive** prompt with **no `--yes`** (non-TTY aborts; permission errors fail loud), and the lab **never overwrites a file it does not own** — provenance is tracked by a sidecar marker and a mandatory teardown removes only lab-placed files.

The Claude-specific surface is the **single** `managed-settings.json` at the path above. Because it is one file at the most sensitive location, the "foreign file" safety case is especially pointed: the operator's **real employer may already enforce policy through this exact file**, so a present file with no lab marker is hard-refused and never touched.
