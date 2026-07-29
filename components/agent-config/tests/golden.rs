use std::fs;
use std::path::{Path, PathBuf};

use agent_config::agents;
use agent_config::config::Config;
use agent_config::model::{Agent, Cell, Os, Scope};
use agent_config::render;

const AUDIT_CONF: &str = "\
agent_audit.elasticsearch.url=http://localhost:9200
agent_audit.elasticsearch.timeout_ms=2000
agent_audit.capture.user_prompt.enabled=true
agent_audit.capture.user_prompt.content=plaintext
agent_audit.capture.tool_call.enabled=true
agent_audit.capture.tool_call.content=plaintext
agent_audit.seal.epoch=
agent_audit.seal.recipients_file=
";

const TELEMETRY_CONF: &str = "telemetry.apm_server.endpoint=http://localhost:8200\n";

const UNIX_TARGET: &str = "/tmp/agent-config-fixture";

fn render_cell(
    name: &str,
    conf: &str,
    local_conf: Option<&str>,
    scope: Scope,
    os: Os,
    target: Option<&str>,
) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(name);
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    let conf_path = dir.join("setup.conf");
    fs::write(&conf_path, conf).unwrap();
    if let Some(overlay) = local_conf {
        fs::write(dir.join("setup.local.conf"), overlay).unwrap();
    }
    let out = dir.join("out");
    let cfg = Config::load(&conf_path).unwrap();
    let cell = Cell {
        agent: Agent::Claude,
        scope,
        os,
        target: target.map(String::from),
    };
    let entries = agents::manifest(&cfg, &cell).unwrap();
    render::render(&entries, &out).unwrap();
    out
}

fn assert_file(out: &Path, rel: &str, expected: &str) {
    let actual = fs::read_to_string(out.join(rel)).unwrap_or_else(|_| panic!("missing {rel}"));
    assert_eq!(actual, expected, "content mismatch: {rel}");
}

fn assert_hook_assets(out: &Path, hooks_dir: &str, ext: &str) {
    let sources = [
        (
            format!("agent-audit.{ext}"),
            format!("agents/claude/hooks/agent-audit.{ext}"),
        ),
        (
            format!("lib/adapter.{ext}"),
            format!("agents/claude/hooks/lib/adapter.{ext}"),
        ),
        (
            format!("lib/agent-audit-core.{ext}"),
            format!("agents/shared/agent-audit/lib/agent-audit-core.{ext}"),
        ),
        (
            format!("lib/seal.{ext}"),
            format!("agents/shared/agent-audit/lib/seal.{ext}"),
        ),
    ];
    for (rel, source) in sources {
        let rendered = fs::read(out.join(hooks_dir).join(&rel))
            .unwrap_or_else(|_| panic!("missing {hooks_dir}/{rel}"));
        let original = fs::read(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("..")
                .join(&source),
        )
        .unwrap_or_else(|_| panic!("missing component source {source}"));
        assert_eq!(rendered, original, "asset drift: {rel}");
    }
}

#[test]
fn local_audit_linux() {
    let out = render_cell(
        "local-audit-linux",
        AUDIT_CONF,
        None,
        Scope::Local,
        Os::Linux,
        Some(UNIX_TARGET),
    );
    assert_file(
        &out,
        ".claude/settings.local.json",
        include_str!("fixtures/local-audit-linux.settings.json"),
    );
    assert_file(
        &out,
        ".claude/hooks/agent-audit.conf",
        include_str!("fixtures/agent-audit-basic.conf"),
    );
    assert_file(&out, ".claude/.gitignore", "*\n");
    assert_file(&out, ".mcp.json", include_str!("fixtures/mcp.json"));
    assert_hook_assets(&out, ".claude/hooks", "sh");
}

#[test]
fn project_audit_linux_has_no_mcp() {
    let out = render_cell(
        "project-audit-linux",
        AUDIT_CONF,
        None,
        Scope::Project,
        Os::Linux,
        Some(UNIX_TARGET),
    );
    assert_file(
        &out,
        ".claude/settings.local.json",
        include_str!("fixtures/local-audit-linux.settings.json"),
    );
    assert!(
        !out.join(".mcp.json").exists(),
        ".mcp.json is local-scope only"
    );
}

#[test]
fn local_audit_windows_uses_exec_form() {
    let out = render_cell(
        "local-audit-windows",
        AUDIT_CONF,
        None,
        Scope::Local,
        Os::Windows,
        Some("C:/Users/user/proj"),
    );
    assert_file(
        &out,
        ".claude/settings.local.json",
        include_str!("fixtures/local-audit-windows.settings.json"),
    );
    assert_hook_assets(&out, ".claude/hooks", "ps1");
}

