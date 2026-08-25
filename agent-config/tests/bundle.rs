use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

use agent_config::config::Config;
use agent_config::model::{Agent, Os, Scope};
use agent_config::render::{self, BundleRun, ProjectSelection};

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
        scope: Scope::Managed,
        oses,
        project: None,
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
    render::bundle(
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
            .all(|n| n.starts_with("agent-config-claude-managed-")),
        "{archives:?}"
    );

    let ledger = fs::read_to_string(dir.join("agent-config-managed-versions.conf")).unwrap();
    for os in ["linux", "macos", "windows"] {
        assert!(
            ledger.contains(&format!("claude.{os}.version=")),
            "{ledger}"
        );
        assert!(ledger.contains(&format!("claude.{os}.hash=")), "{ledger}");
    }
}

#[test]
fn unchanged_cells_are_skipped_and_the_ledger_is_stable() {
    let dir = workspace("bundle-stable");
    let cfg = load(&dir, AUDIT_CONF);
    let run = managed_run(&dir, vec![Os::Linux], false);
    render::bundle(&cfg, None, Agent::Claude, &dir, &run).unwrap();
    let ledger_before = fs::read_to_string(dir.join("agent-config-managed-versions.conf")).unwrap();
    let archives_before = zips(&dir);

    render::bundle(&cfg, None, Agent::Claude, &dir, &run).unwrap();
    assert_eq!(
        ledger_before,
        fs::read_to_string(dir.join("agent-config-managed-versions.conf")).unwrap()
    );
    assert_eq!(archives_before, zips(&dir), "skipped cell must not re-emit");
}

#[test]
fn changed_content_bumps_the_version_sequence() {
    let dir = workspace("bundle-changed");
    let cfg = load(&dir, AUDIT_CONF);
    let run = managed_run(&dir, vec![Os::Linux], false);
    render::bundle(&cfg, None, Agent::Claude, &dir, &run).unwrap();

    let cfg = load(&dir, &AUDIT_CONF.replace("2000", "5000"));
    render::bundle(&cfg, None, Agent::Claude, &dir, &run).unwrap();

    let ledger = fs::read_to_string(dir.join("agent-config-managed-versions.conf")).unwrap();
    let version_line = ledger
        .lines()
        .find(|l| l.starts_with("claude.linux.version="))
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
    render::bundle(
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
        names.contains(&"etc/claude-code/managed-settings.d/10-agent-config.json".to_string()),
        "{names:?}"
    );
    assert!(
        names.contains(&"etc/claude-code/agent-config.version".to_string()),
        "{names:?}"
    );
    assert!(
        names.contains(&"etc/claude-code/agent-config.sha256".to_string()),
        "{names:?}"
    );

    let mut checksums = String::new();
    zip.by_name("etc/claude-code/agent-config.sha256")
        .unwrap()
        .read_to_string(&mut checksums)
        .unwrap();
    assert!(
        !checksums.contains("agent-config.version") && !checksums.contains("agent-config.sha256"),
        "{checksums}"
    );
    assert!(
        checksums.contains("  etc/claude-code/managed-settings.d/10-agent-config.json"),
        "{checksums}"
    );

    let mut fragment = String::new();
    zip.by_name("etc/claude-code/managed-settings.d/10-agent-config.json")
        .unwrap()
        .read_to_string(&mut fragment)
        .unwrap();
    assert_eq!(
        fragment,
        include_str!("fixtures/managed-audit-linux.fragment.json")
    );
}

