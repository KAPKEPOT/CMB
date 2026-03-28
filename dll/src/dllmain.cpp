// cipher-mt5-bridge/dll/src/dllmain.cpp
// WebSocket client bridge for CMG Gateway
//
// Supports two modes:
//   MANUAL: EA calls BridgeInit(url, account_id) with direct WS URL
//   DOCKER: EA calls BridgeInitFromEnv() — reads config from launcher.py output files
//
// Architecture:
//   - WebSocket thread receives commands and queues them
//   - MT5 main thread polls for commands via BridgePollCommand()
//   - CMD_CREDENTIALS delivers MT5 login info from gateway
//   - All trading operations execute on MT5's main thread

#define CIPHERBRIDGE_EXPORTS

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>
#include <string>
#include <memory>
#include <atomic>
#include <thread>
#include <codecvt>
#include <locale>
#include <fstream>

#include "cipher_bridge.h"
#include "types_internal.h"
#include "websocket_client.h"
#include "protocol.h"

using namespace cipher;

// Globals
static std::unique_ptr<WebSocketClient> g_ws_client;
static ThreadSafeQueue<std::string> g_response_queue;
static SubscriptionTracker g_subscriptions;
static LogQueue g_log;
static std::atomic<bool> g_initialized{false};
static std::string g_account_id;
static std::string g_gateway_url;
static std::string g_auth_token;

// Thread-safe command queue — WebSocket thread pushes, MT5 main thread pops
static ThreadSafeQueue<ParsedCommand> g_command_queue;

// Response sender thread
static std::thread g_sender_thread;
static std::atomic<bool> g_sender_running{false};

// UTF-16 ↔ UTF-8 conversion helpers
static std::string wstr_to_utf8(const wchar_t* wstr) {
    if (!wstr || !wstr[0]) return "";
    int size_needed = WideCharToMultiByte(CP_UTF8, 0, wstr, -1, nullptr, 0, nullptr, nullptr);
    if (size_needed <= 0) return "";
    std::string result(size_needed - 1, '\0');
    WideCharToMultiByte(CP_UTF8, 0, wstr, -1, &result[0], size_needed, nullptr, nullptr);
    return result;
}

static bool utf8_to_wstr(const std::string& utf8, wchar_t* out, int out_size) {
    if (out_size <= 0) return false;
    if (utf8.empty()) {
        out[0] = L'\0';
        return true;
    }
    int required = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, nullptr, 0);
    if (required <= 0) {
        out[0] = L'\0';
        return false;
    }
    if (required > out_size) {
        MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, out, out_size);
        out[out_size - 1] = L'\0';
        return false;
    }
    MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, out, out_size);
    return true;
}

// Read a single line from a file (used in Docker mode)
static std::string read_file_line(const std::string& path) {
    std::ifstream file(path);
    if (!file.is_open()) return "";
    std::string line;
    std::getline(file, line);
    // Trim whitespace
    while (!line.empty() && (line.back() == '\n' || line.back() == '\r' || line.back() == ' '))
        line.pop_back();
    return line;
}

// Response sender thread (sends queued responses over WebSocket)
static void sender_thread_func() {
    while (g_sender_running) {
        auto response = g_response_queue.wait_pop_for(std::chrono::milliseconds(50));
        if (response.has_value() && g_ws_client && g_ws_client->is_connected()) {
            g_ws_client->send_response(response.value());
        }
    }
    // Drain remaining
    while (auto response = g_response_queue.try_pop()) {
        if (g_ws_client) g_ws_client->send_response(response.value());
    }
}

