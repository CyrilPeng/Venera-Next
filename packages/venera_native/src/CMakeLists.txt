# SPDX-License-Identifier: GPL-3.0-or-later
cmake_minimum_required(VERSION 3.16)
project(venera_native VERSION 1.0.0 LANGUAGES C CXX)

set(LZMA "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/lzma")
set(LODEPNG "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/lodepng")
add_library(venera_native SHARED venera_png.c venera_7z.cpp "${LODEPNG}/lodepng.c"
  "${LZMA}/7zAlloc.c" "${LZMA}/7zArcIn.c" "${LZMA}/7zBuf.c" "${LZMA}/7zBuf2.c"
  "${LZMA}/7zCrc.c" "${LZMA}/7zCrcOpt.c" "${LZMA}/7zDec.c" "${LZMA}/7zFile.c"
  "${LZMA}/7zStream.c" "${LZMA}/Bcj2.c" "${LZMA}/Bra.c" "${LZMA}/Bra86.c"
  "${LZMA}/Delta.c" "${LZMA}/LzmaDec.c" "${LZMA}/Lzma2Dec.c" "${LZMA}/CpuArch.c")
target_include_directories(venera_native PRIVATE "${LZMA}")
target_compile_features(venera_native PRIVATE c_std_99 cxx_std_17)
target_compile_definitions(venera_native PRIVATE VENERA_LZMA_PORTABLE_ENDIAN=1)
find_package(Threads REQUIRED)
target_link_libraries(venera_native PRIVATE Threads::Threads)
set_target_properties(venera_native PROPERTIES
  C_VISIBILITY_PRESET hidden CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN YES POSITION_INDEPENDENT_CODE ON)
if(ANDROID)
  target_link_options(venera_native PRIVATE "-Wl,-z,max-page-size=16384")
endif()

option(VENERA_NATIVE_BUILD_TESTS "Build native ABI and ownership regressions" OFF)
if(VENERA_NATIVE_BUILD_TESTS)
  enable_testing()
  add_executable(venera_native_test ../test/native_test.cpp)
  target_link_libraries(venera_native_test PRIVATE venera_native)
  target_compile_features(venera_native_test PRIVATE cxx_std_17)
  add_test(NAME venera_native_abi COMMAND venera_native_test
    "${CMAKE_CURRENT_SOURCE_DIR}/../test/fixtures")
endif()
