// cipher-mt5-bridge/dll/src/tcp_server.cpp
// Single-client TCP server implementation

#include "tcp_server.h"
#include <sstream>

namespace cipher {

TcpServer::TcpServer(int port, LogQueue& log)
    : port_(port), log_(log) {}

TcpServer::~TcpServer() {
    stop();
}

bool TcpServer::start() {
    // Initialize Winsock
    WSADATA wsaData;
    int result = WSAStartup(MAKEWORD(2, 2), &wsaData);
    if (result != 0) {
        log_.log("WSAStartup failed: " + std::to_string(result));
        return false;
    }

    // Create listening socket
    struct addrinfo hints{}, *addrResult = nullptr;
    hints.ai_family   = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    hints.ai_flags    = AI_PASSIVE;

    std::string port_str = std::to_string(port_);
    result = getaddrinfo(nullptr, port_str.c_str(), &hints, &addrResult);
    if (result != 0) {
        log_.log("getaddrinfo failed: " + std::to_string(result));
        WSACleanup();
        return false;
    }

    listen_socket_ = socket(addrResult->ai_family, addrResult->ai_socktype, addrResult->ai_protocol);
    if (listen_socket_ == INVALID_SOCKET) {
        log_.log("socket() failed: " + std::to_string(WSAGetLastError()));
        freeaddrinfo(addrResult);
        WSACleanup();
        return false;
    }

    // Allow address reuse
    int opt = 1;
    setsockopt(listen_socket_, SOL_SOCKET, SO_REUSEADDR, (const char*)&opt, sizeof(opt));

    // Bind
    result = bind(listen_socket_, addrResult->ai_addr, (int)addrResult->ai_addrlen);
    freeaddrinfo(addrResult);
    if (result == SOCKET_ERROR) {
        log_.log("bind() failed: " + std::to_string(WSAGetLastError()));
        closesocket(listen_socket_);
        listen_socket_ = INVALID_SOCKET;
        WSACleanup();
        return false;
    }

    // Listen
    result = listen(listen_socket_, 1); // Single client
    if (result == SOCKET_ERROR) {
        log_.log("listen() failed: " + std::to_string(WSAGetLastError()));
        closesocket(listen_socket_);
        listen_socket_ = INVALID_SOCKET;
        WSACleanup();
        return false;
    }

    running_ = true;
    log_.log("TCP server listening on port " + port_str);

    // Start accept loop in background thread
    accept_thread_ = std::thread(&TcpServer::accept_loop, this);

    return true;
}

void TcpServer::stop() {
    running_ = false;

    // Close listening socket to unblock accept()
    if (listen_socket_ != INVALID_SOCKET) {
        closesocket(listen_socket_);
        listen_socket_ = INVALID_SOCKET;
    }

    // Close client socket
    {
        std::lock_guard<std::mutex> lock(client_mutex_);
        if (client_socket_ != INVALID_SOCKET) {
            shutdown(client_socket_, SD_BOTH);
            closesocket(client_socket_);
            client_socket_ = INVALID_SOCKET;
        }
        client_connected_ = false;
    }

    // Join threads
    if (accept_thread_.joinable()) accept_thread_.join();
    if (reader_thread_.joinable()) reader_thread_.join();

    WSACleanup();
    log_.log("TCP server stopped");
}

void TcpServer::accept_loop() {
    while (running_) {
        // Accept one client at a time
        SOCKET new_client = accept(listen_socket_, nullptr, nullptr);
        if (new_client == INVALID_SOCKET) {
            if (running_) {
                int err = WSAGetLastError();
                if (err != WSAEINTR && err != WSAENOTSOCK) {
                    log_.log("accept() failed: " + std::to_string(err));
                }
            }
            continue;
        }

        // Close existing client if any
        {
            std::lock_guard<std::mutex> lock(client_mutex_);
            if (client_socket_ != INVALID_SOCKET) {
                log_.log("Replacing existing client connection");
                shutdown(client_socket_, SD_BOTH);
                closesocket(client_socket_);
            }
            client_socket_ = new_client;
            client_connected_ = true;
        }

        // Wait for previous reader thread to finish
        if (reader_thread_.joinable()) reader_thread_.join();

        log_.log("Gateway client connected");

        // Disable Nagle's algorithm for lower latency
        int flag = 1;
        setsockopt(new_client, IPPROTO_TCP, TCP_NODELAY, (const char*)&flag, sizeof(flag));

        // Set socket buffer sizes
        int buf_size = 65536;
        setsockopt(new_client, SOL_SOCKET, SO_RCVBUF, (const char*)&buf_size, sizeof(buf_size));
        setsockopt(new_client, SOL_SOCKET, SO_SNDBUF, (const char*)&buf_size, sizeof(buf_size));

        // Start reader thread for this client
        reader_thread_ = std::thread(&TcpServer::reader_loop, this, new_client);
    }
}

void TcpServer::reader_loop(SOCKET client) {
    const int RECV_BUF_SIZE = 65536;
    char recv_buf[RECV_BUF_SIZE];
    std::string line_buffer;

    while (running_ && client_connected_) {
        int bytes_read = recv(client, recv_buf, RECV_BUF_SIZE - 1, 0);

        if (bytes_read <= 0) {
            if (bytes_read == 0) {
                log_.log("Gateway client disconnected gracefully");
            } else {
                int err = WSAGetLastError();
                if (running_ && err != WSAEINTR && err != WSAECONNRESET) {
                    log_.log("recv() error: " + std::to_string(err));
                }
            }
            break;
        }

        recv_buf[bytes_read] = '\0';
        line_buffer.append(recv_buf, bytes_read);

        // Process complete lines (newline-delimited JSON)
        size_t pos;
        while ((pos = line_buffer.find('\n')) != std::string::npos) {
            std::string line = line_buffer.substr(0, pos);
            line_buffer.erase(0, pos + 1);

            // Trim \r if present
            if (!line.empty() && line.back() == '\r')
                line.pop_back();

            if (!line.empty()) {
                std::lock_guard<std::mutex> lock(callback_mutex_);
                if (on_line_) {
                    on_line_(line);
                }
            }
        }
    }

    // Mark disconnected
    {
        std::lock_guard<std::mutex> lock(client_mutex_);
        if (client_socket_ == client) {
            closesocket(client_socket_);
            client_socket_ = INVALID_SOCKET;
            client_connected_ = false;
        }
    }
    
    // Notify dllmain so it can flush stale queued responses
    {
        std::lock_guard<std::mutex> lock(callback_mutex_);
        if (on_disconnect_) on_disconnect_();
    }
    
    log_.log("Reader thread exiting");
}

bool TcpServer::send_line(const std::string& json_line) {
    std::lock_guard<std::mutex> lock(client_mutex_);
    if (client_socket_ == INVALID_SOCKET || !client_connected_)
        return false;

    std::string data = json_line + "\n";
    const char* ptr = data.c_str();
    int remaining = static_cast<int>(data.size());

    while (remaining > 0) {
        int sent = send(client_socket_, ptr, remaining, 0);
        if (sent == SOCKET_ERROR) {
            int err = WSAGetLastError();
            log_.log("send() failed: " + std::to_string(err));
            // Mark disconnected
            shutdown(client_socket_, SD_BOTH);
            closesocket(client_socket_);
            client_socket_ = INVALID_SOCKET;
            client_connected_ = false;
            return false;
        }
        ptr += sent;
        remaining -= sent;
    }

    return true;
}
void TcpServer::set_on_disconnect(OnDisconnectCallback cb) {
    std::lock_guard<std::mutex> lock(callback_mutex_);
    on_disconnect_ = std::move(cb);
}

void TcpServer::set_on_line(OnLineCallback cb) {
    std::lock_guard<std::mutex> lock(callback_mutex_);
    on_line_ = std::move(cb);
}

bool TcpServer::is_client_connected() const {
    return client_connected_.load();
}

} // namespace cipher
