use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use agent_config::config::Config;
use agent_config::seal;

fn audit_conf(extra_seal_keys: &str) -> String {
    format!(
        "\
agent_audit.elasticsearch.url=http://localhost:9200
agent_audit.elasticsearch.timeout_ms=2000
agent_audit.capture.user_prompt.enabled=true
agent_audit.capture.user_prompt.content=encrypted
agent_audit.capture.tool_call.enabled=true
agent_audit.capture.tool_call.content=plaintext
{extra_seal_keys}"
    )
}

fn load(dir: &Path, conf: &str) -> Config {
    let path = dir.join("setup.conf");
    fs::write(&path, conf).unwrap();
    Config::load(&path).unwrap()
}

fn resolve(dir: &Path, cfg: &Config) -> Result<Option<seal::SealSource>, String> {
    seal::resolve(dir, cfg.audit.as_ref().unwrap())
}

fn openssl_available() -> bool {
    Command::new("openssl")
        .arg("version")
        .output()
        .is_ok_and(|o| o.status.success())
}

fn make_cert(pem: &Path, epoch: &str) {
    fs::create_dir_all(pem.parent().unwrap()).unwrap();
    let status = Command::new("openssl")
        .args([
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
        ])
        .arg("-keyout")
        .arg(pem.with_extension("key"))
        .arg("-out")
        .arg(pem)
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
    let cfg = load(&dir, &audit_conf("agent_audit.seal.epoch=\n"));
    let err = resolve(&dir, &cfg).unwrap_err();
    assert!(err.contains("requires agent_audit.seal.epoch"), "{err}");
}

#[test]
fn empty_epoch_without_encryption_means_no_seal() {
    let dir = workspace("seal-off");
    let conf = audit_conf("agent_audit.seal.epoch=\n").replace("encrypted", "plaintext");
    let cfg = load(&dir, &conf);
    assert!(resolve(&dir, &cfg).unwrap().is_none());
}

#[test]
fn default_root_is_sealing_recipients_beside_the_conf() {
    if !openssl_available() {
        eprintln!("skipping: openssl not available");
        return;
    }
    let dir = workspace("seal-default-root");
    make_cert(&dir.join("sealing/recipients/2026a/recipient.pem"), "2026a");

    let cfg = load(&dir, &audit_conf("agent_audit.seal.epoch=2026a\n"));
    let resolved = resolve(&dir, &cfg).unwrap().expect("seal must resolve");
    assert_eq!(resolved.key_id, "2026a");
    assert!(!resolved.cert.is_empty());

    let cfg = load(&dir, &audit_conf("agent_audit.seal.epoch=2026b\n"));
    let err = resolve(&dir, &cfg).unwrap_err();
    assert!(err.contains("not found for epoch 2026b"), "{err}");
}

#[test]
fn recipients_root_key_is_conf_relative() {
    if !openssl_available() {
        eprintln!("skipping: openssl not available");
        return;
    }
    let dir = workspace("seal-root-key");
    make_cert(&dir.join("shared/keys/2026a/recipient.pem"), "2026a");

    let cfg = load(
        &dir,
        &audit_conf("agent_audit.seal.epoch=2026a\nagent_audit.seal.recipients_root=shared/keys\n"),
    );
    let resolved = resolve(&dir, &cfg).unwrap().expect("seal must resolve");
    assert_eq!(resolved.key_id, "2026a");
}

#[test]
fn recipients_file_override_is_conf_relative_not_cwd() {
    if !openssl_available() {
        eprintln!("skipping: openssl not available");
        return;
    }
    let dir = workspace("seal-file-override");
    make_cert(&dir.join("certs/other.pem"), "2026a");

    let cfg = load(
        &dir,
        &audit_conf(
            "agent_audit.seal.epoch=2026a\nagent_audit.seal.recipients_file=certs/other.pem\n",
        ),
    );
    assert!(
        !Path::new("certs/other.pem").exists(),
        "test invalid: the override must not resolve from the cwd"
    );
    let resolved = resolve(&dir, &cfg).unwrap().expect("seal must resolve");
    assert_eq!(resolved.key_id, "2026a");

    let cfg = load(
        &dir,
        &audit_conf(
            "agent_audit.seal.epoch=2026b\nagent_audit.seal.recipients_file=certs/other.pem\n",
        ),
    );
    let err = resolve(&dir, &cfg).unwrap_err();
    assert!(err.contains("CN epoch 2026a != seal.epoch 2026b"), "{err}");
}

#[test]
fn refuses_certs_under_a_private_directory() {
    let dir = workspace("seal-private");
    let private = dir.join("private/recipient.pem");
    fs::create_dir_all(private.parent().unwrap()).unwrap();
    fs::write(&private, "not really a cert").unwrap();
    let cfg = load(
        &dir,
        &audit_conf(
            "agent_audit.seal.epoch=2026a\nagent_audit.seal.recipients_file=private/recipient.pem\n",
        ),
    );
    let err = resolve(&dir, &cfg).unwrap_err();
    assert!(err.contains("must not be under sealing/private/"), "{err}");
}
