use std::fs;
use std::path::Path;
use std::process::Command;
use std::time::Instant;

use anyhow::{Context, Result};
use colored::Colorize;

use crate::display;

/// Result of running a reproduction script.
pub struct RunResult {
    pub success: bool,
    pub exit_code: i32,
    pub duration_secs: u64,
}

/// Execute the reproduction script in the work directory.
pub fn run_script(script_path: &Path, work_dir: &Path) -> Result<RunResult> {
    display::log("Running reproduction script...");
    println!();
    println!("{}", "--- REPRODUCTION OUTPUT ---".bold());
    println!();

    let start = Instant::now();

    let status = Command::new(script_path)
        .current_dir(work_dir)
        .status()
        .with_context(|| format!("Failed to execute {}", script_path.display()))?;

    let duration = start.elapsed().as_secs();
    let exit_code = status.code().unwrap_or(-1);

    println!();
    println!("{}", "--- END REPRODUCTION OUTPUT ---".bold());
    println!();

    Ok(RunResult {
        success: status.success(),
        exit_code,
        duration_secs: duration,
    })
}

/// Print a success report after a passed verification.
pub fn report_success(work_dir: &Path, duration: u64) {
    display::success("==========================================");
    display::success("  VERIFICATION SUCCESSFUL");
    display::success(&format!("  Duration: {duration}s"));
    display::success("==========================================");
    println!();

    // Show result.json if present
    let result_json = work_dir.join("logs/result.json");
    if result_json.exists() {
        display::log("Result:");
        if let Ok(content) = fs::read_to_string(&result_json) {
            if let Some(first_line) = content.lines().next() {
                println!("{first_line}");
            }
        }
        println!();
    }

    show_logs_summary(work_dir);
    println!();
    display::log(&format!(
        "Results saved to: {}",
        work_dir.display().to_string().bold()
    ));
}

/// Print a failure report.
pub fn report_failure(work_dir: &Path, exit_code: i32, duration: u64) {
    display::error(&format!("=========================================="));
    display::error(&format!("  VERIFICATION FAILED (exit code: {exit_code})"));
    display::error(&format!("  Duration: {duration}s"));
    display::error("==========================================");
    println!();

    let logs_dir = work_dir.join("logs");
    if logs_dir.is_dir() {
        display::error(&format!("Logs: {}/", logs_dir.display()));
        list_dir_files(&logs_dir);
        println!();

        let repro_log = logs_dir.join("repro.log");
        if repro_log.exists() {
            display::error("Last 20 lines of repro.log:");
            if let Ok(content) = fs::read_to_string(&repro_log) {
                let lines: Vec<&str> = content.lines().collect();
                let start = lines.len().saturating_sub(20);
                for line in &lines[start..] {
                    println!("    {line}");
                }
            }
        }
    }

    println!();
    display::log(&format!(
        "Results saved to: {}",
        work_dir.display().to_string().bold()
    ));
}

fn show_logs_summary(work_dir: &Path) {
    let logs_dir = work_dir.join("logs");
    if logs_dir.is_dir() {
        display::log(&format!("Logs: {}/", logs_dir.display()));
        list_dir_files(&logs_dir);
    }
}

fn list_dir_files(dir: &Path) {
    if let Ok(entries) = fs::read_dir(dir) {
        let mut names: Vec<String> = entries
            .filter_map(|e| e.ok())
            .filter_map(|e| e.file_name().into_string().ok())
            .collect();
        names.sort();
        for name in names {
            println!("    - {name}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn run_script_returns_success_on_zero_exit() {
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("ok.sh");
        fs::write(&script, "#!/bin/bash\nexit 0\n").unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();

        let result = run_script(&script, dir.path()).unwrap();
        assert!(result.success);
        assert_eq!(result.exit_code, 0);
    }

    #[test]
    fn run_script_returns_failure_on_nonzero_exit() {
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("fail.sh");
        fs::write(&script, "#!/bin/bash\nexit 42\n").unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();

        let result = run_script(&script, dir.path()).unwrap();
        assert!(!result.success);
        assert_eq!(result.exit_code, 42);
    }

    #[test]
    fn run_script_records_duration() {
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("quick.sh");
        fs::write(&script, "#!/bin/bash\nexit 0\n").unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();

        let result = run_script(&script, dir.path()).unwrap();
        // Should complete in well under a second
        assert!(result.duration_secs < 5);
    }

    #[test]
    fn run_script_fails_on_missing_file() {
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("nonexistent.sh");
        let result = run_script(&script, dir.path());
        assert!(result.is_err());
    }

    #[test]
    fn list_dir_files_no_panic_on_empty_dir() {
        let dir = tempfile::tempdir().unwrap();
        // Just verify it doesn't panic
        list_dir_files(dir.path());
    }

    #[test]
    fn list_dir_files_no_panic_on_nonexistent() {
        list_dir_files(Path::new("/tmp/nonexistent-pruva-test-dir-xyz"));
    }
}
