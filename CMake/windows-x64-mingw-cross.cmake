# Cross-compile Windows x86-64 binaries from a Linux host with MinGW-w64.
#
# The windows-x64-mingw-* presets build *on* Windows, in an MSYS2 shell, where
# plain `gcc` is already the MinGW compiler. This file is for the other
# direction: an Ubuntu host with gcc-mingw-w64-x86-64-posix installed, which is
# what scripts/docker uses.
#
# OpenSSL has to be one built for the Windows target; the host copy cannot be
# linked. Point CROSS_PREFIX at a prefix containing lib/libcrypto.a and
# lib/libssl.a, and set OPENSSL_ROOT_DIR to the same place so FindOpenSSL
# looks there:
#
#   export CROSS_PREFIX=$HOME/toolchain/windows-x86_64/prefix
#   export OPENSSL_ROOT_DIR=$CROSS_PREFIX
#   cmake -G Ninja \
#       -D CMAKE_TOOLCHAIN_FILE=CMake/windows-x64-mingw-cross.cmake \
#       -D CMAKE_BUILD_TYPE=Release -D ARCH=default -S . -B build

set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

if(DEFINED ENV{MINGW_PREFIX})
    set(MINGW_PREFIX "$ENV{MINGW_PREFIX}")
else()
    set(MINGW_PREFIX "x86_64-w64-mingw32")
endif()

if(DEFINED ENV{CROSS_PREFIX})
    set(CROSS_PREFIX "$ENV{CROSS_PREFIX}")
else()
    set(CROSS_PREFIX "$ENV{HOME}/toolchain/windows-x86_64/prefix")
endif()

# The posix-thread flavour, when present: the win32-thread one has no
# std::thread, std::mutex or std::condition_variable, which this tree uses
# everywhere.
if(EXISTS "/usr/bin/${MINGW_PREFIX}-gcc-posix")
    set(CMAKE_C_COMPILER "/usr/bin/${MINGW_PREFIX}-gcc-posix")
else()
    set(CMAKE_C_COMPILER "/usr/bin/${MINGW_PREFIX}-gcc")
endif()

if(EXISTS "/usr/bin/${MINGW_PREFIX}-g++-posix")
    set(CMAKE_CXX_COMPILER "/usr/bin/${MINGW_PREFIX}-g++-posix")
else()
    set(CMAKE_CXX_COMPILER "/usr/bin/${MINGW_PREFIX}-g++")
endif()

set(CMAKE_RC_COMPILER "/usr/bin/${MINGW_PREFIX}-windres")
set(CMAKE_AR "/usr/bin/${MINGW_PREFIX}-ar")
set(CMAKE_RANLIB "/usr/bin/${MINGW_PREFIX}-ranlib")
set(CMAKE_STRIP "/usr/bin/${MINGW_PREFIX}-strip")

set(CMAKE_FIND_ROOT_PATH
    "/usr/${MINGW_PREFIX}"
    "${CROSS_PREFIX}")

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# Nothing produced here can be executed on the build host, so CMake's compiler
# check has to stop at linking a static library.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
