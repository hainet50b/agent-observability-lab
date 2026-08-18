use std::path::{Path, PathBuf};
use std::process::ExitCode;

use clap::{Args, Parser, Subcommand};

use agent_config::config::Config;
use agent_config::model::{Agent, Cell, Concern, Os, Scope};
use agent_config::seal::{self, SealSource};
use agent_config::{agents, bundle, place, render};

#[derive(Parser)]
#[command(
    name = "agent-config",
    about = "Render, place, tear down, and bundle agent config"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Args)]
struct Selection {
    /// Agent data-plane config declaring the telemetry / audit concerns
    #[arg(long, value_name = "FILE")]
    config: PathBuf,
    /// One or more agents (repeatable or comma-separated)
    #[arg(long, value_parser = Agent::parse, value_delimiter = ',', required = true)]
    agent: Vec<Agent>,
    /// Secrets overlay (default: agent-config.local.conf beside --config)
    #[arg(long, value_name = "FILE")]
    local_conf: Option<PathBuf>,
    /// Seal recipients root holding <epoch>/recipient.pem (default: sealing/recipients beside --config)
    #[arg(long, value_name = "DIR")]
    seal_recipients: Option<PathBuf>,
    /// Seal recipient cert, bypassing the recipients root
    #[arg(long, value_name = "FILE")]
    seal_cert: Option<PathBuf>,
}

#[derive(Subcommand)]
enum Command {
    /// Write a rendered bundle tree to a directory
    Render {
        #[command(flatten)]
        selection: Selection,
        /// Restrict to these concerns (repeatable or comma-separated; default: all declared)
        #[arg(long, value_parser = Concern::parse, value_delimiter = ',')]
        concern: Vec<Concern>,
        #[arg(long, value_parser = Scope::parse, default_value = "local")]
        scope: Scope,
        /// Target OS (defaults to the host OS)
        #[arg(long, value_parser = Os::parse)]
        os: Option<Os>,
        /// Deploy path baked into the rendered content (local/project scopes)
        #[arg(long, value_name = "DIR")]
        target: Option<String>,
        /// Directory the rendered tree is written to
        #[arg(long, value_name = "DIR")]
        out: PathBuf,
    },
    /// Deploy the bundle to a live target (marker-aware, fail-if-foreign)
    Place {
        #[command(flatten)]
        selection: Selection,
        /// Restrict to these concerns (repeatable or comma-separated; default: all declared)
        #[arg(long, value_parser = Concern::parse, value_delimiter = ',')]
        concern: Vec<Concern>,
        #[arg(long, value_parser = Scope::parse, default_value = "local")]
        scope: Scope,
        /// Deploy directory (--scope project only)
        #[arg(long, value_name = "DIR")]
        target: Option<String>,
    },
    /// Remove a placed bundle (only files whose marker carries this executor)
    Teardown {
        #[command(flatten)]
        selection: Selection,
        #[arg(long, value_parser = Scope::parse, default_value = "local")]
        scope: Scope,
        /// Deploy directory (--scope project only)
        #[arg(long, value_name = "DIR")]
        target: Option<String>,
    },
    /// Emit versioned zip archives per scope x OS cell
    Bundle {
        #[command(flatten)]
        selection: Selection,
        /// Restrict to one scope (default: local and managed; project needs --target)
        #[arg(long, value_parser = Scope::parse)]
        scope: Option<Scope>,
        /// Restrict to one OS (default: all three)
        #[arg(long, value_parser = Os::parse)]
        os: Option<Os>,
        /// Deploy path baked into local/project cells
        #[arg(long, value_name = "DIR")]
        target: Option<String>,
        /// Archive output directory (default: dist/ beside the config)
        #[arg(long, value_name = "DIR")]
        out: Option<PathBuf>,
        /// Re-emit unchanged cells too
        #[arg(long)]
        all: bool,
    },
}

fn main() -> ExitCode {
    match run(Cli::parse()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("FAIL: {message}");
            ExitCode::from(2)
        }
    }
}

fn run(cli: Cli) -> Result<(), String> {
    match cli.command {
        Command::Render {
            selection,
            concern,
            scope,
            os,
            target,
            out,
        } => {
            let (cfg, seal) = load(&selection, &concern)?;
            let os = resolve_os(os)?;
            let target = target.map(normalize_path);
            if scope == Scope::Managed && target.is_some() {
                return Err("--scope managed does not take --target".into());
            }
            for agent in agents_of(&selection) {
                let cell = Cell {
                    agent,
                    scope,
                    os,
                    target: target.clone(),
                };
                let entries = agents::manifest(&cfg, &cell, seal.as_ref())?;
                render::render(&entries, &out)?;
            }
            Ok(())
        }
        Command::Place {
            selection,
            concern,
            scope,
            target,
        } => deploy(&selection, &concern, scope, target, false),
        Command::Teardown {
            selection,
            scope,
            target,
        } => deploy(&selection, &[], scope, target, true),
        Command::Bundle {
            selection,
            scope,
            os,
            target,
            out,
            all,
        } => {
            let (cfg, seal) = load(&selection, &[])?;
            let config_dir = config_dir(&selection.config);
            let target = target.map(normalize_path);
            let scopes = match scope {
                Some(scope) => vec![scope],
                None if target.is_some() => vec![Scope::Local, Scope::Project, Scope::Managed],
                None => vec![Scope::Local, Scope::Managed],
            };
            let run = bundle::BundleRun {
                scopes,
                oses: match os {
                    Some(os) => vec![os],
                    None => Os::ALL.to_vec(),
                },
                target,
                out_dir: out.unwrap_or_else(|| config_dir.join("dist")),
                emit_all: all,
            };
            for agent in agents_of(&selection) {
                bundle::bundle(&cfg, seal.as_ref(), agent, &config_dir, &run)?;
            }
            Ok(())
        }
    }
}

