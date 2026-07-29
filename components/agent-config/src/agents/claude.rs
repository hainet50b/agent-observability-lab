use serde_json::{Value, json};

use crate::assets;
use crate::config::{Audit, Config, Telemetry};
use crate::model::{Cell, Entry, Flavor, Location, Os, Scope};
use crate::owner::OWNER;

pub fn managed_root(os: Os) -> &'static str {
    match os {
        Os::Linux => "/etc/claude-code",
        Os::Macos => "/Library/Application Support/ClaudeCode",
        Os::Windows => "C:/Program Files/ClaudeCode",
    }
}

pub fn manifest(cfg: &Config, cell: &Cell) -> Result<Vec<Entry>, String> {
    match cell.scope {
        Scope::Local | Scope::Project => user_entries(cfg, cell),
        Scope::Managed => managed_entries(cfg, cell),
    }
}

fn user_entries(cfg: &Config, cell: &Cell) -> Result<Vec<Entry>, String> {
    let target = cell.target()?;
    let mut settings = serde_json::Map::new();
    let mut entries = Vec::new();

    if let Some(telemetry) = &cfg.telemetry {
        settings.insert("env".into(), otel_env(telemetry, EmptyHeaders::Keep)?);
    }

    if let Some(audit) = &cfg.audit {
        let hooks_dir = format!("{target}/.claude/hooks");
        settings.insert("hooks".into(), hooks_block(cell.os, &hooks_dir)?);
        entries.push(text_entry(
            "agent-audit",
            Location::InTarget(".claude/hooks/agent-audit.conf".into()),
            render_conf(audit, "", ""),
        ));
        entries.extend(hook_asset_entries(cell.os, |rel| {
            Location::InTarget(format!(".claude/hooks/{rel}"))
        }));
    }

    entries.insert(
        0,
        text_entry(
            "settings",
            Location::InTarget(".claude/settings.local.json".into()),
            pretty(&Value::Object(settings)),
        ),
    );
    entries.push(text_entry(
        "gitignore",
        Location::InTarget(".claude/.gitignore".into()),
        "*\n".into(),
    ));

    if cell.scope == Scope::Local {
        let mut mcp: Value = parse_template(assets::MCP_TEMPLATE)?;
        mcp.as_object_mut().unwrap().remove("_comment");
        entries.push(text_entry(
            "mcp",
            Location::InTarget(".mcp.json".into()),
            pretty(&mcp),
        ));
    }

    Ok(entries)
}

fn managed_entries(cfg: &Config, cell: &Cell) -> Result<Vec<Entry>, String> {
    let root = managed_root(cell.os);
    let mut fragment: Value = parse_template(assets::MANAGED_SETTINGS_TEMPLATE)?;
    let mut entries = Vec::new();

    if let Some(telemetry) = &cfg.telemetry {
        fragment["env"] = otel_env(telemetry, EmptyHeaders::Drop)?;
    }

    if let Some(audit) = &cfg.audit {
        let hooks_root = format!("{root}/hooks/{OWNER}");
        fragment["hooks"] = hooks_block(cell.os, &hooks_root)?;
        entries.push(text_entry(
            "hook:agent-audit.conf",
            Location::Host(format!("{hooks_root}/agent-audit.conf")),
            render_conf(audit, "", ""),
        ));
        entries.extend(hook_asset_entries(cell.os, |rel| {
            Location::Host(format!("{hooks_root}/{rel}"))
        }));
    }

    entries.insert(
        0,
        text_entry(
            "managed-settings",
            Location::Host(format!("{root}/managed-settings.d/10-{OWNER}.json")),
            pretty(&fragment),
        ),
    );

    Ok(entries)
}

fn hook_asset_entries(os: Os, location: impl Fn(&str) -> Location) -> impl Iterator<Item = Entry> {
    assets::claude_hooks(os.flavor())
        .into_iter()
        .map(move |asset| Entry {
            key: format!("hook:{}", asset.rel),
            location: location(asset.rel),
            content: asset.bytes.to_vec(),
            executable: asset.executable,
        })
}

