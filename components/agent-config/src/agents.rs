pub mod claude;

use crate::config::Config;
use crate::model::{Agent, Cell, Entry};

pub fn manifest(cfg: &Config, cell: &Cell) -> Result<Vec<Entry>, String> {
    if let Some(audit) = &cfg.audit {
        if (audit.user_prompt.content == "encrypted" || audit.tool_call.content == "encrypted")
            && audit.seal.epoch.is_empty()
        {
            return Err("content=encrypted requires agent_audit.seal.epoch".into());
        }
        if !audit.seal.epoch.is_empty() {
            return Err(
                "seal rendering is not implemented yet (arrives with the place engine)".into(),
            );
        }
    }
    match cell.agent {
        Agent::Claude => claude::manifest(cfg, cell),
        Agent::Codex => Err("codex is not implemented yet (arrives in a later stage)".into()),
    }
}
