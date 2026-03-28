# cipher-mt5-bridge/docker/Dockerfile
# Multi-stage build for MT5 Bridge container
#
# This container runs:
#   1. Wine + MT5 terminal (headless via Xvfb)
#   2. CipherBridge DLL loaded by the EA
#   3. Launcher script that handles registration + credential delivery
#
# Environment variables (injected by gateway):
#   ACCOUNT_ID    — unique account identifier
#   AUTH_TOKEN     — one-time auth token for registration
#   GATEWAY_URL   — gateway base URL (e.g. https://gateway.rayonix.site)

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV DISPLAY=:99

# Install Wine + dependencies
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        wine64 \
        libwine \
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
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies for launcher
RUN pip3 install --no-cache-dir --break-system-packages requests websocket-client

# Initialize Wine prefix
RUN wineboot --init && \
    # Wait for Wine to finish setup
    sleep 5

# Download MT5 installer
RUN mkdir -p /opt/mt5 && \
    wget -q "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe" \
        -O /opt/mt5/mt5setup.exe

# Install MT5 silently under Wine
RUN xvfb-run wine64 /opt/mt5/mt5setup.exe /auto && \
    # Wait for installation to complete
    sleep 30 && \
    # Kill any remaining Wine processes
    wineserver -k || true

# Find MT5 installation path and data folder
ENV MT5_INSTALL_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5"
ENV MT5_DATA_DIR="/root/.wine/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal"

# Create necessary directories
RUN mkdir -p "${MT5_INSTALL_DIR}" && \
    mkdir -p /opt/bridge

# Copy bridge files
COPY dll/build/Release/CipherBridge.dll /opt/bridge/CipherBridge.dll
COPY mql5/Include/CipherBridge.mqh /opt/bridge/CipherBridge.mqh
COPY mql5/Experts/CipherBridgeEA.mq5 /opt/bridge/CipherBridgeEA.mq5
COPY docker/launcher.py /opt/bridge/launcher.py
COPY docker/entrypoint.sh /opt/bridge/entrypoint.sh

RUN chmod +x /opt/bridge/entrypoint.sh

# Health check
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
    CMD pgrep -f terminal64.exe > /dev/null || exit 1

ENTRYPOINT ["/opt/bridge/entrypoint.sh"]