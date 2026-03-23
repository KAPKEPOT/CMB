// cipher-mt5-bridge/dll/include/tcp_server.h
// Single-client TCP server for communicating with the Rust CMG gateway

#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <string>
#include <thread>
#include <atomic>
#include <functional>

#include "types_internal.h"

#pragma comment(lib, "Ws2_32.lib")

namespace cipher {

class TcpServer {
public:
    using OnLineCallback       = std::function<void(const std::string& line)>;
    using OnDisconnectCallback = std::function<void()>;

    TcpServer(int port, LogQueue& log);
    ~TcpServer();

    // Start listening. Blocks until shutdown or error — run in a thread.
    bool start();

    // Stop the server and close all connections.
    void stop();

    // Send a line (appends \n) to the connected client.
    // Returns false if no client connected.
    bool send_line(const std::string& json_line);

    // Set callback for incoming lines from the client.
    void set_on_line(OnLineCallback cb);
    void set_on_disconnect(OnDisconnectCallback cb);

    // Is the gateway client currently connected?
    bool is_client_connected() const;

private:
    void accept_loop();
    void reader_loop(SOCKET client);

    int port_;
    LogQueue& log_;

    SOCKET listen_socket_ = INVALID_SOCKET;
    SOCKET client_socket_ = INVALID_SOCKET;
    std::mutex client_mutex_;

    std::atomic<bool> running_{false};
    std::atomic<bool> client_connected_{false};

    std::thread accept_thread_;
    std::thread reader_thread_;

    OnLineCallback on_line_;
    OnDisconnectCallback on_disconnect_;
    std::mutex callback_mutex_;
};

} // namespace cipher