# Dependency resolution for DeroGold.
#
# Each function below produces the imported target that src/CMakeLists.txt
# links against, so the link lines do not care where a library came from.
#
# Everything here uses plain CMake and system packages. There is deliberately
# no package manager and nothing is downloaded during the build: everything
# that is not a plain system package lives under external/ and is compiled with
# the project.

include(FindPackageHandleStandardArgs)

# Version of the RocksDB copy checked into external/rocksdb. Informational;
# change it only when that tree is replaced.
set(DEROGOLD_ROCKSDB_VERSION "11.8.1")

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

# Crypto++ and miniupnpc are built from the copies checked into external/.
# Both are small and neither is reliably packaged across the platforms this
# project targets, so vendoring them removes two install steps and any question
# of which version is present. Nothing here consults the system for them.
function(derogold_add_cryptopp)
    if(TARGET cryptopp::cryptopp)
        return()
    endif()

    set(_src "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../external/cryptopp")

    if(NOT EXISTS "${_src}/CMakeLists.txt")
        message(FATAL_ERROR "external/cryptopp is missing from the checkout.")
    endif()

    # Static only, and none of the extras. These option names are prefixed in
    # the vendored CMakeLists precisely so setting them here cannot disturb the
    # enclosing project.
    set(CRYPTOPP_BUILD_STATIC ON CACHE BOOL "" FORCE)
    set(CRYPTOPP_BUILD_SHARED OFF CACHE BOOL "" FORCE)
    set(CRYPTOPP_BUILD_TESTING OFF CACHE BOOL "" FORCE)
    set(CRYPTOPP_BUILD_DOCUMENTATION OFF CACHE BOOL "" FORCE)

    add_subdirectory("${_src}" "${CMAKE_BINARY_DIR}/external/cryptopp" EXCLUDE_FROM_ALL)

    if(NOT TARGET cryptopp-static)
        message(FATAL_ERROR "The vendored Crypto++ did not produce a static library target.")
    endif()

    add_library(cryptopp::cryptopp ALIAS cryptopp-static)

    # DeroGold includes <cryptopp/sha.h>, so the headers have to be reachable
    # under a cryptopp/ prefix. They sit flat in the source tree, so mirror
    # them into the build tree once and expose that.
    set(_compat "${CMAKE_BINARY_DIR}/external/include")

    file(GLOB _cryptopp_headers "${_src}/*.h")
    file(COPY ${_cryptopp_headers} DESTINATION "${_compat}/cryptopp")

    target_include_directories(cryptopp-static INTERFACE "$<BUILD_INTERFACE:${_compat}>")

    message(STATUS "Crypto++: building the copy in external/cryptopp")
endfunction()

function(derogold_add_miniupnpc)
    if(TARGET miniupnpc::miniupnpc)
        return()
    endif()

    set(_src "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../external/miniupnpc")

    if(NOT EXISTS "${_src}/CMakeLists.txt")
        message(FATAL_ERROR "external/miniupnpc is missing from the checkout.")
    endif()

    set(UPNPC_BUILD_STATIC ON CACHE BOOL "" FORCE)
    set(UPNPC_BUILD_SHARED OFF CACHE BOOL "" FORCE)
    set(UPNPC_BUILD_TESTS OFF CACHE BOOL "" FORCE)
    set(UPNPC_BUILD_SAMPLE OFF CACHE BOOL "" FORCE)
    set(UPNPC_NO_INSTALL ON CACHE BOOL "" FORCE)

    add_subdirectory("${_src}" "${CMAKE_BINARY_DIR}/external/miniupnpc" EXCLUDE_FROM_ALL)

    if(NOT TARGET libminiupnpc-static)
        message(FATAL_ERROR "The vendored miniupnpc did not produce a static library target.")
    endif()

    # Upstream already aliases miniupnpc::miniupnpc when only the static
    # library is built; define it ourselves if that ever changes.
    if(NOT TARGET miniupnpc::miniupnpc)
        add_library(miniupnpc::miniupnpc ALIAS libminiupnpc-static)
    endif()

    # Same prefix problem as Crypto++: DeroGold includes
    # <miniupnpc/miniupnpc.h> because that is how the headers are installed
    # system-wide, but in the source tree they are flat under include/.
    set(_compat "${CMAKE_BINARY_DIR}/external/include")

    file(GLOB _miniupnpc_headers "${_src}/include/*.h")
    file(COPY ${_miniupnpc_headers} DESTINATION "${_compat}/miniupnpc")

    target_include_directories(libminiupnpc-static INTERFACE "$<BUILD_INTERFACE:${_compat}>")

    message(STATUS "miniupnpc: building the copy in external/miniupnpc")
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
                "-D DEROGOLD_SYSTEM_ROCKSDB=ON to build the "
                "${DEROGOLD_ROCKSDB_VERSION} copy in external/rocksdb instead.")
        endif()

        message(STATUS "RocksDB: system install ${RocksDB_VERSION}")
        return()
    endif()

    message(STATUS "RocksDB: building the ${DEROGOLD_ROCKSDB_VERSION} copy in external/rocksdb")

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

    set(_src "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../external/rocksdb")

    if(NOT EXISTS "${_src}/CMakeLists.txt")
        message(FATAL_ERROR "external/rocksdb is missing from the checkout.")
    endif()

    add_subdirectory("${_src}" "${CMAKE_BINARY_DIR}/external/rocksdb" EXCLUDE_FROM_ALL)

    # RocksDB's own CMake exports "rocksdb"; the rest of this project links the
    # namespaced name, so bridge the two.
    if(TARGET rocksdb AND NOT TARGET RocksDB::rocksdb)
        add_library(RocksDB::rocksdb ALIAS rocksdb)
    endif()

    if(NOT TARGET RocksDB::rocksdb)
        message(FATAL_ERROR "The vendored RocksDB did not define a usable target.")
    endif()

    # RocksDB does not always attach its own include directory to the target
    # when consumed this way.
    target_include_directories(rocksdb PUBLIC "${_src}/include")

    # RocksDB 10 and newer use defaulted comparison operators in their *public*
    # headers, so it is not only RocksDB's own sources that need C++20: every
    # file of ours that includes one does too. Requiring it on the interface
    # raises those translation units to C++20 and leaves the rest of the
    # project on C++17.
    target_compile_features(rocksdb INTERFACE cxx_std_20)
endfunction()
