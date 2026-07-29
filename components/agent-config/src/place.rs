use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::model::{Agent, Content, Entry, Location};
use crate::owner::OWNER;

const MARKER_SUFFIX: &str = ".managed";

pub fn place(
    entries: &[Entry],
    target_dir: &Path,
    agent: &str,
    endpoint: &str,
) -> Result<(), String> {
    for entry in entries {
        let path = target_path(entry, target_dir)?;
        if entry_is_marked(entry) {
            assert_ours_or_absent(&entry.key, endpoint, &path)?;
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
                    write_marker(agent, endpoint, &path)?;
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
                write_marker(agent, endpoint, &path)?;
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
                    write_marker(agent, endpoint, &path)?;
                    log(&format!("{}: wrote {}", entry.key, path.display()));
                }
            }
            Content::AuthLink { source } => {
                place_auth_link(&entry.key, source, &path, agent, endpoint)?;
            }
        }
    }
    Ok(())
}

pub fn teardown(agent: Agent, target_dir: &Path, endpoint: &str) -> Result<(), String> {
    let (targets, hooks_dir, anchor) = match agent {
        Agent::Claude => crate::agents::claude::teardown_targets(),
        Agent::Codex => crate::agents::codex::teardown_targets(),
    };

    let anchor_path = target_dir.join(anchor);
    let hooks_owned = marker_field(&marker_path(&anchor_path), "endpoint")
        .is_some_and(|marker_endpoint| marker_endpoint == endpoint);

    let mut failed = false;
    for (key, rel) in targets {
        remove_file(key, endpoint, &target_dir.join(rel), &mut failed);
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

fn remove_file(key: &str, endpoint: &str, path: &Path, failed: &mut bool) {
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
    if marker_field(&marker, "endpoint").as_deref() != Some(endpoint) {
        log(&format!(
            "{key}: REFUSED — {} carries a different endpoint ({}). Not removed.",
            path.display(),
            marker_field(&marker, "endpoint").unwrap_or_default()
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

fn place_auth_link(
    key: &str,
    source: &Path,
    path: &Path,
    agent: &str,
    endpoint: &str,
) -> Result<(), String> {
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
    write_marker(agent, endpoint, path)?;
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

fn assert_ours_or_absent(key: &str, endpoint: &str, path: &Path) -> Result<(), String> {
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
    let marker_endpoint = marker_field(&marker, "endpoint").unwrap_or_default();
    if marker_endpoint != endpoint {
        return Err(format!(
            "{key}: REFUSED — {} carries a different endpoint ({marker_endpoint}); run teardown first. Not touched.",
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

fn write_marker(agent: &str, endpoint: &str, target: &Path) -> Result<(), String> {
    let marker = marker_path(target);
    let content = format!(
        "tool={OWNER}\nagent={agent}\nendpoint={endpoint}\nplaced_at={}\ntarget={}\n",
        utc_now_iso(),
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

fn utc_now_iso() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock is before 1970")
        .as_secs();
    let (year, month, day) = civil_from_days((secs / 86400) as i64);
    let rem = secs % 86400;
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z.rem_euclid(146097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (yoe + era * 400 + i64::from(month <= 2), month, day)
}
