use std::fs;
use std::path::{Path, PathBuf};

use agent_config::config::Config;
use agent_config::model::{Agent, Cell, Os, Scope};
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
    let cell = Cell {
        agent,
        scope,
        os: Os::detect().unwrap(),
        target: Some(target.display().to_string().replace('\\', "/")),
    };
    let entries = agents::manifest(cfg, &cell, None)?;
    place::place(&entries, &target, agent.name(), &cfg.marker_endpoint(scope))
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
    ] {
        assert!(target.join(marked).is_file(), "missing {marked}");
        let marker = target.join(format!("{marked}.managed"));
        assert!(marker.is_file(), "missing marker for {marked}");
        let fields = marker_lines(&marker);
        assert!(fields.contains(&("tool".into(), "agent-observability-lab".into())));
        assert!(fields.contains(&("agent".into(), "claude".into())));
        assert!(fields.contains(&("endpoint".into(), "http://localhost:9200".into())));
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
fn place_refuses_a_different_deploy_endpoint() {
    let dir = workspace("place-endpoint-mismatch");
    let cfg = load(&dir, AUDIT_CONF);
    place_into(&dir, &cfg, Agent::Claude, Scope::Local).unwrap();

    let other = load(&dir, &AUDIT_CONF.replace("localhost:9200", "other:9200"));
    let err = place_into(&dir, &other, Agent::Claude, Scope::Local).unwrap_err();
    assert!(
        err.contains("different endpoint"),
        "unexpected error: {err}"
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

    place::teardown(Agent::Claude, &target, &cfg.marker_endpoint(Scope::Local)).unwrap();

    assert!(!target.join(".claude/settings.local.json").exists());
    assert!(!target.join(".claude/settings.local.json.managed").exists());
    assert!(!target.join(".claude/hooks").exists());
    assert!(!target.join(".mcp.json").exists());
    assert!(
        target.join(".claude/own.txt").is_file(),
        "user file must survive"
    );

    place::teardown(Agent::Claude, &target, &cfg.marker_endpoint(Scope::Local)).unwrap();
}

#[test]
fn teardown_leaves_unmarked_files_and_reports_success() {
    let dir = workspace("teardown-unmarked");
    let cfg = load(&dir, AUDIT_CONF);
    let target = dir.join("target");
    fs::create_dir_all(&target).unwrap();
    fs::write(target.join(".mcp.json"), "{}\n").unwrap();

    place::teardown(Agent::Claude, &target, &cfg.marker_endpoint(Scope::Local)).unwrap();
    assert!(
        target.join(".mcp.json").is_file(),
        "unmarked file is the user's own"
    );
}

#[test]
fn teardown_refuses_a_different_deploy_endpoint() {
    let dir = workspace("teardown-endpoint-mismatch");
    let cfg = load(&dir, AUDIT_CONF);
    place_into(&dir, &cfg, Agent::Claude, Scope::Local).unwrap();
    let target = dir.join("target");

    let err = place::teardown(Agent::Claude, &target, "http://other:9200").unwrap_err();
    assert!(err.contains("refused"), "unexpected error: {err}");
    assert!(
        target.join(".claude/settings.local.json").is_file(),
        "refused file must remain"
    );
}
