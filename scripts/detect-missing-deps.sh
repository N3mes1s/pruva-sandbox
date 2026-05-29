#!/usr/bin/env bash
#
# detect-missing-deps.sh - Analyze pruva-verify failure logs to detect missing dependencies
#
# Reads a log file from a failed reproduction and outputs:
#   - Detected missing commands/tools
#   - Suggested apt packages to install
#   - Suggested pip packages to install
#   - Suggested npm packages to install
#
# Usage:
#   ./scripts/detect-missing-deps.sh /path/to/log
#   ./scripts/detect-missing-deps.sh /path/to/log --json
#
set -euo pipefail

LOG_FILE="${1:-}"
OUTPUT_JSON=false

if [[ "${2:-}" == "--json" ]]; then
  OUTPUT_JSON=true
fi

if [[ -z "$LOG_FILE" ]] || [[ ! -f "$LOG_FILE" ]]; then
  echo "Usage: $0 <log-file> [--json]" >&2
  exit 1
fi

# Known mappings: command/module -> apt package
declare -A CMD_TO_APT=(
  [locate]="plocate"
  [plocate]="plocate"
  [mlocate]="plocate"
  [updatedb]="plocate"
  [docker]="docker.io"
  [docker-compose]="docker-compose"
  [go]="golang"
  [cargo]="cargo"
  [rustc]="rustc"
  [ruby]="ruby"
  [gem]="ruby"
  [perl]="perl"
  [php]="php"
  [java]="default-jdk"
  [javac]="default-jdk"
  [mvn]="maven"
  [gradle]="gradle"
  [make]="build-essential"
  [gcc]="build-essential"
  [g++]="build-essential"
  [nmap]="nmap"
  [netcat]="netcat-openbsd"
  [nc]="netcat-openbsd"
  [socat]="socat"
  [sqlite3]="sqlite3"
  [psql]="postgresql-client"
  [mysql]="mysql-client"
  [redis-cli]="redis-tools"
  [openssl]="openssl"
  [curl]="curl"
  [wget]="wget"
  [autoconf]="autoconf"
  [autoreconf]="autoconf"
  [aclocal]="automake"
  [automake]="automake"
  [libtoolize]="libtool"
  [xmllint]="libxml2-utils"
  [xsltproc]="xsltproc"
  [ffmpeg]="ffmpeg"
  [convert]="imagemagick"
  [ldapsearch]="ldap-utils"
  [pip]="python3-pip"
  [pip3]="python3-pip"
  [virtualenv]="python3-venv"
  [composer]="composer"
  [phpize]="php-dev"
)

# Known Python module -> pip package
declare -A PYMOD_TO_PIP=(
  [requests]="requests"
  [flask]="flask"
  [django]="django"
  [numpy]="numpy"
  [pandas]="pandas"
  [yaml]="pyyaml"
  [pyyaml]="pyyaml"
  [jwt]="pyjwt"
  [cryptography]="cryptography"
  [paramiko]="paramiko"
  [boto3]="boto3"
  [aiohttp]="aiohttp"
  [httpx]="httpx"
  [bs4]="beautifulsoup4"
  [lxml]="lxml"
  [PIL]="pillow"
  [cv2]="opencv-python"
  [redis]="redis"
  [psycopg2]="psycopg2-binary"
  [pymongo]="pymongo"
  [sqlalchemy]="sqlalchemy"
  [pydantic]="pydantic"
  [fastapi]="fastapi"
  [uvicorn]="uvicorn"
  [websockets]="websockets"
  [grpc]="grpcio"
  [protobuf]="protobuf"
)

# Collect findings
APT_PACKAGES=()
PIP_PACKAGES=()
NPM_PACKAGES=()
MISSING_COMMANDS=()
DIAGNOSTICS=()

add_missing_command() {
  local cmd="$1"
  [[ -z "$cmd" ]] && return
  MISSING_COMMANDS+=("$cmd")
  if [[ -n "${CMD_TO_APT[$cmd]:-}" ]]; then
    APT_PACKAGES+=("${CMD_TO_APT[$cmd]}")
  fi
}

add_diagnostic() {
  local diagnostic="$1"
  [[ -z "$diagnostic" ]] && return
  DIAGNOSTICS+=("$diagnostic")
}

