# Install script for directory: /root/derogold-dev/rev-rebase-test/external/miniupnpc

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
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/include/miniupnpc" TYPE FILE FILES
    "/root/derogold-dev/rev-rebase-test/external/miniupnpc/miniupnpc.h"
    "/root/derogold-dev/rev-rebase-test/external/miniupnpc/miniwget.h"
    "/root/derogold-dev/rev-rebase-test/external/miniupnpc/upnpcommands.h"
    "/root/derogold-dev/rev-rebase-test/external/miniupnpc/igd_desc_parse.h"
    "/root/derogold-dev/rev-rebase-test/external/miniupnpc/upnpreplyparse.h"
    "/root/derogold-dev/rev-rebase-test/external/miniupnpc/upnperrors.h"
    "/root/derogold-dev/rev-rebase-test/external/miniupnpc/upnpdev.h"
    "/root/derogold-dev/rev-rebase-test/external/miniupnpc/miniupnpctypes.h"
    "/root/derogold-dev/rev-rebase-test/external/miniupnpc/portlistingparse.h"
    "/root/derogold-dev/rev-rebase-test/external/miniupnpc/miniupnpc_declspec.h"
    )
endif()

