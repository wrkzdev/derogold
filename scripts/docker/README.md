# Docker release builds

One command builds the whole DeroGold release set - the command line tools for
each platform, and all three wallets - and packs it for release with the root
`LICENSE` inside:

| Target        | Package                                        | How it is built                            |
|---------------|------------------------------------------------|--------------------------------------------|
| `linux`       | `derogold-cli-linux-x86_64-<version>.tar.gz`   | native GCC, fully static binaries          |
| `linux-arm64` | `derogold-cli-linux-arm64-<version>.tar.gz`    | aarch64 cross toolchain + static OpenSSL   |
| `windows`     | `derogold-cli-windows-x86_64-<version>.zip`    | MinGW-w64 (posix threads) + static OpenSSL |
| `gui`         | `derogold-gui-linux-x86_64-<version>.tar.gz`   | `libwallet_capi.so` + Flutter Linux bundle |
| `web`         | `derogold-web-wallet-<version>.tar.gz`         | Emscripten WASM module + Flutter web build |
| `android`     | `derogold-android-<version>.tar.gz`            | NDK library per ABI + Gradle APK and AAB   |

Three groups select several at once:

| Group  | Targets                                 |
|--------|-----------------------------------------|
| `cli`  | `linux` `linux-arm64` `windows`         |
| `apps` | `gui` `web` `android`                   |
| `all`  | everything above (the default)          |

The CLI packages are built first, so a problem in the C++ fails the run in a
couple of minutes rather than after Gradle and Emscripten have had their turn.

To put the packages in `dist/` instead of `builds/`, which is what a release
wants:

```bash
bash scripts/docker/dist.sh          # everything
bash scripts/docker/dist.sh cli      # just the command line packages
bash scripts/docker/dist.sh apps     # just the wallets
```

`<version>` is `MAJOR.MINOR.REV.BUILD` from the
`project(DeroGold VERSION ...)` line in the root `CMakeLists.txt`; override it
with `VERSION=`.

Every package contains, flat inside a directory of the same name:

```
DeroGoldd  degwallet  DeroGold-service  wallet-api  degwallet-upgrader
miner      cryptotest  DeroGold-txpow-server  LICENSE
```

The executable list is taken from the checked-out `src/CMakeLists.txt`, so a
branch that does not build `DeroGold-txpow-server` yet gets a package without
it (the build log notes the omission). A declared executable that is missing
after the build fails the run. A `SHA256SUMS-<version>.txt` is written next to
the packages.

This is a different thing from the two Dockerfiles at the repository root:
`Dockerfile` builds the published container image, and `Dockerfile.portable`
builds one Linux package against an older glibc. This image builds the release
set for several operating systems from one command, and keeps its build trees
and ccache between runs.

## Requirements

- Docker 20.10 or newer (or Podman: `DOCKER=podman`). Any Linux host works;
  Docker Desktop on macOS/Windows works too, the image is always `linux/amd64`.
- Disk: about 3 GB for the image if you only ever build the `cli` targets, but
  roughly 25-30 GB once Flutter, the Android SDK/NDK and Emscripten are in it,
  plus another 10-15 GB for the build trees and Gradle's caches. A remote
  build host is the comfortable place for this.
- RAM: the RocksDB and C++20 sources need roughly 1.5 GB per compile job. A
  4 GB machine should use `JOBS=2`.
- Network access the first time, to fetch the base image, CMake and OpenSSL.
  Later runs are offline.

## Usage

From the repository root:

```bash
# Every target, into builds/
bash scripts/docker/build.sh

# Every target, into dist/ - what a release wants
bash scripts/docker/dist.sh

# One target
bash scripts/docker/build.sh linux
bash scripts/docker/build.sh linux-arm64
bash scripts/docker/build.sh windows

# Fewer compile jobs on a small machine
JOBS=2 bash scripts/docker/build.sh
```

`dist.sh` is `build.sh` with `OUT_DIR=dist/` and `KEEP_GOING=1`, so one
toolchain failing still leaves you the packages that did build. Every
environment variable below works with either.

The first run builds the toolchain image (10-20 minutes, mostly the OpenSSL
compile). After that the image is cached and each run goes straight to the
build. The build trees under `build-docker/` and the ccache inside it survive
between runs, so a rebuild after a small source change is quick; `CLEAN=1`
starts the affected targets from scratch.

Packages land in `builds/`:

```
builds/
  derogold-cli-linux-x86_64-1.0.1.0.tar.gz
  derogold-cli-windows-x86_64-1.0.1.0.zip
  SHA256SUMS-1.0.1.0.txt
```

Per-target logs are in `build-docker/logs/`.

### Options

All options are environment variables. Targets are positional arguments.

