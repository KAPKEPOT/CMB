// cipher-mt5-bridge/dll/include/cipher_bridge.h
// Public API for the CipherBridge DLL
// This DLL is loaded by the MQL5 Expert Advisor and provides
// TCP connectivity to the Rust CMG gateway.

#pragma once

#ifdef CIPHERBRIDGE_EXPORTS
#define BRIDGE_API __declspec(dllexport)
#else
#define BRIDGE_API __declspec(dllimport)
#endif

// MQL5 uses __stdcall for DLL imports
#define BRIDGE_CALL __stdcall

#ifdef __cplusplus
extern "C" {
#endif

// Command type enum — returned by BridgePollCommand
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
};

// Lifecycle

// Initialize the bridge and start TCP listener on the given port.
// Returns 1 on success, 0 on failure.
BRIDGE_API int BRIDGE_CALL BridgeInit(int port);

// Shut down the bridge, close all connections, stop TCP listener.
BRIDGE_API void BRIDGE_CALL BridgeShutdown();

// Connection status

// Returns 1 if the Rust gateway is currently connected, 0 otherwise.
BRIDGE_API int BRIDGE_CALL BridgeIsClientConnected();

// Push market data TO the gateway (called from EA's OnTick / OnTimer)

// Push a tick update. symbol is a wide string (MQL5 native).
BRIDGE_API void BRIDGE_CALL BridgePushTick(
    const wchar_t* symbol,
    double bid, double ask, double last,
    long long volume, long long timeMs
);

// Push a candle update.
BRIDGE_API void BRIDGE_CALL BridgePushCandle(
    const wchar_t* symbol,
    const wchar_t* timeframe,
    long long timeMs,
    double open, double high, double low, double close,
    long long volume, int complete
);

// Command polling (called from EA's OnTimer)

// Poll for the next pending command from the gateway.
// Returns the command type (BridgeCommandType enum).
// Fills requestId (pre-allocated by MQL5, min 128 wchars).
// Fills paramsJson with the JSON "data" payload (min 8192 wchars).
// Returns CMD_NONE (0) if no command is pending.
BRIDGE_API int BRIDGE_CALL BridgePollCommand(
    wchar_t* requestId,
    wchar_t* paramsJson
);

// Push responses BACK to the gateway (called after EA processes a command)

// Push a fully-formed JSON response string to the gateway.
// The string must be a complete JSON object matching BridgeResponse format.
BRIDGE_API void BRIDGE_CALL BridgePushResponse(const wchar_t* responseJson);

// Subscription tracking

// Returns the number of symbols currently subscribed by the gateway.
BRIDGE_API int BRIDGE_CALL BridgeGetSubscribedSymbolCount();

// Get the symbol at the given index. Fills symbolOut (min 64 wchars).
// Returns 1 on success, 0 if index out of range.
BRIDGE_API int BRIDGE_CALL BridgeGetSubscribedSymbol(
    int index, wchar_t* symbolOut
);

// Logging (bridge → EA log)

// Get the next log message from the bridge (for EA to Print()).
// Returns 1 if a message was available, 0 if empty.
BRIDGE_API int BRIDGE_CALL BridgeGetLogMessage(wchar_t* messageOut);

#ifdef __cplusplus
}
#endif
