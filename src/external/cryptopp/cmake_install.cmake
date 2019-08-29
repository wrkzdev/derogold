# Install script for directory: /root/derogold-dev/rev-rebase-test/external/cryptopp

# Set the install prefix
if(NOT DEFINED CMAKE_INSTALL_PREFIX)
  set(CMAKE_INSTALL_PREFIX "/usr/local")
endif()
string(REGEX REPLACE "/$" "" CMAKE_INSTALL_PREFIX "${CMAKE_INSTALL_PREFIX}")

# Set the install configuration name.
if(NOT DEFINED CMAKE_INSTALL_CONFIG_NAME)
  if(BUILD_TYPE)
    string(REGEX REPLACE "^[^A-Za-z0-9_]+" ""
           CMAKE_INSTALL_CONFIG_NAME "${BUILD_TYPE}")
  else()
    set(CMAKE_INSTALL_CONFIG_NAME "")
  endif()
  message(STATUS "Install configuration: \"${CMAKE_INSTALL_CONFIG_NAME}\"")
endif()

# Set the component getting installed.
if(NOT CMAKE_INSTALL_COMPONENT)
  if(COMPONENT)
    message(STATUS "Install component: \"${COMPONENT}\"")
    set(CMAKE_INSTALL_COMPONENT "${COMPONENT}")
  else()
    set(CMAKE_INSTALL_COMPONENT)
  endif()
endif()

# Install shared libraries without execute permission?
if(NOT DEFINED CMAKE_INSTALL_SO_NO_EXE)
  set(CMAKE_INSTALL_SO_NO_EXE "1")
endif()

# Is this installation the result of a crosscompile?
if(NOT DEFINED CMAKE_CROSSCOMPILING)
  set(CMAKE_CROSSCOMPILING "FALSE")
endif()

if("x${CMAKE_INSTALL_COMPONENT}x" STREQUAL "xUnspecifiedx" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE STATIC_LIBRARY FILES "/root/derogold-dev/rev-rebase-test/src/external/cryptopp/libcryptopp.a")
endif()

if("x${CMAKE_INSTALL_COMPONENT}x" STREQUAL "xUnspecifiedx" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/include/cryptopp" TYPE FILE FILES
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/3way.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/adler32.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/adv_simd.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/aes.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/aes_armv4.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/algebra.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/algparam.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/arc4.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/argnames.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/aria.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/arm_simd.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/asn.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/authenc.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/base32.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/base64.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/basecode.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/blake2.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/blowfish.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/blumshub.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/camellia.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/cast.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/cbcmac.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/ccm.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/chacha.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/chachapoly.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/cham.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/channels.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/cmac.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/config.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/cpu.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/crc.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/cryptlib.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/darn.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/default.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/des.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/dh.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/dh2.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/dll.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/dmac.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/donna.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/donna_32.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/donna_64.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/donna_sse.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/drbg.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/dsa.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/eax.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/ec2n.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/eccrypto.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/ecp.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/ecpoint.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/elgamal.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/emsa2.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/eprecomp.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/esign.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/factory.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/fhmqv.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/files.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/filters.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/fips140.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/fltrimpl.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/gcm.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/gf256.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/gf2_32.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/gf2n.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/gfpcrypt.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/gost.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/gzip.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/hashfwd.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/hc128.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/hc256.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/hex.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/hight.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/hkdf.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/hmac.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/hmqv.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/hrtimer.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/ida.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/idea.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/integer.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/iterhash.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/kalyna.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/keccak.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/lea.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/lubyrack.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/luc.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/mars.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/md2.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/md4.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/md5.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/mdc.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/mersenne.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/misc.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/modarith.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/modes.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/modexppc.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/mqueue.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/mqv.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/naclite.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/nbtheory.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/nr.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/oaep.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/oids.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/osrng.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/ossig.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/padlkrng.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/panama.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/pch.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/pkcspad.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/poly1305.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/polynomi.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/ppc_simd.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/pssr.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/pubkey.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/pwdbased.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/queue.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/rabbit.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/rabin.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/randpool.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/rc2.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/rc5.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/rc6.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/rdrand.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/resource.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/rijndael.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/ripemd.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/rng.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/rsa.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/rw.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/safer.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/salsa.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/scrypt.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/seal.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/secblock.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/seckey.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/seed.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/serpent.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/serpentp.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/sha.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/sha3.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/shacal2.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/shake.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/shark.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/simeck.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/simon.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/simple.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/siphash.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/skipjack.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/sm3.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/sm4.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/smartptr.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/sosemanuk.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/speck.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/square.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/stdcpp.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/strciphr.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/tea.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/threefish.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/tiger.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/trap.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/trunhash.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/ttmac.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/tweetnacl.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/twofish.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/vmac.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/wake.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/whrlpool.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/words.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/xed25519.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/xtr.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/xtrcrypt.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/zdeflate.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/zinflate.h"
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/zlib.h"
    )
endif()

if("x${CMAKE_INSTALL_COMPONENT}x" STREQUAL "xUnspecifiedx" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/cmake/cryptopp" TYPE FILE FILES
    "/root/derogold-dev/rev-rebase-test/external/cryptopp/cryptopp-config.cmake"
    "/root/derogold-dev/rev-rebase-test/src/external/cryptopp/cryptopp-config-version.cmake"
    )
endif()

if("x${CMAKE_INSTALL_COMPONENT}x" STREQUAL "xUnspecifiedx" OR NOT CMAKE_INSTALL_COMPONENT)
  if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/cryptopp/cryptopp-targets.cmake")
    file(DIFFERENT EXPORT_FILE_CHANGED FILES
         "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/cryptopp/cryptopp-targets.cmake"
         "/root/derogold-dev/rev-rebase-test/src/external/cryptopp/CMakeFiles/Export/lib/cmake/cryptopp/cryptopp-targets.cmake")
    if(EXPORT_FILE_CHANGED)
      file(GLOB OLD_CONFIG_FILES "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/cryptopp/cryptopp-targets-*.cmake")
      if(OLD_CONFIG_FILES)
        message(STATUS "Old export file \"$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/cryptopp/cryptopp-targets.cmake\" will be replaced.  Removing files [${OLD_CONFIG_FILES}].")
        file(REMOVE ${OLD_CONFIG_FILES})
      endif()
    endif()
  endif()
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/cmake/cryptopp" TYPE FILE FILES "/root/derogold-dev/rev-rebase-test/src/external/cryptopp/CMakeFiles/Export/lib/cmake/cryptopp/cryptopp-targets.cmake")
  if("${CMAKE_INSTALL_CONFIG_NAME}" MATCHES "^()$")
    file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/cmake/cryptopp" TYPE FILE FILES "/root/derogold-dev/rev-rebase-test/src/external/cryptopp/CMakeFiles/Export/lib/cmake/cryptopp/cryptopp-targets-noconfig.cmake")
  endif()
endif()

