# 插件工具与宿主兼容验证

日常插件开发使用独立仓库 https://github.com/Lingyan000/fluxdo-plugin-tools 。本目录只负责真实 QuickJS 与已发布 SDK 的宿主侧验证。

1. 在工具仓库执行 pnpm install --frozen-lockfile 和 pnpm build。
2. 设置 FLUXDO_PLUGIN_TOOLS 为工具仓库绝对路径；需要时设置 FLUXDO_DART 为主仓库 Dart SDK。
3. 在应用仓库执行 node tool/plugin_tools/check_sdk_contract.mjs 和 node --test tool/plugin_tools/native.test.mjs。

也可用 FLUXDO_PLUGIN_CLI 指向解压或安装后的 CLI 包进行同样的原生回归。测试只使用本地计数与假桥，不访问真实账号。工具仓库本身不要求 Dart。


完整设备集成：FLUXDO_PLUGIN_TOOLS=工具目录 flutter test test/modules/metaverse/metaverse_development_integration_test.dart。测试启动真实 CLI WebSocket，复用 App 会话与原生引擎；不依赖真实账号。

组件契约：dart run tool/plugin_tools/export_components.dart 由实际 DataSource 读取位置导出 JSON 与宿主 Dart 常量。--check 使用 `dart run tool/plugin_tools/export_components.dart test/fixtures/metaverse/sdk/components.json --check`。把 JSON 同步至工具 packages/sdk/schema/components.json。

RFW CLI 校验器：dart compile js -O2 tool/plugin_tools/rfw_validator.dart -o build/rfw-validator.js；复制至工具 packages/cli/vendor/rfw-validator.cjs。保留官方 RFW 与 Dart 许可证。CLI 使用官方解析器，不要求插件作者安装 Flutter。

SDK 测试宿主的 prelude.js 来自生产 metaverse_plugin_prelude.dart；check_sdk_contract.mjs 同时核对组件契约、前导脚本、SDK 类型和 API 示例覆盖。工具依赖版本由 .github/workflows/plugin-development.yaml 固定。
