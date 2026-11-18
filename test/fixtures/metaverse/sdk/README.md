# 插件 SDK 兼容夹具

本目录是独立工具仓库 Lingyan000/fluxdo-plugin-tools 的 SDK 0.4.0 快照，用于核对宿主、真实前导脚本与开发中心。更新时从同一工具发行版本导入声明和 contract.json，再运行 node tool/plugin_tools/check_sdk_contract.mjs。

设置 FLUXDO_PLUGIN_TOOLS 后，还会检查快照是否与工具仓库一致。协议源由独立 SDK 仓库维护，权限和实际执行继续由 Dart 宿主校验。
