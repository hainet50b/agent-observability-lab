use std::fs;
use std::path::Path;

use crate::model::Scope;

pub struct Telemetry {
    pub endpoint: String,
    pub api_key: String,
}

pub struct Capture {
    pub enabled: String,
    pub content: String,
}

pub struct Seal {
    pub epoch: String,
    pub recipients_file: String,
}

pub struct Audit {
    pub es_url: String,
    pub api_key: String,
    pub timeout_ms: String,
    pub user_prompt: Capture,
    pub tool_call: Capture,
    pub seal: Seal,
}

pub struct Config {
    pub telemetry: Option<Telemetry>,
    pub audit: Option<Audit>,
}

impl Config {
    pub fn load(path: &Path) -> Result<Config, String> {
        let text = fs::read_to_string(path)
            .map_err(|_| format!("config file not found: {}", path.display()))?;
        let pairs = parse_pairs(&text);
        let get = |key: &str| last_value(&pairs, key);

        let mut telemetry = match get("telemetry.apm_server.endpoint") {
            Some(endpoint) if !endpoint.is_empty() => Some(Telemetry {
                endpoint,
                api_key: String::new(),
            }),
            _ => None,
        };

        let mut audit = if pairs.iter().any(|(k, _)| k.starts_with("agent_audit.")) {
            let require = |key: &str| {
                get(key)
                    .filter(|v| !v.is_empty())
                    .ok_or_else(|| format!("{}: missing or empty key '{key}'.", path.display()))
            };
            Some(Audit {
                es_url: require("agent_audit.elasticsearch.url")?,
                api_key: String::new(),
                timeout_ms: require("agent_audit.elasticsearch.timeout_ms")?,
                user_prompt: Capture {
                    enabled: require("agent_audit.capture.user_prompt.enabled")?,
                    content: require("agent_audit.capture.user_prompt.content")?,
                },
                tool_call: Capture {
                    enabled: require("agent_audit.capture.tool_call.enabled")?,
                    content: require("agent_audit.capture.tool_call.content")?,
                },
                seal: Seal {
                    epoch: get("agent_audit.seal.epoch").unwrap_or_default(),
                    recipients_file: get("agent_audit.seal.recipients_file").unwrap_or_default(),
                },
            })
        } else {
            None
        };

        if telemetry.is_none() && audit.is_none() {
            return Err(format!(
                "{}: declares neither telemetry.apm_server.endpoint nor agent_audit.* keys",
                path.display()
            ));
        }

        let overlay = path.with_file_name("setup.local.conf");
        if let Ok(text) = fs::read_to_string(&overlay) {
            let pairs = parse_pairs(&text);
            if let Some(t) = telemetry.as_mut()
                && let Some(v) = last_value(&pairs, "telemetry.apm_server.api_key")
            {
                t.api_key = v;
            }
            if let Some(a) = audit.as_mut()
                && let Some(v) = last_value(&pairs, "agent_audit.elasticsearch.api_key")
            {
                a.api_key = v;
            }
        }

        Ok(Config { telemetry, audit })
    }

    pub fn marker_endpoint(&self, scope: Scope) -> String {
        match scope {
            Scope::Managed => format!(
                "telemetry={};audit={}",
                self.telemetry
                    .as_ref()
                    .map(|t| format!("{}/v1/logs", t.endpoint))
                    .unwrap_or_default(),
                self.audit
                    .as_ref()
                    .map(|a| a.es_url.clone())
                    .unwrap_or_default()
            ),
            Scope::Local | Scope::Project => match (&self.telemetry, &self.audit) {
                (Some(t), None) => t.endpoint.clone(),
                (None, Some(a)) => a.es_url.clone(),
                _ => format!(
                    "telemetry={};audit={}",
                    self.telemetry
                        .as_ref()
                        .map(|t| t.endpoint.clone())
                        .unwrap_or_default(),
                    self.audit
                        .as_ref()
                        .map(|a| a.es_url.clone())
                        .unwrap_or_default()
                ),
            },
        }
    }
}

fn parse_pairs(text: &str) -> Vec<(String, String)> {
    text.lines()
        .filter_map(|line| line.trim_end_matches('\r').split_once('='))
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

fn last_value(pairs: &[(String, String)], key: &str) -> Option<String> {
    pairs
        .iter()
        .rev()
        .find(|(k, _)| k == key)
        .map(|(_, v)| v.clone())
}
