// cipher-mt5-bridge/dll/include/protocol.h
// JSON protocol handler matching Rust's BridgeCommand / BridgeResponse
// Uses nlohmann/json (single header, download from https://github.com/nlohmann/json)

#pragma once

#include <string>
#include <vector>
#include <optional>

#include "cipher_bridge.h"
#include "types_internal.h"

// nlohmann/json — place json.hpp in dll/include/nlohmann/
#include <nlohmann/json.hpp>

namespace cipher {

using json = nlohmann::json;

// ============================================================================
// Parse incoming JSON line into a ParsedCommand
// ============================================================================

// Parses a CommandEnvelope:
//   {"request_id": "uuid", "type": "PlaceOrder", "data": {...}}
// Returns CMD_NONE on parse failure.
ParsedCommand parse_command(const std::string& json_line);

// ============================================================================
// Build outgoing JSON response strings
// ============================================================================

// These match BridgeResponse's #[serde(tag = "type", content = "data")] format:
//   {"type": "Pong", "data": {"request_id": "uuid", "timestamp": 123456}}

std::string build_pong(const std::string& request_id, long long timestamp);

std::string build_status(
    bool connected, const std::string& terminal, const std::string& server,
    long long account, long long uptime, int symbols_count
);

std::string build_subscribed(
    const std::string& request_id,
    const std::vector<std::string>& symbols,
    const std::string& timeframe
);

std::string build_unsubscribed(
    const std::string& request_id,
    const std::vector<std::string>& symbols
);

std::string build_account_info(
    const std::string& request_id,
    long long login, const std::string& name, const std::string& server,
    double balance, double equity, double margin, double free_margin,
    int leverage, const std::string& currency, double profit
);

std::string build_symbol_info(
    const std::string& request_id,
    const std::string& symbol, const std::string& description,
    int digits, double point, int spread, bool spread_float,
    double tick_size, double tick_value, double contract_size,
    double min_volume, double max_volume, double volume_step,
    double margin_initial, double margin_maintenance,
    const std::string& trade_mode, const std::string& execution_mode,
    int trade_freeze_level, int trade_stops_level
);

// bars_json is a pre-built JSON array string: [{"time":...,"open":...}, ...]
std::string build_history_data(
    const std::string& request_id,
    const std::string& symbol, const std::string& timeframe,
    const std::string& bars_json_array
);

std::string build_order_result(
    const std::string& request_id,
    long long ticket, bool success, const std::string& error
);

// positions_json is a pre-built JSON array string
std::string build_positions(
    const std::string& request_id,
    const std::string& positions_json_array
);

// orders_json is a pre-built JSON array string
std::string build_orders(
    const std::string& request_id,
    const std::string& orders_json_array
);

std::string build_tick(
    const std::string& symbol,
    double bid, double ask, double last,
    long long volume, long long time
);

std::string build_candle(
    const std::string& symbol, const std::string& timeframe,
    long long time, double open, double high, double low, double close,
    long long volume, bool complete
);

std::string build_error(int code, const std::string& message);

} // namespace cipher