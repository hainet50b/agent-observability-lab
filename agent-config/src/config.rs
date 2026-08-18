use std::fs;
use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::model::Concern;

pub const DEFAULT_OVERLAY: &str = "agent-config.local.toml";
pub const DEFAULT_EXECUTOR: &str = "agent-config";

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ConfFile {
    agent_config: Option<AgentConfigFile>,
    telemetry: Option<TelemetryFile>,
    agent_audit: Option<AuditFile>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct AgentConfigFile {
    executor: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct TelemetryFile {
    apm_server: ApmServerFile,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ApmServerFile {
    endpoint: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct AuditFile {
    elasticsearch: ElasticsearchFile,
    capture: CaptureFile,
    seal: Option<SealFile>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ElasticsearchFile {
    url: String,
    timeout_ms: u64,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct CaptureFile {
    user_prompt: Capture,
    tool_call: Capture,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct SealFile {
    epoch: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct OverlayFile {
    telemetry: Option<TelemetryOverlay>,
    agent_audit: Option<AuditOverlay>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct TelemetryOverlay {
    apm_server: ApiKeyFile,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct AuditOverlay {
    elasticsearch: ApiKeyFile,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ApiKeyFile {
    api_key: String,
}

#[derive(Debug, Deserialize, Clone, Copy)]
#[serde(deny_unknown_fields)]
pub struct Capture {
    pub enabled: bool,
    pub content: Content,
}

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Content {
    Plaintext,
    Redacted,
    Encrypted,
}

impl Content {
    pub fn as_str(self) -> &'static str {
        match self {
            Content::Plaintext => "plaintext",
            Content::Redacted => "redacted",
            Content::Encrypted => "encrypted",
        }
    }
}

#[derive(Debug)]
pub struct Telemetry {
    pub endpoint: String,
    pub api_key: String,
}

#[derive(Debug)]
pub struct Audit {
    pub es_url: String,
    pub api_key: String,
    pub timeout_ms: u64,
    pub user_prompt: Capture,
    pub tool_call: Capture,
    pub seal_epoch: String,
}

#[derive(Debug)]
pub struct Config {
    pub executor: String,
    pub telemetry: Option<Telemetry>,
    pub audit: Option<Audit>,
}

impl Config {
    pub fn load(path: &Path, local_conf: Option<&Path>) -> Result<Config, String> {
        let text = fs::read_to_string(path)
            .map_err(|_| format!("config file not found: {}", path.display()))?;
        let file: ConfFile =
            toml::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))?;

        let executor = match file.agent_config {
            Some(a) => {
                require(path, "agent_config.executor", &a.executor)?;
                a.executor
            }
            None => DEFAULT_EXECUTOR.into(),
        };

        let mut telemetry = file
            .telemetry
            .map(|t| -> Result<Telemetry, String> {
                require(
                    path,
                    "telemetry.apm_server.endpoint",
                    &t.apm_server.endpoint,
                )?;
                Ok(Telemetry {
                    endpoint: t.apm_server.endpoint,
                    api_key: String::new(),
                })
            })
            .transpose()?;

        let mut audit = file
            .agent_audit
            .map(|a| -> Result<Audit, String> {
                require(path, "agent_audit.elasticsearch.url", &a.elasticsearch.url)?;
                Ok(Audit {
                    es_url: a.elasticsearch.url,
                    api_key: String::new(),
                    timeout_ms: a.elasticsearch.timeout_ms,
                    user_prompt: a.capture.user_prompt,
                    tool_call: a.capture.tool_call,
                    seal_epoch: a.seal.map(|s| s.epoch).unwrap_or_default(),
                })
            })
            .transpose()?;

        if telemetry.is_none() && audit.is_none() {
            return Err(format!(
                "{}: declares neither a [telemetry] nor an [agent_audit] table",
                path.display()
            ));
        }

        let overlay = match local_conf {
            Some(overlay) => overlay.to_path_buf(),
            None => conf_dir(path).join(DEFAULT_OVERLAY),
        };
        match fs::read_to_string(&overlay) {
            Ok(text) => {
                let file: OverlayFile =
                    toml::from_str(&text).map_err(|e| format!("{}: {e}", overlay.display()))?;
                if let Some(t) = telemetry.as_mut()
                    && let Some(o) = file.telemetry
                {
                    t.api_key = o.apm_server.api_key;
                }
                if let Some(a) = audit.as_mut()
                    && let Some(o) = file.agent_audit
                {
                    a.api_key = o.elasticsearch.api_key;
                }
            }
            Err(_) if local_conf.is_some() => {
                return Err(format!("--local-conf not found: {}", overlay.display()));
            }
            Err(_) => {}
        }

        Ok(Config {
            executor,
            telemetry,
            audit,
        })
    }

    pub fn retain_concerns(&mut self, concerns: &[Concern]) -> Result<(), String> {
        if concerns.is_empty() {
            return Ok(());
        }
        for &concern in concerns {
            let declared = match concern {
                Concern::Telemetry => self.telemetry.is_some(),
                Concern::Audit => self.audit.is_some(),
            };
            if !declared {
                return Err(format!(
                    "--concern {} requested but the config declares no {} table",
                    concern.name(),
                    match concern {
                        Concern::Telemetry => "[telemetry]",
                        Concern::Audit => "[agent_audit]",
                    }
                ));
            }
        }
        if !concerns.contains(&Concern::Telemetry) {
            self.telemetry = None;
        }
        if !concerns.contains(&Concern::Audit) {
            self.audit = None;
        }
        Ok(())
    }
}

pub fn conf_dir(config: &Path) -> PathBuf {
    config
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."))
        .to_path_buf()
}

fn require(path: &Path, key: &str, value: &str) -> Result<(), String> {
    if value.is_empty() {
        return Err(format!("{}: '{key}' is empty", path.display()));
    }
    Ok(())
}
