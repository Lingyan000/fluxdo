# 插件发布与排错

面向插件作者。先完成[快速上手](README.md#快速上手)，再将验证过的包交给市场。CLI、脚手架与 SDK 的 1.0.0 仍为发行候选；草稿公开前，使用同批本地工具验证，不能将草稿下载地址写入在线目录。

## 生成一份可核对的发布物

推荐使用脚手架自带的 `.github/workflows/plugin-release.yml`：手动触发后检查、测试、签名打包，生成市场条目并创建草稿 Release。配置仓库 Secret `PLUGIN_SIGNING_KEY`；密钥轮换另配置 `PLUGIN_PREVIOUS_SIGNING_KEY`。核对草稿后再公开。

手动发布也须让包、摘要和市场条目来自同一次构建：

1. 为作者生成并妥善保存 RSA 私钥，不放进插件工程、版本库、日志或附件。丢失密钥将无法证明后续版本与原作者的连续性。CLI 接受 2048–4096 位 RSA、指数 65537；例如在项目外执行：

   ```sh
   openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -pkeyopt rsa_keygen_pubexp:65537 -out publisher-private.pem
   ```

   用操作系统权限保护私钥。签名绑定清单、脚本和 UI 摘要，不是平台认证；首次信任仍由用户决定。

2. 在插件项目中执行检查与模拟测试：

   ```sh
   npm run check
   npm test
   ```

   模拟测试只验证业务逻辑。正式设备的权限撤销、系统通知、导航和账号流程须在可控环境单独验收。

3. 更新清单 `version`，在固定提交和锁定依赖上生成签名包与条目。替换仓库、标签及项目外的私钥路径：

   ```sh
   npx --no-install fluxdo market-entry --repository https://github.com/OWNER/REPO --tag plugin-v1.0.0 --channel stable --key ../publisher-private.pem
   ```

   `market-entry` 会重新检查、构建、签名并写入 `dist/<id>-<version>.fluxplugin` 与 `dist/market-entry.json`。它不上传 Release，也不提交市场。不要先上传另一次 `pack` 的包，再用这次条目的摘要。只做本地安装包可使用 `npm run pack:plugin -- --key ../publisher-private.pem`。

4. 对最终包生成 `dist/SHA256SUMS.txt`，并与条目的 `sha256` 核对。下面跨平台 Node 命令只读取条目对应的包：

   ```sh
   node --input-type=module -e "import{readFileSync,writeFileSync}from'node:fs';import{createHash}from'node:crypto';const e=JSON.parse(readFileSync('dist/market-entry.json','utf8'));const f=decodeURIComponent(new URL(e.packageUrl).pathname.split('/').pop());const h=createHash('sha256').update(readFileSync('dist/'+f)).digest('hex');if(h!==e.sha256)throw Error('摘要不一致');writeFileSync('dist/SHA256SUMS.txt',h+'  '+f+'\n');"
   ```

5. 创建与条目 `packageUrl` 一致的 GitHub Release，上传这份 `.fluxplugin` 和 `SHA256SUMS.txt`。先保留草稿，确认版本、渠道、资源及签名再公开。公开后重新下载并核对摘要，不覆盖已发布附件。

6. 编辑 `market-entry.json` 的简介、分类、截图和更新说明。权限范围与公钥指纹已从实际包推导，不手工伪造。将条目提交到目录仓库 `entries/`，运行下节校验后提 PR。

稳定渠道不能使用预发布版本号；测试渠道用 `--channel preview`，GitHub Release 同时标为 prerelease。`requiredFeatures` 须与包一致。用户可关闭测试渠道，稳定条目仍须存在。

## 提交到市场

默认目录为 [Lingyan000/fluxdo-plugins](https://github.com/Lingyan000/fluxdo-plugins)。按该仓 README 放置条目，更新索引并校验公开发布包：

```sh
node tools/catalog.mjs
node tools/catalog.mjs --check --verify-packages
```

第三方目录沿用相同索引契约；用户在市场的来源管理中添加 GitHub 仓库或支持的 HTTPS 索引地址。提交目录不等于用户已安装或授权；宿主下载后验证摘要、签名、清单和实际访问范围。

作者密钥正常轮换时，打包和生成条目都使用 `--key 新密钥 --previous-key 旧密钥`。缺少连续性证明会要求用户重新审阅，并按换发布者处理数据和授权。版本回退、开发编号切换及迁移规则见[定时更新](automatic-updates.md#版本恢复与数据迁移)。

发现坏版本时，在目录标记 `withdrawn` 或 `withdrawnVersions` 并写明原因，另发修复版。不要替换原版本的包，也不要将尚未公开的草稿配置到在线市场。

## 常见问题

### 接口请求被拒绝

先看插件日志里的错误码、目标域名和调用来源。`fetch` 只接受符合清单 `permissions.network` 的 HTTPS 域名，IP 字面量、保留目标和非允许端口会拒绝；不能把论坛保留域名加入网络权限。带凭证请求还须匹配 origin、路径段和方法，并获得服务账号权限。

HTTP 4xx/5xx 通常仍返回响应，检查 `response.ok/status`；不要把业务失败当作成功。权限拒绝应保留其他可用内容，只有用户点击需要该权限的功能时再申请。详见[网络](api.md#网络)和[用户关闭权限时](api.md#用户关闭权限时)。

### 图片不显示

先核对 URL、真实响应内容、TLS 和重定向目标。`Image` 默认允许清单联网域名内的图片；只有超出这些域名的匿名公网图片才需要 `permissions.publicImages: true` 且用户开启外部图片权限。论坛读取返回的准许头像另有受控通道。

公开图片请求不会附带账号 Cookie 或服务凭证，私密图片不能靠扩大图片权限解决，应按[临时附件与私密图片](api.md#临时附件与私密图片)使用 `files.preview`。单图大小、解码、缓存和跳转限制见[组件参考](components.md)。

### 页面滚动、底栏或键盘布局异常

`PageLayout`、`ListPage`、`GridPage`、`TimelinePage` 自带滚动，清单对应页面使用 `scroll: false`。不要再套无限高的滚动容器；输入和固定操作区使用组件的 footer，让宿主处理键盘与安全区。少量嵌套网格用 `TileGrid`，长列表用页面级组件。

### 按钮没有反应

核对 RFW 的 `event "名称"` 与 `fluxdo.on('名称', handler)` 完全一致；检查 `enabled/loading`、当前 surface 是否可见，以及日志中的参数或权限拒绝。导航、授权、付款需要真实用户点击资格，定时器或页面加载事件不能代替点击。处理器中的异步操作使用 `ctx.api` 关联当前界面。

### 热更新后状态丢失或操作重复

正式脚本的持久数据放 `storage`，当前界面数据用 `ctx.setData`；模块内需要热替换保留的状态使用 `import.meta.hot.data`。自建资源在 `import.meta.hot.dispose` 清理，不在模块顶层发不可重入的外部写请求。

清单变化、完整模块图重载或断线恢复需要重新审阅启动，不保证任意模块状态无损恢复。已发送的外部副作用无法撤回；Connect、付款和未完成调用期间会暂缓更新。详见[开发工具](development-tooling.md)。

### 无线扫码连不上

确认电脑 CLI 正在监听正确的局域网 IPv4，手机与电脑同网且没有 AP/访客隔离，防火墙允许开发端口。iOS 首次连接需要允许本地网络；Windows/Linux 使用粘贴地址。相机不可用时也可粘贴。

服务重启后旧令牌和 TLS 指纹失效，需要重新扫码。不能仅修改旧配对地址的主机部分。二维码含临时凭证，不公开截图或写入版本库。连接后可运行 `npx --no-install fluxdo doctor --pair '完整配对地址'` 查看能力、权限和调用统计，诊断不返回业务数据值或凭证。

### 更新后要求重新审阅

同源更新保留已选权限；新增敏感权限、访问范围扩大或签名连续性变化需要审阅。`requiredFeatures` 缺失表示宿主不兼容，需要更新应用，不能靠反复启用绕过。自动更新不会自动降版，手动版本替换仍要核对同源签名与数据版本。

### 该查哪里的日志

打开「插件管理 → 当前插件 → 日志」，按脚本或框架来源、级别筛选。提供错误码、插件版本和请求关联号即可，不导出真实密码、令牌或完整私密响应。仅清空当前插件日志与清空数据是不同操作，数据重置会移除该插件的业务数据和服务凭证。
