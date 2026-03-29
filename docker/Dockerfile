# cipher-mt5-bridge/docker/Dockerfile
# Wine + MT5 terminal + CipherBridge DLL container
#
# Environment variables (injected by gateway):
#   ACCOUNT_ID    — unique account identifier
#   AUTH_TOKEN     — one-time auth token for registration
#   GATEWAY_URL   — gateway base URL (e.g. https://gateway.cipherbridge.cloud)

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV DISPLAY=:99
ENV PYTHONUNBUFFERED=1

# Install Wine + dependencies
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        wine \
        xvfb \
        x11-utils \
        wget \
        curl \
        ca-certificates \
        cabextract \
        python3 \
        python3-pip \
        unzip \
        xdotool \
        procps \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies for launcher
RUN pip3 install --no-cache-dir requests websocket-client

# Initialize Wine prefix
RUN wineboot --init && \
    sleep 5

# Download MT5 installer
RUN mkdir -p /opt/mt5 && \
    wget -q "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe" \
        -O /opt/mt5/mt5setup.exe

# Install MT5 silently under Wine
# MT5 installer can take a while — give it 5 minutes
# The installer may "fail" from Wine's perspective but still install files
RUN Xvfb :99 -screen 0 1024x768x16 & \
    sleep 2 && \
    timeout 300 wine64 /opt/mt5/mt5setup.exe /auto || true && \
    sleep 15 && \
    wineserver -k || true && \
    # Verify installation
    echo "=== Checking MT5 installation ===" && \
    find /root/.wine -name "terminal64.exe" -type f 2>/dev/null && \
    echo "=== MT5 check complete ==="

# Find MT5 installation path
ENV MT5_INSTALL_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5"

# Create bridge directory
RUN mkdir -p /opt/bridge

# Copy bridge files
COPY dll/build/Release/CipherBridge.dll /opt/bridge/CipherBridge.dll
COPY mql5/Include/CipherBridge.mqh /opt/bridge/CipherBridge.mqh
COPY mql5/Experts/CipherBridgeEA.mq5 /opt/bridge/CipherBridgeEA.mq5
COPY docker/launcher.py /opt/bridge/launcher.py
COPY docker/entrypoint.sh /opt/bridge/entrypoint.sh

RUN chmod +x /opt/bridge/entrypoint.sh

# Health check — look for terminal64.exe process, not a TCP port
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
    CMD pgrep -f terminal64.exe > /dev/null || exit 1

ENTRYPOINT ["/opt/bridge/entrypoint.sh"]