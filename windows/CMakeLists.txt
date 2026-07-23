# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(fluxdo LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "fluxdo")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# All Windows C/C++ sources in this project are UTF-8. Without an explicit
# source charset MSVC falls back to the host ANSI code page (936 on zh-CN).
if(MSVC)
  add_compile_options(/utf-8)
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

install(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/runner/native/"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}/native"
  COMPONENT Runtime
  PATTERN ".keep" EXCLUDE)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)

# === 媒体压缩:随包分发 ffmpeg(构建期下载,开发机缓存一次)===
# 运行时零下载(终端用户网络不可控);缓存已 gitignore。下载失败时
# 按报错提示手动下载放置后重新构建即可。
set(FFMPEG_CACHE_EXE "${CMAKE_CURRENT_SOURCE_DIR}/.ffmpeg-cache/ffmpeg.exe")
if(NOT EXISTS "${FFMPEG_CACHE_EXE}")
  message(STATUS "Downloading bundled ffmpeg (~81MB, one-time, cached at windows/.ffmpeg-cache)")
  file(DOWNLOAD
    "https://npmmirror.com/mirrors/ffmpeg-static/b6.0/ffmpeg-win32-x64"
    "${FFMPEG_CACHE_EXE}.part"
    SHOW_PROGRESS
    TLS_VERIFY ON
    STATUS FFMPEG_DL_STATUS)
  list(GET FFMPEG_DL_STATUS 0 FFMPEG_DL_CODE)
  if(NOT FFMPEG_DL_CODE EQUAL 0)
    file(REMOVE "${FFMPEG_CACHE_EXE}.part")
    # 可选组件,不挡构建(离线打包环境如 Flatpak 沙箱禁网):产物不含
    # 随包 ffmpeg,运行时回落系统 PATH 查找;离线构建要带上的话,预先
    # 把文件放到下面的缓存路径即可(本块检测到已存在会跳过下载)。
    message(WARNING "bundled ffmpeg download failed (${FFMPEG_DL_STATUS}). "
      "Build continues WITHOUT bundled ffmpeg. To include it, manually "
      "download https://npmmirror.com/mirrors/ffmpeg-static/b6.0/ffmpeg-win32-x64 "
      "and save it as ${FFMPEG_CACHE_EXE}, then rebuild.")
  else()
    file(RENAME "${FFMPEG_CACHE_EXE}.part" "${FFMPEG_CACHE_EXE}")
  endif()
endif()
if(EXISTS "${FFMPEG_CACHE_EXE}")
  install(PROGRAMS "${FFMPEG_CACHE_EXE}" DESTINATION "${CMAKE_INSTALL_PREFIX}"
    COMPONENT Runtime)
endif()