#[test]
fn local_bundle_bakes_the_stack_dir() {
    let dir = workspace("bundle-local");
    let cfg = load(&dir, AUDIT_CONF);
    let run = BundleRun {
        scope: Scope::Local,
        oses: vec![Os::Linux],
        project: None,
        out_dir: dir.join("dist"),
        emit_all: false,
    };
    render::bundle(&cfg, None, Agent::Claude, &dir, &run).unwrap();

    let archives = zips(&dir);
    assert_eq!(archives.len(), 1, "{archives:?}");
    assert!(
        archives[0].starts_with("agent-config-claude-local-linux-"),
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

#[test]
fn local_and_project_versions_land_in_scope_specific_ledgers() {
    let dir = workspace("bundle-scoped-ledgers");
    let target_dir = workspace("bundle-scoped-ledgers-target");
    let target_path = target_dir.display().to_string().replace('\\', "/");
    let cfg = load(
        &dir,
        &format!("{AUDIT_CONF}\n[project.server-a]\nlinux = \"{target_path}\"\n"),
    );

    let local_run = BundleRun {
        scope: Scope::Local,
        oses: vec![Os::Linux],
        project: None,
        out_dir: dir.join("dist"),
        emit_all: false,
    };
    render::bundle(&cfg, None, Agent::Claude, &dir, &local_run).unwrap();

    let (oses, project_target) = cfg
        .os_candidates(Scope::Project, Some("server-a"), &[Os::Linux], false)
        .unwrap();
    assert_eq!(oses, vec![Os::Linux]);
    let project_run = BundleRun {
        scope: Scope::Project,
        oses,
        project: Some(ProjectSelection {
            name: "server-a".into(),
            target: project_target.unwrap().clone(),
        }),
        out_dir: dir.join("dist"),
        emit_all: false,
    };
    render::bundle(&cfg, None, Agent::Claude, &dir, &project_run).unwrap();

    assert!(
        !dir.join("agent-config-managed-versions.conf").exists(),
        "no managed cells were bundled"
    );

    let local_ledger = fs::read_to_string(dir.join("agent-config-local-versions.conf")).unwrap();
    assert!(
        local_ledger.contains("claude.linux.version="),
        "{local_ledger}"
    );

    let project_ledger =
        fs::read_to_string(dir.join("agent-config-project-versions.conf")).unwrap();
    assert!(
        project_ledger.contains("claude.server-a.linux.version="),
        "{project_ledger}"
    );
}

fn project_config(dir: &Path) -> Config {
    load(
        dir,
        &format!(
            "{AUDIT_CONF}
[project.server-a]
linux = \"/srv/server-a\"
windows = \"C:/server-a\"
"
        ),
    )
}

#[test]
fn os_candidates_defaults_to_every_os_the_scope_declares() {
    let dir = workspace("os-candidates-defaults");
    let cfg = project_config(&dir);

    let (managed, target) = cfg.os_candidates(Scope::Managed, None, &[], false).unwrap();
    assert_eq!(managed, Os::ALL.to_vec());
    assert!(target.is_none());

    let (local, _) = cfg.os_candidates(Scope::Local, None, &[], false).unwrap();
    assert_eq!(local, vec![Os::detect().unwrap()]);

    let (project, target) = cfg
        .os_candidates(Scope::Project, Some("server-a"), &[], false)
        .unwrap();
    assert_eq!(project, vec![Os::Linux, Os::Windows], "macos undeclared");
    assert_eq!(target.unwrap().for_os(Os::Linux), Some("/srv/server-a"));
}

#[test]
fn os_candidates_intersects_an_explicit_os_filter() {
    let dir = workspace("os-candidates-filter");
    let cfg = project_config(&dir);

    let (oses, _) = cfg
        .os_candidates(Scope::Project, Some("server-a"), &[Os::Windows], false)
        .unwrap();
    assert_eq!(oses, vec![Os::Windows]);

    let (oses, _) = cfg
        .os_candidates(Scope::Managed, None, &[Os::Macos], false)
        .unwrap();
    assert_eq!(oses, vec![Os::Macos]);
}

#[test]
fn os_candidates_empty_result_is_not_an_error() {
    let dir = workspace("os-candidates-empty");
    let cfg = project_config(&dir);

    let (oses, _) = cfg
        .os_candidates(Scope::Project, Some("server-a"), &[Os::Macos], false)
        .unwrap();
    assert!(oses.is_empty(), "macos was never declared for server-a");
}

#[test]
fn os_candidates_place_restricts_to_the_detected_host() {
    let dir = workspace("os-candidates-place");
    let cfg = project_config(&dir);

    let (managed, _) = cfg.os_candidates(Scope::Managed, None, &[], true).unwrap();
    assert_eq!(managed, vec![Os::detect().unwrap()]);

    let host = Os::detect().unwrap();
    let declared_for_host = matches!(host, Os::Linux | Os::Windows);
    let (project, _) = cfg
        .os_candidates(Scope::Project, Some("server-a"), &[], true)
        .unwrap();
    if declared_for_host {
        assert_eq!(project, vec![host]);
    } else {
        assert!(project.is_empty(), "host has no declared project target");
    }
}

#[test]
fn os_candidates_requires_a_declared_project_name() {
    let dir = workspace("os-candidates-missing-name");
    let cfg = project_config(&dir);

    let err = cfg
        .os_candidates(Scope::Project, None, &[], false)
        .unwrap_err();
    assert!(err.contains("--project <name>"), "{err}");

    let err = cfg
        .os_candidates(Scope::Project, Some("no-such-project"), &[], false)
        .unwrap_err();
    assert!(err.contains("no-such-project"), "{err}");
}
