use std::fs;
use std::path::{Path, PathBuf};

use crate::model::{Agent, Content, Entry, Location, Os, Scope};

const MARKER_SUFFIX: &str = ".managed";

/// `.version` (always the fixed `{today}-0001`, never looked up or minted —
/// `place` never touches a ledger) and `.sha256` (the fresh manifest of
/// `entries`) sidecars for a placed cell, mirroring the `--zip` sidecars at
/// the same placement rule: managed root for managed cells, agent home for
/// user-scope cells.
pub fn sidecar_entries(
    entries: &[Entry],
    executor: &str,
    agent: Agent,
    scope: Scope,
    os: Os,
) -> Result<Vec<Entry>, String> {
    let manifest = crate::render::manifest_of(entries)?;
    let version = format!("{}-0001\n", crate::clock::utc_today_compact());
    let location = |ext: &str| -> Location {
        match scope {
            Scope::Managed => {
                let root = match agent {
                    Agent::Claude => crate::agents::claude::managed_root(os),
                    Agent::Codex => crate::agents::codex::managed_root(os),
                };
                Location::Host(format!("{root}/{executor}.{ext}"))
            }
            Scope::Local | Scope::Project => {
                Location::InTarget(format!("{}/{executor}.{ext}", agent.home()))
            }
        }
    };
    Ok(vec![
        Entry::marked_file("version", location("version"), version),
        Entry::marked_file("sha256", location("sha256"), manifest),
    ])
}

pub fn place(entries: &[Entry], target_dir: &Path, executor: &str) -> Result<(), String> {
    for entry in entries {
        let path = target_path(entry, target_dir)?;
        if entry_is_marked(entry) {
            assert_ours_or_absent(&entry.key, executor, &path)?;
        }
    }

    for entry in entries {
        let path = target_path(entry, target_dir)?;
        match &entry.content {
            Content::File {
                bytes,
                executable,
                marked,
            } => {
                write_file(&entry.key, &path, bytes, *executable)?;
                if *marked {
                    write_marker(executor, &path)?;
                }
                log(&format!("{}: wrote {}", entry.key, path.display()));
            }
            Content::JsonKeys(keys) => {
                let base = if path.exists() {
                    let text = fs::read_to_string(&path).map_err(|e| {
                        format!("{}: could not read {}: {e}", entry.key, path.display())
                    })?;
                    serde_json::from_str(&text).map_err(|e| {
                        format!("{}: {} is not valid JSON: {e}", entry.key, path.display())
                    })?
                } else {
                    serde_json::Value::Object(serde_json::Map::new())
                };
                let mut merged = base;
                for (key, value) in keys {
                    merged[key.as_str()] = value.clone();
                }
                write_file(
                    &entry.key,
                    &path,
                    crate::model::json_pretty(&merged).as_bytes(),
                    false,
                )?;
                write_marker(executor, &path)?;
                log(&format!("{}: wrote {}", entry.key, path.display()));
            }
            Content::TomlSections(sections) => {
                if path.exists() {
                    let mut text = fs::read_to_string(&path).map_err(|e| {
                        format!("{}: could not read {}: {e}", entry.key, path.display())
                    })?;
                    for section in sections {
                        if text.contains(&section.sentinel) {
                            log(&format!(
                                "{}: {} already present in {} — no-op.",
                                entry.key,
                                section.sentinel,
                                path.display()
                            ));
                        } else {
                            text.push('\n');
                            text.push_str(&section.text);
                            log(&format!(
                                "{}: appended {} to {}",
                                entry.key,
                                section.sentinel,
                                path.display()
                            ));
                        }
                    }
                    write_file(&entry.key, &path, text.as_bytes(), false)?;
                } else {
                    let texts: Vec<&str> = sections.iter().map(|s| s.text.as_str()).collect();
                    write_file(&entry.key, &path, texts.join("\n").as_bytes(), false)?;
                    write_marker(executor, &path)?;
                    log(&format!("{}: wrote {}", entry.key, path.display()));
                }
            }
            Content::AuthLink { source } => {
                place_auth_link(&entry.key, source, &path, executor)?;
            }
        }
    }
    Ok(())
}

