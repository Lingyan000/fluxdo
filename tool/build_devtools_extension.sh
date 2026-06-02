#!/usr/bin/env bash
# 构建 Cookie 引擎 v0.4.0 DevTools Extension 并复制到 extension/devtools/build
# 设计依据: docs/cookie-sync-design-v0.4.0.md §11.4
#
# 使用:
#   ./tool/build_devtools_extension.sh
#
# 之后启动 Flutter DevTools 会自动加载 Cookie tab。

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT_DIR="$PROJECT_ROOT/devtools_extension"
DEST="$PROJECT_ROOT/extension/devtools"

if [[ ! -d "$EXT_DIR" ]]; then
  echo "错误: $EXT_DIR 不存在"
  exit 1
fi

echo "==> 拉取 DevTools extension 依赖..."
cd "$EXT_DIR"
flutter pub get

echo "==> 构建 + 复制到 $DEST/build ..."
dart run devtools_extensions build_and_copy --source=. --dest="$DEST"

echo "==> 验证 extension/devtools/build 已就绪..."
if [[ -d "$DEST/build" && -f "$DEST/config.yaml" ]]; then
  echo "[OK] DevTools extension 已就绪。启动 \`flutter run\` + 打开 Flutter DevTools 即可看到 Cookie tab。"
else
  echo "错误: build 输出缺失"
  exit 1
fi
