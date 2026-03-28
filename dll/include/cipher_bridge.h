// cipher-mt5-bridge/dll/include/cipher_bridge.h
// v3.0 — Supports both Docker (env vars) and manual (EA input) modes

#pragma once

#ifdef CIPHERBRIDGE_EXPORTS
#define BRIDGE_API __declspec(dllexport)
#else
#define BRIDGE_API __declspec(dllimport)
#endif

#define BRIDGE_CALL __stdcall

// Command type enum
enum BridgeCommandType {
    CMD_NONE             = 0,
    CMD_PING             = 1,
    CMD_STATUS           = 2,
    CMD_CONNECT          = 3,
    CMD_DISCONNECT       = 4,
    CMD_SUBSCRIBE        = 5,
    CMD_UNSUBSCRIBE      = 6,
    CMD_GET_ACCOUNT_INFO = 7,
    CMD_GET_SYMBOL_INFO  = 8,
    CMD_GET_HISTORY      = 9,
    CMD_PLACE_ORDER      = 10,
    CMD_CLOSE_ORDER      = 11,
    CMD_MODIFY_ORDER     = 12,
    CMD_GET_POSITIONS    = 13,
    CMD_GET_ORDERS       = 14,
    // New: credential delivery from gateway
    CMD_CREDENTIALS      = 15,
};

// === Lifecycle ===

// Initialize bridge in MANUAL mode (EA provides URL and account_id)
BRIDGE_API int BRIDGE_CALL BridgeInit(
    const wchar_t* gateway_ws_url,   // Full WS URL (e.g. wss://gw:443/bridge/ws?token=xxx)
    const wchar_t* account_id         // Account UUID
);

// Initialize bridge in DOCKER mode (reads from config files written by launcher.py)
// Reads: /tmp/bridge_ws_url.txt, /tmp/bridge_account_id.txt
// Returns 1 on success, 0 on failure.
BRIDGE_API int BRIDGE_CALL BridgeInitFromEnv();

// Poll for the next pending command.
// Returns CMD_NONE if no command pending.
// CMD_CREDENTIALS means paramsJson contains {"mt5_login":"...","mt5_password":"...","mt5_server":"..."}
BRIDGE_API int BRIDGE_CALL BridgePollCommand(
    wchar_t* requestId,    // pre-allocated, min 128 wchars
    wchar_t* paramsJson    // pre-allocated, min 8192 wchars
);

// Shut down the bridge
BRIDGE_API void BRIDGE_CALL BridgeShutdown();

// === Connection ===

BRIDGE_API int BRIDGE_CALL BridgeIsClientConnected();

// === Market Data (EA → Gateway) ===

BRIDGE_API void BRIDGE_CALL BridgePushTick(
    const wchar_t* symbol,
    double bid, double ask, double last,
    long long volume, long long timeMs
);

BRIDGE_API void BRIDGE_CALL BridgePushCandle(
    const wchar_t* symbol,
    const wchar_t* timeframe,
    long long timeMs,
    double open, double high, double low, double close,
    long long volume, int complete
);

// === Responses (EA → Gateway) ===

BRIDGE_API void BRIDGE_CALL BridgePushResponse(const wchar_t* responseJson);

// === Subscriptions ===

BRIDGE_API int BRIDGE_CALL BridgeGetSubscribedSymbolCount();
BRIDGE_API int BRIDGE_CALL BridgeGetSubscribedSymbol(int index, wchar_t* symbolOut);

// === Logging ===

BRIDGE_API int BRIDGE_CALL BridgeGetLogMessage(wchar_t* messageOut);