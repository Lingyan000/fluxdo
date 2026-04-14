# FluxDO

> 一个真诚、友善、团结、专业的 [Linux.do](https://linux.do/) 第三方客户端

[![Telegram Channel](https://img.shields.io/badge/Telegram-Channel-26A5E4?logo=telegram&logoColor=white)](https://t.me/ldxfd)
[![Telegram Group](https://img.shields.io/badge/Telegram-Group-26A5E4?logo=telegram&logoColor=white)](https://t.me/fluxdo_chat)

FluxDO 是为 [Linux.do](https://linux.do/) 社区打造的现代化移动和桌面客户端，基于 Flutter 开发，致力于为用户提供流畅、优雅的论坛浏览体验。

## 下载

<a href="https://github.com/lingyan000/fluxdo/releases"><img alt="Get it on GitHub" src="https://img.shields.io/github/v/release/lingyan000/fluxdo?style=for-the-badge&logo=github&label=GitHub%20Releases" /></a>
<a href="altstore://source?url=https://lingyan000.github.io/fluxdo/source.json"><img alt="Add to AltStore" src="https://img.shields.io/badge/AltStore-Add_Source-0c6bff?style=for-the-badge&logo=apple" /></a>

### AltStore 安装

1. 在 iOS 设备上安装 [AltStore](https://altstore.io/)
2. 打开 AltStore，进入 **Browse** → **Sources** → 点击左上角 **+**
3. 粘贴源地址：
   ```
   https://lingyan000.github.io/fluxdo/source.json
   ```
4. 在源中找到 FluxDO 并安装

![FluxDO 预览](screenshots/preview.png)

## 特性

### 核心功能
- **跨平台支持**：Android、iOS、Windows、macOS、Linux
- **Material Design 3**：现代化 UI 设计，支持动态取色
- **深色模式**：自动适配系统主题
- **完整论坛功能**：浏览话题、发帖回复、搜索、通知
- **内容管理**：书签、浏览历史、关注列表
- **徽章系统**：查看和展示社区徽章
- **Markdown 编辑器**：支持富文本编辑和预览
- **图片支持**：图片上传、查看、保存
- **投票功能**：参与社区投票

### 技术特性
- **安全连接**：集成 Rust 实现的 DOH (DNS over HTTPS) 代理
- **性能优化**：图片缓存、懒加载、代码高亮
- **实时通知**：MessageBus 实时消息推送
- **智能渲染**：HTML 内容分块渲染，流畅滚动

## 快速开始

### 前置要求

- Flutter SDK ^3.10.4
- Rust 工具链（用于编译 DOH 代理）
- Android Studio / Xcode（移动端开发）

### 安装步骤

1. **克隆仓库**
   ```bash
   git clone https://github.com/Lingyan000/fluxdo.git
   cd fluxdo
   ```

2. **安装 Flutter 依赖**
   ```bash
   flutter pub get
   ```

3. **生成多语言文件**
   ```bash
   dart run tool/merge_l10n.dart
   ```

4. **编译 Rust DOH 代理**（可选，用于网络加速）

   桌面平台：
   ```bash
   # Windows
   .\scripts\build_desktop.ps1

   # macOS/Linux
   ./scripts/build_desktop.sh
   ```

   Android 平台：
   ```bash
   # Windows
   .\scripts\build_android.ps1

   # macOS/Linux
   ./scripts/build_android.sh
   ```

5. **运行应用**
   ```bash
   # Android
   flutter run --dart-define=cronetHttpNoPlay=true

   # Windows
   flutter run -d windows

   # macOS
   flutter run -d macos
   ```

## 项目结构

```
fluxdo/
├── lib/
│   ├── config/              # 应用配置
│   ├── models/              # 数据模型（话题、用户、通知等）
│   ├── modules/             # 功能模块
│   ├── pages/               # 页面组件
│   ├── providers/           # Riverpod 状态管理
│   ├── services/            # 业务逻辑服务
│   │   ├── network/         # 网络层（DOH、代理、适配器）
│   │   └── ...
│   ├── utils/               # 工具类
│   ├── widgets/             # 可复用组件
│   └── main.dart
├── core/
│   └── doh_proxy/           # Rust DOH 代理实现
├── packages/                # 本地依赖包
├── scripts/                 # 构建脚本
└── pubspec.yaml
```

## 技术栈

- **前端框架**：Flutter
- **状态管理**：Riverpod
- **网络请求**：Dio + Native Dio Adapter
- **HTML 渲染**：flutter_widget_from_html
- **代码高亮**：re_highlight + google_fonts (FiraCode)
- **图片处理**：extended_image + cached_network_image
- **本地存储**：shared_preferences + flutter_secure_storage
- **网络代理**：Rust (DOH + ECH)

## DOH 代理功能

FluxDO 集成了基于 Rust 的 DOH (DNS over HTTPS) 代理，提供：

- **DNS 加密查询**：防止 DNS 污染和劫持
- **多服务器支持**：DNSPod、腾讯 DNS、阿里 DNS、Cloudflare、Canadian Shield、Google、Quad9
- **ECH 支持**：加密 TLS 握手中的 SNI 字段（用户无感知）
- **跨平台实现**：
  - Android/iOS：FFI 调用
  - Windows/macOS/Linux：独立进程

详细文档请参考 [core/doh_proxy/README.md](https://github.com/Lingyan000/fluxdo_doh)

## 关于 Linux.do

[Linux.do](https://linux.do/) 是一个真诚、友善、团结、专业的技术社区，汇聚了众多热爱技术、乐于分享的开发者。FluxDO 作为第三方客户端，致力于为社区成员提供更好的移动和桌面端体验。

**注意**：本项目为非官方客户端，与 Linux.do 官方无直接关联。

## 问题反馈

如果您在使用过程中遇到问题或有建议，欢迎：
- 在 [Linux.do](https://linux.do/) 论坛发帖讨论
- 提交 [Issue](https://github.com/Lingyan000/fluxdo/issues)

## 开源协议

本项目基于 [GPL-3.0](LICENSE) 协议开源。

## 致谢

感谢 [Linux.do](https://linux.do/) 社区的所有成员，是你们的真诚、友善、团结、专业让这个社区充满活力。
