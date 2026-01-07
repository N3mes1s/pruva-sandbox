# Pre-built Pruva Reproduction Environment
# This image has all tools pre-installed for instant startup

FROM mcr.microsoft.com/devcontainers/base:ubuntu

# Install Python (default version) and Node.js
RUN apt-get update && apt-get install -y \
    python3 \
    python3-venv \
    python3-pip \
    curl \
    wget \
    git \
    jq \
    unzip \
    build-essential \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Node.js LTS
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Pre-install pruva-verify
COPY pruva-verify /usr/local/bin/pruva-verify
RUN chmod +x /usr/local/bin/pruva-verify

# Set up user
USER vscode
