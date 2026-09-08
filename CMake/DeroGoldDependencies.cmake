# Dependency resolution for DeroGold.
#
# Each function below produces the imported target that src/CMakeLists.txt
# links against, so the link lines do not care where a library came from.
#
# Everything here uses plain CMake and system packages. There is deliberately
# no package manager: the header-only libraries are vendored under external/,
# and the rest are ordinary distribution packages. The one exception is
# RocksDB, which is built from source by default because this code needs a
# newer release than most distributions carry.

include(FetchContent)
include(FindPackageHandleStandardArgs)

# Version of RocksDB built when DEROGOLD_SYSTEM_ROCKSDB is OFF.
set(DEROGOLD_ROCKSDB_VERSION "11.8.1" CACHE STRING "RocksDB version to build from source")

# Oldest RocksDB accepted when using a system install. RocksDBWrapper calls
# WaitForCompact(WaitForCompactOptions), which was added in 8.1.
set(DEROGOLD_ROCKSDB_MINIMUM "8.1")

# Emit a consistent "install this" message and stop.
function(_derogold_missing_dependency name debian fedora arch brew)
    message(FATAL_ERROR
        "Could not find ${name}.\n"
        "Install it with one of:\n"
        "  Debian/Ubuntu: sudo apt install ${debian}\n"
        "  Fedora/RHEL:   sudo dnf install ${fedora}\n"
        "  Arch:          sudo pacman -S ${arch}\n"
        "  macOS:         brew install ${brew}\n"
        "See BUILDING.md for the full list.")
endfunction()

function(derogold_require_boost)
    # Header-only components plus the compiled serialization library.
    find_package(Boost QUIET COMPONENTS serialization)

    if(NOT Boost_FOUND)
        _derogold_missing_dependency("Boost (with the serialization component)"
            "libboost-serialization-dev" "boost-devel" "boost" "boost")
    endif()

    # Older FindBoost modules do not define the namespaced targets, so create
    # them when they are absent to keep the link lines identical either way.
    if(NOT TARGET Boost::boost)
        add_library(Boost::boost INTERFACE IMPORTED GLOBAL)
        set_target_properties(Boost::boost PROPERTIES
            INTERFACE_INCLUDE_DIRECTORIES "${Boost_INCLUDE_DIRS}")
    endif()

    if(NOT TARGET Boost::serialization)
        add_library(Boost::serialization UNKNOWN IMPORTED GLOBAL)
        set_target_properties(Boost::serialization PROPERTIES
            IMPORTED_LOCATION "${Boost_SERIALIZATION_LIBRARY}"
            INTERFACE_INCLUDE_DIRECTORIES "${Boost_INCLUDE_DIRS}")
    endif()

    message(STATUS "Boost: ${Boost_VERSION} (${Boost_INCLUDE_DIRS})")
endfunction()

function(derogold_require_openssl)
    # Shipped with CMake, so nothing to shim.
    find_package(OpenSSL QUIET)

    if(NOT OpenSSL_FOUND)
        _derogold_missing_dependency("OpenSSL"
            "libssl-dev" "openssl-devel" "openssl" "openssl@3")
    endif()

    message(STATUS "OpenSSL: ${OPENSSL_VERSION}")
endfunction()

function(derogold_require_cryptopp)
    if(TARGET cryptopp::cryptopp)
        return()
    endif()

    # Upstream and vcpkg ship a CMake config; distributions usually do not.
    find_package(cryptopp CONFIG QUIET)

    if(TARGET cryptopp::cryptopp)
        message(STATUS "Crypto++: found via CMake config")
        return()
    endif()

    # Fall back to pkg-config, then to a plain library search. Debian names the
    # package libcrypto++ while most others use libcryptopp.
    find_package(PkgConfig QUIET)

    if(PkgConfig_FOUND)
        pkg_check_modules(PC_CRYPTOPP QUIET libcrypto++ libcryptopp cryptopp)
    endif()

    find_path(CRYPTOPP_INCLUDE_DIR
        NAMES cryptopp/cryptlib.h crypto++/cryptlib.h
        HINTS ${PC_CRYPTOPP_INCLUDE_DIRS})

    find_library(CRYPTOPP_LIBRARY
        NAMES cryptopp crypto++ libcryptopp
        HINTS ${PC_CRYPTOPP_LIBRARY_DIRS})

    if(NOT CRYPTOPP_INCLUDE_DIR OR NOT CRYPTOPP_LIBRARY)
        _derogold_missing_dependency("Crypto++"
            "libcrypto++-dev" "cryptopp-devel" "crypto++" "cryptopp")
    endif()

    add_library(cryptopp::cryptopp UNKNOWN IMPORTED GLOBAL)
    set_target_properties(cryptopp::cryptopp PROPERTIES
        IMPORTED_LOCATION "${CRYPTOPP_LIBRARY}"
        INTERFACE_INCLUDE_DIRECTORIES "${CRYPTOPP_INCLUDE_DIR}")

    message(STATUS "Crypto++: ${CRYPTOPP_LIBRARY}")
endfunction()

