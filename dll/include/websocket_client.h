// cipher-mt5-bridge/dll/include/websocket_client.h
#pragma once

#include <string>
#include <functional>
#include <atomic>
#include <thread>
#include <mutex>
#include <queue>
#include <memory>

// Forward declare WebSocket++ types
namespace websocketpp {
    namespace lib {
        namespace asio {
            class io_context;
        }
    }
    template<typename T>
    class client;
    class connection_hdl;
    template<typename T>
    class connection;
    struct config;
}

namespace cipher {

// Message types for event-driven communication
enum class MessageType {
    COMMAND,      // Command from gateway to execute
    PING,         // Heartbeat ping
    PONG,         // Heartbeat response
    REGISTER_ACK, // Registration acknowledgment
    ERROR         // Error message
};

// Parsed message from gateway
struct GatewayMessage {
    MessageType type;
    std::string request_id;
    std::string command_type;  // e.g., "PlaceOrder", "GetAccountInfo"
    std::string params_json;   // Command parameters
    std::string raw;           // Raw JSON for debugging
};

// Callback types for event-driven architecture
using OnCommandCallback = std::function<void(const GatewayMessage& msg)>;
using OnConnectedCallback = std::function<void()>;
using OnDisconnectedCallback = std::function<void()>;
using OnErrorCallback = std::function<void(const std::string& error)>;

class WebSocketClient {
public:
    WebSocketClient();
    ~WebSocketClient();

    // Connect to gateway (initiates OUTBOUND connection)
    bool connect(const std::string& url, const std::string& account_id);
    
    // Disconnect gracefully
    void disconnect();
    
    // Send a response back to gateway
    bool send_response(const std::string& response_json);
    
    // Check connection status
    bool is_connected() const;
    
    // Get account ID
    const std::string& account_id() const { return account_id_; }
    
    // Set event callbacks
    void set_on_command(OnCommandCallback cb) { on_command_ = std::move(cb); }
    void set_on_connected(OnConnectedCallback cb) { on_connected_ = std::move(cb); }
    void set_on_disconnected(OnDisconnectedCallback cb) { on_disconnected_ = std::move(cb); }
    void set_on_error(OnErrorCallback cb) { on_error_ = std::move(cb); }

private:
    // Internal WebSocket handlers (called from WebSocket++ threads)
    void on_open(websocketpp::connection_hdl hdl);
    void on_message(websocketpp::connection_hdl hdl, std::string payload);
    void on_close(websocketpp::connection_hdl hdl);
    void on_fail(websocketpp::connection_hdl hdl);
    
    // Run the ASIO io_context
    void run_io_context();
    
    // Send registration message after connection
    void send_registration();
    
    // Parse incoming message into GatewayMessage
    GatewayMessage parse_message(const std::string& json);
    
    // Reconnect logic
    void start_reconnect_timer();
    
private:
    // WebSocket client (PIMPL to hide WebSocket++ headers)
    struct Impl;
    std::unique_ptr<Impl> impl_;
    
    // State
    std::atomic<bool> connected_{false};
    std::atomic<bool> running_{false};
    std::string url_;
    std::string account_id_;
    
    // Threads
    std::thread io_thread_;
    
    // Callbacks
    OnCommandCallback on_command_;
    OnConnectedCallback on_connected_;
    OnDisconnectedCallback on_disconnected_;
    OnErrorCallback on_error_;
    
    // Reconnection
    std::atomic<int> reconnect_attempts_{0};
    static constexpr int MAX_RECONNECT_ATTEMPTS = 10;
    static constexpr int BASE_RECONNECT_DELAY_MS = 1000;
    std::shared_ptr<std::atomic<bool>> reconnect_cancelled_;
};

} // namespace cipher