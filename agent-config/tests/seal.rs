use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use agent_config::config::Config;
use agent_config::seal;

fn audit_conf(seal_table: &str) -> String {
    format!(
        r#"
[agent_audit.elasticsearch]
url = "http://localhost:9200"
timeout_ms = 2000

[agent_audit.capture.user_prompt]
enabled = true
content = "encrypted"

[agent_audit.capture.tool_call]
enabled = true
content = "plaintext"
{seal_table}"#
    )
}

fn epoch_table(epoch: &str) -> String {
    format!("\n[agent_audit.seal]\nepoch = \"{epoch}\"\n")
}

fn load(dir: &Path, conf: &str) -> Config {
    let path = dir.join("agent-config.toml");
    fs::write(&path, conf).unwrap();
    Config::load(&path, None).unwrap()
}

fn resolve(
    dir: &Path,
    cfg: &Config,
    recipients_root: Option<&Path>,
    cert: Option<&Path>,
) -> Result<Option<seal::SealSource>, String> {
    seal::resolve(dir, cfg.audit.as_ref().unwrap(), recipients_root, cert)
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
    let cfg = load(&dir, &audit_conf(""));
    let err = resolve(&dir, &cfg, None, None).unwrap_err();
    assert!(err.contains("requires agent_audit.seal.epoch"), "{err}");
}

#[test]
fn empty_epoch_without_encryption_means_no_seal() {
    let dir = workspace("seal-off");
    let conf = audit_conf(&epoch_table("")).replace("encrypted", "plaintext");
    let cfg = load(&dir, &conf);
    assert!(resolve(&dir, &cfg, None, None).unwrap().is_none());
}

#[test]
fn seal_wiring_flags_require_an_epoch() {
    let dir = workspace("seal-flags-no-epoch");
    let conf = audit_conf("").replace("encrypted", "plaintext");
    let cfg = load(&dir, &conf);
    let err = resolve(&dir, &cfg, Some(Path::new("anywhere")), None).unwrap_err();
    assert!(err.contains("require agent_audit.seal.epoch"), "{err}");
}

#[test]
fn default_root_is_sealing_recipients_beside_the_conf() {
    if !openssl_available() {
        eprintln!("skipping: openssl not available");
        return;
    }
    let dir = workspace("seal-default-root");
    make_cert(&dir.join("sealing/recipients/2026a/recipient.pem"), "2026a");

    let cfg = load(&dir, &audit_conf(&epoch_table("2026a")));
    let resolved = resolve(&dir, &cfg, None, None)
        .unwrap()
        .expect("seal must resolve");
    assert_eq!(resolved.key_id, "2026a");
    assert!(!resolved.cert.is_empty());

    let cfg = load(&dir, &audit_conf(&epoch_table("2026b")));
    let err = resolve(&dir, &cfg, None, None).unwrap_err();
    assert!(err.contains("not found for epoch 2026b"), "{err}");
}

#[test]
fn seal_recipients_flag_overrides_the_root() {
    if !openssl_available() {
        eprintln!("skipping: openssl not available");
        return;
    }
    let dir = workspace("seal-root-flag");
    make_cert(&dir.join("shared/keys/2026a/recipient.pem"), "2026a");

    let cfg = load(&dir, &audit_conf(&epoch_table("2026a")));
    let resolved = resolve(&dir, &cfg, Some(&dir.join("shared/keys")), None)
        .unwrap()
        .expect("seal must resolve");
    assert_eq!(resolved.key_id, "2026a");
}

#[test]
fn seal_cert_flag_bypasses_the_root_but_not_the_cn_check() {
    if !openssl_available() {
        eprintln!("skipping: openssl not available");
        return;
    }
    let dir = workspace("seal-cert-flag");
    make_cert(&dir.join("certs/other.pem"), "2026a");

    let cfg = load(&dir, &audit_conf(&epoch_table("2026a")));
    let resolved = resolve(&dir, &cfg, None, Some(&dir.join("certs/other.pem")))
        .unwrap()
        .expect("seal must resolve");
    assert_eq!(resolved.key_id, "2026a");

    let cfg = load(&dir, &audit_conf(&epoch_table("2026b")));
    let err = resolve(&dir, &cfg, None, Some(&dir.join("certs/other.pem"))).unwrap_err();
    assert!(err.contains("CN epoch 2026a != seal.epoch 2026b"), "{err}");
}

#[test]
fn refuses_certs_under_a_private_directory() {
    let dir = workspace("seal-private");
    let private = dir.join("private/recipient.pem");
    fs::create_dir_all(private.parent().unwrap()).unwrap();
    fs::write(&private, "not really a cert").unwrap();
    let cfg = load(&dir, &audit_conf(&epoch_table("2026a")));
    let err = resolve(&dir, &cfg, None, Some(&private)).unwrap_err();
    assert!(err.contains("must not be under sealing/private/"), "{err}");
}
