#!/bin/bash
# cipher-mt5-bridge/docker/entrypoint.sh
# Container entrypoint — orchestrates bridge startup
#
# Sequence:
#   1. Validate environment variables
#   2. Start virtual display (Xvfb)
#   3. Run launcher.py (HTTP register → WS credentials → write MT5 config)
#   4. Deploy bridge files to MT5 data folder
#   5. Start MT5 terminal
#   6. Monitor MT5 process, restart if it crashes

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
# Step 4: Deploy bridge files to MT5
# ============================================================================

echo "→ Deploying bridge files..."

# Find the MT5 data directory (hash-named folder)
MT5_DATA_ROOT="$HOME/.wine/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal"
MT5_DATA=$(find "$MT5_DATA_ROOT" -maxdepth 1 -type d -name "[A-F0-9]*" | head -1)

if [ -z "$MT5_DATA" ]; then
    echo "⚠️  MT5 data folder not found, using install dir"
    # Create a default data structure
    MT5_DATA="$MT5_DATA_ROOT/default"
    mkdir -p "$MT5_DATA/MQL5/Libraries"
    mkdir -p "$MT5_DATA/MQL5/Include"
    mkdir -p "$MT5_DATA/MQL5/Experts"
fi

# Copy files
cp /opt/bridge/CipherBridge.dll "$MT5_DATA/MQL5/Libraries/"
cp /opt/bridge/CipherBridge.mqh "$MT5_DATA/MQL5/Include/"
cp /opt/bridge/CipherBridgeEA.mq5 "$MT5_DATA/MQL5/Experts/"

echo "✅ Bridge files deployed to $MT5_DATA"

# ============================================================================
# Step 5: Write WS URL for the DLL to read
# ============================================================================

# The DLL will read this file on BridgeInit instead of using EA input params
echo "$WS_URL" > /tmp/bridge_ws_url.txt
echo "$ACCOUNT_ID" > /tmp/bridge_account_id.txt
echo "$AUTH_TOKEN" > /tmp/bridge_auth_token.txt
echo "$GATEWAY_URL" > /tmp/bridge_gateway_url.txt

echo "✅ Bridge config written"

# ============================================================================
# Step 6: Start MT5
# ============================================================================

echo "→ Starting MetaTrader 5..."

MT5_EXE="$HOME/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe"

if [ ! -f "$MT5_EXE" ]; then
    # Try alternative path
    MT5_EXE=$(find "$HOME/.wine" -name "terminal64.exe" -type f | head -1)
fi

if [ -z "$MT5_EXE" ]; then
    echo "❌ MT5 terminal64.exe not found"
    exit 1
fi

# Start MT5 with login credentials
wine64 "$MT5_EXE" \
    /login:$MT5_LOGIN \
    /password:$MT5_PASSWORD \
    /server:$MT5_SERVER \
    /portable &

MT5_PID=$!
echo "✅ MT5 started (PID: $MT5_PID)"
echo "   Login:  $MT5_LOGIN"
echo "   Server: $MT5_SERVER"

# Wait for MT5 to initialize
sleep 10

# ============================================================================
# Step 7: Monitor MT5 process
# ============================================================================

echo ""
echo "╔═══════════════════════════════════════════╗"
echo "║   Bridge Running                          ║"
echo "╚═══════════════════════════════════════════╝"
echo ""

RESTART_COUNT=0
MAX_RESTARTS=10

while true; do
    # Check if MT5 is still running
    if ! kill -0 $MT5_PID 2>/dev/null; then
        RESTART_COUNT=$((RESTART_COUNT + 1))
        
        if [ $RESTART_COUNT -ge $MAX_RESTARTS ]; then
            echo "❌ MT5 crashed $MAX_RESTARTS times — giving up"
            exit 1
        fi
        
        echo "⚠️  MT5 crashed (restart $RESTART_COUNT/$MAX_RESTARTS), restarting..."
        sleep 5
        
        wine64 "$MT5_EXE" \
            /login:$MT5_LOGIN \
            /password:$MT5_PASSWORD \
            /server:$MT5_SERVER \
            /portable &
        MT5_PID=$!
        
        echo "✅ MT5 restarted (PID: $MT5_PID)"
    fi
    
    # Check Xvfb
    if ! kill -0 $XVFB_PID 2>/dev/null; then
        echo "⚠️  Xvfb died, restarting..."
        Xvfb :99 -screen 0 1024x768x16 &
        XVFB_PID=$!
    fi
    
    sleep 10
done