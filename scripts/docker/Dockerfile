# DeroGold release builder image.
#
# One image carries the toolchains the portable release set needs:
#   - the native GCC of the base image   -> Linux x86_64 (fully static)
#   - MinGW-w64 (posix threads) + a static OpenSSL built for the Windows target
#                                        -> Windows x86_64
#   - the aarch64 cross toolchain + a static OpenSSL built for it
#                                        -> Linux ARM64 (fully static)
#
# It also carries the toolchains the apps need - Flutter, the Android SDK/NDK
# and Emscripten - for the GUI, Android and web targets.
#
# The repository is never copied into the image. build.sh bind-mounts it at run
# time, so the image only changes when one of the pinned versions below does.
# The build context is scripts/, not scripts/docker/, because the image builds
# libucontext during its own build and needs that script:
#
#   docker build -t derogold-builder -f scripts/docker/Dockerfile scripts
#
# Every ARG can be overridden with --build-arg (build.sh passes
# IMAGE_BUILD_ARGS straight through).
#
# 22.04 rather than 24.04: it is what the published releases are built on, and
# its gcc-11/12 clears the floor the bundled RocksDB needs (C++20 `using
# enum`). The Linux package is statically linked, so the base image's glibc
# only bounds what the *Windows* cross-build and the build tools see, but
# keeping the two aligned means a package built here behaves like a release.

ARG UBUNTU_VERSION=22.04
FROM ubuntu:${UBUNTU_VERSION}

ARG DEBIAN_FRONTEND=noninteractive

# Static OpenSSL for the Windows target. The Linux target links the static
# libraries out of the base image's libssl-dev.
ARG OPENSSL_VERSION=3.5.8

