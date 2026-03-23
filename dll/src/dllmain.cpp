// cipher-mt5-bridge/dll/src/dllmain.cpp
// DLL entry point and exported function implementations
// This is the glue between the MQL5 EA and the TCP connection to CMG.

#define CIPHERBRIDGE_EXPORTS

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>
#include <string>
#include <memory>
#include <codecvt>
#include <locale>

#include "cipher_bridge.h"
#include "types_internal.h"
#include "tcp_server.h"
#include "protocol.h"

// Globals

static std::unique_ptr<cipher::TcpServer>           g_server;
static cipher::ThreadSafeQueue<cipher::ParsedCommand> g_command_queue;
static cipher::ThreadSafeQueue<std::string>          g_response_queue;
static cipher::SubscriptionTracker                   g_subscriptions;
static cipher::LogQueue                              g_log;
static std::atomic<bool>                             g_initialized{false};

// Background thread that drains the response queue and sends over TCP
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

// Returns true if the string fit within out_size, false if it was truncated.
static bool utf8_to_wstr(const std::string& utf8, wchar_t* out, int out_size) {
    if (out_size <= 0) return false;
    if (utf8.empty()) {
        out[0] = L'\0';
        return true;
    }
    // First pass: calculate required size (includes null terminator)
    int required = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, nullptr, 0);
    if (required <= 0) {
        out[0] = L'\0';
        return false;
    }
    if (required > out_size) {
        // Truncate: fill what fits, always null-terminate
        MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, out, out_size);
        out[out_size - 1] = L'\0';
        return false;  // caller knows truncation happened
    }
    MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, out, out_size);
    return true;
}

// Response sender thread
static void sender_thread_func() {
    while (g_sender_running) {
        auto response = g_response_queue.wait_pop_for(std::chrono::milliseconds(50));
        if (response.has_value() && g_server) {
            if (!g_server->send_line(response.value())) {
                g_log.log("Failed to send response to gateway");
            }
        }
    }
    // Drain remaining responses
    while (true) {
        auto response = g_response_queue.try_pop();
        if (!response.has_value()) break;
        if (g_server) g_server->send_line(response.value());
    }
}

// Incoming line handler (called from TCP reader thread)

static void on_incoming_line(const std::string& line) {
    auto cmd = cipher::parse_command(line);

    if (cmd.type == CMD_NONE) {
        g_log.log("Failed to parse command: " + line.substr(0, 200));
        // Send error back
        std::string err = cipher::build_error(-1, "Invalid command format");
        g_response_queue.push(err);
        return;
    }

    // Handle Subscribe/Unsubscribe at the DLL level to track symbols
    if (cmd.type == CMD_SUBSCRIBE) {
        try {
            auto j = nlohmann::json::parse(cmd.params_json);
            if (j.contains("symbols") && j["symbols"].is_array()) {
                std::vector<std::string> symbols;
                for (auto& s : j["symbols"]) {
                    if (s.is_string()) symbols.push_back(s.get<std::string>());
                }
                g_subscriptions.add(symbols);
            }
        } catch (...) {}
    }
    else if (cmd.type == CMD_UNSUBSCRIBE) {
        try {
            auto j = nlohmann::json::parse(cmd.params_json);
            if (j.contains("symbols") && j["symbols"].is_array()) {
                std::vector<std::string> symbols;
                for (auto& s : j["symbols"]) {
                    if (s.is_string()) symbols.push_back(s.get<std::string>());
                }
                g_subscriptions.remove(symbols);
            }
        } catch (...) {}
    }

    // Queue command for the EA to process
    g_command_queue.push(std::move(cmd));
}

// DLL entry point

BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID lpReserved) {
    switch (reason) {
        case DLL_PROCESS_ATTACH:
            DisableThreadLibraryCalls(hModule);
            break;
        case DLL_PROCESS_DETACH:
            // Clean up if the EA didn't call BridgeShutdown
            if (g_initialized) {
                g_sender_running = false;
                if (g_sender_thread.joinable()) g_sender_thread.join();
                if (g_server) g_server->stop();
                g_server.reset();
                g_initialized = false;
            }
            break;
    }
    return TRUE;
}