pub fn teardown(agent: Agent, target_dir: &Path, executor: &str) -> Result<(), String> {
    let (targets, hooks_dir, anchor) = match agent {
        Agent::Claude => crate::agents::claude::teardown_targets(executor),
        Agent::Codex => crate::agents::codex::teardown_targets(executor),
    };

    let anchor_path = target_dir.join(anchor);
    let hooks_owned = marker_field(&marker_path(&anchor_path), "executor")
        .is_some_and(|marker_executor| marker_executor == executor);

    let mut failed = false;
    for (key, rel) in targets {
        remove_file(key, executor, &target_dir.join(rel), &mut failed);
    }

    let hooks_path = target_dir.join(hooks_dir);
    if hooks_owned && hooks_path.is_dir() {
        fs::remove_dir_all(&hooks_path)
            .map_err(|e| format!("hooks: could not remove {}: {e}", hooks_path.display()))?;
        log(&format!("hooks: removed {}", hooks_path.display()));
    }

    if failed {
        return Err(
            "one or more files were refused (see above); nothing foreign was removed".into(),
        );
    }

    let home = target_dir.join(Path::new(anchor).components().next().unwrap());
    if fs::remove_dir(&home).is_ok() {
        log(&format!("removed empty {}", home.display()));
    }
    Ok(())
}

pub trait Confirm {
    fn confirm(&mut self, prompt: &str) -> Result<bool, String>;
}

pub struct TtyConfirm {
    yes_all: bool,
}

impl TtyConfirm {
    pub fn new() -> Result<TtyConfirm, String> {
        use std::io::IsTerminal;
        if !std::io::stdin().is_terminal() {
            return Err(
                "no controlling TTY — placement is always interactive (there is no --yes); nothing was changed"
                    .into(),
            );
        }
        Ok(TtyConfirm { yes_all: false })
    }
}

impl Confirm for TtyConfirm {
    fn confirm(&mut self, prompt: &str) -> Result<bool, String> {
        if self.yes_all {
            return Ok(true);
        }
        eprint!("{prompt} [y/a/N] ");
        let mut reply = String::new();
        std::io::stdin()
            .read_line(&mut reply)
            .map_err(|_| "aborted (EOF on confirm); nothing was changed".to_string())?;
        if reply.is_empty() {
            return Err("aborted (EOF on confirm); nothing was changed".into());
        }
        match reply.trim() {
            "a" | "A" | "all" | "ALL" => {
                self.yes_all = true;
                Ok(true)
            }
            "y" | "Y" | "yes" | "YES" => Ok(true),
            _ => {
                log("declined — skipping");
                Ok(false)
            }
        }
    }
}

pub fn managed_place(
    entries: &[Entry],
    executor: &str,
    confirm: &mut dyn Confirm,
) -> Result<(), String> {
    let mut failed = false;
    for entry in entries {
        let Some((bytes, executable)) = entry.content.rendered() else {
            continue;
        };
        let path = host_path(entry)?;
        let key = &entry.key;
        let marker = marker_path(&path);

        if !path.exists() {
            log(&format!(
                "{key}: {} does not exist (new file)",
                path.display()
            ));
            show_content(&bytes);
            if !confirm.confirm(&format!("Place {key} at {}?", path.display()))? {
                continue;
            }
            install_file(key, &path, &bytes, executable)?;
            if let Err(e) = write_marker(executor, &path) {
                let _ = fs::remove_file(&path);
                return Err(format!(
                    "{key}: {e} — rolled back {} so it is not left unmarked",
                    path.display()
                ));
            }
            log(&format!("{key}: placed {}", path.display()));
            continue;
        }

        if !marker.is_file() {
            log(&format!(
                "{key}: REFUSED — {} exists with no provenance marker (not placed by this tool / real-org managed config). Never touched.",
                path.display()
            ));
            failed = true;
            continue;
        }
        let existing_executor = marker_field(&marker, "executor").unwrap_or_default();
        if existing_executor != executor {
            log(&format!(
                "{key}: REFUSED — {} is owned by executor '{existing_executor}', not '{executor}'. Not touched.",
                path.display()
            ));
            failed = true;
            continue;
        }

        if fs::read(&path).ok().as_deref() == Some(bytes.as_slice()) {
            log(&format!("{key}: already placed and identical — no-op."));
            continue;
        }

        log(&format!(
            "{key}: {} was placed by managed setup but the content changed:",
            path.display()
        ));
        show_diff(&path, &bytes);
        if !confirm.confirm(&format!("Update {key} at {}?", path.display()))? {
            continue;
        }
        install_file(key, &path, &bytes, executable)?;
        write_marker(executor, &path).map_err(|e| {
            format!(
                "{key}: updated {} but {e} — remove it manually",
                path.display()
            )
        })?;
        log(&format!("{key}: updated {}", path.display()));
    }
    if failed {
        return Err(
            "one or more managed files were refused (see above); nothing foreign was touched"
                .into(),
        );
    }
    Ok(())
}

