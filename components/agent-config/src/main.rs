use std::path::{Path, PathBuf};
use std::process::ExitCode;

use clap::{Args, Parser, Subcommand};

use agent_config::config::Config;
use agent_config::model::{Agent, Cell, Os, Scope};
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
    /// Stack setup.conf declaring the telemetry / audit concerns
    #[arg(long, value_name = "FILE")]
    config: PathBuf,
    #[arg(long, value_parser = Agent::parse)]
    agent: Agent,
}

#[derive(Subcommand)]
enum Command {
    /// Write a rendered bundle tree to a directory
    Render {
        #[command(flatten)]
        selection: Selection,
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
        #[arg(long, value_parser = Scope::parse, default_value = "local")]
        scope: Scope,
        /// Deploy directory (--scope project only)
        #[arg(long, value_name = "DIR")]
        target: Option<String>,
    },
    /// Remove a placed bundle (only files whose marker matches this deploy)
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
            scope,
            os,
            target,
            out,
        } => {
            let (cfg, seal) = load(&selection)?;
            let cell = Cell {
                agent: selection.agent,
                scope,
                os: resolve_os(os)?,
                target: target.map(normalize_path),
            };
            if cell.scope == Scope::Managed && cell.target.is_some() {
                return Err("--scope managed does not take --target".into());
            }
            let entries = agents::manifest(&cfg, &cell, seal.as_ref())?;
            render::render(&entries, &out)
        }
        Command::Place {
            selection,
            scope,
            target,
        } => deploy(&selection, scope, target, false),
        Command::Teardown {
            selection,
            scope,
            target,
        } => deploy(&selection, scope, target, true),
        Command::Bundle {
            selection,
            scope,
            os,
            target,
            out,
            all,
        } => {
            let (cfg, seal) = load(&selection)?;
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
            bundle::bundle(&cfg, seal.as_ref(), selection.agent, &config_dir, &run)
        }
    }
}

fn deploy(
    selection: &Selection,
    scope: Scope,
    target: Option<String>,
    teardown: bool,
) -> Result<(), String> {
    let (cfg, seal) = load(selection)?;
    let endpoint = cfg.marker_endpoint(scope);

    if scope == Scope::Managed {
        if target.is_some() {
            return Err("--scope managed does not take --target".into());
        }
        let os = Os::detect()?;
        let mut confirm = place::TtyConfirm::new()?;
        let root = PathBuf::from(match selection.agent {
            Agent::Claude => agents::claude::managed_root(os),
            Agent::Codex => agents::codex::managed_root(os),
        });
        if teardown {
            let candidates = match selection.agent {
                Agent::Claude => agents::claude::managed_candidates(&cfg, os),
                Agent::Codex => agents::codex::managed_candidates(&cfg, os),
            };
            return place::managed_teardown(&candidates, &root, &mut confirm);
        }
        let cell = Cell {
            agent: selection.agent,
            scope,
            os,
            target: None,
        };
        let entries = agents::manifest(&cfg, &cell, seal.as_ref())?;
        return place::managed_place(&entries, selection.agent.name(), &endpoint, &mut confirm);
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
    if teardown {
        return place::teardown(selection.agent, &target_dir, &endpoint);
    }
    let cell = Cell {
        agent: selection.agent,
        scope,
        os: Os::detect()?,
        target: Some(canonical(&target_dir)?),
    };
    let entries = agents::manifest(&cfg, &cell, seal.as_ref())?;
    place::place(&entries, &target_dir, selection.agent.name(), &endpoint)
}

fn load(selection: &Selection) -> Result<(Config, Option<SealSource>), String> {
    let cfg = Config::load(&selection.config)?;
    let seal = match &cfg.audit {
        Some(audit) => seal::resolve(&config_dir(&selection.config), audit)?,
        None => None,
    };
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