#[test]
fn local_telemetry_linux() {
    let out = render_cell(
        "local-telemetry-linux",
        TELEMETRY_CONF,
        None,
        Scope::Local,
        Os::Linux,
        Some(UNIX_TARGET),
    );
    assert_file(
        &out,
        ".claude/settings.local.json",
        include_str!("fixtures/local-telemetry.settings.json"),
    );
    assert_file(&out, ".mcp.json", include_str!("fixtures/mcp.json"));
    assert!(
        !out.join(".claude/hooks").exists(),
        "telemetry-only deploy carries no hooks"
    );
}

#[test]
fn local_telemetry_api_key_renders_auth_header() {
    let out = render_cell(
        "local-telemetry-key",
        TELEMETRY_CONF,
        Some("telemetry.apm_server.api_key=TESTKEY\n"),
        Scope::Local,
        Os::Linux,
        Some(UNIX_TARGET),
    );
    assert_file(
        &out,
        ".claude/settings.local.json",
        include_str!("fixtures/local-telemetry-key.settings.json"),
    );
}

#[test]
fn managed_audit_linux() {
    let out = render_cell(
        "managed-audit-linux",
        AUDIT_CONF,
        None,
        Scope::Managed,
        Os::Linux,
        None,
    );
    let root = "etc/claude-code";
    assert_file(
        &out,
        &format!("{root}/managed-settings.d/10-agent-observability-lab.json"),
        include_str!("fixtures/managed-audit-linux.fragment.json"),
    );
    assert_file(
        &out,
        &format!("{root}/hooks/agent-observability-lab/agent-audit.conf"),
        include_str!("fixtures/agent-audit-basic.conf"),
    );
    assert_hook_assets(&out, &format!("{root}/hooks/agent-observability-lab"), "sh");
}

#[test]
fn managed_audit_windows() {
    let out = render_cell(
        "managed-audit-windows",
        AUDIT_CONF,
        None,
        Scope::Managed,
        Os::Windows,
        None,
    );
    let root = "C/Program Files/ClaudeCode";
    assert_file(
        &out,
        &format!("{root}/managed-settings.d/10-agent-observability-lab.json"),
        include_str!("fixtures/managed-audit-windows.fragment.json"),
    );
    assert_hook_assets(
        &out,
        &format!("{root}/hooks/agent-observability-lab"),
        "ps1",
    );
}

#[test]
fn managed_audit_macos_paths() {
    let out = render_cell(
        "managed-audit-macos",
        AUDIT_CONF,
        None,
        Scope::Managed,
        Os::Macos,
        None,
    );
    let fragment = fs::read_to_string(out.join(
        "Library/Application Support/ClaudeCode/managed-settings.d/10-agent-observability-lab.json",
    ))
    .unwrap();
    assert!(fragment.contains(
        "'/Library/Application Support/ClaudeCode/hooks/agent-observability-lab/agent-audit.sh' --stream user_prompt"
    ));
}

#[test]
fn managed_telemetry_linux_drops_empty_headers() {
    let out = render_cell(
        "managed-telemetry-linux",
        TELEMETRY_CONF,
        None,
        Scope::Managed,
        Os::Linux,
        None,
    );
    assert_file(
        &out,
        "etc/claude-code/managed-settings.d/10-agent-observability-lab.json",
        include_str!("fixtures/managed-telemetry-linux.fragment.json"),
    );
    assert!(
        !out.join("etc/claude-code/hooks").exists(),
        "telemetry-only managed deploy carries no hooks"
    );
}

#[test]
fn managed_combined_linux() {
    let conf = format!("{TELEMETRY_CONF}{AUDIT_CONF}");
    let out = render_cell(
        "managed-combined-linux",
        &conf,
        Some("telemetry.apm_server.api_key=TESTKEY\n"),
        Scope::Managed,
        Os::Linux,
        None,
    );
    assert_file(
        &out,
        "etc/claude-code/managed-settings.d/10-agent-observability-lab.json",
        include_str!("fixtures/managed-combined-linux.fragment.json"),
    );
}

fn render_codex_cell(
    name: &str,
    conf: &str,
    local_conf: Option<&str>,
    scope: Scope,
    os: Os,
    target: Option<&str>,
) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(name);
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    let conf_path = dir.join("setup.conf");
    fs::write(&conf_path, conf).unwrap();
    if let Some(overlay) = local_conf {
        fs::write(dir.join("setup.local.conf"), overlay).unwrap();
    }
    let out = dir.join("out");
    let cfg = Config::load(&conf_path).unwrap();
    let cell = Cell {
        agent: Agent::Codex,
        scope,
        os,
        target: target.map(String::from),
    };
    let entries = agents::manifest(&cfg, &cell).unwrap();
    render::render(&entries, &out).unwrap();
    out
}

