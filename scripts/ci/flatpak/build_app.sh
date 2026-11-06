#!/usr/bin/env bash

set -euo pipefail

SOURCE_TREE_ROOT="${1:-}"
INSTALL_ROOT="${2:-/app/fluxdo}"

if [[ -z "${SOURCE_TREE_ROOT}" || ! -d "${SOURCE_TREE_ROOT}" ]]; then
  echo "Usage: $0 <source-tree-root> [install-root]" >&2
  exit 1
fi

export HOME="${SOURCE_TREE_ROOT}/.flatpak-home"
export PUB_CACHE="${SOURCE_TREE_ROOT}/.pub-cache"
export CARGO_HOME="${SOURCE_TREE_ROOT}/.cargo-home"
export CARGO_NET_OFFLINE=true
export CI=true
export BOT=true
export CONTINUOUS_INTEGRATION=true
export FLUTTER_ROOT="${SOURCE_TREE_ROOT}/flutter-sdk"
export XDG_CONFIG_HOME="${HOME}/.config"

LLVM_SDK_BIN=""
LLVM_SDK_LIB=""
if [[ -d "/usr/lib/sdk/llvm20/bin" ]]; then
  LLVM_SDK_BIN="/usr/lib/sdk/llvm20/bin"
fi
if [[ -d "/usr/lib/sdk/llvm20/lib" ]]; then
  LLVM_SDK_LIB="/usr/lib/sdk/llvm20/lib"
fi

RUST_SDK_ROOT="${SOURCE_TREE_ROOT}/rust-sdk"
if [[ ! -x "${RUST_SDK_ROOT}/bin/rustc" || ! -x "${RUST_SDK_ROOT}/bin/cargo" ]]; then
  echo "Missing staged Rust toolchain; rerun prepare_source_tree.sh" >&2
  exit 1
fi
export PATH="${CARGO_HOME}/bin:${RUST_SDK_ROOT}/bin:${FLUTTER_ROOT}/bin:${FLUTTER_ROOT}/bin/cache/dart-sdk/bin${LLVM_SDK_BIN:+:${LLVM_SDK_BIN}}:${PATH}"
if [[ -n "${LLVM_SDK_LIB}" ]]; then
  export LD_LIBRARY_PATH="${LLVM_SDK_LIB}:${LD_LIBRARY_PATH:-}"
fi

rustc --version
cargo --version

mkdir -p "${HOME}" "${CARGO_HOME}" "${INSTALL_ROOT}"
mkdir -p "${XDG_CONFIG_HOME}/flutter"
mkdir -p "${CARGO_HOME}/bin"

LINUX_CC="gcc"
LINUX_CXX="g++"
if command -v clang >/dev/null 2>&1 && command -v clang++ >/dev/null 2>&1; then
  LINUX_CC="clang"
  LINUX_CXX="clang++"
fi
LINUX_CC="$(command -v "${LINUX_CC}")"
LINUX_CXX="$(command -v "${LINUX_CXX}")"

git config --global --add safe.directory "${SOURCE_TREE_ROOT}/flutter-sdk"
git config --global --add safe.directory "${SOURCE_TREE_ROOT}"

cd "${SOURCE_TREE_ROOT}"

cat > "${CARGO_HOME}/bin/rustup" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

state_dir="${CARGO_HOME:-$HOME/.cargo}/.rustup-shim"
toolchains_file="${state_dir}/toolchains"
host_triple="$(rustc -vV | sed -n 's/^host: //p')"
default_entry="stable-${host_triple}"

mkdir -p "${state_dir}"

ensure_toolchain() {
  local toolchain="${1}"
  if [[ ! -f "${toolchains_file}" ]]; then
    printf '%s\n' "${default_entry}" > "${toolchains_file}"
  fi

  if grep -Fxq "${toolchain}-${host_triple}" "${toolchains_file}"; then
    return
  fi

  printf '%s\n' "${toolchain}-${host_triple}" >> "${toolchains_file}"
}

