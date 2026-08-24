#!/usr/bin/env bash
set -euo pipefail

init_script="${PRUVA_DIND_INIT_SCRIPT:-/usr/local/share/docker-init.sh}"
marker="PRUVA_DIND_BACKEND_MARKER"

if [[ ! -f "$init_script" ]]; then
  echo "Missing docker-in-docker init script: $init_script" >&2
  exit 1
fi

python3 - "$init_script" "$marker" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
marker = sys.argv[2]
text = path.read_text()
if marker in text:
    raise SystemExit(0)

start = text.find("# Prefer legacy only when the ip_tables kernel module is actually present.")
end = text.find('dockerd_start="', start)
if start < 0 or end < 0:
    raise SystemExit("Could not find docker-init iptables backend selection block")

replacement = f"""# {marker}: Codespaces can retain a legacy FORWARD DROP table even when
# the default alternative points at nft. Probe legacy first so dockerd writes
# rules to the backend that will actually see bridged container traffic.
if type iptables-legacy > /dev/null 2>&1 \\
   && update-alternatives --list iptables 2>/dev/null | grep -q '/usr/sbin/iptables-legacy'; then
    iptables-legacy -S >/dev/null 2>&1 || true
fi

if type iptables-legacy > /dev/null 2>&1 \\
   && {{ grep -qE '^(ip_tables)\\b' /proc/modules \\
        || [ -d /sys/module/ip_tables ]; }} \\
   && update-alternatives --list iptables 2>/dev/null | grep -q '/usr/sbin/iptables-legacy'; then
    update-alternatives --set iptables  /usr/sbin/iptables-legacy || true
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy || true
elif type iptables-nft > /dev/null 2>&1 \\
     && update-alternatives --list iptables 2>/dev/null | grep -q '/usr/sbin/iptables-nft'; then
    update-alternatives --set iptables  /usr/sbin/iptables-nft  || true
    update-alternatives --set ip6tables /usr/sbin/ip6tables-nft || true
fi
"""

path.write_text(text[:start] + replacement + text[end:])
PY
