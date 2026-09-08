# Building DeroGold

There is no package manager to set up. Install a compiler, CMake and five
libraries from your system's own repositories, then build.

## Quick start (Linux)

```sh
# Debian / Ubuntu
sudo apt install build-essential cmake ninja-build git curl pkg-config \
    libboost-serialization-dev libssl-dev libcrypto++-dev \
    libminiupnpc-dev libzstd-dev

git clone -b development https://github.com/derogold/derogold-core.git
cd derogold-core
cmake -G Ninja -D CMAKE_BUILD_TYPE=Release -S . -B build
cmake --build build
```

Binaries land in `build/src`.

No `--recursive` clone is needed any more; there are no submodules.

## What the build needs

| Dependency | Where it comes from |
| --- | --- |
| rapidjson, cpp-httplib, cxxopts, nlohmann-json, cpp-linenoise | Vendored in `external/`, nothing to install |
| Boost (serialization) | System package |
| OpenSSL | System package |
| Crypto++ | System package |
| miniupnpc | System package |
| zstd | System package, used by RocksDB |
| RocksDB | Built from source during the build, see below |

If a system library is missing, CMake stops with the install command for your
platform rather than a wall of linker errors.

### Compiler

A C++17 compiler for DeroGold itself. The bundled RocksDB builds as C++20, so
in practice you need GCC 11 or newer, or Clang 14 or newer. Older toolchains
can still build by pointing at a system RocksDB, see the next section.

### Install commands for other platforms

```sh
# Fedora / RHEL
sudo dnf install gcc-c++ cmake ninja-build git boost-devel openssl-devel \
    cryptopp-devel miniupnpc-devel libzstd-devel

# Arch
sudo pacman -S base-devel cmake ninja git boost openssl crypto++ miniupnpc zstd

# macOS
brew install cmake ninja boost openssl@3 cryptopp miniupnpc zstd

# Windows, MSYS2 MINGW64 shell
pacman -S mingw-w64-x86_64-toolchain mingw-w64-x86_64-cmake \
    mingw-w64-x86_64-ninja mingw-w64-x86_64-boost mingw-w64-x86_64-openssl \
    mingw-w64-x86_64-crypto++ mingw-w64-x86_64-miniupnpc mingw-w64-x86_64-zstd
```

## RocksDB

DeroGold needs a recent RocksDB. It calls `WaitForCompact`, which arrived in
8.1, and most distributions still ship 6.x or 7.x. So by default the build
downloads and compiles RocksDB itself. This makes the first build considerably
longer; afterwards it is cached in the build directory.

To use your distribution's RocksDB instead:

```sh
cmake -D DEROGOLD_SYSTEM_ROCKSDB=ON -S . -B build
```

The build refuses a system RocksDB older than 8.1 rather than failing later
with confusing compiler errors.

To pin a different bundled version:

```sh
cmake -D DEROGOLD_ROCKSDB_VERSION=10.10.1 -S . -B build
```

Databases are not backward compatible across major RocksDB versions. A chain
database written by this build cannot be opened by an older binary, so keep a
copy before switching if you may want to go back.

## Presets

`CMakePresets.json` carries the configurations used by CI. They are convenient
but entirely optional; the plain commands above work everywhere.

```sh
cmake --preset linux-x64-gcc-release
cmake --build --preset linux-x64-gcc-release
```

## Native versus portable binaries

By default the build targets the machine it is compiled on. Pass
`-D ARCH=default` for a binary that runs on other machines, at some cost in
performance.

## Windows and MSVC

MSVC is not currently supported. The four system libraries above have no
standard source on Windows outside MSYS2, which is what the MinGW instructions
use. Building with MSVC means providing Boost, OpenSSL, Crypto++ and miniupnpc
yourself and pointing CMake at them.

## Upgrading from the vcpkg build

Nothing needs migrating. Delete the leftover directory if you still have one:

```sh
rm -rf vcpkg
```
