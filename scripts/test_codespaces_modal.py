#!/usr/bin/env python3
"""
test_codespaces_modal.py - Run pruva-verify inside Modal sandboxes

Spins up parallel Modal sandboxes using the pruva-sandbox Docker image
and runs pruva-verify for each REPRO_ID, collecting pass/fail results.

Works through HTTP proxies by patching grpclib to tunnel gRPC connections
through HTTP CONNECT.

Prerequisites:
    pip install modal

Usage:
    # Test latest 10 reproductions
    python3 scripts/test_codespaces_modal.py

    # Test specific REPRO_IDs
    python3 scripts/test_codespaces_modal.py --repro-ids REPRO-2026-00105,REPRO-2026-00104

    # Test latest N
    python3 scripts/test_codespaces_modal.py --latest 5

Environment variables:
    MODAL_TOKEN_ID      Modal token ID (required)
    MODAL_TOKEN_SECRET  Modal token secret (required)
    HTTPS_PROXY         HTTP proxy URL (optional, for tunneling)
    PRUVA_API_URL       Pruva API base URL (optional)
"""

import asyncio
import base64
import json
import os
import re
import socket
import ssl as _ssl_mod
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime

sys.stdout.reconfigure(line_buffering=True)

API_URL = os.environ.get("PRUVA_API_URL", "https://pruva-api-production.up.railway.app/v1")
PROXY_URL = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy", "")
MAX_PARALLEL = 5  # Max concurrent sandboxes


# ── Proxy tunnel support for grpclib ──

def _setup_proxy_tunnel():
    """Patch grpclib to tunnel gRPC connections through an HTTP CONNECT proxy.

    This is needed because grpclib (used by Modal) doesn't support HTTP proxies
    natively. We intercept connection creation, establish a CONNECT tunnel through
    the proxy, then do TLS on top with correct SNI (Server Name Indication) so
    Modal's envoy can route the request properly.
    """
    if not PROXY_URL:
        return

    parsed = urllib.parse.urlparse(PROXY_URL)
    proxy_host = parsed.hostname
    proxy_port = parsed.port or 80
    proxy_auth = None
    if parsed.username and parsed.password:
        creds = f"{parsed.username}:{parsed.password}"
        proxy_auth = base64.b64encode(creds.encode()).decode()

    import grpclib.client

    _orig_create = grpclib.client.Channel._create_connection

    def _create_tunnel_socket(target_host, target_port):
        """Create a raw TCP socket tunneled through HTTP CONNECT proxy."""
        sock = socket.create_connection((proxy_host, proxy_port), timeout=30)
        connect_req = f"CONNECT {target_host}:{target_port} HTTP/1.1\r\nHost: {target_host}:{target_port}\r\n"
        if proxy_auth:
            connect_req += f"Proxy-Authorization: Basic {proxy_auth}\r\n"
        connect_req += "\r\n"
        sock.sendall(connect_req.encode())

        resp = b""
        while b"\r\n\r\n" not in resp:
            chunk = sock.recv(4096)
            if not chunk:
                raise ConnectionError("Proxy closed connection during CONNECT")
            resp += chunk

        status_line = resp.split(b"\r\n")[0].decode()
        if "200" not in status_line:
            sock.close()
            raise ConnectionError(f"CONNECT failed: {status_line}")

        sock.setblocking(False)
        return sock

    async def _patched_create(self):
        target_host = self._host
        target_port = self._port

        if target_host in ("127.0.0.1", "localhost", "::1"):
            return await _orig_create(self)

        loop = asyncio.get_event_loop()
        sock = await loop.run_in_executor(None, _create_tunnel_socket, target_host, target_port)

        ssl_ctx = _ssl_mod.SSLContext(_ssl_mod.PROTOCOL_TLS_CLIENT)
        ssl_ctx.check_hostname = False
        ssl_ctx.verify_mode = _ssl_mod.CERT_NONE
        ssl_ctx.set_alpn_protocols(["h2"])

        _, protocol = await loop.create_connection(
            self._protocol_factory,
            ssl=ssl_ctx,
            sock=sock,
            server_hostname=target_host,
        )
        return protocol

    grpclib.client.Channel._create_connection = _patched_create
    print(f"[proxy] Tunnel enabled via {proxy_host}:{proxy_port}", flush=True)


# ── Core test logic ──

async def run_single_test(client, app, image, repro_id: str) -> dict:
    """Run pruva-verify for a single REPRO_ID in a Modal sandbox."""
    import modal

    result = {
        "repro_id": repro_id,
        "status": "unknown",
        "exit_code": -1,
        "duration_secs": 0,
        "stdout": "",
        "stderr": "",
        "missing_deps": [],
    }

    start = time.time()
    try:
        sb = await modal.Sandbox.create.aio(
            app=app, image=image, timeout=1800, client=client,
            env={
                "PRUVA_SANDBOX": "true",
                "PRUVA_API_URL": API_URL,
                "REPRO_ID": repro_id,
                "PRUVA_RESULTS_DIR": "/tmp/pruva-results",
            },
        )

        proc = await sb.exec.aio("bash", "-c", f"pruva-verify {repro_id} 2>&1")
        stdout_lines = []
        async for line in proc.stdout:
            stdout_lines.append(line)
        await proc.wait.aio()

        result["exit_code"] = proc.returncode
        result["stdout"] = "".join(stdout_lines)[-10000:]
        result["status"] = "pass" if proc.returncode == 0 else "fail"

        await sb.terminate.aio()

    except asyncio.TimeoutError:
        result["status"] = "timeout"
        result["stderr"] = "Sandbox timed out"
    except Exception as e:
        result["status"] = "error"
        result["stderr"] = f"{type(e).__name__}: {e}"

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


