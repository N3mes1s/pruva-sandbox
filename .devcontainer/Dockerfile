# Pre-built Pruva Reproduction Environment
# This image has all tools pre-installed for instant startup

FROM mcr.microsoft.com/devcontainers/base:ubuntu

# Build arguments for version tracking
ARG BUILD_DATE=unknown
ARG GIT_SHA=unknown

LABEL io.pruva.sandbox.version="${BUILD_DATE}"
LABEL io.pruva.sandbox.revision="${GIT_SHA}"

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
    ripgrep \
    docker.io \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python3 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip \
    && rm -f /usr/lib/python*/EXTERNALLY-MANAGED

# Install Node.js LTS
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install patch tool (for auto-applying reproduction script fixes)
RUN apt-get update && apt-get install -y patch && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install pruva-verify (always fetch latest from GitHub main branch)
RUN curl -fsSL https://raw.githubusercontent.com/N3mes1s/pruva-sandbox/main/pruva-verify \
    -o /usr/local/bin/pruva-verify && chmod +x /usr/local/bin/pruva-verify

# Create environment manifest for version tracking
RUN echo "PRUVA_SANDBOX_VERSION=${BUILD_DATE}" > /etc/pruva-sandbox-version && \
    echo "PRUVA_SANDBOX_SHA=${GIT_SHA}" >> /etc/pruva-sandbox-version && \
    python3 --version 2>&1 | sed 's/^/PRUVA_SANDBOX_PYTHON="/' | sed 's/$/"/' >> /etc/pruva-sandbox-version && \
    node --version 2>&1 | sed 's/^/PRUVA_SANDBOX_NODE="/' | sed 's/$/"/' >> /etc/pruva-sandbox-version && \
    gcc --version 2>&1 | head -1 | sed 's/^/PRUVA_SANDBOX_GCC="/' | sed 's/$/"/' >> /etc/pruva-sandbox-version

# Set up user
USER vscode