pub fn managed_teardown(
    candidates: &[(String, String)],
    root: &Path,
    executor: &str,
    confirm: &mut dyn Confirm,
) -> Result<(), String> {
    let mut failed = false;
    for (key, host) in candidates {
        let path = expand_host(host);
        let marker = marker_path(&path);
        if !path.exists() && !marker.is_file() {
            log(&format!(
                "{key}: nothing to remove ({} absent)",
                path.display()
            ));
            continue;
        }
        if !marker.is_file() {
            log(&format!(
                "{key}: REFUSED — {} has no provenance marker (not placed by this tool / real-org config). Not removed.",
                path.display()
            ));
            failed = true;
            continue;
        }
        let marker_executor = marker_field(&marker, "executor").unwrap_or_default();
        if marker_executor != executor {
            log(&format!(
                "{key}: REFUSED — {} is owned by executor '{marker_executor}', not '{executor}'. Not removed.",
                path.display()
            ));
            failed = true;
            continue;
        }
        let placed_at = marker_field(&marker, "placed_at").unwrap_or_default();
        if !confirm.confirm(&format!(
            "Remove managed {key} at {} (executor='{marker_executor}' placed_at='{placed_at}')?",
            path.display()
        ))? {
            continue;
        }
        if path.exists() && fs::remove_file(&path).is_err() {
            return Err(format!(
                "cannot remove {} (permission denied?) — remove it manually with elevated privileges, e.g.: sudo rm '{}'",
                path.display(),
                path.display()
            ));
        }
        if fs::remove_file(&marker).is_err() {
            log(&format!(
                "{key}: removed {} but could not remove marker {} — remove it manually",
                path.display(),
                marker.display()
            ));
        }
        log(&format!("{key}: removed {} and its marker", path.display()));
    }
    if failed {
        return Err("one or more managed files were refused (see above)".into());
    }
    remove_empty_dirs(root);
    if !root.exists() {
        log(&format!("removed empty managed root {}", root.display()));
    }
    Ok(())
}

fn remove_empty_dirs(dir: &Path) {
    let Ok(children) = fs::read_dir(dir) else {
        return;
    };
    for child in children.flatten() {
        if child.file_type().is_ok_and(|t| t.is_dir()) {
            remove_empty_dirs(&child.path());
        }
    }
    let _ = fs::remove_dir(dir);
}

pub fn expand_host(host: &str) -> PathBuf {
    if let Some(rest) = host.strip_prefix("%USERPROFILE%") {
        let profile = std::env::var_os("USERPROFILE").unwrap_or_default();
        return PathBuf::from(format!("{}{rest}", PathBuf::from(profile).display()));
    }
    PathBuf::from(host)
}

fn host_path(entry: &Entry) -> Result<PathBuf, String> {
    match &entry.location {
        Location::Host(abs) => Ok(expand_host(abs)),
        Location::InTarget(_) => Err(format!(
            "{}: managed placement received a target-relative entry",
            entry.key
        )),
    }
}

fn show_content(bytes: &[u8]) {
    log("content to be written:");
    for line in String::from_utf8_lossy(bytes).lines() {
        eprintln!("  | {line}");
    }
}

fn show_diff(target: &Path, new_bytes: &[u8]) {
    let tmp = std::env::temp_dir().join(format!("agent-config-diff-{}", std::process::id()));
    if fs::write(&tmp, new_bytes).is_ok() {
        let shown = std::process::Command::new("diff")
            .arg("-u")
            .arg(target)
            .arg(&tmp)
            .status()
            .is_ok();
        let _ = fs::remove_file(&tmp);
        if shown {
            return;
        }
    }
    log("(diff unavailable) existing content differs from the new content");
}

fn install_file(key: &str, path: &Path, bytes: &[u8], executable: bool) -> Result<(), String> {
    let dir = path.parent().expect("placement target always has a parent");
    fs::create_dir_all(dir).map_err(|_| {
        format!(
            "cannot create {} — rerun with privileges, e.g.: sudo mkdir -p '{}'",
            dir.display(),
            dir.display()
        )
    })?;
    fs::write(path, bytes).map_err(|_| {
        format!(
            "{key}: cannot write {} (permission denied?) — install it manually with elevated privileges",
            path.display()
        )
    })?;
    #[cfg(unix)]
    if executable {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o755))
            .map_err(|e| format!("{key}: cannot set mode on {}: {e}", path.display()))?;
    }
    #[cfg(not(unix))]
    let _ = executable;
    Ok(())
}

fn remove_file(key: &str, executor: &str, path: &Path, failed: &mut bool) {
    let marker = marker_path(path);
    let exists = path.symlink_metadata().is_ok();
    if !exists && !marker.is_file() {
        log(&format!(
            "{key}: nothing to remove ({} absent)",
            path.display()
        ));
        return;
    }
    if !marker.is_file() {
        log(&format!(
            "{key}: leaving {} — not placed by this tool (your own login/config). Not an error.",
            path.display()
        ));
        return;
    }
    if marker_field(&marker, "executor").as_deref() != Some(executor) {
        log(&format!(
            "{key}: REFUSED — {} is owned by executor '{}', not '{executor}'. Not removed.",
            path.display(),
            marker_field(&marker, "executor").unwrap_or_default()
        ));
        *failed = true;
        return;
    }
    if exists && fs::remove_file(path).is_err() {
        log(&format!(
            "{key}: FATAL: could not remove {}",
            path.display()
        ));
        *failed = true;
        return;
    }
    if fs::remove_file(&marker).is_err() {
        log(&format!(
            "{key}: removed {} but could not remove marker {} — remove it manually",
            path.display(),
            marker.display()
        ));
    }
    log(&format!("{key}: removed {} and its marker", path.display()));
}

