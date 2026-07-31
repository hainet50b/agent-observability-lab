use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

use agent_config::bundle::{self, BundleRun};
use agent_config::config::Config;
use agent_config::model::{Agent, Os, Scope};

const AUDIT_CONF: &str = r#"
[agent_audit.elasticsearch]
url = "http://localhost:9200"
timeout_ms = 2000

[agent_audit.capture.user_prompt]
enabled = true
content = "plaintext"

[agent_audit.capture.tool_call]
enabled = true
content = "plaintext"
"#;

fn workspace(name: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(name);
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn load(dir: &Path, conf: &str) -> Config {
    let path = dir.join("agent-config.toml");
    fs::write(&path, conf).unwrap();
    Config::load(&path, None).unwrap()
}

fn managed_run(dir: &Path, oses: Vec<Os>, emit_all: bool) -> BundleRun {
    BundleRun {
        scopes: vec![Scope::Managed],
        oses,
        target: None,
        out_dir: dir.join("dist"),
        emit_all,
    }
}

fn zips(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(dir.join("dist"))
        .map(|entries| {
            entries
                .flatten()
                .map(|e| e.file_name().to_string_lossy().to_string())
                .filter(|n| n.ends_with(".zip"))
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    names
}

#[test]
fn bundles_managed_cells_with_a_version_ledger() {
    let dir = workspace("bundle-managed");
    let cfg = load(&dir, AUDIT_CONF);
    bundle::bundle(
        &cfg,
        None,
        Agent::Claude,
        &dir,
        &managed_run(&dir, Os::ALL.to_vec(), false),
    )
    .unwrap();

    let archives = zips(&dir);
    assert_eq!(archives.len(), 3, "one archive per OS: {archives:?}");
    assert!(
        archives
            .iter()
            .all(|n| n.starts_with("agent-observability-lab-claude-managed-")),
        "{archives:?}"
    );

    let ledger = fs::read_to_string(dir.join("bundle-versions.conf")).unwrap();
    for os in ["linux", "macos", "windows"] {
        assert!(
            ledger.contains(&format!("claude.managed.{os}.version=")),
            "{ledger}"
        );
        assert!(
            ledger.contains(&format!("claude.managed.{os}.hash=")),
            "{ledger}"
        );
    }
}

#[test]
fn unchanged_cells_are_skipped_and_the_ledger_is_stable() {
    let dir = workspace("bundle-stable");
    let cfg = load(&dir, AUDIT_CONF);
    let run = managed_run(&dir, vec![Os::Linux], false);
    bundle::bundle(&cfg, None, Agent::Claude, &dir, &run).unwrap();
    let ledger_before = fs::read_to_string(dir.join("bundle-versions.conf")).unwrap();
    let archives_before = zips(&dir);

    bundle::bundle(&cfg, None, Agent::Claude, &dir, &run).unwrap();
    assert_eq!(
        ledger_before,
        fs::read_to_string(dir.join("bundle-versions.conf")).unwrap()
    );
    assert_eq!(archives_before, zips(&dir), "skipped cell must not re-emit");
}

#[test]
fn changed_content_bumps_the_version_sequence() {
    let dir = workspace("bundle-changed");
    let cfg = load(&dir, AUDIT_CONF);
    let run = managed_run(&dir, vec![Os::Linux], false);
    bundle::bundle(&cfg, None, Agent::Claude, &dir, &run).unwrap();

    let cfg = load(&dir, &AUDIT_CONF.replace("2000", "5000"));
    bundle::bundle(&cfg, None, Agent::Claude, &dir, &run).unwrap();

    let ledger = fs::read_to_string(dir.join("bundle-versions.conf")).unwrap();
    let version_line = ledger
        .lines()
        .find(|l| l.starts_with("claude.managed.linux.version="))
        .unwrap();
    assert!(version_line.ends_with("-0002"), "{version_line}");
    let archives = zips(&dir);
    assert_eq!(
        archives.len(),
        1,
        "stale archives are removed: {archives:?}"
    );
    assert!(archives[0].ends_with("-0002.zip"), "{archives:?}");
}

#[test]
fn archive_carries_the_rendered_tree_and_version_file() {
    let dir = workspace("bundle-content");
    let cfg = load(&dir, AUDIT_CONF);
    bundle::bundle(
        &cfg,
        None,
        Agent::Claude,
        &dir,
        &managed_run(&dir, vec![Os::Linux], false),
    )
    .unwrap();

    let archive = dir.join("dist").join(&zips(&dir)[0]);
    let mut zip = zip::ZipArchive::new(fs::File::open(&archive).unwrap()).unwrap();
    let names: Vec<String> = (0..zip.len())
        .map(|i| zip.by_index(i).unwrap().name().to_string())
        .collect();
    assert!(
        names.contains(
            &"etc/claude-code/managed-settings.d/10-agent-observability-lab.json".to_string()
        ),
        "{names:?}"
    );
    assert!(
        names.contains(&"etc/claude-code/agent-observability-lab.version".to_string()),
        "{names:?}"
    );

    let mut fragment = String::new();
    zip.by_name("etc/claude-code/managed-settings.d/10-agent-observability-lab.json")
        .unwrap()
        .read_to_string(&mut fragment)
        .unwrap();
    assert_eq!(
        fragment,
        include_str!("fixtures/managed-audit-linux.fragment.json")
    );
}

#[test]
fn local_bundle_bakes_the_stack_dir_and_project_needs_a_target() {
    let dir = workspace("bundle-local");
    let cfg = load(&dir, AUDIT_CONF);
    let run = BundleRun {
        scopes: vec![Scope::Local, Scope::Project],
        oses: vec![Os::Linux],
        target: None,
        out_dir: dir.join("dist"),
        emit_all: false,
    };
    bundle::bundle(&cfg, None, Agent::Claude, &dir, &run).unwrap();

    let archives = zips(&dir);
    assert_eq!(
        archives.len(),
        1,
        "project without --target is skipped: {archives:?}"
    );
    assert!(
        archives[0].starts_with("agent-observability-lab-claude-local-linux-"),
        "{archives:?}"
    );

    let mut zip =
        zip::ZipArchive::new(fs::File::open(dir.join("dist").join(&archives[0])).unwrap()).unwrap();
    let mut settings = String::new();
    zip.by_name(".claude/settings.local.json")
        .unwrap()
        .read_to_string(&mut settings)
        .unwrap();
    let baked = dir
        .canonicalize()
        .unwrap()
        .display()
        .to_string()
        .replace('\\', "/");
    let baked = baked.strip_prefix("//?/").unwrap_or(&baked).to_string();
    assert!(
        settings.contains(&format!("{baked}/.claude/hooks/agent-audit.sh")),
        "{settings}"
    );
}
