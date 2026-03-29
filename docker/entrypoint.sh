#!/bin/bash
# cipher-mt5-bridge/docker/entrypoint.sh
# Container entrypoint — orchestrates bridge startup
#
# Sequence:
#   1. Validate environment variables
#   2. Start virtual display (Xvfb)
#   3. Run launcher.py (HTTP register → WS credentials → write MT5 config)
#   4. Deploy bridge files to MT5 directories
#   5. Start MT5 terminal
#   6. Monitor via Wine process list (not PID — wine64 wrapper exits immediately)

set -e

echo "╔═══════════════════════════════════════════╗"
echo "║   CipherBridge Container v2.0             ║"
echo "╚═══════════════════════════════════════════╝"
echo ""

# ============================================================================
# Step 1: Validate environment
# ============================================================================

if [ -z "$ACCOUNT_ID" ]; then
    echo "❌ ACCOUNT_ID not set"
    exit 1
fi

if [ -z "$AUTH_TOKEN" ]; then
    echo "❌ AUTH_TOKEN not set"
    exit 1
fi

if [ -z "$GATEWAY_URL" ]; then
    echo "❌ GATEWAY_URL not set"
    exit 1
fi

echo "✅ Environment validated"
echo "   Account:  ${ACCOUNT_ID:0:8}..."
echo "   Gateway:  $GATEWAY_URL"

# ============================================================================
# Step 2: Start virtual display
# ============================================================================

echo "→ Starting Xvfb..."
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
Xvfb :99 -screen 0 1024x768x16 &
XVFB_PID=$!
sleep 2

if ! kill -0 $XVFB_PID 2>/dev/null; then
    echo "❌ Xvfb failed to start"
    exit 1
fi
echo "✅ Xvfb running on :99"

# ============================================================================
# Step 3: Run launcher (registration + credential retrieval)
# ============================================================================

echo "→ Running bridge launcher..."
CREDS_FILE="/tmp/mt5_credentials.json"

python3 /opt/bridge/launcher.py \
    --account-id "$ACCOUNT_ID" \
    --auth-token "$AUTH_TOKEN" \
    --gateway-url "$GATEWAY_URL" \
    --output "$CREDS_FILE"

if [ $? -ne 0 ]; then
    echo "❌ Launcher failed — cannot retrieve credentials"
    exit 1
fi

if [ ! -f "$CREDS_FILE" ]; then
    echo "❌ Credentials file not created"
    exit 1
fi

# Read credentials
MT5_LOGIN=$(python3 -c "import json; d=json.load(open('$CREDS_FILE')); print(d['mt5_login'])")
MT5_PASSWORD=$(python3 -c "import json; d=json.load(open('$CREDS_FILE')); print(d['mt5_password'])")
MT5_SERVER=$(python3 -c "import json; d=json.load(open('$CREDS_FILE')); print(d['mt5_server'])")
WS_URL=$(python3 -c "import json; d=json.load(open('$CREDS_FILE')); print(d.get('ws_url', ''))")

echo "✅ Credentials received: login=$MT5_LOGIN, server=$MT5_SERVER"

# Clean up credentials file (sensitive)
rm -f "$CREDS_FILE"

# ============================================================================
# Step 4: Find MT5 and deploy bridge files
# ============================================================================

echo "→ Deploying bridge files..."

# Find MT5 executable
MT5_EXE=$(find "$HOME/.wine" -name "terminal64.exe" -type f 2>/dev/null | head -1)

if [ -z "$MT5_EXE" ]; then
    echo "❌ MT5 terminal64.exe not found — installation may have failed"
    echo "   Searching for any MT5 files..."
    find "$HOME/.wine" -name "*.exe" -path "*MetaTrader*" 2>/dev/null || echo "   No MetaTrader files found"
    exit 1
fi

MT5_INSTALL_DIR=$(dirname "$MT5_EXE")
echo "   MT5 found at: $MT5_INSTALL_DIR"

# With /portable flag, MT5 uses its install directory for data
# Deploy files directly next to the terminal
MT5_MQL_DIR="$MT5_INSTALL_DIR/MQL5"
mkdir -p "$MT5_MQL_DIR/Libraries"
mkdir -p "$MT5_MQL_DIR/Include"
mkdir -p "$MT5_MQL_DIR/Experts"

