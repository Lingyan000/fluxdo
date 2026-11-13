# 原生组件参考

注册表位于 [metaverse_widget_library.dart](../../lib/modules/metaverse/plugin/ui/metaverse_widget_library.dart)。当前提供 24 个宿主组件和 33 个 rfw 基础组件。界面文件使用 `import fluxdo;`。应用内开发中心提供每个宿主组件的真实预览、参数调整与事件记录。

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
| `PageLayout` | `children`、可选 `footer`、`loading: false` | `onRefresh`。有界页面提供滚动内容和底部操作区域，最大内容宽度 960。刷新完成需把 loading 改回 false |
| `ListPage` | `items`、可选 `search`、`header`、`actions`、`emptyTitle`、`error`、`loading: false`、`hasMore: false`、`loadingMore: false`、`moreLabel` | `onRefresh`、`onRetry`、`onLoadMore`。分组列表按需构建，可点击加载更多，刷新保留已有条目 |
| `DetailPage` | `sections`、可选 `header`、`actions`、`emptyTitle`、`error`、`loading: false` | `onRefresh`、`onRetry`。分区间距与底部操作由页面管理，刷新保留已有内容 |
| `FormPage` | `fields`、`resetKey: ""`、`loading: false`、可选 `header`、`actions`、`submitLabel` | `onChanged` 回传 `{field, value}`，校验通过后 `onSubmit` 回传 `{values}`。加载期间禁用输入与提交 |
| `ActionBar` | `actions` 组件列表 | 操作靠右排列，窄屏自动换为纵向；事件由内部按钮声明 |
| `TileGrid` | `children` | 按可用宽度选择列数，720 及以上三列，320 及以上两列，其余一列，间距 12 |
| `Choice` | `label`、`selected: false` | `onSelected`，事件沿用声明参数，选择值由脚本管理 |
| `EmptyState` | `title`、可选 `message`、`icon`、`action` | 空内容或错误状态，默认购物袋图标，通用场景建议指定 icon |
| `SelectableLabel` | `text` | 可选择复制的 bodyMedium 文本 |
| `Label` | `text`、`style: bodyMedium`、`color`、`bold: false`、`maxLines`、`align` | bold 使用 w600，指定 maxLines 后溢出显示省略号 |
| `Surface` | `child`、`radius: 16`、`padding: [16.0]`、`color` | `onTap`。圆角经过应用形状 token，默认颜色结合当前页面背景 |
| `Button` | `label`、`icon`、`variant`、`enabled: true`、`loading: false` | `onPressed`。variant 支持 tonal、outlined、text，默认填充按钮。loading 时显示进度并禁用 |
| `IconButton` | `icon`、`tooltip` | `onPressed`。未知图标使用 extension，省略回调时禁用 |
| `Symbol` | `name`、`size`、`color` | 未知图标使用 extension |
| `Image` | `url`、`width`、`height`、`fit: cover`、`radius: 0` | HTTPS 匿名加载，跳转逐跳校验图片权限，HTTP 地址先升级 HTTPS。支持位图和静态 SVG，失败后可点击重试。响应最多 16 MiB，位图解码尺寸受组件限制 |
| `ListItem` | `title`、`subtitle`、`leading`、`trailing` | `onTap`，空 subtitle 隐藏 |
| `Divider` | 无参数 | 高度 1 的分隔组件 |
| `Spinner` | `size: 32` | 应用统一加载指示器 |
| `ProgressBar` | 可选 `value` | 数值限制在 0–1，省略时为不定进度 |
| `Chip` | `label`、`color: secondaryContainer`、`textColor: onSecondaryContainer` | 状态文字标签 |
| `Gap` | `size: 8` | 宽高相等的空白 |
| `Toggle` | `value: false` | `onChanged` 追加 `{value: bool}` |
| `SearchInput` | `value: ""`、`hint` | `onChanged`、`onSubmitted` 追加 `{value: string}`。清空按钮同时触发两者，提交后收起输入焦点 |
| `TextInput` | `value: ""`、`label`、`hint`、`obscure: false`、`maxLines: 1` | `onChanged`、`onSubmitted` 追加 `{value: string}`。obscure 强制单行 |

`Label.style` 支持 displaySmall、headlineLarge、headlineMedium、headlineSmall、titleLarge、titleMedium、titleSmall、bodyLarge、bodyMedium、bodySmall、labelLarge、labelMedium、labelSmall。

颜色 token 支持 primary、secondary、tertiary、error 及其 onX、XContainer、onXContainer，另有 surface、onSurface、onSurfaceVariant、surfaceContainerLowest、surfaceContainerLow、surfaceContainer、surfaceContainerHigh、surfaceContainerHighest、outline、outlineVariant。

图标名支持 add、arrow_forward、bolt、bookmark、calendar、chart、check、check_circle、chevron_right、close、cloud、code、copy、credit_card、delete、download、edit、error、extension、favorite、gift、group、history、home、hub、image、info、key、link、lock、mail、notifications、open_in_new、payments、person、public、refresh、schedule、search、settings、share、shopping_cart、star、storefront、sync、tag、token、trending_up、verified、visibility、wallet、warning。

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

列表的 `items` 是条目组件列表。空列表会显示加载、错误或空态，非空列表在刷新时保留当前条目。声明 `onLoadMore` 后，`hasMore: true` 显示加载更多按钮，`loadingMore: true` 显示分页进度，`hasMore: false` 显示末尾提示。插件负责页码、追加数据和请求去重，分页请求失败时通过 `error` 与 `onRetry` 提供恢复入口。

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
