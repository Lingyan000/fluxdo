# 原生组件参考

界面文件使用 `import fluxdo;`。可用组件由[生产注册表](../../lib/modules/metaverse/plugin/ui/metaverse_widget_library.dart)导出。应用内开发中心提供每个宿主组件的真实预览、参数调整与事件记录。

## 参数和事件

- `child` 是单个组件，`children` 是组件列表。动态列表使用 `...for item in data.items:`。
- `data.xxx` 读取脚本 `ctx.setData` 写入的值。事件使用 `event "事件名" { 参数 }`，由 `fluxdo.on` 接收。
- 宿主组件的数值参数接受整数和小数。rfw 基础组件的 double 参数使用 `16.0` 等小数写法。
- 内边距使用小数列表 `[start, top, end, bottom]`，如 `[16.0, 8.0, 16.0, 8.0]`。一个值应用于四边，缺少 end 时沿用 start，缺少 bottom 时沿用 top。
- 枚举参数使用名称字符串，如 `"start"`、`"cover"`。宿主文本参数支持字符串及由字符串、数字组成的片段列表。
- `Label`、`Surface`、`Symbol`、`Chip` 的颜色支持主题 token 或 ARGB 整数。推荐主题 token，适配深浅色和用户主题。

```text
import fluxdo;

widget SearchPage = PageLayout(
  loading: data.loading,
  onRefresh: event "refresh" {},
  children: [
    SearchInput(
      value: data.query,
      hint: "搜索",
      onChanged: event "query.changed" {},
      onSubmitted: event "search" {},
    ),
    Gap(size: 12),
    ...for item in data.items:
      ListItem(
        title: item.title,
        onTap: event "item.open" { id: item.id },
      ),
  ],
);
```

输入事件通过 `args.value` 传值，脚本应回写对应数据。`PageLayout` 管理滚动时，清单页面使用 `scroll: false`，避免嵌套两个页面滚动容器。示例的 loading、query 和 items 由 `page.open` 初始化。

## 宿主组件

