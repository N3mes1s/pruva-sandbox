use anyhow::{bail, Context, Result};
use serde::Deserialize;

/// A single artifact entry from the API.
#[derive(Debug, Clone, Deserialize)]
pub struct Artifact {
    pub path: String,
    #[serde(default)]
    pub category: String,
    #[serde(default)]
    pub size: u64,
}

/// The environment block from metadata.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct Environment {
    #[serde(default)]
    pub sandbox_version: Option<String>,
}

/// Reproduction metadata from the Pruva API.
#[derive(Debug, Clone, Deserialize)]
pub struct ReproMetadata {
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub severity: Option<String>,
    #[serde(default)]
    pub ghsa_id: Option<String>,
    #[serde(default)]
    pub cve_id: Option<String>,
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default)]
    pub reproduction_script: Option<String>,
    #[serde(default)]
    pub artifacts: Vec<Artifact>,
    #[serde(default)]
    pub environment: Environment,
}

/// Fetch reproduction metadata from the API.
pub fn fetch_metadata(
    client: &reqwest::blocking::Client,
    api_url: &str,
    repro_id: &str,
) -> Result<ReproMetadata> {
    let url = format!("{api_url}/reproductions/{repro_id}");
    client
        .get(&url)
        .send()
        .context("Failed to fetch reproduction metadata")?
        .error_for_status()
        .context("Failed to fetch reproduction metadata")?
        .json::<ReproMetadata>()
        .context("Failed to parse reproduction metadata JSON")
}

/// Select the reproduction script path from the metadata.
///
/// Priority:
///   1. `reproduction_script` field if set
///   2. First artifact with category "reproduction_script" under `repro/`
///   3. Largest artifact with category "reproduction_script"
pub fn select_script_artifact(meta: &ReproMetadata) -> Result<String> {
    // 1. Direct field
    if let Some(ref script) = meta.reproduction_script {
        if !script.is_empty() {
            return Ok(script.clone());
        }
    }

    let repro_scripts: Vec<&Artifact> = meta
        .artifacts
        .iter()
        .filter(|a| a.category == "reproduction_script")
        .collect();

    if repro_scripts.is_empty() {
        bail!("No reproduction script found in metadata");
    }

    // 2. Prefer one under repro/
    if let Some(a) = repro_scripts.iter().find(|a| a.path.starts_with("repro/")) {
        return Ok(a.path.clone());
    }

    // 3. Fallback to largest
    repro_scripts
        .iter()
        .max_by_key(|a| a.size)
        .map(|a| a.path.clone())
        .context("No reproduction script found in metadata")
}

/// Determine which artifact paths to download.
///
/// Includes: the script itself, anything under `repro/`, `bundle/repro/`,
/// and companion files in the same directory as the script.
pub fn artifacts_to_download(meta: &ReproMetadata, script_path: &str) -> Vec<String> {
    let script_dir = {
        let p = std::path::Path::new(script_path);
        match p.parent() {
            Some(parent) if parent != std::path::Path::new("") => {
                Some(format!("{}/", parent.display()))
            }
            _ => None,
        }
    };

    meta.artifacts
        .iter()
        .filter(|a| {
            a.path == script_path
                || a.path.starts_with("repro/")
                || a.path.starts_with("bundle/repro/")
                || script_dir
                    .as_ref()
                    .map_or(false, |prefix| a.path.starts_with(prefix))
        })
        .map(|a| a.path.clone())
        .collect()
}

