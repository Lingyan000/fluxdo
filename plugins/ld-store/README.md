# LD士多

## 1.6.0

需要支持 schema 7 的 FluxDO 宿主。新版增加与应用一致的搜索框、商品及订单弹层托柄、六格支付密码输入和付款成功动效。安装弹层支持滚动、展开权限详情，更新按钮固定在底部。升级后在元宇宙的添加服务入口选择 LD士多，确认更新插件。

- 原生登录从当前 Linux DO 账号发起。宿主显示服务条款与授权确认，执行 Connect 导航、PKCE 一次性码交换和服务身份校验，将会话绑定当前账号并存入安全存储。
- 商品列表使用自适应卡片，筛选可收起。商品链接进入原生详情弹层，兑换和付款操作位于底部，颜色、圆角、字体及弹框使用应用公共组件。
- 确认订单页自动读取报价，改数量后重新报价，保留仍有效的优惠券选择。创建订单需要逐笔确认，失败恢复沿用原提交号。
- 待支付订单提供原生 LDC 收银台。宿主核对订单号、付款账号、收款方与金额，首次使用可在原生界面设置支付密码，保存后另行确认付款。用户输入六位支付密码并确认后提交一次。响应丢失时回查原单，交付状态取自士多订单接口。
- 登录凭证、支付链接中的订单令牌与支付密码由宿主处理。脚本调用具名能力，获取可展示的业务结果。
- LDC 收银台及本机生物识别由应用统一提供。用户可主动开启指纹、面部识别或 Touch ID 付款，将支付密码按账号保存到本机系统安全存储，每笔付款均需系统确认。取消识别后可输入密码，关闭功能会删除保存的密码。当前入口覆盖 Android、iOS、macOS，Windows 和 Linux 使用密码付款。

商品、搜索、分类、库存、报价、选券、订单列表、详情和交付展示由本目录的三个文件定义。当前授权与交易适配采用士多的 PKCE 交接协议、订单协议及 LDC 买家支付接口。其他服务可复用相同协议，采用不同协议的服务需要增加宿主适配。

链接商品沿用站点提供的外部兑换说明，普通站内订单使用原生确认和付款流程。

## 安装

选择「元宇宙 → 添加第三方服务 → LD士多」安装随客户端分发的版本。也可从同一 HTTPS 目录中的清单地址安装，或生成文件包后选择「从文件安装」。

```sh
dart run tool/pack_metaverse_plugin.dart plugins/ld-store build/plugins/ld-store.fluxplugin
```

同一内置资源来源更新时保留订单恢复记录，来源或权限变化后需要重新启用。旧版宿主需要先升级，才能加载 schema 7。

## 验证

已按官方网页发布脚本与公开仓库核对授权和交易路径。匿名调用授权初始化成功。回归使用模拟业务响应，覆盖 PKCE、账号校验、报价、创建确认、提交恢复、支付确认、取消及响应丢失，并检查明暗主题、窄屏、大字和商品弹层。

真实账号授权、真机 VPN、系统生物识别弹窗和实际交易仍需使用新版客户端验证。本次开发验证使用模拟交易，覆盖认证取消、账号切换、主动开启与关闭、付款结果不明时的查询恢复。可用公开读取测试检查网络。

```sh
flutter test --dart-define=LD_STORE_LIVE=true test/modules/metaverse/ld_store_live_test.dart
```

框架保留双栈 Fake-IP 候选。系统 VPN/TUN 由系统路由处理，显式代理使用原域名建立连接。网页备用入口用于商品读取故障时手动浏览。

## 网络任务交接（2026-11-12）

用户使用手机代理 App 的 VPN/TUN 模式。相同手机与网络下，网页可以看到商品，关闭手机 VPN 后原生广场也可访问。开启 VPN 时原生分类与商品请求失败，用户在 VPN 连接记录中没有找到商城域名。

已收到的真机日志来自 `0.2.29+2026102016`，请求为 `GET https://api2.ldspro.qzz.io/api/shop/products`。

```text
[插件网络] api2.ldspro.qzz.io connectionTimeout VPN=true DNS=system transport=core IPv4=0 IPv6=1
[Core/client] Connect api2.ldspro.qzz.io:443 failed after 5001ms: Connection timeout
```

交接提交 `e9942d3` 的调用链为 `main.js → fluxdo.fetch → MetaversePluginHost → MetaversePluginNetwork → NetCoreHttpAdapter(pinnedOnly) → fluxdo_net_pinned_request_start → Core.pinned_client → EgressConnector`。该提交的相关入口如下。

- `lib/modules/metaverse/plugin/providers/metaverse_plugin_providers.dart` 根据网络设置选择系统解析或 DoH。核心已启动且支持固定地址请求时使用核心传输。
- `lib/modules/metaverse/plugin/metaverse_plugin_network.dart` 校验清单域名与解析地址，筛选公网候选，再把 IP 列表传给核心。日志中的 `IPv4=0` 是筛选后结果。该版本的检查会排除 `198.18.0.0/15` 中的 Fake-IP。
- `core/net_core/src/egress.rs` 使用上述候选连接目标。当前直接 TCP 建连单次超时为 5 秒。应用内代理或系统 HTTP/SOCKS 代理存在时，经相应代理连接候选 IP。
- `lib/services/network/android_route_snapshot.dart` 与 `android/app/src/main/kotlin/com/github/lingyan000/fluxdo/NetworkRouteChannel.kt` 在超时后读取默认网络和候选地址对应路由，用于补充诊断。

网络任务后续提供了 Bettbox 的双栈 Fake-IP 输入及 Android 隔离实验。交接版本会把 `198.18.0.6` 与 `2001:2::6` 筛成仅剩 IPv6，阻断 IPv6 后会重现建连超时。原故障手机的具体目标地址仍待采集。

复现时保持手机 VPN 开启，从「元宇宙 → 添加第三方服务 → LD士多」安装并启用，打开物品广场刷新一次。对齐 `[插件网络]` 与 `Egress TCP to … via … failed` 的时间，再按应用及实际目标 IP 检查 VPN 记录。现有手动 DoH 重试入口用于对照观察，其效果仍需同一设备验证。

本地入口 `test/modules/metaverse/ld_store_live_test.dart` 可按上文显式开启公开只读验证。它覆盖分类、商品和详情，本地 HTTP 代理验证与 Android 真机 TUN 路径须分别验收。生产原生登录、下单与支付的接入状态见本文开头。

### Fake-IP 兼容修正

框架现已保留上述两个范围的 DNS 候选，交错地址族后交给核心或 Dart 应急出口。新核心的插件入口支持显式代理按域名解析与选址，直连仍限于本次筛选结果。普通私网、回环、非授权域名及 TLS 校验继续受各自检查约束。代理远端的地址限制由用户配置的代理负责，具体边界见[插件网络协议](../../docs/metaverse-plugin.md)。

`test/modules/metaverse/metaverse_fake_ip_test.dart` 覆盖 IPv4 Fake-IP、双栈 Fake-IP、IPv4 Fake-IP 加真实 IPv6、IPv6 无响应回退、候选截断、取消与证书错误。Rust 出口测试验证代理收到原域名、空直连集合不能自行解析直连，以及原 pinned 契约。

`test/modules/metaverse/metaverse_fake_ip_core_test.dart` 使用本地核心和回环代理核对真实 FFI 发出的 CONNECT 域名，覆盖上述三种地址组合及本地 DNS 失败。设置 `FLUXDO_LIVE=1` 后运行该用例，代理只记录请求并返回错误。真实手机的 VPN 路径仍需安装包含新核心的版本复测。
