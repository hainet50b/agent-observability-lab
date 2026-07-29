use std::path::PathBuf;
use std::process::ExitCode;

use agent_config::config::Config;
use agent_config::model::{Agent, Cell, Os, Scope};
use agent_config::{agents, render};

const USAGE: &str = "usage: agent-config render --config <setup.conf> --agent <claude|codex> \
--out <dir> [--scope <local|project|managed>] [--os <linux|macos|windows>] [--target <dir>]";

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("FAIL: {message}");
            ExitCode::from(2)
        }
    }
}

fn run() -> Result<(), String> {
    let mut args = std::env::args().skip(1);
    match args.next().as_deref() {
        Some("render") => {}
        _ => return Err(USAGE.into()),
    }

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

    let cell = Cell {
        agent: agent.ok_or("--agent is required")?,
        scope,
        os: match os {
            Some(os) => os,
            None => Os::detect()?,
        },
        target: target.map(|t| t.replace('\\', "/")),
    };
    if cell.scope == Scope::Managed && cell.target.is_some() {
        return Err("--scope managed does not take --target".into());
    }

    let cfg = Config::load(&config.ok_or("--config is required")?)?;
    let entries = agents::manifest(&cfg, &cell)?;
    render::render(&entries, &out.ok_or("--out is required")?)
}
