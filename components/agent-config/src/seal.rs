use std::fs;
use std::path::Path;
use std::process::Command;

use crate::config::Audit;

#[derive(Debug)]
pub struct SealSource {
    pub cert: Vec<u8>,
    pub key_id: String,
}

pub fn resolve(conf_dir: &Path, audit: &Audit) -> Result<Option<SealSource>, String> {
    let encrypted =
        audit.user_prompt.content == "encrypted" || audit.tool_call.content == "encrypted";
    let epoch = audit.seal.epoch.as_str();
    if encrypted && epoch.is_empty() {
        return Err("content=encrypted requires agent_audit.seal.epoch".into());
    }
    if epoch.is_empty() {
        return Ok(None);
    }

    let recipients_root = if audit.seal.recipients_root.is_empty() {
        conf_dir.join("sealing/recipients")
    } else {
        conf_dir.join(&audit.seal.recipients_root)
    };
    let src = if audit.seal.recipients_file.is_empty() {
        recipients_root.join(epoch).join("recipient.pem")
    } else {
        conf_dir.join(&audit.seal.recipients_file)
    };
    let src_text = src.display().to_string().replace('\\', "/");
    if src_text.contains("/private/") {
        return Err(format!(
            "seal recipient must not be under sealing/private/: {src_text}"
        ));
    }
    let cert = fs::read(&src)
        .map_err(|_| format!("recipient cert not found for epoch {epoch} at {src_text}"))?;

    let cn = cert_cn_epoch(&src)?;
    if cn != epoch {
        return Err(format!(
            "recipient cert CN epoch {} != seal.epoch {epoch} ({src_text})",
            if cn.is_empty() { "<none>" } else { &cn }
        ));
    }

    Ok(Some(SealSource {
        cert,
        key_id: epoch.to_string(),
    }))
}

fn cert_cn_epoch(cert: &Path) -> Result<String, String> {
    let output = Command::new("openssl")
        .args(["x509", "-noout", "-subject", "-in"])
        .arg(cert)
        .output()
        .map_err(|_| "openssl required to verify recipient cert".to_string())?;
    if !output.status.success() {
        return Err(format!(
            "openssl could not read the recipient cert {}",
            cert.display()
        ));
    }
    let subject = String::from_utf8_lossy(&output.stdout);
    let cn = subject
        .split("CN")
        .nth(1)
        .map(|rest| rest.trim_start().trim_start_matches('=').trim_start())
        .and_then(|cn| cn.strip_prefix("agent-audit-recipient-"))
        .map(|epoch| {
            epoch
                .split([',', '/', '\n', '\r'])
                .next()
                .unwrap_or("")
                .trim()
                .to_string()
        })
        .unwrap_or_default();
    Ok(cn)
}
