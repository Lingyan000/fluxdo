# 脚本 API 参考

当前宿主支持脚本 API 版本 1 和 2。版本 2 使用 schema 9，提供通用凭证、Connect 和支付接口。运行时协议位于 `packages/fluxdo_plugin_runtime`，应用能力由 `MetaversePluginHost` 注入。

## API 2 通用能力

服务插件负责发起授权、处理回调、交换服务凭证、调用业务接口及刷新交付结果。宿主提供 Connect 账号授权、按范围注入凭证、原生 LDC 收银台。每次调用仍须通过安装时批准的权限检查。

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

### `credentials.status(name)`、`credentials.remove(name)`

`status` 返回 `{authorized, expiresAt}`，过期时间为 Unix 秒或 null。有效性包含当前应用账号绑定和过期检查。`remove` 返回 null，移除该具名凭证，并取消正在保存或使用旧版本凭证的调用。清空插件数据也会移除全部凭证。

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

用户点击后调用公共 Linux DO Connect，使用当前应用账号完成授权。返回服务回调 URL，取消返回 null。宿主检查授权地址、redirect_uri、回调地址和 state。插件随后请求回调并处理服务协议。服务初始化接口、PKCE 关联和凭证交换由插件实现。

### `crypto.pkce()`、`crypto.uuid()`

`pkce` 返回 `{verifier, challenge, method: 'S256'}`，使用安全随机数和 SHA-256。`uuid` 返回安全随机 UUID v4。适合授权关联与业务幂等提交号。

### `payments.request({provider, url, reference, amount})`

用户点击后打开应用原生收银台。当前 provider 为 `linuxDoCredit`，url 使用 LDC 收银台地址，reference 是服务订单号，amount 推荐传十进制金额字符串。宿主核对 LDC 返回的订单号、付款账号和金额，付款确认使用 LDC 交易 ID 校验收款账号、金额及状态。支付密码和生物识别由应用管理。

返回收银台结果 `{state: 'paid'}`，已提交但尚未确认时返回 `{state: 'pending'}`，提交前关闭返回 null。付款成功后，插件刷新自己的订单与交付接口。测试和应用内开发中心使用模拟桥。

API 2 的 `user.get()` 返回当前账号的 `{id, username}`，需要 identity 权限。通用网络、存储、界面与导航接口沿用下文签名。下文 `auth.*` 和 `checkout.*` 为 API 1 迁移期接口。

## 环境与结果

脚本可使用 JS 内置对象、`Promise`、`console`、`setTimeout`、`clearTimeout`、`fluxdo`。界面由 rfw 声明。模块代码需要在发布前打包进 `main.js`，运行时没有提供 Node 模块加载接口。

除事件注册外，`fluxdo` 方法返回 Promise。宿主拒绝调用或发生网络错误时 Promise reject，JS 接收到 `Error`。业务 HTTP 错误通常仍返回响应对象，由插件检查 `status` 或 `ok`。当前错误信息包含中文描述和部分稳定代码，业务逻辑优先使用响应状态或明确的返回字段。

以下签名使用类型说明便于阅读，运行时仍执行 JavaScript。

## 事件与上下文

### `fluxdo.on(name, handler)`

注册 `(ctx, args) => void | Promise<void>`。同名事件再次注册会替换之前的处理函数。返回 `undefined`。处理函数抛错或返回 rejected Promise 时，运行时向日志桥报告错误。

| 事件 | 触发时机 | 参数 |
| --- | --- | --- |
| `card.load` | 卡片实例创建 | 对象，可为空 |
| `page.open` | 页面实例首次打开 | 对象，可为空 |
| `page.hide` | 页面被路由覆盖或应用进入后台 | `reason` 为 `route` 或 `app` |
| `page.resume` | 页面恢复前台可见 | `reason` 为 `route` 或 `app` |
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

## 网络

### `fluxdo.fetch(url, options?)`

| 参数 | 类型 | 默认与说明 |
| --- | --- | --- |
| `url` | string | HTTPS 服务 URL，须通过清单网络范围校验 |
| `options.method` | string | 默认 `GET`，支持 `GET`、`POST`、`PUT`、`PATCH`、`DELETE` |
| `options.headers` | object | 默认空对象，Cookie 等受限头由宿主检查 |
| `options.body` | JSON 值或 string | 对象自动 JSON 编码并补充 Content-Type，最大 256 KiB |
| `options.auth` | boolean | 默认 false，true 时由宿主附带该插件的凭证 |

