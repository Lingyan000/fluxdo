# 插件工具与宿主兼容验证

日常插件开发使用独立仓库 https://github.com/Lingyan000/fluxdo-plugin-tools 。本目录只负责真实 QuickJS 与已发布 SDK 的宿主侧验证。

1. 在工具仓库执行 pnpm install --frozen-lockfile 和 pnpm build。
2. 设置 FLUXDO_PLUGIN_TOOLS 为工具仓库绝对路径；需要时设置 FLUXDO_DART 为主仓库 Dart SDK。
3. 在应用仓库执行 node tool/plugin_tools/check_sdk_contract.mjs 和 node --test tool/plugin_tools/native.test.mjs。

也可用 FLUXDO_PLUGIN_CLI 指向解压或安装后的 CLI 包进行同样的原生回归。测试只使用本地计数与假桥，不访问真实账号。工具仓库本身不要求 Dart。
