use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};
use zip::ZipWriter;
use zip::write::SimpleFileOptions;

use crate::config::{Config, ProjectTarget};
use crate::model::{Agent, Cell, Entry, Os, Scope};
use crate::seal::SealSource;

pub fn render(entries: &[Entry], out_dir: &Path) -> Result<(), String> {
    for entry in entries {
        let Some((bytes, executable)) = entry.content.rendered() else {
            continue;
        };
        let rel = entry.location.render_rel()?;
        let dest = out_dir.join(&rel);
        let dir = dest
            .parent()
            .expect("render destination always has a parent");
        fs::create_dir_all(dir).map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
        fs::write(&dest, &bytes).map_err(|e| format!("cannot write {}: {e}", dest.display()))?;
        #[cfg(unix)]
        if executable {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&dest, fs::Permissions::from_mode(0o755))
                .map_err(|e| format!("cannot set mode on {}: {e}", dest.display()))?;
        }
        #[cfg(not(unix))]
        let _ = executable;
        eprintln!("[agent-config] {}: rendered {}", entry.key, dest.display());
    }
    Ok(())
}

pub struct BundleRun {
    pub scope: Scope,
    pub oses: Vec<Os>,
    pub project: Option<ProjectSelection>,
    pub out_dir: PathBuf,
    pub emit_all: bool,
}

pub struct ProjectSelection {
    pub name: String,
    pub target: ProjectTarget,
}

struct RenderedFile {
    rel: String,
    bytes: Vec<u8>,
    executable: bool,
}

pub fn bundle(
    cfg: &Config,
    seal: Option<&SealSource>,
    agent: Agent,
    config_dir: &Path,
    run: &BundleRun,
) -> Result<(), String> {
    let today = crate::clock::utc_today_compact();

    fs::create_dir_all(&run.out_dir)
        .map_err(|e| format!("cannot create {}: {e}", run.out_dir.display()))?;

    let mut ledger = load_ledger(config_dir, &cfg.executor, run.scope, &today)?;
    let mut changed = 0;

    for &os in &run.oses {
        let cell_name = format!("{}/{}/{}", agent.name(), run.scope.name(), os.name());
        let target = match run.scope {
            Scope::Managed => None,
            Scope::Local => Some(canonical_dir(config_dir)?),
            Scope::Project => {
                let sel = run
                    .project
                    .as_ref()
                    .expect("project scope requires a resolved project selection");
                Some(
                    sel.target
                        .for_os(os)
                        .expect("os already filtered to declared targets")
                        .to_string(),
                )
            }
        };
        let cell = Cell {
            agent,
            scope: run.scope,
            os,
            target,
        };
        let mut files = rendered_files(cfg, &cell, seal)?;
        if files.is_empty() {
            return Err(format!("{cell_name}: rendered nothing"));
        }
        files.sort_by(|a, b| a.rel.cmp(&b.rel));
        let manifest = cell_manifest(&files);
        let hash = cell_hash(&manifest);

        let key = ledger_key(
            agent,
            run.scope,
            os,
            run.project.as_ref().map(|p| p.name.as_str()),
        );
        let old_hash = ledger.entries.get(&format!("{key}.hash")).cloned();
        let old_version = ledger.entries.get(&format!("{key}.version")).cloned();
        let (version, cell_changed) = match (old_hash, old_version) {
            (Some(h), Some(v)) if h == hash => (v, false),
            _ => (ledger.new_version.clone(), true),
        };
        ledger
            .entries
            .insert(format!("{key}.version"), version.clone());
        ledger.entries.insert(format!("{key}.hash"), hash);
        if cell_changed {
            changed += 1;
            ledger.changed = true;
        }

        if !cell_changed && !run.emit_all {
            log(&format!("{cell_name}: unchanged since {version} — skipped"));
            continue;
        }

        files.push(RenderedFile {
            rel: sidecar_file_rel("version", &cfg.executor, agent, &cell)?,
            bytes: format!("{version}\n").into_bytes(),
            executable: false,
        });
        files.push(RenderedFile {
            rel: sidecar_file_rel("sha256", &cfg.executor, agent, &cell)?,
            bytes: manifest.into_bytes(),
            executable: false,
        });

        let prefix = format!(
            "{}-{}-{}-{}-",
            cfg.executor,
            agent.name(),
            run.scope.name(),
            os.name()
        );
        remove_stale_archives(&run.out_dir, &prefix)?;
        let archive = run.out_dir.join(format!("{prefix}{version}.zip"));
        write_zip(&archive, &files)?;
        if cell_changed {
            log(&format!(
                "{cell_name}: CHANGED -> {version} — wrote {}",
                archive.display()
            ));
        } else {
            log(&format!(
                "{cell_name}: unchanged, re-emitted {version} — wrote {}",
                archive.display()
            ));
        }
    }

    if ledger.changed {
        write_ledger(&ledger.path, &ledger.entries)?;
        log(&format!(
            "ledger updated: {} (commit it)",
            ledger.path.display()
        ));
    }
    if changed == 0 {
        log("no cells changed — ledgers untouched");
    }
    Ok(())
}

