// cipher-mt5-bridge/dll/src/protocol.cpp
// JSON protocol implementation

#include "protocol.h"
#include <unordered_map>

namespace cipher {

// Map type string → BridgeCommandType
static const std::unordered_map<std::string, int> COMMAND_TYPE_MAP = {
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

ParsedCommand parse_command(const std::string& json_line) {
    ParsedCommand cmd;
    cmd.type = CMD_NONE;

    try {
        json j = json::parse(json_line);

        // Extract request_id (top-level, from CommandEnvelope's flatten)
        if (j.contains("request_id") && j["request_id"].is_string()) {
            cmd.request_id = j["request_id"].get<std::string>();
        }

        // Extract type
        if (!j.contains("type") || !j["type"].is_string()) {
            return cmd;
        }
        std::string type_str = j["type"].get<std::string>();

        auto it = COMMAND_TYPE_MAP.find(type_str);
        if (it == COMMAND_TYPE_MAP.end()) {
            return cmd;
        }
        cmd.type = it->second;

        // Extract data payload as JSON string
        if (j.contains("data") && !j["data"].is_null()) {
            cmd.params_json = j["data"].dump();
        } else {
            cmd.params_json = "{}";
        }
    }
    catch (const json::exception&) {
        cmd.type = CMD_NONE;
    }

    return cmd;
}

// Helper to wrap type + data
static std::string wrap_response(const std::string& type, const json& data) {
    json envelope;
    envelope["type"] = type;
    envelope["data"] = data;
    return envelope.dump();
}

static std::string wrap_response_no_data(const std::string& type) {
    json envelope;
    envelope["type"] = type;
    return envelope.dump();
}

// Response builders

std::string build_pong(const std::string& request_id, long long timestamp) {
    json data;
    data["request_id"] = request_id;
    data["timestamp"] = timestamp;
    return wrap_response("Pong", data);
}

std::string build_status(
    bool connected, const std::string& terminal, const std::string& server,
    long long account, long long uptime, int symbols_count
) {
    json data;
    data["connected"]     = connected;
    data["terminal"]      = terminal;
    data["server"]        = server;
    data["account"]       = account;
    data["uptime"]        = uptime;
    data["symbols_count"] = symbols_count;
    return wrap_response("Status", data);
}

std::string build_subscribed(
    const std::string& request_id,
    const std::vector<std::string>& symbols,
    const std::string& timeframe
) {
    json data;
    data["request_id"] = request_id;
    data["symbols"]    = symbols;
    if (!timeframe.empty())
        data["timeframe"] = timeframe;
    else
        data["timeframe"] = nullptr;
    return wrap_response("Subscribed", data);
}

std::string build_unsubscribed(
    const std::string& request_id,
    const std::vector<std::string>& symbols
) {
    json data;
    data["request_id"] = request_id;
    data["symbols"]    = symbols;
    return wrap_response("Unsubscribed", data);
}

std::string build_account_info(
    const std::string& request_id,
    long long login, const std::string& name, const std::string& server,
    double balance, double equity, double margin, double free_margin,
    int leverage, const std::string& currency, double profit
) {
    json data;
    data["request_id"]  = request_id;
    data["login"]       = login;
    data["name"]        = name;
    data["server"]      = server;
    data["balance"]     = balance;
    data["equity"]      = equity;
    data["margin"]      = margin;
    data["free_margin"] = free_margin;
    data["leverage"]    = leverage;
    data["currency"]    = currency;
    data["profit"]      = profit;
    return wrap_response("AccountInfo", data);
}

std::string build_symbol_info(
    const std::string& request_id,
    const std::string& symbol, const std::string& description,
    int digits, double point, int spread, bool spread_float,
    double tick_size, double tick_value, double contract_size,
    double min_volume, double max_volume, double volume_step,
    double margin_initial, double margin_maintenance,
    const std::string& trade_mode, const std::string& execution_mode,
    int trade_freeze_level, int trade_stops_level
) {
    json data;
    data["request_id"]          = request_id;
    data["symbol"]              = symbol;
    data["description"]         = description;
    data["digits"]              = digits;
    data["point"]               = point;
    data["spread"]              = spread;
    data["spread_float"]        = spread_float;
    data["tick_size"]           = tick_size;
    data["tick_value"]          = tick_value;
    data["contract_size"]       = contract_size;
    data["min_volume"]          = min_volume;
    data["max_volume"]          = max_volume;
    data["volume_step"]         = volume_step;
    data["margin_initial"]      = margin_initial;
    data["margin_maintenance"]  = margin_maintenance;
    data["trade_mode"]          = trade_mode;
    data["execution_mode"]      = execution_mode;
    data["trade_freeze_level"]  = trade_freeze_level;
    data["trade_stops_level"]   = trade_stops_level;
    return wrap_response("SymbolInfo", data);
}

std::string build_history_data(
    const std::string& request_id,
    const std::string& symbol, const std::string& timeframe,
    const std::string& bars_json_array
) {
    json data;
    data["request_id"] = request_id;
    data["symbol"]     = symbol;
    data["timeframe"]  = timeframe;
    // Parse the pre-built array so it embeds correctly
    try {
        data["bars"] = json::parse(bars_json_array);
    } catch (...) {
        data["bars"] = json::array();
    }
    return wrap_response("HistoryData", data);
}

std::string build_order_result(
    const std::string& request_id,
    long long ticket, bool success, const std::string& error
) {
    json data;
    data["request_id"] = request_id;
    data["ticket"]     = ticket;
    data["success"]    = success;
    if (error.empty())
        data["error"] = nullptr;
    else
        data["error"] = error;
    return wrap_response("OrderResult", data);
}

std::string build_positions(
    const std::string& request_id,
    const std::string& positions_json_array
) {
    json data;
    data["request_id"] = request_id;
    try {
        data["positions"] = json::parse(positions_json_array);
    } catch (...) {
        data["positions"] = json::array();
    }
    return wrap_response("Positions", data);
}

std::string build_orders(
    const std::string& request_id,
    const std::string& orders_json_array
) {
    json data;
    data["request_id"] = request_id;
    try {
        data["orders"] = json::parse(orders_json_array);
    } catch (...) {
        data["orders"] = json::array();
    }
    return wrap_response("Orders", data);
}

std::string build_tick(
    const std::string& symbol,
    double bid, double ask, double last,
    long long volume, long long time
) {
    json data;
    data["symbol"] = symbol;
    data["bid"]    = bid;
    data["ask"]    = ask;
    data["last"]   = last;
    data["volume"] = volume;
    data["time"]   = time;
    return wrap_response("Tick", data);
}

std::string build_candle(
    const std::string& symbol, const std::string& timeframe,
    long long time, double open, double high, double low, double close,
    long long volume, bool complete
) {
    json data;
    data["symbol"]    = symbol;
    data["timeframe"] = timeframe;
    data["time"]      = time;
    data["open"]      = open;
    data["high"]      = high;
    data["low"]       = low;
    data["close"]     = close;
    data["volume"]    = volume;
    data["complete"]  = complete;
    return wrap_response("Candle", data);
}

std::string build_error(int code, const std::string& message) {
    json data;
    data["code"]    = code;
    data["message"] = message;
    return wrap_response("Error", data);
}

} // namespace cipher
