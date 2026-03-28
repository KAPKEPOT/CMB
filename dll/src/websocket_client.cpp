// cipher-mt5-bridge/dll/src/websocket_client.cpp
#include "websocket_client.h"

// WebSocket++ with standalone Asio TLS
#define ASIO_STANDALONE
#include <websocketpp/config/asio_client.hpp>
#include <websocketpp/client.hpp>
#include <nlohmann/json.hpp>
#include <chrono>
#include <sstream>

// Asio SSL (standalone, no Boost)
#include <asio/ssl.hpp>

using json = nlohmann::json;

namespace cipher {

// Type alias for TLS-enabled client
using tls_client = websocketpp::client<websocketpp::config::asio_tls_client>;
using ssl_context = asio::ssl::context;
using context_ptr = std::shared_ptr<ssl_context>;

// PIMPL implementation to hide WebSocket++ headers
struct WebSocketClient::Impl {
    tls_client client;
    websocketpp::connection_hdl hdl;
    std::mutex send_mutex;
    
    Impl() {
        client.init_asio();
        // Disable logging for production
        client.set_access_channels(websocketpp::log::alevel::none);
        client.set_error_channels(websocketpp::log::elevel::none);
    }
    
    // Reset ASIO state for reconnection — WebSocket++ requires this
    // after client.run() has returned, otherwise get_connection() fails
    void reset() {
        client.reset();
    }
};

WebSocketClient::WebSocketClient()
    : impl_(std::make_unique<Impl>())
    , reconnect_cancelled_(std::make_shared<std::atomic<bool>>(false)) {
    
    // --- Fix 5: TLS init handler (required for wss:// connections) ---
    // Without this, WebSocket++ cannot establish TLS and silently fails.
    impl_->client.set_tls_init_handler([](websocketpp::connection_hdl) -> context_ptr {
        auto ctx = std::make_shared<ssl_context>(ssl_context::tlsv12_client);
        
        try {
            // Use system default CA certificates
            ctx->set_default_verify_paths();
            
            // For production: verify server certificate
            // ctx->set_verify_mode(asio::ssl::verify_peer);
            
            // For development/self-signed: skip verification
            ctx->set_verify_mode(asio::ssl::verify_none);
        }
        catch (std::exception& e) {
            // If SSL context setup fails, return it anyway — 
            // connection will fail with a clear TLS error
        }
        
        return ctx;
    });
    
    // Set up WebSocket++ handlers with lambdas that call our methods
    impl_->client.set_open_handler([this](websocketpp::connection_hdl hdl) {
        this->on_open(hdl);
    });
    
    impl_->client.set_message_handler([this](websocketpp::connection_hdl hdl, 
                                              tls_client::message_ptr msg) {
        this->on_message(hdl, msg->get_payload());
    });
    
    impl_->client.set_close_handler([this](websocketpp::connection_hdl hdl) {
        this->on_close(hdl);
    });
    
    impl_->client.set_fail_handler([this](websocketpp::connection_hdl hdl) {
        this->on_fail(hdl);
    });
}

WebSocketClient::~WebSocketClient() {
    disconnect();
}

bool WebSocketClient::connect(const std::string& url, const std::string& account_id) {
    if (running_) return false;
    
    url_ = url;
    account_id_ = account_id;
    running_ = true;
    
    // Reset ASIO state for reconnection ---
    // After client.run() returns (from a previous connection),
    // the io_context is in a stopped state. reset() clears it
    // so get_connection() and run() work again.
    impl_->reset();
    
    websocketpp::lib::error_code ec;
    auto con = impl_->client.get_connection(url, ec);
    
    if (ec) {
        if (on_error_) on_error_("Failed to create connection: " + ec.message());
        running_ = false;
        return false;
    }
    
    impl_->client.connect(con);
    
    // Start ASIO io_context in background thread
    io_thread_ = std::thread(&WebSocketClient::run_io_context, this);
    
    return true;
}

void WebSocketClient::run_io_context() {
    try {
        impl_->client.run();
    }
    catch (const std::exception& e) {
        if (on_error_) on_error_("ASIO run error: " + std::string(e.what()));
    }
    running_ = false;
}

void WebSocketClient::disconnect() {
    if (!running_ && !connected_) return;
    
    // Signal any sleeping reconnect threads to abort before we destroy state
    reconnect_cancelled_->store(true);
    
    if (connected_) {
        websocketpp::lib::error_code ec;
        impl_->client.close(impl_->hdl, websocketpp::close::status::normal, "Shutting down", ec);
    }
    
    impl_->client.stop();
    
    if (io_thread_.joinable()) {
        io_thread_.join();
    }
    
    connected_ = false;
    running_ = false;
}

bool WebSocketClient::send_response(const std::string& response_json) {
    if (!connected_) return false;
    
    std::lock_guard<std::mutex> lock(impl_->send_mutex);
    websocketpp::lib::error_code ec;
    impl_->client.send(impl_->hdl, response_json, websocketpp::frame::opcode::text, ec);
    return !ec;
}

bool WebSocketClient::is_connected() const {
    return connected_.load();
}

void WebSocketClient::on_open(websocketpp::connection_hdl hdl) {
    impl_->hdl = hdl;
    connected_ = true;
    reconnect_attempts_ = 0;
    
    // Send registration immediately
    send_registration();
    
    if (on_connected_) on_connected_();
}

void WebSocketClient::send_registration() {
    json reg_msg = {
        {"type", "register"},
        {"account_id", account_id_},
        {"version", "2.0.0"}
    };
    
    send_response(reg_msg.dump());
}

void WebSocketClient::on_message(websocketpp::connection_hdl hdl, std::string payload) {
    GatewayMessage msg = parse_message(payload);
    
    // Dispatch to callback based on message type
    switch (msg.type) {
        case MessageType::COMMAND:
            if (on_command_) {
                on_command_(msg);
            }
            break;
            
        case MessageType::PING:
            // Respond to ping with pong
            {
                json pong = {
                    {"type", "pong"},
                    {"timestamp", std::chrono::duration_cast<std::chrono::milliseconds>(
                        std::chrono::system_clock::now().time_since_epoch()).count()}
                };
                if (!msg.request_id.empty()) {
                    pong["request_id"] = msg.request_id;
                }
                send_response(pong.dump());
            }
            break;
            
        case MessageType::REGISTER_ACK:
            // Registration confirmed
            break;
            
        case MessageType::ERROR:
            if (on_error_) on_error_(msg.params_json);
            break;
            
        default:
            // Unknown message type
            break;
    }
}

GatewayMessage WebSocketClient::parse_message(const std::string& json_str) {
    GatewayMessage msg;
    msg.type = MessageType::ERROR;
    msg.raw = json_str;
    
    try {
        auto j = json::parse(json_str);
        
        std::string type_str = j.value("type", "");
        
        if (type_str == "register_ack") {
            msg.type = MessageType::REGISTER_ACK;
            msg.request_id = j.value("request_id", "");
        }
        else if (type_str == "ping") {
            msg.type = MessageType::PING;
            msg.request_id = j.value("request_id", "");
        }
        else if (type_str == "pong") {
            msg.type = MessageType::PONG;
        }
        else if (type_str == "error") {
            msg.type = MessageType::ERROR;
            if (j.contains("data")) {
                msg.params_json = j["data"].dump();
            }
        }
        else {
            // This is a command
            msg.type = MessageType::COMMAND;
            msg.command_type = type_str;
            msg.request_id = j.value("request_id", "");
            
            // Extract parameters from "data" field
            if (j.contains("data") && !j["data"].is_null()) {
                msg.params_json = j["data"].dump();
            } else {
                msg.params_json = "{}";
            }
        }
    }
    catch (const json::exception& e) {
        if (on_error_) on_error_("JSON parse error: " + std::string(e.what()));
    }
    
    return msg;
}

void WebSocketClient::on_close(websocketpp::connection_hdl hdl) {
    connected_ = false;
    if (on_disconnected_) on_disconnected_();
    start_reconnect_timer();
}

void WebSocketClient::on_fail(websocketpp::connection_hdl hdl) {
    connected_ = false;
    if (on_disconnected_) on_disconnected_();
    start_reconnect_timer();
}

void WebSocketClient::start_reconnect_timer() {
    if (reconnect_attempts_ >= MAX_RECONNECT_ATTEMPTS) {
        if (on_error_) on_error_("Max reconnection attempts reached");
        return;
    }
    
    reconnect_attempts_++;
    
    int delay_ms = BASE_RECONNECT_DELAY_MS * (1 << (reconnect_attempts_ - 1));
    if (delay_ms > 30000) delay_ms = 30000;  // Cap at 30 seconds
    
    
    // Safe if object is destroyed: cancelled prevents touching 'this'.
    // Added running_ check to close the TOCTOU race window.
    auto cancelled = reconnect_cancelled_;
    std::string url = url_;
    std::string aid = account_id_;

    std::thread([this, cancelled, url, aid, delay_ms]() {
        std::this_thread::sleep_for(std::chrono::milliseconds(delay_ms));
        // Double-check: cancel flag AND running flag must both be safe
        if (!cancelled->load() && running_.load()) {
            // Wait for previous io_thread to finish before reconnecting
            if (io_thread_.joinable()) {
                io_thread_.join();
            }
            running_ = false;  // Reset so connect() accepts the call
            connect(url, aid);
        }
    }).detach();
}

} // namespace cipher