#!/usr/bin/env bash
# 升级 SDK 时比较上次审查版本，不自动覆盖自研选区代码。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SDK="${FLUTTER_ROOT:-${ROOT}/.fvm/flutter_sdk}"
BASE="${1:-9584c6713b}"
git -C "$SDK" rev-parse --verify "${BASE}^{commit}" >/dev/null
FILES=(
  packages/flutter/lib/src/widgets/selectable_region.dart
  packages/flutter/lib/src/widgets/text_selection.dart
  packages/flutter/lib/src/widgets/context_menu_controller.dart
  packages/flutter/lib/src/material/adaptive_text_selection_toolbar.dart
  packages/flutter/lib/src/material/text_selection_toolbar.dart
  packages/flutter/lib/src/material/text_selection_toolbar_layout_delegate.dart
  packages/flutter/lib/src/services/process_text.dart
)
printf '上次审查：%s；当前 SDK：' "$BASE"
git -C "$SDK" rev-parse --short HEAD
printf '\n官方选区相关提交：\n'
git -C "$SDK" log --oneline "${BASE}..HEAD" -- "${FILES[@]}"
printf '\n接口与行为差异：\n'
git -C "$SDK" diff "$BASE" HEAD -- "${FILES[@]}"
printf '\n回归命令：\n%s\n' 'fvm flutter test --no-pub packages/fluxdo_render/test/selection'
printf '%s\n' '注意：无差异不等于无 engine/平台变化；仍需 Android/iOS 真机拖柄、滚动和溢出菜单验收。'
