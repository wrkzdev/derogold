# Building DeroGold

There is no package manager to set up. Install a compiler, CMake and OpenSSL
from your system's own repositories, then build.

## Quick start (Linux)

```sh
# Debian / Ubuntu
sudo apt install build-essential cmake ninja-build git libssl-dev

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
| rapidjson, cpp-httplib, cxxopts, nlohmann-json, cpp-linenoise | Vendored in `external/`, header-only, nothing to install |
| Crypto++, miniupnpc, zstd | Vendored in `external/`, compiled with the project |
| OpenSSL | System package |
| RocksDB | Vendored in `external/`, compiled with the project, see below |

If OpenSSL is missing, CMake stops with the install command for your platform
rather than a wall of linker errors.

### CMake

3.15 or newer. Ubuntu 22.04's 3.22 is fine.

### Compiler

A C++17 compiler for DeroGold itself. The bundled RocksDB builds as C++20, so
in practice you need GCC 11 or newer, or Clang 14 or newer. Older toolchains
can still build by pointing at a system RocksDB, see the next section.

### Install commands for other platforms

```sh
# Fedora / RHEL
sudo dnf install gcc-c++ cmake ninja-build git openssl-devel

# Arch
sudo pacman -S base-devel cmake ninja git openssl

# macOS
brew install cmake ninja openssl@3

# Windows, MSYS2 MINGW64 shell
pacman -S mingw-w64-x86_64-toolchain mingw-w64-x86_64-cmake \
    mingw-w64-x86_64-ninja mingw-w64-x86_64-openssl
```

## RocksDB

DeroGold needs a recent RocksDB. It calls `WaitForCompact`, which arrived in
8.1, and most distributions still ship 6.x or 7.x. A trimmed copy of 11.8.1
therefore lives in `external/rocksdb` and is compiled with the project. Nothing
is downloaded during the build. This makes the first build considerably longer;
afterwards it is cached in the build directory.

To use your distribution's RocksDB instead:

```sh
cmake -D DEROGOLD_SYSTEM_ROCKSDB=ON -S . -B build
```

The build refuses a system RocksDB older than 8.1 rather than failing later
with confusing compiler errors.

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

## Vendored libraries

Crypto++, miniupnpc, zstd and RocksDB are compiled from the sources in
`external/`, so there is nothing to install and no version to match. zstd is
there because RocksDB needs it: the blockchain wrapper writes with kZSTD when
compression is on, so an existing database cannot be opened without it.

Crypto++ carries a small local patch to its CMake build, described at the top
of `external/cryptopp/CMakeLists.txt`. The RocksDB copy is upstream 11.8.1 with
the documentation, Java bindings, tests, benchmarks and code generators
removed; only what the library build compiles is kept. zstd is upstream 1.5.7,
library and CMake files only.

## Windows and MSVC

MSVC is not currently supported. OpenSSL has no standard source on Windows
outside MSYS2, which is what the MinGW instructions use. Building with MSVC
means providing it yourself and pointing CMake at it.

## Upgrading from the vcpkg build

Nothing needs migrating. Delete the leftover directory if you still have one:

```sh
rm -rf vcpkg
```
