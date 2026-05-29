use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use anyhow::{bail, Context, Result};

use crate::metadata::normalize_artifact_path;

/// Download a single artifact from the API into `work_dir`, normalizing bundle/ paths.
/// Returns the local path relative to work_dir on success.
pub fn download_artifact(
    client: &reqwest::blocking::Client,
    api_url: &str,
    repro_id: &str,
    artifact_path: &str,
    work_dir: &Path,
) -> Result<String> {
    let local_rel = normalize_artifact_path(artifact_path);
    let dest = work_dir.join(local_rel);

    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("Failed to create directory {}", parent.display()))?;
    }

    let url = format!("{api_url}/reproductions/{repro_id}/artifacts/{artifact_path}");
    let bytes = client
        .get(&url)
        .send()
        .with_context(|| format!("Failed to download artifact {artifact_path}"))?
        .error_for_status()
        .with_context(|| format!("Failed to download artifact {artifact_path}"))?
        .bytes()
        .context("Failed to read artifact bytes")?;

    fs::write(&dest, &bytes)
        .with_context(|| format!("Failed to write artifact to {}", dest.display()))?;

    // Make .sh and .py files executable
    if local_rel.ends_with(".sh") || local_rel.ends_with(".py") {
        make_executable(&dest)?;
    }

    Ok(local_rel.to_string())
}

/// Download all selected artifacts. Returns the count of successfully downloaded files.
pub fn download_all(
    client: &reqwest::blocking::Client,
    api_url: &str,
    repro_id: &str,
    artifact_paths: &[String],
    work_dir: &Path,
) -> Result<usize> {
    let mut count = 0;
    for path in artifact_paths {
        match download_artifact(client, api_url, repro_id, path, work_dir) {
            Ok(_) => count += 1,
            Err(e) => {
                eprintln!("Warning: failed to download {path}: {e}");
            }
        }
    }
    Ok(count)
}

/// Ensure the script file exists, is executable, and return its absolute path.
pub fn prepare_script(work_dir: &Path, script_artifact: &str) -> Result<std::path::PathBuf> {
    let local_rel = normalize_artifact_path(script_artifact);
    let script_path = work_dir.join(local_rel);

    if !script_path.exists() {
        bail!("Failed to download reproduction script");
    }

    make_executable(&script_path)?;
    Ok(script_path)
}

/// Set the executable bit on a file.
pub fn make_executable(path: &Path) -> Result<()> {
    let meta = fs::metadata(path).with_context(|| format!("Cannot stat {}", path.display()))?;
    let mut perms = meta.permissions();
    perms.set_mode(perms.mode() | 0o111);
    fs::set_permissions(path, perms).with_context(|| format!("Cannot chmod {}", path.display()))?;
    Ok(())
}

