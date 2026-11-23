# 插件开发工具选型与热更新

工具、脚手架和 SDK 0.11.0 支持 schema 12、设备配对、JS/RFW 热更新和离线校验。可在开发中心预览自适应集合组件与页面标题栏、体验按需授权，在测试宿主分发 `task.run` 调试后台业务。系统调度、通知和底栏入口用已安装包验证。宿主使用 Flutter 3.50。

## 选型依据

插件运行在 QuickJS，界面由 RFW 描述并交给 Flutter 原生组件。发布时继续把 JS 业务打包为单个 `main.js`，不改变已有插件运行协议。

Vite 用于开发期的模块依赖图、TypeScript 转换缓存、文件监听、失效传播及 HMR。实际通过 Environment API 创建 `fluxdo` 环境，并在现有 `IsolateScriptEngine` 中加载 ModuleRunner，验证修改入口模块后，未修改的计数模块保留原实例，热数据通过 `import.meta.hot.data` 传递。

仅监听文件并重新生成整包，直接使用 Rolldown 已足够。选择 Vite 的原因是现在已经验证可复用它的模块级热替换，不必自行维护一套模块加载与 HMR 协议。当前没有网页调试面板需求，因此不创建网页应用。

## 分工

| 层 | 职责 |
| --- | --- |
| tsdown | 构建 Node CLI/工具库和类型声明 |
| Vite | 开发模块依赖图、转换、缓存、文件监听及 HMR |
| Rolldown | 由 Vite/tsdown 使用的打包底层，正式插件依然输出独立脚本 |
| FluxDO 开发会话 | 设备配对、来源验证、更新确认、日志传输、会话结束和数据隔离 |
| FluxDO 宿主 | 权限、API、执行限额、RFW 界面、授权和付款流程 |

这些构建工具安装在开发者电脑上。手机只需要开发运行器和会话适配，正式插件不携带 Vite。

## 已有实现与验证

