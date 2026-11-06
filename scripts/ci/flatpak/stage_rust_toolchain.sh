#!/usr/bin/env bash
# 将源准备阶段的实际编译器一起带入离线沙箱，避免 SDK 扩展滞后于依赖 MSRV。
set -euo pipefail
source_tree="${1:?Usage: stage_rust_toolchain.sh <source-tree>}"
rust_sysroot="$(rustc --print sysroot)"
python3 - "${source_tree}/core/net_core/Cargo.toml" <<'PY'
import re, subprocess, sys
text = open(sys.argv[1]).read()
required = re.search(r'^rust-version\s*=\s*"([\d.]+)"', text, re.M).group(1)
version = subprocess.check_output(['rustc', '--version'], text=True).split()[1]
triple = subprocess.check_output(['rustc', '-vV'], text=True)
def parts(value):
    return tuple(int(n) for n in value.split('.')) + (0,) * (3 - len(value.split('.')))
if parts(version) < parts(required):
    sys.exit(f'Rust {version} is below required {required}; update the source preparation toolchain')
if 'host: x86_64-unknown-linux-gnu' not in triple:
    sys.exit('Flatpak source preparation requires the x86_64-unknown-linux-gnu Rust toolchain')
PY
mkdir -p "${source_tree}/rust-sdk"
# 不复制 rustup shim 或目标构建缓存；直接使用可搬迁的编译器、标准库和 Cargo。
rsync -a --delete --exclude 'share/doc/' "${rust_sysroot}/" "${source_tree}/rust-sdk/"
"${source_tree}/rust-sdk/bin/rustc" -vV > "${source_tree}/rust-sdk/FLUXDO_TOOLCHAIN.txt"
"${source_tree}/rust-sdk/bin/cargo" --version >> "${source_tree}/rust-sdk/FLUXDO_TOOLCHAIN.txt"
cat "${source_tree}/rust-sdk/FLUXDO_TOOLCHAIN.txt"
