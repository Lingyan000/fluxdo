#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ARTIFACT_ROOT="${PROJECT_ROOT}/.artifacts/flatpak"
SOURCE_TREE_ROOT="${ARTIFACT_ROOT}/source-tree"
ARTIFACT_PATH="${ARTIFACT_ROOT}/fluxdo-flatpak-source-tree.tar.gz"
PUB_CACHE_DIR="${PUB_CACHE:-${PROJECT_ROOT}/.pub-cache}"
NLOHMANN_JSON_VERSION="${NLOHMANN_JSON_VERSION:-3.11.3}"

detect_flutter_root() {
  if [[ -n "${FLUTTER_ROOT:-}" ]]; then
    printf '%s\n' "${FLUTTER_ROOT}"
    return
  fi

  if ! command -v flutter >/dev/null 2>&1; then
    echo "flutter is required to prepare the Flatpak source tree" >&2
    exit 1
  fi

  local flutter_bin
  flutter_bin="$(command -v flutter)"
  cd "$(dirname "${flutter_bin}")/.." && pwd
}

FLUTTER_ROOT="$(detect_flutter_root)"
DART_BIN="${FLUTTER_ROOT}/bin/cache/dart-sdk/bin/dart"

echo "==> Using Flutter SDK at ${FLUTTER_ROOT}"
echo "==> Using local pub cache at ${PUB_CACHE_DIR}"

export PUB_CACHE="${PUB_CACHE_DIR}"

mkdir -p "${PUB_CACHE_DIR}"
mkdir -p "${ARTIFACT_ROOT}"

cd "${PROJECT_ROOT}"

echo "==> Generating l10n"
"${DART_BIN}" tool/merge_l10n.dart

echo "==> Preparing Flutter dependencies"
flutter config --enable-linux-desktop
flutter precache --linux
flutter pub get
bash "${SCRIPT_DIR}/patch_linux_plugins.sh"

echo "==> Warming Cargokit build tool dependencies"
CARGOKIT_WARM_ROOT="${ARTIFACT_ROOT}/cargokit-pub-runners"
rm -rf "${CARGOKIT_WARM_ROOT}"
mkdir -p "${CARGOKIT_WARM_ROOT}"

while IFS= read -r build_tool_pubspec; do
  [[ -n "${build_tool_pubspec}" ]] || continue
  build_tool_dir="$(dirname "${build_tool_pubspec}")"
  runner_dir="${CARGOKIT_WARM_ROOT}/$(basename "$(dirname "${build_tool_dir}")")-$(basename "$(dirname "$(dirname "${build_tool_dir}")")")"
  rm -rf "${runner_dir}"
  mkdir -p "${runner_dir}/bin"
  cat > "${runner_dir}/pubspec.yaml" <<EOF
name: cargokit_cache_warmer
publish_to: none
environment:
  sdk: '>=3.0.0 <4.0.0'
dependencies:
  build_tool:
    path: "${build_tool_dir}"
EOF
  cat > "${runner_dir}/bin/main.dart" <<'EOF'
void main() {}
EOF
  (
    cd "${runner_dir}"
    "${DART_BIN}" pub get --no-precompile
  )
done < <(find "${PUB_CACHE_DIR}" -path '*/cargokit/build_tool/pubspec.yaml' 2>/dev/null | sort -u)

rm -rf "${CARGOKIT_WARM_ROOT}"

echo "==> Generating CA certificates"
(cd "${PROJECT_ROOT}/core/doh_proxy" && cargo run --bin gen_ca)

echo "==> Staging repository source tree"
rm -rf "${SOURCE_TREE_ROOT}"
mkdir -p "${SOURCE_TREE_ROOT}"

rsync -a --delete \
  --exclude '.artifacts/' \
  --exclude '.dart_tool/' \
  --exclude '.flatpak-builder/' \
  --exclude '.git/' \
  --exclude '.pub-cache/' \
  --exclude '.vscode/' \
  --exclude '.idea/' \
  --exclude 'build/' \
  --exclude 'flatpak/stage/' \
  --exclude 'logs/' \
  "${PROJECT_ROOT}/" \
  "${SOURCE_TREE_ROOT}/"

echo "==> Copying offline pub cache"
rsync -a --delete "${PUB_CACHE_DIR}/" "${SOURCE_TREE_ROOT}/.pub-cache/"
python3 "${SCRIPT_DIR}/refresh_pub_advisories_cache.py" "${SOURCE_TREE_ROOT}/.pub-cache"

echo "==> Copying Flutter SDK into source tree"
rsync -a --delete "${FLUTTER_ROOT}/" "${SOURCE_TREE_ROOT}/flutter-sdk/"
bash "${SCRIPT_DIR}/patch_staged_flutter_sdk.sh" "${SOURCE_TREE_ROOT}"

echo "==> Writing Flatpak-local Flutter settings"
mkdir -p "${SOURCE_TREE_ROOT}/.flatpak-home/.config/flutter"
cat > "${SOURCE_TREE_ROOT}/.flatpak-home/.config/flutter/settings" <<'EOF'
{
  "enable-linux-desktop": true,
  "cli-animations": false
}
EOF

echo "==> Vendoring nlohmann_json ${NLOHMANN_JSON_VERSION}"
rm -rf "${SOURCE_TREE_ROOT}/third_party/nlohmann_json"
mkdir -p "${SOURCE_TREE_ROOT}/third_party/nlohmann_json"
curl -L "https://github.com/nlohmann/json/releases/download/v${NLOHMANN_JSON_VERSION}/json.tar.xz" \
  | tar -xJ --strip-components=1 -C "${SOURCE_TREE_ROOT}/third_party/nlohmann_json"

echo "==> Rehydrating generated Flutter metadata inside staged tree"
(
  cd "${SOURCE_TREE_ROOT}"
  export PUB_CACHE="${SOURCE_TREE_ROOT}/.pub-cache"
  export PATH="${SOURCE_TREE_ROOT}/flutter-sdk/bin:${SOURCE_TREE_ROOT}/flutter-sdk/bin/cache/dart-sdk/bin:${PATH}"
  bash "scripts/ci/patch_linux_plugins.sh"
  flutter pub get --offline
  python3 "scripts/ci/refresh_pub_advisories_cache.py" "${SOURCE_TREE_ROOT}/.pub-cache"
)

echo "==> Vendoring Cargo dependencies for offline Linux builds"
(
  cd "${SOURCE_TREE_ROOT}"
  mapfile -t RUST_MANIFESTS < <(python3 "scripts/ci/list_linux_rust_manifests.py" "${SOURCE_TREE_ROOT}")

  CARGO_VENDOR_ARGS=(
    --versioned-dirs
    cargo-vendor
    --manifest-path
    core/doh_proxy/Cargo.toml
  )

  for manifest in "${RUST_MANIFESTS[@]}"; do
    CARGO_VENDOR_ARGS+=(--sync "${manifest}")
  done

  mkdir -p .cargo
  cargo vendor "${CARGO_VENDOR_ARGS[@]}" > .cargo/config.toml
  cat >> .cargo/config.toml <<'EOF'
[net]
offline = true
git-fetch-with-cli = true
EOF
)

echo "==> Archiving prepared Flatpak source tree"
rm -f "${ARTIFACT_PATH}"
tar -C "${SOURCE_TREE_ROOT}" -czf "${ARTIFACT_PATH}" .

echo "Prepared Flatpak source tree artifact:"
echo "  ${ARTIFACT_PATH}"