# ---------------------------------------------------------------------------
# Host packages: native toolchain, the MinGW-w64 cross toolchain, build tools.
# Only the x86_64 posix-thread MinGW flavour is installed; the "mingw-w64"
# metapackage would also pull the i686 and win32-thread variants, and the
# win32-thread one has no std::thread.
#
# CMake comes from apt.kitware.com: 22.04 ships 3.22, and the vendored RocksDB
# expects newer. Same source Dockerfile and Dockerfile.portable use.
# ---------------------------------------------------------------------------
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gpg \
 && curl -fsSL https://apt.kitware.com/keys/kitware-archive-latest.asc \
      | gpg --dearmor - > /usr/share/keyrings/kitware-archive-keyring.gpg \
 && . /etc/os-release \
 && echo "deb [signed-by=/usr/share/keyrings/kitware-archive-keyring.gpg] https://apt.kitware.com/ubuntu/ ${UBUNTU_CODENAME} main" \
      > /etc/apt/sources.list.d/kitware.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
      cmake \
      ninja-build \
      pkg-config \
      ccache \
      git \
      unzip \
      zip \
      xz-utils \
      file \
      perl \
      make \
      python3 \
      libssl-dev \
      zlib1g-dev \
      gcc-mingw-w64-x86-64-posix \
      g++-mingw-w64-x86-64-posix \
      binutils-mingw-w64-x86-64 \
      mingw-w64-x86-64-dev \
      crossbuild-essential-arm64 \
 && (update-alternatives --set x86_64-w64-mingw32-gcc /usr/bin/x86_64-w64-mingw32-gcc-posix || true) \
 && (update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix || true) \
 && rm -rf /var/lib/apt/lists/* \
 && cmake --version | head -1 \
 && g++ --version | head -1

# ---------------------------------------------------------------------------
# OpenSSL for the Windows target. --libdir=lib so the layout is the same
# whatever OpenSSL's default for the mingw64 target is;
# CMake/windows-x64-mingw-cross.cmake finds it through CROSS_PREFIX, which
# container-build.sh points here.
# ---------------------------------------------------------------------------
ENV DEROGOLD_MINGW_PREFIX_DIR=/opt/toolchain/windows-x86_64/prefix
RUN set -eux; \
    mkdir -p /tmp/openssl; \
    cd /tmp/openssl; \
    curl -fsSL -o openssl.tar.gz \
      "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"; \
    tar xzf openssl.tar.gz; \
    cd "openssl-${OPENSSL_VERSION}"; \
    ./Configure mingw64 \
        no-shared \
        no-tests \
        no-module \
        --cross-compile-prefix=x86_64-w64-mingw32- \
        --prefix="${DEROGOLD_MINGW_PREFIX_DIR}" \
        --libdir=lib \
        --openssldir="${DEROGOLD_MINGW_PREFIX_DIR}/ssl"; \
    make -j"$(nproc)"; \
    make install_sw; \
    cd /; \
    rm -rf /tmp/openssl; \
    test -f "${DEROGOLD_MINGW_PREFIX_DIR}/lib/libcrypto.a"; \
    test -f "${DEROGOLD_MINGW_PREFIX_DIR}/lib/libssl.a"

# ---------------------------------------------------------------------------
# OpenSSL for the Linux ARM64 target.
#
# The host's libssl-dev is x86_64 and cannot be linked into an aarch64 binary.
# Building it here rather than pulling libssl-dev:arm64 through multiarch keeps
# this to one mechanism, the same one the Windows target uses, and gives static
# libraries -static can actually use.
# ---------------------------------------------------------------------------
ENV DEROGOLD_ARM64_PREFIX_DIR=/opt/toolchain/linux-arm64/prefix
RUN set -eux; \
    mkdir -p /tmp/openssl-arm64; \
    cd /tmp/openssl-arm64; \
    curl -fsSL -o openssl.tar.gz \
      "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"; \
    tar xzf openssl.tar.gz; \
    cd "openssl-${OPENSSL_VERSION}"; \
    ./Configure linux-aarch64 \
        no-shared \
        no-tests \
        no-module \
        --cross-compile-prefix=aarch64-linux-gnu- \
        --prefix="${DEROGOLD_ARM64_PREFIX_DIR}" \
        --libdir=lib \
        --openssldir="${DEROGOLD_ARM64_PREFIX_DIR}/ssl"; \
    make -j"$(nproc)"; \
    make install_sw; \
    cd /; \
    rm -rf /tmp/openssl-arm64; \
    test -f "${DEROGOLD_ARM64_PREFIX_DIR}/lib/libcrypto.a"; \
    test -f "${DEROGOLD_ARM64_PREFIX_DIR}/lib/libssl.a"

# ===========================================================================
# App toolchains: the GUI wallet, the web wallet and the Android wallet.
#
# These are much larger than everything above - together they roughly quadruple
# the image - and none of them is needed to build the CLI packages. They are
# here anyway, in one image, because the alternative is two images to keep in
# step, and a release needs all of it.
# ===========================================================================

# ---------------------------------------------------------------------------
# Packages the three app toolchains need:
#   - GTK, clang: Flutter's Linux desktop build
#   - JDK: Gradle, for Android
#   - the rest: what the SDKs and emsdk want at run time
# ---------------------------------------------------------------------------
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      clang \
      libgtk-3-dev \
      liblzma-dev \
      libglu1-mesa \
      libstdc++-12-dev \
      openjdk-17-jdk-headless \
      lib32stdc++6 \
      lib32z1 \
      python3-pip \
      wget \
 && rm -rf /var/lib/apt/lists/*

# Flutter and the Android SDK both run git inside directories this image owns
# but the build does not: build.sh runs the container as the calling host user,
# and git refuses to work in a tree owned by somebody else. Marking every path
# safe is right for a throwaway builder image and wrong anywhere else.
RUN git config --system --add safe.directory '*'

# ---------------------------------------------------------------------------
# Flutter. Cloned at a tag rather than unpacked from a tarball, because that is
# how Flutter expects to live - it runs git on its own directory to work out
# its version, and a tarball-installed SDK trips over that.
#
# 3.38.0 is the floor: extras/mobile-wallet/pubspec.yaml asks for
# flutter >= 3.38.0 and a Dart SDK of ^3.10.7.
# ---------------------------------------------------------------------------
ARG FLUTTER_VERSION=3.38.0
ENV FLUTTER_HOME=/opt/flutter
ENV PATH="${FLUTTER_HOME}/bin:${FLUTTER_HOME}/bin/cache/dart-sdk/bin:${PATH}"
RUN set -eux; \
    git clone --depth 1 --branch "${FLUTTER_VERSION}" \
      https://github.com/flutter/flutter.git "${FLUTTER_HOME}"; \
    flutter --version; \
    flutter config --no-analytics --enable-linux-desktop --enable-web; \
    # Pull the build artifacts now so no build has to download them, and so a
    # container with no network can still produce a package.
    flutter precache --universal --linux --web; \
    # The SDK caches into its own directory, and the build runs as an
    # arbitrary uid.
    chmod -R a+rwX "${FLUTTER_HOME}"

# ---------------------------------------------------------------------------
# Android SDK and NDK.
#
# The NDK is what cross-compiles libwallet_capi.so for each ABI; the SDK and
# build-tools are what Gradle assembles the APK and AAB with.
# ---------------------------------------------------------------------------
ARG ANDROID_CMDLINE_TOOLS=11076708
ARG ANDROID_PLATFORM_VERSION=35
ARG ANDROID_BUILD_TOOLS=35.0.0
ARG ANDROID_NDK_VERSION=26.3.11579264
ENV ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_HOME=/opt/android-sdk
ENV ANDROID_NDK_HOME=${ANDROID_SDK_ROOT}/ndk/${ANDROID_NDK_VERSION}
ENV PATH="${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${PATH}"
RUN set -eux; \
    mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools"; \
    cd /tmp; \
    curl -fsSL -o tools.zip \
      "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS}_latest.zip"; \
    unzip -q tools.zip -d "${ANDROID_SDK_ROOT}/cmdline-tools"; \
    mv "${ANDROID_SDK_ROOT}/cmdline-tools/cmdline-tools" "${ANDROID_SDK_ROOT}/cmdline-tools/latest"; \
    rm -f tools.zip; \
    yes | sdkmanager --licenses >/dev/null; \
    sdkmanager --install \
      "platform-tools" \
      "platforms;android-${ANDROID_PLATFORM_VERSION}" \
      "build-tools;${ANDROID_BUILD_TOOLS}" \
      "ndk;${ANDROID_NDK_VERSION}" >/dev/null; \
    test -d "${ANDROID_NDK_HOME}"; \
    chmod -R a+rwX "${ANDROID_SDK_ROOT}"

# ---------------------------------------------------------------------------
# libucontext, for Android only.
#
# bionic has no getcontext/setcontext/makecontext/swapcontext, which the fibre
# dispatcher needs. Built once here, per ABI, rather than on every build; see
# scripts/build-libucontext-android.sh, which this runs.
# ---------------------------------------------------------------------------
ARG LIBUCONTEXT_VERSION=1.2
ARG ANDROID_API=21
ENV DEROGOLD_LIBUCONTEXT_DIR=/opt/toolchain/android/libucontext
COPY build-libucontext-android.sh /tmp/build-libucontext-android.sh
RUN set -eux; \
    PREFIX="${DEROGOLD_LIBUCONTEXT_DIR}" \
    LIBUCONTEXT_VERSION="${LIBUCONTEXT_VERSION}" \
    API="${ANDROID_API}" \
    bash /tmp/build-libucontext-android.sh arm64-v8a armeabi-v7a x86_64; \
    rm -f /tmp/build-libucontext-android.sh; \
    test -f "${DEROGOLD_LIBUCONTEXT_DIR}/arm64-v8a/lib/libucontext.a"; \
    chmod -R a+rwX "${DEROGOLD_LIBUCONTEXT_DIR}"

# ---------------------------------------------------------------------------
# Emscripten, for the web wallet's WebAssembly module.
#
# Pinned: the module is linked with pthreads and a raised stack, and the
# meaning of those flags has moved between emsdk releases.
# ---------------------------------------------------------------------------
ARG EMSDK_VERSION=3.1.64
ENV EMSDK=/opt/emsdk
RUN set -eux; \
    git clone --depth 1 https://github.com/emscripten-core/emsdk.git "${EMSDK}"; \
    cd "${EMSDK}"; \
    ./emsdk install "${EMSDK_VERSION}"; \
    ./emsdk activate "${EMSDK_VERSION}"; \
    chmod -R a+rwX "${EMSDK}"
# Not put on PATH: emsdk wants to be sourced (it sets EM_CONFIG and the cache
# location as well as PATH). container-build.sh sources emsdk_env.sh in the web
# target only, so the other targets keep the plain host toolchain.
ENV EMSDK_ENV="${EMSDK}/emsdk_env.sh"

# The Emscripten cache lives inside the SDK and is written on first use, which
# is a build running as an arbitrary uid. Warm it here so that write happens
# while we are still root - and with pthreads, since that is what the wallet
# module is built with and the threaded sysroot is compiled separately.
RUN set -eux; \
    . "${EMSDK_ENV}"; \
    embuilder build libc libc++ libc++abi libemmalloc --pthreads || true; \
    chmod -R a+rwX "${EMSDK}"

# ---------------------------------------------------------------------------
# Run-time layout. build.sh mounts the repo at /work, the build tree at /build
# and the package directory at /out, and runs the container as the calling host
# user so nothing comes back root-owned. HOME lives under /tmp so an arbitrary
# uid always has a writable home.
# ---------------------------------------------------------------------------
ENV HOME=/tmp/derogold-home \
    CCACHE_DIR=/build/.ccache
RUN mkdir -p /work /build /out /tmp/derogold-home \
 && chmod 1777 /work /build /out /tmp/derogold-home

WORKDIR /work
CMD ["bash"]
