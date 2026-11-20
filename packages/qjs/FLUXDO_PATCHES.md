# FluxDO 原生运行时补丁

基于 pub.dev `qjs 0.2.3`（https://github.com/iv-re/qjs），保留上游 MIT 许可与 QuickJS 许可；仅存入构建所需的源码，不存入预编译库。

Dart isolate 的消息会在不同系统线程上执行。上游只在创建 QuickJS 运行时时记录栈顶，后续任务换线程后会误报栈溢出，或使栈限额失效。插件宿主在每条同步命令开始前调用 `updateStackTop()`，经原生入口重设栈顶，继续保留 512 KiB 栈上限。不要在 JS 回调内调用，以免重设递归预算。

原生头文件增加导出宏，构建钩子使用 C11 与 Windows UTF-8 编译选项；所需系统库按目标平台链接。

本地 build hook 始终源码构建（Android、iOS、macOS、Windows、Linux），确保该入口随应用打包。升级时需对照上游恢复这一补丁或确认已有等效修复；`qjs.g.dart` 的新增绑定与 `src/qjs_dart.h` 同步。

回归见主工程 `metaverse_script_engine_test.dart` 和 `metaverse_market_ui_test.dart`，覆盖运行时重建、重复事件、死循环、Promise 微任务、堆/栈上限与主动中断。