返回 `{ status, headers, body, ok, json() }`。`body` 为字符串，`json()` 同步解析并可能抛出异常，`ok` 表示 HTTP 2xx。响应最大 1 MiB。重定向原样返回，插件需要对目标再次发起受检查请求。Set-Cookie 等敏感响应头被过滤。

`readSession` 的带凭证请求当前仅允许无请求体、无自定义头的 GET。普通 token 模式按其清单配置附带凭证。公开请求也会经过目标、方法和请求头检查。

图片通过宿主 `Image` 组件加载，使用专用匿名请求。脚本 `fetch` 返回文本响应。

### `fluxdo.auth.query(name, args)`

向 `auth.queries[name]` 声明的端点提交 JSON POST。`args` 须为对象，体积不超过 256 KiB。要求存在有效服务会话，且会话已授权该查询地址。

返回 `{ status, body, ok, json() }`。该接口是现有 `readSession` 协议的补充能力。

## 插件数据

| 方法 | 参数与结果 | 行为 |
| --- | --- | --- |
| `fluxdo.storage.get(key)` | string → Promise<JSON 值或 null> | 缺失键返回 null |
| `fluxdo.storage.set(key, value)` | string、JSON 值 → Promise<null> | 保存普通数据，null/undefined 按删除处理 |
| `fluxdo.storage.remove(key)` | string → Promise<null> | 删除该键 |

键长度为 1–128，每个插件编码后的数据总量最多 256 KiB。卡片与所有页面共享数据。数据保存在插件目录下的 `storage.json`。每个插件的写入按队列串行执行，多个键的并发写入保留各自结果。账号变化不会自动分隔这些普通键值。

用户可从插件管理重置本地数据和服务会话。重置会停止实例，拒绝旧代次排队写入，并等待正在写入的数据落盘后清理。脚本存储 API 为表中的三个方法。

## 账号与登录

| 方法 | 结果 | 条件与语义 |
| --- | --- | --- |
| `fluxdo.auth.status()` | Promise<object> | 返回下表状态，查询本地授权 |
| `fluxdo.auth.request()` | Promise<boolean> | 用户点击触发。token 模式收集凭证，配置 Connect 的服务执行现有原生登录流程，取消返回 false |
| `fluxdo.auth.signOut()` | Promise<void> | 删除本插件在宿主保存的 token 与服务会话 |
| `fluxdo.user.get()` | Promise<{username: string} 或 null> | 需要 `permissions.identity`，读取当前论坛用户名 |

`auth.status()` 返回字段如下。

| 字段 | 含义 |
| --- | --- |
| `required` | 当前清单是否为需手填凭证的 token 模式 |
| `nativeSupported` | 是否配置 `auth.connect` |
| `paymentSupported` | 是否声明支付能力 |
| `authorized` | 是否存在符合当前账号绑定的本地凭证 |
| `queries` | 当前服务会话允许的具名查询列表 |
| `checkoutUnit` | 已取得有效建单授权时的计价单位，可缺省 |

`authorized` 是本地检查结果，服务端仍可能撤销会话。当前 `auth.signOut()` 执行本地删除。服务端退出或授权撤销需对应服务协议支持。

## 页面与外部链接

| 方法 | 参数与结果 | 行为 |
| --- | --- | --- |
| `fluxdo.navigate(page, params?)` | string、object → Promise<null> | 打开清单声明的页面，Promise 在发起导航后完成 |
| `fluxdo.prepareNavigation(page)` | string → Promise<function(params)> | 用户点击时预约一次目标页面，返回可用于异步完成后的导航函数 |
| `fluxdo.openUrl(url)` | string → Promise<null> | 通过应用链接策略打开 HTTP(S) 地址 |
| `fluxdo.session.login()` | Promise<null> | 打开清单的 `webLogin` 地址 |
| `fluxdo.session.open(path)` | string → Promise<null> | 打开 `webLogin` 同源的绝对路径，例如 `/orders` |
| `fluxdo.toast(message, type?)` | string、string → Promise<null> | 存在可见界面时显示带插件身份的提示，默认 info |

