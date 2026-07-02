use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use colored::Colorize;

use crate::display;

const FAILURE_LOG_TAIL_LINES: usize = 20;

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

    let status = execute_script_with_retry(script_path, work_dir)
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

fn execute_script_with_retry(script_path: &Path, work_dir: &Path) -> std::io::Result<ExitStatus> {
    const ETXTBSY: i32 = 26;
    const MAX_ATTEMPTS: usize = 3;

    let mut last_error = None;
    for attempt in 1..=MAX_ATTEMPTS {
        match Command::new(script_path).current_dir(work_dir).status() {
            Ok(status) => return Ok(status),
            Err(error) if error.raw_os_error() == Some(ETXTBSY) && attempt < MAX_ATTEMPTS => {
                last_error = Some(error);
                thread::sleep(Duration::from_millis(50));
            }
            Err(error) => return Err(error),
        }
    }

    Err(last_error.expect("ETXTBSY retry loop should retain the last error"))
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
    display::error("==========================================");
    display::error(&format!("  VERIFICATION FAILED (exit code: {exit_code})"));
    display::error(&format!("  Duration: {duration}s"));
    display::error("==========================================");
    println!();

    let logs_dir = work_dir.join("logs");
    if logs_dir.is_dir() {
        display::error(&format!("Logs: {}/", logs_dir.display()));
        list_dir_files(&logs_dir);
        println!();

        tail_log_files(&logs_dir, FAILURE_LOG_TAIL_LINES);
    }

    println!();
    display::log(&format!(
        "Results saved to: {}",
        work_dir.display().to_string().bold()
    ));
}

fn tail_log_files(logs_dir: &Path, max_lines: usize) {
    let files = sorted_regular_files(logs_dir);
    if files.is_empty() {
        return;
    }

    for (index, file) in files.iter().enumerate() {
        if index > 0 {
            println!();
        }

        let name = file
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("<unknown>");
        display::error(&format!("Last {max_lines} lines of {name}:"));
        match tail_file_lines(file, max_lines) {
            Ok(lines) => {
                for line in lines {
                    println!("    {line}");
                }
            }
            Err(error) => {
                println!("    <failed to read {}: {error}>", file.display());
            }
        }
    }
}

fn sorted_regular_files(dir: &Path) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = match fs::read_dir(dir) {
        Ok(entries) => entries
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.path())
            .filter(|path| path.is_file())
            .collect(),
        Err(_) => Vec::new(),
    };
    files.sort_by(|left, right| left.file_name().cmp(&right.file_name()));
    files
}

