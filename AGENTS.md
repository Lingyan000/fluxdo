# AGENTS.md

FluxDO 是 [Linux.do](https://linux.do/)（Discourse）的 Flutter 第三方客户端，覆盖 Android、iOS、macOS、Windows、Linux。
开发环境与日常命令见 [docs/development.md](docs/development.md)。

## 仓库结构

```
lib/
  pages/ widgets/       页面与组件
  providers/            Riverpod 状态
  services/             网络、Discourse API、平台能力
  models/               数据模型
  theme/                主题：ThemeSpec、界面风格、配色解析
  settings/             设置页定义与渲染
  l10n/modules/         国际化 arb 源文件（生成产物不入库）
  modules/              相对独立的功能模块（小程序、打赏等）
packages/
  fluxdo_render/        帖子 HTML 渲染与编辑器（独立 git 子模块）
  common_ui/            通用交互组件、形状与强调 token
  m3e_ui/               Material 3 Expressive 组件
  app_icons/            图标库
core/net_core/          网络核心（Rust）
assets/themes/          内置主题 JSON（启动时自动扫描）
tool/                   just 命令背后的 Dart 脚本
test/architecture/      架构守卫测试
.agents/skills/         按需加载的工作流
```

## 命令

```sh
just sync          # pub get、生成 l10n、证书资源；just run / build 会自动执行
just doctor        # 检查开发环境与生成产物
just l10n          # 生成国际化代码；just l10n-check 校验是否最新
just analyze       # flutter analyze
just test          # 工作区测试；参数透传给 flutter test
just run / build   # flutter run / build
```

新建 git worktree 后先执行 `git submodule update --init packages/fluxdo_render` 和 `just l10n`，否则会出现大量与改动无关的编译错误。

## 约定

- **时间**：Discourse API 的时间都是 UTC。解析用 `TimeUtils.parseUtcTime()`，显示用 `TimeUtils` 的 `format*` 方法（`lib/utils/time_utils.dart`）；禁止直接 `DateTime.parse()` / `tryParse()`，禁止在 `TimeUtils` 之外调用 `.toLocal()`。
- **路由与弹窗**：使用 `InteractionPageRoute`、`showAppDialog`、`showAppBottomSheet` 等统一入口，不直接用 `MaterialPageRoute`、`showDialog`、`showModalBottomSheet`（[守卫](test/architecture/interaction_entry_points_test.dart)）。关闭根层弹框用 `Navigator.of(context, rootNavigator: true)` 或弹框自己的 context，裸 `pop` 会误关嵌套导航里的页面。
- **主题 token**：颜色和圆角必须经过主题 token，同一块区域里的颜色、圆角保持一致。圆角用 `context.shapes`，图标强调色用 `context.emphasis`，分类色用 `ColorUtils.category`。细则与新增主题见 [fluxdo-theme](.agents/skills/fluxdo-theme/SKILL.md)，守卫见 `test/architecture/` 下的 ratchet 测试。
- **国际化**：界面文案一律走 arb，以 `zh` 为基准语言；只用文本插入的方式改 arb。流程见 [fluxdo-l10n](.agents/skills/fluxdo-l10n/SKILL.md)。
- **视觉变化需确认**：颜色、字号、字重、间距、动效等用户能察觉的变化，要先经维护者确认；不要在性能优化或重构中顺带修改。
- **不写硬编码白名单**：「需要处理哪些」从数据或类型推导，不靠手写常量列表。
- **跨平台**：平台层改动要评估全部五个平台。
- **依赖**：新增或升级依赖时，先查 pub.dev 使用最新稳定版；不得擅自修改 SDK 约束。
- **注释与提交信息**：使用中文；描述功能本身，不写「仿 XX」「XX 式」等特指其他产品的说法。

## 测试与验证

- 选择能覆盖改动的最小检查：相关测试文件加 `flutter analyze`。不要默认跑全量测试或完整构建，构建太慢，运行效果由维护者自己验证。
- 全量测试中存在与改动无关的存量失败。判断失败是否由自己引起，要在干净的 HEAD 上对比同一个用例。
- 改动 `packages/fluxdo_render` 时，验证流程（全量 golden、fixture 索引）见 [fluxdo-render](.agents/skills/fluxdo-render/SKILL.md)。
- 能机械检查的规则放进 `test/architecture/` 守卫测试。合理的存量用法通过基线计数豁免，只降不升。
- TODO：CI 还没有运行守卫测试和 analyze，要先治理存量问题再接入。在此之前，提交前请自行运行 `flutter test test/architecture`。

## 提交

工作区里经常有别人并行未提交的改动。

- 只暂存自己改过的文件，禁止 `git add -A` / `git add .`。暂存后检查 `git diff --cached --stat`，行数明显异常就说明带上了无关改动。
- 按功能分笔提交；已推送的历史不改写。
- 提交信息不加 AI 工具的 `Co-Authored-By`；Claude Code 已在 `.claude/settings.json` 中关闭署名。
- 子模块 `packages/fluxdo_render` 先提交并推送，再在主仓提交子模块指针。
- 完整流程见 [fluxdo-commit](.agents/skills/fluxdo-commit/SKILL.md)。

## 编辑这些说明

- 规则只写在本文件。`CLAUDE.md`、`GEMINI.md` 只用 `@AGENTS.md` 导入，不要往里面加内容。
- skill 放在 `.agents/skills/<名称>/SKILL.md`，frontmatter 只用标准字段（`name`、`description`、`license`、`compatibility`、`metadata`、`allowed-tools`）。`.claude/skills` 是指向该目录的软链。
- Windows 检出软链需要开启开发者模式，并设置 `core.symlinks=true`（新克隆：`git clone -c core.symlinks=true`；已有克隆：`git config core.symlinks true` 后执行 `git checkout -- .claude`）。否则 `.claude/skills` 会检出成纯文本文件，[守卫](test/architecture/agent_config_test.dart) 会失败。