# Pattern: "command not found"
while IFS= read -r line; do
  # bash: foo: command not found
  cmd=$(echo "$line" | grep -oP '(?<=: )\S+(?=: command not found)' || true)
  if [[ -n "$cmd" ]]; then
    add_missing_command "$cmd"
  fi

  # foo: command not found
  cmd=$(echo "$line" | grep -oP '^[[:alnum:]_.+-]+(?=: command not found)' || true)
  if [[ -n "$cmd" ]]; then
    add_missing_command "$cmd"
  fi

  # sh: 1: foo: not found / ERROR: foo not found
  if [[ "$line" != *"command not found" ]]; then
    cmd=$(echo "$line" | grep -oP '(?<=: )[[:alnum:]_.+-]+(?=:? not found$)' || true)
    if [[ -n "$cmd" ]]; then
      add_missing_command "$cmd"
    fi
  fi

  # /usr/bin/env: 'foo': No such file or directory
  cmd=$(echo "$line" | grep -oP "(?<=/usr/bin/env: ')[^']+(?=': No such file or directory)" || true)
  if [[ -n "$cmd" ]]; then
    add_missing_command "$cmd"
  fi

  # Python: ModuleNotFoundError: No module named 'foo'
  mod=$(echo "$line" | grep -oP "(?<=No module named ')[^'.]+(?=')" || true)
  if [[ -n "$mod" ]]; then
    if [[ -n "${PYMOD_TO_PIP[$mod]:-}" ]]; then
      PIP_PACKAGES+=("${PYMOD_TO_PIP[$mod]}")
    else
      PIP_PACKAGES+=("$mod")
    fi
  fi

  # Node: Cannot find module 'foo'
  mod=$(echo "$line" | grep -oP "(?<=Cannot find module ')[^']+(?=')" || true)
  if [[ -n "$mod" ]] && [[ "$mod" != /* ]] && [[ "$mod" != ./* ]]; then
    NPM_PACKAGES+=("$mod")
  fi

  # Node: Error: Cannot find package 'foo'
  mod=$(echo "$line" | grep -oP "(?<=Cannot find package ')[^']+(?=')" || true)
  if [[ -n "$mod" ]]; then
    NPM_PACKAGES+=("$mod")
  fi

  # cannot open shared object file
  lib=$(echo "$line" | grep -oP '\S+\.so[.\d]*(?=: cannot open shared object file)' || true)
  if [[ -n "$lib" ]]; then
    MISSING_COMMANDS+=("shared-lib:$lib")
  fi

  if [[ "$line" == *"failed to connect to the docker API"* ]] || [[ "$line" == *"Cannot connect to the Docker daemon"* ]]; then
    add_diagnostic "docker-daemon-unavailable"
  fi

  if [[ "$line" == *"Acquire (13: Permission denied)"* ]] || [[ "$line" == *"/var/lib/apt/lists/partial is missing"* ]]; then
    add_diagnostic "apt-permission-denied"
  fi

  if [[ "$line" == *"pathspec"* && "$line" == *"did not match any file"* ]] || [[ "$line" == *"couldn't find remote ref"* ]]; then
    add_diagnostic "invalid-git-ref"
  fi

done < "$LOG_FILE"

# Deduplicate
APT_PACKAGES=($(printf '%s\n' "${APT_PACKAGES[@]}" 2>/dev/null | sort -u || true))
PIP_PACKAGES=($(printf '%s\n' "${PIP_PACKAGES[@]}" 2>/dev/null | sort -u || true))
NPM_PACKAGES=($(printf '%s\n' "${NPM_PACKAGES[@]}" 2>/dev/null | sort -u || true))
MISSING_COMMANDS=($(printf '%s\n' "${MISSING_COMMANDS[@]}" 2>/dev/null | sort -u || true))
DIAGNOSTICS=($(printf '%s\n' "${DIAGNOSTICS[@]}" 2>/dev/null | sort -u || true))

TOTAL=$(( ${#APT_PACKAGES[@]} + ${#PIP_PACKAGES[@]} + ${#NPM_PACKAGES[@]} ))

array_to_json() {
  if [[ $# -eq 0 ]]; then
    echo "[]"
  else
    printf '%s\n' "$@" | jq -R . | jq -s .
  fi
}

if [[ "$OUTPUT_JSON" == "true" ]]; then
  # JSON output for programmatic use
  apt_json=$(array_to_json "${APT_PACKAGES[@]}")
  pip_json=$(array_to_json "${PIP_PACKAGES[@]}")
  npm_json=$(array_to_json "${NPM_PACKAGES[@]}")
  cmds_json=$(array_to_json "${MISSING_COMMANDS[@]}")
  diagnostics_json=$(array_to_json "${DIAGNOSTICS[@]}")
  jq -n \
    --argjson apt "$apt_json" \
    --argjson pip "$pip_json" \
    --argjson npm "$npm_json" \
    --argjson cmds "$cmds_json" \
    --argjson diagnostics "$diagnostics_json" \
    --argjson total "$TOTAL" \
    '{total_missing: $total, missing_commands: $cmds, apt_packages: $apt, pip_packages: $pip, npm_packages: $npm, diagnostics: $diagnostics}'
else
  # Human-readable output
  if [[ $TOTAL -eq 0 ]] && [[ ${#MISSING_COMMANDS[@]} -eq 0 ]] && [[ ${#DIAGNOSTICS[@]} -eq 0 ]]; then
    echo "No missing dependencies detected in the log."
    exit 0
  fi

  echo "=== Missing Dependencies Detected ==="
  echo ""

  if [[ ${#MISSING_COMMANDS[@]} -gt 0 ]]; then
    echo "Missing commands: ${MISSING_COMMANDS[*]}"
    echo ""
  fi

  if [[ ${#DIAGNOSTICS[@]} -gt 0 ]]; then
    echo "Diagnostics: ${DIAGNOSTICS[*]}"
    echo ""
  fi

  if [[ ${#APT_PACKAGES[@]} -gt 0 ]]; then
    echo "APT packages to install:"
    printf '  - %s\n' "${APT_PACKAGES[@]}"
    echo ""
    echo "Dockerfile snippet:"
    echo "  RUN apt-get update && apt-get install -y \\"
    for pkg in "${APT_PACKAGES[@]}"; do
      echo "      $pkg \\"
    done
    echo "      && apt-get clean && rm -rf /var/lib/apt/lists/*"
    echo ""
  fi

  if [[ ${#PIP_PACKAGES[@]} -gt 0 ]]; then
    echo "Python packages to install:"
    printf '  - %s\n' "${PIP_PACKAGES[@]}"
    echo ""
    echo "Dockerfile snippet:"
    echo "  RUN pip3 install ${PIP_PACKAGES[*]}"
    echo ""
  fi

  if [[ ${#NPM_PACKAGES[@]} -gt 0 ]]; then
    echo "NPM packages to install:"
    printf '  - %s\n' "${NPM_PACKAGES[@]}"
    echo ""
    echo "Dockerfile snippet:"
    echo "  RUN npm install -g ${NPM_PACKAGES[*]}"
    echo ""
  fi
fi

exit 0
