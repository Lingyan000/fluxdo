# 元宇宙第三方插件

开发入口见 [插件开发](plugins/README.md)。应用内「元宇宙 → 插件管理 → 更多 → 开发中心」可调整生产组件参数、触发事件并运行 API 示例。

## 结构与职责

```mermaid
flowchart TD
  P[插件脚本<br/>服务授权、业务接口、状态与页面数据] --> B[宿主能力桥<br/>权限、凭证、网络、导航、日志]
  P --> U[声明式界面<br/>应用原生组件]
  P --> N[导航页面贡献<br/>用户选择加入底栏]
  B --> F[论坛只读适配<br/>权限、账号隔离与限流]
  B --> C[公共 Connect<br/>应用账号授权]
  B --> L[应用 LDC 收银台<br/>密码、生物识别与交易核验]
  P --> S[插件私有存储<br/>业务记录与迁移]
  B --> R[独立运行时包<br/>脚本协议、生命周期与资源限制]
```

服务初始化、回调内容解析、兑换服务令牌、商品、报价、订单幂等和交付刷新由插件实现。宿主按清单授权提供通用能力。付款能力属于应用，插件提交 LDC 支付地址、参考号和预期金额，应用通过 LDC 交易接口核验后返回结果。

## 插件包与清单

目录包含 `plugin.json`、`main.js`、`ui.rfwtxt`。用 `dart run tool/pack_metaverse_plugin.dart <目录> <输出文件>` 生成 `.fluxplugin`。三个远端资源须同源，导入时检查大小、清单、脚本路径和组件引用。

