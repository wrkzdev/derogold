cmake_minimum_required(VERSION 3.15)
cmake_policy(SET CMP0091 NEW)

if(CMAKE_VERSION VERSION_GREATER_EQUAL "3.30")
    cmake_policy(SET CMP0167 NEW)
endif()

message(CHECK_START "Finding CMAKE_SOURCE_DIR")
file(TO_CMAKE_PATH "${CMAKE_SOURCE_DIR}" CMAKE_SOURCE_DIR_NORMAL)
message(CHECK_PASS "${CMAKE_SOURCE_DIR_NORMAL}")

message(CHECK_START "Finding CMAKE_BINARY_DIR")
file(TO_CMAKE_PATH "${CMAKE_BINARY_DIR}" CMAKE_BINARY_DIR_NORMAL)

if("${CMAKE_SOURCE_DIR_NORMAL}" STREQUAL "${CMAKE_BINARY_DIR_NORMAL}")
    message(CHECK_FAIL "${CMAKE_BINARY_DIR_NORMAL}")
    message(FATAL_ERROR "CMAKE_BINARY_DIR cannot be the same as CMAKE_SOURCE_DIR.")
else()
    message(CHECK_PASS "${CMAKE_BINARY_DIR_NORMAL}")
endif()

project(DeroGold VERSION 1.0.1.0 HOMEPAGE_URL https://derogold.com LANGUAGES C CXX ASM)

# Dependencies come from three places, no package manager involved:
#
#   1. Libraries vendored under external/ and built with the project:
#      rapidjson, cpp-httplib, cxxopts, nlohmann-json and cpp-linenoise are
#      header-only; Crypto++ and miniupnpc are compiled from their checked-in
#      sources, as are zstd and RocksDB. All of them are pinned by being in
#      the tree, so none can drift underneath a build and none has to be
#      installed first.
#   2. OpenSSL, taken from the system. It is large, ubiquitous and
#      packaged everywhere. See BUILDING.md.
#   3. RocksDB, which is built from source by default because the version
#      packaged by most distributions is older than this code requires.
#      Set -D DEROGOLD_SYSTEM_ROCKSDB=ON to use the system one instead.

option(DEROGOLD_SYSTEM_ROCKSDB
    "Link the system RocksDB instead of building it from source" OFF)

# The daemon and the CLI tools. Turned off when building only the wallet
# library for an application to link, which needs none of them and would
# otherwise pay for the whole daemon - RocksDB included - to be compiled.
option(DEROGOLD_BUILD_EXECUTABLES
    "Build the daemon and the command line tools" ON)

# libwallet_capi, the C interface to the wallet backend that the Flutter
# wallets under extras/ load through dart:ffi. See include/walletcapi.
option(DEROGOLD_BUILD_WALLET_CAPI
    "Build the wallet C API shared library" OFF)

# The WebAssembly build of the same wallet, for the browser wallet under
# extras/web-wallet. Needs the Emscripten toolchain and the C API.
option(DEROGOLD_BUILD_WALLET_WASM
    "Build the wallet WASM module (Emscripten)" OFF)

# Threads in the browser. The wallet synchroniser has no single-step mode, so
# the background threads are what make a browser wallet sync at all - which is
# why this defaults ON, and why the page has to be served with
# Cross-Origin-Opener-Policy and Cross-Origin-Embedder-Policy.
option(DEROGOLD_WASM_PTHREADS
    "Build the WASM module with pthreads (required for syncing)" ON)

# Android defaults: a wallet library and nothing else.
option(DEROGOLD_ANDROID_PROFILE
    "Apply Android build defaults (wallet library only)" OFF)

# The NDK ships no OpenSSL. Without it cpp-httplib has no TLS, so the wallet
# reaches its node over plain HTTP - which is what the mobile wallet does.
option(DEROGOLD_ANDROID_DISABLE_OPENSSL
    "Do not look for or link OpenSSL on Android" ON)

# bionic has no getcontext/swapcontext/makecontext, which the fibre dispatcher
# in src/platform/linux/system/ needs. Build them with
# scripts/build-libucontext-android.sh and point this at the result.
set(LIBUCONTEXT_ROOT "" CACHE PATH
    "Root of a prebuilt libucontext for Android (expects include/ and lib/libucontext.a)")

# Both wallet-only profiles turn the daemon and the CLI tools off: they need
# RocksDB and a P2P stack that neither target can build.
if(DEROGOLD_ANDROID_PROFILE)
    message(STATUS "Android profile: building the wallet library only")
    set(DEROGOLD_BUILD_EXECUTABLES OFF CACHE BOOL "Build the daemon and the command line tools" FORCE)
endif()

if(EMSCRIPTEN AND DEROGOLD_BUILD_WALLET_WASM)
    message(STATUS "Emscripten WASM build: building the wallet library only")
    set(DEROGOLD_BUILD_EXECUTABLES OFF CACHE BOOL "Build the daemon and the command line tools" FORCE)
    set(DEROGOLD_BUILD_WALLET_CAPI ON CACHE BOOL "Build the wallet C API shared library" FORCE)
endif()

include(CTest)

# Enable c11
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Enable c++17
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(CheckCCompilerFlag)
include(CheckCXXCompilerFlag)

if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Windows")
    set(CMAKE_INSTALL_PREFIX "${CMAKE_BINARY_DIR}")
endif()

set(USE_CCACHE ON CACHE BOOL "Use ccache to speed up incremental compilation.")

if(USE_CCACHE)
    find_program(CCACHE_PROGRAM ccache)

    if(CCACHE_PROGRAM)
        message(STATUS "Found ccache: ${CCACHE_PROGRAM}")

        if(MSVC)
            file(COPY_FILE ${CCACHE_PROGRAM} ${CMAKE_BINARY_DIR}/cl.exe ONLY_IF_DIFFERENT)

            # By default Visual Studio generators will use /Zi which is not compatible
            # with ccache, so tell Visual Studio to use /Z7 instead.
            if(CMAKE_VERSION VERSION_GREATER_EQUAL "3.25")
                message(STATUS "Setting MSVC debug information format to 'Embedded'")
                set(CMAKE_MSVC_DEBUG_INFORMATION_FORMAT "$<$<CONFIG:Debug,RelWithDebInfo>:Embedded>")
            endif()

            set(CMAKE_VS_GLOBALS
                "CLToolExe=cl.exe"
                "CLToolPath=${CMAKE_BINARY_DIR}"
                "UseMultiToolTask=true"
                "DebugInformationFormat=OldStyle")
        else()
            set(CMAKE_C_COMPILER_LAUNCHER "${CCACHE_PROGRAM}")
            set(CMAKE_CXX_COMPILER_LAUNCHER "${CCACHE_PROGRAM}")
        endif()
    endif()
endif()

# Set default build type.
set(CMAKE_BUILD_TYPE Release CACHE STRING "Choose the type of build, options are: Debug, Release, RelWithDebInfo")

# Set target architecture for optimizations
set(ARCH native CACHE STRING "Set target architecture, options are: native, default")

# `native` means "the machine doing the compiling", which is the wrong
# question the moment that is not the machine running the result - and for
# Android, WebAssembly and the other cross builds the compiler simply refuses:
#
#   clang++: error: unsupported argument 'native' to option '-march='
#
# Every cross target could pass -D ARCH=default instead, and they mostly do,
# but forgetting it produces several hundred lines of that message rather than
# anything pointing here.
if(ARCH STREQUAL "native" AND CMAKE_CROSSCOMPILING)
    message(STATUS "Cross-compiling: using ARCH=default, because -march=native describes the build machine")
    set(ARCH default)
endif()

if(CMAKE_C_COMPILER_ID STREQUAL "GNU" OR CMAKE_C_COMPILER_ID STREQUAL "Clang")
    if(NOT ARCH STREQUAL "default")
        add_compile_options(-march=${ARCH})
    endif()
endif()

# This section is for settings found in the slow-hash routine(s) that may benefit some systems (mostly ARM)
set(FORCE_USE_HEAP ON CACHE BOOL "Force the use of heap memory allocation")
set(NO_AES OFF CACHE BOOL "Turn off Hardware AES instructions?")
set(NO_OPTIMIZED_MULTIPLY_ON_ARM OFF CACHE BOOL "Turn off Optimized Multiplication on ARM?")

if(FORCE_USE_HEAP)
    add_compile_definitions(FORCE_USE_HEAP)
    message(STATUS "FORCE_USE_HEAP: ENABLED")
else()
    message(STATUS "FORCE_USE_HEAP: DISABLED")
endif()

if(NO_AES)
    add_compile_definitions(NO_AES)
    message(STATUS "HW AES: DISABLED")
else()
    message(STATUS "HW AES: ENABLED")

    check_c_compiler_flag(-maes HAS_AES_NI_COMPILER_FLAG)

    if(HAS_AES_NI_COMPILER_FLAG)
        string(APPEND CMAKE_C_FLAGS " -maes")
    endif()
endif()

if(NO_OPTIMIZED_MULTIPLY_ON_ARM)
    add_compile_definitions(NO_OPTIMIZED_MULTIPLY_ON_ARM)
    message(STATUS "OPTIMIZED_ARM_MULTIPLICATION: DISABLED")
else()
    message(STATUS "OPTIMIZED_ARM_MULTIPLICATION: ENABLED")
endif()

set(SET_PACKAGE_OUTPUT_SUFFIX "${CPACK_SYSTEM_NAME}" CACHE STRING "Set the CPack package file name suffix")

# This section helps us tag our builds with the git commit information
set(SET_COMMIT_ID_IN_VERSION ON CACHE BOOL "Include commit ID in version")

file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/version")

if(NOT SET_COMMIT_ID_IN_VERSION)
    unset(BUILD_COMMIT_ID)
elseif(NOT DEFINED BUILD_COMMIT_ID)
    if(EXISTS "${CMAKE_SOURCE_DIR}/.git")
        find_package(Git QUIET)

        if(Git_FOUND)
            execute_process(
                COMMAND "${GIT_EXECUTABLE}" rev-parse --short HEAD
                WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
                RESULT_VARIABLE BUILD_COMMIT_ID_RESULT
                OUTPUT_VARIABLE BUILD_COMMIT_ID
                OUTPUT_STRIP_TRAILING_WHITESPACE)
        endif()
    endif()
endif()

configure_file("${CMAKE_CURRENT_SOURCE_DIR}/src/config/version.h.in" "${CMAKE_CURRENT_BINARY_DIR}/version/version.h")
add_custom_target(version ALL)

include_directories("${CMAKE_CURRENT_BINARY_DIR}/version" "external" "include" "src")

# Platform specific code base information is applied here
if(MSVC)
    add_compile_definitions(_CRT_SECURE_NO_WARNINGS _WIN32_WINNT=0x0A00 WIN32_LEAN_AND_MEAN)
    add_compile_options(/bigobj /MP /W3 /GS-)
    add_link_options(/STACK:10485760)

    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

    include_directories(${CMAKE_CURRENT_SOURCE_DIR}/src/platform/windows)
    include_directories(${CMAKE_CURRENT_SOURCE_DIR}/src/platform/msc)
elseif(MINGW)
    add_compile_definitions(_CRT_SECURE_NO_WARNINGS _WIN32_WINNT=0x0A00 WIN32_LEAN_AND_MEAN)
    add_link_options(-static)

    include_directories(${CMAKE_CURRENT_SOURCE_DIR}/src/platform/windows)
    include_directories(${CMAKE_CURRENT_SOURCE_DIR}/src/platform/mingw)
elseif(APPLE)
    include_directories(${CMAKE_CURRENT_SOURCE_DIR}/src/platform/osx)
    include_directories(${CMAKE_CURRENT_SOURCE_DIR}/src/platform/posix)
elseif(ANDROID)
    # Android runs the Linux (epoll/ucontext) implementation; what bionic does
    # not provide is #ifdef'd there and supplied by libucontext.
    include_directories(${CMAKE_CURRENT_SOURCE_DIR}/src/platform/linux)
    include_directories(${CMAKE_CURRENT_SOURCE_DIR}/src/platform/posix)
    add_compile_definitions(_GNU_SOURCE _XOPEN_SOURCE=700)
else()
    include_directories(${CMAKE_CURRENT_SOURCE_DIR}/src/platform/linux)
    include_directories(${CMAKE_CURRENT_SOURCE_DIR}/src/platform/posix)
endif()

if(NOT MSVC)
    if(${CMAKE_SYSTEM_NAME} STREQUAL "Linux")
        # This option has no effect in glibc version less than 2.20.
        # Since glibc 2.20 _BSD_SOURCE is deprecated, this macro is recomended instead
        add_compile_definitions(_DEFAULT_SOURCE _GNU_SOURCE)
    endif()

    # # These options generate all those nice warnings we see while building
    set(WARNINGS "-Wall -Wextra -Wpointer-arith -Wvla -Wwrite-strings -Wno-error=extra -Wno-error=unused-function -Wno-error=sign-compare -Wno-error=strict-aliasing -Wno-error=type-limits -Wno-unused-parameter -Wno-error=unused-variable -Wno-error=undef -Wno-error=unused-result")

    if(CMAKE_C_COMPILER_ID STREQUAL "Clang")
        set(WARNINGS "${WARNINGS} -Wno-error=mismatched-tags -Wno-error=null-conversion -Wno-overloaded-shift-op-parentheses -Wno-error=shift-count-overflow -Wno-error=tautological-constant-out-of-range-compare -Wno-error=unused-private-field -Wno-error=unneeded-internal-declaration -Wno-error=unused-function -Wno-error=missing-braces -Wno-error=unused-command-line-argument -Wno-error=integer-overflow")

        check_cxx_compiler_flag(-Wno-nan-infinity-disabled HAS_NO_NAN_INFINITY_DISABLED)

        if(HAS_NO_NAN_INFINITY_DISABLED)
            set(WARNINGS "${WARNINGS} -Wno-nan-infinity-disabled")
        endif()
    else()
        set(WARNINGS "${WARNINGS} -Wno-error=unused-but-set-variable -Wno-error=odr")

        if(NOT APPLE)
            set(WARNINGS "${WARNINGS} -Wlogical-op -Wno-error=maybe-uninitialized -Wno-error=clobbered")
        endif()
    endif()

    set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} ${WARNINGS} -Waggregate-return -Wnested-externs -Wold-style-definition -Wstrict-prototypes -Wno-implicit-fallthrough")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${WARNINGS} -Wno-reorder -Wno-missing-field-initializers")

    check_cxx_compiler_flag(-Wno-error=inconsistent-missing-override HAS_INCONSISTENT_MISSING_OVERRIDE)

    if(HAS_INCONSISTENT_MISSING_OVERRIDE)
        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wno-error=inconsistent-missing-override")
    endif()

    if(APPLE)
        if(CMAKE_C_COMPILER_ID STREQUAL "GNU")
            # Need to build against libc++ instead of libstc++ on apple
            set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -nostdinc++ -nodefaultlibs -isystem /usr/local/opt/llvm/include/c++/v1 -L /usr/local/opt/llvm/lib -Wl,-rpath,/usr/local/opt/llvm/lib -lc++ -lc++abi -lm -lc -lgcc_s -lgcc")
        elseif(CMAKE_C_COMPILER_ID STREQUAL "Clang")
            # Need to link against the llvm libc++ library, default is too old for std::filesystem
            set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -stdlib=libc++ -I/usr/local/opt/llvm/include/c++/v1")
        endif()
    endif()

    if(NOT APPLE AND NOT EMSCRIPTEN)
        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -pthread")
    endif()

    if(EMSCRIPTEN)
        # Both of these are whole-program properties under Emscripten rather
        # than per-target ones, so they go on the global flags.
        #
        # -pthread makes the wasm memory shared, and objects built with and
        # without it cannot be linked together: the feature has to match
        # everywhere or the link fails on mismatched atomics.
        #
        # -fexceptions likewise. Without it a throw compiles to a trap that
        # kills the module, and the wallet backend reports plenty of ordinary
        # conditions - a wrong password, a rejected transaction - by throwing.
        # It has to be on for the libraries, not only for the module that
        # catches.
        if(DEROGOLD_WASM_PTHREADS)
            set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -pthread")
            set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -pthread")
        endif()

        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fexceptions")
    endif()

    # # Setting up DEBUG flags
    if(CMAKE_C_COMPILER_ID STREQUAL "GNU")
        set(DEBUG_FLAGS "-g3 -Og -gdwarf-4 -fvar-tracking -fvar-tracking-assignments -fno-inline -fno-omit-frame-pointer")
    else()
        set(DEBUG_FLAGS "-g3 -O0 -fno-omit-frame-pointer")
    endif()

    # # Setting up RELEASE flags
    set(RELEASE_FLAGS "-O3 -DNDEBUG")

    # # Set up the normal CMake flags as we've built them
    set(CMAKE_C_FLAGS_DEBUG "${CMAKE_C_FLAGS_DEBUG} ${DEBUG_FLAGS}")
    set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} ${DEBUG_FLAGS}")
    set(CMAKE_C_FLAGS_RELEASE "${CMAKE_C_FLAGS_RELEASE} ${RELEASE_FLAGS}")
    set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} ${RELEASE_FLAGS}")

    # # Statically link our binaries
    #
    # Not on Android, where the NDK's own static libc++ is selected by the
    # toolchain file, and not under Emscripten, which has no such libraries.
    if(NOT APPLE AND NOT ANDROID AND NOT EMSCRIPTEN)
        set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -static-libgcc -static-libstdc++")
    endif()
