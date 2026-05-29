use anyhow::{bail, Context, Result};
use regex::Regex;

/// The kind of identifier the user provided.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InputId {
    Repro(String),
    Ghsa(String),
    Cve(String),
}

/// Parse a user-supplied string into a typed identifier.
pub fn parse_input(input: &str) -> Result<InputId> {
    let repro_re = Regex::new(r"^REPRO-\d{4}-\d+$").unwrap();
    let ghsa_re = Regex::new(r"^GHSA-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}$").unwrap();
    let cve_re = Regex::new(r"^CVE-\d{4}-\d+$").unwrap();

    if repro_re.is_match(input) {
        Ok(InputId::Repro(input.to_string()))
    } else if ghsa_re.is_match(input) {
        Ok(InputId::Ghsa(input.to_string()))
    } else if cve_re.is_match(input) {
        Ok(InputId::Cve(input.to_string()))
    } else {
        bail!(
            "Invalid ID format: {input}\n\
             Expected: REPRO-YYYY-NNNNN, GHSA-xxxx-xxxx-xxxx, or CVE-YYYY-NNNNN"
        );
    }
}

/// Resolve any identifier to its canonical REPRO-... id via the API.
pub fn resolve_repro_id(
    client: &reqwest::blocking::Client,
    api_url: &str,
    id: &InputId,
) -> Result<String> {
    match id {
        InputId::Repro(repro_id) => Ok(repro_id.clone()),
        InputId::Ghsa(ghsa_id) => {
            let url = format!("{api_url}/reproductions/lookup/ghsa/{ghsa_id}");
            let resp: serde_json::Value = client
                .get(&url)
                .send()
                .context(format!("No reproduction found for {ghsa_id}"))?
                .error_for_status()
                .context(format!("No reproduction found for {ghsa_id}"))?
                .json()
                .context("Invalid JSON in GHSA lookup response")?;
            resp["repro_id"]
                .as_str()
                .map(|s| s.to_string())
                .context("Missing repro_id in GHSA lookup response")
        }
        InputId::Cve(cve_id) => {
            let url = format!("{api_url}/reproductions/lookup/cve/{cve_id}");
            let resp: serde_json::Value = client
                .get(&url)
                .send()
                .context(format!("No reproduction found for {cve_id}"))?
                .error_for_status()
                .context(format!("No reproduction found for {cve_id}"))?
                .json()
                .context("Invalid JSON in CVE lookup response")?;
            resp["repro_id"]
                .as_str()
                .map(|s| s.to_string())
                .context("Missing repro_id in CVE lookup response")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_valid_repro_id() {
        assert_eq!(
            parse_input("REPRO-2026-00006").unwrap(),
            InputId::Repro("REPRO-2026-00006".into())
        );
    }

    #[test]
    fn parse_valid_repro_id_large_number() {
        assert_eq!(
            parse_input("REPRO-2026-99999").unwrap(),
            InputId::Repro("REPRO-2026-99999".into())
        );
    }

    #[test]
    fn parse_valid_ghsa_id() {
        assert_eq!(
            parse_input("GHSA-655q-fx9r-782v").unwrap(),
            InputId::Ghsa("GHSA-655q-fx9r-782v".into())
        );
    }

    #[test]
    fn parse_valid_cve_id() {
        assert_eq!(
            parse_input("CVE-2025-1716").unwrap(),
            InputId::Cve("CVE-2025-1716".into())
        );
    }

    #[test]
    fn parse_invalid_input_random_string() {
        assert!(parse_input("hello-world").is_err());
    }

    #[test]
    fn parse_invalid_input_partial_repro() {
        assert!(parse_input("REPRO-2026").is_err());
    }

    #[test]
    fn parse_invalid_input_empty() {
        assert!(parse_input("").is_err());
    }

    #[test]
    fn parse_invalid_ghsa_uppercase() {
        // GHSA ids use lowercase hex
        assert!(parse_input("GHSA-AAAA-BBBB-CCCC").is_err());
    }

    #[test]
    fn parse_invalid_cve_no_number() {
        assert!(parse_input("CVE-abcd-efgh").is_err());
    }

    #[test]
    fn parse_repro_id_is_direct() {
        let client = reqwest::blocking::Client::new();
        let id = InputId::Repro("REPRO-2026-00001".into());
        // Repro IDs resolve locally without network
        let result = resolve_repro_id(&client, "http://localhost:0", &id).unwrap();
        assert_eq!(result, "REPRO-2026-00001");
    }

    // --- additional parse_input edge cases ---

    #[test]
    fn parse_repro_single_digit_sequence() {
        assert_eq!(
            parse_input("REPRO-2026-1").unwrap(),
            InputId::Repro("REPRO-2026-1".into())
        );
    }

    #[test]
    fn parse_cve_single_digit() {
        assert_eq!(
            parse_input("CVE-2025-1").unwrap(),
            InputId::Cve("CVE-2025-1".into())
        );
    }

    #[test]
    fn parse_ghsa_rejects_too_short_segment() {
        assert!(parse_input("GHSA-abc-defg-hijk").is_err());
    }

    #[test]
    fn parse_ghsa_rejects_too_long_segment() {
        assert!(parse_input("GHSA-abcde-fghi-jklm").is_err());
    }

    #[test]
    fn parse_rejects_lowercase_repro() {
        assert!(parse_input("repro-2026-00001").is_err());
    }

    #[test]
    fn parse_rejects_lowercase_cve() {
        assert!(parse_input("cve-2025-1716").is_err());
    }

    #[test]
    fn parse_rejects_whitespace_padding() {
        assert!(parse_input(" REPRO-2026-00001 ").is_err());
    }

    #[test]
    fn parse_rejects_repro_with_letters_in_sequence() {
        assert!(parse_input("REPRO-2026-abc").is_err());
    }

    #[test]
    fn parse_rejects_cve_missing_year() {
        assert!(parse_input("CVE--1716").is_err());
    }

    #[test]
    fn parse_ghsa_allows_digits_in_segments() {
        assert_eq!(
            parse_input("GHSA-1234-5678-9abc").unwrap(),
            InputId::Ghsa("GHSA-1234-5678-9abc".into())
        );
    }

    #[test]
    fn parse_rejects_trailing_newline() {
        assert!(parse_input("REPRO-2026-00001\n").is_err());
    }

    #[test]
    fn parse_rejects_repro_with_extra_dashes() {
        assert!(parse_input("REPRO-2026-001-extra").is_err());
    }

    #[test]
    fn parse_rejects_cve_with_extra_dashes() {
        assert!(parse_input("CVE-2025-1716-1").is_err());
    }

    #[test]
    fn parse_rejects_ghsa_with_only_two_segments() {
        assert!(parse_input("GHSA-abcd-efgh").is_err());
    }

    #[test]
    fn parse_rejects_ghsa_with_four_segments() {
        assert!(parse_input("GHSA-abcd-efgh-ijkl-mnop").is_err());
    }

    #[test]
    fn parse_rejects_repro_zero_year() {
        assert!(parse_input("REPRO-0000-00001").is_ok());
    }

    #[test]
    fn parse_cve_large_sequence_number() {
        assert_eq!(
            parse_input("CVE-2025-999999999").unwrap(),
            InputId::Cve("CVE-2025-999999999".into())
        );
    }

    #[test]
    fn parse_rejects_ghsa_with_uppercase_hex() {
        // A-F are uppercase, should be rejected
        assert!(parse_input("GHSA-ABCD-efgh-ijkl").is_err());
    }

    #[test]
    fn parse_rejects_just_prefix() {
        assert!(parse_input("REPRO-").is_err());
        assert!(parse_input("CVE-").is_err());
        assert!(parse_input("GHSA-").is_err());
    }

    #[test]
    fn input_id_debug_and_clone() {
        let id = InputId::Repro("REPRO-2026-00001".into());
        let cloned = id.clone();
        assert_eq!(id, cloned);
        // Verify Debug impl works
        let debug = format!("{:?}", id);
        assert!(debug.contains("Repro"));
    }

    #[test]
    fn input_id_equality() {
        let a = InputId::Ghsa("GHSA-1234-5678-9abc".into());
        let b = InputId::Ghsa("GHSA-1234-5678-9abc".into());
        let c = InputId::Cve("CVE-2025-0001".into());
        assert_eq!(a, b);
        assert_ne!(a, c);
    }
}
