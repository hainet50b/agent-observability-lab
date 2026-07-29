use std::fs;
use std::path::Path;

use crate::model::Entry;

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