实现位于 [fluxdo-plugin-tools](https://github.com/Lingyan000/fluxdo-plugin-tools)，CLI、脚手架和 SDK 使用 pnpm workspace 同仓维护、分别打包发布。验证版本为 Vite 8.3.8、tsdown 0.23.7。

原生 QuickJS 集成回归已覆盖：

1. 保存 TS 文件后更新模块，保留未修改模块的数据。
2. 热替换传递 `hot.data`，同名事件按新的处理函数执行。
3. 语法错误时旧处理器可继续工作，修复后恢复更新。
4. 拒绝 Node 内置模块及项目根目录外文件读取。
5. 不新增 `process`、`require`、`fetch`、`document` 全局能力。
6. Vite 要求整模块图重载时交回宿主，不自动重新执行入口。

开发运行器由独立 CLI 构建；兼容层提供 URL、UTF-8 和 base64 纯计算对象。

## CLI 和宿主接入边界

- fluxdo dev 监听本机回环端口；App 开发中心粘贴配对地址后审阅权限。Android 使用 adb reverse，桌面同机连接；暂不提供局域网无线和 iOS 真机连接。--stdio 保留模块测试入口。
- 应用使用独立开发实例，不能覆盖已安装正式插件的数据和凭证。
- RFW 变化走组件库替换；JS 变化走模块 HMR；不兼容更新由宿主重启实例。
- 权限和所需能力变化重新校验，新增权限仍需用户确认。
- SDK 事件、定时器和异步响应按模块/实例归属清理；支付和 Connect 期间暂缓切换，不重放副作用。
- 源映射交由 CLI 展示原始 TS 文件与行号；不依赖 QuickJS 未提供的 V8 堆栈接口。
- 任意 JS 模块状态不会自动无损保留；主动修改外部服务的数据也无法靠代码回退撤销。

## 官方资料

- [Vite 自定义运行环境与 ModuleRunner](https://vite.dev/guide/api-environment-runtimes)
- [Vite HMR API](https://vite.dev/guide/api-hmr)
- [Rolldown watch](https://rolldown.rs/reference/Function.watch)
- [tsdown](https://tsdown.dev/)

宿主兼容验证保留在 [tool/plugin_tools](../../tool/plugin_tools/README.md)。SDK 兼容夹具按发行版同步到 test/fixtures/metaverse/sdk，并核对真实脚本导出、开发中心 API 覆盖和能力注册表。普通插件作者无需运行这些 Flutter/QuickJS 集成检查。


## 使用与边界

1. 独立脚手架创建项目并安装依赖，pnpm test 使用显式 mock 验证业务。
2. pnpm dev 输出配对地址。App 插件管理的开发中心右上角打开连接入口；Android 先执行 adb reverse tcp:5174 tcp:5174。
3. 确认清单权限后开始原生预览。JS 模块成功执行后提交处理器并释放旧资源；RFW 更新保留现有数据。
4. 异步事件、宿主调用、Connect 和支付结束后应用更新。断线自动重连，恢复连接和完整重载需要手动审阅重启；不自动重放业务。
5. 退出开发会话销毁临时文件与内存凭证，正式插件索引和存储不受影响。日志按 runtimeId/pluginId 筛选且脱敏后回传。
6. fluxdo market-entry --repository URL --tag TAG 构建并生成 GitHub 市场草稿，作者填写变更说明和截图。

CLI 的完整 RFW 解析器来自官方 Dart 实现；组件参数名从生产注册代码导出，SDK、CLI、宿主用同一契约。检查顶层参数名，以及能从组件读取位置推导的静态参数类型和嵌套路径；诊断给出组件、字段与行列。动态引用、循环结果及不能可靠推导的类型仍须在原生预览中验证。模块顶层已完成的外部副作用无法回滚；开发应使用测试服务或模拟宿主。

SDK 0.6.0 增加 `cardNavigation` 与 `contentPresentation`，CLI 同时校验默认卡片页面、统计、金额、数量输入、Markdown、复制和固定工具区参数。插件需声明必需能力，旧宿主会提示升级而不会静默丢弃交互。

SDK 0.7.0 增加 `eventStreams`、SSE 订阅与状态事件。开发中心的实时连接示例可动态查看消息、断线与重连，测试宿主通过 `dispatch("stream.event", ...)` 注入事件，不依赖真实服务。

SDK 0.9.0 增加 `pageChrome`。页面可通过清单的 `appBar.title` 和 `appBar.actions` 引用 RFW 组件，与正文共用数据和事件来源。CLI 同时校验能力声明和组件引用；宿主保留返回、关闭与安全区。参见[页面标题栏](components.md#页面标题栏)。

SDK 0.11.0 增加 `credentialClaims` 与 `iconButtonContent`。插件可通过 `credentials.status(name, {jwt: true})` 获取所属有效凭证的声明用于展示资料，不能将未验签的声明当作服务端身份核验。标题栏按钮可使用 `IconButton.child` 组合头像等原生组件，并保留按钮的交互和无障碍语义。

## 模拟场景和发布

SDK 0.8.0 的 createScenario 提供可显式控制的权限、账号、离线、凭证失效、宿主环境和设置响应；createPluginHarness 的 virtualTimers 与 advance 可推进重试计时。事件流通过 dispatch 注入帧和状态。测试替身不会模拟真实认证、网络栈或系统调度，也不等于设备端安全验收。

[data-migration 示例](https://github.com/Lingyan000/fluxdo-plugin-tools/tree/main/examples/data-migration)包含隔离存储迁移、语言选择及声明式设置。插件可在 preferences.changed、host.environmentChanged 和恢复可见时重新读取宿主环境。

脚手架包含手动触发的 GitHub Actions 发布模板，完成类型检查、模拟测试、打包和 SHA-256，再创建草稿 Release。作者可配置 PLUGIN_SIGNING_KEY 与轮换时的 PLUGIN_PREVIOUS_SIGNING_KEY；临时私钥文件受限权限且退出步骤即删除，不进入包或产物。作者审阅草稿后自行发布，再提交生成的市场条目。发布信任与撤回规则见[定时更新](automatic-updates.md)。
