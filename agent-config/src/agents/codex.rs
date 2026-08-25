use crate::assets;
use crate::config::{Config, Telemetry};
use crate::model::{Cell, Content, Entry, Flavor, Location, Os, Scope, Section};
use crate::seal::SealSource;

pub fn managed_root(os: Os) -> &'static str {
    match os {
        Os::Linux | Os::Macos => "/etc/codex",
        Os::Windows => "C:/ProgramData/OpenAI/Codex",
    }
}

pub fn manifest(
    cfg: &Config,
    cell: &Cell,
    seal: Option<&SealSource>,
) -> Result<Vec<Entry>, String> {
    match cell.scope {
        Scope::Local | Scope::Project => user_entries(cfg, cell, seal),
        Scope::Managed => Ok(managed_entries(cfg, cell, seal)),
    }
}

pub fn teardown_targets(
    executor: &str,
) -> (Vec<(&'static str, String)>, &'static str, &'static str) {
    (
        vec![
            ("config", ".codex/config.toml".to_string()),
            ("agent-audit", ".codex/hooks/agent-audit.conf".to_string()),
            ("agent-audit", ".codex/hooks/recipient.pem".to_string()),
            ("auth", ".codex/auth.json".to_string()),
            ("gitignore", ".codex/.gitignore".to_string()),
            ("version", format!(".codex/{executor}.version")),
            ("sha256", format!(".codex/{executor}.sha256")),
        ],
        ".codex/hooks",
        ".codex/config.toml",
    )
}

pub fn managed_candidates(cfg: &Config, os: Os) -> Vec<(String, String)> {
    let root = managed_root(os);
    let mut candidates = Vec::new();
    if cfg.audit.is_some() {
        candidates.push((
            "requirements".to_string(),
            format!("{root}/requirements.toml"),
        ));
        candidates.extend(crate::agents::claude::hook_candidates(
            &format!("{root}/hooks/{}", cfg.executor),
            os,
        ));
    }
    let managed_config = if os == Os::Windows {
        "%USERPROFILE%/.codex/managed_config.toml".to_string()
    } else {
        format!("{root}/managed_config.toml")
    };
    candidates.push(("managed_config".to_string(), managed_config));
    candidates.push((
        "version".to_string(),
        format!("{root}/{}.version", cfg.executor),
    ));
    candidates.push((
        "sha256".to_string(),
        format!("{root}/{}.sha256", cfg.executor),
    ));
    candidates
}

fn user_entries(
    cfg: &Config,
    cell: &Cell,
    seal: Option<&SealSource>,
) -> Result<Vec<Entry>, String> {
    let target = cell.target()?;
    let mut sections = Vec::new();
    let mut entries = Vec::new();

    if let Some(telemetry) = &cfg.telemetry {
        sections.push(Section {
            sentinel: "[otel]".into(),
            text: otel_section(telemetry),
        });
    }

    if let Some(audit) = &cfg.audit {
        let hooks_dir = format!("{target}/.codex/hooks");
        sections.push(Section {
            sentinel: "[[hooks.UserPromptSubmit]]".into(),
            text: hooks_section(cell.os, &hooks_dir),
        });
        let recipients_file = seal.map(|_| format!("{hooks_dir}/recipient.pem"));
        entries.push(Entry::marked_file(
            "agent-audit",
            Location::InTarget(".codex/hooks/agent-audit.conf".into()),
            crate::agents::render_conf(
                assets::CODEX_AGENT_AUDIT_CONF_TEMPLATE,
                audit,
                recipients_file.as_deref().unwrap_or(""),
                seal.map(|s| s.key_id.as_str()).unwrap_or(""),
            ),
        ));
        if let Some(seal) = seal {
            entries.push(Entry {
                key: "agent-audit".into(),
                location: Location::InTarget(".codex/hooks/recipient.pem".into()),
                content: Content::File {
                    bytes: seal.cert.clone(),
                    executable: false,
                    marked: true,
                },
            });
        }
        entries.extend(hook_asset_entries(cell.os, |rel| {
            Location::InTarget(format!(".codex/hooks/{rel}"))
        }));
    }

    if cell.scope == Scope::Local {
        sections.push(Section {
            sentinel: "[mcp_servers.elasticsearch]".into(),
            text: assets::CODEX_MCP_TEMPLATE.to_string(),
        });
        entries.push(Entry {
            key: "auth".into(),
            location: Location::InTarget(".codex/auth.json".into()),
            content: Content::AuthLink {
                source: home_auth_json(),
            },
        });
    }

    entries.insert(
        0,
        Entry {
            key: "config".into(),
            location: Location::InTarget(".codex/config.toml".into()),
            content: Content::TomlSections(sections),
        },
    );
    entries.push(Entry::marked_file(
        "gitignore",
        Location::InTarget(".codex/.gitignore".into()),
        "*\n".into(),
    ));

    Ok(entries)
}

fn managed_entries(cfg: &Config, cell: &Cell, seal: Option<&SealSource>) -> Vec<Entry> {
    let root = managed_root(cell.os);
    let mut entries = Vec::new();

    if let Some(audit) = &cfg.audit {
        let hooks_root = format!("{root}/hooks/{}", cfg.executor);
        entries.push(Entry::marked_file(
            "requirements",
            Location::Host(format!("{root}/requirements.toml")),
            requirements(cell.os, &hooks_root),
        ));
        let recipients_file = seal.map(|_| format!("{hooks_root}/recipient.pem"));
        entries.push(Entry::marked_file(
            "hook:agent-audit.conf",
            Location::Host(format!("{hooks_root}/agent-audit.conf")),
            crate::agents::render_conf(
                assets::CODEX_AGENT_AUDIT_CONF_TEMPLATE,
                audit,
                recipients_file.as_deref().unwrap_or(""),
                seal.map(|s| s.key_id.as_str()).unwrap_or(""),
            ),
        ));
        if let Some(seal) = seal {
            entries.push(Entry {
                key: "hook:recipient.pem".into(),
                location: Location::Host(format!("{hooks_root}/recipient.pem")),
                content: Content::File {
                    bytes: seal.cert.clone(),
                    executable: false,
                    marked: true,
                },
            });
        }
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
        entries.push(Entry::marked_file(
            "managed_config",
            Location::Host(target),
            [assets::CODEX_MANAGED_CONFIG_TEMPLATE, otel_body].join("\n"),
        ));
    }

    entries
}

fn home_auth_json() -> std::path::PathBuf {
    let home = std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .unwrap_or_default();
    std::path::PathBuf::from(home).join(".codex/auth.json")
}

fn hook_asset_entries(os: Os, location: impl Fn(&str) -> Location) -> impl Iterator<Item = Entry> {
    assets::codex_hooks(os.flavor())
        .into_iter()
        .map(move |asset| Entry {
            key: format!("hook:{}", asset.rel),
            location: location(asset.rel),
            content: Content::File {
                bytes: asset.bytes.to_vec(),
                executable: asset.executable,
                marked: false,
            },
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