function(derogold_require_miniupnpc)
    if(TARGET miniupnpc::miniupnpc)
        return()
    endif()

    find_package(miniupnpc CONFIG QUIET)

    if(TARGET miniupnpc::miniupnpc)
        message(STATUS "miniupnpc: found via CMake config")
        return()
    endif()

    find_package(PkgConfig QUIET)

    if(PkgConfig_FOUND)
        pkg_check_modules(PC_MINIUPNPC QUIET miniupnpc)
    endif()

    find_path(MINIUPNPC_INCLUDE_DIR
        NAMES miniupnpc/miniupnpc.h
        HINTS ${PC_MINIUPNPC_INCLUDE_DIRS})

    find_library(MINIUPNPC_LIBRARY
        NAMES miniupnpc
        HINTS ${PC_MINIUPNPC_LIBRARY_DIRS})

    if(NOT MINIUPNPC_INCLUDE_DIR OR NOT MINIUPNPC_LIBRARY)
        _derogold_missing_dependency("miniupnpc"
            "libminiupnpc-dev" "miniupnpc-devel" "miniupnpc" "miniupnpc")
    endif()

    add_library(miniupnpc::miniupnpc UNKNOWN IMPORTED GLOBAL)
    set_target_properties(miniupnpc::miniupnpc PROPERTIES
        IMPORTED_LOCATION "${MINIUPNPC_LIBRARY}"
        INTERFACE_INCLUDE_DIRECTORIES "${MINIUPNPC_INCLUDE_DIR}")

    message(STATUS "miniupnpc: ${MINIUPNPC_LIBRARY}")
endfunction()

function(derogold_require_rocksdb)
    if(DEROGOLD_SYSTEM_ROCKSDB)
        find_package(RocksDB CONFIG QUIET)

        if(NOT TARGET RocksDB::rocksdb)
            _derogold_missing_dependency("RocksDB ${DEROGOLD_ROCKSDB_MINIMUM} or newer"
                "librocksdb-dev" "rocksdb-devel" "rocksdb" "rocksdb")
        endif()

        if(RocksDB_VERSION AND RocksDB_VERSION VERSION_LESS DEROGOLD_ROCKSDB_MINIMUM)
            message(FATAL_ERROR
                "Found RocksDB ${RocksDB_VERSION}, but this code needs "
                "${DEROGOLD_ROCKSDB_MINIMUM} or newer. Re-run without "
                "-D DEROGOLD_SYSTEM_ROCKSDB=ON to build "
                "${DEROGOLD_ROCKSDB_VERSION} from source instead.")
        endif()

        message(STATUS "RocksDB: system install ${RocksDB_VERSION}")
        return()
    endif()

    message(STATUS "RocksDB: building ${DEROGOLD_ROCKSDB_VERSION} from source")

    # Compression: the wrapper writes with kZSTD when compression is enabled,
    # so an existing database cannot be opened without zstd support. Keep the
    # rest off; nothing here uses them.
    set(WITH_ZSTD ON CACHE BOOL "" FORCE)
    set(WITH_SNAPPY OFF CACHE BOOL "" FORCE)
    set(WITH_LZ4 OFF CACHE BOOL "" FORCE)
    set(WITH_BZ2 OFF CACHE BOOL "" FORCE)
    set(WITH_ZLIB OFF CACHE BOOL "" FORCE)

    # Trim everything we do not link against; this is most of the build time.
    set(WITH_GFLAGS OFF CACHE BOOL "" FORCE)
    set(WITH_TESTS OFF CACHE BOOL "" FORCE)
    set(WITH_ALL_TESTS OFF CACHE BOOL "" FORCE)
    set(WITH_BENCHMARK_TOOLS OFF CACHE BOOL "" FORCE)
    set(WITH_TOOLS OFF CACHE BOOL "" FORCE)
    set(WITH_CORE_TOOLS OFF CACHE BOOL "" FORCE)
    set(WITH_EXAMPLES OFF CACHE BOOL "" FORCE)
    set(BENCHMARK_ENABLE_GTEST_TESTS OFF CACHE BOOL "" FORCE)

    # Static, and portable rather than tuned for the building machine, so a
    # binary built on one host still runs on another.
    set(ROCKSDB_BUILD_SHARED OFF CACHE BOOL "" FORCE)
    set(PORTABLE ON CACHE STRING "" FORCE)
    set(USE_RTTI ON CACHE BOOL "" FORCE)
    set(FAIL_ON_WARNINGS OFF CACHE BOOL "" FORCE)

    # RocksDB 10 and newer declare C++20 as their own default. Let it have
    # that rather than forcing this project's C++17 on it, which is not a
    # combination upstream builds or tests. This assignment is scoped to this
    # function, so it reaches the RocksDB subdirectory and nothing else; the
    # two standards share an ABI under the same compiler, and only RocksDB's
    # own API crosses the boundary.
    #
    # This is what raises the compiler floor to roughly GCC 11 or Clang 14.
    # Older toolchains should pass -D DEROGOLD_SYSTEM_ROCKSDB=ON instead.
    set(CMAKE_CXX_STANDARD 20)
    set(CMAKE_CXX_STANDARD_REQUIRED ON)

    FetchContent_Declare(rocksdb
        URL "https://github.com/facebook/rocksdb/archive/refs/tags/v${DEROGOLD_ROCKSDB_VERSION}.tar.gz"
        DOWNLOAD_EXTRACT_TIMESTAMP TRUE)

    FetchContent_MakeAvailable(rocksdb)

    # RocksDB's own CMake exports "rocksdb"; the rest of this project links the
    # namespaced name, so bridge the two.
    if(TARGET rocksdb AND NOT TARGET RocksDB::rocksdb)
        add_library(RocksDB::rocksdb ALIAS rocksdb)
    endif()

    if(NOT TARGET RocksDB::rocksdb)
        message(FATAL_ERROR "RocksDB was fetched but did not define a usable target.")
    endif()

    # RocksDB does not always attach its own include directory to the target
    # when consumed this way.
    target_include_directories(rocksdb PUBLIC "${rocksdb_SOURCE_DIR}/include")
endfunction()