fn rendered_files(
    cfg: &Config,
    cell: &Cell,
    seal: Option<&SealSource>,
) -> Result<Vec<RenderedFile>, String> {
    let entries = crate::agents::manifest(cfg, cell, seal)?;
    let mut files = Vec::new();
    for entry in &entries {
        let Some((bytes, executable)) = entry.content.rendered() else {
            continue;
        };
        files.push(RenderedFile {
            rel: entry.location.render_rel()?,
            bytes,
            executable,
        });
    }
    Ok(files)
}

fn sidecar_file_rel(
    ext: &str,
    executor: &str,
    agent: Agent,
    cell: &Cell,
) -> Result<String, String> {
    let file_name = format!("{executor}.{ext}");
    match cell.scope {
        Scope::Managed => {
            let root = match agent {
                Agent::Claude => crate::agents::claude::managed_root(cell.os),
                Agent::Codex => crate::agents::codex::managed_root(cell.os),
            };
            let rel = crate::model::Location::Host(format!("{root}/{file_name}")).render_rel()?;
            Ok(rel)
        }
        Scope::Local | Scope::Project => Ok(format!("{}/{file_name}", agent.home())),
    }
}

fn cell_manifest(files: &[RenderedFile]) -> String {
    let mut manifest = String::new();
    for file in files {
        manifest.push_str(&hex(&Sha256::digest(&file.bytes)));
        manifest.push_str("  ");
        manifest.push_str(&file.rel);
        manifest.push('\n');
    }
    manifest
}

fn cell_hash(manifest: &str) -> String {
    hex(&Sha256::digest(manifest.as_bytes()))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn write_zip(archive: &Path, files: &[RenderedFile]) -> Result<(), String> {
    let out = fs::File::create(archive)
        .map_err(|e| format!("cannot create {}: {e}", archive.display()))?;
    let mut zip = ZipWriter::new(out);
    for file in files {
        let mode = if file.executable { 0o755 } else { 0o644 };
        let options = SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated)
            .unix_permissions(mode);
        zip.start_file(&file.rel, options)
            .map_err(|e| format!("{}: cannot add {}: {e}", archive.display(), file.rel))?;
        zip.write_all(&file.bytes)
            .map_err(|e| format!("{}: cannot write {}: {e}", archive.display(), file.rel))?;
    }
    zip.finish()
        .map_err(|e| format!("cannot finalize {}: {e}", archive.display()))?;
    Ok(())
}

fn remove_stale_archives(out_dir: &Path, prefix: &str) -> Result<(), String> {
    let entries = match fs::read_dir(out_dir) {
        Ok(entries) => entries,
        Err(_) => return Ok(()),
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with(prefix) && name.ends_with(".zip") {
            fs::remove_file(entry.path())
                .map_err(|e| format!("cannot remove stale {}: {e}", entry.path().display()))?;
        }
    }
    Ok(())
}

struct Ledger {
    path: PathBuf,
    entries: BTreeMap<String, String>,
    new_version: String,
    changed: bool,
}

fn ledger_file_name(executor: &str, scope: Scope) -> String {
    format!("{executor}-{}-versions.conf", scope.name())
}

fn load_ledger(
    config_dir: &Path,
    executor: &str,
    scope: Scope,
    today: &str,
) -> Result<Ledger, String> {
    let path = config_dir.join(ledger_file_name(executor, scope));
    let entries = read_ledger(&path)?;
    let max_seq = entries
        .values()
        .filter_map(|value| value.strip_prefix(&format!("{today}-")))
        .filter_map(|seq| seq.parse::<u32>().ok())
        .max()
        .unwrap_or(0);
    Ok(Ledger {
        path,
        entries,
        new_version: format!("{today}-{:04}", max_seq + 1),
        changed: false,
    })
}

fn ledger_key(agent: Agent, scope: Scope, os: Os, project_name: Option<&str>) -> String {
    match scope {
        Scope::Managed | Scope::Local => format!("{}.{}", agent.name(), os.name()),
        Scope::Project => format!(
            "{}.{}.{}",
            agent.name(),
            project_name.expect("project scope requires a resolved project name"),
            os.name()
        ),
    }
}

fn read_ledger(path: &Path) -> Result<BTreeMap<String, String>, String> {
    let mut ledger = BTreeMap::new();
    let Ok(text) = fs::read_to_string(path) else {
        return Ok(ledger);
    };
    for line in text.lines() {
        if let Some((key, value)) = line.trim_end_matches('\r').split_once('=') {
            ledger.insert(key.to_string(), value.to_string());
        }
    }
    Ok(ledger)
}

fn write_ledger(path: &Path, ledger: &BTreeMap<String, String>) -> Result<(), String> {
    let mut text = String::new();
    for (key, value) in ledger {
        text.push_str(key);
        text.push('=');
        text.push_str(value);
        text.push('\n');
    }
    fs::write(path, text).map_err(|e| format!("cannot write {}: {e}", path.display()))
}

fn canonical_dir(dir: &Path) -> Result<String, String> {
    let abs = dir
        .canonicalize()
        .map_err(|e| format!("cannot resolve {}: {e}", dir.display()))?;
    let text = abs.display().to_string().replace('\\', "/");
    Ok(text.strip_prefix("//?/").unwrap_or(&text).to_string())
}

fn log(message: &str) {
    eprintln!("[agent-config] {message}");
}
