use colored::Colorize;

pub fn log(msg: &str) {
    println!("{} {msg}", "[pruva]".cyan());
}

pub fn error(msg: &str) {
    eprintln!("{} {msg}", "[pruva]".red());
}

pub fn success(msg: &str) {
    println!("{} {msg}", "[pruva]".green());
}

pub fn warn(msg: &str) {
    println!("{} {msg}", "[pruva]".yellow());
}

/// Print the reproduction banner.
pub fn print_banner(
    repro_id: &str,
    title: &str,
    severity: &str,
    ghsa_id: Option<&str>,
    cve_id: Option<&str>,
) {
    println!();
    println!("{}", "========================================".bold());
    println!("{}", repro_id.bold());
    println!("{}", "========================================".bold());
    println!("{} {title}", "Title:   ".bold());
    println!("{} {severity}", "Severity:".bold());
    if let Some(ghsa) = ghsa_id {
        println!("{} {ghsa}", "GHSA:    ".bold());
    }
    if let Some(cve) = cve_id {
        println!("{} {cve}", "CVE:     ".bold());
    }
    println!("{}", "========================================".bold());
    println!();
}

/// Print the pre-execution warning.
pub fn print_warning() {
    println!();
    warn("==========================================");
    warn("  WARNING: This will execute code that");
    warn("  exploits a real vulnerability.");
    warn("==========================================");
    println!();
}

#[cfg(test)]
mod tests {
    // Display functions are side-effect-only (stdout/stderr). We verify they
    // don't panic. Integration tests can capture output if needed.

    use super::*;

    #[test]
    fn log_does_not_panic() {
        log("test message");
    }

    #[test]
    fn error_does_not_panic() {
        error("test error");
    }

    #[test]
    fn success_does_not_panic() {
        success("test success");
    }

    #[test]
    fn warn_does_not_panic() {
        warn("test warn");
    }

    #[test]
    fn print_banner_full() {
        print_banner(
            "REPRO-2026-00001",
            "Test vuln",
            "HIGH",
            Some("GHSA-xxxx-xxxx-xxxx"),
            Some("CVE-2025-0001"),
        );
    }

    #[test]
    fn print_banner_no_ghsa_or_cve() {
        print_banner("REPRO-2026-00001", "Test vuln", "HIGH", None, None);
    }

    #[test]
    fn print_warning_does_not_panic() {
        print_warning();
    }
}
