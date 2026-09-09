# Building DeroGold

There is no package manager to set up. Install a compiler, CMake and OpenSSL
from your system's own repositories, then build.

## Quick start (Linux)

```sh
# Debian / Ubuntu
sudo apt install build-essential cmake ninja-build git libssl-dev

git clone https://github.com/derogold/derogold-core.git
cd derogold-core
cmake -G Ninja -D CMAKE_BUILD_TYPE=Release -S . -B build
cmake --build build
```

Binaries land in `build/src`.

No `--recursive` clone is needed any more; there are no submodules.

> This builds for **the machine you are compiling on** and will likely crash
> with an illegal instruction on any other CPU. Add `-D ARCH=default` for a
> binary you can copy elsewhere; see [Portable builds](#portable-builds).

## What the build needs

| Dependency | Where it comes from |
| --- | --- |
| rapidjson, cpp-httplib, cxxopts, nlohmann-json, cpp-linenoise | Vendored in `external/`, header-only, nothing to install |
| Crypto++, miniupnpc, zstd | Vendored in `external/`, compiled with the project |
| OpenSSL | System package |
| RocksDB | Vendored in `external/`, compiled with the project, see below |

Exact versions, and any local modifications made to a vendored tree, are
recorded in [external/README.md](external/README.md).

If OpenSSL is missing, CMake stops with the install command for your platform
rather than a wall of linker errors.

Nothing under `extras/` is built by CMake. The block explorer there is static
HTML and JavaScript, served by any web server; see
[extras/explorer/README.md](extras/explorer/README.md).

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

## Portable builds

"Portable" is two separate questions, and they have different answers.

### 1. Which CPUs the binary runs on

Controlled by `ARCH`, which defaults to `native`:

| `ARCH` | Effect |
| --- | --- |
| `native` (default) | `-march=native`. Fastest on this machine, **illegal instruction crash on anything older** |
| `default` | No `-march` at all, so the compiler's baseline. This is what the released binaries use |
| anything else | Passed straight through as `-march=<value>`, e.g. `x86-64-v2`, `haswell`, `armv8-a` |

The middle option is a genuine middle ground: `-D ARCH=x86-64-v2` targets
roughly any x86-64 chip from 2009 onward and keeps SSE4.2 and POPCNT, while
`ARCH=default` goes all the way back to plain SSE2.

Hardware AES needs no flag either way. The build adds `-maes` when the compiler
accepts it, but the hashing code checks CPUID at runtime and falls back to
software AES, so an `ARCH=default` binary still uses AES-NI on chips that have
it and runs correctly on chips that do not. Setting `NO_AES=ON` is for
toolchains that reject `-maes`, not for portability. To force the software path
at runtime — for a bug report, say — set `TURTLECOIN_USE_SOFTWARE_AES=1` in the
environment.

### 2. Which machines the binary loads on

The C++ runtime is already handled: every non-Apple build links with
`-static-libgcc -static-libstdc++`, so the target does not need a matching
libstdc++. MinGW goes further and links `-static`, which is why the Windows
binaries need no MSYS2 DLLs beside them.

That leaves two dynamic dependencies on Linux:

- **OpenSSL.** Link it statically with `-D OPENSSL_USE_STATIC_LIBS=ON`,
  provided your distribution ships `libssl.a` / `libcrypto.a` (Debian and
  Ubuntu do, in `libssl-dev`).
- **glibc**, which cannot be statically linked in any way worth shipping. A
  binary built against glibc 2.39 will not start on a system with 2.35. There
  is no flag for this: **build on the oldest distribution you intend to
  support.** CI builds on Ubuntu 22.04 and 24.04 for exactly this reason.

### Building one

Nothing about this needs presets. `ARCH=default` is the whole of it:

```sh
cmake -G Ninja -D CMAKE_BUILD_TYPE=Release -D ARCH=default -S . -B build
cmake --build build
```

Binaries land in `build/src`, and will run on any x86-64 machine with a new
enough glibc. Add `-D OPENSSL_USE_STATIC_LIBS=ON` if you also want to drop the
OpenSSL runtime dependency; note that the official builds do **not** do this,
so they expect libssl on the target.

To produce the same archive the releases ship, build the `package` target and
set the two variables the release configuration uses:

```sh
CC=gcc CXX=g++ cmake -G Ninja \
    -D CMAKE_BUILD_TYPE=Release \
    -D ARCH=default \
    -D SET_COMMIT_ID_IN_VERSION=OFF \
    -D SET_PACKAGE_OUTPUT_SUFFIX=linux-x64-gcc \
    -S . -B build
cmake --build build --target package
```

`SET_COMMIT_ID_IN_VERSION=OFF` keeps the version string to the release number
rather than a number plus a commit hash, and `SET_PACKAGE_OUTPUT_SUFFIX` only
names the file. On Windows run the same thing from the MSYS2 MINGW64 shell with
`-D SET_PACKAGE_OUTPUT_SUFFIX=windows-x64-mingw-gcc`.

The result is an archive under `build/Packaging` rather than loose binaries —
`DeroGold-linux-x64-gcc.tar.gz` and so on. The format follows the machine you
build **on**, not the one you build for: `.tar.gz` and `.deb` from Linux,
`.zip` from Windows, `.tar.gz` from macOS.

If you would rather not type that, `cmake --preset linux-x64-gcc-package` is
the same set of variables under a name; see [Presets](#presets).

### Checking what you produced

```sh
# Which shared libraries are still required. With OPENSSL_USE_STATIC_LIBS=ON
# this should be down to libc, libm, libdl, libpthread and the loader.
ldd build/src/DeroGoldd

# The oldest glibc the binary demands, which is the version floor on the target
objdump -T build/src/DeroGoldd | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -1
```

On Windows, `ldd DeroGoldd.exe` from the MSYS2 shell should list only DLLs from
`C:\Windows`; anything under `/mingw64/bin` means the binary is not standalone.

Neither check proves the instruction set is right — nothing in the ELF header
records the `-march` used. The only reliable test is running the binary on the
oldest CPU you intend to support, where a wrong `ARCH` shows up immediately as
`Illegal instruction`.

## Presets

`CMakePresets.json` carries the configurations used by CI. They are a shorthand
for the `-D` flags shown above and nothing more — every preset in the file is
some combination of `CMAKE_BUILD_TYPE`, `ARCH`, `SET_COMMIT_ID_IN_VERSION`,
`SET_PACKAGE_OUTPUT_SUFFIX`, `CMAKE_TOOLCHAIN_FILE`, `CC`/`CXX` and a
generator. Nothing is only reachable through them, and you can ignore this
section entirely.

For reference, the release configuration spelled both ways:

| Preset | Equivalent |
| --- | --- |
| `linux-x64-gcc-package` | `CC=gcc CXX=g++`, `-G Ninja`, `CMAKE_BUILD_TYPE=Release`, `ARCH=default`, `SET_COMMIT_ID_IN_VERSION=OFF`, `SET_PACKAGE_OUTPUT_SUFFIX=linux-x64-gcc`, target `package` |
| `linux-arm64-gcc-cross-package` | the same, plus `CMAKE_TOOLCHAIN_FILE=CMake/linux-arm64-gcc.cmake` and suffix `linux-arm64-gcc-cross` |

Names follow `<platform>-<arch>-<compiler>[-<variant>]`. The variant decides
what you get:

| Variant | Purpose |
| --- | --- |
| *(none)* | Multi-config developer build; binaries land in `build/src/<Config>/` |
| `-all` | Single-config Release build of everything |
| `-install` | Adds the install step |
| `-package` | Release, `ARCH=default`, builds an archive under `build/Packaging` |

Configure presets and build presets do not always share a name. There is no
`-release` **configure** preset — the release build presets attach to the
plain configure preset:

```sh
cmake --preset linux-x64-gcc                 # configure
cmake --build --preset linux-x64-gcc-release # build
```

For the `-package` variants the two names do match, so `cmake --preset X`
followed by `cmake --build --preset X` works for those.

## Cross-compiling for ARM64

CI cross-compiles the ARM64 release from an x86-64 host rather than building on
ARM hardware. There is a toolchain file for it, so this is again ordinary
CMake:

```sh
sudo apt install crossbuild-essential-arm64

cmake -G Ninja \
    -D CMAKE_TOOLCHAIN_FILE=CMake/linux-arm64-gcc.cmake \
    -D CMAKE_BUILD_TYPE=Release \
    -D ARCH=default \
    -D SET_COMMIT_ID_IN_VERSION=OFF \
    -D SET_PACKAGE_OUTPUT_SUFFIX=linux-arm64-gcc-cross \
    -S . -B build
cmake --build build --target package
```

`CMake/linux-arm64-clang.cmake` is the Clang equivalent. Both only switch
compilers when the host is not already aarch64, so the same command also works
natively on an ARM64 machine — where you would normally want `ARCH=native`
instead.

Cross builds need an OpenSSL built for the target, not the host copy. If the
link fails on `-lssl` or `-lcrypto`, that is what is missing.

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

`CMakePresets.json` does still carry `windows-x64-msvc*` presets, but no CI job
uses them and they will not configure without an OpenSSL you supply.

## Other build options

| Option | Default | Effect |
| --- | --- | --- |
| `USE_CCACHE` | `ON` | Uses ccache when it is on `PATH`. Harmless when it is not |
| `SET_COMMIT_ID_IN_VERSION` | `ON` | Appends the short commit hash to the version string |
| `FORCE_USE_HEAP` | `ON` | Allocates the hashing scratchpad on the heap rather than the stack |
| `NO_AES` | `OFF` | Drops `-maes`, for toolchains that reject it. Not needed for portability |
| `NO_OPTIMIZED_MULTIPLY_ON_ARM` | `OFF` | Disables the ARM multiply path, for toolchains that miscompile it |

## Upgrading from the vcpkg build

Nothing needs migrating. Delete the leftover directory if you still have one:

```sh
rm -rf vcpkg
```
