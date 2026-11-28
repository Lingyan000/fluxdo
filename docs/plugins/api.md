# 脚本 API 参考

当前宿主支持脚本 API 版本 1 和 2。版本 2 使用 schema 9 至 12。运行时协议位于 `packages/fluxdo_plugin_runtime`，应用能力由 `MetaversePluginHost` 注入。

清单默认最多声明 16 个页面。需要更多独立路由时，声明 `extendedPages` 可扩展到 32 个；总清单、脚本与界面容量限制仍适用。路由声明不会预先创建页面或发起请求。

| 场景 | 参考 |
| --- | --- |
| 先了解运行方式 | [环境与结果](#环境与结果)、[事件与上下文](#事件与上下文) |
| 读取接口与保存数据 | [网络](#网络)、[插件数据](#插件数据)、[普通存储作用域](#普通存储作用域) |
| 打开页面、浏览器和提示 | [页面与外部链接](#页面与外部链接)、[导航页面贡献](#导航页面贡献)、[能力发现与确认](#能力发现与确认) |
| 权限申请、授权与付款 | [用户关闭权限时](#用户关闭权限时)、[权限、账号、凭证与支付](#权限账号凭证与支付) |
| 论坛与后台工作 | [论坛只读接口与原生导航](#论坛只读接口与原生导航)、[定时任务、通知与角标](#定时任务通知与角标)、[SSE 实时事件](#sse-实时事件) |
| 附件、验证和迁移 | [临时附件与私密图片](#临时附件与私密图片)、[人机验证](#人机验证)、[宿主环境、偏好与迁移](#宿主环境偏好与迁移) |

## 环境与结果

脚本可使用 JS 内置对象、`Promise`、`console`、`setTimeout`、`clearTimeout`、`fluxdo`。界面由 rfw 声明。模块代码需要在发布前打包进 `main.js`，运行时没有提供 Node 模块加载接口。

除事件注册外，`fluxdo` 方法返回 Promise。宿主拒绝调用或发生网络错误时 Promise reject，JS 接收到 `Error`。业务 HTTP 错误通常仍返回响应对象，由插件检查 `status` 或 `ok`。当前错误信息包含中文描述和部分稳定代码，业务逻辑优先使用响应状态或明确的返回字段。

以下签名使用类型说明便于阅读，运行时仍执行 JavaScript。

## 事件与上下文

### `fluxdo.on(name, handler)`

注册 `(ctx, args) => void | Promise<void>`。同名事件再次注册会替换之前的处理函数。返回注销函数 `() => void`。处理函数抛错或返回 rejected Promise 时，运行时向日志桥报告错误。

| 事件 | 触发时机 | 参数 |
| --- | --- | --- |
| `card.load` | 卡片实例创建 | 对象，可为空 |
| `page.open` | 页面实例首次打开 | 对象，可为空 |
| `page.hide` | 页面被路由覆盖、切换导航标签或应用进入后台 | `reason` 为 `route` 或 `app` |
| `page.resume` | 页面恢复前台可见 | `reason` 为 `route` 或 `app` |
| `card.refresh` | 用户刷新元宇宙服务页，不授予弹窗或导航的点击授权 | 空对象 |
| `card.hide` / `card.resume` | 卡片所在标签隐藏或恢复 | 同页面的 `reason` |
| `page.refresh` | 用户按底栏配置的刷新手势重复点击当前入口 | 空对象 |
| `surface.close` | 界面实例关闭 | 对象，可为空 |
| 自定义事件 | rfw 的 `event` 被用户操作触发 | rfw 中声明的参数与组件事件值 |

页面初次打开只收到 `page.open`。被覆盖期间进入后台，恢复可见时 `reason` 可为 `app`。旧宿主可能缺少恢复事件或 `reason`。

| `ctx` 成员 | 类型与用途 |
| --- | --- |
| `surface` | 本次界面实例标识，适合作为状态 Map 的键 |
| `kind` | `card` 或 `page` |
| `page` | 页面 ID，卡片为 `null` |
| `params` | 页面参数对象，含导航或链接规则传入的值 |
| `setData(key, value)` | 同步发出界面数据更新，返回 `undefined` |

`setData` 的 key 长度为 1–64。数据支持 JSON 值，每次最多 20,000 个节点，最大深度 32。map 中的 null 被移除，列表中的 null 及顶层空值按空字符串处理。超限更新被忽略并报告。它只更新指定 surface。

```js
const pages = new Map();

fluxdo.on('page.open', async (ctx) => {
  const state = { revision: 0 };
  pages.set(ctx.surface, state);
  const revision = ++state.revision;
  ctx.setData('loading', true);
  try {
    const response = await fluxdo.fetch('https://api.example.org/items');
    if (!response.ok) throw new Error('读取失败');
    if (pages.get(ctx.surface) === state && revision === state.revision) {
      ctx.setData('items', response.json().items || []);
    }
  } finally {
    if (pages.get(ctx.surface) === state) ctx.setData('loading', false);
  }
});

fluxdo.on('surface.close', (ctx) => pages.delete(ctx.surface));
```

示例域名需要加入清单。并发搜索还应递增 revision，避免晚到的旧响应覆盖新结果。

## 界面调用归属

事件处理器提供 `ctx.api`，其方法与 `fluxdo` 的调用方法相同。使用 `ctx.api.fetch`、`ctx.api.storage` 等会将界面身份带入调用日志。界面关闭后其绑定调用会被拒绝。

## 开发与事件释放

fluxdo.on(name, handler) 返回撤销函数，只移除本次注册，不影响之后替换的同名处理器。开发运行器在模块成功替换后自动撤销旧事件和模块定时器；自建资源仍应放进 import.meta.hot.dispose。正式脚本不携带开发运行器。

开发连接、热更新、模拟宿主与 CLI 命令见 [开发工具](development-tooling.md)。CLI 错误会包含 RFW/TS 文件位置；未提供模拟的外部 API 在测试中直接失败。开发协议错误 development_invalid_pairing 表示配对地址不符合回环协议，development_project_invalid 表示项目快照或容量无效，development_requires_api2 表示旧 API 版本不能作为开发实例，module_disposed 表示旧模块异步回调已失效。

## 网络

### `fluxdo.fetch(url, options?)`

| 参数 | 类型 | 默认与说明 |
| --- | --- | --- |
| `url` | string | HTTPS 服务 URL，须通过清单网络范围校验 |
| `options.method` | string | 默认 `GET`，支持 `GET`、`POST`、`PUT`、`PATCH`、`DELETE` |
| `options.headers` | object | 默认空对象，Cookie 等受限头由宿主检查 |
| `options.body` | JSON 值或 string | 对象自动 JSON 编码并补充 Content-Type，最大 256 KiB |
| `options.credential` | string | 声明的具名凭证，由宿主按 origin、路径和方法注入 |

返回 `{ status, headers, body, ok, json() }`。`body` 为字符串，`json()` 同步解析并可能抛出异常，`ok` 表示 HTTP 2xx。响应最大 1 MiB。重定向原样返回，插件需要对目标再次发起受检查请求。Set-Cookie 等敏感响应头被过滤。

公开请求与带凭证请求都经过目标、方法和请求头检查。API 1 的普通 token 插件继续使用 `options.auth: true`。

图片通过宿主 `Image` 组件加载，使用专用匿名请求。脚本 `fetch` 返回文本响应。

## 插件数据

| 方法 | 参数与结果 | 行为 |
| --- | --- | --- |
| `fluxdo.storage.get(key)` | string → Promise<JSON 值或 null> | 缺失键返回 null |
| `fluxdo.storage.set(key, value)` | string、JSON 值 → Promise<null> | 保存普通数据，null/undefined 按删除处理 |
| `fluxdo.storage.setMany(entries)` | object → Promise<null> | 在一个事务中修改多个键 |
| `fluxdo.storage.remove(key)` | string → Promise<null> | 删除该键 |

键长度为 1–128，`@` 前缀保留给宿主使用。卡片、页面和工作任务共享插件目录中的 `data.sqlite`，首次读取时迁移已有 `storage.json`。每个插件所有分区合计上限 2 MiB。「清空插件数据」清除全部分区并停止任务。切换账号后旧账号实例不能读取或写入新账号。

### 普通存储作用域

新 API 2 插件使用 schema 12，声明 `requiredFeatures: ["storageScopes"]` 及 `storage: {"default":"account","scopes":["shared","account"]}`。账号范围同时需要 `permissions.identity: true`。所有普通存储方法接受最后一个可选参数 `{scope: "shared" | "account"}`；省略时使用清单的默认分区。只能选择声明的分区，不能指定账号 ID。账号范围在未登录或身份权限关闭时拒绝，共享范围仍可使用。

```js
await ctx.api.storage.set('draft', {quantity: 1}); // 当前账号
await ctx.api.storage.set('categories', [{id: 1, name: '工具'}], {scope: 'shared'});
const categories = await ctx.api.storage.get('categories', {scope: 'shared'});
```

`shared` 是同一插件跨账号共享的数据，不能放订单、私信或凭证。新增可读范围或改变默认分区需要重新审阅。旧账号分区不会自动变成共享数据；从遗留共享模式升级到同时具有账号区的插件，使用 `storage.partition` 归属旧数据。显式共享区使用独立命名空间，未归属的遗留数据不会被共享读取。已经声明显式作用域的插件不能通过普通升级删掉声明；回退使用对应版本的数据快照。

未声明 `storage` 的旧清单继续兼容：声明论坛、任务、通知或底栏角标能力时使用账号分区，否则使用遗留共享区。新插件应明确声明，避免后来增加能力时意外改变数据归属。SDK 脚手架默认声明仅共享区，加入账号功能时需一起调整清单。

`storage.compareAndSet(key, expected, value)` 在同一事务内比较 JSON 值、写入并返回布尔值。`null` 表示缺少键，写入 `null` 会删除键。页面和任务同时修改同一数据时，失败的一方应重新读取后再合并。需要此能力的插件声明 `atomicStorage`。

用户可从插件管理重置本地数据和服务会话。重置会停止实例，拒绝旧代次排队写入，并等待正在写入的数据落盘后清理。批量修改通过 `setMany` 原子提交。

### `storage.setMany(entries)`

原子修改当前插件的多个键，参数为对象，值为 null 表示删除。最多 128 个键，单键长度与整体存储容量沿用 `storage.set` 的限制。返回 null，任意校验或写入失败时保留原数据。可在一次操作中保存新记录并移除旧记录。

## 页面与外部链接

| 方法 | 参数与结果 | 行为 |
| --- | --- | --- |
| `fluxdo.navigate(page, params?, options?)` | string、object → Promise<null> | 打开清单声明的页面，Promise 在发起导航后完成 |
| `fluxdo.prepareNavigation(page, options?)` | string → Promise<function(params)> | 用户点击时预约一次目标页面，返回可用于异步完成后的导航函数 |
| `fluxdo.openUrl(url)` | string → Promise<null> | 通过应用链接策略打开 HTTP(S) 地址 |
| `fluxdo.browser.open(url, options?)` | string、`{mode?}` → Promise<null> | `mode` 可选 `ask`（默认）、`inApp`、`external`、`preference` |
| `fluxdo.session.login()` | Promise<null> | 打开清单的 `webLogin` 地址 |
| `fluxdo.session.open(path)` | string → Promise<null> | 打开 `webLogin` 同源的绝对路径，例如 `/orders` |
| `fluxdo.toast(message, type?)` | string、string → Promise<null> | 存在可见界面时显示带插件身份的提示，默认 info |

普通导航、授权和网页入口需要用户操作后的 10 秒内调用，一次点击可消耗一次普通界面操作。同一时间只允许一个正在执行的界面操作。Toast 最短间隔一秒，消息最多 200 字符，具体提示样式由宿主 delegate 决定。

`options: {replace: true}` 使用 `navigationReplacement` 能力，替换当前插件的普通页面；
返回时不再进入已经完成的表单。不能替换底栏主页、其他插件页面或弹层。目标页以普通页面展示。
开发预览也支持替换；生产环境的替换始终受用户点击或有效预约约束。

预约绑定目标页面、替换方式、原始 surface 和账号，成功使用后失效。新的插件点击、离开原页面、关闭页面或应用进入后台使预约失效。本次原生确认框可临时覆盖页面，待 `page.resume` 后调用预约函数。预约可跨越普通点击的 10 秒窗口。`prepareNavigation` 自 `8679b7ab` 提供，使用前检查方法是否存在。

`browser.open` 需要用户点击触发。`inApp` 直接使用内置浏览器，`external` 使用外部浏览器，`ask` 每次展示打开方式选择，`preference` 沿用应用设置。直接打开模式仍执行链接安全检查，高风险地址保留确认，阻止地址按应用规则处理。

```js
await ctx.api.browser.open("https://example.org", {mode: "inApp"});
```

旧宿主应先检查 `ctx.api.browser?.open` 是否存在，再决定使用 `openUrl`。组件库当前提供原生 RFW 组件，网页展示通过浏览器 API 打开独立页面。

网页会话在浏览器中管理。网页入口的 Promise 不携带登录结果，插件应通过服务协议确认登录状态。

## 导航页面贡献

schema 11 支持在普通页面中声明 `navigation: {label, icon?}`，`label` 为 1–12 字符，图标使用现有组件库图标名，省略时继承插件图标。弹层页面不能作为底栏入口。

```json
{
  "schema": 11,
  "apiVersion": 2,
  "requiredFeatures": ["navigationEntries", "forumRead"],
  "permissions": {"network": [], "identity": true, "forum": ["activity"]},
  "pages": [{
    "id": "activity", "title": "用户动态", "widget": "Activity", "scroll": false,
    "navigation": {"label": "动态", "icon": "person"}
  }]
}
```

这是清单片段，仍需填写插件身份与资源字段。用户选择后才加入导航，脚本不能自行添加或重排。稳定标识由插件 ID 和页面 ID 组成，修改标题或图标不会改变配置。卸载、禁用、挂起、升级移除页面时，实际导航隐藏入口并回到可用页面；设置保留原位置供用户移除或日后恢复。恢复后不会强行切换当前页面。

第一次选中才启动页面，切换标签保留 RFW 数据与滚动位置，返回仅发 `page.resume`。插件所有界面都不可见时，宿主冻结页面定时器；恢复后继续剩余延时。需要关闭页面后更新的插件应声明独立任务。

底栏重复点击的回顶动作滚动宿主页面容器；刷新动作发 `page.refresh`，由插件注册处理器。推荐使用 `scroll:false` 配合 `PageLayout`、`ListPage` 或 `GridPage`，避免自行嵌套滚动容器。

## 多服务链接接管

宿主按已启用服务的静态链接规则收集候选，第三方插件不能覆盖论坛内链。单候选直接进入页面；多个候选由用户选择服务和目标页面，或选择浏览器。取消选择会终止本次点击。用户可按域名记住选择，偏好仅在多个候选时生效；选择结束时再次核对候选，脚本不能指定优先级。

插件默认选择在停用、卸载、暂停、撤销链接权限或不再声明该域名时失效。浏览器偏好在该域名最后一个可用服务消失时清理，候选数量暂时减少不会清除选择；域名匹配包含通配子域，路径参数不参与偏好回收。插件管理页的更多菜单可重置全部已记住的选择，取消确认不改变偏好。保存失败恢复仍有效的选择，期间发生的停用或新选择优先，迟到写入不能覆盖重置结果。

## 能力发现与确认

### `host.features()`

返回当前宿主支持的能力名称数组。必需能力在 schema 10 或更高版本的 `requiredFeatures` 中声明。可选功能用运行时查询决定是否展示。完整名称见[宿主能力注册表](../../packages/fluxdo_plugin_runtime/lib/src/plugin_features.dart)。

### `dialogs.confirm({title, message, confirmLabel, agreement?})`

显示宿主原生确认弹框，返回 boolean。需要当前页面的用户操作。`agreement` 可含 `{label, url}`，url 必须是 HTTPS；宿主提供阅读入口和默认未勾选的同意项，未勾选无法确认。取消、关闭均返回 false。宿主不会替插件保存同意状态。

确认成功后只续接一次用户操作资格，可调用 Connect 或导航；账号切换、页面销毁或应用仍在后台时不续接。Connect 仍显示自己的账号授权确认，服务条款不代替账号授权。

```js
fluxdo.on('login', async ctx => {
  if (!await ctx.api.dialogs.confirm({
    title: '登录服务', message: '请阅读并同意服务条款。', confirmLabel: '继续',
    agreement: {label: '服务条款', url: 'https://service.example/terms'}
  })) return;
  // 服务自己的初始化、PKCE、回调交换由插件实现。
  const callback = await ctx.api.connect.authorize(authorizationUrl);
  if (!callback) return;
});
```

完整 TypeScript 签名见 [独立 SDK 类型声明](https://github.com/Lingyan000/fluxdo-plugin-tools/blob/main/packages/sdk/types/global.d.ts)。开发中心可直接体验确认框、协议勾选和取消结果，不会向服务发起真实授权。

## 控制台与定时器

| 调用 | 参数与行为 |
| --- | --- |
| `console.log(...values)` | 字符串或 JSON 序列化值，级别 info |
| `console.info(...values)` | 同 log |
| `console.debug(...values)` | 当前实现映射到 info |
| `console.warn(...values)` | 级别 warn |
| `console.error(...values)` | 级别 error |
| `setTimeout(fn, ms, ...args)` | 返回本运行实例内的计时器 ID，非函数返回 0 |
| `clearTimeout(id)` | 取消计时器，返回 undefined |

插件设置可按等级、类型和来源筛选日志，并单独清空或导出。`pluginId` 标识插件，`runtimeId` 标识运行实例，`emitter` 区分宿主和插件；界面调用还带 `surfaceId`。网络核心按 `coreRequestId` 关联异步记录，未关联请求的共享连接事件只归宿主。系统任务的已脱敏日志限量暂存，下次在前台归档。每实例每分钟最多记录 120 条 console 日志。

每个运行时最多 64 个计时器，延时最大 10 分钟，负值按 0 处理。计时器超额时当前桥会忽略设置请求。并发宿主调用最多 32 个，surface 最多 16 个。最后一块界面关闭后，宿主默认 30 秒释放运行实例。单条引擎指令默认 5 秒看门狗，具体资源隔离局限见架构审计。

## 权限、账号、凭证与支付

服务插件负责发起授权、处理回调、交换服务凭证、调用业务接口及刷新交付结果。宿主提供 Connect 账号授权、按范围注入凭证、原生 LDC 收银台。宿主结合清单和用户当前的权限选择检查每次调用。

### 用户关闭权限时

声明 `requiredFeatures: ["runtimePermissions"]` 后，页面可通过 `await ctx.api.permissions.status()` 获取本插件声明的权限及其开关状态。返回对象中，`false` 表示已关闭，缺少的键表示未声明。状态查询不会弹框。

在用户点击具体功能时，可以调用 `await ctx.api.permissions.request(['forumActivity'])`。宿主只展示本次操作缺少的可管理权限。允许后返回 `true`，脚本可继续当前操作。取消返回 `false`，适合保留输入、显示已有内容和重新申请入口。已允许的权限直接返回 `true`。弹框需要当前前台界面有效的用户操作，任务不能申请，基础能力和清单外的权限不能申请。插件开关与 Connect 确认、逐笔支付、系统通知授权各自生效。

作者在清单中声明访问范围。宿主负责分类，用户可以在安装页选择，也可以稍后到插件的「权限管理」修改。同源更新沿用已有开关，新增的敏感权限类别默认关闭。已有类别的访问范围扩大时，用户需要重新审阅清单。`host.features()` 表示宿主支持某项 API，调用时仍要检查权限。

| 权限 | 关闭后的行为 |
| --- | --- |
| 当前论坛账号 | `user.get()` 返回 `null`。公开页面仍可使用。 |
| 服务账号 | `credentials.status()` 和旧版 `auth.status()` 返回未授权。宿主清除此插件的服务凭证。登录、获取凭证和带凭证的请求会被拒绝。 |
| 用户资料、动态、关注列表 | 每个范围独立检查。已关闭的 `forum.read` 不返回数据。 |
| 支付 | 宿主拒绝打开收银台。允许时每笔付款仍需用户确认。 |
| 后台更新 | 已安排的任务转为仅前台运行。重新允许后，需由用户重新启用任务的后台更新。 |
| 通知 | `notifications.isAllowed()` 和 `requestPermission()` 返回 `false`，清除已发通知。重新允许申请后仍需当前账号和系统授权。 |
| 内容链接、外部图片 | 关闭内容链接使帖子链接恢复通常的打开方式。关闭外部图片后仍允许清单联网域名内的图片，以及宿主按论坛读取结果准许的头像。 |

被策略拒绝的敏感操作抛出 `permission_denied:<权限标识>`。插件应保留可用的功能，并在用户尝试受限操作时提示可从「权限管理」开启。要删除已缓存的业务数据，可以在插件管理中选择「清空插件数据」。

```json
{
  "schema": 9,
  "apiVersion": 2,
  "permissions": {
    "network": ["api.example.org"],
    "identity": true,
    "connect": ["https://api.example.org/callback"],
    "credentials": {
      "account": {
        "label": "服务访问凭证",
        "header": "Authorization",
        "scheme": "Bearer",
        "requests": [{
          "origin": "https://api.example.org",
          "pathPrefix": "/v2",
          "methods": ["GET", "POST"]
        }]
      }
    },
    "payments": ["linuxDoCredit"]
  }
}
```

以上片段展示新增字段，完整清单仍须包含身份、版本及界面资源。API 2 清单通过 `permissions` 声明能力。`credentials` 的名称由插件定义，请求限制按 origin、路径前缀和方法共同匹配，路径按段匹配。凭证头默认为 `Authorization`，scheme 默认为 `Bearer`，空 scheme 可用于 API key。Connect 回调须为网络权限内的 HTTPS 精确地址。

### `credentials.status(name, {jwt?: boolean})`、`credentials.remove(name)`

`status` 返回 `{authorized, expiresAt}`，过期时间为 Unix 秒或 null。有效性包含当前应用账号绑定和过期检查。`remove` 返回 null，移除该具名凭证，并取消正在保存或使用旧版本凭证的调用。清空插件数据也会移除全部凭证。

宿主支持 `credentialClaims` 时，`status(name, {jwt: true})` 对有效 JWT 额外返回 `claims`，与 `capture(..., {jwt: true})` 的声明一致，方便恢复已有会话的用户资料。非 JWT 或无法解析的凭证省略该字段，过期、账号不符或关闭服务账号权限时也不返回。声明是解码数据，不能替代服务端的签名与身份校验；不得将完整声明写入日志，宿主不会返回凭证原文。

### `credentials.request(name)`

用户点击后打开原生凭证输入弹框，保存成功返回 true，取消返回 false。插件通过具名凭证调用网络接口，输入内容保存在宿主安全存储。

### `credentials.capture(name, request, options)`

用于服务端响应中的凭证交换。`request` 使用 `fetch` 的 url、method、headers、body 字段。`options.tokenPath` 是 JSON 字段名或数组索引构成的路径，长度 1–16，可选 `expiresAtPath` 提取 Unix 秒。`jwt: true` 可解码 JWT 的 claims 和 exp。JWT 的签发身份、业务账号和服务权限须由插件通过服务验证接口核对。

```js
const captured = await ctx.api.credentials.capture('account', {
  url: 'https://api.example.org/token',
  method: 'POST',
  body: {code, verifier}
}, {tokenPath: ['access', 'value'], jwt: true});
const response = await ctx.api.fetch('https://api.example.org/v2/me', {
  credential: 'account'
});
```

返回 `{authorized: true, expiresAt, claims?}`。宿主直接保存选中的凭证，返回值仅包含状态及选定的 JWT 声明。交换请求须满足网络权限，成功状态为 HTTP 2xx，JSON 或字段无效会拒绝保存。交换期间账号变化、插件停用、移除凭证或清空数据都会取消操作。

### `connect.authorize(url)`

用户点击后由宿主再次显示公共 Linux DO Connect 确认框，展示当前账号、插件和回调网站；明确同意后才发起授权。返回服务回调 URL，取消返回 null。宿主检查授权地址、redirect_uri、回调地址和 state。插件随后请求回调并处理服务协议。服务初始化接口、PKCE 关联和凭证交换由插件实现。

### `crypto.pkce()`、`crypto.uuid()`

`pkce` 返回 `{verifier, challenge, method: 'S256'}`，使用安全随机数和 SHA-256。`uuid` 返回安全随机 UUID v4。适合授权关联与业务幂等提交号。

### `crypto.sha256(text)`

对 UTF-8 文本计算 SHA-256，返回小写十六进制字符串。输入上限 1 MiB，可用于本地记录索引与数据摘要。

### `payments.request({provider, url, reference, amount})`

用户点击后打开应用原生收银台。当前 provider 为 `linuxDoCredit`，url 使用 LDC 收银台地址，reference 是服务订单号，amount 推荐传十进制金额字符串。宿主核对 LDC 返回的订单号、付款账号和金额，付款确认使用 LDC 交易 ID 校验收款账号、金额及状态。支付密码和生物识别由应用管理。

返回收银台结果 `{state: 'paid'}`，已提交但尚未确认时返回 `{state: 'pending'}`，提交前关闭返回 null。付款成功后，插件刷新自己的订单与交付接口。测试和应用内开发中心使用模拟桥。

API 2 的 `user.get()` 返回当前账号的 `{id, username}`，需要 identity 权限。通用网络、存储、界面与导航接口沿用下文签名。API 1 仅保留普通网络、存储、界面和手填 token 兼容。服务授权及订单协议已迁入插件脚本。

## 论坛只读接口与原生导航

论坛的会话、请求队列、代理和网络日志仍由宿主维护。插件不能把论坛域名加入 `permissions.network`，也不能获得 Cookie、CSRF、私信接口或原始用户对象。API 2 + schema 11 的 `permissions.forum` 支持三种权限，安装和权限更新时展示：

| 权限 | `resource` | 返回内容 |
| --- | --- | --- |
| `profiles` | `user` | id、用户名、昵称、头像、信任级别、最近在线和发帖时间 |
| `activity` | `actions` | 用户的发帖、回复、点赞 |
| `activity` | `reactions` / `boosts` | 发出的回应与 Boost |
| `following` | `following` | 关注列表的基本用户字段 |

### `ctx.api.forum.read(options)`

从可见页面或有效调度任务的 `ctx.api` 调用。需要登录，并只能读取服务端允许当前账号看到的内容。页面模块顶层调用不会获得界面权限。

```ts
const page = await ctx.api.forum.read({
  resource: 'actions', username: 'demo',
  actions: ['topics', 'replies'], offset: 0
});
// page.items、page.nextOffset；实际字段有完整 TypeScript 声明。
await ctx.api.forum.open({type: 'topic', topicId: 42, postNumber: 1});
```

`actions` 可选 `topics`、`replies`、`likes`，默认三种；不能传 Discourse 的任意过滤编号。`actions` 和 `following` 使用 `offset`（0–10000），后者每页最多 100 条；`reactions`、`boosts` 使用 `before` 游标。响应分别提供 `nextOffset` 或 `nextBefore`，空页时为 null。时间均为 UTC ISO 字符串。支持的返回字段以 SDK 类型为准，页面标题、摘要等可为 null。

请求受全局与每插件预算控制：每插件每分钟最多 120 次、同时 2 次；所有插件每分钟最多 240 次、同时 6 次。服务端 429 按 Retry-After 秒数冷却 60–3600 秒，403 冷却至少 60 秒。插件应指数退避，不要不断重试。关闭页面、隐藏标签、停止插件或切换账号后，迟到响应不会交给插件。单次结果上限 512 KiB。

错误码：`forum_permission_denied`、`forum_auth_required`、`forum_not_visible`、`forum_account_changed`、`forum_rate_limited`、`forum_forbidden`、`forum_not_found`、`forum_network_error`、`forum_response_too_large`，以及无效参数对应的 `forum_invalid_*`/`forum_unknown_resource`。

论坛响应提供的 `avatarUrl` 可直接用于图片组件，无需额外论坛网络权限。宿主只登记响应中实际返回的头像 URL，并匿名下载；它不是脚本读取站点任意资源的通道。

### `ctx.api.forum.open(destination)`

用户点击后打开宿主原生页面：`{type:'topic', topicId, postNumber?}` 或 `{type:'user', username}`。不需要论坛读取权限，也不会向插件返回原生页面内的数据。每次调用消耗用户激活；页面加载或定时器不能触发导航。Promise 在发起导航后结束，无需等用户返回。

开发中心的 API 列表提供两项接口的参数与响应演示，论坛数据使用模拟值，导航演示展示原生页面外壳，避免演示读取真实账号。独立工具仓的 `examples/forum-activity` 可用于真实 App 联调。

## 定时任务、通知与角标

使用 API 2、schema 12。清单可声明最多 4 个 `tasks: [{id, title}]`，并列出 `requiredFeatures: ["scheduledTasks"]`。需要系统后台调度时再声明 `permissions.background: true`。进程前台运行时不要求页面打开。Android 使用 WorkManager，iOS 使用 BGTaskScheduler，两者按系统条件调度；不能保证 15 分钟唤醒一次。桌面仅在应用进程存活时运行。无远程推送或常驻服务。

| 接口或事件 | 行为 |
| --- | --- |
| `ctx.api.tasks.schedule({id, intervalSeconds, background?})` | 需要用户点击；前台间隔 10–86400 秒，默认不在后台运行。开启后台另有宿主确认，取消返回 `false`。同 ID 重新设置取代旧计划。 |
| `ctx.api.tasks.list()` / `cancel(id)` | 列出或停止本插件当前账号的任务；列表含 `nextAt`、`lastAt`（毫秒时间戳）和最近错误码。任务失败会退避。 |
| `fluxdo.on('task.run', async (ctx, {id,background}) => …)` | 在独立 JS 实例中运行，无页面与点击资格。返回的 Promise 决定执行结果；支持已批准的只读请求、存储、角标及通知，不能导航、授权或付款。每次仅执行一个到期任务，不补跑积压周期。 |
| `task.updated` / `page.resume` | 前台任务完成后通知可见页面重新读取存储。系统后台执行时没有页面事件，恢复前台时从存储读取。 |
| `ctx.api.navigation.setBadge(page, count)` | 需要 `navigationBadge` 及该页的 `navigation` 入口，`0` 清除，最大 99999。不会自行添加底栏入口。 |
| `ctx.api.navigation.dismiss()` | `modalDismiss`。完成表单后从当前插件弹层调用，成功关闭返回 `true`。普通页面、卡片或被其他路由覆盖时返回 `false`。 |
| `ctx.api.notifications.requestPermission()` / `isAllowed()` / `revoke()` | 声明 `permissions.notifications: true` 和 `localNotifications`。申请须由可见界面的点击触发；用户可从宿主管理页撤销。`isAllowed()` 返回该账号对该插件的授权，系统也可独立静音。撤销同时取消已发通知。 |
| `ctx.api.notifications.status()` / `openSettings()` | 声明 `notificationStatus`。状态返回 `{authorized, system, canOpenSettings}`；`system` 为 `allowed`、`denied` 或 `unknown`。`authorized` 仅表示当前账号给插件的许可；系统拒绝后保留插件偏好，发送时返回 `notification_system_denied`，不会计入已投递。`openSettings()` 必须由用户点击触发，不自动更改许可；Android 定位插件通知渠道，未创建渠道或全局禁用时打开应用通知设置，iOS 定位应用通知设置，macOS/Windows 打开系统通知设置，Linux 返回 false。 |
| `ctx.api.notifications.show({key,title,body,page,params?})` / `cancel(key)` | 只打开本插件声明的页面；系统通知只携带宿主编号。同键一分钟内合并，每插件每分钟最多三条。停用、换源、退出账号后不能再由旧通知打开原页面。 |

```js
fluxdo.on('enable', ctx => ctx.api.tasks.schedule({ id: 'refresh', intervalSeconds: 30 }));
fluxdo.on('task.run', async (ctx, {id}) => {
  if (id !== 'refresh') return;
  // 在这里读取已获准的数据源；只持久化下一次打开页面需要的字段。
  await ctx.api.storage.set('lastRefresh', Date.now());
});
```

打包安装后可测试完整的系统授权、冷启动和撤销。临时开发会话不注册正式任务或通知。

## SSE 实时事件

声明 `requiredFeatures: ["eventStreams"]`。复用 `permissions.network` 与凭证的请求范围；带凭证时需要用户允许「服务账号」。不新增单独的消息连接开关。连接不会赋予系统通知权限，发通知仍需用户授权。

```js
fluxdo.on('page.open', async ctx => {
  await ctx.api.streams.open({
    id: 'updates', url: 'https://api.example.org/events', credential: 'account'
  });
});
fluxdo.on('stream.event', (ctx, frame) => {
  // event、data、lastEventId 都来自服务端，不把它们当作用户点击。
  if (frame.event === 'count.changed') ctx.setData('unread', JSON.parse(frame.data).unread);
});
fluxdo.on('stream.state', (ctx, state) => {
  if (state.state === 'open') { /* 按服务协议补查断线期间可能遗漏的状态。 */ }
});
// 在拥有订阅的同一 ctx 中关闭：await ctx.api.streams.close('updates');
```

- `streams.open({id,url,credential?,headers?,lastEventId?})` 返回订阅 ID；实际连接结果通过 `stream.state` 返回。只允许可见页面或卡片、HTTPS 标准端口、清单允许的域名；不自动跟随重定向。相同界面的同 ID 不能重复打开。
- `streams.close(id)` 立即取消该界面的连接与重试，无需等网络返回。重复关闭无副作用。
- `stream.event` 参数为 `{id,event,data,lastEventId}`，data 是原始文本，JSON 解析由插件负责。处理器 Promise 完成后再交付下一帧；10 秒仍未结束则停止订阅。
- `stream.state` 的 `state` 为 `connecting/open/retrying/closed`，可附 `reason/status/retryInMs`。401/403、重定向、非 SSE 响应、非法帧和速率超限停止；网络中断、429、5xx 退避重连，遵守服务端 `retry` 与 `Retry-After` 秒数。204 表示停止。
- 隐藏或应用切后台立即断开，恢复时重连；关闭页面、撤销授权、注销服务账号、换账号或插件停用后取消。系统任务不能建立长连接。页面隐藏时不向脚本追加状态事件，使用已有 `page.hide/card.hide` 生命周期。
- 每实例最多 8 个订阅、2 条同时连接，全局最多 12 条连接；每实例每分钟最多发起 30 次连接。帧最多 64 Ki 个 UTF-16 单元，每 10 秒最多 1 MiB 或 300 条数据事件；75 秒无字节活动即重连。心跳注释不交给业务处理器。
- 重连携带最后成功交付的 `Last-Event-ID`；服务端是否重放取决于自身协议，插件仍应补查快照及去重。未以空行结束的残缺帧丢弃。凭证不交给脚本，日志只记插件、界面、目标域名、连接状态和错误码，不记录 URL 参数或事件正文。

应用内开发中心提供动态 `streams.open` 演示，用模拟消息展示连接、消息到达与重连，无真实账号请求。Android、iOS 和三种桌面平台共用此实现；后台长连接与远程推送不在此 API 的保证范围。

## 临时附件与私密图片

声明 `fileAttachments`。文件选择和预览必须由当前可见界面的点击触发，系统任务不能使用。文件字节留在宿主内存，脚本只能取得 `{handle,name,size,mimeType}`；句柄不能跨页面使用。上传目标继续受 `permissions.network`、凭证路径与用户「服务账号」许可约束。

```js
fluxdo.on('choose', async ctx => {
  const file = await ctx.api.files.pick({extensions: ['png', 'jpg', 'webp'], maxBytes: 5242880});
  if (file) { /* 记录句柄，在界面中显示文件名，等待用户提交。 */ }
});
fluxdo.on('upload', async ctx => {
  const response = await ctx.api.files.upload({
    id: 'evidence', handle: selected.handle, url: 'https://api.example.org/evidence',
    credential: 'account', encoding: 'multipart', field: 'file', fields: {operationId}
  });
  if (response.ok) await ctx.api.files.release(selected.handle);
});
fluxdo.on('files.progress', (ctx, {id, sent, total}) => {
  if (id === 'evidence') ctx.setData('progress', total > 0 ? sent / total : 0);
});
fluxdo.on('files.invalidated', ctx => { /* 清空已选文件和上传状态。 */ });
```

`encoding: 'base64'` 将文件编码到 JSON 的 `field` 字段，不添加 data URL 前缀；`multipart` 将附加字段作为字符串发送。支持 POST/PUT/PATCH，不跟随跳转，不自动重试。进度代表发送字节数，不能替代服务端成功响应。取消或网络断开后，服务端仍可能已接收；插件应复用服务端支持的幂等操作号并先核对记录。

`files.cancel(id)` 取消当前页面的传输，`files.release(handle)` 释放单个文件。每文件至多 16 MiB，默认 5 MiB，每实例至多 8 个文件、总计 32 MiB、同时 2 个操作。页面关闭、普通导航遮挡、应用切后台、停用或账号变化会撤销句柄；由 `files.preview` 打开的查看器暂时遮挡来源时保留句柄。撤销产生 `files.invalidated`。

`files.preview({handle})` 预览已选图片，或用 `{url,credential?,headers?}` 读取受保护的图片。复用应用图片查看器，仅接收 PNG/JPEG/WebP/GIF；不跟随重定向，不写入共享图片缓存，不把图片字节交给脚本。来源失效时关闭查看器并移除其解码缓存。保存或分享是用户在查看器中的单独操作。

## 人机验证

声明 `captchaChallenge` 后，用户点击可调用 `captcha.request({provider:'hcaptcha',origin,siteKey})`，成功返回短期令牌，取消返回 `null`。`origin` 必须是已声明网络域名的 HTTPS 标准端口来源，不能带路径或查询；服务端如何验证令牌、绑定动作及防重放由插件对应服务负责。

宿主复用原生验证码面板，只载入宿主生成的文档和官方验证控件；不载入业务页面，不注入业务凭证。准备超时、过期和切后台使当前挑战失效，重试后旧回调不能继续。验证成功后仍需由业务服务校验，不能把得到令牌等同于业务成功。

验证内容由平台 WebView 承载。Android 不启用会清理应用共享 Cookie 的 incognito；不主动读取、写入或注入论坛 Cookie，CSP 限制资源到验证服务域名，不能承诺独立的 Android Cookie 容器。其他平台使用可用的无痕配置。应用内演示使用模拟挑战，真实 siteKey 的跨平台运行仍需接入方验证。

## 宿主环境、偏好与迁移

声明 hostEnvironment 后，ctx.api.host.environment() 返回当前应用语言标签、平台和时区偏移分钟数。语言来自应用选择，未选择时跟随系统；host.environmentChanged 事件通知可见界面重新读取。隐藏期间不重放变化，恢复可见时应重新读取。后台任务可以读取当时环境，但不会收到页面事件。

声明 pluginPreferences 并在清单 preferences 配置普通偏好，支持 toggle、text 和 choice。宿主管理页负责校验与保存，ctx.api.preferences.get() 返回当前清单的有效值或默认值；插件不能直接修改这些宿主设置。preferences.changed 通知可见页面。每插件最多 24 项、选项至多 32 项、文本值最多 512 字符；密码和令牌仍使用凭证接口，不放在普通偏好里。

声明 `manifestLocalization` 后可用 `locales` 覆盖显示文字，例如 `{"en":{"name":"Store","pages.market.title":"Market"}}`。可翻译名称、简介、页面标题、导航标签、任务标题、偏好标题和选项；标识、资源路径、权限和来源不能翻译。按地区、语言、原始字段依次回退，译文不会改变已有权限审阅。市场条目可独立提供 `name/summary/description/changelog` 的 `locales`。

声明 dataMigrations 与 dataVersion 后，storage.migrate 只在数据版本增加时触发。其 ctx.api 仅允许普通存储与 host.features，fromVersion/toVersion 是正整数。迁移在副本上逐分区进行，事件 `scope` 标识 `shared`、`account` 或未归属的 `legacy`；不能借 scope 参数跨区读写。失败保留旧版，不会重复联网或重放付款。详见[版本恢复与数据迁移](automatic-updates.md#版本恢复与数据迁移)。

从公共数据切换到账号分区时，声明 `accountDataMigration` 并处理 `storage.partition`。该事件接收 `{accountId, legacy, account}`，返回新的 `{legacy, account}`，只在无网络、凭证和界面能力的隔离引擎中执行；迁移与正常页面都无法读取其他账号分区。必须保留无法归属的数据、处理冲突并移除已经消费的旧记录。执行时机、权限和并发规则同上文链接。

## API 1 手填凭证兼容

旧插件的 token 模式仍支持 `auth.status()`、`auth.request()`、`auth.signOut()`。状态返回 `{required, authorized}`，request 仅由用户点击触发并收集手填凭证，signOut 删除本地凭证。新插件使用本页 API 2 具名凭证。

旧版服务协议清单保留在已安装列表中，显示更新提示。更新时按插件导出旧记录，由插件解释和迁移。新版安装器拒绝旧服务协议，宿主桥和 SDK 已移除 `auth.query` 与 `checkout`。
