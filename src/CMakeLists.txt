# Add external libraries as include dirs, so we can do #include "httplib" for example
include_directories(${CMAKE_SOURCE_DIR}/external/cpp-linenoise)
include_directories(${CMAKE_SOURCE_DIR}/external/nlohmann-json)

# The browser build has no filesystem, so WalletBackend and the C API write the
# wallet through the in-memory store in wasm_fs_bridge.h instead. Both include
# it directly, so it has to be on the include path for every target here, not
# only the wasm module.
if(EMSCRIPTEN)
    include_directories(${CMAKE_SOURCE_DIR}/extras/web-wallet-wasm/wasm/include)
endif()

# wallet_capi is a shared library, and every static library that ends up inside
# it has to be compiled as position independent code. Set before any target is
# declared, so it reaches all of them.
if(DEROGOLD_BUILD_WALLET_CAPI AND NOT WIN32)
    set(CMAKE_POSITION_INDEPENDENT_CODE ON)
endif()

# Show cmake where the source files are. CONFIGURE_DEPENDS makes the build
# system re-run the glob when the directory contents change, so adding or
# removing a source file does not need a manual re-configure.
file(GLOB_RECURSE Common CONFIGURE_DEPENDS common/*)
file(GLOB_RECURSE Config CONFIGURE_DEPENDS config/*)
# icon.ico is the CPack installer icon and version.h.in is configured into the
# build directory. Neither is a source file.
list(FILTER Config EXCLUDE REGEX "[.](ico|in)$")
file(GLOB_RECURSE Crypto CONFIGURE_DEPENDS crypto/*)
file(GLOB_RECURSE CryptoNoteCore CONFIGURE_DEPENDS cryptonotecore/* CryptoNoteConfig.h)

# RocksDBWrapper is the daemon's database adapter and the only thing in the
# tree that includes <rocksdb/...>. A wallet-only build does not link RocksDB,
# and on Android or Emscripten it is not there to compile against either, so
# drop it from the library rather than compiling dead code that needs headers
# this configuration never fetched.
if(NOT DEROGOLD_BUILD_EXECUTABLES)
    list(FILTER CryptoNoteCore EXCLUDE REGEX "RocksDBWrapper\\.(h|cpp)$")
endif()

# Core and the transaction pool cleaner are the daemon's, and the only two
# files left in this library that reach for the fibre dispatcher in system/ -
# which is built on epoll and has no WebAssembly implementation. A wallet
# needs neither: the two transaction helpers it used to take from Core now
# live in RawBlockTools, which depends on nothing but the serializer.
#
# Android keeps them. bionic has epoll, so the dispatcher builds there.
if(EMSCRIPTEN)
    list(FILTER CryptoNoteCore EXCLUDE REGEX "(Core|TransactionPoolCleaner)\\.(h|cpp)$")

    # Backed by a memory mapped file, so it needs system/MemoryMappedFile.h.
    # Only WalletGreen's indices use it, and WalletGreen is not part of a
    # browser build.
    list(FILTER Common EXCLUDE REGEX "FileMappedVector\\.(h|cpp)$")
endif()
file(GLOB_RECURSE CryptoNoteProtocol CONFIGURE_DEPENDS cryptonoteprotocol/*)
file(GLOB_RECURSE CryptoTest CONFIGURE_DEPENDS cryptotest/*)
file(GLOB_RECURSE Errors CONFIGURE_DEPENDS errors/*)
file(GLOB_RECURSE Http CONFIGURE_DEPENDS http/*)
file(GLOB_RECURSE JsonRpcServer CONFIGURE_DEPENDS jsonrpcserver/*)
file(GLOB_RECURSE Logging CONFIGURE_DEPENDS logging/*)
file(GLOB_RECURSE Logger CONFIGURE_DEPENDS logger/*)
file(GLOB_RECURSE miner CONFIGURE_DEPENDS miner/*)
file(GLOB_RECURSE Mnemonics CONFIGURE_DEPENDS mnemonics/*)
file(GLOB_RECURSE Nigel CONFIGURE_DEPENDS nigel/*)
file(GLOB_RECURSE NodeRpcProxy CONFIGURE_DEPENDS noderpcproxy/*)
file(GLOB_RECURSE P2p CONFIGURE_DEPENDS p2p/*)
file(GLOB_RECURSE Rpc CONFIGURE_DEPENDS rpc/*)
file(GLOB_RECURSE Serialization CONFIGURE_DEPENDS serialization/*)
file(GLOB_RECURSE SubWallets CONFIGURE_DEPENDS subwallets/*)
file(GLOB_RECURSE Transfers CONFIGURE_DEPENDS transfers/*)
file(GLOB_RECURSE TxPowServer CONFIGURE_DEPENDS txpowserver/*)
file(GLOB_RECURSE DeroGoldd CONFIGURE_DEPENDS daemon/*)
file(GLOB_RECURSE Utilities CONFIGURE_DEPENDS utilities/*)
file(GLOB_RECURSE Wallet CONFIGURE_DEPENDS wallet/*)
file(GLOB_RECURSE WalletApi CONFIGURE_DEPENDS walletapi/*)
file(GLOB_RECURSE WalletBackend CONFIGURE_DEPENDS walletbackend/*)
file(GLOB_RECURSE WalletService CONFIGURE_DEPENDS walletservice/*)
file(GLOB_RECURSE WalletUpgrader CONFIGURE_DEPENDS walletupgrader/*)
file(GLOB_RECURSE zedwallet++ CONFIGURE_DEPENDS zedwallet++/*)

if(DEROGOLD_BUILD_WALLET_CAPI)
    file(GLOB_RECURSE WalletCAPI CONFIGURE_DEPENDS walletcapi/*)
endif()

if(WIN32)
    file(GLOB_RECURSE System CONFIGURE_DEPENDS system/* platform/windows/system/*)
elseif(APPLE)
    file(GLOB_RECURSE System CONFIGURE_DEPENDS system/* platform/osx/system/* platform/posix/system/*)
else()
    file(GLOB_RECURSE System CONFIGURE_DEPENDS system/* platform/linux/system/* platform/posix/system/*)
endif()

# Group the files together in IDEs
source_group("" FILES ${Common} ${Config} ${Crypto} ${CryptoNoteCore} ${CryptoNoteProtocol} ${DeroGoldd} ${JsonRpcServer} ${Http} ${Logging} ${Logger} ${miner} ${Mnemonics} ${Nigel} ${NodeRpcProxy} ${P2p} ${Rpc} ${Serialization} ${System} ${Transfers} ${TxPowServer} ${Wallet} ${WalletApi} ${WalletBackend} ${WalletService} ${zedwallet++} ${CryptoTest} ${Errors} ${Utilities} ${WalletUpgrader} ${SubWallets})

# Define a group of files as a library to link against
add_library(Common STATIC ${Common})
add_library(Config STATIC ${Config})
add_library(Crypto STATIC ${Crypto})
add_library(CryptoNoteCore STATIC ${CryptoNoteCore})
add_library(Errors STATIC ${Errors})
add_library(Http STATIC ${Http})
add_library(Logging STATIC ${Logging})
add_library(Logger STATIC ${Logger})
add_library(Mnemonics STATIC ${Mnemonics})
add_library(Nigel STATIC ${Nigel})
add_library(Serialization STATIC ${Serialization})
add_library(SubWallets STATIC ${SubWallets})
add_library(Utilities STATIC ${Utilities})
add_library(WalletBackend STATIC ${WalletBackend})

# The daemon's half of the tree: the P2P stack, the RPC servers, the fibre
# dispatcher and the old WalletGreen wallet. None of it can be compiled for
# WebAssembly - sockets, epoll and miniupnpc have no implementation there -
# and the browser wallet calls into none of it, so it is not declared at all.
# Declaring the targets would be enough to break the build, because "make
# all" builds every target whether or not anything links it.
if(NOT EMSCRIPTEN)
    add_library(JsonRpcServer STATIC ${JsonRpcServer})
    add_library(NodeRpcProxy STATIC ${NodeRpcProxy})
    add_library(P2P STATIC ${CryptoNoteProtocol} ${P2p})
    add_library(Rpc STATIC ${Rpc})
    add_library(System STATIC ${System})
    add_library(Transfers STATIC ${Transfers})
    add_library(Wallet STATIC ${Wallet})
endif()

if(DEROGOLD_BUILD_WALLET_CAPI)
    if(EMSCRIPTEN)
        # A SHARED library under Emscripten is a side module loaded at runtime,
        # which is not what this is - the C API is linked straight into the
        # wasm module beside the exports that call it.
        add_library(wallet_capi STATIC ${WalletCAPI})
    else()
        add_library(wallet_capi SHARED ${WalletCAPI})
    endif()
endif()

# Crypto requires -O2 optimization due to its sensitivity.
if(CMAKE_C_COMPILER_ID STREQUAL "GNU" AND CMAKE_C_COMPILER_VERSION VERSION_GREATER_EQUAL "10")
    target_compile_options(Crypto PRIVATE $<$<COMPILE_LANGUAGE:C>:-O2>)
endif()

if(MSVC OR MINGW)
    set(CT_SOURCES_OS binaryinfo/cryptotest.rc)
    set(MINER_SOURCES_OS binaryinfo/miner.rc)
    set(PG_SOURCES_OS binaryinfo/service.rc)
    set(DAEMON_SOURCES_OS binaryinfo/daemon.rc)
    set(TXPOW_SERVER_SOURCES_OS binaryinfo/txpowserver.rc)
    set(WALLET_API_SOURCES_OS binaryinfo/walletapi.rc)
    set(WALLET_UPGRADER_SOURCES_OS binaryinfo/walletupgrader.rc)
    set(ZED_WALLET_SOURCES_OS binaryinfo/zedwallet.rc)
endif()

if(DEROGOLD_BUILD_EXECUTABLES)
    add_executable(cryptotest ${CryptoTest} ${CT_SOURCES_OS})
    add_executable(miner ${miner} ${MINER_SOURCES_OS})
    add_executable(TxPowServer ${TxPowServer} ${TXPOW_SERVER_SOURCES_OS})
    add_executable(WalletService ${WalletService} ${PG_SOURCES_OS})
    add_executable(DeroGoldd ${DeroGoldd} ${DAEMON_SOURCES_OS})
    add_executable(WalletApi ${WalletApi} ${WALLET_API_SOURCES_OS})
    add_executable(WalletUpgrader ${WalletUpgrader} ${WALLET_UPGRADER_SOURCES_OS})
    add_executable(zedwallet++ ${zedwallet++} ${ZED_WALLET_SOURCES_OS})
endif()

# bionic has no ucontext API. libucontext supplies getcontext, setcontext,
# makecontext and swapcontext, which the fibre dispatcher in
# platform/linux/system/ is built on; without it the link fails there and
# nowhere else, which reads as a mystery.
set(DEROGOLD_ANDROID_UCONTEXT_LIB "")

if(ANDROID)
    if(LIBUCONTEXT_ROOT AND EXISTS "${LIBUCONTEXT_ROOT}/lib/libucontext.a")
        if(EXISTS "${LIBUCONTEXT_ROOT}/include")
            target_include_directories(System PRIVATE "${LIBUCONTEXT_ROOT}/include")
        endif()

        target_link_libraries(System PUBLIC "${LIBUCONTEXT_ROOT}/lib/libucontext.a")
        set(DEROGOLD_ANDROID_UCONTEXT_LIB "${LIBUCONTEXT_ROOT}/lib/libucontext.a")
        message(STATUS "Android: linking libucontext from ${LIBUCONTEXT_ROOT}/lib/libucontext.a")
    else()
        message(FATAL_ERROR
            "An Android build needs libucontext, which was not found at:\n"
            "  ${LIBUCONTEXT_ROOT}/lib/libucontext.a\n"
            "Build it with scripts/build-libucontext-android.sh and pass "
            "-D LIBUCONTEXT_ROOT=<prefix>.")
    endif()
endif()

if(MSVC OR MINGW)
    target_link_libraries(System ws2_32)
    target_link_libraries(P2P bcrypt)

    if(DEROGOLD_BUILD_EXECUTABLES)
        # rpcrt4 in lower case: MinGW-w64 ships librpcrt4.a and the linker
        # looks for exactly that, so -lRpcrt4 fails when cross-compiling from
        # Linux. MSVC does not care either way, its filesystem being
        # case-insensitive, so one spelling serves both.
        target_link_libraries(DeroGoldd rpcrt4 ws2_32 advapi32 crypt32 gdi32 user32)
        target_link_libraries(WalletService rpcrt4 ws2_32 advapi32 crypt32 gdi32 user32)
        target_link_libraries(zedwallet++ ws2_32 advapi32 crypt32 gdi32 user32)
        target_link_libraries(WalletApi ws2_32 advapi32 crypt32 gdi32 user32)
        target_link_libraries(miner ws2_32 advapi32 crypt32 gdi32 user32)
        target_link_libraries(TxPowServer ws2_32 advapi32 crypt32 gdi32 user32)
        target_link_libraries(WalletUpgrader ws2_32 advapi32 crypt32 gdi32 user32)
    endif()

    if(DEROGOLD_BUILD_WALLET_CAPI)
        target_link_libraries(wallet_capi ws2_32 advapi32 crypt32 gdi32 user32)
    endif()
endif()

# Add the dependencies we need
target_link_libraries(Config rapidjson)
target_link_libraries(Crypto rapidjson)
if(EMSCRIPTEN)
    # P2P, Rpc and System are the daemon's half of this library, and none of
    # them can be built for WebAssembly: they want sockets, epoll and
    # miniupnpc. Naming them here would have CMake build them as dependencies
    # of the wallet even though no wallet object ever calls into them, so the
    # browser build links the parsing and crypto half only.
    target_link_libraries(CryptoNoteCore PUBLIC Common Crypto Http Logging Serialization Utilities WalletBackend rapidjson)
else()
    target_link_libraries(CryptoNoteCore PUBLIC Common Crypto Http Logging P2P Rpc Serialization System Utilities WalletBackend rapidjson)
endif()

# RocksDBWrapper.cpp lives in this library, so this is where its headers are
# needed. Under vcpkg they happened to be on the global include path and no
# link was required; now that RocksDB is an ordinary target, leaving this out
# meant the compiler fell back to whatever /usr/include/rocksdb happened to
# hold, which on most machines is a version far older than this code needs.
#
# PRIVATE on purpose: only the daemon also includes RocksDBWrapper.h, and it
# links RocksDB itself, so the C++20 requirement RocksDB carries stays with
# this target instead of spreading across the whole project.
#
# A wallet-only build has no RocksDB to link and no RocksDBWrapper compiled
# into the library either - it is filtered out of the glob above - so the
# whole dependency drops away. That is what lets the Android and WebAssembly
# wallets build: RocksDB cross-compiles to neither.
if(DEROGOLD_BUILD_EXECUTABLES)
    target_link_libraries(CryptoNoteCore PRIVATE RocksDB::rocksdb)
endif()

target_link_libraries(Errors Crypto SubWallets Utilities)
target_link_libraries(Logging Common)
target_link_libraries(Mnemonics Errors)
target_link_libraries(Nigel CryptoNoteCore Errors httplib::httplib)

# OpenSSL is absent from an Android wallet build by design; cpp-httplib then
# compiles without TLS and every https:// address is refused rather than
# silently downgraded.
if(TARGET OpenSSL::SSL)
    target_link_libraries(Nigel OpenSSL::Crypto OpenSSL::SSL)
endif()
target_link_libraries(Serialization Common Crypto)
target_link_libraries(SubWallets Common Logger rapidjson)
target_link_libraries(Utilities Common Errors rapidjson)

# The daemon-only targets, which a browser build never declares.
if(NOT EMSCRIPTEN)
    target_link_libraries(NodeRpcProxy Rpc)
    target_link_libraries(P2P CryptoNoteCore Serialization System miniupnpc::miniupnpc)
    target_link_libraries(Rpc CryptoNoteCore P2P Utilities httplib::httplib rapidjson)
    target_link_libraries(Transfers CryptoNoteCore)
    target_link_libraries(Wallet Common CryptoNoteCore NodeRpcProxy Transfers WalletBackend)
endif()
if(EMSCRIPTEN)
    # Wallet is WalletGreen, needed only to upgrade a wallet file written by a
    # version that predates this format. That path is compiled out in a
    # browser build (see WalletBackend::tryUpgradeWalletFormat), and keeping
    # the library here would drag Core.h, NodeRpcProxy and the dispatcher back
    # into the link through the back door.
    target_link_libraries(WalletBackend Config Logger Mnemonics Nigel Serialization SubWallets Utilities cryptopp::cryptopp rapidjson)
else()
    target_link_libraries(WalletBackend Config Logger Mnemonics Nigel Serialization SubWallets Utilities Wallet cryptopp::cryptopp rapidjson)
endif()

if(DEROGOLD_BUILD_EXECUTABLES)
    target_link_libraries(cryptotest Common Crypto rapidjson cxxopts::cxxopts)
    target_link_libraries(DeroGoldd CryptoNoteCore Errors System cxxopts::cxxopts OpenSSL::Crypto OpenSSL::SSL rapidjson RocksDB::rocksdb)
    target_link_libraries(miner Crypto Errors Serialization System Utilities cxxopts::cxxopts httplib::httplib OpenSSL::Crypto OpenSSL::SSL rapidjson)
    # The PoW server only parses prefixes, hashes them and serves HTTP: no
    # chain, no wallet, no P2P, and so no RocksDB either.
    target_link_libraries(TxPowServer Serialization Common Crypto Logger Config cxxopts::cxxopts httplib::httplib OpenSSL::Crypto OpenSSL::SSL rapidjson)
    target_link_libraries(WalletApi WalletBackend cxxopts::cxxopts httplib::httplib OpenSSL::Crypto OpenSSL::SSL)
    target_link_libraries(WalletService Errors JsonRpcServer Mnemonics Wallet cxxopts::cxxopts OpenSSL::Crypto OpenSSL::SSL rapidjson)
    target_link_libraries(WalletUpgrader Common Utilities WalletBackend cxxopts::cxxopts)
    target_link_libraries(zedwallet++ WalletBackend cxxopts::cxxopts OpenSSL::Crypto OpenSSL::SSL rapidjson)
endif()

if(DEROGOLD_BUILD_WALLET_CAPI)
    # PRIVATE: nothing linking the shared library should inherit these, the
    # whole point being that a caller sees the C header and nothing else.
    target_link_libraries(wallet_capi PRIVATE WalletBackend rapidjson)

    if(TARGET OpenSSL::SSL)
        target_link_libraries(wallet_capi PRIVATE OpenSSL::Crypto OpenSSL::SSL)
    endif()

    # A shared library does not inherit symbols from a static archive the way
    # an executable does, so libucontext has to be named here as well as on
    # System, or the link fails on getcontext/swapcontext/makecontext.
    if(ANDROID AND DEROGOLD_ANDROID_UCONTEXT_LIB)
        target_link_libraries(wallet_capi PRIVATE "${DEROGOLD_ANDROID_UCONTEXT_LIB}")
    endif()

    set_target_properties(wallet_capi PROPERTIES
        OUTPUT_NAME "wallet_capi"
        C_VISIBILITY_PRESET hidden
        CXX_VISIBILITY_PRESET hidden
        VISIBILITY_INLINES_HIDDEN ON)

    # Only what wallet_capi.h declares is exported; everything else stays
    # internal, which keeps the library small and its surface honest.
    target_compile_definitions(wallet_capi PRIVATE WALLET_CAPI_BUILDING)
endif()

if(EMSCRIPTEN AND DEROGOLD_BUILD_WALLET_WASM)
    # The browser wallet. One exported entry point taking a JSON request and
    # returning a JSON reply; see extras/web-wallet-wasm/.
    add_executable(wallet_wasm
        ${CMAKE_SOURCE_DIR}/extras/web-wallet-wasm/wasm/src/wallet_wasm_exports.cpp)

    target_link_libraries(wallet_wasm PRIVATE wallet_capi WalletBackend rapidjson)

    target_include_directories(wallet_wasm PRIVATE
        ${CMAKE_SOURCE_DIR}/include
        ${CMAKE_SOURCE_DIR}/extras/web-wallet-wasm/wasm/include)

    # Emits wallet_wasm.js beside wallet_wasm.wasm. The name matters: the glue
    # script asks for the .wasm by the name it was linked under, so the pair
    # cannot be renamed afterwards, and extras/web-wallet/web/ loads exactly
    # these two.
    set_target_properties(wallet_wasm PROPERTIES
        OUTPUT_NAME "wallet_wasm"
        SUFFIX ".js")

    # MODULARIZE gives the page a factory to call rather than a module that
    # starts itself on load, which is what lets the worker decide when to
    # bring it up. ENVIRONMENT drops the Node and shell paths from the glue.
    target_link_options(wallet_wasm PRIVATE
        -fexceptions
        "-sMODULARIZE=1"
        # The module factory. Named ...Module to keep it distinct from the
        # DeroGoldWallet object wallet_bridge.js installs on the page: one is
        # the raw Emscripten module inside the worker, the other is the API the
        # app calls.
        "-sEXPORT_NAME=DeroGoldWalletModule"
        "-sENVIRONMENT=web,worker"
        "-sEXPORTED_FUNCTIONS=['_wallet_wasm_request','_malloc','_free']"
        "-sEXPORTED_RUNTIME_METHODS=['ccall','cwrap','UTF8ToString','stringToUTF8','lengthBytesUTF8','HEAP32','HEAPU8']"
        "-sALLOW_MEMORY_GROWTH=1"
        "-sINITIAL_MEMORY=64MB"
        # The fibre dispatcher in src/platform/linux/system/ runs coroutines on
        # their own stacks and the block handlers recurse, so the default 64KB
        # is nowhere near enough.
        "-sSTACK_SIZE=4MB"
        # wallet_wasm_request returns after the module is up and is called
        # again and again; letting the runtime exit after main() would tear
        # everything down on the first call.
        "-sEXIT_RUNTIME=0"
        "-sASSERTIONS=1")

    if(DEROGOLD_WASM_PTHREADS)
        # -pthread itself is on the global flags: shared memory has to match
        # across every object in the link. Only the pool sizing is local.
        #
        # Every worker in the pool is built at startup, because building one
        # later needs the page's main thread and the calls into this module
        # block it. The pool therefore has to cover the peak: the synchroniser
        # loop, the block downloader and its parallel download windows, Nigel's
        # background refresh, and the block-processing threads, which
        # resolve_sync_threads() in wallet_wasm_exports.cpp caps at six. Raise
        # that cap and this together, or a thread will wait on one that cannot
        # be created and simply hang.
        target_link_options(wallet_wasm PRIVATE
            -pthread
            "-sPTHREAD_POOL_SIZE=20"
            # Warn rather than abort if the peak is ever misjudged: a slow
            # wallet beats a dead one.
            "-sPTHREAD_POOL_SIZE_STRICT=1")
    endif()

    add_dependencies(wallet_wasm version)
endif()

# Add dependencies means we have to build the latter before we build the former
# In this case it's because we need to have the current version name rather
# than a cached one
if(NOT EMSCRIPTEN)
    add_dependencies(JsonRpcServer version)
    add_dependencies(P2P version)
    add_dependencies(Rpc version)
endif()

if(DEROGOLD_BUILD_EXECUTABLES)
    add_dependencies(cryptotest version)
    add_dependencies(miner version)
    add_dependencies(TxPowServer version)
    add_dependencies(DeroGoldd version)
    add_dependencies(WalletUpgrader version)
    add_dependencies(WalletApi version)
    add_dependencies(WalletService version)
    add_dependencies(zedwallet++ version)
endif()

if(DEROGOLD_BUILD_WALLET_CAPI)
    add_dependencies(wallet_capi version)
endif()

# Finally build the binaries
if(DEROGOLD_BUILD_EXECUTABLES)
    set_property(TARGET DeroGoldd PROPERTY OUTPUT_NAME "DeroGoldd")
    set_property(TARGET zedwallet++ PROPERTY OUTPUT_NAME "degwallet")
    set_property(TARGET WalletService PROPERTY OUTPUT_NAME "DeroGold-service")
    set_property(TARGET miner PROPERTY OUTPUT_NAME "miner")
    set_property(TARGET TxPowServer PROPERTY OUTPUT_NAME "DeroGold-txpow-server")
    set_property(TARGET cryptotest PROPERTY OUTPUT_NAME "cryptotest")
    set_property(TARGET WalletApi PROPERTY OUTPUT_NAME "wallet-api")
    set_property(TARGET WalletUpgrader PROPERTY OUTPUT_NAME "degwallet-upgrader")

    # Additional make targets, can be used to build a subset of the targets
    # e.g. make pool will build only DeroGoldd and service
    add_custom_target(pool DEPENDS DeroGoldd WalletService)
    add_custom_target(solominer DEPENDS DeroGoldd zedwallet++ miner)
    add_custom_target(cli DEPENDS DeroGoldd zedwallet++)
    add_custom_target(cli-wallet DEPENDS zedwallet++)
    add_custom_target(txpow-server DEPENDS TxPowServer)

    install(TARGETS DeroGoldd zedwallet++ WalletService miner WalletApi WalletUpgrader TxPowServer)
endif()

if(DEROGOLD_BUILD_WALLET_CAPI)
    install(TARGETS wallet_capi)
endif()

# CPack
set(CPACK_PACKAGE_NAME "DeroGold")
set(CPACK_PACKAGE_VENDOR "The DeroGold Developers")
set(CPACK_PACKAGE_ICON "${CMAKE_SOURCE_DIR}/src/config/icon.ico")
set(CPACK_PACKAGE_DIRECTORY "${CMAKE_BINARY_DIR}/Packaging")
set(CPACK_PACKAGE_CONTACT "goldmember@derogold.com")
set(CPACK_PACKAGE_FILE_NAME "${CPACK_PACKAGE_NAME}-${SET_PACKAGE_OUTPUT_SUFFIX}")

if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Windows")
    set(CPACK_GENERATOR "ZIP")
elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL "Linux")
    set(CPACK_GENERATOR "TGZ;DEB")
elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin")
    set(CPACK_GENERATOR "TGZ")
endif()

include(CPack)

# CTest
if(DEROGOLD_BUILD_EXECUTABLES)
    add_test(NAME CryptoTest COMMAND ${CMAKE_BINARY_DIR}/src/cryptotest)
endif()