fn assert_codex_hook_assets(out: &Path, hooks_dir: &str, ext: &str) {
    let sources = [
        (
            format!("agent-audit.{ext}"),
            format!("agents/codex/hooks/agent-audit.{ext}"),
        ),
        (
            format!("lib/adapter.{ext}"),
            format!("agents/codex/hooks/lib/adapter.{ext}"),
        ),
        (
            format!("lib/agent-audit-core.{ext}"),
            format!("agents/shared/agent-audit/lib/agent-audit-core.{ext}"),
        ),
        (
            format!("lib/seal.{ext}"),
            format!("agents/shared/agent-audit/lib/seal.{ext}"),
        ),
    ];
    for (rel, source) in sources {
        let rendered = fs::read(out.join(hooks_dir).join(&rel))
            .unwrap_or_else(|_| panic!("missing {hooks_dir}/{rel}"));
        let original = fs::read(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("..")
                .join(&source),
        )
        .unwrap_or_else(|_| panic!("missing component source {source}"));
        assert_eq!(rendered, original, "asset drift: {rel}");
    }
}

#[test]
fn codex_local_audit_linux() {
    let out = render_codex_cell(
        "codex-local-audit-linux",
        AUDIT_CONF,
        None,
        Scope::Local,
        Os::Linux,
        Some(UNIX_TARGET),
    );
    assert_file(
        &out,
        ".codex/config.toml",
        include_str!("fixtures/codex-local-audit.config.toml"),
    );
    assert_file(
        &out,
        ".codex/hooks/agent-audit.conf",
        include_str!("fixtures/agent-audit-basic.conf"),
    );
    assert_file(&out, ".codex/.gitignore", "*\n");
    assert_codex_hook_assets(&out, ".codex/hooks", "sh");
}

#[test]
fn codex_project_audit_linux_has_no_mcp() {
    let out = render_codex_cell(
        "codex-project-audit-linux",
        AUDIT_CONF,
        None,
        Scope::Project,
        Os::Linux,
        Some(UNIX_TARGET),
    );
    assert_file(
        &out,
        ".codex/config.toml",
        include_str!("fixtures/codex-project-audit.config.toml"),
    );
}

#[test]
fn codex_local_audit_windows_backslashes_hook_paths() {
    let out = render_codex_cell(
        "codex-local-audit-windows",
        AUDIT_CONF,
        None,
        Scope::Local,
        Os::Windows,
        Some("C:/Users/user/proj"),
    );
    assert_file(
        &out,
        ".codex/config.toml",
        include_str!("fixtures/codex-local-audit-windows.config.toml"),
    );
    assert_codex_hook_assets(&out, ".codex/hooks", "ps1");
}

#[test]
fn codex_local_telemetry_linux() {
    let out = render_codex_cell(
        "codex-local-telemetry-linux",
        TELEMETRY_CONF,
        None,
        Scope::Local,
        Os::Linux,
        Some(UNIX_TARGET),
    );
    assert_file(
        &out,
        ".codex/config.toml",
        include_str!("fixtures/codex-local-telemetry.config.toml"),
    );
    assert!(!out.join(".codex/hooks").exists());
}

#[test]
fn codex_managed_audit_linux() {
    let out = render_codex_cell(
        "codex-managed-audit-linux",
        AUDIT_CONF,
        None,
        Scope::Managed,
        Os::Linux,
        None,
    );
    assert_file(
        &out,
        "etc/codex/requirements.toml",
        include_str!("fixtures/codex-requirements-linux.toml"),
    );
    assert_file(
        &out,
        "etc/codex/hooks/agent-observability-lab/agent-audit.conf",
        include_str!("fixtures/agent-audit-basic.conf"),
    );
    assert_codex_hook_assets(&out, "etc/codex/hooks/agent-observability-lab", "sh");
    assert!(!out.join("etc/codex/managed_config.toml").exists());
}

#[test]
fn codex_managed_audit_windows() {
    let out = render_codex_cell(
        "codex-managed-audit-windows",
        AUDIT_CONF,
        None,
        Scope::Managed,
        Os::Windows,
        None,
    );
    assert_file(
        &out,
        "C/ProgramData/OpenAI/Codex/requirements.toml",
        include_str!("fixtures/codex-requirements-windows.toml"),
    );
    assert_codex_hook_assets(
        &out,
        "C/ProgramData/OpenAI/Codex/hooks/agent-observability-lab",
        "ps1",
    );
}

#[test]
fn codex_managed_telemetry_linux() {
    let out = render_codex_cell(
        "codex-managed-telemetry-linux",
        TELEMETRY_CONF,
        Some("telemetry.apm_server.api_key=TESTKEY\n"),
        Scope::Managed,
        Os::Linux,
        None,
    );
    assert_file(
        &out,
        "etc/codex/managed_config.toml",
        include_str!("fixtures/codex-managed-config.toml"),
    );
    assert!(!out.join("etc/codex/requirements.toml").exists());
}

#[test]
fn codex_managed_telemetry_windows_targets_userprofile() {
    let out = render_codex_cell(
        "codex-managed-telemetry-windows",
        TELEMETRY_CONF,
        Some("telemetry.apm_server.api_key=TESTKEY\n"),
        Scope::Managed,
        Os::Windows,
        None,
    );
    assert_file(
        &out,
        "USERPROFILE/.codex/managed_config.toml",
        include_str!("fixtures/codex-managed-config.toml"),
    );
}
