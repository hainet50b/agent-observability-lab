use std::path::{Path, PathBuf};
use std::process::ExitCode;

use agent_config::config::Config;
use agent_config::model::{Agent, Cell, Os, Scope};
use agent_config::seal::{self, SealSource};
use agent_config::{agents, place, render};

const USAGE: &str = "usage:
  agent-config render   --config <setup.conf> --agent <claude|codex> --out <dir>
                        [--scope <local|project|managed>] [--os <linux|macos|windows>] [--target <dir>]
  agent-config place    --config <setup.conf> --agent <claude|codex> [--scope <local|project>] [--target <dir>]
  agent-config teardown --config <setup.conf> --agent <claude|codex> [--scope <local|project>] [--target <dir>]";

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("FAIL: {message}");
            ExitCode::from(2)
        }
    }
}

struct Args {
    config: PathBuf,
    agent: Agent,
    scope: Scope,
    os: Option<Os>,
    target: Option<String>,
    out: Option<PathBuf>,
}

fn parse_args(mut args: std::env::Args) -> Result<Args, String> {
    let mut config = None;
    let mut agent = None;
    let mut scope = Scope::Local;
    let mut os = None;
    let mut target = None;
    let mut out = None;
    while let Some(flag) = args.next() {
        let mut value = || args.next().ok_or(format!("{flag} needs a value"));
        match flag.as_str() {
            "--config" => config = Some(PathBuf::from(value()?)),
            "--agent" => agent = Some(Agent::parse(&value()?)?),
            "--scope" => scope = Scope::parse(&value()?)?,
            "--os" => os = Some(Os::parse(&value()?)?),
            "--target" => target = Some(value()?),
            "--out" => out = Some(PathBuf::from(value()?)),
            other => return Err(format!("unknown argument: {other}\n{USAGE}")),
        }
    }
    Ok(Args {
        config: config.ok_or("--config is required")?,
        agent: agent.ok_or("--agent is required")?,
        scope,
        os,
        target: target.map(|t| t.replace('\\', "/")),
        out,
    })
}

fn run() -> Result<(), String> {
    let mut argv = std::env::args();
    argv.next();
    let command = argv.next().ok_or(USAGE)?;
    let args = parse_args(argv)?;

    let cfg = Config::load(&args.config)?;
    let seal = resolve_seal(&cfg)?;

    match command.as_str() {
        "render" => {
            let cell = Cell {
                agent: args.agent,
                scope: args.scope,
                os: match args.os {
                    Some(os) => os,
                    None => Os::detect()?,
                },
                target: args.target,
            };
            if cell.scope == Scope::Managed && cell.target.is_some() {
                return Err("--scope managed does not take --target".into());
            }
            let entries = agents::manifest(&cfg, &cell, seal.as_ref())?;
            render::render(&entries, &args.out.ok_or("--out is required")?)
        }
        "place" | "teardown" => {
            if args.os.is_some() {
                return Err(format!("--os does not apply to {command} (host OS only)"));
            }
            if args.out.is_some() {
                return Err(format!("--out does not apply to {command}"));
            }
            let target_dir = resolve_target_dir(&args)?;
            let endpoint = cfg.marker_endpoint(args.scope);
            if command == "teardown" {
                return place::teardown(args.agent, &target_dir, &endpoint);
            }
            let cell = Cell {
                agent: args.agent,
                scope: args.scope,
                os: Os::detect()?,
                target: Some(canonical(&target_dir)?),
            };
            let entries = agents::manifest(&cfg, &cell, seal.as_ref())?;
            place::place(&entries, &target_dir, args.agent.name(), &endpoint)
        }
        _ => Err(USAGE.into()),
    }
}

fn resolve_seal(cfg: &Config) -> Result<Option<SealSource>, String> {
    let Some(audit) = &cfg.audit else {
        return Ok(None);
    };
    let recipients_root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join("sealing/recipients");
    seal::resolve(&recipients_root, audit)
}

fn resolve_target_dir(args: &Args) -> Result<PathBuf, String> {
    match args.scope {
        Scope::Local => {
            if args.target.is_some() {
                return Err(
                    "--scope local does not take --target (use --scope project to deploy into a directory)"
                        .into(),
                );
            }
            Ok(args
                .config
                .parent()
                .filter(|p| !p.as_os_str().is_empty())
                .unwrap_or(Path::new("."))
                .to_path_buf())
        }
        Scope::Project => args
            .target
            .as_ref()
            .map(PathBuf::from)
            .ok_or("--scope project requires --target <dir>".into()),
        Scope::Managed => {
            Err("managed placement is not implemented yet (arrives in a later stage)".into())
        }
    }
}

fn canonical(dir: &Path) -> Result<String, String> {
    std::fs::create_dir_all(dir).map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
    let abs = dir
        .canonicalize()
        .map_err(|e| format!("cannot resolve {}: {e}", dir.display()))?;
    let text = abs.display().to_string().replace('\\', "/");
    Ok(text.strip_prefix("//?/").unwrap_or(&text).to_string())
}
