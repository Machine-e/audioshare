cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "external_route_channel.cpp"
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib" "ole32.lib" "runtimeobject.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

find_program(DOTNET_EXECUTABLE dotnet)
if(DOTNET_EXECUTABLE)
  set(AURACAST_SCANNER_PROJECT
    "${CMAKE_SOURCE_DIR}/auracast_scanner/AuracastScanner.csproj")
  add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
    COMMAND "${DOTNET_EXECUTABLE}" publish "${AURACAST_SCANNER_PROJECT}"
      -c Release
      -r win-x64
      --self-contained false
      -p:PublishSingleFile=true
      -p:PublishTrimmed=false
      -o "$<TARGET_FILE_DIR:${BINARY_NAME}>"
    COMMENT "Publishing audioshare_auracast_scanner helper"
    VERBATIM
  )
else()
  message(WARNING "dotnet was not found; Auracast scanner helper will not be built.")
endif()

find_program(CARGO_EXECUTABLE cargo
  HINTS "$ENV{USERPROFILE}/.cargo/bin")
if(CARGO_EXECUTABLE)
  set(AUDIOSHARE_CORE_MANIFEST
    "${CMAKE_SOURCE_DIR}/../crates/audioshare_core/Cargo.toml")
  set(AUDIOSHARE_CORE_DLL
    "${CMAKE_SOURCE_DIR}/../crates/audioshare_core/target/release/audioshare_core.dll")
  add_custom_command(
    OUTPUT "${AUDIOSHARE_CORE_DLL}"
    COMMAND "${CARGO_EXECUTABLE}" build --release --manifest-path "${AUDIOSHARE_CORE_MANIFEST}"
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}/.."
    COMMENT "Building audioshare_core Rust audio runtime"
    VERBATIM
  )
  add_custom_target(audioshare_core_rust ALL DEPENDS "${AUDIOSHARE_CORE_DLL}")
  add_dependencies(${BINARY_NAME} audioshare_core_rust)
  add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${AUDIOSHARE_CORE_DLL}"
      "$<TARGET_FILE_DIR:${BINARY_NAME}>/audioshare_core.dll"
  )
  install(FILES "${AUDIOSHARE_CORE_DLL}" DESTINATION "${CMAKE_INSTALL_PREFIX}"
    COMPONENT Runtime)
else()
  message(WARNING "cargo was not found; audioshare_core.dll will not be built and Windows playback will be unavailable.")
endif()

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
