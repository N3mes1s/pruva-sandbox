# Pre-built Pruva Reproduction Environment
# This image has all tools pre-installed for instant startup

FROM mcr.microsoft.com/devcontainers/base:ubuntu

# Install Python 3.11
RUN apt-get update && apt-get install -y \
    python3.11 \
    python3.11-venv \
    python3-pip \
    && ln -sf /usr/bin/python3.11 /usr/bin/python3 \
    && ln -sf /usr/bin/python3.11 /usr/bin/python \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Node.js LTS
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install common tools for reproductions
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    git \
    jq \
    unzip \
    build-essential \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Pre-install pruva-verify
COPY pruva-verify /usr/local/bin/pruva-verify
RUN chmod +x /usr/local/bin/pruva-verify

# Set up user
USER vscode
