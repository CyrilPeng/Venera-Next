cmake_minimum_required(VERSION 3.14)
project(share_plus_windows_tests LANGUAGES CXX)
enable_testing()

# Standalone tests compile production request/COM code without a Flutter engine
# or share UI. Override this path when testing outside the host repository.
set(FLUTTER_EPHEMERAL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../windows/flutter/ephemeral"
    CACHE PATH "Host Flutter Windows ephemeral directory")
set(FLUTTER_WRAPPER_INCLUDE "${FLUTTER_EPHEMERAL_DIR}/cpp_client_wrapper/include")

add_library(share_request STATIC ../share_request.cpp)
target_link_libraries(share_request PUBLIC runtimeobject)
add_executable(share_request_test share_request_test.cpp)
target_link_libraries(share_request_test PRIVATE share_request)
# Also compile the actual plugin adapter; no DLL or running app is touched.
add_library(share_plus_adapter_compile OBJECT ../share_plus_plugin.cpp)
target_compile_definitions(share_request PRIVATE _HAS_EXCEPTIONS=0)
target_compile_definitions(share_plus_adapter_compile PRIVATE _HAS_EXCEPTIONS=0)

foreach(target share_request share_request_test share_plus_adapter_compile)
  target_compile_features(${target} PRIVATE cxx_std_17)
  target_compile_definitions(${target} PRIVATE UNICODE _UNICODE NOMINMAX)
  target_compile_options(${target} PRIVATE /W4 /WX /EHsc /wd4100 /wd4267)
  target_include_directories(${target} PRIVATE .. "${FLUTTER_WRAPPER_INCLUDE}" "${FLUTTER_EPHEMERAL_DIR}")
endforeach()

add_test(NAME share_request COMMAND share_request_test)
set_tests_properties(share_request PROPERTIES TIMEOUT 60)