async def run_tests_parallel(ids: list[str], max_parallel: int = MAX_PARALLEL) -> list[dict]:
    """Run multiple tests in parallel using Modal sandboxes."""
    import modal

    os.environ["MODAL_SERVER_URL"] = "https://api.modal.com"

    token_id = os.environ.get("MODAL_TOKEN_ID", "")
    token_secret = os.environ.get("MODAL_TOKEN_SECRET", "")
    if not token_id or not token_secret:
        print("[error] MODAL_TOKEN_ID and MODAL_TOKEN_SECRET must be set", flush=True)
        sys.exit(1)

    print("[modal] Connecting client...", flush=True)
    client = await modal.Client.from_credentials.aio(token_id, token_secret)
    print("[modal] Client connected!", flush=True)

    print("[modal] Looking up app...", flush=True)
    app = await modal.App.lookup.aio("pruva-codespace-tests", create_if_missing=True, client=client)
    print("[modal] App ready", flush=True)

    image = modal.Image.from_registry("ghcr.io/n3mes1s/pruva-sandbox:latest", add_python="3.12")

    semaphore = asyncio.Semaphore(max_parallel)
    results = []

    async def bounded_test(repro_id):
        async with semaphore:
            print(f"  [start] {repro_id}", flush=True)
            result = await run_single_test(client, app, image, repro_id)
            icon = {"pass": "PASS", "fail": "FAIL", "timeout": "TIMEOUT", "error": "ERROR"}.get(result["status"], "?")
            print(f"  [{icon}]  {repro_id} ({result['duration_secs']}s)", flush=True)
            if result["missing_deps"]:
                for dep in result["missing_deps"]:
                    print(f"         Missing {dep['type']}: {dep['name']}", flush=True)
            return result

    tasks = [bounded_test(rid) for rid in ids]
    results = await asyncio.gather(*tasks)
    return list(results)


def fetch_latest_repro_ids(count: int = 10) -> list[str]:
    """Fetch the latest published REPRO_IDs from the Pruva API."""
    url = f"{API_URL}/reproductions?status=published&limit={count}"
    with urllib.request.urlopen(url, timeout=30) as resp:
        data = json.loads(resp.read())
    return [r["repro_id"] for r in data.get("reproductions", [])]


def fetch_repro_ids_from_branches(count: int = 10) -> list[str]:
    """Fetch REPRO_IDs from git branches (fallback if API doesn't have a list endpoint)."""
    import subprocess
    result = subprocess.run(
        ["git", "branch", "-r", "--sort=-committerdate"],
        capture_output=True, text=True, cwd=os.path.dirname(os.path.dirname(__file__))
    )
    ids = []
    for line in result.stdout.strip().split("\n"):
        line = line.strip()
        if "origin/repro/REPRO-" in line:
            repro_id = line.split("origin/repro/")[-1]
            ids.append(repro_id)
            if len(ids) >= count:
                break
    return ids


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

    all_missing = set()
    for r in results:
        for dep in r.get("missing_deps", []):
            all_missing.add(f"[{dep['type']}] {dep['name']}")

    if all_missing:
        print("  MISSING DEPENDENCIES (add to Dockerfile):")
        for dep in sorted(all_missing):
            print(f"    - {dep}")
        print()

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

    return {"passed": passed, "failed": failed, "errors": errors}


async def async_main(repro_ids: str = "", latest: int = 10):
    """Main async entrypoint."""
    print("=" * 60)
    print("  Pruva Codespace Test (Modal Sandboxes)")
    print("=" * 60)
    print(f"  Time: {datetime.now().isoformat()}")
    print(f"  API:  {API_URL}")
    print()

    _setup_proxy_tunnel()

    if repro_ids:
        ids = [r.strip() for r in repro_ids.split(",") if r.strip()]
    else:
        print(f"Fetching latest {latest} reproductions from API...")
        try:
            ids = fetch_latest_repro_ids(latest)
        except Exception as e:
            print(f"  API fetch failed ({e}), falling back to git branches...")
            ids = fetch_repro_ids_from_branches(latest)

    if not ids:
        print("No REPRO_IDs found to test.")
        return

    print(f"Testing {len(ids)} reproduction(s):")
    for rid in ids:
        print(f"  - {rid}")
    print()

    print(f"Launching tests in Modal sandboxes (max {MAX_PARALLEL} parallel)...")
    print()

    results = await run_tests_parallel(ids)
    summary = print_results(results)

    # Output JSON results for CI integration
    json_results = {
        "timestamp": datetime.now().isoformat(),
        "total": len(results),
        "passed": summary["passed"],
        "failed": summary["failed"],
        "errors": summary["errors"],
        "results": results,
    }

    results_file = os.environ.get("RESULTS_FILE", "")
    if results_file:
        with open(results_file, "w") as f:
            json.dump(json_results, f, indent=2)
        print(f"\nResults written to {results_file}")

    if summary["failed"] > 0 or summary["errors"] > 0:
        sys.exit(1)


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Test Codespace reproductions via Modal sandboxes")
    parser.add_argument("--repro-ids", type=str, default="", help="Comma-separated REPRO_IDs")
    parser.add_argument("--latest", type=int, default=10, help="Test latest N reproductions")
    args = parser.parse_args()

    asyncio.run(async_main(repro_ids=args.repro_ids, latest=args.latest))