fn tail_file_lines(path: &Path, max_lines: usize) -> std::io::Result<Vec<String>> {
    let content = fs::read(path)?;
    let content = String::from_utf8_lossy(&content);
    let lines: Vec<&str> = content.lines().collect();
    let start = lines.len().saturating_sub(max_lines);
    Ok(lines[start..]
        .iter()
        .map(|line| (*line).to_string())
        .collect())
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

    #[test]
    fn list_dir_files_lists_sorted_entries() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("charlie.log"), "c").unwrap();
        fs::write(dir.path().join("alpha.log"), "a").unwrap();
        fs::write(dir.path().join("bravo.log"), "b").unwrap();
        // Just verify it doesn't panic with populated directory
        list_dir_files(dir.path());
    }

    #[test]
    fn run_script_captures_correct_exit_code() {
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("exit7.sh");
        fs::write(&script, "#!/bin/bash\nexit 7\n").unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();

        let result = run_script(&script, dir.path()).unwrap();
        assert!(!result.success);
        assert_eq!(result.exit_code, 7);
    }

    #[test]
    fn run_script_exit_code_127_command_not_found() {
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("bad_cmd.sh");
        fs::write(&script, "#!/bin/bash\nnonexistent_command_xyz_123\n").unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();

        let result = run_script(&script, dir.path()).unwrap();
        assert!(!result.success);
        assert_eq!(result.exit_code, 127);
    }

    #[test]
    fn run_script_uses_work_dir_as_cwd() {
        let dir = tempfile::tempdir().unwrap();
        let marker = dir.path().join("created_by_script.txt");
        let script = dir.path().join("cwd_test.sh");
        fs::write(
            &script,
            "#!/bin/bash\npwd > created_by_script.txt\nexit 0\n",
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();

        let result = run_script(&script, dir.path()).unwrap();
        assert!(result.success);
        assert!(
            marker.exists(),
            "Script should write to its working directory"
        );
        let content = fs::read_to_string(&marker).unwrap();
        assert!(content
            .trim()
            .ends_with(dir.path().file_name().unwrap().to_str().unwrap()));
    }

    #[test]
    fn report_success_no_panic_without_logs() {
        let dir = tempfile::tempdir().unwrap();
        // No logs directory - should not panic
        report_success(dir.path(), 42);
    }

    #[test]
    fn report_success_no_panic_with_result_json() {
        let dir = tempfile::tempdir().unwrap();
        let logs_dir = dir.path().join("logs");
        fs::create_dir_all(&logs_dir).unwrap();
        fs::write(logs_dir.join("result.json"), r#"{"status":"pass"}"#).unwrap();
        report_success(dir.path(), 10);
    }

    #[test]
    fn report_success_with_empty_result_json() {
        let dir = tempfile::tempdir().unwrap();
        let logs_dir = dir.path().join("logs");
        fs::create_dir_all(&logs_dir).unwrap();
        fs::write(logs_dir.join("result.json"), "").unwrap();
        report_success(dir.path(), 5);
    }

    #[test]
    fn report_failure_no_panic_without_logs() {
        let dir = tempfile::tempdir().unwrap();
        report_failure(dir.path(), 1, 10);
    }

    #[test]
    fn report_failure_with_repro_log() {
        let dir = tempfile::tempdir().unwrap();
        let logs_dir = dir.path().join("logs");
        fs::create_dir_all(&logs_dir).unwrap();
        // Write more than 20 lines to test tail behavior
        let content: String = (1..=30).map(|i| format!("line {i}\n")).collect();
        fs::write(logs_dir.join("repro.log"), &content).unwrap();
        report_failure(dir.path(), 42, 100);
    }

    #[test]
    fn report_failure_with_short_repro_log() {
        let dir = tempfile::tempdir().unwrap();
        let logs_dir = dir.path().join("logs");
        fs::create_dir_all(&logs_dir).unwrap();
        fs::write(logs_dir.join("repro.log"), "only one line\n").unwrap();
        report_failure(dir.path(), 1, 3);
    }

    #[test]
    fn report_failure_tails_all_regular_log_files() {
        let dir = tempfile::tempdir().unwrap();
        let logs_dir = dir.path().join("logs");
        fs::create_dir_all(&logs_dir).unwrap();
        fs::write(logs_dir.join("proftpd.log"), "daemon failed\n").unwrap();
        fs::write(logs_dir.join("repro.log"), "wrapper failed\n").unwrap();
        fs::create_dir(logs_dir.join("nested")).unwrap();

        report_failure(dir.path(), 1, 3);
    }

    #[test]
    fn sorted_regular_files_returns_sorted_files_only() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("zeta.log"), "z").unwrap();
        fs::write(dir.path().join("alpha.log"), "a").unwrap();
        fs::create_dir(dir.path().join("nested")).unwrap();

        let names: Vec<String> = sorted_regular_files(dir.path())
            .into_iter()
            .map(|path| path.file_name().unwrap().to_string_lossy().into_owned())
            .collect();

        assert_eq!(names, vec!["alpha.log", "zeta.log"]);
    }

    #[test]
    fn tail_file_lines_returns_only_requested_tail() {
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("service.log");
        fs::write(&log, "one\ntwo\nthree\n").unwrap();

        assert_eq!(tail_file_lines(&log, 2).unwrap(), vec!["two", "three"]);
    }

    #[test]
    fn show_logs_summary_with_multiple_files() {
        let dir = tempfile::tempdir().unwrap();
        let logs_dir = dir.path().join("logs");
        fs::create_dir_all(&logs_dir).unwrap();
        fs::write(logs_dir.join("install.log"), "installed").unwrap();
        fs::write(logs_dir.join("repro.log"), "repro output").unwrap();
        fs::write(logs_dir.join("result.json"), "{}").unwrap();
        show_logs_summary(dir.path());
    }

    #[test]
    fn show_logs_summary_no_logs_dir() {
        let dir = tempfile::tempdir().unwrap();
        // No logs directory at all
        show_logs_summary(dir.path());
    }
}
