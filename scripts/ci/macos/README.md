# macOS QuickJS 兼容性验证

## 当前方案：直接使用 quickjs_engine 0.1.5 上游库

0.1.1 的预编译 dylib 只有 arm64、最低系统为 macOS 26.0，因此此前曾在
Podfile 中接入项目内源码构建补丁。0.1.5 已修复：

- x86_64：最低 macOS 10.13（LC_VERSION_MIN_MACOSX）。
- arm64：最低 macOS 11.0（LC_BUILD_VERSION）。
- 同一 dylib 提供双架构，桥接 C++/QuickJS 源码与 0.1.1 相同。

现已移除旧的 prepare_quickjs.rb 和 Podfile 重定向，使用 Flutter/CocoaPods
默认安装流程；不额外编译、不改 pub-cache、不增加依赖覆盖。

## 回归检查

`verify_quickjs.rb` 接受 dylib 路径及可选架构列表，检查实际架构、最低系统
不高于 macOS 12，以及 FFI 桥接导出。默认要求 arm64、x86_64 都存在。

```sh
# Flutter pub get 后，从插件链接获取本次解析到的源码/预编译库。
PLUGIN=macos/Flutter/ephemeral/.symlinks/plugins/quickjs_engine
ruby scripts/ci/macos/verify_quickjs.rb "$PLUGIN/macos/Frameworks/libquickjs_c_bridge_plugin.dylib"

# 编译独立加载测试（JSON、数组归约、BigInt），无需链接 QuickJS。
xcrun clang -std=c11 -I "$PLUGIN/native/cxx/quickjs" \
  test/native/quickjs_macos_smoke.c -o /tmp/quickjs-smoke
/tmp/quickjs-smoke "$PWD/$PLUGIN/macos/Frameworks/libquickjs_c_bridge_plugin.dylib"

fvm dart tool/flutterw.dart build macos --debug
APP_LIB="$PWD/build/macos/Build/Products/Debug/fluxdo.app/Contents/Frameworks/libquickjs_c_bridge_plugin.dylib"
# CocoaPods 会按本次应用架构裁剪库，arm64 本机构建只要求 arm64。
ruby scripts/ci/macos/verify_quickjs.rb "$APP_LIB" arm64
/tmp/quickjs-smoke "$APP_LIB"
```

Intel slice 可在 Apple Silicon 安装 Rosetta 后，以 `-arch x86_64` 编译测试程序，
再用 `arch -x86_64` 执行。双架构冒烟不等于 Intel 整应用验收，最低系统兼容
最终仍需 macOS 12 实机测试。
