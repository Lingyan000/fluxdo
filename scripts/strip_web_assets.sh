#!/bin/sh
# 依赖包里只供 Web 端加载的资源（wasm 解码器、web worker、hls.js 等）也会被
# 打进原生包。剔除 flutter_assets/packages/<包>/ 下名为 web 的目录；
# Android 见 android/app/build.gradle.kts，Windows/Linux 见各自 CMakeLists.txt。
#
# 用法：strip_web_assets.sh <App.framework 路径>
# Xcode 构建阶段在 flutter assemble 之后、embed 之前调用。iOS 的 App.framework
# 在 assemble 时已签名，删除资源后按 Flutter 的规则重签；macOS 在 embed 时
# 会再次签名。
set -e

framework="$1"
if [ ! -d "$framework" ]; then
  echo "error: 找不到 $framework" >&2
  exit 1
fi

removed=$(find "$framework" -type d -path "*/flutter_assets/packages/*/web" -prune -print)
if [ -z "$removed" ]; then
  exit 0
fi

echo "$removed" | while IFS= read -r dir; do
  echo "剔除 Web 专用资源: ${dir#"$framework"/}"
  rm -rf "$dir"
done

identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
case "$CONFIGURATION" in
  Release*) codesign --force --sign "$identity" "$framework" ;;
  *) codesign --force --sign "$identity" --timestamp=none "$framework" ;;
esac
