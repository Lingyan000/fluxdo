#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

FLUTTER_VERSION="${FLUTTER_VERSION:-3.41.5}"
FLUTTER_ROOT="${FLUTTER_ROOT:-$HOME/flutter}"
FLUTTER_ARCHIVE="flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
FLUTTER_URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/${FLUTTER_ARCHIVE}"
DART_BIN="${FLUTTER_ROOT}/bin/cache/dart-sdk/bin/dart"

if ! command -v pacman >/dev/null 2>&1; then
  echo "This script currently supports Arch Linux builders only." >&2
  exit 1
fi

if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

echo "==> Installing Arch Linux build dependencies"
${SUDO} pacman -Syu --noconfirm
${SUDO} pacman -S --noconfirm --needed \
  base-devel \
  clang \
  cmake \
  curl \
  file \
  git \
  gtk3 \
  libepoxy \
  libsecret \
  libwpe \
  ninja \
  pkgconf \
  python \
  wayland \
  wpebackend-fdo \
  wpewebkit \
  xz

if [[ ! -x "${HOME}/.cargo/bin/rustup" ]]; then
  echo "==> Installing rustup"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
fi

if [[ ! -x "${FLUTTER_ROOT}/bin/flutter" ]]; then
  echo "==> Downloading Flutter ${FLUTTER_VERSION}"
  mkdir -p "$(dirname "${FLUTTER_ROOT}")"
  curl -L "${FLUTTER_URL}" | tar -xJ -C "$(dirname "${FLUTTER_ROOT}")"
fi

export PATH="${HOME}/.cargo/bin:${FLUTTER_ROOT}/bin:${FLUTTER_ROOT}/bin/cache/dart-sdk/bin:${PATH}"

echo "==> Configuring git safe directories"
git config --global --add safe.directory "${FLUTTER_ROOT}"
git config --global --add safe.directory "${PROJECT_ROOT}"
if [[ -d "${PROJECT_ROOT}/core/doh_proxy/.git" ]]; then
  git config --global --add safe.directory "${PROJECT_ROOT}/core/doh_proxy"
fi

echo "==> Toolchain versions"
flutter --version
dart --version
rustup show active-toolchain
cargo --version
rustc --version

echo "==> Preparing Flutter Linux build"
flutter config --enable-linux-desktop

cd "${PROJECT_ROOT}"

echo "==> Generating l10n"
"${DART_BIN}" tool/merge_l10n.dart

flutter pub get
bash "${SCRIPT_DIR}/patch_linux_plugins.sh"

echo "==> Building Linux bundle"
CC=gcc CXX=g++ flutter build linux --release

echo "==> Building desktop DOH proxy"
cargo build --manifest-path core/doh_proxy/Cargo.toml --release --bin doh_proxy_bin --features ech

echo "==> Copying desktop DOH proxy into bundle"
install -Dm755 core/doh_proxy/target/release/doh_proxy_bin build/linux/x64/release/bundle/doh_proxy_bin

echo "==> Bundling WPE runtime libraries"
bash "${SCRIPT_DIR}/bundle_wpe_runtime_libs.sh" "build/linux/x64/release/bundle"

echo "==> Verifying bundle dependencies"
bash "${SCRIPT_DIR}/check_linux_bundle.sh" "build/linux/x64/release/bundle"

echo "==> Archiving bundle artifact"
mkdir -p .artifacts/linux
tar -C build/linux/x64/release -czf .artifacts/linux/fluxdo-linux-bundle.tar.gz bundle
