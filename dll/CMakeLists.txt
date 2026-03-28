# cipher-mt5-bridge/dll/CMakeLists.txt
cmake_minimum_required(VERSION 3.16)
project(CipherBridge LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Force 64-bit
if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
    message(FATAL_ERROR "MT5 requires a 64-bit build. Use -A x64 with Visual Studio generator.")
endif()

# Third-party dependency paths
set(THIRD_PARTY_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party)
set(WEBSOCKETPP_INCLUDE_DIR ${THIRD_PARTY_DIR}/websocketpp)
set(ASIO_INCLUDE_DIR ${THIRD_PARTY_DIR}/asio)

# Download WebSocket++ if not present
if(NOT EXISTS ${WEBSOCKETPP_INCLUDE_DIR}/websocketpp/config/asio_client.hpp)
    message(STATUS "Downloading WebSocket++...")
    file(DOWNLOAD 
        https://github.com/zaphoyd/websocketpp/archive/refs/tags/0.8.2.tar.gz
        ${CMAKE_BINARY_DIR}/websocketpp.tar.gz
        SHOW_PROGRESS)
    execute_process(COMMAND ${CMAKE_COMMAND} -E tar xzf ${CMAKE_BINARY_DIR}/websocketpp.tar.gz
                    WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
    file(MAKE_DIRECTORY ${THIRD_PARTY_DIR})
    file(RENAME ${CMAKE_BINARY_DIR}/websocketpp-0.8.2 ${WEBSOCKETPP_INCLUDE_DIR})
endif()

# Download Asio if not present
if(NOT EXISTS ${ASIO_INCLUDE_DIR}/asio.hpp)
    message(STATUS "Downloading Asio...")
    file(DOWNLOAD 
        https://github.com/chriskohlhoff/asio/archive/refs/tags/asio-1-28-0.tar.gz
        ${CMAKE_BINARY_DIR}/asio.tar.gz
        SHOW_PROGRESS)
    execute_process(COMMAND ${CMAKE_COMMAND} -E tar xzf ${CMAKE_BINARY_DIR}/asio.tar.gz
                    WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
    file(MAKE_DIRECTORY ${ASIO_INCLUDE_DIR})
    # Asio headers are inside asio-asio-1-28-0/asio/include/
    file(GLOB ASIO_HEADERS "${CMAKE_BINARY_DIR}/asio-asio-1-28-0/asio/include/*")
    foreach(HEADER ${ASIO_HEADERS})
        get_filename_component(FNAME ${HEADER} NAME)
        if(NOT EXISTS ${ASIO_INCLUDE_DIR}/${FNAME})
            file(RENAME ${HEADER} ${ASIO_INCLUDE_DIR}/${FNAME})
        endif()
    endforeach()
endif()

# Find OpenSSL (required for wss:// TLS connections)
# On Windows: install via vcpkg, or set OPENSSL_ROOT_DIR manually
# vcpkg: vcpkg install openssl:x64-windows-static
# Manual: set -DOPENSSL_ROOT_DIR=C:/OpenSSL-Win64
find_package(OpenSSL QUIET)
if(NOT OPENSSL_FOUND)
    # Try common Windows install paths
    set(OPENSSL_SEARCH_PATHS
        "C:/OpenSSL-Win64"
        "C:/Program Files/OpenSSL-Win64"
        "C:/Program Files/OpenSSL"
        "$ENV{VCPKG_ROOT}/installed/x64-windows-static"
        "$ENV{VCPKG_ROOT}/installed/x64-windows"
    )
    foreach(SEARCH_PATH ${OPENSSL_SEARCH_PATHS})
        if(EXISTS "${SEARCH_PATH}/include/openssl/ssl.h")
            set(OPENSSL_ROOT_DIR ${SEARCH_PATH})
            find_package(OpenSSL REQUIRED)
            break()
        endif()
    endforeach()
    
    if(NOT OPENSSL_FOUND)
        message(FATAL_ERROR 
            "OpenSSL not found. Required for wss:// connections.\n"
            "Install via one of:\n"
            "  1. vcpkg install openssl:x64-windows-static\n"
            "  2. Download from https://slproweb.com/products/Win32OpenSSL.html (Win64 full)\n"
            "  3. Set -DOPENSSL_ROOT_DIR=C:/path/to/openssl")
    endif()
endif()

message(STATUS "OpenSSL found: ${OPENSSL_VERSION}")
message(STATUS "OpenSSL include: ${OPENSSL_INCLUDE_DIR}")

# Sources
set(SOURCES
    src/dllmain.cpp
    src/websocket_client.cpp
    src/protocol.cpp
)

# Create DLL
add_library(CipherBridge SHARED ${SOURCES})

# Include paths
target_include_directories(CipherBridge PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${WEBSOCKETPP_INCLUDE_DIR}
    ${ASIO_INCLUDE_DIR}
    ${OPENSSL_INCLUDE_DIR}
)

# Preprocessor definitions
target_compile_definitions(CipherBridge PRIVATE
    CIPHERBRIDGE_EXPORTS
    WIN32_LEAN_AND_MEAN
    _CRT_SECURE_NO_WARNINGS
    NOMINMAX
    ASIO_STANDALONE
    ASIO_HAS_STD_SHARED_PTR
    _WEBSOCKETPP_CPP11_STL_
)

# Link libraries
target_link_libraries(CipherBridge PRIVATE 
    ws2_32 
    Crypt32 
    OpenSSL::SSL 
    OpenSSL::Crypto
)

# MSVC-specific flags
if(MSVC)
    set_property(TARGET CipherBridge PROPERTY
        MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    target_compile_options(CipherBridge PRIVATE
        $<$<CONFIG:Release>:/O2 /Oi /GL /GS->
        /bigobj
        /std:c++17
    )
    target_link_options(CipherBridge PRIVATE
        $<$<CONFIG:Release>:/LTCG /OPT:REF /OPT:ICF>
    )
endif()

set_target_properties(CipherBridge PROPERTIES
    PREFIX ""
    OUTPUT_NAME "CipherBridge"
)

install(TARGETS CipherBridge RUNTIME DESTINATION bin)