---
name: fluxdo-theme
description: 在新增或调整内置主题（`assets/themes/*.json` 的配色、强调色、界面风格 `style`），或界面在某个主题下颜色、圆角不协调时使用。覆盖组件取色与圆角 token 的选用、主题 JSON 字段、守卫测试和效果图目检。
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
会拦截新增的写死用法；确实属于合理例外时，调整守卫的基线并写清楚原因。

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

节日主题（`festival-*.json`）只提供配色，不出现在主题画廊里；节日期间自动生效，形状、字体和界面风格
仍跟随用户自己选的主题。节日日期在 `assets/festivals/` 中配置。
