# 元宇宙动态插件框架需求：以 LD士多为验证场景

调研日期：2026-11-11。本文可直接提供给框架开发者作为需求输入。

**当前交付状态（1.4.0）：** 已实现独立安装、原生物品广场、帖子商品详情弹层和兑换预览。原生报价、选券、确认建单、重启后恢复提交结果，以及买家订单详情都已接到客户端并用离线服务验证。未实现生产账号的无浏览器签发和买家原生付款；未向线上下单。网页入口使用士多已有的 Linux DO 回调，完成网页登录不会为原生页面建立会话。源码与安装说明见 [LD士多插件](../plugins/ld-store/README.md)。

## 1. 目标与职责边界

1.4.0 根据已发布的[订单客户端](https://ldcstore.com/assets/orderService-BWIG3D2m.js)与[兑换页面](https://ldcstore.com/assets/OrderConfirm-Ddlp9QJm.js)核对了预期金额与 `ord_` 提交号。宿主的通用订单协议负责授权端点、原生逐笔确认和持久化；插件决定何时展示报价、建单、恢复和进入详情。服务器返回“已建单”并不意味着“已付款”。不开放通用带凭证的 POST。

1.3.1 返回行为：官网的[支付窗口通信脚本](https://ldcstore.com/assets/paymentReturn-myEY8fdn.js)区分窗口关闭与结果通知。插件既不以窗口关闭为支付成功，也不从页面恢复事件推断付款。回到原生订单页时，只读该买家的订单；回到兑换页时重新读取当前商品，重新限制数量，丢弃旧报价；用户主动查价才发报价请求。

1.3.0：原生兑换页处理平台数量上限、无限库存和账号剩余额度，具备正式报价与选券的客户端流程。仅当宿主持有单独授权的 `/api/shop/orders/quote` 查询时发送报价；普通服务读会话仍不能发 POST，匿名用户只看预估。上游依据：[数量规则](https://github.com/caigg188/LDStatusPro/blob/main/ld-store/src/utils/checkoutQuantity.js)、[报价服务](https://github.com/caigg188/LDStatusPro/blob/main/ld-store/src/services/shop/couponService.ts)、[结算界面](https://github.com/caigg188/LDStatusPro/blob/main/ld-store/src/views/OrderConfirm.vue)。模拟验证不等于真实账号已取得授权，签发、建单和支付确认仍待接入。

1.2.0 增量：原生买家订单列表、筛选、分页和详情已接入官方 GET 结构；已交付订单可手动展开服务端返回的交付内容。端到端验证使用本地模拟签发的会话和固定订单，覆盖缺少会话、失效与交付内容清除，没有访问线上买家数据。生产原生签发、正式报价、下单与支付仍未打通。接口依据：[订单服务](https://github.com/caigg188/LDStatusPro/blob/main/ld-store/src/services/shop/orderService.ts)、[详情与交付字段](https://github.com/caigg188/LDStatusPro/blob/main/ld-store/src/views/OrderDetail.vue)。

2026-11-12 更新（插件 1.1.0）：原生页面已增加兑换预览（库存、限购、数量、未计优惠的小计）；不调用受保护的报价或下单接口，不把本地小计当成服务端应付金额。公开读取可在只有 IPv6 候选且建连超时后，手动对失败域名启用加密 DNS 并再次读取。登录、付款、我的订单仍由官网承载，不能验收为原生闭环。

要继续原生买家流程，需分别确认两项对客户端可用的契约：

1. 士多认可的原生授权交接：如何绑定用户同意、回传一次性 code、指定合法 origin 并换取仅适用于士多的会话。现有官方网页方案见[士多授权说明](https://github.com/caigg188/LDStatusPro/blob/main/ld-store/docs/auth-session.md)。不要求照搬某种回调登记方式，也不能把论坛或 LDC 的登录态直接当作士多授权。
2. 支付方认可的买家确认方式：提供客户端可调用的支付意图、用户确认或取消、超时查单及回执验证方式。已公开的 [LDC 商户接口](https://credit.linux.do/docs/api) 和[士多订单接口](https://github.com/caigg188/LDStatusPro/blob/main/ld-store/src/services/shop/orderService.ts)能取得收银台地址或查询状态，并不能据此推断可在第三方客户端直接扣用户积分。验收使用隔离测试环境或模拟服务，不向线上发起创建订单、取消订单、支付或兑换。

请基于当前元宇宙插件框架继续开发。目标是让第三方作者能独立发布插件，用户安装后获得原生界面、链接接管、登录授权和服务交互能力。

**不要只继续抽取 LDC/CDK 公共逻辑，也不要把 LD士多的页面和接口实现写进宿主 Dart 代码。**

用 LD士多验证下面的完整场景：

```text
通过地址安装插件
→ 元宇宙出现服务卡片
→ 进入插件自己的物品广场
→ 浏览、搜索、筛选商品
→ 点击商品打开详情

点击帖子中的 LD士多商品链接
→ 由插件规则接管
→ 弹层打开插件商品详情
→ 登录授权
→ 确认订单
→ 打开支付页面
→ 返回后查询订单与交付结果
```

| 宿主框架负责 | 独立插件负责 |
| --- | --- |
| 插件安装、加载、生命周期与权限 | LD士多接口地址、参数与数据适配 |
| 通用组件库、页面和弹层容器 | 广场、商品详情、确认订单和订单列表 |
| 链接规则匹配、参数传递 | 声明接管哪些 LD士多链接 |
| 受控网络、图片、存储 | 搜索、筛选、分页、报价与下单逻辑 |
| 浏览器授权交接、安全凭证存储 | 声明所需授权配置，调用宿主能力 |
| 浏览器返回通知、页面恢复事件 | 查询订单并更新业务状态 |

新增服务、修改插件页面和业务逻辑，不应要求修改宿主或重新编译客户端。新增底层通用能力需要更新宿主是可以接受的，但必须明确协议版本和兼容边界。

## 2. 调研范围与证据

- 站点：[LD士多](https://ldcstore.com/)。
- 官方帮助：[购买物品与查看订单](https://ldcstore.com/docs/buy-guide)。
- 官方前端：[caigg188/LDStatusPro — ld-store](https://github.com/caigg188/LDStatusPro/tree/main/ld-store)。
- 已在线匿名验证：商品分类、分页商品列表、商品详情返回 JSON。
- 已通过官方前端源码确认：登录交接、报价、订单、支付地址、优惠券等接口。
- 未完成：真实登录授权、认证后的业务请求、真实订单和支付验证。

以下接口是站点前端使用的业务接口，尚未确认存在承诺兼容性的第三方开放 API。实现时重新核对当前源码，不把前端实现当作永久合同。

## 3. LD士多接口

### 3.1 服务地址与通用约定

当前源码默认地址：

| 服务 | 地址 |
| --- | --- |
| 商城业务 API | `https://api2.ldspro.qzz.io` |
| 登录认证 API | `https://api1.ldspro.qzz.io` |
| 图片服务 API | `https://api.ldspro.qzz.io` |

普通业务接口的登录凭证使用：

```http
Authorization: Bearer <JWT>
```

商品浏览接口可匿名调用，登录后可能返回与用户相关的内容或权限信息。不能把匿名结果当作全站完整商品集合。

参考：[请求封装与默认地址](https://github.com/caigg188/LDStatusPro/blob/main/ld-store/src/utils/api.ts)。

### 3.2 商品浏览与链接

以下三个接口已经在线匿名验证：

| 方法 | 路径 | 主要返回 |
| --- | --- | --- |
| GET | `/api/shop/categories` | `data.categories` |
| GET | `/api/shop/products` | `data.products`、`data.pagination` |
| GET | `/api/shop/products/{id}` | `data.product` |

商品列表支持：

| 参数 | 用途 |
| --- | --- |
| `page`、`pageSize` | 分页 |
| `categoryId` | 分类 |
| `search` | 关键词 |
| `inStock=true` | 仅有库存 |
| `priceMin`、`priceMax` | 价格区间 |
| `sortBy`、`sortOrder` | 排序 |
| `ranking`、`cursor` 等 | 推荐排序与游标分页，具体组合以源码为准 |

例如：

```text
GET https://api2.ldspro.qzz.io/api/shop/products?page=1&pageSize=20&categoryId=2
```

源码中的排序映射：

| 排序 | 参数 |
| --- | --- |
| 最新上架 | `sortBy=created_at&sortOrder=DESC` |
| 价格最低 | `sortBy=final_price&sortOrder=ASC` |
| 价格最高 | `sortBy=final_price&sortOrder=DESC` |
| 销量优先 | `sortBy=sold_count&sortOrder=DESC` |

商品返回字段包含名称、描述、图片、价格、折扣、库存、销量、卖家、购买限制与交付方式。列表、详情之间的字段不完全一致，适配应放在插件内。

商品链接格式：

```text
https://ldcstore.com/product/{id}
```

历史商品 ID 是数字，新商品可能是 UUID，必须作为不透明标识原样传递，不能统一转为整数。插件规则 `/product/:id` 应覆盖两者。

参考：[商品接口](https://github.com/caigg188/LDStatusPro/blob/main/ld-store/src/services/shop/catalogService.ts)、[资源编号约定](https://github.com/caigg188/LDStatusPro/blob/main/ld-store/docs/public-resource-ids.md)。

### 3.3 登录授权

以下流程按官方源码确认，尚未完成真实授权验证。它并非让用户在网站生成 API Key 再手填。

1. 客户端生成 PKCE verifier 和 S256 challenge。
2. 向登录认证 API 请求：

   ```text
   GET /api/auth/init
       ?site=linux.do
       &return_url=…
       &code_challenge=…
   ```

3. 保存本次流程的 state/verifier，打开返回的 `auth_url`。
4. 用户完成授权，回跳交接数据携带一次性 code 和 state。交接数据的编码、解析及校验以官方回调实现为准。
5. 向商城业务 API 请求：

   ```http
   POST /api/shop/auth/exchange
   Content-Type: application/json
   ```

   ```json
   {
     "code": "一次性授权码",
     "state": "本次授权状态",
     "verifier": "本次PKCE verifier",
     "origin": "受服务端认可的来源"
   }
   ```

6. 得到候选 JWT 后，携带 Bearer 凭证调用 `GET /api/shop/auth/verify`。
7. 验证成功才建立登录态。

必须核实服务端对 `return_url` 和 `origin` 的限制，确定客户端可使用的接入方式。不能假定任意自定义协议、localhost 或客户端来源都被允许，也不要伪造来源绕过校验。

官方已采用 PKCE 与短时一次性授权码交接。不要恢复从回跳 URL 提取长期 JWT 的旧方案，也不要把现有 LDC/CDK 凭证直接用于士多。

**原生登录验收口径：** 已登录论坛的用户点击「授权士多」，在 FluxDO 原生确认框查看服务和授权范围；点同意后由宿主得到士多签发、可由士多验证的本次会话。点取消不签发会话，整个流程不打开浏览器（包括内置 WebView）。当前的 `webLogin` 不满足此项。需要士多提供允许客户端使用的一次性授权交接方式，说明谁签发与接收授权码、如何绑定本次请求和用户同意、如何校验及撤销会话。仅登记网页回调不能证明支持无浏览器流程。

参考：[登录入口](https://github.com/caigg188/LDStatusPro/blob/main/ld-store/src/views/Login.vue)、[回调处理](https://github.com/caigg188/LDStatusPro/blob/main/ld-store/src/views/AuthCallback.vue)、[授权交接说明](https://github.com/caigg188/LDStatusPro/blob/main/ld-store/docs/auth-session.md)。

### 3.4 报价、订单、优惠券与支付

以下接口在官方前端源码确认，未执行真实交易，均需要登录：

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| POST | `/api/shop/orders/quote` | 获取报价和优惠券信息 |
| POST | `/api/shop/orders` | 创建订单 |
| GET | `/api/shop/order-submissions/{token}` | 查询一次下单提交的结果 |
| GET | `/api/shop/orders?role=buyer` | 买家订单列表 |
| GET | `/api/shop/orders/{orderNo}?role=buyer` | 订单详情 |
| GET | `/api/shop/orders/{orderNo}/payment-url` | 获取支付地址 |
| POST | `/api/shop/orders/{orderNo}/refresh` | 刷新支付状态 |
| POST | `/api/shop/orders/{orderNo}/cancel` | 取消订单 |
| GET | `/api/shop/my-coupons` | 我的优惠券 |

报价请求：

```json
{
  "productId": "商品ID",
  "quantity": 1
}
```

报价响应主要字段包括 `productId`、`quantity`、`payableAmount`、`coupons`。

创建订单参数示例：

```json
{
  "productId": "商品ID",
  "quantity": 1,
  "submissionToken": "本次下单幂等标识",
  "expectedAmount": 50,
  "couponClaimId": "可选优惠券ID"
}
```

上面的中文字符串只是字段说明，不能作为实际请求值。无优惠券时省略 `couponClaimId`；幂等标识需使用符合官方约定的安全随机值。

创建结果包含 `orderNo`、`orderId`，以及可能存在的 `paymentUrl`、`paymentState`、到期和重试相关字段。

订单列表主要返回 `orders` 与 `pagination`；详情主要返回 `order`，可能附带 `logs`。交付内容的具体字段与可见条件需在实现时继续核对，不臆造独立的“领取卡密”接口。

必须遵循官方的幂等与恢复语义：下单超时不代表失败，应先用原 `submissionToken` 查单，不能直接生成新标识重新下单。重试应保留原购买意图；金额或库存变化需要重新确认。

支付返回仅作为查询订单的触发信号，最终结果以服务端订单状态为准。

参考：[订单接口](https://github.com/caigg188/LDStatusPro/blob/main/ld-store/src/services/shop/orderService.ts)、[报价与优惠券](https://github.com/caigg188/LDStatusPro/blob/main/ld-store/src/services/shop/couponService.ts)、[下单恢复](https://github.com/caigg188/LDStatusPro/blob/main/ld-store/src/composables/orders/useCheckoutSubmission.ts)、[响应结构](https://github.com/caigg188/LDStatusPro/blob/main/ld-store/src/contracts/commerce.ts)、[支付返回处理](https://github.com/caigg188/LDStatusPro/blob/main/ld-store/src/utils/paymentReturn.js)。

## 4. 独立插件需要实现的界面

以下页面用于检验框架是否够用，不要实现成宿主内置页面。

| 界面 | 必需内容与交互 |
| --- | --- |
| 元宇宙服务卡片 | 服务名称、登录状态、明确的“进入物品广场”入口 |
| 物品广场 | 分类、商品图片、名称、价格、库存、搜索、排序、筛选、分页、刷新 |
| 商品详情 | 图片、描述、卖家、价格、库存、购买条件、交付方式、购买按钮 |
| 确认订单 | 数量、报价、优惠券、应付金额、明确确认操作、防重复提交、结果恢复 |
| 我的订单 | 分页、状态筛选、进入订单详情 |
| 订单详情 | 支付状态、继续支付、刷新、可用时取消、交付内容与异常提示 |

各页面需要有加载、空数据、网络错误、登录过期等状态。商品详情还应处理商品下架、库存不足和购买条件不满足。

商品描述可能包含格式与链接，需要明确支持范围和安全渲染方式；不要求复刻网站全部样式。

登录授权由宿主流程承载，插件按需显示登录入口和状态。授权成功保留原商品、页面和用户选择，但不自动替用户下单或支付。

第一阶段不做卖家后台、发布商品、求购广场、私聊和完整售后系统。

## 5. 框架需要补齐的通用能力

### 5.1 动态页面与组件

检查现有组件及事件是否足够支持上述界面，缺失部分补成通用组件或 SDK：

- 列表、网格、输入、筛选、数量选择。
- 刷新与分页；先支持明确的“加载更多”也可以。
- 页面参数、数据更新、事件回传。
- 页面打开、关闭、重新可见、应用恢复等生命周期。
- 窄屏与桌面布局约束，避免宿主固定滚动容器限制插件页面。
- 错误、空数据和加载状态，以及需要时展示格式化描述的能力。

不要新增 `LdStoreProductCard` 等业务组件代替通用能力。插件应能自行组合已有组件形成新页面，并明确当前不支持任意 Dart Widget、原生扩展或 Canvas 绘制的边界。

### 5.2 内容链接点击后弹层打开

明确需求：**点击帖子里的 LD士多商品链接，应能直接在弹层打开插件提供的商品详情，而不是只能整页跳转或打开网站。**

框架需要：

- 允许插件声明链接对应的页面、参数和展示方式。
- 同一详情页支持普通页面和弹层两种承载，不重复编写业务 UI。
- 提供通用自适应弹层；手机底部弹层、桌面居中弹框可作为待维护者确认的展示方案。
- 正确处理滚动、关闭、返回、内部导航、键盘和异步加载。
- 关闭弹层后保留帖子位置。
- 插件停用、未安装或规则未匹配时，回到现有链接处理逻辑；加载异常时保留可理解的退路。
- 不在链接分发器中硬编码 LD士多域名与商品路径。

清单字段如何命名由框架开发者设计，但必须提供实际可用示例。涉及具体视觉方案时先按项目约定确认，不在重构中顺带修改已有页面样式。

### 5.3 通用授权交接

在现有手填 token 之外，提供宿主代办的浏览器授权能力：

- PKCE、安全随机数、state 绑定及校验。
- 授权回调捕获、取消、超时和错误处理。
- 授权码兑换与身份验证。
- 凭证安全保存及受限域名代发。
- 登录失效、退出、账号切换处理。
- 授权成功后通知插件更新状态，保留原商品和页面上下文。

长期 JWT、verifier 等敏感信息由宿主管理，不直接暴露给插件脚本。插件提供声明式配置，具体支持的协议范围必须明确，不能声称支持任意授权方式。

若真实回调与来源限制尚未确认，记录为外部接入待验证项，不能以模拟授权成功替代真实验证。

### 5.4 支付承载与恢复

提供通用浏览器会话及返回事件，插件利用这些事件查单：

- 打开支付 URL。
- 区分返回、关闭、取消和超时。
- 支持应用恢复后通知插件。
- 保留订单号和待恢复状态。
- 页面销毁、插件停用后结束相关监听和轮询。
- 支付返回不能直接被当作支付成功。

报价、下单、查单属于插件业务逻辑，不要求在宿主增加 LD士多订单 API。设计时评估 Android、iOS、macOS、Windows、Linux 五个平台的浏览器与返回机制，明确差异和退路。

### 5.5 图片与权限

实际商品图片可能来自：

- `ldimg.ldcstore.com`。
- 卖家自己的外部图床。
- 头像 CDN。

不能只加入几个观察到的域名就宣称支持完成，也不能直接全面放开任意网络访问。

给出并实现适合动态插件的图片权限方案，明确图片加载与脚本联网权限的关系，以及重定向、私网地址、超大图片和加载失败的处理。不要为 LD士多手写一份持续维护的图片域名列表作为最终方案。

### 5.6 插件开发与运行边界

- 提供清单 schema、SDK、组件参数、生命周期和错误处理文档。
- 声明最低宿主能力或协议版本；不兼容时明确提示。
- 提供定位脚本、UI 和网络错误的方法，日志不能泄露凭证。
- 说明 UI 自定义范围、资源限制和运行隔离限制。
- 评估现有死循环无法可靠终止、内存缺乏硬限制的问题，如实记录，不能把隔离描述成已完全解决。
- 正确清理停用、卸载、更新和登出后的运行实例及敏感状态。

自动更新、插件市场和签名分发体系不作为本轮主要目标；不要以继续扩展这些外围能力代替核心页面、授权和弹层验证。

## 6. 交付内容与验收

### 6.1 交付内容

1. 通用框架实现。
2. 更新后的插件协议、SDK、组件和生命周期文档。
3. 一个与宿主业务代码分离的参考插件包。
4. 相关测试与真实接入的未验证项清单。

参考插件可以先使用明确标注的模拟接口验证框架，但不能把模拟验证称为 LD士多生产接入完成。独立插件包应采用与第三方安装相同的协议，不通过测试专用 Dart 业务页面绕开框架。

### 6.2 核心验收标准

- 客户端编译后，从地址安装参考插件即可显示卡片和页面。
- 修改远端插件的布局或业务逻辑，重新安装或更新后生效，宿主无需重新编译。
- 插件的广场、详情、订单页面定义均位于插件包。
- 帖子商品链接能提取数字或 UUID ID，并弹层打开插件详情。
- 弹层关闭不丢失帖子位置，插件内部导航及返回行为正确。
- 登录、浏览器返回与页面恢复有可测试的通用协议。
- 覆盖重复下单、结果未知、授权取消、登录过期、弹层关闭、插件停用等关键场景。
- 安装、存储、加载和渲染链路至少有一项贯通验证，不能只直接实例化页面组件作为动态安装验收。
- 分别列出“模拟验证通过”“真实接口只读验证通过”“真实授权验证通过”“真实交易未验证”，不要混在一起。
- 真实交易需要用户明确授权，不为验收自动创建订单或支付。

### 6.3 项目验证要求

遵守项目 AGENTS.md，运行覆盖改动的相关测试和 `flutter analyze`；提交前运行 `flutter test test/architecture`。不要默认做完整构建，不带入工作区中其他人的并行改动。

## 7. 开始开发前先给出的判断

先对照当前代码列出“已有、缺失、需要调整”的能力，再按上述场景补齐。

如果 LD士多真实接口或回调策略构成限制，应指出具体限制、证据及可行接入方式，不虚构接口，不把框架能力不足和第三方服务限制混为一谈。

**最终要证明独立动态插件能完成这些交互，而不是只证明服务接口抽象得更统一。**
