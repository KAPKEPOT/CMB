# Building CipherBridge DLL

Step-by-step guide to compile the CipherBridge DLL on Windows. The DLL is a C++ WebSocket bridge that runs inside MetaTrader 5 and connects to the CipherTrade Gateway.

## Prerequisites

### 1. Visual Studio Build Tools

Download and install from: https://visualstudio.microsoft.com/downloads/#build-tools-for-visual-studio-2022

During installation, select the **"C++ build tools"** workload. This installs:
- MSVC compiler (`cl.exe`)
- CMake (bundled)
- NMake
- Windows SDK

### 2. OpenSSL (Win64 Full)

Download the **full** version (not Light) from: https://slproweb.com/products/Win32OpenSSL.html

- Choose **"Win64 OpenSSL v3.x.x"** — the one that says ~250MB, not ~5MB
- Install to the default path: `C:\Program Files\OpenSSL-Win64`
- The "Light" version does not include development headers and libraries

### 3. Git

Download from: https://git-scm.com/download/win

## Build Steps

### 1. Clone the repository

```cmd
cd C:\Users\Administrator
git clone https://github.com/KAPKEPOT/CMB.git
cd CMB
```

### 2. Open the correct terminal

From the Start Menu, open:

**"x64 Native Tools Command Prompt for VS 2022"** (or VS 2025)

The title bar must show `x64 Native Tools`. Verify the environment says:

```
[vcvarsall.bat] Environment initialized for: 'x64'
```

**Do NOT use:**
- Regular Command Prompt or PowerShell (no compiler)
- x64_x86 Cross Tools (builds 32-bit — MT5 requires 64-bit)
- x86 Native Tools (builds 32-bit)

### 3. Build

```cmd
cd C:\Users\Administrator\CMB\dll
mkdir build
cd build
cmake .. -G "NMake Makefiles"
nmake
```

CMake will automatically:
- Download WebSocket++ 0.8.2
- Download Asio 1.28.0
- Find OpenSSL at `C:\Program Files\OpenSSL-Win64`
- Configure the build with C++17

### 4. Verify

```cmd
dir CipherBridge.dll
```

Expected output: `CipherBridge.dll` (~5MB)

### 5. Copy to Release directory

```cmd
mkdir ..\build\Release
copy CipherBridge.dll ..\build\Release\
```

### 6. Commit and push

```cmd
cd C:\Users\Administrator\CMB
git add dll/build/Release/CipherBridge.dll
git commit -m "Add compiled bridge DLL (x64)"
git push
```

## Clean Rebuild

If you need to start fresh (e.g., after changing CMakeLists.txt):

```cmd
cd C:\Users\Administrator\CMB\dll
rd /s /q build
mkdir build
cd build
cmake .. -G "NMake Makefiles"
nmake
```

Always delete the entire `build` directory — CMake caches the generator choice and won't switch without a clean start.

## Troubleshooting

### "OpenSSL not found"

You installed the Light version. Uninstall it (Control Panel → Programs → Uninstall) and install the full version (~250MB) from https://slproweb.com/products/Win32OpenSSL.html.

Verify:
```cmd
dir "C:\Program Files\OpenSSL-Win64\lib\*.lib"
```

Should show `libssl.lib` and `libcrypto.lib`.

### "MT5 requires a 64-bit build"

You opened the wrong terminal. Close it and open **"x64 Native Tools Command Prompt"** from the Start Menu. The banner must say `Environment initialized for: 'x64'`, not `x64_x86`.

### "MAKEFILE not found" after cmake

CMake configuration failed (check the output above the nmake error). Common causes:
- OpenSSL not found (see above)
- Wrong generator — always use `"NMake Makefiles"` with quotes
- Stale cache — delete the `build` directory and start fresh

### "'cmake' is not recognized"

You're not in the Visual Studio developer terminal. CMake is bundled with VS Build Tools and only available in the developer command prompts.

### Macro redefinition warnings (C4005)

Harmless. `ASIO_STANDALONE` and `WIN32_LEAN_AND_MEAN` are defined in both CMakeLists.txt and source files. The build succeeds — these are just warnings, not errors.

### "websocketpp::connection_hdl redefinition" (C2371)

The forward declarations in `websocket_client.h` conflict with WebSocket++'s actual types. The fix (already applied): replace the forward declaration block with:

```cpp
#include <memory>
namespace websocketpp {
    using connection_hdl = std::weak_ptr<void>;
}
```

### "'ERROR': Windows macro collision"

The `ERROR` token in `enum class MessageType` collides with `#define ERROR 0` from `wingdi.h`. The fix (already applied): rename to `MSG_ERROR` in `websocket_client.h` and all references in `websocket_client.cpp`.

## Architecture

```
CipherBridge.dll (this build)
    │
    ├── WebSocket++ (TLS client, connects to gateway)
    ├── Asio (standalone, async I/O)
    ├── OpenSSL (TLS/SSL for wss:// connections)
    └── nlohmann/json (JSON protocol)

MT5 Terminal loads DLL via Expert Advisor (CipherBridgeEA.mq5)
    │
    └── Connects OUTBOUND to CMG Gateway at wss://gateway:port/bridge/ws
```

## Dependencies

| Library | Version | Source | Purpose |
|---------|---------|--------|---------|
| WebSocket++ | 0.8.2 | Auto-downloaded by CMake | WebSocket client |
| Asio | 1.28.0 | Auto-downloaded by CMake | Async I/O (standalone, no Boost) |
| OpenSSL | 3.x | Manual install | TLS for wss:// |
| nlohmann/json | 3.x | Included in repo (`include/nlohmann/json.hpp`) | JSON parsing |
| Windows SDK | 10+ | Included with VS Build Tools | Win32 APIs |
