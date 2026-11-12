# LD士多

**1.4.0：原生建单与结果恢复。** 有正式报价及独立建单授权时，可在兑换页核对后提交。确认框显示士多账号、商品编号、数量、券和最终预期积分；取消不发请求。超时或重启后先查原提交号；仅在商城明确返回尚无记录时才能用相同内容再次确认。已建订单可直接打开原生详情。普通安装目前仍无生产签发适配器；不会出现原生提交按钮，也不会自动付款。升级需 schema 5 宿主，重新确认权限并启用。测试没有向线上创建订单或付款。

**1.3.1：** 广场现在标出选中的分类和排序。兑换页优先展示应付最低的方案；在同一页主动选过券或“不使用优惠券”，再次查价会保留选择。若所选券已不可用，展示无券应付并提示核对。返回兑换页时会重新读取库存和价格，保留仍可购买的数量，丢弃旧报价；返回订单页只查服务端状态，离开时收起交付内容。这两个返回行为需要新版宿主。手填的旧凭证不算服务签发的原生会话。

普通安装可直接使用原生商品页面；需授权的订单、报价和建单已用本地模拟会话验证。生产账号的无浏览器登录及真实支付未接通。以下记录按版本描述能力。

**1.3.0 兑换页：**不限库存不再显示为负数或禁止兑换；按商品的有效库存、当前账号剩余额度和平台上限共同限制数量。没有原生授权时，显示未计优惠的预估小计。如果宿主取得士多会话且有单独的报价授权，才会显示「查询当前报价」；报价来自士多的报价接口，可在返回的可用优惠券和不使用券之间切换。改数量后旧报价立即失效。没有线上原生签发适配器，普通安装不会出现报价按钮；本次仅以模拟签发及报价验证，不会自动建单、申请优惠券或扣款。此版本需 schema 4 宿主。

**1.2.0 订单页面：**「我的订单」现在进入原生列表。有宿主保管的有效士多会话时，可按状态筛选、翻页、打开详情和查看服务端已返回的交付内容；会话过期会清空页面。没有会话时不请求买家接口，不自动打开网页，可自行选「在士多官网查看订单」。此版尚无士多认可的原生签发流程，普通安装后进入的是未授权状态。网页会话不能用于这里；不要从网页拷贝令牌。下文的官网查单说明描述 1.1.0。更新到 1.2.0 须使用支持 schema 3 的宿主，审阅变更后的权限并重新开启。

这是 FluxDO 元宇宙的独立社区插件。三个发布文件是 `plugin.json`、`main.js` 和 `ui.rfwtxt`，不依赖宿主中的士多业务代码。

在仓库根目录执行：

```sh
dart run tool/pack_metaverse_plugin.dart plugins/ld-store build/plugins/ld-store.fluxplugin
```

在支持文件安装的 FluxDO 客户端选择「元宇宙 → 添加第三方服务 → 从文件安装」，选择生成的文件，审阅权限后开启。也可以把三个文件放在同一 HTTPS 目录，输入清单地址安装；重新安装可更新。文件包按内容识别来源，内容改变后需重新开启。

随客户端分发时无需另传文件：选择「元宇宙 → 添加第三方服务 → LD士多」，确认权限后开启。APK 包含同一份插件清单、界面与脚本，可离线安装插件；浏览商品仍需联网。1.4.0 起，来自同一 APK 资源路径的插件在后续版本更新时保留订单恢复记录；首次从旧包升级或从外部文件切换到内置来源，需要重新开启。

构建 ARM64 Android 测试包：`dart tool/flutterw.dart build apk --profile --target-platform=android-arm64 --no-tree-shake-icons`。RFW 运行时解码图标，AOT 构建需要保留图标字体。

广场与详情由本包的 RFW 描述在客户端绘制。广场支持关键词、分类、库存、价格筛选、排序和分页；帖子中的士多商品链接会打开详情弹层。外部商品图片由宿主单独加载，不向脚本提供图片响应。

1.0.1 起，如果商品请求失败，可以直接点「在网页中浏览士多」或「在网页中查看商品」。报告域名指向内网时，反复登录无效：请检查网络是否仅返回虚拟地址。新版宿主支持在 FluxDO 网络设置中启用加密 DNS 后重试；仅更新插件包即可使用网页入口，但不会更改旧客户端的 DNS 行为。