| 组件 | 参数与默认值 | 事件及行为 |
| --- | --- | --- |
| `PageLayout` | `children`、可选 `toolbar`、`footer`、`loading: false`、`hasMore: false`、`loadingMore: false`、`loadMoreError: ""` | `onRefresh`、`onLoadMore`。有界页面提供滚动内容和底部操作区域，最大内容宽度 960。刷新完成需把 loading 改回 false |
| `TimelinePage` | `identity`、`items`、`itemKeys`、`header`、`footer`、`loadingPlaceholder`、`loading`、`loadingMore`、`hasMore`、`error`、`emptyTitle`、`moreLabel`、`endRevision` | `onLoadMore`、`onRetry`。需要 `timelinePages`，使用下方时间线顺序与定位约定 |
| `ListPage` | `items`、可选 `toolbar`、`search`、`header`、`actions`、`emptyTitle`、`error`、`loading: false`、`hasMore: false`、`loadingMore: false`、`moreLabel` | `onRefresh`、`onRetry`、`onLoadMore`。分组列表按需构建，上滑接近底部时加载下一页，也保留手动加载入口，刷新保留已有条目 |
| `DetailPage` | `sections`、可选 `toolbar`、`header`、`actions`、`emptyTitle`、`error`、`loading: false` | `onRefresh`、`onRetry`。分区间距与底部操作由页面管理，刷新保留已有内容 |
| `FormPage` | `fields`、`resetKey: ""`、`loading: false`、可选 `header`、`actions`、`submitLabel` | `onChanged` 回传 `{field, value}`，校验通过后 `onSubmit` 回传 `{values}`。加载期间禁用输入与提交 |
| `ActionBar` | `actions` 组件列表 | 操作靠右排列，窄屏自动换为纵向；事件由内部按钮声明 |
| `TileGrid` | `children`、`layout: natural`、`columns: 0`、`minTileWidth: 0`、`spacing: 12`、`runSpacing: 12` | 自然高度、同排等高、瀑布流，详见下方网格布局 |
| `Choice` | `label`、`selected: false`、`leading`、`layout: inline / stacked` | `onSelected`，值由脚本管理。`stacked` 将头像或图标放在标签上方，适合横向名单 |
| `EmptyState` | `title`、可选 `message`、`icon`、`action` | 空内容或错误状态，默认购物袋图标，通用场景建议指定 icon |
| `SelectableLabel` | `text` | 可选择复制的 bodyMedium 文本 |
| `Label` | `text`、`style: bodyMedium`、`color`、`bold: false`、`maxLines`、`align` | bold 使用 w600，指定 maxLines 后溢出显示省略号 |
| `Surface` | `child`、`radius: 16`、`padding: [16.0]`、`color` | `onTap`。圆角经过应用形状 token，默认颜色结合当前页面背景 |
| `Button` | `label`、`icon`、`variant`、`enabled: true`、`loading: false`、`fullWidth: false` | `onPressed`。variant 支持 tonal、outlined、text，默认填充按钮。loading 时显示进度并禁用；fullWidth 填满父级分配的宽度，在 Row 中应包入 Expanded |
| `IconButton` | `icon`、可选 `child`、`tooltip`、`enabled: true`、`loading: false`、可选 `selected` | `onPressed`。加载或禁用时不能点击；选中图标使用实心填充。`iconButtonContent` 能力允许用 `child` 替换图标，例如 `Avatar(size: 28)`，保留按钮触区、提示、键盘焦点和禁用语义。未知图标使用 extension，省略回调时禁用 |
| `Symbol` | `name`、`size`、`color` | 未知图标使用 extension |
| `Image` | `url`、`width`、`height`、`fit: cover`、`radius: 0`、`preview: false` | HTTPS 匿名加载，跳转逐跳校验图片权限，HTTP 地址先升级 HTTPS。支持位图和静态 SVG，失败后可点击重试。响应最多 16 MiB，位图解码尺寸受组件限制 |
| `Statistics` | `items: [{value, label}]`，最多 12 项；`loading: false` | 数字与标签自动分列，大字与窄屏换行。加载期间显示骨架，不把未知值当作 0。无内置点击行为，可放在整卡入口中 |
| `Amount` | `value`、`unit`、`original`、`style: titleLarge`、`color` | 主题金额，原值删除线，空间不足时换行；值由插件格式化 |
| `QuantityInput` | `value`、`min: 1`、`max: 9999`、`enabled: true` | `onChanged` 回传 `{value: number}`，边界禁用增减；脚本回写 value |
| `Markdown` | `text`，最多 131072 字符 | 标题、列表、表格、代码、强调与链接，原始 HTML 作为文本。图片通过插件图片出口；`onLink` 仅在点击时回传 `{url}` |
| `CopyButton` | `text`、`label` | 点击后复制并显示应用提示；空文本禁用，不读取剪贴板 |
| `ListItem` | `title`、`subtitle`、`leading`、`trailing` | `onTap`，空 subtitle 隐藏 |
| `Divider` | 无参数 | 高度 1 的分隔组件 |
| `Skeleton` | `child` | 原生骨架容器，禁用子树交互与重复朗读，跟随减少动画设置；声明 `loadingPlaceholders` |
| `SkeletonBox` | `width`、`height: 16`、`radius: 4` | 骨架块使用主题颜色和圆角；与 Skeleton 组合描述内容轮廓 |
| `Spinner` | `size: 32` | 应用统一加载指示器 |
| `ProgressBar` | 可选 `value` | 数值限制在 0–1，省略时为不定进度 |
| `Chip` | `label`、`color: secondaryContainer`、`textColor: onSecondaryContainer` | 状态文字标签 |
| `Gap` | `size: 8` | 宽高相等的空白 |
| `Toggle` | `value: false` | `onChanged` 追加 `{value: bool}` |
| `SearchInput` | `value: ""`、`hint` | `onChanged`、`onSubmitted` 追加 `{value: string}`。清空按钮同时触发两者，提交后收起输入焦点 |
| `TextInput` | `value: ""`、`label`、`hint`、`obscure: false`、`minLines`、`maxLines: 1`、`maxLength`、`variant: "standard"`、`enabled: true`、`readOnly: false`、`showCounter: true` | `onChanged`、`onSubmitted` 追加 `{value: string}`。obscure 强制单行；`filled` 使用公共输入框外壳；设置 minLines 后随输入增高。扩展选项要求 `inputOptions` |

