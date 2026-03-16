# cipher-mt5-bridge/dll/CMakeLists.txt
# Build the CipherBridge DLL for MT5
#
# Prerequisites:
#   - MSVC (Visual Studio 2019/2022) — MT5 requires 64-bit MSVC DLLs
#   - nlohmann/json: place json.hpp in dll/include/nlohmann/
#     Download: https://github.com/nlohmann/json/releases (single_include/nlohmann/json.hpp)
#
# Build:
#   mkdir build && cd build
#   cmake .. -G "Visual Studio 17 2022" -A x64
#   cmake --build . --config Release
#
# Output:
#   build/Release/CipherBridge.dll → copy to MT5_DATA/MQL5/Libraries/

cmake_minimum_required(VERSION 3.16)
project(CipherBridge LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Force 64-bit (MT5 is 64-bit only)
if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
    message(FATAL_ERROR "MT5 requires a 64-bit build. Use -A x64 with Visual Studio generator.")
endif()

# Sources
set(SOURCES
    src/dllmain.cpp
    src/tcp_server.cpp
    src/protocol.cpp
)

# Create DLL
add_library(CipherBridge SHARED ${SOURCES})

# Include paths
target_include_directories(CipherBridge PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

# Preprocessor definitions
target_compile_definitions(CipherBridge PRIVATE
    CIPHERBRIDGE_EXPORTS
    WIN32_LEAN_AND_MEAN
    _CRT_SECURE_NO_WARNINGS
    NOMINMAX
)

# Link Winsock
target_link_libraries(CipherBridge PRIVATE ws2_32)

# MSVC-specific flags
if(MSVC)
    # Static link CRT so the DLL has no external dependencies
    set_property(TARGET CipherBridge PROPERTY
        MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>"
    )
    # Optimization flags for Release
    target_compile_options(CipherBridge PRIVATE
        $<$<CONFIG:Release>:/O2 /Oi /GL /GS->
    )
    target_link_options(CipherBridge PRIVATE
        $<$<CONFIG:Release>:/LTCG /OPT:REF /OPT:ICF>
    )
endif()

# Output name without lib prefix
set_target_properties(CipherBridge PROPERTIES
    PREFIX ""
    OUTPUT_NAME "CipherBridge"
)

# Install target (optional)
install(TARGETS CipherBridge
    RUNTIME DESTINATION bin
    LIBRARY DESTINATION lib
)