// Exported functions

int BRIDGE_CALL BridgeInit(int port) {
    if (g_initialized) {
        g_log.log("Bridge already initialized, shutting down first");
        BridgeShutdown();
    }

    g_log.log("Initializing CipherBridge on port " + std::to_string(port));

    // Clear queues
    g_command_queue.clear();
    g_response_queue.clear();
    g_subscriptions.clear();

    // Create TCP server
    g_server = std::make_unique<cipher::TcpServer>(port, g_log);
    g_server->set_on_line(on_incoming_line);
    g_server->set_on_disconnect([]() {
        // Flush responses queued for the dead connection — sending them to a
        // new client would corrupt its session from the first message.
        g_response_queue.clear();
        g_log.log("Client disconnected — response queue flushed");
    });

    if (!g_server->start()) {
        g_log.log("Failed to start TCP server");
        g_server.reset();
        return 0;
    }

    // Start sender thread
    g_sender_running = true;
    g_sender_thread = std::thread(sender_thread_func);

    g_initialized = true;
    g_log.log("CipherBridge initialized successfully");
    return 1;
}

void BRIDGE_CALL BridgeShutdown() {
    if (!g_initialized) return;

    g_log.log("Shutting down CipherBridge");

    // Stop sender thread
    g_sender_running = false;
    if (g_sender_thread.joinable()) g_sender_thread.join();

    // Stop TCP server
    if (g_server) {
        g_server->stop();
        g_server.reset();
    }

    // Clear state
    g_command_queue.clear();
    g_response_queue.clear();
    g_subscriptions.clear();

    g_initialized = false;
}

int BRIDGE_CALL BridgeIsClientConnected() {
    if (!g_server) return 0;
    return g_server->is_client_connected() ? 1 : 0;
}

void BRIDGE_CALL BridgePushTick(
    const wchar_t* symbol,
    double bid, double ask, double last,
    long long volume, long long timeMs
) {
    if (!g_initialized || !g_server || !g_server->is_client_connected()) return;

    std::string sym = wstr_to_utf8(symbol);

    // Only send if symbol is subscribed
    if (!g_subscriptions.contains(sym)) return;

    std::string json = cipher::build_tick(sym, bid, ask, last, volume, timeMs);
    g_response_queue.push(std::move(json));
}

void BRIDGE_CALL BridgePushCandle(
    const wchar_t* symbol,
    const wchar_t* timeframe,
    long long timeMs,
    double open, double high, double low, double close,
    long long volume, int complete
) {
    if (!g_initialized || !g_server || !g_server->is_client_connected()) return;

    std::string sym = wstr_to_utf8(symbol);
    std::string tf  = wstr_to_utf8(timeframe);

    if (!g_subscriptions.contains(sym)) return;

    std::string json = cipher::build_candle(sym, tf, timeMs, open, high, low, close, volume, complete != 0);
    g_response_queue.push(std::move(json));
}

int BRIDGE_CALL BridgePollCommand(wchar_t* requestId, wchar_t* paramsJson) {
    auto cmd = g_command_queue.try_pop();
    if (!cmd.has_value()) {
        return CMD_NONE;
    }

    bool id_ok     = utf8_to_wstr(cmd->request_id,  requestId,  128);
    bool params_ok = utf8_to_wstr(cmd->params_json, paramsJson, 8192);

    if (!id_ok || !params_ok) {
        // Payload exceeded buffer — push an error response back to the gateway
        // so the external client gets a meaningful rejection instead of silence.
        g_log.log("BridgePollCommand: payload truncated (requestId=" +
                  std::to_string(cmd->request_id.size()) + " chars, params=" +
                  std::to_string(cmd->params_json.size()) + " chars) — sending error");
        std::string err = "{\"type\":\"Error\",\"data\":{\"code\":-2,"
                          "\"message\":\"Command payload too large for bridge buffer\","
                          "\"request_id\":\"" + cmd->request_id + "\"}}";
        g_response_queue.push(std::move(err));
        return CMD_NONE;  // Don't hand a truncated command to the EA
    }

    return cmd->type;
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
