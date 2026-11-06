# SPDX-License-Identifier: GPL-3.0-or-later
cmake_minimum_required(VERSION 3.16)
project(venera_native LANGUAGES C CXX)
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/native")
set(venera_native_bundled_libraries
  "$<TARGET_FILE:venera_native>"
  "${CMAKE_CURRENT_SOURCE_DIR}/../notices/VENERA_NATIVE_THIRD_PARTY_NOTICES.txt"
  PARENT_SCOPE)
