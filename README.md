# CipherBridge — MT5 ↔ CMG Gateway Bridge

Low-latency C++ DLL + MQL5 EA that bridges the MetaTrader 5 terminal to the
Cipher MT5 Gateway (CMG) Rust service over TCP.

## Architecture

```
CMG (Rust/Axum)  ←— TCP (JSON) —→  CipherBridge.dll  ←— fn calls —→  EA (MQL5)
    port 8080                           port 8765                      MT5 Terminal
```

The EA runs inside the MT5 terminal and has native access to `OrderSend`,
`CopyRates`, `SymbolInfoTick`, etc. It calls into the DLL on every tick and
timer event. The DLL manages the TCP connection, JSON serialization, and
thread-safe command/response queuing.

## Data Flow

**Tick (terminal → gateway):**
MT5 fires `OnTick` → EA calls `BridgePushTick()` → DLL serializes to JSON →
TCP write → CMG reader task picks it up → routes to subscribed users.

**Order (gateway → terminal):**
CMG sends `PlaceOrder` JSON → DLL TCP reader parses → command queue →
EA's `OnTimer` calls `BridgePollCommand()` → EA calls `OrderSend()` →
EA calls `BridgePushResponse()` → DLL serializes → TCP write → CMG resolves.

## Latency

- Tick delivery: sub-millisecond (OnTick → DLL → TCP, no queue hop)
- Command round-trip: ~10-25ms (bounded by `OnTimer` polling interval)
- Configurable timer: default 10ms via `InpTimerMs` EA input

## Prerequisites

- **Visual Studio 2019/2022** with C++ desktop workload (MSVC x64)
- **CMake 3.16+**
- **nlohmann/json** single header:
  Download from https://github.com/nlohmann/json/releases
  Place `json.hpp` at `dll/include/nlohmann/json.hpp`
- **MetaTrader 5** terminal (64-bit)

## Build the DLL

```powershell
cd dll

# Download nlohmann/json if not present
mkdir include\nlohmann -ErrorAction SilentlyContinue
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/nlohmann/json/develop/single_include/nlohmann/json.hpp" -OutFile "include\nlohmann\json.hpp"

# Build
mkdir build
cd build
cmake .. -G "Visual Studio 17 2022" -A x64
cmake --build . --config Release
```

Output: `build/Release/CipherBridge.dll`

## Deploy

### DLL

Copy `CipherBridge.dll` to your MT5 data folder:

```
%APPDATA%\MetaQuotes\Terminal\<INSTANCE_ID>\MQL5\Libraries\CipherBridge.dll
```

Find your instance ID in MT5: File → Open Data Folder.

### EA

Copy the MQL5 files:

```
mql5/Include/CipherBridge.mqh  →  MQL5\Include\CipherBridge.mqh
mql5/Experts/CipherBridgeEA.mq5  →  MQL5\Experts\CipherBridgeEA.mq5
```

### Compile the EA

In MetaEditor (F4 from MT5), open `CipherBridgeEA.mq5` and press F7 to compile.

### Attach to Chart

1. In MT5, go to **Tools → Options → Expert Advisors**
2. Check **"Allow DLL imports"**
3. Drag `CipherBridgeEA` onto any chart
4. Set inputs:
   - `InpBridgePort`: TCP port (default 8765, must match CMG config)
   - `InpTimerMs`: Poll interval in ms (default 10)
   - `InpLogVerbose`: Enable detailed logging
5. Click OK — the EA will start listening for the CMG gateway connection

### Start CMG

```bash
# Set bridge host/port to match
MT5_BRIDGE_HOST=127.0.0.1 MT5_BRIDGE_PORT=8765 cargo run
```

CMG connects to the DLL's TCP server. You should see:
- EA log: "Gateway client connected"
- CMG log: "Connected to MT5 bridge"

## Protocol

Newline-delimited JSON over TCP, matching the Rust `BridgeCommand` /
`BridgeResponse` enums (serde `tag = "type"`, `content = "data"`).

**Command envelope (CMG → DLL):**
```json
{"request_id":"uuid","type":"PlaceOrder","data":{"symbol":"EURUSD","side":"buy","order_type":"market","volume":0.1}}
```

**Response (DLL → CMG):**
```json
{"type":"OrderResult","data":{"request_id":"uuid","ticket":12345,"success":true,"error":null}}
```

**Push message (DLL → CMG):**
```json
{"type":"Tick","data":{"symbol":"EURUSD","bid":1.1234,"ask":1.1236,"last":0.0,"volume":0,"time":1710000000000}}
```

## File Structure

```
cipher-mt5-bridge/
├── dll/
│   ├── CMakeLists.txt                 # Build config
│   ├── include/
│   │   ├── cipher_bridge.h            # Public DLL API (exports)
│   │   ├── types_internal.h           # Queues, subscription tracker
│   │   ├── tcp_server.h               # TCP server class
│   │   ├── protocol.h                 # JSON serialization
│   │   └── nlohmann/
│   │       └── json.hpp               # (download separately)
│   └── src/
│       ├── dllmain.cpp                # DLL entry + exported functions
│       ├── tcp_server.cpp             # TCP implementation
│       └── protocol.cpp               # Protocol implementation
├── mql5/
│   ├── Experts/
│   │   └── CipherBridgeEA.mq5        # Expert Advisor
│   └── Include/
│       └── CipherBridge.mqh           # DLL imports + helpers
└── README.md
```

## Notes

- The DLL is statically linked against MSVC CRT (`/MT`) so it ships as a
  single file with no runtime dependencies.
- TCP_NODELAY is set on the client socket to minimize send latency.
- The EA processes up to 32 commands per timer tick to prevent queue buildup
  during bursts.
- Subscription tracking happens at the DLL level — ticks for unsubscribed
  symbols are dropped before serialization, not after.
- The DLL accepts one client connection at a time. If CMG reconnects, the
  old connection is replaced.
