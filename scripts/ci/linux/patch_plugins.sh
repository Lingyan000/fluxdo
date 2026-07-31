#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PUB_CACHE_DIR="${PUB_CACHE:-$HOME/.pub-cache}"
PATCHED=0

declare -a SEARCH_ROOTS=()

if [[ -d "${PUB_CACHE_DIR}" ]]; then
  SEARCH_ROOTS+=("${PUB_CACHE_DIR}")
fi

if [[ -d "${PROJECT_ROOT}/.pub-cache" ]]; then
  SEARCH_ROOTS+=("${PROJECT_ROOT}/.pub-cache")
fi

if [[ "${#SEARCH_ROOTS[@]}" -eq 0 ]]; then
  echo "==> No pub cache directory found, skipping Linux plugin patches"
  exit 0
fi

mapfile -t JSON_HEADERS < <(find "${SEARCH_ROOTS[@]}" -path '*flutter_secure_storage_linux-*/linux/include/json.hpp' 2>/dev/null | sort -u)

for header in "${JSON_HEADERS[@]}"; do
  if grep -q 'operator "" _json' "${header}"; then
    echo "==> Patching ${header}"
    sed -i \
      -e 's/operator "" _json/operator""_json/g' \
      -e 's/operator "" _json_pointer/operator""_json_pointer/g' \
      "${header}"
    PATCHED=1
  fi
done

mapfile -t CARGOKIT_RUN_BUILD_TOOL_SH < <(find "${SEARCH_ROOTS[@]}" -path '*/cargokit/run_build_tool.sh' 2>/dev/null | sort -u)

for script in "${CARGOKIT_RUN_BUILD_TOOL_SH[@]}"; do
  if grep -q 'pub get --no-precompile' "${script}" && ! grep -q 'pub get --offline --no-precompile' "${script}"; then
    echo "==> Patching ${script}"
    sed -i 's/pub get --no-precompile/pub get --offline --no-precompile/g' "${script}"
    PATCHED=1
  fi
done

mapfile -t CARGOKIT_RUN_BUILD_TOOL_CMD < <(find "${SEARCH_ROOTS[@]}" -path '*/cargokit/run_build_tool.cmd' 2>/dev/null | sort -u)

for script in "${CARGOKIT_RUN_BUILD_TOOL_CMD[@]}"; do
  if grep -q 'pub get --no-precompile' "${script}" && ! grep -q 'pub get --offline --no-precompile' "${script}"; then
    echo "==> Patching ${script}"
    sed -i 's/pub get --no-precompile/pub get --offline --no-precompile/g' "${script}"
    PATCHED=1
  fi
done

# media_kit_libs_linux 的 CMake 默认(MIMALLOC_USE_STATIC_LIBS=ON)会在
# configure 期联网下载 mimalloc 源码 —— flatpak 禁网沙箱里 FATAL_ERROR。
# mimalloc 只是给应用 runner 可选链接的分配器优化(需应用侧手动
# target_link_libraries(${MIMALLOC_LIB}),本项目不链),置 OFF 走
# find_library 分支:找不到 libmimalloc.so 也只是不设变量,不报错。
mapfile -t MEDIA_KIT_LINUX_CMAKE < <(find "${SEARCH_ROOTS[@]}" -path '*media_kit_libs_linux-*/linux/CMakeLists.txt' 2>/dev/null | sort -u)

for cmake_file in "${MEDIA_KIT_LINUX_CMAKE[@]}"; do
  if grep -q 'option(MIMALLOC_USE_STATIC_LIBS "Whether to prefer linking to mimalloc statically" ON)' "${cmake_file}"; then
    echo "==> Patching ${cmake_file}"
    sed -i 's/option(MIMALLOC_USE_STATIC_LIBS "Whether to prefer linking to mimalloc statically" ON)/option(MIMALLOC_USE_STATIC_LIBS "Whether to prefer linking to mimalloc statically" OFF)/' "${cmake_file}"
    PATCHED=1
  fi
done

if [[ "${PATCHED}" -eq 0 ]]; then
  echo "==> No Linux plugin patches needed"
fi
