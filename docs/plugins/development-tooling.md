# 插件开发工具选型与热更新

工具、脚手架和 SDK 的首发候选版本为 1.0.0，发行状态与创建命令见[开发入口](README.md#快速上手)。候选工具支持 schema 12、设备配对、JS/RFW 热更新和离线校验。可在开发中心预览自适应集合、时间线、输入框与页面标题栏、体验按需授权，在测试宿主分发 `task.run` 调试后台业务。系统调度、通知和底栏入口用已安装包验证。宿主使用 Flutter 3.50。

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

- `fluxdo dev` 默认监听回环，Android 可使用 `adb reverse`。`fluxdo dev --lan 本机IPv4` 显式绑定局域网网卡，Android、iOS 和桌面可无线配对；终端配对 URL 与二维码写入 stderr，设备日志仍为 stdout JSON；使用临时 TLS 证书，App 按配对地址中的 SHA-256 指纹验证后才发送会话令牌。iOS 首次连接须允许本地网络访问。服务重启后配对地址失效，须重新配对；`--stdio` 保留模块测试入口。
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
2. pnpm dev 输出配对地址。App 插件管理的开发中心「教程 → 连接开发工具」或右上角打开连接入口；Android USB 先执行 adb reverse tcp:5174 tcp:5174。使用 `--lan 本机IPv4` 时，Android、iOS 和 macOS 可点“扫码配对”填入地址，再主动连接并审阅权限；Windows、Linux 或相机不可用时粘贴地址。扫码与粘贴使用同一协议、局域网地址及 TLS 指纹校验，不自动运行插件。
3. 确认清单权限后开始原生预览。JS 模块成功执行后提交处理器并释放旧资源；RFW 更新保留现有数据。
4. 异步事件、宿主调用、Connect 和支付结束后应用更新。断线自动重连，恢复连接和完整重载需要手动审阅重启；不自动重放业务。
5. 退出开发会话销毁临时文件与内存凭证，正式插件索引和存储不受影响。日志按 runtimeId/pluginId 筛选且脱敏后回传。
6. fluxdo market-entry --repository URL --tag TAG 构建并生成 GitHub 市场草稿，作者填写变更说明和截图。

CLI 的完整 RFW 解析器来自官方 Dart 实现；组件参数名从生产注册代码导出，SDK、CLI、宿主用同一契约。检查顶层参数名，以及能从组件读取位置推导的静态参数类型和嵌套路径；诊断给出组件、字段与行列。动态引用、循环结果及不能可靠推导的类型仍须在原生预览中验证。模块顶层已完成的外部副作用无法回滚；开发应使用测试服务或模拟宿主。

SDK 提供 `cardNavigation` 与 `contentPresentation`，CLI 同时校验默认卡片页面、统计、金额、数量输入、Markdown、复制和固定工具区参数。插件需声明必需能力，旧宿主会提示升级而不会静默丢弃交互。

SDK 提供 `eventStreams`、SSE 订阅与状态事件。开发中心的实时连接示例可动态查看消息、断线与重连，测试宿主通过 `dispatch("stream.event", ...)` 注入事件，不依赖真实服务。

SDK 提供 `pageChrome`。页面可通过清单的 `appBar.title` 和 `appBar.actions` 引用 RFW 组件，与正文共用数据和事件来源。CLI 同时校验能力声明和组件引用；宿主保留返回、关闭与安全区。参见[页面标题栏](components.md#页面标题栏)。

SDK 提供 `credentialClaims` 与 `iconButtonContent`。插件可通过 `credentials.status(name, {jwt: true})` 获取所属有效凭证的声明用于展示资料，不能将未验签的声明当作服务端身份核验。标题栏按钮可使用 `IconButton.child` 组合头像等原生组件，并保留按钮的交互和无障碍语义。

## 模拟场景和发布

SDK 的 createScenario 提供可显式控制的权限、账号、离线、凭证失效、宿主环境和设置响应；createPluginHarness 的 virtualTimers 与 advance 可推进重试计时。事件流通过 dispatch 注入帧和状态。测试替身不会模拟真实认证、网络栈或系统调度，也不等于设备端安全验收。

[data-migration 示例](https://github.com/Lingyan000/fluxdo-plugin-tools/tree/main/examples/data-migration)包含隔离存储迁移、语言选择及声明式设置。插件可在 preferences.changed、host.environmentChanged 和恢复可见时重新读取宿主环境。

脚手架包含手动触发的 GitHub Actions 发布模板，完成类型检查、模拟测试、打包和 SHA-256，再创建草稿 Release。作者可配置 PLUGIN_SIGNING_KEY 与轮换时的 PLUGIN_PREVIOUS_SIGNING_KEY；临时私钥文件受限权限且退出步骤即删除，不进入包或产物。作者审阅草稿后自行发布，再提交生成的市场条目。发布信任与撤回规则见[定时更新](automatic-updates.md)。

SDK 提供 `notifications.status()` 和用户点击限定的 `notifications.openSettings()`。插件授权与操作系统设置分别查询；系统关闭通知时仍可正常同步数据。Windows、Linux 无法查询完整投递许可时返回 `unknown`，不把未知当成已授权。

CLI、SDK 与脚手架具有 npm 发布配置；维护者需配置 npm 的包发布权限和可信发布者后运行独立仓库的发布工作流。尚未发布到 npm 时使用 GitHub Release 的 tgz。脚手架 `--distribution npm` 可生成 npm 版本依赖，默认继续使用可取得的 GitHub Release。

## 多语言项目

SDK 的 `@fluxdo/plugin-sdk/i18n` 提供 `createTranslator(catalogs, baseLocale)`。`setLocale` 选择地区或语言回退，`text` 只替换产品文案的参数，不翻译服务器正文。脚手架 `--template localized` 提供可直接开发、热替换和打包的 TypeScript 示例；在 `host.environmentChanged` 和页面恢复时读取应用语言，再更新显示数据。

SDK 的 `storage.partition` 支持账号分区迁移。开发热更新会话使用全新的隔离存储，不执行正式数据迁移，也不为迁移创建第二条模块连接。纯分类逻辑可在 SDK 测试宿主中用 `task` 上下文分发此事件并断言返回数据；正式升级、快照回退和账号切换需用已安装包验证。

已有独立 JS/TS 脚本可使用 `fluxdo localize [目录]`，在 `fluxdo.config.json` 配置 `localization: {baseLocale, script, ui}`，将词典放在 `locales/<语言>.json`。命令生成脚本、RFW 和清单译文；`--check` 可用于 CI 检查产物。缺少显式词典翻译会失败；中文基准可自动生成台湾及香港繁体。带模块导入的 TS 项目使用 SDK 翻译函数并由 Vite 构建，不走独立脚本转换。

## 配对诊断

开发设备已经连接 `fluxdo dev` 后，运行 `fluxdo doctor [目录] --pair '<配对地址>'`。命令完成项目检查，并通过现有配对查询宿主状态，不挤掉设备连接、不创建浏览器调试页。

诊断包含连接状态、宿主能力、缺失能力、权限开关、界面可见性与尺寸、数据字段类型和列表长度、API 次数/错误数/累计与最大耗时。不读取页面正文、文件字节、本地存储值或凭证。数据是最近一次采样，网络耗时不是逐帧性能分析。仅开发会话累计 API 指标，正式安装不额外记录该信息。回环可使用明文；局域网连接先验证配对证书指纹，再发送认证头。配对地址本身是临时凭证，不应写入仓库或公开日志。

市场发布校验同时核对 GitHub Release 是否为草稿或预发布、附件 URL、包摘要、身份及能力。`preview` 必须对应 GitHub 预发布；语义版本没有后缀也不能据此把预发布自动当作稳定版。

## 查询与分页

SDK 的 `@fluxdo/plugin-sdk/data` 提供 `createQueryClient`、`createPagedList` 和 `QueryCancelledError`，由 Vite 打包到插件脚本，不增加宿主业务 API。独立脚本的本地化编译可声明 `runtimeHelpers: ["data"]`，使用同版的 `fluxdoData` 对象；产物不依赖运行时 CDN。

```ts
import {createQueryClient, createPagedList} from '@fluxdo/plugin-sdk/data';
const queries = createQueryClient({identity: account.id});
const data = await queries.query(['categories'], readCategories, {
  ttl: 300_000, tags: ['catalog'],
});
queries.invalidate({tags: ['catalog']});
queries.setIdentity(nextAccount.id);
const list = createPagedList({load: loadPage, itemKey: item => item.id});
list.reset({search: '', category: 'all'});
await list.load();
await list.load({more: true});
```

查询默认最多 64 条、按 JSON UTF-8 保守估计共 2 MiB。同键在途读取合并，失败保留旧数据；失效、手动更新、账号变化或释放后拒绝旧响应回写。分页保留刷新前内容、按稳定标识合并条目，游标不前进时终止继续加载。查询键必须包含影响结果的账号和筛选。关闭页面时释放分页控制器，退出账号时清空实例内缓存。工具不会重试调用，也不会发送建单、付款或消息；业务写操作成功后由插件明确失效相关标签或更新对应条目。

显式普通存储通过清单的 `storage` 与 `storageScopes` 声明，见 [API 存储作用域](api.md#普通存储作用域)。模拟宿主可设置 `storageScope`、`accountId`，账号区用独立命名空间，默认仍兼容旧测试的共享数据。

## 持续验证

Windows 固定 Flutter 版本、字体、尺寸、主题与时间，对比组件黄金图；其他桌面平台运行同一布局断言与真实 QuickJS 测试。黄金图变化必须查看差异再更新，不能用更新基线掩盖溢出。查询基准记录同键请求次数、缓存淘汰和真实引擎耗时，不把测试机的耗时当作手机帧率保证。

移动端工作流用最小设备壳编译生产 QuickJS 引擎与运行时协议，在 Android 模拟器和 iOS 模拟器执行查询、分页、通道通信及销毁。它不加载真实账号，不能替代系统生物识别、后台调度或真实服务授权验收。公开服务契约在市场仓库定时执行匿名 GET，与离线回归分开；上游故障不会被当成代码单测失败。