新插件声明 `schema: 12` 与 `apiVersion: 2`，通过 `requiredFeatures` 声明运行所必需的宿主能力。较早 schema 的最小兼容示例见 [示例积分](examples/metaverse-plugin/plugin.json)，多页面业务示例见 [LD士多](https://github.com/Lingyan000/fluxdo-plugins/tree/main/plugins/ld-store)。

| 字段 | 作用 |
| --- | --- |
| id、version、author | 稳定插件标识、语义版本和作者 |
| permissions.network | 精确域名或通配子域，限制脚本联网 |
| permissions.identity | 读取当前应用账号 ID 与用户名 |
| permissions.credentials | 具名凭证与 origin、路径、请求方法范围 |
| permissions.connect | 允许公共 Connect 返回的精确回调地址 |
| permissions.payments | 使用应用支付提供方，当前为 linuxDoCredit |
| permissions.publicImages | 使用匿名请求加载公网图片 |
| card、pages | 卡片与页面组件，页面可选择 modal 弹层及自管滚动 |
| links | 业务链接到插件页面的规则 |
| webLogin | 可选的网站会话入口 |

安装界面将权限按网络、账号、付款、链接和身份分组，可展开核对范围。同源更新保持安装身份，权限变化重新确认，跨来源安装提示数据影响。GitHub 目录负责索引与发布附件，客户端负责内容摘要和实际包校验。

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

可用组件以[组件参考](plugins/components.md)和生产注册表 `createMetaverseWidgetLibrary` 为准。页面级组件提供列表、网格、详情、表单、固定操作区和自定义标题栏；基础组件提供布局、输入、图片、头像与加载占位。开发中心直接使用生产组件预览，SDK 的参数契约由同一注册表导出，避免另维护一份不完整的组件清单。

颜色写主题色名（`primary`、`onSurfaceVariant`、`error`…）或 `0xAARRGGBB`；
文字样式写主题名（`bodyMedium`、`titleMedium`、`headlineMedium`…）。
数值参数 `16` 与 `16.0` 都接受。

`Image` 默认只加载 `permissions.network` 中的 HTTPS 图片。声明
`permissions.publicImages: true` 后，用户可在安装时授权加载其他公网域名的图片。
图片请求携带宿主 User-Agent、图片 Accept 头，以及清单 HTTPS 主页的公开 origin 作为 Referer，使用独立的匿名客户端。每次跳转重新检查域名权限、宿主保留域名和公网地址，最多请求六次。HTTP 图片地址及跳转目标先升级为 HTTPS，再进行连接，支持合法的非标准 HTTPS 端口与包含下划线的图片主机。所有连接都校验 TLS 域名，且不附带 Cookie 或授权凭证。

单张下载上限为 16 MiB。根据文件内容识别格式，可兼容图床错误标注的 MIME 类型。位图解码尺寸限制为 1024 × 1024，SVG 使用静态渲染器，不执行脚本或加载外链子资源。加载失败后可点击重试。

图片由宿主统一合并并发下载，并按插件、来源、账号和权限上下文隔离缓存。读取缓存仍需先检查权限；可持久化的图片遵守响应缓存策略，带查询参数或经过重定向的图片不写入磁盘。插件数据重置、卸载和应用外部图片缓存清理覆盖对应缓存，详见[组件参考](plugins/components.md)。业务 API、授权与付款响应不使用图片缓存。

插件下载、API 与图片请求共用宿主的 DNS 选择。启用加密 DNS 时使用所选解析器，否则使用系统 DNS。直连筛选会拒绝回环、普通私网、链路本地等地址，并保留 `198.18.0.0/15` 和 `2001:2::/48` 中的 Fake-IP 候选，由系统路由送交 VPN。这两个范围只作为已通过域名审核的 DNS 结果使用，URL 中的 IP 字面量仍被拒绝。TLS 始终校验原域名。候选在截取数量上限前交错地址族，IPv6 不可达时可以尝试 IPv4。Dart 应急出口也使用同一解析快照并尝试备用连接。

插件通过 `fluxdo_net_plugin_request_start` 选择出口策略。应用内或系统显式代理收到原域名，由代理解析并选择目标。本地 DNS 失败或没有允许的直连候选时，传入空直连集合，核心仅可经代理访问。代理绕过规则选择直连时会拒绝该请求。客户端能够检查 URL 和本地直连候选，代理远端的地址访问范围由用户配置的代理策略控制。原 `fluxdo_net_pinned_request_start` 按调用方提供的 IP 建连。插件请求使用独立客户端、连接池和会话，旧核心或未启动核心时使用 Dart 直连应急出口。修改核心后需通过项目构建入口更新相应平台的原生库。


## 状态、日志与数据

同一插件的多个界面共享运行实例，每个界面使用独立 `ctx.surface`。事件处理通过 `ctx.api` 关联界面和调用日志。返回页面收到 `page.resume`，脚本依据业务变化决定刷新。

普通存储按插件隔离；声明论坛读取权限的插件由宿主进一步按论坛账号分区，其他服务的业务键由插件自行分隔。凭证由宿主按插件及账号安全保存。插件设置提供日志查看、导出、清空和数据重置。旧实例晚到回调通过代次检查阻止写回。API、配额和事件详情见 [API 参考](plugins/api.md)。

API 1 的通用网络、界面和手填 token 继续兼容。旧服务授权与订单协议的实现已删除，相关已安装插件可保留数据并更新。旧记录由通用迁移入口原样导出，服务插件负责解释和转换。

## 运行与验证

运行时协议位于 `packages/fluxdo_plugin_runtime`。Flutter、原生引擎、网络和应用能力适配位于 `lib/modules/metaverse/plugin`，论坛和系统任务等应用服务由 `lib/modules/metaverse/host` 注入。服务接口、数据映射、页面业务和刷新策略留在独立插件。

每插件使用独立 QuickJS isolate，宿主设置原生执行截止时间、JS 堆及栈上限，并在停止时中断原生执行。协议与资源边界见[开发入口](plugins/README.md#必需能力与资源边界)，引擎升级需保留的本地修复见 [qjs 维护说明](../packages/qjs/FLUXDO_PATCHES.md)。安装、定时更新、回退及迁移契约见[插件定时更新](plugins/automatic-updates.md)。

开发中心 API 示例使用模拟桥。登录、建单与付款回归采用固定响应，实际付款由用户在应用收银台确认。

导航页面贡献和论坛读取使用 schema 11，接口、权限与生命周期见 [API 参考](plugins/api.md#论坛只读接口与原生导航)。列表、动态合并和刷新策略仍属于插件。
