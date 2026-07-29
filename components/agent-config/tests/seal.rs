use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use agent_config::config::Config;
use agent_config::seal;

fn audit_conf(epoch: &str, recipients_file: &str) -> String {
    format!(
        "\
agent_audit.elasticsearch.url=http://localhost:9200
agent_audit.elasticsearch.timeout_ms=2000
agent_audit.capture.user_prompt.enabled=true
agent_audit.capture.user_prompt.content=encrypted
agent_audit.capture.tool_call.enabled=true
agent_audit.capture.tool_call.content=plaintext
agent_audit.seal.epoch={epoch}
agent_audit.seal.recipients_file={recipients_file}
"
    )
}

fn load(dir: &Path, conf: &str) -> Config {
    let path = dir.join("setup.conf");
    fs::write(&path, conf).unwrap();
    Config::load(&path).unwrap()
}

fn openssl_available() -> bool {
    Command::new("openssl")
        .arg("version")
        .output()
        .is_ok_and(|o| o.status.success())
}

fn make_cert(dir: &Path, epoch: &str) {
    let cert_dir = dir.join("recipients").join(epoch);
    fs::create_dir_all(&cert_dir).unwrap();
    let status = Command::new("openssl")
        .args([
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
        ])
        .arg("-keyout")
        .arg(cert_dir.join("key.pem"))
        .arg("-out")
        .arg(cert_dir.join("recipient.pem"))
        .arg("-subj")
        .arg(format!("/CN=agent-audit-recipient-{epoch}"))
        .output()
        .unwrap();
    assert!(status.status.success(), "openssl req failed");
}

fn workspace(name: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(name);
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn encrypted_content_requires_an_epoch() {
    let dir = workspace("seal-no-epoch");
    let cfg = load(&dir, &audit_conf("", ""));
    let err = seal::resolve(&dir.join("recipients"), cfg.audit.as_ref().unwrap()).unwrap_err();
    assert!(err.contains("requires agent_audit.seal.epoch"), "{err}");
}

#[test]
fn empty_epoch_without_encryption_means_no_seal() {
    let dir = workspace("seal-off");
    let conf = audit_conf("", "").replace("encrypted", "plaintext");
    let cfg = load(&dir, &conf);
    let resolved = seal::resolve(&dir.join("recipients"), cfg.audit.as_ref().unwrap()).unwrap();
    assert!(resolved.is_none());
}

#[test]
fn resolves_the_epoch_cert_and_verifies_its_cn() {
    if !openssl_available() {
        eprintln!("skipping: openssl not available");
        return;
    }
    let dir = workspace("seal-resolve");
    make_cert(&dir, "2026a");

    let cfg = load(&dir, &audit_conf("2026a", ""));
    let resolved = seal::resolve(&dir.join("recipients"), cfg.audit.as_ref().unwrap())
        .unwrap()
        .expect("seal must resolve");
    assert_eq!(resolved.key_id, "2026a");
    assert!(!resolved.cert.is_empty());

    let cfg = load(&dir, &audit_conf("2026b", ""));
    let err = seal::resolve(&dir.join("recipients"), cfg.audit.as_ref().unwrap()).unwrap_err();
    assert!(err.contains("not found for epoch 2026b"), "{err}");

    let cert = dir.join("recipients/2026a/recipient.pem");
    let conf = audit_conf("2026b", &cert.display().to_string().replace('\\', "/"));
    let cfg = load(&dir, &conf);
    let err = seal::resolve(&dir.join("recipients"), cfg.audit.as_ref().unwrap()).unwrap_err();
    assert!(err.contains("CN epoch 2026a != seal.epoch 2026b"), "{err}");
}

#[test]
fn refuses_certs_under_a_private_directory() {
    let dir = workspace("seal-private");
    let private = dir.join("private/recipient.pem");
    fs::create_dir_all(private.parent().unwrap()).unwrap();
    fs::write(&private, "not really a cert").unwrap();
    let conf = audit_conf("2026a", &private.display().to_string().replace('\\', "/"));
    let cfg = load(&dir, &conf);
    let err = seal::resolve(&dir.join("recipients"), cfg.audit.as_ref().unwrap()).unwrap_err();
    assert!(err.contains("must not be under sealing/private/"), "{err}");
}
