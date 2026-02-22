use std::fs;
use std::path::Path;

use anyhow::{Context, Result};
use regex::Regex;

/// Rewrite hardcoded `BASE_DIR="..."` paths in the reproduction script
/// to point at the actual work directory.
///
/// Returns `Some(original)` if a rewrite was performed.
pub fn rewrite_base_dir(script_path: &Path, work_dir: &Path) -> Result<Option<String>> {
    let content = fs::read_to_string(script_path)
        .with_context(|| format!("Cannot read {}", script_path.display()))?;

    let re = Regex::new(r#"BASE_DIR="([^"]*)""#).unwrap();
    let original_base = match re.captures(&content) {
        Some(caps) => caps.get(1).unwrap().as_str().to_string(),
        None => return Ok(None),
    };

    if original_base.is_empty() {
        return Ok(None);
    }

    let work_dir_str = work_dir.to_string_lossy();
    let rewritten = content.replace(&original_base, &work_dir_str);

    fs::write(script_path, &rewritten)
        .with_context(|| format!("Cannot write {}", script_path.display()))?;

    // Restore executable bit after rewrite
    crate::artifacts::make_executable(script_path)?;

    Ok(Some(original_base))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn rewrite_replaces_base_dir() {
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("exploit.sh");
        fs::write(
            &script,
            "#!/bin/bash\nBASE_DIR=\"/root/.pruva/runs/abc/bundle\"\ncd \"$BASE_DIR\"\n",
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();

        let work = tempfile::tempdir().unwrap();
        let result = rewrite_base_dir(&script, work.path()).unwrap();

        assert_eq!(result, Some("/root/.pruva/runs/abc/bundle".into()));
        let content = fs::read_to_string(&script).unwrap();
        assert!(content.contains(&work.path().to_string_lossy().to_string()));
        assert!(!content.contains("/root/.pruva/runs/abc/bundle"));
    }

    #[test]
    fn rewrite_no_base_dir_is_noop() {
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("exploit.sh");
        let original = "#!/bin/bash\necho hello\n";
        fs::write(&script, original).unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();

        let work = tempfile::tempdir().unwrap();
        let result = rewrite_base_dir(&script, work.path()).unwrap();

        assert!(result.is_none());
        assert_eq!(fs::read_to_string(&script).unwrap(), original);
    }

    #[test]
    fn rewrite_empty_base_dir_is_noop() {
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("exploit.sh");
        let original = "#!/bin/bash\nBASE_DIR=\"\"\necho hello\n";
        fs::write(&script, original).unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();

        let work = tempfile::tempdir().unwrap();
        let result = rewrite_base_dir(&script, work.path()).unwrap();

        assert!(result.is_none());
    }

    #[test]
    fn rewrite_preserves_executable_bit() {
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("exploit.sh");
        fs::write(&script, "#!/bin/bash\nBASE_DIR=\"/old/path\"\n").unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();

        let work = tempfile::tempdir().unwrap();
        rewrite_base_dir(&script, work.path()).unwrap();

        let mode = fs::metadata(&script).unwrap().permissions().mode();
        assert!(mode & 0o111 != 0, "Expected executable bits, got {mode:#o}");
    }

    #[test]
    fn rewrite_replaces_all_occurrences() {
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("exploit.sh");
        fs::write(
            &script,
            "#!/bin/bash\nBASE_DIR=\"/old/path\"\ncd /old/path\nls /old/path/data\n",
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();

        let work = tempfile::tempdir().unwrap();
        rewrite_base_dir(&script, work.path()).unwrap();

        let content = fs::read_to_string(&script).unwrap();
        assert!(
            !content.contains("/old/path"),
            "All occurrences should be replaced"
        );
    }
}