普通导航、授权和网页入口需要用户操作后的 10 秒内调用，一次点击可消耗一次普通界面操作。同一时间只允许一个正在执行的界面操作。Toast 最短间隔一秒，消息最多 200 字符，具体提示样式由宿主 delegate 决定。

预约绑定目标页面、原始 surface 和账号，成功使用后失效。新的插件点击、离开原页面、关闭页面或应用进入后台使预约失效。本次原生确认框可临时覆盖页面，待 `page.resume` 后调用预约函数。预约可跨越普通点击的 10 秒窗口。`prepareNavigation` 自 `8679b7ab` 提供，使用前检查方法是否存在。

网页会话在浏览器中管理。网页入口的 Promise 不携带登录结果，插件应通过服务协议确认登录状态。

## 当前订单与支付协议

以下 7 个方法属于现有宿主业务适配。它们要求 `readSession` 及相应清单和服务会话授权，适用于当前支持的订单协议。

| 方法 | 参数与结果 | 行为 |
| --- | --- | --- |
| `fluxdo.checkout.status()` | Promise<Submission> | 查询本机当前服务账号的提交记录 |
| `fluxdo.checkout.submit(intent)` | Promise<Submission> | 用户点击并原生确认后保存提交号，再创建订单 |
| `fluxdo.checkout.recover()` | Promise<Submission> | 使用原提交号查询提交结果 |
| `fluxdo.checkout.retry()` | Promise<Submission> | 服务确认不存在后，由用户重新确认并以原参数、原提交号重试 |
| `fluxdo.checkout.finish(orderNo)` | string → Promise<null> | 清理已确认创建且订单号匹配的本地提交记录，可用于成功导航后的归档 |
| `fluxdo.checkout.pay(orderNo)` | string → Promise<object 或 null> | 用户点击后打开应用级 LDC 收银台，返回结果见下文 |
| `fluxdo.checkout.cancel(orderNo)` | string → Promise<object 或 null> | 用户点击后通过现有业务适配确认取消订单 |

`intent` 包含 `productId: string`、`quantity: int`、`expectedAmount: number`，可选 `couponClaimId: string`。数量范围为 1–5000，金额为 0–1,000,000,000 的有限数值，最多两位小数。商品、订单和券 ID 使用 1–128 个英文字母、数字、下划线或连字符。

`Submission.state` 为 `idle`、`pending`、`missing`、`created` 或 `rejected`。有记录时包含原始意图，创建成功后含 `orderNo`，鉴权失败可含 `issue: authorization`。取消首次确认可返回 idle，取消重试保留之前记录。pending 表示结果尚待查询。原提交号由宿主管理。

当前支付收银台关闭时，已确认支付返回 `{state: 'paid'}`，已提交且结果待查返回 `{state: 'pending'}`，付款前关闭或授权取消返回 null。取消订单经确认并成功提交后返回 `{state: 'cancelled'}`，用户取消确认返回 null。调用失败可 reject。插件使用结果刷新服务端订单，交付内容以服务端订单详情为准。金额、收款方、付款账号和密码验证属于应用收银台。支付结果不明确时回查同一订单。

新服务接入应先核对 [现有协议与复用限制](../metaverse-plugin.md)。通用会话与支付能力的拆分方案见 [架构审计](architecture-review.md)。

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

日志写入应用的结构化日志，包含 `pluginId`、`pluginVersion`、`runtimeId` 和 `emitter`。事件里的 `ctx.api` 调用同时关联 `surfaceId` 与调用链。插件设置的日志页面支持按等级、类型、框架或插件来源筛选，以及当前插件的导出和清空。日志正文有长度限制，每个运行实例每分钟最多记录 120 条 console 日志。调试时记录事件和错误码，授权材料与支付信息通过宿主的专用能力处理。网络核心异步日志的完整调用归属仍待补齐。

每个运行时最多 64 个计时器，延时最大 10 分钟，负值按 0 处理。计时器超额时当前桥会忽略设置请求。并发宿主调用最多 32 个，surface 最多 16 个。最后一块界面关闭后，宿主默认 30 秒释放运行实例。单条引擎指令默认 5 秒看门狗，具体资源隔离局限见架构审计。

## 界面调用归属

事件处理器提供 `ctx.api`，其方法与 `fluxdo` 的调用方法相同。使用 `ctx.api.fetch`、`ctx.api.storage` 等会将界面身份带入调用日志。界面关闭后其绑定调用会被拒绝。
