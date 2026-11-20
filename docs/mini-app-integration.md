# 微应用接入调查与实现边界

核对日期：2026-11-07。依据用户提供的列表/详情响应、登录后的实际网页，以及该网页加载的官方微应用前端脚本。客户端首版代码位于 `lib/modules/mini_apps/`，包含原生广场、详情、工具栏和操作面板；运行内容继续使用官方嵌入宿主。

## 已验证的页面行为

- `/apps` 提供搜索、四种排序、已收藏筛选、卡片/列表切换和分页；已登录时还有“我的微应用”。
- 排序参数是 `hot`、`latest`、`rating`、`used`。搜索输入最多 100 字符，改变搜索、排序或收藏筛选会回到第 0 页。
- `recent_usage_count` 对应近七天的应用使用次数，不是当前用户的最近使用记录。
- `/apps/<app-id>` 是含运行区的应用宿主页，“应用信息”通过面板打开，包含开发者、版本、环境、评分、介绍、更新说明，以及可选的讨论话题。
- `?embed_mode=true` 隐去论坛导航，保留应用信息、声音、分享、收藏、评分、打赏、举报操作。已在登录态下将 CS 静音启动至游戏入口，没有加入游戏。
- 存在音频权限的应用在运行前询问“开启声音”或“静音进入”，运行期间可切换。不能将这一询问错误显示为加载失败。
- 运行容器包含 `frame-host` 与内部应用运行 frame；不能把内部 runtime URL 直接当成独立应用入口。
- 评分为 1–5 的整数，每位成员一份，可修改；点击星级即调用保存，未另设提交按钮。
- 打赏面板读取状态后显示余额、可选档位和冷却提示，本次观察为 1、3、5、10 分；选择后仍需确认。具体档位应使用响应中的 `amounts`。
- 举报复用站点举报分类，只选择适用于 `DiscourseMiniApp::App` 的已启用分类，排除 `notify_user`。分类及 ID 不应硬编码。

  注意：前端 `site.flagTypes` 是从 `/site.json` 的 `post_action_types` 中筛选 `is_flag` 得出的计算属性，不是名为 `flag_types` 的 JSON 字段。已核对 [Discourse Site 模型](https://github.com/discourse/discourse/blob/main/frontend/discourse/app/models/site.js)。
- 分享操作生成应用嵌入代码并尝试复制；失败时打开供手动复制的面板，不能只实现 URL 分享就声称与网页等价。

本次只打开菜单、信息与权限面板，没有提交收藏修改、评分、举报或打赏。写操作协议来自源码核对，成功及错误响应尚未通过实际写操作验证。

## 已核实的读写接口

`<production>` 表示 `/mini-app-api/production/<app-id>`。优先采用详情返回的同源 configuration 地址，使用前校验站点、协议与对应应用路径。

| 功能 | 方法和地址 | 参数/约束 |
| --- | --- | --- |
| 广场 | `GET /mini-app-api/apps.json` | `sort`、`q`、`page`、`favorite`；页号从 0 开始 |
| 正式详情 | `GET <production>/info` | 返回 `app` 与 `configuration` |
| 最新运行资源 | `GET /mini-app-api/runtime-assets.json` | 宿主会在运行前读取，不能永久缓存详情内的脚本地址 |
| 添加收藏 | `PUT configuration.favoriteUrl` | 源码不附请求体，读取返回的 `is_favorited` 布尔值 |
| 取消收藏 | `DELETE configuration.favoriteUrl` | 同上 |
| 评分 | `PUT configuration.ratingUrl` | JSON `{ "score": 1 }`；只接受整数 1–5 |
| 打赏状态 | `GET configuration.tipUrl` | 源码使用 `amounts`、`balance`、`next_tip_at` |
| 提交打赏 | `POST configuration.tipUrl` | JSON `{ "amount": 1, "request_id": "UUID" }` |
| 举报 | `POST configuration.reportUrl` | `flag_type_id`、`release_id`、可选 `message`；网页使用表单数据 |
| 我的应用 | `GET /mini-app-api/my/apps` | `page`；属于开发者管理入口，不等于个人最近使用 |

广场分页使用响应 `page`、`per_page`、`total`。不能根据样例中“每页 40 条”写死页大小。加载和搜索须防止旧请求覆盖新条件结果，并按 `app_id` 去重。

打赏源码为一次金额选择生成 UUID；同一次请求失败后重试保留原 UUID，换金额或确认成功后才清除。不能对可能已成功的提交生成新 UUID 自动重发；失败后先刷新打赏状态。冷却时间以服务端结果为准。

举报优先关联本次运行实际发布的 `release_id`，不是只依赖打开页面时的旧详情。信息面板也会跟随运行时返回的名称、版本、图标和更新说明更新，避免版本切换时展示错误。

操作入口受当前登录身份、`channel`、`anonymous`、`can_rate`、`can_report`、`can_tip` 及举报类型配置控制，不能仅凭 URL 存在就显示为可操作。

## 官方加载器与轻量宿主

轻量宿主为默认引擎，官方网页为兼容备用；保留用户之前明确选择的引擎偏好。尚未测量 Android 设备上各阶段的实际耗时。

核对来源：

- [官方加载器](https://cdn.ldstatic.com/plugins/discourse-mini-app/runtime/loader-825168982ff65bbb3332ffbbbded3d5719cd39946967aa70bdb65dc71176cce3.js)：下载文件的 SHA-256 与文件名一致；调查副本位于 `build/mini-app-research/loader.js`。这是本次核对的版本，生产代码不能硬编码该地址。
- [官方微应用页面模块](https://cdn3.ldstatic.com/assets/br/plugins/discourse-mini-app_main.DjI36i-6yfayk3u.digested.js)：核对页面挂载、运行资源更新、用户资料提供者及销毁调用。调查副本位于 `build/mini-app-research/plugin-main.js`。
- 官方网页引擎在 Cookie 灌入后 `loadUrl(configuration.embedUrl)`；文档开始时注入的 CSS 只隐藏、调整宿主 UI，不减少论坛框架和插件的加载执行。轻量引擎使用同一地址作为可信宿主来源，生成最少的 HTML 并直接挂载官方独立加载器。

### 三种资源复用不能混为页面保活

| 层级 | 官方实现 | 新 WebView 再次打开的含义 |
| --- | --- | --- |
| 浏览器 HTTP 缓存 | 脚本、样式等按 HTTP 缓存策略读取，SDK 和声明的远程资源使用带校验的缓存读取 | 可能省下载，仍需重新解析、执行脚本；是否命中不能只凭 `cacheEnabled` 判断 |
| 持久化应用包 | `discourse-mini-app-artifacts-v1` IndexedDB 保存包字节；读取后重新经过官方 worker 解密、验签、解包与 manifest 校验 | 在同源、相同持久化存储及缓存键有效时可省包下载，不等于省掉解包 |
| 已解包文件 | 加载器模块的内存 Map 保存文件内容；命中后仍检查当前会话及文件/manifest 一致性 | 同一网页保留加载器模块时可复用；销毁 WebView 后该 Map 消失。这里缓存的是资源，不是游戏运行实例 |

官方 `destroy()` 会中止请求、停止 worker、销毁媒体与连接、关闭消息通道、移除 frame、撤销对象 URL，并释放本次运行文件引用；它没有把模块级已解包资源缓存一并清空。因此网页中“关闭应用后重新打开”可能同时省去论坛框架启动和解包，不能把这个现象简单归因为 HTTP 下载速度。是否为用户设备的主要瓶颈仍须计时。

包缓存键并非仅有应用 ID/版本：还绑定站点、`runtime_context` 和发布元数据（包括 manifest、权限、验签公钥、包摘要等）。必须沿用官方失效规则，不能为提高命中率删去会话或发布绑定。IndexedDB 读取失败/超时会降级；本版本默认操作超时为 300ms，这只是待测因素，不代表设备上已经发生超时。持久化命中也会重新走 worker，所以看到“解密/验签/解包”不能推出“又下载了一遍”。

### 已确认的独立宿主接口

加载器导出 `mountLoader(element, configuration)` 和 `createUserDataProvider(...)`；其本身不导入 Ember/Discourse 模块。网页先请求最新 `runtime-assets.json`，合并详情配置，再动态导入加载器。轻量宿主可以沿用这一公开导出接口，保留官方授权、解密验签、沙箱和权限执行流程。

- `mountLoader` 返回 `destroy()`、`close()`、`setAudioMuted(...)`。原生声音操作有机会直接对接此控制器，替代现在通过官方菜单 DOM 找按钮的适配。
- 配置回调有 `onAudioStateChange`、`onRelease`、`onPerformance`。`onRelease` 给出实际运行版本，可改善当前举报前只重新请求详情的边界；`onPerformance` 给出 `packageSource`（`memory`、`persistent`、`network`）及阶段耗时。
- 官方会记录 `discourse-mini-app:load` Performance Measure，包含授权、SDK、包处理、下载、worker、解密/验签/解包、音频选择、挂载、应用启动等阶段。阶段存在并行及包含关系，不能相加当总耗时；等待用户选择声音也不能算作纯加载性能。
- `userProvider` 负责当前用户、按 ID 获取公开资料、头像和会话有效性。网页通过 `/user-cards.json?user_ids=<id>` 获取用户资料，并使用官方 `createUserDataProvider` 裁剪与检查数据。轻量宿主必须补齐此依赖，不能只传应用配置就声称功能等价。
- 宿主还需要当前登录的 Cookie、CSRF 元数据、翻译、主题与视口；敏感会话材料仅留在可信宿主，不向小程序沙箱提供通用原生请求能力。

### 同源与跨平台约束

官方加载器强制要求 worker 和 `frame-host` 与宿主同源，并实际读取 `frame-host` 的 document、标识与 URL；应用隔离 frame 仍由官方创建。应用参数取自宿主 `location.search/hash`，应用 Cookie 操作也校验宿主位于对应 `/apps/<id>` 路径。因此不能把内部 `runtimeUrl` 直接作为入口，也不能仅把相对 URL 改成绝对地址便认为跨域问题解决。

项目 Windows 插件的 `loadData` 在 C++ 中仅调用 `NavigateToString(data)`，没有使用 Dart 侧 `baseUrl`。微软文档说明这种方式的页面地址为 `about:blank`、源为 `null`，不支持依赖源的 IndexedDB 等能力。本次 Windows 和 Android 仅对当前运行页的精确主文档 URL 提供本地 HTML 响应，保留真实 HTTPS 源；包、API、worker 和 frame-host 继续使用原网络路径。Windows 本地插件把所有请求标记为主 frame，因此额外核对 `Sec-Fetch-Dest`，拒绝子 frame、脚本等请求。[WebView2 本地内容说明](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/working-with-local-content)

Android、Apple、Linux 也必须分别验证加载方式产生的真实源、页面路径、Cookie、worker 和 frame-host 访问；不能假设各平台 `loadData(baseUrl: ...)` 的语义相同。当前 Linux fork 使用 `webkit_web_view_load_bytes` 传入 base URL，但仍需运行验证。

### 可切换引擎

- “设置 → 功能设置 → 交互 → 小程序运行引擎”选择默认引擎并持久化，下次打开生效。运行页菜单不再提供引擎选择；默认引擎仅在设置中管理。无设置时默认轻量宿主，未知设置值也使用轻量宿主；明确保存的官方网页选择继续保留。官方网页作为兼容备用，轻量宿主失败时提供直接切换入口。
- 轻量宿主并发获取最新运行资源表、当前登录用户和 CSRF 元数据，核对登录用户与客户端身份，随后导入官方带内容哈希的 loader，使用 `createUserDataProvider` 和 `mountLoader`。不加载论坛页面框架，不硬编码线上 loader 版本。官方加载器仍负责授权、资源下载/缓存、解密验签、应用隔离、媒体和权限执行。
- 保留项目原生工具栏、公共菜单、加载与权限面板、评分/打赏/举报和模糊设置。声音按钮对接 `setAudioMuted` 的真实状态；实际 release 由官方 `onRelease` 回调同步。独立窗口通过私有会话继承启动时选择的引擎，加载失败时仍可使用兼容引擎重试。
- Apple 和 Linux 使用带 HTTPS baseUrl 的 HTML 加载，恢复启动查询参数及锚点；启动前检查安全上下文、真实来源和路径。不满足要求会显示失败与“使用官方网页引擎重试”，不会通过关闭来源或签名检查来强行启动。五端真实 WebView 的 Cookie、IndexedDB、worker 和 iframe 行为仍须实机验证。
- 入口 HTML 标记为不缓存。切换或重试先销毁旧运行器并移除平台视图，再创建新实例；状态轮询、声音和权限回调按文档代隔离。关闭后不保活 WebView 或游戏进程，只复用官方 HTTP 和 IndexedDB 资源缓存。已解包文件的内存缓存仍随网页销毁；本次不修改官方缓存失效规则。
- 两种引擎都读取官方 `discourse-mini-app:load` 性能报告，同时记录平台视图创建、Cookie 就绪及原生观察到完成的时间。独立窗口将经过字段裁剪的报告转交主窗口写入统一日志；不记录令牌、包密码、任意页面字段或启动参数。`audio_choice` 包含用户决策时间，阶段存在并行和包含关系，不应相加作为总耗时。
- 验证包括生产宿主 JS 的执行测试、同源边界、登录绑定、资源更新、声音/销毁/取消、引擎偏好持久化，以及真实 Flutter 运行页的切换销毁、迟到回调隔离和失败回退。测试平台替身不代表五端已经实机通过，也不能据此承诺实际提速幅度。

后续按同一版本、同一设备对比两种引擎的首次打开与关闭重开。如果主要耗时仍在持久化包命中后的解包，应继续研究独立于页面生命周期的已验证资源文件缓存；当前官方 loader 没有导出解包缓存注入接口，不能靠隐藏 WebView 保活解决。
