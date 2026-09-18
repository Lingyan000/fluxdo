#!/usr/bin/env bash
# 从任意工作目录重建真实官方 oracle，再执行 Dart 差分与静态检查。
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$HERE"
pnpm install --frozen-lockfile
pnpm build
# 不自动覆盖fixture：源码或结果漂移必须由测试明确报告。
pnpm test
cd "$ROOT"
flutter test --no-pub \
  packages/fluxdo_render/test/editor/port_probe_test.dart \
  packages/fluxdo_render/test/editor/port_probe_serializer_test.dart
cd "$ROOT/packages/fluxdo_render"
dart analyze lib/src/editor/port_probe \
  test/editor/port_probe_test.dart test/editor/port_probe_serializer_test.dart
