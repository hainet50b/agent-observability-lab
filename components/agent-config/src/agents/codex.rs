use crate::assets;
use crate::config::{Config, Telemetry};
use crate::model::{Cell, Entry, Flavor, Location, Os, Scope};
use crate::owner::OWNER;

pub fn managed_root(os: Os) -> &'static str {
    match os {
        Os::Linux | Os::Macos => "/etc/codex",
        Os::Windows => "C:/ProgramData/OpenAI/Codex",
    }
}

pub fn manifest(cfg: &Config, cell: &Cell) -> Result<Vec<Entry>, String> {
    match cell.scope {
        Scope::Local | Scope::Project => user_entries(cfg, cell),
        Scope::Managed => Ok(managed_entries(cfg, cell)),
    }
}

fn user_entries(cfg: &Config, cell: &Cell) -> Result<Vec<Entry>, String> {
    let target = cell.target()?;
    let mut sections = Vec::new();
    let mut entries = Vec::new();

    if let Some(telemetry) = &cfg.telemetry {
        sections.push(otel_section(telemetry));
    }

    if let Some(audit) = &cfg.audit {
        sections.push(hooks_section(cell.os, &format!("{target}/.codex/hooks")));
        entries.push(Entry::text(
            "agent-audit",
            Location::InTarget(".codex/hooks/agent-audit.conf".into()),
            crate::agents::render_conf(assets::CODEX_AGENT_AUDIT_CONF_TEMPLATE, audit, "", ""),
        ));
        entries.extend(hook_asset_entries(cell.os, |rel| {
            Location::InTarget(format!(".codex/hooks/{rel}"))
        }));
    }

    if cell.scope == Scope::Local {
        sections.push(assets::CODEX_MCP_TEMPLATE.to_string());
    }

    entries.insert(
        0,
        Entry::text(
            "config",
            Location::InTarget(".codex/config.toml".into()),
            sections.join("\n"),
        ),
    );
    entries.push(Entry::text(
        "gitignore",
        Location::InTarget(".codex/.gitignore".into()),
        "*\n".into(),
    ));

    Ok(entries)
}

fn managed_entries(cfg: &Config, cell: &Cell) -> Vec<Entry> {
    let root = managed_root(cell.os);
    let mut entries = Vec::new();

    if let Some(audit) = &cfg.audit {
        let hooks_root = format!("{root}/hooks/{OWNER}");
        entries.push(Entry::text(
            "requirements",
            Location::Host(format!("{root}/requirements.toml")),
            requirements(cell.os, &hooks_root),
        ));
        entries.push(Entry::text(
            "hook:agent-audit.conf",
            Location::Host(format!("{hooks_root}/agent-audit.conf")),
            crate::agents::render_conf(assets::CODEX_AGENT_AUDIT_CONF_TEMPLATE, audit, "", ""),
        ));
        entries.extend(hook_asset_entries(cell.os, |rel| {
            Location::Host(format!("{hooks_root}/{rel}"))
        }));
    }

    if let Some(telemetry) = &cfg.telemetry {
        let target = if cell.os == Os::Windows {
            "%USERPROFILE%/.codex/managed_config.toml".to_string()
        } else {
            format!("{root}/managed_config.toml")
        };
        let otel = otel_section(telemetry);
        let otel_body = &otel[otel
            .find("[otel]")
            .expect("otel template carries an [otel] table")..];
        entries.push(Entry::text(
            "managed_config",
            Location::Host(target),
            [assets::CODEX_MANAGED_CONFIG_TEMPLATE, otel_body].join("\n"),
        ));
    }

    entries
}

fn hook_asset_entries(os: Os, location: impl Fn(&str) -> Location) -> impl Iterator<Item = Entry> {
    assets::codex_hooks(os.flavor())
        .into_iter()
        .map(move |asset| Entry {
            key: format!("hook:{}", asset.rel),
            location: location(asset.rel),
            content: asset.bytes.to_vec(),
            executable: asset.executable,
        })
}

fn hooks_section(os: Os, hooks_dir: &str) -> String {
    let (sh, ps1, conf) = match os.flavor() {
        Flavor::Sh => (
            format!("{hooks_dir}/agent-audit.sh"),
            format!("{hooks_dir}/agent-audit.ps1"),
            format!("{hooks_dir}/agent-audit.conf"),
        ),
        Flavor::Ps1 => {
            let dir = hooks_dir.replace('/', "\\");
            (
                format!("{dir}\\agent-audit.sh"),
                format!("{dir}\\agent-audit.ps1"),
                format!("{dir}\\agent-audit.conf"),
            )
        }
    };
    assets::CODEX_HOOKS_TEMPLATE
        .replace("@@AGENT_AUDIT_SH@@", &sh)
        .replace("@@AGENT_AUDIT_PS1@@", &ps1)
        .replace("@@AGENT_AUDIT_CONF@@", &conf)
}

fn requirements(os: Os, hooks_root: &str) -> String {
    let (dropped_key, placeholder, dir) = match os.flavor() {
        Flavor::Sh => (
            "windows_managed_dir = ",
            "@@MANAGED_DIR@@",
            hooks_root.to_string(),
        ),
        Flavor::Ps1 => (
            "managed_dir = ",
            "@@WINDOWS_MANAGED_DIR@@",
            hooks_root.replace('/', "\\"),
        ),
    };
    let kept: Vec<&str> = assets::CODEX_REQUIREMENTS_TEMPLATE
        .lines()
        .filter(|line| !line.starts_with(dropped_key))
        .collect();
    let requirements = (kept.join("\n") + "\n").replace(placeholder, &dir);
    [requirements, hooks_section(os, hooks_root)].join("\n")
}

fn otel_section(telemetry: &Telemetry) -> String {
    let headers = if telemetry.api_key.is_empty() {
        String::new()
    } else {
        format!(" Authorization = \"ApiKey {}\" ", telemetry.api_key)
    };
    assets::CODEX_OTEL_TEMPLATE
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
        .replace("@@OTLP_HEADERS@@", &headers)
}
