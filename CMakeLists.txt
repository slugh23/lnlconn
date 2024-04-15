cmake_minimum_required(VERSION 3.5)

project(lnlconn VERSION 0.1.0 LANGUAGES C)

include(GNUInstallDirs)

find_package(PkgConfig REQUIRED)
find_package(Lua)

# Lua bindings
if(NOT LUA_FOUND)
  message(WARNING "Lua not found, not building Lua module")
else(NOT LUA_FOUND)
  set(LUA_INST_DIR
    ${CMAKE_INSTALL_PREFIX}/lib/lua/${LUA_VERSION_MAJOR}.${LUA_VERSION_MINOR}/)

  add_library(lnlconn SHARED
    src/lnlconn.c
  )

  target_include_directories(lnlconn PUBLIC
    ${LUA_INCLUDE_DIR}
  )

  target_link_libraries(lnlconn
    ${LUA_LIBRARIES})

  set_target_properties(lnlconn PROPERTIES PREFIX "" OUTPUT_NAME "lnlconn")
  target_compile_options(lnlconn PRIVATE -Wall -Wextra -Werror -Wpedantic)
  install(TARGETS lnlconn LIBRARY RENAME lnlconn.so DESTINATION ${LUA_INST_DIR})
endif(NOT LUA_FOUND)

# scripts
#install(PROGRAMS
#  tools/w1-search.lua
#  DESTINATION ${CMAKE_INSTALL_BINDIR})

# Lua modules
install(PROGRAMS
  lua/nlmsghdr.lua
  lua/cn_msg.lua
  lua/w1_netlink_msg.lua
  lua/w1_netlink_cmd.lua
  lua/w1_con_skt.lua
  lua/w1.lua
  DESTINATION ${CMAKE_INSTALL_PREFIX}/share/lua/${LUA_VERSION_MAJOR}.${LUA_VERSION_MINOR}/)

# Code quality checks
find_program(FLAW_FINDER_EXECUTABLE NAMES flawfinder)
mark_as_advanced(FLAW_FINDER_EXECUTABLE)
if(FLAW_FINDER_EXECUTABLE)
  add_custom_target(
    flawfinder
    COMMAND ${FLAW_FINDER_EXECUTABLE} "--error-level=1"
            "${CMAKE_SOURCE_DIR}/src/"
    COMMENT "Check flaw finders.")
else()
  message(WARNING "flawfinder not found.")
endif(FLAW_FINDER_EXECUTABLE)

find_program(CPP_CHECK_EXECUTABLE NAMES cppcheck)
mark_as_advanced(CPP_CHECK_EXECUTABLE)
if(CPP_CHECK_EXECUTABLE)
  add_custom_target(
    cppcheck
    COMMAND ${CPP_CHECK_EXECUTABLE} "--enable=all" "--error-exitcode=123"
            "${CMAKE_SOURCE_DIR}/src/"
    COMMENT "Check flaw finders.")
else()
  message(WARNING "cppcheck not found.")
endif(CPP_CHECK_EXECUTABLE)