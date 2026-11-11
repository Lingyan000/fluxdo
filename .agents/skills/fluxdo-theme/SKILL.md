---
name: fluxdo-theme
description: 新增或调整 FluxDO 主题，处理主题下的颜色、圆角、自定义背景和节日装饰时使用。涵盖主题 token、主题 JSON、背景分层、装饰注入与验证。
---

# FluxDO 主题

主题由配色、形状（圆角）、界面风格（组件长什么样）三部分组成。同一块区域里的颜色、圆角要保持一致，一律通过主题 token 取值，不在组件里写死。

## 写界面时

| 要什么 | 用什么 | 不要用 |
|---|---|---|
| 圆角 | `context.shapes.borderRadius(N)` / `radius(N)`；无 context 时用 `UiShapes.current` | `BorderRadius.circular(12)` |
| 圆形按钮、图标底座 | `context.shapes.circle()`（方正风格下会收成圆角方） | `BoxShape.circle`、`CircleBorder()` |
| 入口、区块图标 | `context.emphasis.accent` | `colorScheme.primary` |
| 选中、已开启、当前排序 | `context.emphasis.selected` | `colorScheme.primary` |
| 普通操作图标按钮 | 不写颜色（图标按钮主题统一为次要色） | 显式写 `onSurface` |
| 自绘的顶栏工具条 | 用 `TopBarIconScope` 包住，里面的按钮和 AppBar 同色 | 逐个按钮写强调色 |
| 分类、标签色 | `ColorUtils.category(hex, theme)`、`ColorUtils.themed(color, theme)` | 自己写 `int.parse` 解析 |
| 链接 | `colorScheme.primary` | — |
| 判断组件风格 | `context.themeStyle`（例如 `surfaces == SurfaceStyle.flat`） | 按主题 id 判断 |

头像、状态圆点、色点、徽标这类本来就是圆的元素，继续用 `BoxShape.circle`。
守卫测试 `test/architecture/radius_literal_ratchet_test.dart`、`theme_emphasis_ratchet_test.dart`
会拦截新增的写死用法。基线用于豁免合理的存量用法，按 AGENTS.md 的约定只降不升。

## 页面背景与表面

页面背景由 `PageBackgroundScope` 注入，当前优先级为用户背景图、节日底纹、纸张纹理。`ThemeState.hasPageBackground` 供应用构建主题使用，组件可用 `PageBackgroundScope.isActive(context)` 判断。`transparentEnabled`、`isTransparentActive` 和存储键 `theme_transparent` 沿用旧命名，当前对应自定义背景图的启用状态。实现见 [theme_provider.dart](../../../lib/providers/theme_provider.dart) 和 [main.dart](../../../lib/main.dart)。

| 区域 | 接入方式 |
|---|---|
| 普通路由的整页背景 | 由现有路由链路中的 `RoutePageBackground` 绘制，背景随页面转场 |
| 需要遮住滚动内容的标题栏、吸顶条、底栏、窗格底 | 用 `PageBackdrop` 绘制与整页对齐的背景副本 |
| 话题卡片、详情标题与正文、对应骨架屏 | 用 `PageBackgroundScope.contentColor(context, 原有底色)`，有背景时透出背景，无背景时使用原有底色 |
| 面板、菜单、对话框 | 使用组件主题对应的表面色 |
| 剧透等必须遮住内容的区域 | 使用不透明的 `colorScheme.surface` 等语义表面色 |

背景启用时 `scaffoldBackgroundColor` 可能透明。`PageBackdrop(child: ...)` 可跟随内容尺寸，独立填充时用 `Positioned.fill` 等提供有限宽高。实现见 [page_background.dart](../../../packages/common_ui/lib/src/page_background.dart)。

选中、按压、跳转高亮、删除和隐藏帖的状态色继续叠在内容底色上。自绘卡片在绘制外壳时读取 `contentColor`，切换背景可复用文字排版缓存。新内容高亮动画的结束色也通过该入口计算。

AppBar、底部导航与侧栏的背景由 `buildAppTheme` 统一处理。AppBar 在内容滚入下方时使用不透明底色，底部导航下方由布局铺 `PageBackdrop`。页面自行覆盖栏背景时，需要同时处理滚动遮挡与背景显示。实现见 [app_theme.dart](../../../lib/theme/app_theme.dart)。

`PageBackgroundScope` 与 `UiDecor` 保持在稳定的宿主层级，切换设置时更新 builder。builder 使用顶层函数或按配置缓存的闭包，保持引用稳定。公共组件选型见 [fluxdo-ui-components](../fluxdo-ui-components/SKILL.md)。