fn deploy(
    selection: &Selection,
    concerns: &[Concern],
    scope: Scope,
    target: Option<String>,
    teardown: bool,
) -> Result<(), String> {
    let (cfg, seal) = load(selection, concerns)?;

    if scope == Scope::Managed {
        if target.is_some() {
            return Err("--scope managed does not take --target".into());
        }
        let os = Os::detect()?;
        let mut confirm = place::TtyConfirm::new()?;
        for agent in agents_of(selection) {
            let root = PathBuf::from(match agent {
                Agent::Claude => agents::claude::managed_root(os),
                Agent::Codex => agents::codex::managed_root(os),
            });
            if teardown {
                let candidates = match agent {
                    Agent::Claude => agents::claude::managed_candidates(&cfg, os),
                    Agent::Codex => agents::codex::managed_candidates(&cfg, os),
                };
                place::managed_teardown(&candidates, &root, &cfg.executor, &mut confirm)?;
                continue;
            }
            let cell = Cell {
                agent,
                scope,
                os,
                target: None,
            };
            let entries = agents::manifest(&cfg, &cell, seal.as_ref())?;
            place::managed_place(&entries, &cfg.executor, &mut confirm)?;
        }
        return Ok(());
    }

    let target_dir = match scope {
        Scope::Local => {
            if target.is_some() {
                return Err(
                    "--scope local does not take --target (use --scope project to deploy into a directory)"
                        .into(),
                );
            }
            config_dir(&selection.config)
        }
        Scope::Project => PathBuf::from(
            target
                .map(normalize_path)
                .ok_or("--scope project requires --target <dir>")?,
        ),
        Scope::Managed => unreachable!("managed scope is handled above"),
    };
    for agent in agents_of(selection) {
        if teardown {
            place::teardown(agent, &target_dir, &cfg.executor)?;
            continue;
        }
        let cell = Cell {
            agent,
            scope,
            os: Os::detect()?,
            target: Some(canonical(&target_dir)?),
        };
        let entries = agents::manifest(&cfg, &cell, seal.as_ref())?;
        place::place(&entries, &target_dir, &cfg.executor)?;
    }
    Ok(())
}

fn agents_of(selection: &Selection) -> Vec<Agent> {
    let mut agents = Vec::new();
    for &agent in &selection.agent {
        if !agents.contains(&agent) {
            agents.push(agent);
        }
    }
    agents
}

fn load(
    selection: &Selection,
    concerns: &[Concern],
) -> Result<(Config, Option<SealSource>), String> {
    let mut cfg = Config::load(&selection.config, selection.local_conf.as_deref())?;
    cfg.retain_concerns(concerns)?;
    let seal = match &cfg.audit {
        Some(audit) => seal::resolve(
            &config_dir(&selection.config),
            audit,
            selection.seal_recipients.as_deref(),
            selection.seal_cert.as_deref(),
        )?,
        None => {
            if selection.seal_recipients.is_some() || selection.seal_cert.is_some() {
                return Err(
                    "--seal-recipients/--seal-cert apply only to a config with agent_audit.* keys"
                        .into(),
                );
            }
            None
        }
    };
    let on_off = |present: bool| if present { "on" } else { "off" };
    eprintln!(
        "[agent-config] concerns: telemetry={} audit={}",
        on_off(cfg.telemetry.is_some()),
        on_off(cfg.audit.is_some())
    );
    Ok((cfg, seal))
}

fn resolve_os(os: Option<Os>) -> Result<Os, String> {
    match os {
        Some(os) => Ok(os),
        None => Os::detect(),
    }
}

fn config_dir(config: &Path) -> PathBuf {
    agent_config::config::conf_dir(config)
}

fn normalize_path(path: String) -> String {
    path.replace('\\', "/")
}

fn canonical(dir: &Path) -> Result<String, String> {
    std::fs::create_dir_all(dir).map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
    let abs = dir
        .canonicalize()
        .map_err(|e| format!("cannot resolve {}: {e}", dir.display()))?;
    let text = abs.display().to_string().replace('\\', "/");
    Ok(text.strip_prefix("//?/").unwrap_or(&text).to_string())
}
