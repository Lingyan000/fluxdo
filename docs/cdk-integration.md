# CDK 原生领取

CDK 是有独立业务会话的分发服务。原生界面复用 CDK Connect 登录、应用网络与 Cookie 管理；项目、领取、交付查询位于 `lib/modules/cdk`，不放入通用插件引擎。LDC 收银台由应用与插件共用，CDK 负责自己的建单和交付。

## 领取与支付

论坛登录与 CDK 共用 `showCaptchaSheet` 和 `CaptchaPanel`。手机在底部验证，宽屏在居中的面板验证。公共组件根据调用方提供的状态显示提示和题目。论坛登录自行管理勾选和二步验证。CDK 在确认项目后按官网配置启动 invisible 验证，并检查当前项目和会话。

项目列表按服务端资格过滤，列表的 `total_items` 是总量，不能当作剩余库存。详情中的 `available_items_count` 才表示当前剩余。资格包括信任等级、评分、时间、库存、IP 限制和抽奖获奖身份，最终以服务端校验为准。CDK `score` 是资格评分，并非消费余额，不能和 LDC 金额互换。

用户在原生领取面板确认项目和金额后，应用在 CDK 原站页面运行官网配置的 hCaptcha。确认、加载、取消、错误与重试共用同一个面板；验证采用官网的 invisible 模式，只有服务端要求做题时才显示内嵌挑战。验证层从站点已有的 hCaptcha iframe 读取公开 sitekey，使用独立 widget 的 `render/execute` 和回调，不固化部署配置，不触发网页领取按钮，也不绕过官网前端的验证中间件。令牌只用于一次原生领取请求。

加载阶段有 45 秒上限，开始做题后由 hCaptcha 管理挑战过期。关闭、过期、切后台和重新验证都会废弃旧尝试，旧回调不能提交领取或关闭后续页面。账号变化时移除验证内容。主框架导航与原生回调仅接受当前项目的 HTTPS 原站地址；加载失败可原地重试，或显式打开 CDK 网站处理登录。挑战内部交互和证书验证保持原平台行为。

验证码题目需要服务商的网页运行环境。复用应用的跨平台 WebView 可保持官网 origin、业务 Cookie 和现有证书/代理配置，同时让领取与支付主体保持 Flutter 原生界面。移动端独立 SDK 不能替代 CDK 的网站会话和原站配置，也不能覆盖全部桌面平台；因此没有为同一验证引入多套 SDK。实现依据包括 [hCaptcha invisible 接入](https://docs.hcaptcha.com/invisible)、[公开回调协议](https://docs.hcaptcha.com/configuration)和[内嵌 WebView 支持](https://docs.hcaptcha.com/mobile_app_sdks)。

免费项目直接返回 `itemContent`。付费项目返回签名的 `pay_url`、`out_trade_no` 和 `amount`；原生收银台独立查询 LDC 订单，核对订单号、金额和付款账号后才允许确认付款。支持 LDC 的 `/epay/pay/submit.php` 与已有商户使用的 `/epay/submit.php`。不在客户端签名，也不要求买家保存卖家的 Client Secret。

已存在的待付款订单通过项目的 `pending-payment` 查询恢复。这个读取不会再次预留库存或延长订单有效期，库存为零也可继续支付已有订单。不能用重新调用领取接口实现继续支付。

支付提交和 CDK 交付分别确认。CDK 服务端收到 LDC 异步通知后发放内容；客户端只以项目 `is_received` 或明确的领取响应决定是否展示内容。付款后在页面可见时最多查询约 30 秒，隐藏或退后台停止，仍未到账时保留查询入口。LDC 回调或服务端退款由服务端处理，客户端不能伪造成功或主动调用商户通知接口。

领取与支付均禁止自动重放。领取发生网络或响应格式错误时，查询原项目与待付款状态；未知结果不会直接提供重复提交。用户关闭收银台不会撤销 CDK 已预留的库存，过期释放遵从服务端。

## 数据与边界

原生入口包括项目发现与标签筛选、领取详情、历史领取与搜索、个人领取趋势、CDK 平台总览。个人数据和平台统计分开展示，统计缓存尚未生成时显示空态。项目描述按文字显示，兑换内容默认遮蔽，复制由用户发起，切后台后重新遮蔽；内容不写入磁盘缓存和请求体日志。

已开启 CDK 服务时，卡片进入原生页面，帖子中的 `cdk.linux.do/receive/:id` 进入原生领取详情。未开启时保持网页入口。官方服务的子域接管不放宽第三方插件的论坛域名限制。

项目创建、分发材料导入、商户配置、管理审核仍使用网站。服务端没有公开买家订单状态明细接口，因此客户端不能从“暂未发放”推断已退款或退款失败。人机验证桥接依赖官网已登录页面能够渲染 hCaptcha；官网布局或验证码接入变化时需核对兼容性。五个平台复用现有 WebView 实现与证书校验，Windows 使用共享 WebView2 环境。

## 上游协议依据

协议核对基于 [linux-do/cdk 的 9e2bdc6](https://github.com/linux-do/cdk/tree/9e2bdc6548311ab902f341b3932eac93bde12deb)：

- [路由与鉴权](https://github.com/linux-do/cdk/blob/9e2bdc6548311ab902f341b3932eac93bde12deb/internal/router/router.go)
- [领取、待付款恢复与响应](https://github.com/linux-do/cdk/blob/9e2bdc6548311ab902f341b3932eac93bde12deb/internal/apps/payment/router.go)
- [建单、回调交付和退款](https://github.com/linux-do/cdk/blob/9e2bdc6548311ab902f341b3932eac93bde12deb/internal/apps/payment/service.go)
- [hCaptcha 验证中间件](https://github.com/linux-do/cdk/blob/9e2bdc6548311ab902f341b3932eac93bde12deb/frontend/middleware.ts)
- [网站验证组件](https://github.com/linux-do/cdk/blob/9e2bdc6548311ab902f341b3932eac93bde12deb/frontend/components/common/receive/ReceiveVerify.tsx)
- [项目、领取记录与趋势](https://github.com/linux-do/cdk/blob/9e2bdc6548311ab902f341b3932eac93bde12deb/internal/apps/project/routers.go)