// Command handler — called from WebSocket thread.
// Queues commands for the MT5 main thread. Also handles credentials.
static void on_command_received(const GatewayMessage& msg) {
    if (msg.type != MessageType::COMMAND) return;

    // Check for credentials delivery (special case)
    if (msg.command_type == "credentials") {
        ParsedCommand cmd;
        cmd.type = CMD_CREDENTIALS;
        cmd.request_id = msg.request_id;
        cmd.params_json = msg.params_json;  // {"mt5_login":"...", "mt5_password":"...", "mt5_server":"..."}
        g_command_queue.push(std::move(cmd));
        g_log.log("Credentials received from gateway");
        return;
    }

    static const struct { const char* name; int type; } cmd_map[] = {
        {"Ping",            CMD_PING},
        {"Status",          CMD_STATUS},
        {"Connect",         CMD_CONNECT},
        {"Disconnect",      CMD_DISCONNECT},
        {"Subscribe",       CMD_SUBSCRIBE},
        {"Unsubscribe",     CMD_UNSUBSCRIBE},
        {"GetAccountInfo",  CMD_GET_ACCOUNT_INFO},
        {"GetSymbolInfo",   CMD_GET_SYMBOL_INFO},
        {"GetHistory",      CMD_GET_HISTORY},
        {"PlaceOrder",      CMD_PLACE_ORDER},
        {"CloseOrder",      CMD_CLOSE_ORDER},
        {"ModifyOrder",     CMD_MODIFY_ORDER},
        {"GetPositions",    CMD_GET_POSITIONS},
        {"GetOrders",       CMD_GET_ORDERS},
    };

    int cmd_type = CMD_NONE;
    for (const auto& entry : cmd_map) {
        if (msg.command_type == entry.name) { cmd_type = entry.type; break; }
    }

    if (cmd_type == CMD_NONE) {
        g_log.log("Unknown command type: " + msg.command_type);
        return;
    }

    ParsedCommand cmd;
    cmd.type        = cmd_type;
    cmd.request_id  = msg.request_id;
    cmd.params_json = msg.params_json;
    g_command_queue.push(std::move(cmd));
}

// WebSocket event handlers
static void on_connected() {
    g_log.log("Connected to CMG Gateway");
}

static void on_disconnected() {
    g_log.log("Disconnected from CMG Gateway");
    g_response_queue.clear();
}

static void on_error(const std::string& error) {
    g_log.log("WebSocket error: " + error);
}

// Internal init logic (shared between manual and Docker modes)
static int bridge_init_internal(const std::string& ws_url, const std::string& account_id) {
    if (g_initialized) {
        BridgeShutdown();
    }
    
    g_account_id = account_id;
    
    g_log.log("Initializing CipherBridge, connecting to: " + ws_url);
    g_log.log("Account ID: " + g_account_id);
    
    // Clear queues
    g_command_queue.clear();
    g_response_queue.clear();
    g_subscriptions.clear();
    
    // Create WebSocket client
    g_ws_client = std::make_unique<WebSocketClient>();
    
    // Set up event-driven callbacks
    g_ws_client->set_on_command(on_command_received);
    g_ws_client->set_on_connected(on_connected);
    g_ws_client->set_on_disconnected(on_disconnected);
    g_ws_client->set_on_error(on_error);
    
    // Connect (outbound)
    if (!g_ws_client->connect(ws_url, g_account_id)) {
        g_log.log("Failed to connect to gateway");
        g_ws_client.reset();
        return 0;
    }
    
    // Start response sender thread
    g_sender_running = true;
    g_sender_thread = std::thread(sender_thread_func);
    
    g_initialized = true;
    g_log.log("CipherBridge initialized successfully");
    return 1;
}

// ============================================================================
// Exported functions
// ============================================================================

int BRIDGE_CALL BridgeInit(const wchar_t* gateway_ws_url, const wchar_t* account_id) {
    std::string url = wstr_to_utf8(gateway_ws_url);
    std::string aid = wstr_to_utf8(account_id);
    return bridge_init_internal(url, aid);
}

int BRIDGE_CALL BridgeInitFromEnv() {
    g_log.log("Initializing from environment/config files...");
    
    // Try config files first (written by launcher.py in Docker)
    std::string ws_url = read_file_line("/tmp/bridge_ws_url.txt");
    std::string account_id = read_file_line("/tmp/bridge_account_id.txt");
    
    // Fall back to environment variables (Windows or direct Docker)
    if (ws_url.empty()) {
        char* env_val = std::getenv("BRIDGE_WS_URL");
        if (env_val) ws_url = env_val;
    }
    if (account_id.empty()) {
        char* env_val = std::getenv("ACCOUNT_ID");
        if (env_val) account_id = env_val;
    }
    
    // Store gateway URL and auth token for reconnection
    std::string gw_url = read_file_line("/tmp/bridge_gateway_url.txt");
    if (gw_url.empty()) {
        char* env_val = std::getenv("GATEWAY_URL");
        if (env_val) gw_url = env_val;
    }
    g_gateway_url = gw_url;
    
    std::string auth_token = read_file_line("/tmp/bridge_auth_token.txt");
    if (auth_token.empty()) {
        char* env_val = std::getenv("AUTH_TOKEN");
        if (env_val) auth_token = env_val;
    }
    g_auth_token = auth_token;
    
    if (ws_url.empty() || account_id.empty()) {
        g_log.log("ERROR: Cannot read WS URL or account ID from files/env");
        return 0;
    }
    
    g_log.log("Config loaded from files/env");
    return bridge_init_internal(ws_url, account_id);
}

