# 元宇宙第三方插件

完整开发入口见 [插件开发文档](plugins/README.md)，包含当前 API、组件参考和架构审计。本页描述现有清单与协议。

元宇宙（`lib/pages/metaverse_page.dart`）里除了内置的 LDC / CDK，还可以接入第三方
服务。第三方插件由社区作者提供、用户通过清单地址安装，**界面是原生绘制的**：插件
下发声明式界面描述，由宿主用 Flutter 组件渲染，不走 WebView。

可运行的完整示例见 [`docs/examples/metaverse-plugin/`](examples/metaverse-plugin/)，
下面的说明与它一一对应。

## 为什么不是 WebView

- 界面自动跟随主题、圆角、字体与深浅色，视觉上和应用是一体的。
- 插件拿不到 WebView 这种"可以自己发请求"的环境：所有联网都经宿主转手，
  按清单声明的域名白名单放行。
- 插件脚本使用独立运行实例，并有调用限额和看门狗。原生引擎执行中断仍有平台限制，详见 [运行时隔离评估](plugins/architecture-review.md#目标结构与代码隔离)。

## 插件包

实际业务插件见 [LD士多](../plugins/ld-store/README.md)。清单页面可以指定
`presentation: "modal"`：链接和脚本打开同一个页面时，共用其 UI 和数据逻辑，
宽屏使用对话框，其余使用底部弹层；省略时仍然打开独立页面。

作者可以用 `dart run tool/pack_metaverse_plugin.dart <目录> <输出文件>` 生成
本地安装文件。文件和远端安装都要通过清单、资源大小和 UI 校验，并由用户确认权限。

```
plugin.json    清单：声明能力
ui.rfwtxt      界面描述（声明式，只有组件树与数据引用）
main.js        逻辑（跑在独立的 JS 引擎里）
```

三个文件都放在同一个目录，清单里的 `ui` / `script` 是相对清单地址的路径，
安装时宿主只允许下载同源文件。

## 清单

宿主支持 schema 1 至 7。网站会话、商品弹层和公开图片需要 schema 2 或以上，服务读会话需要 schema 3，具名查询需要 schema 4，逐笔确认的原生建单需要 schema 5，原生 Connect 授权、LDC 买家支付与页面自管滚动需要 schema 6，`SearchInput` 需要 schema 7。旧版宿主会在安装时提示版本不兼容。下方基础示例仍使用 schema 1。

```json
{
  "schema": 1,
  "id": "com.example.points",
  "name": "示例积分",
  "version": "1.0.0",
  "author": "example",
  "description": "一句话说明",
  "homepage": "https://example.com/points",
  "icon": "wallet",
  "ui": "ui.rfwtxt",
  "script": "main.js",
  "permissions": { "network": ["api.example.com"], "identity": true },
  "auth": {
    "type": "token",
    "label": "API Key",
    "helpUrl": "https://example.com/points/keys",
    "hosts": ["api.example.com"]
  },
  "card": { "widget": "Card" },
  "pages": [{ "id": "order", "widget": "OrderPage", "title": "订单详情" }],
  "links": [{ "host": "example.com", "path": "/orders/:id", "page": "order" }]
}
```

字段要点：

| 字段 | 说明 |
| --- | --- |
| `id` | 反向域名形式，全局唯一；同一个 id 从别的地址安装会被当作另一个插件 |
| `icon` | 宿主图标名（`wallet`、`token`、`refresh` 等，见 `lib/modules/metaverse/plugin/ui/metaverse_widget_library.dart`） |
| `permissions.network` | 联网白名单。精确域名或 `*.example.com`；不接受内网、IP、以及站点自身域名 |
| `permissions.identity` | 是否允许读取当前用户名 |
| `auth` | `token`：启用时手动填写凭证。可选的 `readSession`：使用已由服务签发、宿主安全保存的会话读取数据。脚本只能让宿主代发 |
| `card` / `pages` | 界面上出现的两处插槽：元宇宙页里的卡片、独立页面 |
| `links` | 接管帖子里的哪些链接。`host` 同样不能是站点自身，`path` 支持 `:name` 与结尾 `*` |

`auth.type` 为 `token` 时，`auth.hosts` 必须是 `permissions.network` 的子集——凭证只能
发往已声明要访问的域名。

schema 3 可声明 `"auth": {"type":"readSession","hosts":["api.example.org"]}`。只允许一个精确的网络权限域名、标准 Authorization Bearer 和不带自定义头或请求体的 GET；不能改授权头、申请手填凭证或用它提交订单。`auth.status().required` 表示是否需要手填才能启用，`authorized` 表示宿主当前是否持有凭证，不代表服务端仍承认它。页面必须处理 401、403 与匿名状态。此能力只消费会话，不实现签发；网页登录也不会自动建立原生授权。已安装插件改变授权声明时清除旧凭证并停用，须重新开启。

## 有独立授权的查询

具名查询和建单是独立授权。订单插件即使能读取订单或查询报价，也不能据此创建订单。

schema 4 的服务读会话可额外声明 `auth.queries`，例如 `{"orderQuote":"/api/shop/orders/quote"}`。安装时显示精确端点。受信任的宿主签发适配器必须另外核实该端点仅执行查询，将获准的完整 URL 与本次令牌作为同一会话安全保存。旧令牌和没有查询授权的会话只能 GET；插件清单本身不能授予权限。

脚本用 `fluxdo.auth.status().then(s => s.queries)` 获得当前会话允许的查询名，调用 `fluxdo.auth.query("orderQuote", {productId, quantity})`，返回 `status`、`ok`、`body` 和 `json()`。POST 请求的 URL、方法、JSON 和授权头由宿主组装。普通 `fetch` 的限制不变，不能把下单、支付或其他有副作用的操作当成查询授权。登出、卸载、更换来源或授权声明均清除会话及其查询授权。

## 原生授权与支付（schema 6）

`auth.connect` 声明 `init`、`callback`、`exchange`、`verify`、`terms` 的完整 HTTPS 地址，均须在网络权限范围内，交换和校验端点属于凭证域名。当前实现支持士多的 Connect + PKCE 交接协议，其请求字段和回调格式固定。宿主使用网站已有回调、state、S256 verifier、一次性码和服务验证接口建立绑定当前账号的会话。`auth.request()` 由点击触发原生条款确认，取消返回 false。

`auth.payment: "linuxDoCredit"` 与 `readSession`、`checkout` 一同声明。安装确认会展示该权限，授权成功后宿主按此服务协议配置报价和建单能力。

- `fluxdo.checkout.pay(orderNo)` 读取业务订单与支付链接，取得 LDC 买家订单，核对账号、金额与商户订单号后展示原生支付确认。六位密码由应用处理，用于 LDC 买家付款请求。
- `fluxdo.checkout.cancel(orderNo)` 展示原生取消确认后取消对应业务订单。
- 两个入口都要求用户点击，且同一插件同时只能处理一笔交易。支付响应丢失后查原单，结果返回给脚本后由订单接口重新读取状态。
- 业务订单协议由 `checkout.create` 路径推导详情、`payment-url`、`refresh`、`cancel` 路径，结构参见 LD士多示例。采用其他交易协议的服务需新增宿主适配。

页面声明 `scroll: false` 时由页面组件管理滚动与底部区域。`PageLayout(children, footer, loading, onRefresh)` 提供居中内容、下拉刷新与固定底部操作栏，配合 `TileGrid`、`Choice`、`EmptyState`、`SelectableLabel` 组合页面。省略 `scroll` 时保留原有宿主滚动方式。

### 应用级 LDC 收银台

`lib/modules/ldc_payment/ldc_payment_sheet.dart` 提供统一收银台，依赖应用服务层的 `LdcPaymentDelegate`。业务适配器负责准备订单、回查交付状态及会话有效性，`LdcPaymentService` 负责核对 LDC 订单、设置初始密码和提交付款。元宇宙的 `MetaversePayment` 实现此接口，插件脚本只接触订单号与结果。收银台可以供其他应用模块和采用 LDC 的插件复用。

指纹、面部识别与 Touch ID 的本机确认由应用级 `LdcBiometricPayment` 提供。在用户勾选开启、密码付款获得明确成功响应后，再经系统生物识别确认保存支付密码。密码按付款账号隔离，写入现有系统安全存储，每笔付款都重新进行系统认证，随后读取密码并向 LDC 提交。关闭该能力会删除本地保存的密码。应用层认证门控与系统安全存储分别执行，当前没有配置逐笔生物识别绑定的存储密钥。

Android、iOS、macOS 在设备提供已录入的生物识别时展示入口。Windows、Linux 及设备不可用时提供密码付款。取消系统认证、认证期间切换账号或切到后台会终止这次认证，界面保留密码入口。系统认证采用 `biometricOnly` 和 `sensitiveTransaction`。Android 主 Activity 使用 `FlutterFragmentActivity`，主题使用 AppCompat，iOS 声明 Face ID 用途。平台要求见 [Android 官方插件说明](https://pub.dev/packages/local_auth_android) 与 [Darwin 官方插件说明](https://pub.dev/packages/local_auth_darwin)。

## 新服务的复用范围

| 能力 | 只发布插件即可调整的部分 | 需要宿主适配的变化 |
| --- | --- | --- |
| 页面与交互 | 卡片、列表、搜索、筛选、底部操作区、商品链接路由、弹层与已提供组件的组合 | 新的原生控件或平台能力 |
| 网络与存储 | 清单中的服务域名、公开 API、具名查询、插件私有存储 | 超出现有凭证类型与请求权限的能力 |
| 原生授权 | 同一 Connect + PKCE 交接协议的初始化、回调、交换、校验、条款地址 | 不同的授权方式、回调数据格式、令牌结构或账号验证协议 |
| 原生订单与付款 | 同一订单协议的创建和恢复路径、商品业务逻辑，复用 LDC 收银台 | 不同的幂等约定、订单响应结构、详情/支付地址等路径约定，或新的支付渠道 |

回归中使用另一个服务的业务域名、授权域名和订单路径，验证原生授权与付款按清单工作。该验证覆盖相同协议的新配置。当前授权协议中的 `ldsp_oauth` 交接字段、订单请求字段与响应结构仍然固定，接入不同协议时需要增加受测的协议适配能力。

`SearchInput(value, hint, onChanged, onSubmitted)` 复用应用 `SearchBar` 和主题。输入事件携带 `value`，搜索图标和键盘搜索触发 `onSubmitted`，清空依次触发空值的 `onChanged` 与 `onSubmitted`。弹层使用公共外壳，手机显示托柄和关闭按钮。收银台使用公共 `PinInput` 与 `M3eSuccessIndicator`，密码输入满六位后仍需明确确认付款。收银台确认付款成功或服务端查单确认已支付后展示成功反馈，待确认状态继续提供原单查询。系统开启减少动态效果时显示静态完成态。

## 原生建单（schema 5）

`auth.checkout` 接受两个不同的固定路径，例如 `{"create":"/orders","lookup":"/order-submissions"}`。它们必须在该服务会话唯一的精确域名下，不能把创建端点同时声明成查询。此协议面向支持“预期金额 + 提交号幂等”的服务。签发方必须单独确认完整的创建、恢复地址以及稳定的买家账号标识和计价单位。没有授权时，`auth.status()` 不返回 `checkoutUnit`。建单和支付是不同权限；这个协议没有扣款方法。

| 脚本调用 | 行为 |
| --- | --- |
| `checkout.status()` | 仅查本机当前服务账号的记录：`idle`、`pending`、`missing`、`created`。不联网。 |
| `checkout.submit({productId,quantity,expectedAmount,couponClaimId?})` | 用户点击后显示宿主原生确认框，逐项核对服务、账号、商品、数量、券、应付金额。取消不提交；确认后先保存意图和唯一提交号，再发 POST。同一账号已有记录时只返回记录。 |
| `checkout.recover()` | 以原提交号发 GET。超时、响应不完整和鉴权失败均不能说明订单不存在。 |
| `checkout.retry()` | 服务明确返回不存在后，用户再次点击并确认，重发原意图和原提交号。脚本不能更改数量、金额或提交号。 |
| `checkout.finish(orderNo)` | 已确认创建且订单号匹配时，清理本地提交记录，可用于成功导航后的归档。仅处理本地记录，调用前须完成结果确认。 |

上表为 `fluxdo.checkout` 的方法。脚本只取得订单号和状态，收银台 URL、凭证和原提交号不会出现在返回值里。订单记录使用系统安全存储；更换服务账号不会串单，同一账号重新取得合法授权后可恢复。更换插件来源和卸载都会清理本机记录。

## 界面描述

rfw 的文本格式，只能 `import fluxdo`（宿主组件库）。数据用 `data.xxx` 读，事件用
`event "名字" { 参数 }` 交给脚本：

```
import fluxdo;

widget Card = Column(
  crossAxisAlignment: "start",
  children: [
    Label(text: "当前积分", style: "labelMedium", color: "onSurfaceVariant"),
    Gap(size: 4),
    Label(text: data.balance, style: "headlineMedium", bold: true),
    Button(
      label: "刷新",
      icon: "refresh",
      variant: "tonal",
      loading: data.loading,
      onPressed: event "refresh" { },
    ),
  ],
);
```

可用组件（详见 `createMetaverseWidgetLibrary`）：

- 布局：`Row` `Column` `Stack` `Padding` `SizedBox` `Expanded` `ListView` `Wrap`
  等 rfw 自带组件（只放行了布局类，`Image` 与 `Container` 被换成宿主版本）。
- `Surface` `Label` `Button` `IconButton` `Symbol` `Image` `ListItem` `Divider`
  `Spinner` `ProgressBar` `Chip` `Gap` `Toggle` `TextInput`。

颜色写主题色名（`primary`、`onSurfaceVariant`、`error`…）或 `0xAARRGGBB`；
文字样式写主题名（`bodyMedium`、`titleMedium`、`headlineMedium`…）。
数值参数 `16` 与 `16.0` 都接受。

`Image` 默认只加载 `permissions.network` 中的 HTTPS 图片。声明
`permissions.publicImages: true` 后，用户可在安装时授权加载其他公网域名的图片。
图片请求携带宿主 User-Agent 和图片 Accept 头，使用独立的匿名客户端。单张下载上限为 16 MiB，解码尺寸限制为 1024 × 1024，加载失败后可点击重试。图片地址须直接返回图片，重定向按请求失败处理。

插件下载、API 与图片请求共用宿主的 DNS 选择。启用加密 DNS 时使用所选解析器，否则使用系统 DNS。直连筛选会拒绝回环、普通私网、链路本地等地址，并保留 `198.18.0.0/15` 和 `2001:2::/48` 中的 Fake-IP 候选，由系统路由送交 VPN。这两个范围只作为已通过域名审核的 DNS 结果使用，URL 中的 IP 字面量仍被拒绝。TLS 始终校验原域名。候选在截取数量上限前交错地址族，IPv6 不可达时可以尝试 IPv4。Dart 应急出口也使用同一解析快照并尝试备用连接。

插件通过 `fluxdo_net_plugin_request_start` 选择出口策略。应用内或系统显式代理收到原域名，由代理解析并选择目标。本地 DNS 失败或没有允许的直连候选时，传入空直连集合，核心仅可经代理访问。代理绕过规则选择直连时会拒绝该请求。客户端能够检查 URL 和本地直连候选，代理远端的地址访问范围由用户配置的代理策略控制。原 `fluxdo_net_pinned_request_start` 按调用方提供的 IP 建连。插件请求使用独立客户端、连接池和会话，旧核心或未启动核心时使用 Dart 直连应急出口。修改核心后需通过项目构建入口更新相应平台的原生库。

## 脚本

全局只有 `fluxdo` 对象，没有 `fetch`、`XMLHttpRequest`、`require`。

```js
// 生命周期：卡片出现、页面打开、页面不再是前台、页面重新可见、界面卸载
fluxdo.on('card.load', (ctx, args) => {});
fluxdo.on('page.open', (ctx, args) => {});
fluxdo.on('page.hide', (ctx, args) => {});
fluxdo.on('page.resume', (ctx, args) => {});
fluxdo.on('surface.close', (ctx, args) => {});

// 界面里 event "refresh" 触发
fluxdo.on('refresh', (ctx, args) => {});

ctx.surface;      // 本次界面实例的 id
ctx.kind;         // 'card' | 'page'
ctx.page;         // 页面 id
ctx.params;       // 链接捕获的参数，以及原始 url
ctx.setData(k, v); // 写入 data.k（界面按 key 读取）
```

页面第一次打开只收到 `page.open`。当页面被其他路由盖住或应用进入后台时收到 `page.hide`，页面再次位于前台时收到一次 `page.resume`。事件参数 `reason` 为 `route` 时表示路由覆盖或普通返回，为 `app` 时表示应用进入或离开后台。被路由覆盖期间进入后台，也会在页面重新可见时收到 `reason: app`。普通返回可保留已加载内容和滚动位置，发生业务变更后再刷新相关数据，隐藏时可收起交付内容。付款结果以支付接口和服务端订单状态为准。早期宿主可能缺少这些可选事件或 `reason` 参数，插件应保留手动刷新入口。

宿主能力：

| 调用 | 说明 |
| --- | --- |
| `fluxdo.fetch(url, {method, headers, body, auth})` | 只允许白名单内的 https；`auth: true` 时由宿主附带凭证。不跟随跳转，3xx 原样返回；`Set-Cookie` 不给脚本 |
| `fluxdo.storage.get/set/remove(key)` | 插件私有键值存储，上限 256KB |
| `fluxdo.auth.status/request/signOut()` | 查询宿主是否持有凭证、手动填写（仅 `token`）、清除本地凭证 |
| `fluxdo.user.get()` | 读取当前用户名，需 `permissions.identity` |
| `fluxdo.navigate(page, params)` | 打开自己声明过的页面 |
| `await fluxdo.prepareNavigation(page)` | 在用户点击时预约一个已声明页面，返回一次性异步函数，调用时传入页面参数 |
| `fluxdo.openUrl(url)` | 交给应用的链接安全策略打开 |
| `fluxdo.toast(message, type)` | 提示，标题里会标明来自哪个插件 |
| `setTimeout/clearTimeout` | 最多 64 个，单个上限 10 分钟 |

`navigate`、`openUrl`、`auth.request` 需要**用户操作**才会生效：脚本在加载时、定时器里
自行发起会被拒绝（`该操作须由用户点击触发`）。一次点击只换一次这类操作。

需要在异步操作完成后打开结果页时，可在点击处理函数中先调用 `prepareNavigation`，再发起原生确认等操作，成功后调用返回的函数。预约绑定发起页面、目标页面和账号，使用一次后失效。新的插件点击、离开发起页面、关闭页面或应用进入后台都会使预约失效。由本次原生操作展示的弹框可临时遮住页面，插件应在 `page.resume` 后执行待处理导航。页面目标及参数由插件决定。旧版宿主缺少此方法，插件可检测方法是否存在并保留手动打开结果页的入口。

## 隔离与限制

- 每个插件的脚本跑在独立 isolate 的 JS 引擎里。脚本死循环不会卡住界面；超过
  5 秒不返回即判定失效，插件被挂起，等你手动恢复。
- 卡在原生循环里的引擎线程无法强制结束（`Isolate.kill` 只在 Dart 代码的安全点生效），
  它会空转到应用退出——所以挂起状态不会自动重试。
- 界面数据一次最多 2 万个节点，超出的 `setData` 被忽略。
- 清单在每次启动时重新校验，站点域名等规则收紧后旧插件会直接失效并被跳过。

## 安装与授权流程

使用网站已有的账号体系时，可声明 `"webLogin": "https://shop.example.org/login"`。用户点击后，`fluxdo.session.login()` 打开该网站的登录页；`fluxdo.session.open('/orders')` 打开同源的受保护页面。两者默认使用应用内置浏览器，保留离站安全检查和用户明确选择系统浏览器的权利。要复用会话，请在同一个浏览器完成登录、查看订单等操作。

这两个调用不返回登录结果或凭证。授权页、回调和账号切换都由网站处理；关闭网页不代表登录成功。卸载插件不等于退出网站账号，网站退出操作也在网站内进行。`webLogin` 不扩大脚本的网络或身份权限，也不需要为 FluxDO 注册回调。

1. 用户在元宇宙页点「添加第三方服务」，填清单地址（使用 HTTPS 域名，通过上文的出口检查）。
2. 宿主下载清单与代码，校验清单、解析界面描述、确认引用的组件都存在。
3. 展示可滚动的权限确认弹层，按用途展示网络域名、接管链接、账号、查询、建单和 LDC 付款。技术端点可展开查看，安装或更新按钮固定在底部，用户确认后才落盘。
4. 用户点开启时，只有 `auth.type = token` 会弹框收集凭证；服务签发的会话不能通过手填建立。
5. 停用即撤销凭证；移除会删除插件的全部本地文件、数据与凭证。

## 相关代码

- `lib/modules/metaverse/core/`：服务接口与链接规则
- `lib/modules/metaverse/plugin/`：清单、安装、存储、网络、宿主桥、脚本运行时、界面
- `lib/modules/metaverse/plugin/runtime/metaverse_plugin_prelude.dart`：注入脚本环境的 SDK
- `lib/modules/metaverse/metaverse_link_router.dart`：帖内链接到插件页面的路由