## 新增内置主题

1. 在 `assets/themes/` 新建 `<id>.json`，可以照着 `nord.json`（经典配色）或 `paper.json`（带界面风格）写。
   注册表会自动扫描这个目录，不需要改代码。
   - 必须同时提供 `light` 和 `dark`：`bg`、`fg`、`fgMuted`、`border`，以及 8 个基础色相 `hues`
     （red、orange、yellow、green、cyan、blue、purple、teal）。
   - `accents` 至少一个；同族主题（`family` 相同）的强调色 id 要一致，切换口味时才能保留用户的选择。
   - `name` 至少写 `zh` 和 `en`。
2. 按主题气质配置 `style`（不写就是 Material 默认外观）：
   - `surfaces`：`filled` / `outlined` / `flat`
   - `controls`：`accent` / `ink`（墨色控件，强调色只留给链接、选中与焦点）
   - `navIndicator`：`pill` / `bar` / `tint`
   - `inputs`：`filled` / `outlined` / `underline`
   - `shadows`：是否要阴影
   - `titleFont`：`serif` / `mono` / 字体目录 id
   - `bodyLineHeight`：正文行高
   - `quote`：`card` / `bar`
   - `texture`：`none` / `paper`
   - `dataColors`：分类色处理，`vivid` / `harmonized` / `muted` / `mono`
3. 跑测试：
   ```sh
   fvm flutter test test/theme test/architecture
   ```
   `builtin_themes_test.dart` 会检查所有主题、强调色、明暗、纯黑组合下文字都可读。
4. 渲染效果图目检：
   ```sh
   fvm flutter test test/preview/theme_style_mockups_test.dart --dart-define=THEME_PREVIEW_DIR=/tmp/theme_preview
   ```
   在 `/tmp/theme_preview/` 查看首页、帖子、设置三屏的效果图。
5. 主题 JSON 只在启动时读取：在应用里验证要冷启动，热重载不会生效。

## 节日主题

节日配色位于 `assets/themes/festival-*.json`，日期与问候在 `assets/festivals/festivals.json` 中配置。`effectiveColorSpec` 选择节日配色，形状、字体和 `effectiveStyle` 跟随用户选择的主题。节日主题默认开启，保存过的关闭状态继续生效，主题画廊通过注册表筛选普通主题。

### 装饰与动画

| 能力 | 接入点 |
|---|---|
| 日期判定、当前节日、跳过本次、装饰开关 | `FestivalCalendar`、`ThemeState.activeFestival`、`isFestivalDecorActive` |
| 节日底纹 | `FestivalPatternBackground`，通过页面背景层注入，用户背景图优先 |
| 首页可点击挂件 | `FestivalBadge`，点击后播放一次图案动画并显示问候 |
| 自绘节日图案 | `FestivalMotif`，`phase` 为循环进度，`intensity` 为动效强度 |
| 空态点缀 | `UiDecor.cornerBadge`，由 `AppEmptyState` 消费 |
| 刷新加载图案 | `UiDecor.loadingIndicator`，由 M3E 刷新圆片消费 |

`FestivalMotif` 默认静止。加载动画由 `festivalLoadingIndicator` 持续推进 `phase` 并保持 `intensity = 1`，挂件由 `FestivalBadge` 控制单次播放和强度渐入渐出。应用宿主使用稳定的 builder 注入 `UiDecor`，组件包通过插槽取得内容。实现位于 [festival_decor.dart](../../../lib/widgets/festival/festival_decor.dart) 和 [festival_badge.dart](../../../lib/widgets/festival/festival_badge.dart)。

### 调试与验证

Debug 包在外观设置的节日分区提供 `festivalDebugPreview`。`setDebugFestival(id)` 可跨日期预览，传 `null` 恢复按日期判定，预览状态仅保存在内存。装饰显示仍受 `festivalDecorEnabled` 控制。入口见 [appearance_theme_section.dart](../../../lib/settings/definitions/appearance_theme_section.dart)。

按改动范围选择已有测试，背景相关看 `test/widgets/common/page_background_test.dart`，节日状态看 `test/providers/festival_theme_test.dart`，日期与资源配置看 `test/theme/festival_calendar_test.dart`。需要检查图案和动画关键帧时运行以下预览。

```sh
mkdir -p /tmp/festival_preview
fvm flutter test test/preview/festival_motifs_preview_test.dart --dart-define=FESTIVAL_PREVIEW_DIR=/tmp/festival_preview
```

输出包含 `festival_motifs.png` 和 `festival_frames.png`。在应用内复核挂件点击、刷新期间连续动画、明暗配色，以及背景图与节日底纹的切换。