`Label.style` 支持 displaySmall、headlineLarge、headlineMedium、headlineSmall、titleLarge、titleMedium、titleSmall、bodyLarge、bodyMedium、bodySmall、labelLarge、labelMedium、labelSmall。

颜色 token 支持 primary、secondary、tertiary、error 及其 onX、XContainer、onXContainer，另有 surface、onSurface、onSurfaceVariant、surfaceContainerLowest、surfaceContainerLow、surfaceContainer、surfaceContainerHigh、surfaceContainerHighest、outline、outlineVariant。

图标名支持 add、arrow_forward、bolt、bookmark、calendar、chart、check、check_circle、chevron_right、close、cloud、code、copy、credit_card、delete、done_all、download、edit、error、extension、favorite、flag、gift、group、history、home、hub、image、info、key、link、lock、mail、notifications、open_in_new、payments、person、public、refresh、schedule、search、settings、share、shopping_cart、star、storefront、sync、tag、thumb_up、thumb_down、token、trending_up、verified、visibility、wallet、warning。

## 页面标题栏

声明 `pageChrome` 后，`pages[].appBar` 可用 `title`、`actions` 引用界面文件内的组件。普通页、底栏页和弹层使用同一契约；标题栏和正文共享 `data`、`ctx.surface` 与用户事件，不会额外触发 `page.open`。省略 title 时使用清单的页面标题。

```json
{"id":"items","widget":"Items","title":"列表","scroll":false,
 "appBar":{"title":"PageTitle","actions":"PageActions"}}
```

```text
widget PageTitle = Label(text: data.title, maxLines: 1);
widget PageActions = Row(mainAxisSize: "min", children: [
  IconButton(icon: "favorite", tooltip: "收藏", selected: data.saved,
    loading: data.saving, onPressed: event "save" {}),
]);
```

返回、关闭、拖柄及安全区由宿主保留，插件不能覆盖。操作区域最多占当前页面宽度的一半，超出后横向滚动；标题栏组件高度受标准栏高约束。标题组件应控制行数，操作组件使用内容宽度的 Row。搜索、分类等较高内容可继续放到 `toolbar`，底部主操作放 `footer` / `actions`。应用开发中心提供可点击的标题栏演示。

从链接打开的页面，未提供自定义操作区时由宿主显示浏览器入口。声明 `appBar.actions` 后由插件决定操作区内容，需要网页入口时调用 `browser.open`，宿主不再重复添加同类按钮。

## 网格布局

`TileGrid.layout` 可选 `natural`（默认，逐行排列并保留各项高度）、`equalHeight`（同排补齐至最高项）和 `masonry`（下一项放入当前最短列）。布局根据组件实际尺寸计算，内容更新及窗口宽度变化后重新排列，支持从右向左的界面方向。等高针对卡片整体，卡片内部的文字行数与内容对齐由内部组件控制。

`columns` 为正整数时指定列数。设为 0 或省略时，若 `minTileWidth > 0`，按最小项宽度自适应列数；否则延续默认断点，宽度 720 及以上三列、320 及以上两列，其余一列。`spacing` 和 `runSpacing` 分别设置水平、垂直间距，接受非负数。窄于最小项宽度时使用单列。

```text
TileGrid(
  layout: "equalHeight",
  minTileWidth: 150.0,
  spacing: 12.0,
  runSpacing: 16.0,
  children: [...for item in data.items: Surface(child: Label(text: item.title))],
)
```

网格由页面滚动容器承载，当前会布局所有已加载项。长列表应结合分页控制数据量。应用内 TileGrid 文档可实时切换三种布局、列数和间距。

## rfw 基础组件