/// Strip the leading `bundle/` prefix from a path if present.
pub fn normalize_artifact_path(path: &str) -> &str {
    path.strip_prefix("bundle/").unwrap_or(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_artifact(path: &str, category: &str, size: u64) -> Artifact {
        Artifact {
            path: path.to_string(),
            category: category.to_string(),
            size,
        }
    }

    fn base_metadata() -> ReproMetadata {
        ReproMetadata {
            title: Some("Test vuln".into()),
            severity: Some("high".into()),
            ghsa_id: Some("GHSA-xxxx-xxxx-xxxx".into()),
            cve_id: Some("CVE-2025-0001".into()),
            status: Some("published".into()),
            reproduction_script: None,
            artifacts: vec![],
            environment: Environment::default(),
        }
    }

    // --- select_script_artifact tests ---

    #[test]
    fn select_script_uses_reproduction_script_field() {
        let mut meta = base_metadata();
        meta.reproduction_script = Some("repro/exploit.sh".into());
        meta.artifacts = vec![make_artifact("repro/other.py", "reproduction_script", 500)];
        assert_eq!(select_script_artifact(&meta).unwrap(), "repro/exploit.sh");
    }

    #[test]
    fn select_script_ignores_empty_reproduction_script_field() {
        let mut meta = base_metadata();
        meta.reproduction_script = Some("".into());
        meta.artifacts = vec![make_artifact(
            "repro/exploit.sh",
            "reproduction_script",
            100,
        )];
        assert_eq!(select_script_artifact(&meta).unwrap(), "repro/exploit.sh");
    }

    #[test]
    fn select_script_prefers_repro_prefix() {
        let mut meta = base_metadata();
        meta.artifacts = vec![
            make_artifact("exploit.sh", "reproduction_script", 500),
            make_artifact("repro/run.sh", "reproduction_script", 100),
        ];
        assert_eq!(select_script_artifact(&meta).unwrap(), "repro/run.sh");
    }

    #[test]
    fn select_script_falls_back_to_largest() {
        let mut meta = base_metadata();
        meta.artifacts = vec![
            make_artifact("small.sh", "reproduction_script", 100),
            make_artifact("big.sh", "reproduction_script", 9000),
        ];
        assert_eq!(select_script_artifact(&meta).unwrap(), "big.sh");
    }

    #[test]
    fn select_script_errors_on_no_artifacts() {
        let meta = base_metadata();
        assert!(select_script_artifact(&meta).is_err());
    }

    #[test]
    fn select_script_ignores_non_reproduction_category() {
        let mut meta = base_metadata();
        meta.artifacts = vec![make_artifact("repro/run.sh", "log", 100)];
        assert!(select_script_artifact(&meta).is_err());
    }

    // --- normalize_artifact_path tests ---

    #[test]
    fn normalize_strips_bundle_prefix() {
        assert_eq!(
            normalize_artifact_path("bundle/repro/exploit.sh"),
            "repro/exploit.sh"
        );
    }

    #[test]
    fn normalize_leaves_non_bundle_path() {
        assert_eq!(
            normalize_artifact_path("repro/exploit.sh"),
            "repro/exploit.sh"
        );
    }

    #[test]
    fn normalize_handles_root_level_file() {
        assert_eq!(normalize_artifact_path("exploit.sh"), "exploit.sh");
    }

    #[test]
    fn normalize_handles_nested_bundle() {
        assert_eq!(
            normalize_artifact_path("bundle/repro/sub/exploit.sh"),
            "repro/sub/exploit.sh"
        );
    }

    // --- artifacts_to_download tests ---

    #[test]
    fn download_includes_script_itself() {
        let mut meta = base_metadata();
        meta.artifacts = vec![
            make_artifact("repro/exploit.sh", "reproduction_script", 100),
            make_artifact("unrelated.txt", "log", 50),
        ];
        let result = artifacts_to_download(&meta, "repro/exploit.sh");
        assert!(result.contains(&"repro/exploit.sh".to_string()));
        assert!(!result.contains(&"unrelated.txt".to_string()));
    }

    #[test]
    fn download_includes_repro_subtree() {
        let mut meta = base_metadata();
        meta.artifacts = vec![
            make_artifact("repro/exploit.sh", "reproduction_script", 100),
            make_artifact("repro/helper.py", "companion", 200),
        ];
        let result = artifacts_to_download(&meta, "repro/exploit.sh");
        assert!(result.contains(&"repro/helper.py".to_string()));
    }

    #[test]
    fn download_includes_bundle_repro_subtree() {
        let mut meta = base_metadata();
        meta.artifacts = vec![
            make_artifact("repro/exploit.sh", "reproduction_script", 100),
            make_artifact("bundle/repro/data.json", "companion", 300),
        ];
        let result = artifacts_to_download(&meta, "repro/exploit.sh");
        assert!(result.contains(&"bundle/repro/data.json".to_string()));
    }

    #[test]
    fn download_includes_companions_in_same_dir() {
        let mut meta = base_metadata();
        meta.artifacts = vec![
            make_artifact("scripts/exploit.sh", "reproduction_script", 100),
            make_artifact("scripts/helper.py", "companion", 200),
            make_artifact("other/unrelated.txt", "log", 50),
        ];
        let result = artifacts_to_download(&meta, "scripts/exploit.sh");
        assert!(result.contains(&"scripts/helper.py".to_string()));
        assert!(!result.contains(&"other/unrelated.txt".to_string()));
    }

    #[test]
    fn download_root_level_script_no_companions() {
        let mut meta = base_metadata();
        meta.artifacts = vec![
            make_artifact("exploit.sh", "reproduction_script", 100),
            make_artifact("other/data.txt", "log", 200),
        ];
        let result = artifacts_to_download(&meta, "exploit.sh");
        assert_eq!(result, vec!["exploit.sh"]);
    }

    // --- additional select_script_artifact edge cases ---

    #[test]
    fn select_script_reproduction_script_field_takes_priority_over_repro_prefix() {
        // reproduction_script field should win even when a repro/-prefixed artifact exists
        let mut meta = base_metadata();
        meta.reproduction_script = Some("custom/path.sh".into());
        meta.artifacts = vec![make_artifact("repro/run.sh", "reproduction_script", 100)];
        assert_eq!(select_script_artifact(&meta).unwrap(), "custom/path.sh");
    }

    #[test]
    fn select_script_none_reproduction_script_field() {
        // None (as opposed to Some("")) should fall through to artifact scan
        let mut meta = base_metadata();
        meta.reproduction_script = None;
        meta.artifacts = vec![make_artifact("repro/run.py", "reproduction_script", 50)];
        assert_eq!(select_script_artifact(&meta).unwrap(), "repro/run.py");
    }

    #[test]
    fn select_script_multiple_repro_prefix_picks_first() {
        // When multiple artifacts start with repro/, the first one wins
        let mut meta = base_metadata();
        meta.artifacts = vec![
            make_artifact("repro/first.sh", "reproduction_script", 100),
            make_artifact("repro/second.sh", "reproduction_script", 200),
        ];
        assert_eq!(select_script_artifact(&meta).unwrap(), "repro/first.sh");
    }

    #[test]
    fn select_script_largest_among_ties() {
        // When no repro/ prefix exists and two have same size, max_by_key picks last
        let mut meta = base_metadata();
        meta.artifacts = vec![
            make_artifact("a.sh", "reproduction_script", 500),
            make_artifact("b.sh", "reproduction_script", 500),
        ];
        // max_by_key with equal keys returns the last element
        let result = select_script_artifact(&meta).unwrap();
        assert_eq!(result, "b.sh");
    }

    #[test]
    fn select_script_single_artifact() {
        let mut meta = base_metadata();
        meta.artifacts = vec![make_artifact("only.sh", "reproduction_script", 42)];
        assert_eq!(select_script_artifact(&meta).unwrap(), "only.sh");
    }

    #[test]
    fn select_script_mixed_categories_only_uses_reproduction_script() {
        let mut meta = base_metadata();
        meta.artifacts = vec![
            make_artifact("repro/log.txt", "log", 9999),
            make_artifact("repro/config.json", "config", 8888),
            make_artifact("exploit.py", "reproduction_script", 10),
        ];
        assert_eq!(select_script_artifact(&meta).unwrap(), "exploit.py");
    }

    // --- additional artifacts_to_download edge cases ---

    #[test]
    fn download_excludes_unrelated_directories() {
        let mut meta = base_metadata();
        meta.artifacts = vec![
            make_artifact("scripts/exploit.sh", "reproduction_script", 100),
            make_artifact("logs/output.txt", "log", 200),
            make_artifact("data/payload.bin", "payload", 300),
        ];
        let result = artifacts_to_download(&meta, "scripts/exploit.sh");
        assert!(result.contains(&"scripts/exploit.sh".to_string()));
        assert!(!result.contains(&"logs/output.txt".to_string()));
        assert!(!result.contains(&"data/payload.bin".to_string()));
    }

    #[test]
    fn download_repro_prefix_included_even_for_non_repro_script() {
        // Anything under repro/ is always included regardless of script location
        let mut meta = base_metadata();
        meta.artifacts = vec![
            make_artifact("custom/exploit.sh", "reproduction_script", 100),
            make_artifact("repro/helper.py", "companion", 200),
            make_artifact("bundle/repro/data.json", "data", 300),
        ];
        let result = artifacts_to_download(&meta, "custom/exploit.sh");
        assert!(result.contains(&"custom/exploit.sh".to_string()));
        assert!(result.contains(&"repro/helper.py".to_string()));
        assert!(result.contains(&"bundle/repro/data.json".to_string()));
    }

    #[test]
    fn download_root_script_does_not_match_root_level_siblings() {
        // Root-level script should NOT pull in other root-level files as companions
        let mut meta = base_metadata();
        meta.artifacts = vec![
            make_artifact("exploit.sh", "reproduction_script", 100),
            make_artifact("helper.py", "companion", 200),
            make_artifact("readme.txt", "docs", 50),
        ];
        let result = artifacts_to_download(&meta, "exploit.sh");
        // Only exact match, no companion matching for root-level scripts
        assert_eq!(result, vec!["exploit.sh"]);
    }

    #[test]
    fn download_nested_script_includes_nested_companions() {
        let mut meta = base_metadata();
        meta.artifacts = vec![
            make_artifact("deep/nested/exploit.sh", "reproduction_script", 100),
            make_artifact("deep/nested/payload.bin", "companion", 200),
            make_artifact("deep/other.txt", "docs", 50),
        ];
        let result = artifacts_to_download(&meta, "deep/nested/exploit.sh");
        assert!(result.contains(&"deep/nested/exploit.sh".to_string()));
        assert!(result.contains(&"deep/nested/payload.bin".to_string()));
        assert!(!result.contains(&"deep/other.txt".to_string()));
    }

    #[test]
    fn download_empty_artifacts_returns_empty() {
        let meta = base_metadata();
        let result = artifacts_to_download(&meta, "repro/exploit.sh");
        assert!(result.is_empty());
    }

    #[test]
    fn download_script_path_not_in_artifacts_still_matches_repro() {
        // Script path is not present as an artifact, but repro/ artifacts are included
        let mut meta = base_metadata();
        meta.artifacts = vec![
            make_artifact("repro/helper.py", "companion", 200),
            make_artifact("unrelated/foo.txt", "log", 50),
        ];
        let result = artifacts_to_download(&meta, "missing/exploit.sh");
        assert!(result.contains(&"repro/helper.py".to_string()));
        assert!(!result.contains(&"unrelated/foo.txt".to_string()));
    }

    // --- additional normalize_artifact_path edge cases ---

    #[test]
    fn normalize_double_bundle_prefix() {
        // Only strips the first bundle/ prefix
        assert_eq!(
            normalize_artifact_path("bundle/bundle/exploit.sh"),
            "bundle/exploit.sh"
        );
    }

    #[test]
    fn normalize_empty_path() {
        assert_eq!(normalize_artifact_path(""), "");
    }

    #[test]
    fn normalize_just_bundle_slash() {
        assert_eq!(normalize_artifact_path("bundle/"), "");
    }

    #[test]
    fn normalize_bundle_without_slash() {
        // "bundle" alone (no trailing slash) should not be stripped
        assert_eq!(normalize_artifact_path("bundle"), "bundle");
    }
}
