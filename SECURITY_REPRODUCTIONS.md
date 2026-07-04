# Pruva Security Reproductions

Pruva publishes verified security vulnerability reproductions with permanent
`REPRO-*` identifiers. This public repository is the GitHub Codespaces execution
surface for those records.

## Public Indexes

- Browse verified reproductions: https://pruva.dev/reproductions
- CVE lookup pages: `https://pruva.dev/cve/CVE-YYYY-NNNNN`
- GHSA lookup pages: `https://pruva.dev/ghsa/GHSA-xxxx-xxxx-xxxx`
- Permanent reproduction pages: `https://pruva.dev/r/REPRO-YYYY-NNNNN`
- Plain-text agent view: `https://pruva.dev/r/REPRO-YYYY-NNNNN.txt`

## Agent-Readable Feeds

- AI assistant guide: https://pruva.dev/llms.txt
- Full reproduction catalog: https://pruva.dev/llms-full.txt
- Public API list: https://api.pruva.dev/v1/reproductions?status=published&limit=10
- Reproduction feed: https://api.pruva.dev/v1/reproductions/feed.xml

## Example Record

- CVE page: https://pruva.dev/cve/CVE-2026-48611
- Reproduction page: https://pruva.dev/r/REPRO-2026-00223
- Plain-text proof: https://pruva.dev/r/REPRO-2026-00223.txt
- JSON metadata: https://api.pruva.dev/v1/reproductions/REPRO-2026-00223

## How Verification Works

1. A published `REPRO-*` record points to public metadata and artifacts on the
   Pruva API.
2. This repository provides the public Codespaces runtime and `pruva-verify`
   client.
3. Codespaces opens the matching `repro/<REPRO_ID>` branch and runs
   `pruva-verify`.
4. The verifier downloads public artifacts, executes the reproduction script in
   the sandbox, and records pass/fail evidence.

Run a published reproduction locally:

```bash
curl -fsSL https://pruva.dev/install.sh | sh
pruva-verify CVE-2026-48611
```

Or open the reproduction from its page on https://pruva.dev/reproductions.