endif()

##############################################################################
# Vendored header-only dependencies
#
# These live in external/, which is already on the include path, so the
# targets below exist purely to keep the names used by target_link_libraries
# unchanged.
##############################################################################

add_library(rapidjson INTERFACE)

add_library(cxxopts_vendored INTERFACE)
add_library(cxxopts::cxxopts ALIAS cxxopts_vendored)

add_library(httplib_vendored INTERFACE)
add_library(httplib::httplib ALIAS httplib_vendored)

##############################################################################
# System dependencies
##############################################################################

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/CMake")

include(DeroGoldDependencies)

# The NDK ships no OpenSSL, so an Android wallet build goes without: cpp-httplib
# then has no TLS and the wallet reaches its node over plain HTTP. Everywhere
# else it is required.
if(ANDROID AND DEROGOLD_ANDROID_DISABLE_OPENSSL)
    message(STATUS "OpenSSL: skipped for this Android build")
else()
    derogold_require_openssl()
endif()

derogold_add_cryptopp()
derogold_add_miniupnpc()

# RocksDB is the daemon's database. Nothing in the wallet chain links it - see
# the RocksDBWrapper filter in src/CMakeLists.txt - so a wallet-only build
# skips the library and its configure step entirely. That is what makes an
# Android or WebAssembly build possible at all: RocksDB does not cross-compile
# to either.
if(DEROGOLD_BUILD_EXECUTABLES)
    derogold_require_rocksdb()
endif()

# So we can use std::string with rapidjson
add_compile_definitions(RAPIDJSON_HAS_STDSTRING)

add_subdirectory(src)
