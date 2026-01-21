# Pre-built Pruva Reproduction Environment
# This image has all tools pre-installed for instant startup

FROM mcr.microsoft.com/devcontainers/base:ubuntu

# Install common build dependencies for reproductions
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
    cmake \
    pkg-config \
    libssl-dev \
    zlib1g-dev \
    libprotobuf-dev \
    protobuf-compiler \
    libgflags-dev \
    libgoogle-glog-dev \
    libleveldb-dev \
    liblz4-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python3 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip

# Install Node.js LTS
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Pre-install pruva-verify
COPY pruva-verify /usr/local/bin/pruva-verify
RUN chmod +x /usr/local/bin/pruva-verify

# Set up user
USER vscode
