pub mod claude;
pub mod codex;

use crate::config::{Audit, Config};
use crate::model::{Agent, Cell, Entry};
use crate::seal::SealSource;

pub fn manifest(
    cfg: &Config,
    cell: &Cell,
    seal: Option<&SealSource>,
) -> Result<Vec<Entry>, String> {
    match cell.agent {
        Agent::Claude => claude::manifest(cfg, cell, seal),
        Agent::Codex => codex::manifest(cfg, cell, seal),
    }
}

pub(crate) fn render_conf(
    template: &str,
    audit: &Audit,
    seal_recipients_file: &str,
    seal_key_id: &str,
) -> String {
    template
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