点击「使用 Linux DO 登录士多」后，在士多官方页面同意条款并授权。框架默认在内置浏览器打开登录、确认兑换和我的订单；三者复用同一浏览器中的士多会话，无需 FluxDO 回调。浏览器中显示的士多账号是实际交易账号，切换或登出也在士多内操作。若离站提示中选择系统浏览器，请在同一个浏览器完成后续操作。

1.1.0 起，广场将分类、排序与价格收进「筛选与排序」。在商品详情点「查看兑换预览」，原生页面重新读取当前商品；可在库存与单次限购范围内调整预估数量、查看未计优惠的小计。改变数量不下单，不发报价请求。仅当用户主动点「前往士多确认兑换」才打开官方入口，需在官网重新确认数量与最终金额；「我的订单」仍打开官方买家订单页。插件不读取站点 Cookie 或 JWT，未实现买家的原生登录、扣款与交付查询。

若手机开启 VPN 后只得到 IPv6 公网候选并且连接超时，新宿主会在插件页顶部显示「对 … 使用加密 DNS，然后刷新」。点击后再点广场刷新（详情或预览点「重试」）。此次运行中，只有该插件对这个域名发起的无凭证、无请求体的公开 GET 使用 FluxDO 当前所选的加密 DNS，并优先尝试 IPv4。不改变全局设置，不自动重发任何请求；退出插件并释放运行实例后失效。线上 DNS 和手机 VPN 路由均会变化，补查 IPv4 并不保证可达。

开发验证：`flutter test --dart-define=LD_STORE_LIVE=true test/modules/metaverse/ld_store_live_test.dart` 通过原生插件客户端匿名请求士多公开分类、列表和详情。可追加 `--dart-define=LD_STORE_TEST_DOH=<解析服务的 HTTPS 地址>` 验证加密 DNS。常规测试不访问线上服务。

验证代理开启时的同一链路，请先构建当前平台的网络核心，再为上述命令追加 `--dart-define=LD_STORE_TEST_CORE=true --dart-define=LD_STORE_TEST_PROXY=true`。测试通过仅允许士多 API 地址的本地代理发起真实 HTTPS 请求，并核实确实建立了代理隧道。

手机代理 App 的 VPN/TUN 不是 HTTP 代理端口，不需要再填一次应用内代理。FluxDO 未被分应用排除时，Android 按 VPN 的路由处理套接字。公网地址多于一个时，新网络核心会尝试备用地址。若网页能看但原生广场超时，保持 VPN 开启、刷新一次，在「网络日志」查 `[插件网络]`：失败类型、检测到的 VPN 状态、实际 DNS 模式和 IPv4/IPv6 候选数量可帮助区分解析问题与建连问题。上面的回环代理测试不能代替真机 TUN 测试。

**VPN 连接日志没有显示域名时**：先在 FluxDO 网络日志找同一时刻的 `Egress TCP to … via … failed`。`via` 是核心实际尝试的 IP 或代理；在 VPN 的连接记录（包括失败记录）里按 FluxDO 和该地址查，不要只按商城域名查。TCP 超时发生在 TLS 握手之前时，没有可供嗅探的 TLS 域名。Android 按应用和目标地址路由，按 IP 建连本身并不绕开 TUN。

带路由诊断的 Android 宿主还会在核心连接超时的日志中给出：

- `resolvedV4` / `filteredV4`：解析器返回的不同 IPv4 数与其中被公网检查排除的数量。两者同为零才表示解析结果中没有 IPv4。
- `candidates`：交给核心的公网候选；和实际逐个尝试的地址有区别。
- `appDefaultVpn` / `targetRoutes`：失败时系统报告给本应用的默认网络是否为 VPN，以及该网络的路由对每个候选的匹配结果（与候选顺序相同）。`matched` 表示有覆盖路由，`no-match` 表示无匹配，`excluded` 表示有更具体的排除路由。这不是逐包抓取；如果核心使用了上游代理，应按 `via` 中的代理地址查看实际第一跳。

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
