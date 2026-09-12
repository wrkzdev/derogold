# DeroGold release builder image.
#
# One image carries the toolchains the portable release set needs:
#   - the native GCC of the base image   -> Linux x86_64 (fully static)
#   - MinGW-w64 (posix threads) + a static OpenSSL built for the Windows target
#                                        -> Windows x86_64
#
# The repository is never copied into the image. build.sh bind-mounts it at run
# time, so the image only changes when one of the pinned versions below does.
# The build context is this directory:
#
#   docker build -t derogold-builder -f scripts/docker/Dockerfile scripts/docker
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
