use std::fs;
use std::path::{Path, PathBuf};

use agent_config::config::Config;
use agent_config::model::{Agent, Cell, Location, Os, Scope};
use agent_config::{agents, place};

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

const TELEMETRY_CONF: &str = "[telemetry.apm_server]
endpoint = \"http://localhost:8200\"
";

fn workspace(name: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(name);
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn load(dir: &Path, conf: &str) -> Config {
    let conf_path = dir.join("agent-config.toml");
    fs::write(&conf_path, conf).unwrap();
    Config::load(&conf_path, None).unwrap()
}

fn place_into(dir: &Path, cfg: &Config, agent: Agent, scope: Scope) -> Result<(), String> {
    let target = dir.join("target");
    fs::create_dir_all(&target).unwrap();
    let os = Os::detect().unwrap();
    let cell = Cell {
        agent,
        scope,
        os,
        target: Some(target.display().to_string().replace('\\', "/")),
    };
    let mut entries = agents::manifest(cfg, &cell, None)?;
    let sidecars = place::sidecar_entries(&entries, &cfg.executor, agent, scope, os)?;
    entries.extend(sidecars);
    place::place(&entries, &target, &cfg.executor)
}

fn marker_lines(path: &Path) -> Vec<(String, String)> {
    fs::read_to_string(path)
        .unwrap()
        .lines()
        .filter_map(|l| l.split_once('='))
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

#[test]
fn place_local_audit_writes_files_and_markers() {
    let dir = workspace("place-local-audit");
    let cfg = load(&dir, AUDIT_CONF);
    place_into(&dir, &cfg, Agent::Claude, Scope::Local).unwrap();
    let target = dir.join("target");

    for marked in [
        ".claude/settings.local.json",
        ".claude/hooks/agent-audit.conf",
        ".claude/.gitignore",
        ".mcp.json",
        ".claude/agent-config.version",
        ".claude/agent-config.sha256",
    ] {
        assert!(target.join(marked).is_file(), "missing {marked}");
        let marker = target.join(format!("{marked}.managed"));
        assert!(marker.is_file(), "missing marker for {marked}");
        let fields = marker_lines(&marker);
        assert!(fields.contains(&("executor".into(), "agent-config".into())));
        assert!(
            fields.iter().any(|(k, _)| k == "placed_at"),
            "missing placed_at"
        );
        assert!(fields.iter().any(|(k, _)| k == "target"), "missing target");
        assert!(
            !fields
                .iter()
                .any(|(k, _)| k == "tool" || k == "agent" || k == "endpoint"),
            "legacy marker fields must be gone: {fields:?}"
        );
    }

    let flavor = if cfg!(windows) { "ps1" } else { "sh" };
    let entry = target.join(format!(".claude/hooks/agent-audit.{flavor}"));
    assert!(entry.is_file(), "hook entry script missing");
    assert!(
        !target
            .join(format!(".claude/hooks/agent-audit.{flavor}.managed"))
            .exists(),
        "hook assets carry no markers"
    );
}

#[test]
fn place_writes_a_fixed_version_and_a_self_excluding_sha256() {
    let dir = workspace("place-sidecars");
    let cfg = load(&dir, AUDIT_CONF);
    place_into(&dir, &cfg, Agent::Claude, Scope::Local).unwrap();
    let target = dir.join("target");

    let version = fs::read_to_string(target.join(".claude/agent-config.version")).unwrap();
    assert_eq!(
        version,
        format!("{}-0001\n", agent_config::clock::utc_today_compact())
    );

    let checksums = fs::read_to_string(target.join(".claude/agent-config.sha256")).unwrap();
    assert!(
        !checksums.contains("agent-config.version") && !checksums.contains("agent-config.sha256"),
        "{checksums}"
    );
    assert!(
        checksums.contains("  .claude/settings.local.json"),
        "{checksums}"
    );
}

#[test]
fn teardown_targets_list_the_version_and_sha256_sidecars() {
    let (targets, _, _) = agents::claude::teardown_targets("agent-config");
    assert!(targets.contains(&("version", ".claude/agent-config.version".to_string())));
    assert!(targets.contains(&("sha256", ".claude/agent-config.sha256".to_string())));

    let (targets, _, _) = agents::codex::teardown_targets("agent-config");
    assert!(targets.contains(&("version", ".codex/agent-config.version".to_string())));
    assert!(targets.contains(&("sha256", ".codex/agent-config.sha256".to_string())));
}

#[test]
fn managed_candidates_list_the_version_and_sha256_sidecars() {
    let dir = workspace("managed-candidates-sidecars");
    let cfg = load(&dir, AUDIT_CONF);
    let os = Os::detect().unwrap();

    let root = agents::claude::managed_root(os);
    let candidates = agents::claude::managed_candidates(&cfg, os);
    assert!(candidates.contains(&(
        "version".to_string(),
        format!("{root}/agent-config.version")
    )));
    assert!(candidates.contains(&("sha256".to_string(), format!("{root}/agent-config.sha256"))));

    let root = agents::codex::managed_root(os);
    let candidates = agents::codex::managed_candidates(&cfg, os);
    assert!(candidates.contains(&(
        "version".to_string(),
        format!("{root}/agent-config.version")
    )));
    assert!(candidates.contains(&("sha256".to_string(), format!("{root}/agent-config.sha256"))));
}

#[test]
fn managed_sidecar_entries_target_the_managed_root() {
    let os = Os::detect().unwrap();
    let sidecars =
        place::sidecar_entries(&[], "agent-config", Agent::Claude, Scope::Managed, os).unwrap();
    let root = agents::claude::managed_root(os);
    match &sidecars[0].location {
        Location::Host(path) => assert_eq!(path, &format!("{root}/agent-config.version")),
        _ => panic!("expected a host location"),
    }
    match &sidecars[1].location {
        Location::Host(path) => assert_eq!(path, &format!("{root}/agent-config.sha256")),
        _ => panic!("expected a host location"),
    }
}

#[test]
fn place_is_idempotent() {
    let dir = workspace("place-idempotent");
    let cfg = load(&dir, AUDIT_CONF);
    place_into(&dir, &cfg, Agent::Claude, Scope::Local).unwrap();
    let settings = dir.join("target/.claude/settings.local.json");
    let first = fs::read_to_string(&settings).unwrap();
    place_into(&dir, &cfg, Agent::Claude, Scope::Local).unwrap();
    assert_eq!(first, fs::read_to_string(&settings).unwrap());
}

#[test]
fn place_refuses_foreign_target_before_writing_anything() {
    let dir = workspace("place-foreign");
    let cfg = load(&dir, AUDIT_CONF);
    let target = dir.join("target");
    fs::create_dir_all(target.join(".claude")).unwrap();
    fs::write(target.join(".claude/settings.local.json"), "{}\n").unwrap();

    let err = place_into(&dir, &cfg, Agent::Claude, Scope::Local).unwrap_err();
    assert!(err.contains("REFUSED"), "unexpected error: {err}");
    assert!(
        err.contains("no provenance marker"),
        "unexpected error: {err}"
    );
    assert!(
        !target.join(".claude/hooks").exists(),
        "nothing may be written on the fail path"
    );
}

#[test]
fn place_converges_after_a_config_edit() {
    let dir = workspace("place-converge");
    let cfg = load(&dir, AUDIT_CONF);
    place_into(&dir, &cfg, Agent::Claude, Scope::Local).unwrap();

    let edited = load(&dir, &AUDIT_CONF.replace("localhost:9200", "other:9200"));
    place_into(&dir, &edited, Agent::Claude, Scope::Local).unwrap();
    let conf = fs::read_to_string(dir.join("target/.claude/hooks/agent-audit.conf")).unwrap();
    assert!(
        conf.contains("other:9200"),
        "re-place must converge: {conf}"
    );
}

#[test]
fn place_refuses_a_different_executor() {
    let dir = workspace("place-executor-mismatch");
    let cfg = load(&dir, AUDIT_CONF);
    place_into(&dir, &cfg, Agent::Claude, Scope::Local).unwrap();

    let other = load(
        &dir,
        &format!("[agent_config]\nexecutor = \"someone-else\"\n{AUDIT_CONF}"),
    );
    let err = place_into(&dir, &other, Agent::Claude, Scope::Local).unwrap_err();
    assert!(
        err.contains("owned by executor 'agent-config'"),
        "unexpected error: {err}"
    );
}

#[test]
fn executor_key_names_the_marker_owner() {
    let dir = workspace("place-executor-key");
    let cfg = load(
        &dir,
        &format!("[agent_config]\nexecutor = \"custom-exec\"\n{AUDIT_CONF}"),
    );
    place_into(&dir, &cfg, Agent::Claude, Scope::Local).unwrap();
    let marker = dir.join("target/.claude/settings.local.json.managed");
    assert!(
        marker_lines(&marker).contains(&("executor".into(), "custom-exec".into())),
        "marker must carry the declared executor"
    );
}

#[test]
fn json_merge_preserves_foreign_top_level_keys_on_our_file() {
    let dir = workspace("place-json-merge");
    let cfg = load(&dir, TELEMETRY_CONF);
    place_into(&dir, &cfg, Agent::Claude, Scope::Local).unwrap();
    let settings = dir.join("target/.claude/settings.local.json");

    let mut value: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
    value["permissions"] = serde_json::json!({ "allow": ["mcp__elasticsearch__esql"] });
    fs::write(&settings, serde_json::to_string_pretty(&value).unwrap()).unwrap();

    place_into(&dir, &cfg, Agent::Claude, Scope::Local).unwrap();
    let merged: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
    assert!(
        merged["permissions"]["allow"][0].is_string(),
        "sibling key lost in merge"
    );
    assert!(merged["env"]["CLAUDE_CODE_ENABLE_TELEMETRY"].is_string());
}

#[test]
fn toml_sections_are_not_duplicated_on_rerun() {
    let dir = workspace("place-toml-sections");
    let cfg = load(&dir, AUDIT_CONF);
    place_into(&dir, &cfg, Agent::Codex, Scope::Local).unwrap();
    place_into(&dir, &cfg, Agent::Codex, Scope::Local).unwrap();

    let config = fs::read_to_string(dir.join("target/.codex/config.toml")).unwrap();
    assert_eq!(config.matches("[[hooks.UserPromptSubmit]]").count(), 1);
    assert_eq!(config.matches("[mcp_servers.elasticsearch]").count(), 1);
}

#[test]
fn teardown_removes_only_lab_files() {
    let dir = workspace("teardown-ours");
    let cfg = load(&dir, AUDIT_CONF);
    place_into(&dir, &cfg, Agent::Claude, Scope::Local).unwrap();
    let target = dir.join("target");
    fs::write(target.join(".claude/own.txt"), "mine\n").unwrap();

    place::teardown(Agent::Claude, &target, &cfg.executor).unwrap();

    assert!(!target.join(".claude/settings.local.json").exists());
    assert!(!target.join(".claude/settings.local.json.managed").exists());
    assert!(!target.join(".claude/hooks").exists());
    assert!(!target.join(".mcp.json").exists());
    assert!(!target.join(".claude/agent-config.version").exists());
    assert!(!target.join(".claude/agent-config.sha256").exists());
    assert!(
        target.join(".claude/own.txt").is_file(),
        "user file must survive"
    );

    place::teardown(Agent::Claude, &target, &cfg.executor).unwrap();
}

#[test]
fn teardown_leaves_unmarked_files_and_reports_success() {
    let dir = workspace("teardown-unmarked");
    let cfg = load(&dir, AUDIT_CONF);
    let target = dir.join("target");
    fs::create_dir_all(&target).unwrap();
    fs::write(target.join(".mcp.json"), "{}\n").unwrap();

    place::teardown(Agent::Claude, &target, &cfg.executor).unwrap();
    assert!(
        target.join(".mcp.json").is_file(),
        "unmarked file is the user's own"
    );
}

#[test]
fn teardown_refuses_a_different_executor() {
    let dir = workspace("teardown-executor-mismatch");
    let cfg = load(&dir, AUDIT_CONF);
    place_into(&dir, &cfg, Agent::Claude, Scope::Local).unwrap();
    let target = dir.join("target");

    let err = place::teardown(Agent::Claude, &target, "someone-else").unwrap_err();
    assert!(err.contains("refused"), "unexpected error: {err}");
    assert!(
        target.join(".claude/settings.local.json").is_file(),
        "refused file must remain"
    );
}
