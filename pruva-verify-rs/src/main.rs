mod artifacts;
mod display;
mod env;
mod metadata;
mod patch;
mod resolve;
mod rewrite;
mod runner;

use std::fs;
use std::path::PathBuf;
use std::process;

use anyhow::{Context, Result};
use clap::Parser;

/// Verify a Pruva vulnerability reproduction locally.
///
/// This runs code that exploits real vulnerabilities.
/// Always run in a VM, container, or disposable environment.
#[derive(Parser, Debug)]
#[command(name = "pruva-verify", version, about)]
struct Cli {
    /// The reproduction identifier (REPRO-YYYY-NNNNN, GHSA-xxxx-xxxx-xxxx, or CVE-YYYY-NNNNN)
    id: String,
}

fn main() {
    let cli = Cli::parse();

    match run(&cli.id) {
        Ok(code) => process::exit(code),
        Err(e) => {
            display::error(&format!("{e:#}"));
            process::exit(1);
        }
    }
}

fn run(input: &str) -> Result<i32> {
    let api_url = std::env::var("PRUVA_API_URL")
        .unwrap_or_else(|_| "https://pruva-api-production.up.railway.app/v1".to_string());
    let keep_dir = std::env::var("PRUVA_KEEP_DIR").unwrap_or_else(|_| "1".to_string());

    let client = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(120))
        .build()
        .context("Failed to create HTTP client")?;

    // --- Environment info ---
    if let Some(version_map) = env::load_sandbox_version() {
        let ver = version_map
            .get("PRUVA_SANDBOX_VERSION")
            .map_or("unknown", |v| v.as_str());
        let sha = version_map
            .get("PRUVA_SANDBOX_SHA")
            .map_or("unknown", |v| v.as_str());
        display::log(&format!("Environment: pruva-sandbox {ver} ({sha})"));
    }

    // --- Resolve ID ---
    display::log(&format!("Resolving {}...", input));
    let parsed_id = resolve::parse_input(input)?;
    let repro_id = resolve::resolve_repro_id(&client, &api_url, &parsed_id)?;
    display::log(&format!("Found reproduction: {repro_id}"));

    // --- Fetch metadata ---
    display::log("Fetching metadata...");
    let meta = metadata::fetch_metadata(&client, &api_url, &repro_id)?;

    let title = meta.title.as_deref().unwrap_or("Unknown");
    let severity = meta.severity.as_deref().unwrap_or("unknown").to_uppercase();

    // --- Version mismatch check ---
    if let Some(ref required_ver) = meta.environment.sandbox_version {
        if let Some(version_map) = env::load_sandbox_version() {
            if let Some(current) = version_map.get("PRUVA_SANDBOX_VERSION") {
                if current != required_ver {
                    display::warn(&format!(
                        "Version mismatch: reproduction created with {required_ver}, running in {current}"
                    ));
                }
            }
        }
    }

    // --- Banner ---
    display::print_banner(
        &repro_id,
        title,
        &severity,
        meta.ghsa_id.as_deref(),
        meta.cve_id.as_deref(),
    );

    // --- Work directory ---
    let results_dir = env::results_dir();
    let work_dir = PathBuf::from(&results_dir).join(&repro_id);

    // Clean previous run
    if work_dir.exists() {
        display::log("Removing previous run directory...");
        fs::remove_dir_all(&work_dir).context("Failed to remove previous work directory")?;
    }
    fs::create_dir_all(&work_dir).context("Failed to create work directory")?;
    display::log(&format!("Working directory: {}", work_dir.display()));

    // Cleanup guard — runs on both success and failure
    let _cleanup = CleanupGuard {
        work_dir: work_dir.clone(),
        keep: keep_dir == "1",
    };

    // --- Select script artifact ---
    let script_artifact = metadata::select_script_artifact(&meta)?;
    display::log(&format!("Found script artifact: {script_artifact}"));

    // --- Download artifacts ---
    let to_download = metadata::artifacts_to_download(&meta, &script_artifact);
    let count = artifacts::download_all(&client, &api_url, &repro_id, &to_download, &work_dir)?;

    let script_path = artifacts::prepare_script(&work_dir, &script_artifact)?;
    let line_count = artifacts::count_lines(&script_path);
    display::log(&format!(
        "Downloaded {count} repro artifact(s), script: {line_count} lines"
    ));

    // --- Apply patches ---
    patch::apply_patches(&client, &repro_id, &work_dir);

    // --- Rewrite hardcoded paths ---
    if let Ok(Some(original)) = rewrite::rewrite_base_dir(&script_path, &work_dir) {
        display::log(&format!(
            "Rewriting paths: {original} -> {}",
            work_dir.display()
        ));
    }

    // --- Confirmation ---
    display::print_warning();
    if !env::confirm_execution() {
        display::log("Aborted.");
        return Ok(0);
    }

    // --- Run ---
    let script_rel = metadata::normalize_artifact_path(&script_artifact);
    let exec_path = work_dir.join(script_rel);
    let result = runner::run_script(&exec_path, &work_dir)?;

    if result.success {
        runner::report_success(&work_dir, result.duration_secs);
        Ok(0)
    } else {
        runner::report_failure(&work_dir, result.exit_code, result.duration_secs);
        Ok(1)
    }
}

/// RAII guard that cleans up the work directory on drop (unless keep_dir is set).
struct CleanupGuard {
    work_dir: PathBuf,
    keep: bool,
}

impl Drop for CleanupGuard {
    fn drop(&mut self) {
        if self.keep {
            display::warn(&format!(
                "Keeping work directory: {}",
                self.work_dir.display()
            ));
        } else if self.work_dir.exists() {
            let _ = fs::remove_dir_all(&self.work_dir);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cleanup_guard_removes_dir_when_not_kept() {
        let dir = tempfile::tempdir().unwrap();
        let work_dir = dir.path().join("test-cleanup");
        fs::create_dir_all(&work_dir).unwrap();
        assert!(work_dir.exists());

        {
            let _guard = CleanupGuard {
                work_dir: work_dir.clone(),
                keep: false,
            };
            // guard dropped here
        }
        assert!(!work_dir.exists(), "Directory should be removed on drop");
    }

    #[test]
    fn cleanup_guard_keeps_dir_when_flagged() {
        let dir = tempfile::tempdir().unwrap();
        let work_dir = dir.path().join("test-keep");
        fs::create_dir_all(&work_dir).unwrap();
        assert!(work_dir.exists());

        {
            let _guard = CleanupGuard {
                work_dir: work_dir.clone(),
                keep: true,
            };
        }
        assert!(work_dir.exists(), "Directory should be kept when keep=true");
    }

    #[test]
    fn cleanup_guard_no_panic_on_nonexistent_dir() {
        {
            let _guard = CleanupGuard {
                work_dir: PathBuf::from("/tmp/nonexistent-pruva-guard-test-xyz"),
                keep: false,
            };
        }
        // Should not panic
    }

    #[test]
    fn cleanup_guard_removes_nested_contents() {
        let dir = tempfile::tempdir().unwrap();
        let work_dir = dir.path().join("nested-cleanup");
        let nested = work_dir.join("subdir/deep");
        fs::create_dir_all(&nested).unwrap();
        fs::write(nested.join("file.txt"), "content").unwrap();

        {
            let _guard = CleanupGuard {
                work_dir: work_dir.clone(),
                keep: false,
            };
        }
        assert!(
            !work_dir.exists(),
            "Entire directory tree should be removed"
        );
    }
}
