cmake_minimum_required(VERSION 3.16)
project(venera_test_libraries LANGUAGES C CXX)

set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")

# Compile the locked plugin's real QuickJS FFI without its GTK/Flutter method
# channel wrapper. Flutter unit tests call this ABI directly, without an engine.
include("${FLUTTER_QJS_ROOT}/cxx/quickjs.cmake")
add_library(flutter_qjs_plugin SHARED "${FLUTTER_QJS_ROOT}/cxx/ffi.cpp")
target_compile_features(flutter_qjs_plugin PRIVATE cxx_std_17)
find_package(Threads REQUIRED)
target_link_libraries(flutter_qjs_plugin PRIVATE quickjs Threads::Threads m)

add_subdirectory("${ZIP_FLUTTER_ROOT}/src" zip_flutter)
add_subdirectory("${FLUTTER_7ZIP_ROOT}/src" flutter_7zip)
add_subdirectory("${LODEPNG_FLUTTER_ROOT}/src" lodepng_flutter)