fn hooks_block(os: Os, hooks_dir: &str) -> Result<Value, String> {
    let mut template: Value = parse_template(assets::HOOK_TEMPLATE)?;
    for (event, stream) in [
        ("UserPromptSubmit", "user_prompt"),
        ("PostToolUse", "tool_call"),
    ] {
        let hook = &mut template["hooks"][event][0]["hooks"][0];
        match os.flavor() {
            Flavor::Sh => {
                let entry = format!("{hooks_dir}/agent-audit.sh");
                let conf = format!("{hooks_dir}/agent-audit.conf");
                hook["command"] = json!(format!("'{entry}' --stream {stream} --config '{conf}'"));
            }
            Flavor::Ps1 => {
                let entry = format!("{hooks_dir}/agent-audit.ps1").replace('/', "\\");
                let conf = format!("{hooks_dir}/agent-audit.conf").replace('/', "\\");
                hook["command"] = json!("powershell");
                hook["args"] = json!([
                    "-NoProfile",
                    "-NonInteractive",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    entry,
                    "-Stream",
                    stream,
                    "-Config",
                    conf
                ]);
            }
        }
    }
    Ok(template["hooks"].take())
}

enum EmptyHeaders {
    Keep,
    Drop,
}

fn otel_env(telemetry: &Telemetry, policy: EmptyHeaders) -> Result<Value, String> {
    let headers = if telemetry.api_key.is_empty() {
        String::new()
    } else {
        format!("Authorization=ApiKey {}", telemetry.api_key)
    };
    let rendered = assets::OTEL_TEMPLATE
        .replace(
            "@@OTLP_LOGS_ENDPOINT@@",
            &format!("{}/v1/logs", telemetry.endpoint),
        )
        .replace(
            "@@OTLP_TRACES_ENDPOINT@@",
            &format!("{}/v1/traces", telemetry.endpoint),
        )
        .replace(
            "@@OTLP_METRICS_ENDPOINT@@",
            &format!("{}/v1/metrics", telemetry.endpoint),
        )
        .replace("@@OTLP_HEADERS@@", &headers);
    let mut template: Value = parse_template(&rendered)?;
    let mut env = template["env"].take();
    if matches!(policy, EmptyHeaders::Drop) && env["OTEL_EXPORTER_OTLP_HEADERS"] == json!("") {
        env.as_object_mut()
            .unwrap()
            .shift_remove("OTEL_EXPORTER_OTLP_HEADERS");
    }
    Ok(env)
}

fn render_conf(audit: &Audit, seal_recipients_file: &str, seal_key_id: &str) -> String {
    assets::AGENT_AUDIT_CONF_TEMPLATE
        .replace("@@ES_URL@@", &audit.es_url)
        .replace("@@ES_API_KEY@@", &audit.api_key)
        .replace("@@ES_TIMEOUT_MS@@", &audit.timeout_ms)
        .replace(
            "@@CAPTURE_USER_PROMPT_ENABLED@@",
            &audit.user_prompt.enabled,
        )
        .replace(
            "@@CAPTURE_USER_PROMPT_CONTENT@@",
            &audit.user_prompt.content,
        )
        .replace("@@CAPTURE_TOOL_CALL_ENABLED@@", &audit.tool_call.enabled)
        .replace("@@CAPTURE_TOOL_CALL_CONTENT@@", &audit.tool_call.content)
        .replace("@@SEAL_RECIPIENTS_FILE@@", seal_recipients_file)
        .replace("@@SEAL_KEY_ID@@", seal_key_id)
}

fn parse_template(text: &str) -> Result<Value, String> {
    serde_json::from_str(text).map_err(|e| format!("invalid template JSON: {e}"))
}

fn pretty(value: &Value) -> String {
    let mut out = serde_json::to_string_pretty(value).expect("JSON serialization cannot fail");
    out.push('\n');
    out
}

fn text_entry(key: &str, location: Location, content: String) -> Entry {
    Entry {
        key: key.into(),
        location,
        content: content.into_bytes(),
        executable: false,
    }
}