/// Count lines in a file (for the "script: N lines" log message).
pub fn count_lines(path: &Path) -> usize {
    fs::read_to_string(path)
        .map(|s| s.lines().count())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn count_lines_on_real_file() {
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("test.sh");
        fs::write(&f, "#!/bin/bash\necho hello\nexit 0\n").unwrap();
        assert_eq!(count_lines(&f), 3);
    }

    #[test]
    fn count_lines_empty_file() {
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("empty.sh");
        fs::write(&f, "").unwrap();
        assert_eq!(count_lines(&f), 0);
    }

    #[test]
    fn count_lines_missing_file() {
        let p = Path::new("/tmp/nonexistent-pruva-test-file-xyz");
        assert_eq!(count_lines(p), 0);
    }

    #[test]
    fn make_executable_sets_bits() {
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("script.sh");
        fs::write(&f, "#!/bin/bash").unwrap();
        // Remove execute bits first
        fs::set_permissions(&f, fs::Permissions::from_mode(0o644)).unwrap();
        make_executable(&f).unwrap();
        let mode = fs::metadata(&f).unwrap().permissions().mode();
        assert!(
            mode & 0o111 != 0,
            "Expected executable bits set, got {mode:#o}"
        );
    }

    #[test]
    fn prepare_script_fails_on_missing() {
        let dir = tempfile::tempdir().unwrap();
        let result = prepare_script(dir.path(), "nonexistent.sh");
        assert!(result.is_err());
    }

    #[test]
    fn prepare_script_succeeds_and_makes_executable() {
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("exploit.sh");
        fs::write(&f, "#!/bin/bash\nexit 0").unwrap();
        fs::set_permissions(&f, fs::Permissions::from_mode(0o644)).unwrap();

        let path = prepare_script(dir.path(), "exploit.sh").unwrap();
        assert_eq!(path, f);
        let mode = fs::metadata(&f).unwrap().permissions().mode();
        assert!(mode & 0o111 != 0);
    }

    #[test]
    fn prepare_script_handles_bundle_prefix() {
        let dir = tempfile::tempdir().unwrap();
        fs::create_dir_all(dir.path().join("repro")).unwrap();
        let f = dir.path().join("repro/exploit.sh");
        fs::write(&f, "#!/bin/bash").unwrap();

        let path = prepare_script(dir.path(), "bundle/repro/exploit.sh").unwrap();
        assert_eq!(path, f);
    }

    // --- additional edge cases ---

    #[test]
    fn count_lines_single_line_no_trailing_newline() {
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("one.txt");
        fs::write(&f, "single line").unwrap();
        assert_eq!(count_lines(&f), 1);
    }

    #[test]
    fn count_lines_only_newlines() {
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("newlines.txt");
        fs::write(&f, "\n\n\n").unwrap();
        assert_eq!(count_lines(&f), 3);
    }

    #[test]
    fn make_executable_preserves_existing_bits() {
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("script.sh");
        fs::write(&f, "#!/bin/bash").unwrap();
        // Set read+write for owner, nothing else
        fs::set_permissions(&f, fs::Permissions::from_mode(0o600)).unwrap();
        make_executable(&f).unwrap();
        let mode = fs::metadata(&f).unwrap().permissions().mode();
        // Original rw- bits should still be present
        assert!(mode & 0o600 != 0, "Read/write bits should be preserved");
        assert!(mode & 0o111 != 0, "Execute bits should be set");
    }

    #[test]
    fn make_executable_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("script.sh");
        fs::write(&f, "#!/bin/bash").unwrap();
        fs::set_permissions(&f, fs::Permissions::from_mode(0o755)).unwrap();
        // Already executable - should not error
        make_executable(&f).unwrap();
        let mode = fs::metadata(&f).unwrap().permissions().mode();
        assert!(mode & 0o111 != 0);
    }

    #[test]
    fn make_executable_fails_on_nonexistent() {
        let result = make_executable(Path::new("/tmp/nonexistent-pruva-chmod-xyz"));
        assert!(result.is_err());
    }

    #[test]
    fn prepare_script_normalizes_nested_bundle_path() {
        let dir = tempfile::tempdir().unwrap();
        // bundle/deep/exploit.sh → deep/exploit.sh after normalization
        fs::create_dir_all(dir.path().join("deep")).unwrap();
        let f = dir.path().join("deep/exploit.sh");
        fs::write(&f, "#!/bin/bash").unwrap();

        let path = prepare_script(dir.path(), "bundle/deep/exploit.sh").unwrap();
        assert_eq!(path, f);
    }

    #[test]
    fn count_lines_multiline_content() {
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("multi.sh");
        fs::write(&f, "line1\nline2\nline3\nline4\nline5\n").unwrap();
        assert_eq!(count_lines(&f), 5);
    }

    #[test]
    fn count_lines_windows_newlines() {
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("win.sh");
        fs::write(&f, "line1\r\nline2\r\nline3\r\n").unwrap();
        // Rust's lines() splits on \n, \r\n counts as single line separator
        assert_eq!(count_lines(&f), 3);
    }

    #[test]
    fn make_executable_full_permission_preservation() {
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("script.sh");
        fs::write(&f, "#!/bin/bash").unwrap();
        // Set permissions to 0o444 (read-only)
        fs::set_permissions(&f, fs::Permissions::from_mode(0o444)).unwrap();
        make_executable(&f).unwrap();
        let mode = fs::metadata(&f).unwrap().permissions().mode();
        // Should now have read+exec for all
        assert!(mode & 0o444 != 0, "Read bits should be preserved");
        assert!(mode & 0o111 != 0, "Execute bits should be set");
    }

    #[test]
    fn prepare_script_returns_absolute_path() {
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("exploit.sh");
        fs::write(&f, "#!/bin/bash\nexit 0").unwrap();

        let path = prepare_script(dir.path(), "exploit.sh").unwrap();
        assert!(path.is_absolute(), "Should return absolute path");
    }

    #[test]
    fn prepare_script_with_root_level_artifact() {
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("run.py");
        fs::write(&f, "#!/usr/bin/env python3\nprint('hi')").unwrap();

        let path = prepare_script(dir.path(), "run.py").unwrap();
        assert_eq!(path, f);
        let mode = fs::metadata(&f).unwrap().permissions().mode();
        assert!(mode & 0o111 != 0, "Should be executable");
    }

    #[test]
    fn prepare_script_with_deeply_nested_path() {
        let dir = tempfile::tempdir().unwrap();
        fs::create_dir_all(dir.path().join("a/b/c")).unwrap();
        let f = dir.path().join("a/b/c/exploit.sh");
        fs::write(&f, "#!/bin/bash").unwrap();

        let path = prepare_script(dir.path(), "bundle/a/b/c/exploit.sh").unwrap();
        assert_eq!(path, f);
    }

    #[test]
    fn count_lines_binary_like_content() {
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("binary_like.sh");
        // Content with null bytes
        fs::write(&f, "#!/bin/bash\n\0\necho hi\n").unwrap();
        // Should still count lines without panic
        let lines = count_lines(&f);
        assert!(lines > 0);
    }
}