# Also check the AppData roaming directory (non-portable mode)
MT5_DATA_ROOT="$HOME/.wine/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal"
MT5_DATA=$(find "$MT5_DATA_ROOT" -maxdepth 1 -type d -name "[A-Fa-f0-9]*" 2>/dev/null | head -1)

if [ -n "$MT5_DATA" ]; then
    echo "   AppData folder found: $MT5_DATA"
    mkdir -p "$MT5_DATA/MQL5/Libraries"
    mkdir -p "$MT5_DATA/MQL5/Include"
    mkdir -p "$MT5_DATA/MQL5/Experts"
    # Deploy to both locations
    cp /opt/bridge/CipherBridge.dll "$MT5_DATA/MQL5/Libraries/"
    cp /opt/bridge/CipherBridge.mqh "$MT5_DATA/MQL5/Include/"
    cp /opt/bridge/CipherBridgeEA.mq5 "$MT5_DATA/MQL5/Experts/"
    echo "   ✅ Files deployed to AppData"
fi

# Always deploy to install directory (portable mode)
cp /opt/bridge/CipherBridge.dll "$MT5_MQL_DIR/Libraries/"
cp /opt/bridge/CipherBridge.mqh "$MT5_MQL_DIR/Include/"
cp /opt/bridge/CipherBridgeEA.mq5 "$MT5_MQL_DIR/Experts/"
echo "✅ Bridge files deployed to $MT5_MQL_DIR"

# ============================================================================
# Step 5: Write WS URL for the DLL to read
# ============================================================================

echo "$WS_URL" > /tmp/bridge_ws_url.txt
echo "$ACCOUNT_ID" > /tmp/bridge_account_id.txt
echo "$AUTH_TOKEN" > /tmp/bridge_auth_token.txt
echo "$GATEWAY_URL" > /tmp/bridge_gateway_url.txt

echo "✅ Bridge config written"

# ============================================================================
# Step 6: Start MT5
# ============================================================================

echo "→ Starting MetaTrader 5..."

# Start MT5 — wine64 is just a wrapper, the actual process runs inside Wine
wine64 "$MT5_EXE" \
    /login:$MT5_LOGIN \
    /password:$MT5_PASSWORD \
    /server:$MT5_SERVER \
    /portable &

echo "✅ MT5 launch command issued"
echo "   Login:  $MT5_LOGIN"
echo "   Server: $MT5_SERVER"

# Wait for MT5 to initialize
sleep 15

# ============================================================================
# Step 7: Monitor via Wine process list
# ============================================================================

# wine64 wrapper exits immediately — we can't track by PID.
# Instead, check if terminal64.exe appears in Wine's process list.

is_mt5_running() {
    # Check if any terminal64.exe process is running under Wine
    pgrep -f "terminal64.exe" > /dev/null 2>&1
}

echo ""
echo "╔═══════════════════════════════════════════╗"
echo "║   Bridge Running                          ║"
echo "╚═══════════════════════════════════════════╝"
echo ""

RESTART_COUNT=0
MAX_RESTARTS=10
CONSECUTIVE_FAILURES=0

while true; do
    if ! is_mt5_running; then
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))

        # Give Wine a grace period — it may still be starting
        if [ $CONSECUTIVE_FAILURES -le 3 ]; then
            echo "⏳ MT5 not detected yet (check $CONSECUTIVE_FAILURES/3)..."
            sleep 10
            continue
        fi

        RESTART_COUNT=$((RESTART_COUNT + 1))
        CONSECUTIVE_FAILURES=0

        if [ $RESTART_COUNT -ge $MAX_RESTARTS ]; then
            echo "❌ MT5 failed $MAX_RESTARTS times — giving up"
            echo "   Last Wine processes:"
            ps aux | grep -i wine 2>/dev/null || true
            exit 1
        fi

        echo "⚠️  MT5 not running (restart $RESTART_COUNT/$MAX_RESTARTS)"
        sleep 5

        wine64 "$MT5_EXE" \
            /login:$MT5_LOGIN \
            /password:$MT5_PASSWORD \
            /server:$MT5_SERVER \
            /portable &

        echo "✅ MT5 restart issued"
        sleep 15
    else
        # MT5 is running — reset failure counter
        CONSECUTIVE_FAILURES=0
    fi

    # Check Xvfb
    if ! kill -0 $XVFB_PID 2>/dev/null; then
        echo "⚠️  Xvfb died, restarting..."
        rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
        Xvfb :99 -screen 0 1024x768x16 &
        XVFB_PID=$!
    fi

    sleep 10
done