| Variable           | Default                        | Meaning                                                        |
|--------------------|--------------------------------|----------------------------------------------------------------|
| `JOBS`             | all CPUs in the container      | parallel compile jobs                                          |
| `VERSION`          | `project()` in `CMakeLists.txt`| version string in the package names                            |
| `OUT_DIR`          | `builds/`                      | where packages and checksums go                                |
| `BUILD_ROOT`       | `build-docker/`                | build trees, staging directories, ccache and logs              |
| `CLEAN`            | `0`                            | `1` wipes each requested target's build tree before configuring|
| `KEEP_GOING`       | `0`                            | `1` keeps building the remaining targets after one fails       |
| `IMAGE`            | `derogold-builder:latest`      | image name                                                     |
| `NO_IMAGE_BUILD`   | `0`                            | `1` skips the `docker build` step                              |
| `IMAGE_BUILD_ARGS` | empty                          | extra `docker build` arguments, see [Toolchain versions](#toolchain-versions) |
| `DOCKER`           | `docker`                       | container CLI                                                  |
| `DOCKER_PLATFORM`  | `linux/amd64`                  | image platform                                                 |

Flags:

- `--shell` opens an interactive shell in the image with the repository at
  `/work`, the build trees at `/build` and the package directory at `/out`.
  Inside it, `bash /work/scripts/docker/container-build.sh linux` does exactly
  what `build.sh linux` does.
- `--image-only` builds or refreshes the image and stops.

On Linux the container runs as your user (under `sudo`, as the user who ran
`sudo`), so nothing in `build-docker/` or `builds/` ends up root-owned.

## What each target does

The flags mirror the manual flows in [BUILDING.md](../../BUILDING.md); the
image just supplies the toolchains.

**Linux** configures with `-D ARCH=default -D SET_COMMIT_ID_IN_VERSION=OFF
-D OPENSSL_USE_STATIC_LIBS=ON -D CMAKE_EXE_LINKER_FLAGS=-static`, then checks
every executable with `file` for `statically linked` before running
`DeroGoldd --version` and `degwallet --version`. `ARCH=default` answers "which
CPUs does this run on" and the static link answers "which machines does it
load on" — together they remove the glibc floor described in BUILDING.md, so
the package runs on distributions far older than the image. The glibc NSS
caveat applies: name lookups use the `files` and `dns` backends built into
glibc, which is what every mainstream distribution ships.

**Linux ARM64** uses `CMake/linux-arm64-gcc.cmake` with the aarch64 OpenSSL the
image built, strips with `aarch64-linux-gnu-strip`, and checks every executable
is a statically linked aarch64 ELF. That toolchain file sets the find modes to
`ONLY` but leaves `CMAKE_FIND_ROOT_PATH` empty, so the container passes the
roots explicitly — without them `FindOpenSSL` has nowhere to look, and the
host's x86_64 OpenSSL must not be what it finds. Unlike the x86_64 target it
runs no `--version` smoke test: nothing in the container executes ARM binaries.

**Windows** uses `CMake/windows-x64-mingw-cross.cmake` with the OpenSSL the
image built for the target (`no-shared`), strips the executables with the
MinGW `strip`, then reads the import tables with `objdump`. This tree already
links MinGW builds with `-static`, so the expected result is that no
`lib*.dll` is imported at all and nothing needs bundling; if that ever
changes, the missing DLLs are copied in and a DLL that cannot be found fails
the build rather than producing a zip that will not start.

Each of the three app targets is two builds: the wallet library with CMake,
then the Flutter app that loads it.

**GUI** builds `libwallet_capi.so` with `-D DEROGOLD_BUILD_EXECUTABLES=OFF
-D DEROGOLD_BUILD_WALLET_CAPI=ON`, then `flutter build linux --release`, then
copies the library into the bundle's `lib/`. That location is not arbitrary:
`wallet_ffi.dart` calls `DynamicLibrary.open('libwallet_capi.so')` with no
path, and a Flutter bundle is linked with an RPATH of `$ORIGIN/lib`, so that
is where the loader looks.

**Web** configures through `emcmake` with `-D DEROGOLD_BUILD_WALLET_WASM=ON
-D DEROGOLD_WASM_PTHREADS=ON`, builds the `wallet_wasm` target, stages
`wallet_wasm.js`, `wallet_wasm.wasm` and the three bridge scripts into the
app's `web/`, then runs `flutter build web --release`. The module is built
with threads, so the page only runs when it is served cross-origin isolated -
see `SERVING.txt` in the package, which carries the two headers and an nginx
block. The names matter: the glue script asks for the `.wasm` by the name it
was linked under, so the pair cannot be renamed after the fact.

**Android** builds `libwallet_capi.so` once per ABI with the NDK toolchain
file, `-D DEROGOLD_ANDROID_PROFILE=ON` and a `LIBUCONTEXT_ROOT` pointing at
the `libucontext` the image built, drops each into
`android/app/src/main/jniLibs/<abi>/`, then asks Flutter for four artifacts:
release and debug, APK and AAB. `ANDROID_ABIS` is checked against `abiFilters`
in the app's `build.gradle` before anything is compiled — an ABI Gradle
packages with no library behind it yields an app that installs and then fails
on its first wallet call, which is not something to discover on a device.

Release signing comes from `android/key.properties` or the `DEROGOLD_KEYSTORE`
environment variables. With neither, a release build falls back to the debug
keystore and says so: installable for testing, not publishable.

## Toolchain versions

Everything the image downloads is pinned at the top of the
[Dockerfile](Dockerfile) and can be changed with `--build-arg`:

| Build argument           | Default             | Used for                                              |
|--------------------------|---------------------|-------------------------------------------------------|
| `UBUNTU_VERSION`         | `22.04`             | base image: GCC 11, MinGW-w64 GCC, and the build tools |
| `OPENSSL_VERSION`        | `3.5.8`             | Windows- and ARM64-target OpenSSL (the Linux target uses `libssl-dev`) |
| `FLUTTER_VERSION`        | `3.38.0`            | the `gui`, `web` and `android` targets                 |
| `ANDROID_CMDLINE_TOOLS`  | `11076708`          | the Android SDK command line tools bundle              |
| `ANDROID_PLATFORM_VERSION` | `35`              | the Android platform Gradle compiles against           |
| `ANDROID_BUILD_TOOLS`    | `35.0.0`            | the Android build tools                                |
| `ANDROID_NDK_VERSION`    | `26.3.11579264`     | cross-compiling the wallet library for each ABI        |
| `ANDROID_API`            | `21`                | the minimum Android API the library targets            |
| `LIBUCONTEXT_VERSION`    | `1.2`               | `getcontext`/`swapcontext` for bionic                  |
| `EMSDK_VERSION`          | `3.1.64`            | the WebAssembly module                                 |

`FLUTTER_VERSION` has a floor rather than a preference:
`extras/mobile-wallet/pubspec.yaml` asks for Flutter 3.38.0 and a Dart SDK of
`^3.10.7`.

```bash
IMAGE_BUILD_ARGS="--build-arg UBUNTU_VERSION=24.04" \
  bash scripts/docker/build.sh --image-only
```

22.04 is deliberate: it is what the published releases use, and its GCC clears
the floor the bundled RocksDB needs (C++20 `using enum`, GCC 11+).

## Other platforms

- **macOS** is the one platform this image cannot build. Cross-building needs
  an osxcross toolchain and an Apple SDK the operator supplies, plus a
  `CMake/` toolchain file for it; the SDK cannot be redistributed inside an
  image. There is an `osx-x64-clang` preset for building *on* a Mac, which is
  unaffected, and the GUI wallet has a `macos/` runner for `flutter build
  macos` there.
- **iOS** would need the same Mac, plus signing. The mobile wallet is Android
  only for now.
- **Windows and ARM64 GUI/web/Android builds** are not separate targets: the
  GUI bundle here is Linux x86_64. A Windows GUI build needs `flutter build
  windows` on Windows, since Flutter does not cross-compile its desktop
  embedders.

Android *is* built, which it was not in earlier revisions of this image. The
two things that blocked it are both handled now: `libucontext` is compiled per
ABI during the image build, because bionic has no `getcontext`/`swapcontext`
for the fibre dispatcher in `src/platform/linux/system/`; and
`DEROGOLD_ANDROID_DISABLE_OPENSSL` defaults on, because the NDK ships no
OpenSSL. That second one has a consequence worth knowing: cpp-httplib then
builds with no TLS at all, so the mobile wallet reaches its node over plain
HTTP and an `https://` address is refused rather than silently downgraded.

## Cleaning up

```bash
rm -rf build-docker builds      # build trees, ccache, logs, packages
docker rmi derogold-builder     # the image
```

## Troubleshooting

- **Compiler killed / `c++: fatal error: Killed signal`**: out of memory.
  Lower `JOBS`, or give Docker Desktop more memory.
- **`... is imported by the Windows executables but was not found`**: a MinGW
  runtime DLL the toolchain links against is missing from the image. Report
  the DLL name; the lookup lives in `find_mingw_dll` in `container-build.sh`.
- **`is not statically linked`** from the Linux target: something pulled in a
  library with no static half. `ldd` the binary in `build-docker/linux-x86_64/src`
  to see which.
- **Stale configuration after switching branches**: `CLEAN=1`. This clears the
  Flutter build directories under `extras/` as well as the CMake trees.
- **`... is not in this checkout`** from `gui`, `web` or `android`: that app is
  not in the branch you are building. The three live in `extras/desktop-wallet`,
  `extras/web-wallet` and `extras/mobile-wallet`.
- **`build.gradle packages ABI '<abi>' but ANDROID_ABIS does not build it`**:
  the two lists disagree. Either add the ABI to `ANDROID_ABIS` or remove it
  from `abiFilters`; shipping an app whose `abiFilters` promises an ABI with
  no library behind it installs cleanly and fails on the first wallet call.
- **The web wallet loads but reports it needs a cross-origin isolated page**:
  the server is not sending `Cross-Origin-Opener-Policy: same-origin` and
  `Cross-Origin-Embedder-Policy: require-corp`. The module is built with
  threads, which need `SharedArrayBuffer`, which the browser only grants an
  isolated page. `SERVING.txt` in the package has an nginx block.
- **Gradle cannot reach the network**: unlike the C++ targets, the first
  Android build resolves dependencies from Maven. It is not offline-capable
  the way the pinned toolchains are.
- **Windows host, Git Bash**: `build.sh` converts paths for Docker Desktop
  itself. Check the repository out with LF line endings for the scripts under
  `scripts/docker/`.