fn place_auth_link(key: &str, source: &Path, path: &Path, executor: &str) -> Result<(), String> {
    if !source.exists() {
        log(&format!(
            "{key}: no {} found; run 'codex login' under CODEX_HOME ({})",
            source.display(),
            path.parent()
                .map(Path::display)
                .map(|d| d.to_string())
                .unwrap_or_default()
        ));
        return Ok(());
    }
    if path.symlink_metadata().is_ok() {
        log(&format!(
            "{key}: existing auth.json kept at {}",
            path.display()
        ));
        return Ok(());
    }
    ensure_parent(path)?;
    if symlink(source, path) {
        log(&format!(
            "{key}: linked {} -> {}",
            path.display(),
            source.display()
        ));
    } else {
        fs::copy(source, path).map_err(|e| {
            format!(
                "{key}: could not copy {} to {}: {e}",
                source.display(),
                path.display()
            )
        })?;
        log(&format!(
            "{key}: copied {} to {} (not a link; a copy can go stale on token refresh)",
            source.display(),
            path.display()
        ));
    }
    write_marker(executor, path)?;
    Ok(())
}

#[cfg(unix)]
fn symlink(source: &Path, target: &Path) -> bool {
    std::os::unix::fs::symlink(source, target).is_ok()
}

#[cfg(windows)]
fn symlink(source: &Path, target: &Path) -> bool {
    std::os::windows::fs::symlink_file(source, target).is_ok()
}

fn target_path(entry: &Entry, target_dir: &Path) -> Result<PathBuf, String> {
    match &entry.location {
        Location::InTarget(rel) => Ok(target_dir.join(rel)),
        Location::Host(_) => {
            Err("managed placement is not implemented yet (arrives in a later stage)".into())
        }
    }
}

fn entry_is_marked(entry: &Entry) -> bool {
    match &entry.content {
        Content::File { marked, .. } => *marked,
        Content::JsonKeys(_) | Content::TomlSections(_) => true,
        Content::AuthLink { .. } => false,
    }
}

fn assert_ours_or_absent(key: &str, executor: &str, path: &Path) -> Result<(), String> {
    if !path.exists() {
        return Ok(());
    }
    let marker = marker_path(path);
    if !marker.is_file() {
        return Err(format!(
            "{key}: REFUSED — {} exists with no provenance marker (not placed by this tool). Never touched.",
            path.display()
        ));
    }
    let marker_executor = marker_field(&marker, "executor").unwrap_or_default();
    if marker_executor != executor {
        return Err(format!(
            "{key}: REFUSED — {} is owned by executor '{marker_executor}', not '{executor}'. Not touched.",
            path.display()
        ));
    }
    Ok(())
}

fn marker_path(path: &Path) -> PathBuf {
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(MARKER_SUFFIX);
    path.with_file_name(name)
}

fn marker_field(marker: &Path, field: &str) -> Option<String> {
    let text = fs::read_to_string(marker).ok()?;
    text.lines()
        .filter_map(|line| line.trim_end_matches('\r').split_once('='))
        .find(|(key, _)| *key == field)
        .map(|(_, value)| value.to_string())
}

fn write_marker(executor: &str, target: &Path) -> Result<(), String> {
    let marker = marker_path(target);
    let content = format!(
        "executor={executor}\nplaced_at={}\ntarget={}\n",
        crate::clock::utc_now_iso(),
        target.display()
    );
    fs::write(&marker, content)
        .map_err(|_| format!("could not write provenance marker {}", marker.display()))
}

fn write_file(key: &str, path: &Path, bytes: &[u8], _executable: bool) -> Result<(), String> {
    ensure_parent(path)?;
    fs::write(path, bytes)
        .map_err(|e| format!("{key}: could not write {}: {e}", path.display()))?;
    #[cfg(unix)]
    if _executable {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o755))
            .map_err(|e| format!("{key}: cannot set mode on {}: {e}", path.display()))?;
    }
    Ok(())
}

fn ensure_parent(path: &Path) -> Result<(), String> {
    let dir = path.parent().expect("placement target always has a parent");
    fs::create_dir_all(dir).map_err(|e| format!("cannot create {}: {e}", dir.display()))
}

fn log(message: &str) {
    eprintln!("[agent-config] {message}");
}
