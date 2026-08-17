use crate::model::Flavor;

pub const OTEL_TEMPLATE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../agents/claude/templates/otel.template.json"
));
pub const HOOK_TEMPLATE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../agents/claude/templates/hook.template.json"
));
pub const MANAGED_SETTINGS_TEMPLATE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../agents/claude/templates/managed-settings.template.json"
));
pub const MCP_TEMPLATE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../agents/claude/templates/mcp.template.json"
));
pub const AGENT_AUDIT_CONF_TEMPLATE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../agents/claude/templates/agent-audit.template.conf"
));

pub const CODEX_OTEL_TEMPLATE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../agents/codex/templates/otel.template.toml"
));
pub const CODEX_HOOKS_TEMPLATE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../agents/codex/templates/hooks.template.toml"
));
pub const CODEX_MCP_TEMPLATE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../agents/codex/templates/mcp.template.toml"
));
pub const CODEX_MANAGED_CONFIG_TEMPLATE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../agents/codex/templates/managed_config.template.toml"
));
pub const CODEX_REQUIREMENTS_TEMPLATE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../agents/codex/templates/requirements.template.toml"
));
pub const CODEX_AGENT_AUDIT_CONF_TEMPLATE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../agents/codex/templates/agent-audit.template.conf"
));

pub struct Asset {
    pub rel: &'static str,
    pub bytes: &'static [u8],
    pub executable: bool,
}

pub fn codex_hooks(flavor: Flavor) -> [Asset; 4] {
    match flavor {
        Flavor::Sh => [
            Asset {
                rel: "agent-audit.sh",
                bytes: include_bytes!(concat!(
                    env!("CARGO_MANIFEST_DIR"),
                    "/../agents/codex/hooks/agent-audit.sh"
                )),
                executable: true,
            },
            Asset {
                rel: "lib/adapter.sh",
                bytes: include_bytes!(concat!(
                    env!("CARGO_MANIFEST_DIR"),
                    "/../agents/codex/hooks/lib/adapter.sh"
                )),
                executable: false,
            },
            Asset {
                rel: "lib/agent-audit-core.sh",
                bytes: include_bytes!(concat!(
                    env!("CARGO_MANIFEST_DIR"),
                    "/../agents/shared/agent-audit/lib/agent-audit-core.sh"
                )),
                executable: false,
            },
            Asset {
                rel: "lib/seal.sh",
                bytes: include_bytes!(concat!(
                    env!("CARGO_MANIFEST_DIR"),
                    "/../agents/shared/agent-audit/lib/seal.sh"
                )),
                executable: false,
            },
        ],
        Flavor::Ps1 => [
            Asset {
                rel: "agent-audit.ps1",
                bytes: include_bytes!(concat!(
                    env!("CARGO_MANIFEST_DIR"),
                    "/../agents/codex/hooks/agent-audit.ps1"
                )),
                executable: false,
            },
            Asset {
                rel: "lib/adapter.ps1",
                bytes: include_bytes!(concat!(
                    env!("CARGO_MANIFEST_DIR"),
                    "/../agents/codex/hooks/lib/adapter.ps1"
                )),
                executable: false,
            },
            Asset {
                rel: "lib/agent-audit-core.ps1",
                bytes: include_bytes!(concat!(
                    env!("CARGO_MANIFEST_DIR"),
                    "/../agents/shared/agent-audit/lib/agent-audit-core.ps1"
                )),
                executable: false,
            },
            Asset {
                rel: "lib/seal.ps1",
                bytes: include_bytes!(concat!(
                    env!("CARGO_MANIFEST_DIR"),
                    "/../agents/shared/agent-audit/lib/seal.ps1"
                )),
                executable: false,
            },
        ],
    }
}

pub fn claude_hooks(flavor: Flavor) -> [Asset; 4] {
    match flavor {
        Flavor::Sh => [
            Asset {
                rel: "agent-audit.sh",
                bytes: include_bytes!(concat!(
                    env!("CARGO_MANIFEST_DIR"),
                    "/../agents/claude/hooks/agent-audit.sh"
                )),
                executable: true,
            },
            Asset {
                rel: "lib/adapter.sh",
                bytes: include_bytes!(concat!(
                    env!("CARGO_MANIFEST_DIR"),
                    "/../agents/claude/hooks/lib/adapter.sh"
                )),
                executable: false,
            },
            Asset {
                rel: "lib/agent-audit-core.sh",
                bytes: include_bytes!(concat!(
                    env!("CARGO_MANIFEST_DIR"),
                    "/../agents/shared/agent-audit/lib/agent-audit-core.sh"
                )),
                executable: false,
            },
            Asset {
                rel: "lib/seal.sh",
                bytes: include_bytes!(concat!(
                    env!("CARGO_MANIFEST_DIR"),
                    "/../agents/shared/agent-audit/lib/seal.sh"
                )),
                executable: false,
            },
        ],
        Flavor::Ps1 => [
            Asset {
                rel: "agent-audit.ps1",
                bytes: include_bytes!(concat!(
                    env!("CARGO_MANIFEST_DIR"),
                    "/../agents/claude/hooks/agent-audit.ps1"
                )),
                executable: false,
            },
            Asset {
                rel: "lib/adapter.ps1",
                bytes: include_bytes!(concat!(
                    env!("CARGO_MANIFEST_DIR"),
                    "/../agents/claude/hooks/lib/adapter.ps1"
                )),
                executable: false,
            },
            Asset {
                rel: "lib/agent-audit-core.ps1",
                bytes: include_bytes!(concat!(
                    env!("CARGO_MANIFEST_DIR"),
                    "/../agents/shared/agent-audit/lib/agent-audit-core.ps1"
                )),
                executable: false,
            },
            Asset {
                rel: "lib/seal.ps1",
                bytes: include_bytes!(concat!(
                    env!("CARGO_MANIFEST_DIR"),
                    "/../agents/shared/agent-audit/lib/seal.ps1"
                )),
                executable: false,
            },
        ],
    }
}
