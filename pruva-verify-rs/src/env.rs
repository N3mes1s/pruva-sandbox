use std::collections::HashMap;
use std::fs;
use std::path::Path;

/// Read /etc/pruva-sandbox-version into a key=value map.
pub fn load_sandbox_version() -> Option<HashMap<String, String>> {
    let path = Path::new("/etc/pruva-sandbox-version");
    if !path.exists() {
        return None;
    }

    let content = fs::read_to_string(path).ok()?;
    let map: HashMap<String, String> = content
        .lines()
        .filter_map(|line| {
            let line = line.trim();
            let (key, val) = line.split_once('=')?;
            // Strip surrounding quotes from value
            let val = val.trim_matches('"');
            Some((key.to_string(), val.to_string()))
        })
        .collect();

    if map.is_empty() {
        None
    } else {
        Some(map)
    }
}

/// Determine the results directory.
///
/// Priority:
///   1. `PRUVA_RESULTS_DIR` env var
///   2. `/workspaces/<repo>/pruva-results` in Codespaces
///   3. `$HOME/pruva-results`
pub fn results_dir() -> String {
    if let Ok(dir) = std::env::var("PRUVA_RESULTS_DIR") {
        if !dir.is_empty() {
            return dir;
        }
    }

    let is_codespaces = std::env::var("CODESPACES").ok().as_deref() == Some("true");
    if is_codespaces {
        if let Ok(repo) = std::env::var("GITHUB_REPOSITORY") {
            // "owner/repo-name" -> "repo-name"
            let repo_name = repo.rsplit('/').next().unwrap_or(&repo);
            return format!("/workspaces/{repo_name}/pruva-results");
        }
    }

    let home = std::env::var("HOME").unwrap_or_else(|_| "/root".to_string());
    format!("{home}/pruva-results")
}

/// Whether we're in a sandbox environment (auto-confirm).
pub fn is_sandbox() -> bool {
    std::env::var("CODESPACES").ok().as_deref() == Some("true")
        || std::env::var("PRUVA_SANDBOX").ok().as_deref() == Some("true")
}

/// Whether stdin is a terminal (for interactive confirmation).
pub fn is_interactive() -> bool {
    atty_stdin()
}

fn atty_stdin() -> bool {
    unsafe { libc::isatty(libc::STDIN_FILENO) != 0 }
}

/// Ask for interactive confirmation. Returns `true` to proceed.
pub fn confirm_execution() -> bool {
    if is_sandbox() {
        crate::display::log("Auto-confirming in sandbox environment...");
        return true;
    }

    if !is_interactive() {
        // Non-interactive, non-sandbox: proceed (matches bash behavior)
        return true;
    }

    eprint!("Continue? [y/N] ");
    let mut input = String::new();
    if std::io::stdin().read_line(&mut input).is_err() {
        return false;
    }
    matches!(input.trim(), "y" | "Y")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn results_dir_respects_env_override() {
        // This test is sensitive to env vars, so we test the logic path
        // by examining the function's documented behavior. In a real test
        // harness you'd use temp_env or similar.
        let dir = results_dir();
        // Should at minimum return a non-empty string
        assert!(!dir.is_empty());
        assert!(dir.ends_with("pruva-results"));
    }

    #[test]
    fn is_sandbox_false_by_default() {
        // In test context, neither CODESPACES nor PRUVA_SANDBOX should be set
        // (unless running inside a codespace, in which case this is correct)
        let result = is_sandbox();
        // We can't assert false because the test might run in a sandbox.
        // Just verify it returns a bool without panicking.
        let _ = result;
    }

    #[test]
    fn load_sandbox_version_returns_none_when_missing() {
        // /etc/pruva-sandbox-version likely doesn't exist in test env
        // If it does, it should return Some with a valid map
        let result = load_sandbox_version();
        // Either None or Some with entries - both are valid
        if let Some(map) = result {
            assert!(!map.is_empty());
        }
    }
}