int BRIDGE_CALL BridgePollCommand(wchar_t* requestId, wchar_t* paramsJson) {
    auto cmd = g_command_queue.try_pop();
    if (!cmd.has_value()) return CMD_NONE;

    bool id_ok     = utf8_to_wstr(cmd->request_id,  requestId,  128);
    bool params_ok = utf8_to_wstr(cmd->params_json, paramsJson, 8192);

    if (!id_ok || !params_ok) {
        g_log.log("BridgePollCommand: payload truncated — sending error");
        std::string err = "{\"type\":\"Error\",\"data\":{\"code\":-2,"
                          "\"message\":\"Command payload too large\","
                          "\"request_id\":\"" + cmd->request_id + "\"}}";
        g_response_queue.push(std::move(err));
        return CMD_NONE;
    }

    return cmd->type;
}

void BRIDGE_CALL BridgeShutdown() {
    if (!g_initialized) return;
    
    g_log.log("Shutting down CipherBridge");
    
    g_sender_running = false;
    if (g_sender_thread.joinable()) g_sender_thread.join();
    
    if (g_ws_client) {
        g_ws_client->disconnect();
        g_ws_client.reset();
    }
    
    g_command_queue.clear();
    g_response_queue.clear();
    g_subscriptions.clear();
    
    g_initialized = false;
    g_log.log("CipherBridge shutdown complete");
}

int BRIDGE_CALL BridgeIsClientConnected() {
    if (!g_ws_client) return 0;
    return g_ws_client->is_connected() ? 1 : 0;
}

void BRIDGE_CALL BridgePushTick(
    const wchar_t* symbol,
    double bid, double ask, double last,
    long long volume, long long timeMs
) {
    if (!g_initialized || !g_ws_client || !g_ws_client->is_connected()) return;
    std::string sym = wstr_to_utf8(symbol);
    if (!g_subscriptions.contains(sym)) return;
    std::string json = build_tick(sym, bid, ask, last, volume, timeMs);
    g_response_queue.push(std::move(json));
}

void BRIDGE_CALL BridgePushCandle(
    const wchar_t* symbol,
    const wchar_t* timeframe,
    long long timeMs,
    double open, double high, double low, double close,
    long long volume, int complete
) {
    if (!g_initialized || !g_ws_client || !g_ws_client->is_connected()) return;
    std::string sym = wstr_to_utf8(symbol);
    std::string tf = wstr_to_utf8(timeframe);
    if (!g_subscriptions.contains(sym)) return;
    std::string json = build_candle(sym, tf, timeMs, open, high, low, close, volume, complete != 0);
    g_response_queue.push(std::move(json));
}

void BRIDGE_CALL BridgePushResponse(const wchar_t* responseJson) {
    if (!g_initialized) return;
    std::string json = wstr_to_utf8(responseJson);
    if (!json.empty()) {
        g_response_queue.push(std::move(json));
    }
}

int BRIDGE_CALL BridgeGetSubscribedSymbolCount() {
    return g_subscriptions.count();
}

int BRIDGE_CALL BridgeGetSubscribedSymbol(int index, wchar_t* symbolOut) {
    std::string sym = g_subscriptions.get(index);
    if (sym.empty()) {
        if (symbolOut) symbolOut[0] = L'\0';
        return 0;
    }
    utf8_to_wstr(sym, symbolOut, 64);
    return 1;
}

int BRIDGE_CALL BridgeGetLogMessage(wchar_t* messageOut) {
    auto msg = g_log.poll();
    if (!msg.has_value()) {
        if (messageOut) messageOut[0] = L'\0';
        return 0;
    }
    utf8_to_wstr(msg.value(), messageOut, 512);
    return 1;
}