if [[ $# -eq 0 ]]; then
  echo "rustup shim: missing command" >&2
  exit 1
fi

case "$1" in
  toolchain)
    case "${2:-}" in
      list)
        ensure_toolchain stable
        first=1
        while IFS= read -r entry; do
          [[ -n "${entry}" ]] || continue
          if [[ "${first}" -eq 1 ]]; then
            printf '%s (default)\n' "${entry}"
            first=0
          else
            printf '%s\n' "${entry}"
          fi
        done < "${toolchains_file}"
        ;;
      install)
        ensure_toolchain "${3:-stable}"
        ;;
      *)
        echo "rustup shim: unsupported toolchain subcommand: ${2:-}" >&2
        exit 1
        ;;
    esac
    ;;
  target)
    case "${2:-}" in
      list)
        toolchain="stable"
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --toolchain)
              toolchain="${2:-stable}"
              shift 2
              ;;
            --installed)
              shift
              ;;
            *)
              shift
              ;;
          esac
        done
        ensure_toolchain "${toolchain}"
        targets_file="${state_dir}/targets-${toolchain}"
        if [[ ! -f "${targets_file}" ]]; then
          printf '%s\n' "${host_triple}" > "${targets_file}"
        fi
        cat "${targets_file}"
        ;;
      add)
        toolchain="stable"
        target_to_add=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --toolchain)
              toolchain="${2:-stable}"
              shift 2
              ;;
            target|add)
              shift
              ;;
            *)
              target_to_add="$1"
              shift
              ;;
          esac
        done
        ensure_toolchain "${toolchain}"
        targets_file="${state_dir}/targets-${toolchain}"
        if [[ ! -f "${targets_file}" ]]; then
          printf '%s\n' "${host_triple}" > "${targets_file}"
        fi
        if [[ -n "${target_to_add}" ]] && ! grep -Fxq "${target_to_add}" "${targets_file}"; then
          printf '%s\n' "${target_to_add}" >> "${targets_file}"
        fi
        ;;
      *)
        echo "rustup shim: unsupported target subcommand: ${2:-}" >&2
        exit 1
        ;;
    esac
    ;;
  component)
    case "${2:-}" in
      add)
        exit 0
        ;;
      *)
        echo "rustup shim: unsupported component subcommand: ${2:-}" >&2
        exit 1
        ;;
    esac
    ;;
  run)
    if [[ $# -lt 4 ]]; then
      echo "rustup shim: invalid run arguments" >&2
      exit 1
    fi
    shift 2
    exec "$@"
    ;;
  show)
    case "${2:-}" in
      active-toolchain)
        printf '%s (default)\n' "${default_entry}"
        ;;
      *)
        echo "rustup shim: unsupported show subcommand: ${2:-}" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "rustup shim: unsupported command: $1" >&2
    exit 1
    ;;
esac
EOF
chmod 755 "${CARGO_HOME}/bin/rustup"

cat > "${SOURCE_TREE_ROOT}/linux/cargokit_options.yaml" <<'EOF'
use_precompiled_binaries: false
EOF

bash "scripts/ci/flatpak/patch_staged_flutter_sdk.sh" "${SOURCE_TREE_ROOT}"
bash "scripts/ci/linux/patch_plugins.sh"
python3 "scripts/ci/flatpak/refresh_pub_advisories_cache.py" "${PUB_CACHE}"
python3 "scripts/ci/flatpak/relocate_staged_pub_metadata.py" "${SOURCE_TREE_ROOT}"
python3 "scripts/ci/flatpak/rebuild_linux_plugin_symlinks.py" "${SOURCE_TREE_ROOT}"
python3 \
  "scripts/ci/linux/write_generated_config.py" \
  "${SOURCE_TREE_ROOT}" \
  "${FLUTTER_ROOT}" \
  "lib/main.dart" \
  "${SOURCE_TREE_ROOT}/linux/flutter/ephemeral/generated_config.cmake"

dart tool/project_tasks.dart native:prepare linux --release
CC="${LINUX_CC}" CXX="${LINUX_CXX}" cmake \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="${LINUX_CC}" \
  -DCMAKE_CXX_COMPILER="${LINUX_CXX}" \
  -DFLUTTER_TARGET_PLATFORM=linux-x64 \
  -B build/linux/x64/release \
  -S linux
ninja -C build/linux/x64/release install

cp -a build/linux/x64/release/bundle/. "${INSTALL_ROOT}/"
