#!/usr/bin/env python3
"""
sandbox_shell.py - Interactive shell into a Modal sandbox using pruva-sandbox image.

Opens a persistent Modal sandbox and lets you run commands interactively.
Useful for debugging reproduction failures.

Usage:
    python3 scripts/sandbox_shell.py
    python3 scripts/sandbox_shell.py --repro-id REPRO-2026-00105

Environment variables:
    MODAL_TOKEN_ID      Modal token ID (required)
    MODAL_TOKEN_SECRET  Modal token secret (required)
    HTTPS_PROXY         HTTP proxy URL (optional)
"""

import asyncio
import base64
import os
import socket
import ssl as _ssl_mod
import sys
import urllib.parse

sys.stdout.reconfigure(line_buffering=True)

API_URL = os.environ.get("PRUVA_API_URL", "https://pruva-api-production.up.railway.app/v1")
PROXY_URL = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy", "")


def _setup_proxy_tunnel():
    """Patch grpclib to tunnel through HTTP CONNECT proxy."""
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


async def run_cmd(sb, cmd):
    """Run a command in the sandbox and return output."""
    proc = await sb.exec.aio("bash", "-c", cmd)
    out = []
    async for line in proc.stdout:
        out.append(line)
        print(line, end="", flush=True)
    await proc.wait.aio()
    return proc.returncode, "".join(out)


async def main(repro_id: str = ""):
    import modal

    _setup_proxy_tunnel()

    os.environ["MODAL_SERVER_URL"] = "https://api.modal.com"

    token_id = os.environ.get("MODAL_TOKEN_ID", "")
    token_secret = os.environ.get("MODAL_TOKEN_SECRET", "")
    if not token_id or not token_secret:
        print("[error] MODAL_TOKEN_ID and MODAL_TOKEN_SECRET must be set")
        sys.exit(1)

    print("[modal] Connecting...", flush=True)
    client = await modal.Client.from_credentials.aio(token_id, token_secret)
    app = await modal.App.lookup.aio("pruva-codespace-tests", create_if_missing=True, client=client)
    image = modal.Image.from_registry("ghcr.io/n3mes1s/pruva-sandbox:latest", add_python="3.12")

    env = {"PRUVA_SANDBOX": "true", "PRUVA_API_URL": API_URL}
    if repro_id:
        env["REPRO_ID"] = repro_id
        env["PRUVA_RESULTS_DIR"] = "/tmp/pruva-results"

    print("[modal] Creating sandbox...", flush=True)
    sb = await modal.Sandbox.create.aio(app=app, image=image, timeout=1800, client=client, env=env)
    print("[sandbox] Ready! Type commands (Ctrl+D to exit):", flush=True)
    print()

    try:
        while True:
            try:
                cmd = input("sandbox$ ")
            except EOFError:
                break
            if not cmd.strip():
                continue
            if cmd.strip() in ("exit", "quit"):
                break
            code, _ = await run_cmd(sb, cmd)
            if code != 0:
                print(f"(exit code: {code})")
    except KeyboardInterrupt:
        pass
    finally:
        print("\n[sandbox] Terminating...", flush=True)
        await sb.terminate.aio()
        print("[sandbox] Done.", flush=True)


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Interactive shell into Modal sandbox")
    parser.add_argument("--repro-id", type=str, default="", help="REPRO_ID to set in env")
    args = parser.parse_args()

    asyncio.run(main(repro_id=args.repro_id))