这些组件来自仓库锁定的 rfw 2.0.0。表中列出构造参数，默认行为沿用该版本的 core widgets。复杂样式参数的编码由 rfw `ArgumentDecoders` 定义。[rfw 2.0.0](https://pub.dev/packages/rfw/versions/2.0.0)

| 组件 | 参数 |
| --- | --- |
| `Align` | alignment、widthFactor、heightFactor、child，加通用动画参数 |
| `AspectRatio` | aspectRatio，默认 1.0，child |
| `Center` | widthFactor、heightFactor、child |
| `ClipRRect` | borderRadius、clipBehavior、child |
| `ColoredBox` | color 为 ARGB 整数、child |
| `Column` | children、mainAxisAlignment、mainAxisSize、crossAxisAlignment、textDirection、verticalDirection、textBaseline |
| `Row` | 与 Column 相同 |
| `DefaultTextStyle` | style、textAlign、softWrap、overflow、maxLines、textWidthBasis、textHeightBehavior、child，加通用动画参数 |
| `Directionality` | textDirection，默认 ltr，child |
| `Expanded` | flex，默认 1，child。放置在 Row 或 Column 中 |
| `Flexible` | flex，默认 1，fit，默认 loose，child |
| `FittedBox` | fit、alignment、clipBehavior、child |
| `FractionallySizedBox` | alignment、widthFactor、heightFactor、child |
| `GestureDetector` | behavior、child，以及 onTap、onTapDown、onTapUp、onTapCancel、onDoubleTap、onLongPress 事件。回调只传声明参数 |
| `GridView` | children、gridDelegate，加通用列表参数 |
| `IntrinsicHeight` | child |
| `IntrinsicWidth` | width、height、child。width 和 height 对应 Flutter 的 stepWidth 和 stepHeight |
| `ListBody` | mainAxis、reverse、children |
| `ListView` | children、itemExtent、prototypeItem，加通用列表参数 |
| `Opacity` | opacity，默认 0.0，alwaysIncludeSemantics、child，加通用动画参数 |
| `Padding` | padding、child，加通用动画参数 |
| `Positioned` | start、top、end、bottom、width、height、child，加通用动画参数。使用方向性起止边 |
| `Rotation` | turns、alignment、filterQuality、child，加通用动画参数 |
| `SafeArea` | left、top、right、bottom、minimum、maintainBottomViewPadding、child |
| `Scale` | scale、alignment、filterQuality、child，加通用动画参数 |
| `SingleChildScrollView` | scrollDirection、reverse、padding、primary、dragStartBehavior、clipBehavior、restorationId、keyboardDismissBehavior、child |
| `SizedBox` | width、height、child |
| `SizedBoxExpand` | child |
| `SizedBoxShrink` | child |
| `Spacer` | flex，默认 1 |
| `Stack` | alignment、textDirection、fit、clipBehavior、children |
| `Text` | text、style、strutStyle、textAlign、textDirection、locale、softWrap、overflow、textScaleFactor、maxLines、semanticsLabel、textWidthBasis、textHeightBehavior |
| `Wrap` | direction、alignment、spacing、runAlignment、runSpacing、crossAxisAlignment、textDirection、verticalDirection、clipBehavior、children |

通用动画参数为 `duration`、`curve`、`onEnd`。通用列表参数为 `scrollDirection`、`reverse`、`primary`、`shrinkWrap`、`padding`、`addAutomaticKeepAlives`、`addRepaintBoundaries`、`addSemanticIndexes`、`cacheExtent`、`semanticChildCount`、`dragStartBehavior`、`keyboardDismissBehavior`、`restorationId`、`clipBehavior`。

生产界面优先使用宿主组件承载文本、表单、图片和操作，基础组件用于布局。列表或网格需要明确约束，避免在无界滚动区域放置 Expanded。所有布局都应检查窄屏、大字体、键盘弹出和底部安全区域。

## 页面与表单

`ListPage`、`DetailPage` 和 `FormPage` 管理自己的滚动区域，清单页面设 `scroll: false`。`ListPage.actions` 和 `DetailPage.actions` 接收单个组件，通常使用 `ActionBar`。`FormPage.actions` 接收组件列表，在提交按钮前展示附加操作。附加操作的禁用状态由插件传入。

列表的 `items` 是条目组件列表。空列表会显示加载、错误或空态，非空列表在刷新时保留当前条目。声明 `onLoadMore` 后，`hasMore: true` 显示加载更多按钮，`loadingMore: true` 显示分页进度，`hasMore: false` 显示末尾提示。`PageLayout` 和 `ListPage` 会在向下滚动至距离底部 240 像素内触发 `onLoadMore`。内容不足一屏时继续上滑也会触发。加载期间以及错误、末页状态暂停自动分页。插件应在请求开始和结束时更新 `loading` 或 `loadingMore`，并负责页码、追加数据和请求去重，`ListPage` 分页请求失败时通过 `error` 与 `onRetry` 提供恢复入口，`PageLayout` 使用 `loadMoreError` 暂停自动分页并由插件提供重试操作。

表单字段使用以下结构。

| 字段 | 说明 |
| --- | --- |
| `name` | 必填且唯一的非空字符串，用于提交结果的键 |
| `label`、`hint` | 显示名称与输入提示，label 默认使用 name |
| `type` | text、multiline、password、toggle、choice，默认 text |
| `value` | toggle 使用布尔值，其他类型使用字符串。choice 的值必须存在于 options 中，否则清空选择 |
| `required` | 默认 false。必填文本去除首尾空白后不能为空，必填开关需要开启，必填选择需要选中 |
| `maxLength` | 可选正整数，按用户感知字符数量校验文本长度 |
| `error` | 服务端字段错误，非空时显示并阻止提交。插件处理完错误后清空该值 |
| `options` | choice 的选项列表，每项包含唯一字符串 value 和可选 label |

```text
import fluxdo;

widget Settings = FormPage(
  resetKey: data.resetKey,
  loading: data.saving,
  fields: [
    {name: "title", label: "名称", value: data.title, required: true, maxLength: 40},
    {name: "notes", label: "备注", type: "multiline"},
    {name: "enabled", label: "启用提醒", type: "toggle", value: true},
    {name: "frequency", label: "频率", type: "choice", value: "daily",
      options: [{value: "daily", label: "每天"}, {value: "weekly", label: "每周"}]},
  ],
  onChanged: event "field.changed" {},
  onSubmit: event "settings.save" {},
);
```

`onSubmit` 的 `args.values` 包含所有当前字段。表单内部保留用户编辑，脚本更新 loading 或其他无关状态不会覆盖输入。脚本显式改变字段 value 会更新该字段，改变 resetKey 会按声明值重置整个表单。删除字段后，该字段也会从提交结果移除。

password 字段用于插件自己的业务输入。LDC 支付调用 `payments.request`，支付密码与生物识别由应用收银台管理。详情、列表、表单与操作区的颜色和形状沿用应用主题。

## `GridPage`

面向长网格的页面组件。与 `TileGrid` 相同的参数：`layout`（natural/equalHeight/masonry，默认 natural）、`columns`（0 为响应式）、`minTileWidth`、`spacing`、`runSpacing`。列数与宽度来自当前可用空间，支持 RTL。

`items` 是卡片组件列表；`header` 是随内容滚动的筛选或搜索区域；`actions` 是固定底部操作区。`loading`、`error`、`emptyTitle` 控制首次加载/错误/空态；`hasMore`、`loadingMore`、`moreLabel` 控制分页。事件：`onRefresh`、`onRetry`、`onLoadMore`。上滑接近底部时自动请求下一页，同一请求期间不会重复触发，分页失败停止自动加载并显示重试。

自然高度和等高模式按可见行构建；瀑布流按可见卡片构建。默认视口预取可提前构建少量卡片。页面清单使用 `scroll:false`，避免与外层滚动嵌套。网格本身必须获得有限页面高度才能虚拟化。

```rfw
widget Market = GridPage(layout: "equalHeight", minTileWidth: 150.0,
  loading: data.loading, hasMore: data.more, loadingMore: data.loadingMore,
  error: data.error, onRefresh: event "refresh" {}, onRetry: event "retry" {},
  onLoadMore: event "more" {},
  items: [...for item in data.items: Surface(child: Label(text: item.title))],
);
```
## 自适应集合视图

声明 `adaptiveCollections` 后，可用 `AdaptivePane` 布置名单与内容。页面设置 `scroll: false`，用 `compactHeader` 放窄屏筛选栏，`sidebar` 放宽屏名单，`body` 放 `ListPage`。`masterWidth` 和 `minDetailWidth` 按当前可用空间决定何时并排。`ListPage.empty` 可放带操作按钮的空态，首次打开就能引导用户添加内容。

`ContentRow` 可组合 `leading`、`meta`、`title`、`summary` 和 `detail`。`Avatar` 按宿主图片权限加载，加载失败显示名称首字。传入正整数 `count` 会显示角标，零会隐藏角标。`RelativeTime` 接受 UTC 时间并跟随应用的相对时间显示，`Choice.leading` 可放头像或图标。

## 固定工具区与卡片入口

`PageLayout`、`ListPage`、`DetailPage`、`GridPage` 的 `toolbar` 固定在内容区上方，适合搜索和分类。普通 `header` 随列表滚动。工具区最高占页面 45%，大字下内部可滚动；`footer` / `actions` 放主要操作。

`Image(preview: true)` 和 Markdown 图片点击后使用应用公共图片查看器，支持双击缩放、拖动关闭、保存及平台支持的分享操作。首次预览复用图片现有的加载请求，重试仍通过插件的图片权限与网络出口；查看器和导出操作只消费图片字节，不另行按 URL 下载或附带论坛凭据。SVG 以静态位图预览和导出，不执行脚本或加载外链子资源。上述展示能力需要声明 `requiredFeatures: ["contentPresentation"]`。

正式安装的插件不必自行保存图片。`Image`、`Avatar` 和 Markdown 里的图片共用宿主缓存，按插件来源和当前账号隔离；重新打开页面或应用时，未过期的图片可直接显示。宿主先核对图片权限，命中时不做网络请求。默认保留 24 小时，有效期服从服务器且最长 7 天。带查询参数的地址（可能含临时签名）、经过重定向的响应以及要求 `no-store`、`no-cache` 或 `private` 的响应只复用正在进行的请求。手动重试会重新下载。清除插件数据或卸载会移除该插件的图片；设置里的「外部图片」可一次清理所有插件图片。此机制不缓存脚本的 `fetch` 响应。

清单可声明 `card: {"widget":"Card", "page":"home"}` 并包含 `cardNavigation` 必需能力。`page` 必须指向普通页面。宿主使整张卡片可点击，卡片内部的按钮和更多菜单仍独立响应。`Card` 的内容仍由插件任意组合组件；例如只放 `Statistics(items: data.stats)`，不必再放一个“进入”按钮。未声明 `page` 的历史卡片行为不变。

## 加载与刷新

声明 `loadingPlaceholders` 后，首次取数可用 `Skeleton` 与 `SkeletonBox` 按内容布局组合占位，`ListPage` 和
`GridPage` 的 `loadingPlaceholder` 接收这一组件。已有条目时忽略占位，继续显示原列表。
`loading` 表示请求仍在进行，结束请求后必须还原为 false；不要在同一份数据刷新时先清空条目。
只有账号、筛选等内容身份变化时才清空旧内容。报价等局部请求在对应区域显示占位，不在整页顶部增加加载块。

页面滚动区延伸至系统手势区域，末尾 padding 保护最后一项；固定底部操作在手势区域上方。
空的底部插槽不会保留操作栏间距。普通声明式页面由宿主提供安全间距，不需要再包整页 SafeArea。

### 时间线

`TimelinePage` 接收从新到旧排列的 `items`，并以相同顺序传入唯一、稳定的字符串 `itemKeys`。最新项位于屏幕底部，追加历史放在数组末尾。组件只负责显示、定位与分页触发；网络协议、消息身份和发送资格均由插件负责。清单页面使用 `scroll: false`，不要再套滚动容器。

更换会话或查询时修改 `identity`，以重置定位。位于最新位置时自动跟随内容与键盘高度变化；正在查看历史时保留可见条目的位置，显示“回到最新”按钮。主动发送成功等操作可递增 `endRevision` 回到末尾，轮询、加载历史和只读刷新不应修改它。移除正在阅读的条目时只能保留其余可见条目的位置，不保证已经被删除的锚点。

向历史方向滑动到边界时触发 `onLoadMore`，内容不足一屏也支持继续滑动。插件需回写 `loadingMore`、`hasMore` 和 `error`，失败不会循环请求。初次加载可提供等高的 `loadingPlaceholder`，空态和错误通过 `emptyTitle`、`error`、`onRetry` 呈现。

`footer` 复用统一底部背景、最大宽度及安全区，不应再加一层整栏内边距。多行编辑建议使用 `TextInput(variant: "filled", minLines: 1, maxLines: 4, maxLength: 500)`；发送期间可设 `readOnly: true` 保留焦点和草稿，避免禁用输入导致键盘收起。`maxLength` 按用户可见字符限制，业务仍需校验服务端长度规则。
