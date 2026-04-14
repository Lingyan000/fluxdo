#!/bin/bash
set -e

# 多语言生成脚本
#
# 用法:
#   bash scripts/gen_l10n.sh          # 合并 + 生成（开发用）
#   bash scripts/gen_l10n.sh --check  # 合并 + 生成 + 校验 Dart 文件无变化（CI 用）
#   bash scripts/gen_l10n.sh --merge  # 仅合并 ARB，不生成 Dart（快速，用于 git hook）

echo "==> 合并模块化 ARB..."
dart tool/merge_l10n.dart

if [ "$1" = "--merge" ]; then
  echo "==> 完成（仅合并）"
  exit 0
fi

echo "==> 生成本地化代码..."
flutter gen-l10n

if [ "$1" = "--check" ]; then
  echo "==> 校验生成的 Dart 文件是否与仓库一致..."
  if git diff --quiet lib/l10n/app_localizations.dart lib/l10n/app_localizations_en.dart lib/l10n/app_localizations_zh.dart; then
    echo "==> 校验通过，生成文件与仓库一致"
  else
    echo "==> [ERROR] 生成的 Dart 文件与仓库不一致！"
    echo "==> 请运行 bash scripts/gen_l10n.sh 并提交更新后的文件"
    git diff --stat lib/l10n/app_localizations*.dart
    exit 1
  fi
fi

echo "==> 完成"
