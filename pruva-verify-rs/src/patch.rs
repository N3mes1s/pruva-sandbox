use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::display;

/// Local filesystem paths where patches may be found.
pub fn local_patch_paths(repro_id: &str) -> Vec<PathBuf> {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/root".to_string());
    let exe_dir = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.to_path_buf()));

    let mut paths = vec![
        PathBuf::from(format!("/tmp/repro-patches/{repro_id}.patch")),
        PathBuf::from(format!(
            "/workspaces/pruva-sandbox/repro-patches/{repro_id}.patch"
        )),
        PathBuf::from(format!(
            "{home}/pruva-sandbox/repro-patches/{repro_id}.patch"
        )),
    ];

    if let Some(dir) = exe_dir {
        paths.push(dir.join(format!("repro-patches/{repro_id}.patch")));
    }

    paths
}

/// GitHub raw URL for a patch.
pub fn github_patch_url(repro_id: &str) -> String {
    format!(
        "https://raw.githubusercontent.com/N3mes1s/pruva-sandbox/main/repro-patches/{repro_id}.patch"
    )
}

/// Try to apply a patch file to the work directory.
/// Returns `true` if the patch was applied successfully.
fn apply_patch_file(patch_path: &Path, work_dir: &Path) -> bool {
    let file = match fs::File::open(patch_path) {
        Ok(f) => f,
        Err(_) => return false,
    };

    let status = Command::new("patch")
        .args(["-p0", "--directory"])
        .arg(work_dir)
        .stdin(std::process::Stdio::from(file))
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();

    matches!(status, Ok(s) if s.success())
}

/// Try applying patches from local paths, then from GitHub.
/// Returns `true` if any patch was applied.
pub fn apply_patches(client: &reqwest::blocking::Client, repro_id: &str, work_dir: &Path) -> bool {
    // 1. Try local paths
    for patch_path in local_patch_paths(repro_id) {
        if patch_path.exists() {
            display::log(&format!("Applying patch: {}", patch_path.display()));
            if apply_patch_file(&patch_path, work_dir) {
                display::log("Patch applied successfully");
                return true;
            } else {
                display::warn("Patch failed to apply (may already be applied)");
            }
            // Only try the first existing local patch
            return false;
        }
    }

    // 2. Try GitHub
    let url = github_patch_url(repro_id);
    if let Ok(resp) = client.get(&url).send() {
        if resp.status().is_success() {
            if let Ok(bytes) = resp.bytes() {
                if !bytes.is_empty() {
                    let tmp = tempfile::NamedTempFile::new().ok();
                    if let Some(tmp) = tmp {
                        if fs::write(tmp.path(), &bytes).is_ok() {
                            display::log("Applying patch from GitHub...");
                            if apply_patch_file(tmp.path(), work_dir) {
                                display::log("Patch applied successfully");
                                return true;
                            } else {
                                display::warn("Patch failed to apply (may already be applied)");
                            }
                        }
                    }
                }
            }
        }
    }

    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_patch_paths_contains_tmp() {
        let paths = local_patch_paths("REPRO-2026-00001");
        assert!(paths.iter().any(|p| p.starts_with("/tmp/repro-patches/")));
    }

    #[test]
    fn local_patch_paths_contains_workspaces() {
        let paths = local_patch_paths("REPRO-2026-00001");
        assert!(paths.iter().any(|p| {
            p.to_string_lossy()
                .contains("/workspaces/pruva-sandbox/repro-patches/")
        }));
    }

    #[test]
    fn local_patch_paths_uses_repro_id() {
        let paths = local_patch_paths("REPRO-2026-00042");
        for p in &paths {
            assert!(
                p.to_string_lossy().contains("REPRO-2026-00042"),
                "Expected REPRO-2026-00042 in path: {}",
                p.display()
            );
        }
    }

    #[test]
    fn github_patch_url_format() {
        let url = github_patch_url("REPRO-2026-00096");
        assert_eq!(
            url,
            "https://raw.githubusercontent.com/N3mes1s/pruva-sandbox/main/repro-patches/REPRO-2026-00096.patch"
        );
    }

    #[test]
    fn apply_patch_file_fails_on_nonexistent() {
        let dir = tempfile::tempdir().unwrap();
        let result = apply_patch_file(Path::new("/tmp/nonexistent-patch-xyz"), dir.path());
        assert!(!result);
    }

    #[test]
    fn apply_patch_file_works_with_valid_patch() {
        let dir = tempfile::tempdir().unwrap();

        // Create target file
        let target = dir.path().join("exploit.sh");
        fs::write(&target, "#!/bin/bash\necho old\n").unwrap();

        // Create a simple unified diff patch
        let patch = dir.path().join("fix.patch");
        let patch_content = "\
--- exploit.sh.orig
+++ exploit.sh
@@ -1,2 +1,2 @@
 #!/bin/bash
-echo old
+echo new
";
        fs::write(&patch, patch_content).unwrap();

        let result = apply_patch_file(&patch, dir.path());
        assert!(result, "Patch should apply successfully");

        let content = fs::read_to_string(&target).unwrap();
        assert!(content.contains("echo new"));
    }

    #[test]
    fn apply_patch_file_fails_on_empty_patch() {
        let dir = tempfile::tempdir().unwrap();
        let patch = dir.path().join("empty.patch");
        fs::write(&patch, "").unwrap();

        // Empty patch: `patch` command may return non-zero or zero depending on version
        // but should not panic
        let _ = apply_patch_file(&patch, dir.path());
    }

    #[test]
    fn apply_patch_file_fails_on_corrupt_patch() {
        let dir = tempfile::tempdir().unwrap();
        let patch = dir.path().join("corrupt.patch");
        fs::write(&patch, "this is not a valid patch\nrandom content\n").unwrap();

        let result = apply_patch_file(&patch, dir.path());
        assert!(!result, "Corrupt patch should fail");
    }

    #[test]
    fn local_patch_paths_returns_at_least_three() {
        let paths = local_patch_paths("REPRO-2026-00050");
        assert!(
            paths.len() >= 3,
            "Should have at least /tmp, /workspaces, and $HOME paths"
        );
    }

    #[test]
    fn local_patch_paths_all_end_with_patch_extension() {
        let paths = local_patch_paths("REPRO-2026-00099");
        for p in &paths {
            assert!(
                p.to_string_lossy().ends_with(".patch"),
                "Expected .patch extension: {}",
                p.display()
            );
        }
    }

    #[test]
    fn github_patch_url_contains_repo_path() {
        let url = github_patch_url("REPRO-2026-00001");
        assert!(url.contains("N3mes1s/pruva-sandbox"));
        assert!(url.contains("repro-patches/"));
        assert!(url.starts_with("https://"));
    }

    #[test]
    fn apply_patches_returns_false_when_no_patches_exist() {
        let client = reqwest::blocking::Client::builder()
            .timeout(std::time::Duration::from_secs(5))
            .build()
            .unwrap();
        let dir = tempfile::tempdir().unwrap();
        // Use an ID that won't have any local or remote patches
        let result = apply_patches(&client, "REPRO-9999-99999", dir.path());
        assert!(!result, "Should return false when no patches found");
    }
}
