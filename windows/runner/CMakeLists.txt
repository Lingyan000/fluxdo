cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "render_signet_handler.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# render_signet_handler 用 C++/WinRT(Windows.UI.Composition):
# - WinRT 错误模型是 winrt::hresult_error 异常,标准设置里的
#   _HAS_EXCEPTIONS=0 只对 runner 撤销(不影响插件);
# - winrt 头在 /W4 /WX 下有已知告警,用 /external 把尖括号头降噪。
target_compile_definitions(${BINARY_NAME} PRIVATE "_HAS_EXCEPTIONS=1")
target_compile_options(${BINARY_NAME} PRIVATE /external:W0 /external:anglebrackets)

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# quickjs_engine 0.1.1 的 pubspec 声明 pluginClass: QuickjsEnginePlugin,
# Flutter 据此生成 registrant 调 QuickjsEnginePluginRegisterWithRegistrar;
# 但其 windows 头/实现导出的是 CApi 后缀版本 —— 符号错位,链接
# identifier not found。上游未修前用别名宏桥接(语义同一函数)。
target_compile_definitions(${BINARY_NAME} PRIVATE
  "QuickjsEnginePluginRegisterWithRegistrar=QuickjsEnginePluginCApiRegisterWithRegistrar")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
# render_signet_handler 依赖:WinRT 投影 / DispatcherQueue / D3D / D2D
# (dxguid 提供 CLSID_D2D1Blend 等效果 GUID 定义)
target_link_libraries(${BINARY_NAME} PRIVATE
  "windowsapp.lib" "CoreMessaging.lib" "d3d11.lib" "d2d1.lib" "dxguid.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
