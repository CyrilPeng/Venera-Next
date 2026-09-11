cmake_minimum_required(VERSION 3.14)
project(windows_startup_tests LANGUAGES CXX)

set(RUNNER_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../runner")
set(FLUTTER_EPHEMERAL "${CMAKE_CURRENT_SOURCE_DIR}/../flutter/ephemeral")
if(NOT EXISTS "${FLUTTER_EPHEMERAL}/flutter_windows.dll.lib")
  message(FATAL_ERROR "Run flutter build windows --debug before these tests.")
endif()

add_executable(windows_startup_tests
  startup_test.cpp
  "${RUNNER_DIR}/startup_log.cpp"
  "${RUNNER_DIR}/win32_window.cpp"
  "${RUNNER_DIR}/window_startup.cpp"
)
target_compile_features(windows_startup_tests PRIVATE cxx_std_17)
target_compile_definitions(windows_startup_tests PRIVATE UNICODE _UNICODE NOMINMAX)
target_compile_options(windows_startup_tests PRIVATE /W4 /WX /wd4100 /EHsc)
target_include_directories(windows_startup_tests PRIVATE
  "${RUNNER_DIR}" "${FLUTTER_EPHEMERAL}"
)
target_link_libraries(windows_startup_tests PRIVATE
  "${FLUTTER_EPHEMERAL}/flutter_windows.dll.lib"
  dwmapi shell32 ole32 uuid
)
add_custom_command(TARGET windows_startup_tests POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${FLUTTER_EPHEMERAL}/flutter_windows.dll"
    "$<TARGET_FILE_DIR:windows_startup_tests>"
)
enable_testing()
add_test(NAME windows_startup COMMAND windows_startup_tests)
set_tests_properties(windows_startup PROPERTIES TIMEOUT 30)
