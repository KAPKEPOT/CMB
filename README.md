<div align="center">

# CipherBridge — MT5 ↔ Gateway Bridge

[![C++17](https://img.shields.io/badge/C%2B%2B-17-00599C?logo=cplusplus&logoColor=white)](https://en.cppreference.com/w/cpp/17)
[![MQL5](https://img.shields.io/badge/MQL5-Expert%20Advisor-4A90D9)](https://www.mql5.com/)
[![Docker](https://img.shields.io/badge/Docker-Wine%20%2B%20MT5-2496ED?logo=docker&logoColor=white)](https://www.docker.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**Low-latency C++ DLL + MQL5 Expert Advisor that bridges MetaTrader 5 to the [CipherBridge Gateway (CMG)](https://github.com/KAPKEPOT/CMG) over WebSocket.**

</div>

---

## Architecture

```
CMG Gateway (Rust/axum)  ←── WSS (JSON) ──→  CipherBridge.dll  ←── fn calls ──→  EA (MQL5)
    Linux VPS                                  inside MT5                         MT5 Terminal
    /bridge/ws                                 outbound conn                      OrderSend, etc.
```

The EA runs inside the MT5 terminal with native access to `OrderSend`, `CopyRates`, `SymbolInfoTick`, etc. It calls into the DLL on every tick and timer event. The DLL manages the WebSocket connection, TLS, JSON serialization, and thread-safe command/response queuing.

**Key design:** The DLL connects **outbound** to the gateway — zero inbound ports needed on the machine running MT5.

## Data Flow

**Tick (terminal → gateway):**

MT5 fires `OnTick` → EA calls `BridgePushTick()` → DLL serializes to JSON → WebSocket send → CMG routes to subscribers.

**Order (gateway → terminal):**

CMG sends `PlaceOrder` JSON over WebSocket → DLL parses → command queue → EA's `OnTimer` calls `BridgePollCommand()` → EA calls `OrderSend()` → EA calls `BridgePushResponse()` → DLL sends result over WebSocket → CMG resolves.

**Credentials (gateway → terminal, Docker mode):**

Container starts → `launcher.py` registers with gateway → gets WebSocket token → writes config files → DLL reads them via `BridgeInitFromEnv()` → connects → gateway delivers encrypted credentials via `CMD_CREDENTIALS` → EA logs into MT5.

## Two Operating Modes

### Manual Mode (Windows VPS)

The EA provides the WebSocket URL and account ID directly:

```
EA Input: GatewayUrl = wss://gateway.example.com/bridge/ws?token=xxx
EA Input: AccountId  = a1b2c3d4-...
```

EA calls `BridgeInit(url, account_id)` on startup.

### Docker Mode (Automated)

The gateway provisions a Docker container with Wine + MT5. The `launcher.py` script handles registration automatically:

```
Container starts → launcher.py registers → gets WS token → writes config files
→ MT5 starts → EA calls BridgeInitFromEnv() → reads config → connects
```

No manual configuration needed — everything is injected by the gateway.

## Latency

- Tick delivery: sub-millisecond (OnTick → DLL → WebSocket, no queue hop)
- Command round-trip: ~10-25ms (bounded by `OnTimer` polling interval)
- Configurable timer: default 10ms via `InpTimerMs` EA input
- Reconnection: exponential backoff, 1s → 2s → 4s → ... → 30s cap, 10 attempts max

## Building the DLL

### Prerequisites

| Requirement | Download |
|-------------|----------|
| VS Build Tools 2022/2025 (C++ workload) | https://visualstudio.microsoft.com/downloads/#build-tools-for-visual-studio-2022 |
| OpenSSL Win64 **Full** (~250MB, not Light) | https://slproweb.com/products/Win32OpenSSL.html |
| Git | https://git-scm.com/download/win |

WebSocket++, Asio, and nlohmann/json are downloaded automatically by CMake.

### Build Steps

**1. Clone:**

```cmd
git clone https://github.com/KAPKEPOT/CMB.git
cd CMB
```

**2. Open the correct terminal:**

From the Start Menu, open **"x64 Native Tools Command Prompt for VS 2022"** (or 2025).

The banner must say:
```
[vcvarsall.bat] Environment initialized for: 'x64'
```

Do **NOT** use x64_x86 Cross Tools (builds 32-bit), regular CMD, or PowerShell.

**3. Build:**

```cmd
cd dll
mkdir build
cd build
cmake .. -G "NMake Makefiles"
nmake
```

**4. Verify:**

```cmd
dir CipherBridge.dll
```

Output: `CipherBridge.dll` (~5MB)

### Clean Rebuild

```cmd
cd CMB\dll
rd /s /q build
mkdir build
cd build
cmake .. -G "NMake Makefiles"
nmake
```

Always delete the entire `build` directory when switching generators or after changing CMakeLists.txt.

### Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| "OpenSSL not found" | Installed Light version | Uninstall, install Full (~250MB) |
| "MT5 requires a 64-bit build" | Wrong terminal (x64_x86) | Open **x64 Native Tools** terminal |
| "MAKEFILE not found" | cmake failed | Check cmake output, delete `build/`, retry |
| `ERROR` macro collision | Windows defines `ERROR` as `0` | Already fixed: renamed to `MSG_ERROR` |
| `connection_hdl` redefinition | Bad forward declarations | Already fixed: uses `std::weak_ptr<void>` typedef |
| "ASIO_STANDALONE redefinition" | Defined in both CMake and source | Harmless warning, build succeeds |

## Deploy (Manual Mode)

### 1. Copy DLL

Copy `CipherBridge.dll` to your MT5 data folder:

```
%APPDATA%\MetaQuotes\Terminal\<INSTANCE_ID>\MQL5\Libraries\CipherBridge.dll
```

Find your instance ID: MT5 → File → Open Data Folder.

### 2. Copy MQL5 Files

```
mql5/Include/CipherBridge.mqh  →  MQL5\Include\CipherBridge.mqh
mql5/Experts/CipherBridgeEA.mq5  →  MQL5\Experts\CipherBridgeEA.mq5
```

### 3. Compile the EA

In MetaEditor (F4 from MT5), open `CipherBridgeEA.mq5` and press F7.

### 4. Attach to Chart

1. MT5 → **Tools → Options → Expert Advisors** → Check **"Allow DLL imports"**
2. Drag `CipherBridgeEA` onto any chart
3. Set inputs:
   - `InpGatewayUrl`: WebSocket URL (e.g., `wss://gateway.example.com/bridge/ws?token=xxx`)
   - `InpAccountId`: Account UUID from gateway
   - `InpTimerMs`: Poll interval in ms (default 10)
   - `InpLogVerbose`: Enable detailed logging
4. Click OK — the DLL connects outbound to the gateway

## Deploy (Docker Mode)

The gateway handles this automatically. When a user registers via the Telegram bot:

1. Gateway creates account + encrypts credentials
2. DockerProvisioner runs: `docker create ciphertrade/mt5-bridge:latest` with env vars
3. Container starts Wine + Xvfb + MT5
4. `launcher.py` registers with gateway, gets WS token
5. MT5 launches with EA attached
6. EA calls `BridgeInitFromEnv()` → reads config → connects
7. Gateway delivers credentials via `CMD_CREDENTIALS`
8. EA logs into MT5 broker

### Build the Docker Image

```bash
cd CMB
docker build -t ciphertrade/mt5-bridge:latest -f docker/Dockerfile .
```

### Docker Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `ACCOUNT_ID` | Account UUID | `a1b2c3d4-e5f6-...` |
| `AUTH_TOKEN` | One-time registration token | `pJdWQcvf...` |
| `GATEWAY_URL` | Gateway base URL | `https://gateway.example.com` |

## Protocol

JSON over WebSocket, matching the Rust `BridgeCommand` / `BridgeResponse` enums (serde `tag = "type"`, `content = "data"`).

**Command (gateway → DLL):**

```json
{"request_id":"uuid","type":"PlaceOrder","data":{"symbol":"EURUSD","side":"buy","order_type":"market","volume":0.1}}
```

**Response (DLL → gateway):**

```json
{"type":"OrderResult","data":{"request_id":"uuid","ticket":12345,"success":true,"error":null}}
```

**Tick push (DLL → gateway):**

```json
{"type":"Tick","data":{"symbol":"EURUSD","bid":1.1234,"ask":1.1236,"last":0.0,"volume":0,"time":1710000000000}}
```

**Credentials delivery (gateway → DLL):**

```json
{"request_id":"uuid","type":"credentials","data":{"mt5_login":"12345","mt5_password":"secret","mt5_server":"Demo-Server"}}
```

**Registration (DLL → gateway, on connect):**

```json
{"type":"register","account_id":"a1b2c3d4-...","version":"2.0.0"}
```

## Supported Commands

| Command | Direction | Description |
|---------|-----------|-------------|
| `Ping` / `Pong` | Both | Heartbeat |
| `credentials` | Gateway → DLL | Deliver MT5 login credentials |
| `PlaceOrder` | Gateway → DLL | Execute market/limit/stop order |
| `CloseOrder` | Gateway → DLL | Close position by ticket |
| `ModifyOrder` | Gateway → DLL | Modify SL/TP |
| `GetAccountInfo` | Gateway → DLL | Balance, equity, margin |
| `GetPositions` | Gateway → DLL | Open positions list |
| `GetOrders` | Gateway → DLL | Pending orders list |
| `GetSymbolInfo` | Gateway → DLL | Symbol specifications |
| `GetHistory` | Gateway → DLL | OHLCV bar data |
| `Subscribe` | Gateway → DLL | Subscribe to symbol ticks |
| `Unsubscribe` | Gateway → DLL | Unsubscribe from symbol |
| `Tick` | DLL → Gateway | Real-time tick data |
| `Candle` | DLL → Gateway | Real-time candle updates |

## Project Structure

```
CMB/
├── dll/                              # C++ Bridge DLL
│   ├── CMakeLists.txt                # Build config (auto-downloads deps)
│   ├── include/
│   │   ├── cipher_bridge.h           # Public DLL API (exports)
│   │   ├── websocket_client.h        # WebSocket++ TLS client
│   │   ├── types_internal.h          # Thread-safe queues, subscription tracker
│   │   ├── protocol.h                # JSON serialization
│   │   └── nlohmann/
│   │       └── json.hpp              # JSON library (included in repo)
│   ├── src/
│   │   ├── dllmain.cpp               # DLL entry + all exported functions
│   │   ├── websocket_client.cpp      # WebSocket connection, TLS, reconnection
│   │   └── protocol.cpp              # JSON command/response builders
│   ├── third_party/                  # Auto-downloaded by CMake
│   │   ├── websocketpp/              # WebSocket++ 0.8.2
│   │   └── asio/                     # Standalone Asio 1.28.0
│   └── build/
│       └── Release/
│           └── CipherBridge.dll      # Compiled DLL (x64)
├── mql5/
│   ├── Experts/
│   │   └── CipherBridgeEA.mq5       # Expert Advisor (runs in MT5)
│   └── Include/
│       └── CipherBridge.mqh          # DLL function imports for MQL5
├── docker/
│   ├── Dockerfile                    # Wine + MT5 + DLL container image
│   ├── docker-compose.yml            # For local testing
│   ├── entrypoint.sh                 # Container startup script
│   └── launcher.py                   # Gateway registration + config writer
├── BUILD.md                          # Detailed build instructions
└── README.md                         # This file
```

## Dependencies

| Library | Version | Source | Purpose |
|---------|---------|--------|---------|
| WebSocket++ | 0.8.2 | Auto-downloaded | WebSocket client (TLS) |
| Asio | 1.28.0 | Auto-downloaded | Async I/O (standalone, no Boost) |
| OpenSSL | 3.x | Manual install (Windows) | TLS for wss:// connections |
| nlohmann/json | 3.x | Included in repo | JSON parsing + serialization |
| Windows SDK | 10+ | VS Build Tools | Win32 APIs |

## Technical Notes

- The DLL is statically linked against MSVC CRT (`/MT`) — ships as a single file with no runtime dependencies
- WebSocket connection uses TLS 1.2+ with `verify_none` (configurable in `websocket_client.cpp`)
- Subscription tracking at the DLL level — ticks for unsubscribed symbols are dropped before serialization
- Thread-safe queues with `std::mutex` + `std::condition_variable` — command queue has timeout-based polling
- Reconnection with exponential backoff: 1s, 2s, 4s, 8s, 16s, 30s (capped), up to 10 attempts
- Response sender runs in a dedicated thread — drains queue on shutdown
- PIMPL pattern hides WebSocket++ headers from the public API — compile times stay fast

## Related Repositories

- **[CMG Gateway](https://github.com/KAPKEPOT/CMG)** — Rust/axum trading API server
- **[FX Signal Copier](https://github.com/KAPKEPOT/fx-signal-copier)** — Telegram bot frontend

---

<div align="center">

**Built with ❤️ by [KAPKEPOT](https://github.com/KAPKEPOT)**

</div>
