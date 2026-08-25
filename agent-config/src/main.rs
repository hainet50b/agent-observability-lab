use std::path::{Path, PathBuf};
use std::process::ExitCode;

use clap::{Args, Parser, Subcommand};

use agent_config::config::Config;
use agent_config::model::{Agent, Cell, Concern, Os, Scope};
use agent_config::seal::{self, SealSource};
use agent_config::{agents, place, render};

#[derive(Parser)]
#[command(
    name = "agent-config",
    about = "Render, place, and tear down agent config"
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
    /// Write a rendered bundle: a plain tree, or (--zip) versioned zip archives
    Render {
        #[command(flatten)]
        selection: Selection,
        /// Restrict to these concerns (repeatable or comma-separated; default: all declared)
        #[arg(long, value_parser = Concern::parse, value_delimiter = ',')]
        concern: Vec<Concern>,
        #[arg(long, value_parser = Scope::parse, default_value = "local")]
        scope: Scope,
        /// Restrict to these OSes (repeatable or comma-separated; default: every OS the scope makes available)
        #[arg(long, value_parser = Os::parse, value_delimiter = ',')]
        os: Vec<Os>,
        /// Declared project name (--scope project only; see [project.<name>] in --config)
        #[arg(long, value_name = "NAME")]
        project: Option<String>,
        /// Output directory (plain tree: required; --zip: defaults to dist/ beside --config)
        #[arg(long, value_name = "DIR")]
        out: Option<PathBuf>,
        /// Emit versioned zip archives (one per scope x OS cell) instead of a plain tree
        #[arg(long)]
        zip: bool,
        /// Re-emit unchanged --zip cells too
        #[arg(long)]
        all: bool,
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
        /// Declared project name (--scope project only; see [project.<name>] in --config)
        #[arg(long, value_name = "NAME")]
        project: Option<String>,
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
            project,
            out,
            zip,
            all,
        } => render_cmd(
            &selection,
            &concern,
            RenderArgs {
                scope,
                os,
                project,
                out,
                zip,
                all,
            },
        ),
        Command::Place {
            selection,
            concern,
            scope,
            project,
        } => place_cmd(&selection, &concern, scope, project),
        Command::Teardown {
            selection,
            scope,
            target,
        } => teardown_cmd(&selection, scope, target),
    }
}

struct RenderArgs {
    scope: Scope,
    os: Vec<Os>,
    project: Option<String>,
    out: Option<PathBuf>,
    zip: bool,
    all: bool,
}

fn render_cmd(selection: &Selection, concern: &[Concern], args: RenderArgs) -> Result<(), String> {
    let RenderArgs {
        scope,
        os,
        project,
        out,
        zip,
        all,
    } = args;
    if scope != Scope::Project && project.is_some() {
        return Err(format!(
            "--scope {} does not take --project (only --scope project does)",
            scope.name()
        ));
    }
    if !zip && all {
        return Err("--all only applies with --zip".into());
    }
    if zip && !concern.is_empty() {
        return Err(
            "--concern is not supported with --zip (archives always carry the full declaration)"
                .into(),
        );
    }

    let (cfg, seal) = load(selection, concern)?;
    let config_dir = config_dir(&selection.config);
    let (oses, project_target) = cfg.os_candidates(scope, project.as_deref(), &os, false)?;

    if oses.is_empty() {
        log(&format!(
            "--scope {}: skipped — no OS candidate survived filtering",
            scope.name()
        ));
        return Ok(());
    }

    if zip {
        let run = render::BundleRun {
            scope,
            oses,
            project: project_target.map(|target| render::ProjectSelection {
                name: project
                    .clone()
                    .expect("checked above: --project is Some for Scope::Project"),
                target: target.clone(),
            }),
            out_dir: out.unwrap_or_else(|| config_dir.join("dist")),
            emit_all: all,
        };
        for agent in agents_of(selection) {
            render::bundle(&cfg, seal.as_ref(), agent, &config_dir, &run)?;
        }
        return Ok(());
    }

    let out = out.ok_or(
        "--out <DIR> is required for a plain render (pass --zip to write archives to dist/ instead)",
    )?;
    for agent in agents_of(selection) {
        for &cell_os in &oses {
            let target = match scope {
                Scope::Managed => None,
                Scope::Local => Some(canonical(&config_dir)?),
                Scope::Project => Some(
                    project_target
                        .expect("resolved above for Scope::Project")
                        .for_os(cell_os)
                        .expect("os already filtered to declared targets")
                        .to_string(),
                ),
            };
            let cell = Cell {
                agent,
                scope,
                os: cell_os,
                target,
            };
            let entries = agents::manifest(&cfg, &cell, seal.as_ref())?;
            let dest = if oses.len() > 1 {
                out.join(cell_os.name())
            } else {
                out.clone()
            };
            render::render(&entries, &dest)?;
        }
    }
    Ok(())
}

fn place_cmd(
    selection: &Selection,
    concern: &[Concern],
    scope: Scope,
    project: Option<String>,
) -> Result<(), String> {
    if scope != Scope::Project && project.is_some() {
        return Err(format!(
            "--scope {} does not take --project (only --scope project does)",
            scope.name()
        ));
    }

    let (cfg, seal) = load(selection, concern)?;
    let (oses, project_target) = cfg.os_candidates(scope, project.as_deref(), &[], true)?;

    if oses.is_empty() {
        log(&format!(
            "--scope {}: skipped — no OS candidate matched the host",
            scope.name()
        ));
        return Ok(());
    }
    let os = oses[0];

    if scope == Scope::Managed {
        let mut confirm = place::TtyConfirm::new()?;
        for agent in agents_of(selection) {
            let cell = Cell {
                agent,
                scope,
                os,
                target: None,
            };
            let mut entries = agents::manifest(&cfg, &cell, seal.as_ref())?;
            let sidecars = place::sidecar_entries(&entries, &cfg.executor, agent, scope, os)?;
            entries.extend(sidecars);
            place::managed_place(&entries, &cfg.executor, &mut confirm)?;
        }
        return Ok(());
    }

    let target_dir = match scope {
        Scope::Local => config_dir(&selection.config),
        Scope::Project => PathBuf::from(
            project_target
                .expect("resolved above for Scope::Project")
                .for_os(os)
                .expect("os already filtered to declared targets")
                .to_string(),
        ),
        Scope::Managed => unreachable!("managed scope is handled above"),
    };
    for agent in agents_of(selection) {
        let cell = Cell {
            agent,
            scope,
            os,
            target: Some(canonical(&target_dir)?),
        };
        let mut entries = agents::manifest(&cfg, &cell, seal.as_ref())?;
        let sidecars = place::sidecar_entries(&entries, &cfg.executor, agent, scope, os)?;
        entries.extend(sidecars);
        place::place(&entries, &target_dir, &cfg.executor)?;
    }
    Ok(())
}

fn teardown_cmd(selection: &Selection, scope: Scope, target: Option<String>) -> Result<(), String> {
    let (cfg, _seal) = load(selection, &[])?;

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
            let candidates = match agent {
                Agent::Claude => agents::claude::managed_candidates(&cfg, os),
                Agent::Codex => agents::codex::managed_candidates(&cfg, os),
            };
            place::managed_teardown(&candidates, &root, &cfg.executor, &mut confirm)?;
        }
        return Ok(());
    }

    let target_dir = match scope {
        Scope::Local => {
            if target.is_some() {
                return Err(
                    "--scope local does not take --target (use --scope project to tear down a directory)"
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
        place::teardown(agent, &target_dir, &cfg.executor)?;
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

fn log(message: &str) {
    eprintln!("[agent-config] {message}");
}
