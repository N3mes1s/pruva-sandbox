#!/usr/bin/env python3
"""
test_codespaces_modal.py - Run pruva-verify inside Modal containers

Spins up parallel Modal sandboxes using the pruva-sandbox Docker image
and runs pruva-verify for each REPRO_ID, collecting pass/fail results.

Prerequisites:
    pip install modal
    modal token set --token-id <id> --token-secret <secret>

Usage:
    # Test latest 10 reproductions
    python3 scripts/test_codespaces_modal.py

    # Test specific REPRO_IDs
    python3 scripts/test_codespaces_modal.py --repro-ids REPRO-2026-00105,REPRO-2026-00104

    # Test latest N
    python3 scripts/test_codespaces_modal.py --latest 5

    # Or via modal run (uses @app.local_entrypoint):
    modal run scripts/test_codespaces_modal.py --latest 5
"""

import json
import sys
import urllib.request
from datetime import datetime

import modal

API_URL = "https://pruva-api-production.up.railway.app/v1"

# The pruva-sandbox Docker image from GHCR, with all repro tools pre-installed.
# add_python ensures Modal's runtime is available inside the container.
pruva_image = modal.Image.from_registry(
    "ghcr.io/n3mes1s/pruva-sandbox:latest",
    add_python="3.12",
)

app = modal.App("pruva-codespace-tests")


@app.function(
    image=pruva_image,
    timeout=1800,  # 30 minutes max per reproduction
    retries=0,
    memory=2048,
)
def run_pruva_verify(repro_id: str) -> dict:
    """Run pruva-verify for a single REPRO_ID inside the Modal container.

    This mimics exactly what happens when a GitHub Codespace starts:
    the container has pruva-verify pre-installed, and it runs with
    the REPRO_ID set as an environment variable.
    """
    import os
    import re
    import subprocess
    import time

    result = {
        "repro_id": repro_id,
        "status": "unknown",
        "exit_code": -1,
        "duration_secs": 0,
        "stdout": "",
        "stderr": "",
        "missing_deps": [],
    }

    env = os.environ.copy()
    env["PRUVA_SANDBOX"] = "true"
    env["PRUVA_API_URL"] = API_URL
    env["REPRO_ID"] = repro_id
    env["PRUVA_RESULTS_DIR"] = "/tmp/pruva-results"

    start = time.time()
    try:
        proc = subprocess.run(
            ["pruva-verify", repro_id],
            capture_output=True,
            text=True,
            timeout=1500,  # 25 min process timeout
            env=env,
        )
        result["exit_code"] = proc.returncode
        result["stdout"] = proc.stdout[-10000:]  # Last 10KB
        result["stderr"] = proc.stderr[-5000:]
        result["status"] = "pass" if proc.returncode == 0 else "fail"
    except subprocess.TimeoutExpired:
        result["status"] = "timeout"
        result["stderr"] = "Process timed out after 25 minutes"
    except Exception as e:
        result["status"] = "error"
        result["stderr"] = str(e)

    result["duration_secs"] = round(time.time() - start, 1)

    # Detect missing dependencies from output
    output = result["stdout"] + result["stderr"]
    missing = []
    for line in output.split("\n"):
        if "command not found" in line:
            parts = line.split(":")
            if len(parts) >= 2:
                cmd = parts[-2].strip()
                if cmd and not cmd.startswith("/"):
                    missing.append({"type": "command", "name": cmd})
        m = re.search(r"No module named '([^']+)'", line)
        if m:
            missing.append({"type": "python", "name": m.group(1)})
        m = re.search(r"Cannot find module '([^']+)'", line)
        if m and not m.group(1).startswith(("/", ".")):
            missing.append({"type": "npm", "name": m.group(1)})

    result["missing_deps"] = missing
    return result


def fetch_latest_repro_ids(count: int = 10) -> list[str]:
    """Fetch the latest published REPRO_IDs from the Pruva API."""
    url = f"{API_URL}/reproductions?status=published&limit={count}"
    with urllib.request.urlopen(url, timeout=30) as resp:
        data = json.loads(resp.read())
    return [r["repro_id"] for r in data.get("reproductions", [])]


def print_results(results: list[dict]):
    """Print formatted results summary."""
    passed = sum(1 for r in results if r["status"] == "pass")
    failed = sum(1 for r in results if r["status"] == "fail")
    errors = sum(1 for r in results if r["status"] in ("error", "timeout"))

    print()
    print("=" * 60)
    print("  RESULTS SUMMARY")
    print("=" * 60)
    print(f"  Total:   {len(results)}")
    print(f"  Passed:  {passed}")
    print(f"  Failed:  {failed}")
    print(f"  Errors:  {errors}")
    print()

    # Collect missing deps
    all_missing = set()
    for r in results:
        for dep in r.get("missing_deps", []):
            all_missing.add(f"[{dep['type']}] {dep['name']}")

    if all_missing:
        print("  MISSING DEPENDENCIES (add to Dockerfile):")
        for dep in sorted(all_missing):
            print(f"    - {dep}")
        print()

    # Print failure details
    for r in results:
        if r["status"] != "pass":
            print(f"\n--- {r['repro_id']} ({r['status'].upper()}, exit {r['exit_code']}, {r['duration_secs']}s) ---")
            if r["stderr"]:
                print("STDERR (last 500 chars):")
                print(r["stderr"][-500:])
            if r["stdout"]:
                print("STDOUT (last 500 chars):")
                print(r["stdout"][-500:])
            print()

    if failed > 0 or errors > 0:
        print("SOME TESTS FAILED")
    else:
        print("ALL TESTS PASSED")


@app.local_entrypoint()
def main(
    repro_ids: str = "",
    latest: int = 10,
):
    """Test Codespace reproductions using Modal containers.

    Args:
        repro_ids: Comma-separated REPRO_IDs to test
        latest: Number of latest reproductions to test (default: 10)
    """
    print("=" * 60)
    print("  Pruva Codespace Test (Modal)")
    print("=" * 60)
    print(f"  Time: {datetime.now().isoformat()}")
    print(f"  API:  {API_URL}")
    print()

    if repro_ids:
        ids = [r.strip() for r in repro_ids.split(",") if r.strip()]
    else:
        print(f"Fetching latest {latest} reproductions from API...")
        ids = fetch_latest_repro_ids(latest)

    print(f"Testing {len(ids)} reproduction(s):")
    for rid in ids:
        print(f"  - {rid}")
    print()

    print("Launching parallel tests in Modal containers...")
    print("(Each runs in its own pruva-sandbox container)")
    print()

    results = []
    for result in run_pruva_verify.map(ids):
        icon = {"pass": "\u2705", "fail": "\u274c", "timeout": "\u23f0", "error": "\u26a0\ufe0f"}.get(result["status"], "?")
        print(f"  {icon} {result['repro_id']}: {result['status'].upper()} ({result['duration_secs']}s)")
        if result["missing_deps"]:
            for dep in result["missing_deps"]:
                print(f"      Missing {dep['type']}: {dep['name']}")
        results.append(result)

    print_results(results)

    if any(r["status"] != "pass" for r in results):
        sys.exit(1)


# Also support running directly with `python3 scripts/test_codespaces_modal.py`
if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Test Codespace reproductions via Modal")
    parser.add_argument("--repro-ids", type=str, default="", help="Comma-separated REPRO_IDs")
    parser.add_argument("--latest", type=int, default=10, help="Test latest N reproductions")
    args = parser.parse_args()

    # When running directly, use modal.run() to execute the app
    with modal.enable_output():
        with app.run():
            main.local(repro_ids=args.repro_ids, latest=args.latest)
