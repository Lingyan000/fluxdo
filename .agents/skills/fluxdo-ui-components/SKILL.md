---
name: fluxdo-ui-components
description: 编写或修改 FluxDO 页面、弹窗、列表和设置项时，选用项目公共组件并接入页面背景、主题与节日装饰。涵盖路由弹层、加载状态、控件、内容展示和自适应布局。
---

# FluxDO 公共组件

实现界面前，按场景查找下面的公共入口，再阅读对应组件的构造参数和现有调用。新代码优先复用已有能力，选型时核对所需交互、语义和布局是否受支持。

## 组件位置

| 位置 | 内容 | 依赖 |
|---|---|---|
| `packages/common_ui` | 路由、弹层外壳、菜单、空态、形状与强调 token、页面背景、玻璃材质 | Flutter、app_icons |
| `packages/m3e_ui` | 加载、进度、按钮组、开关、导航栏、下拉刷新、分段卡片 | Flutter、common_ui、material_new_shapes |
| `lib/widgets/common` 等 | 带模糊的弹层入口、头像、图片、提示、错误页、应用布局 | 应用能力 |

跨包组件从包入口导入。新增公共组件按依赖方向放置并导出，应用提供的装饰或背景可通过 `UiDecor`、`PageBackgroundScope` 注入。两个包的公开入口分别见 [common_ui.dart](../../../packages/common_ui/lib/common_ui.dart) 和 [m3e_ui.dart](../../../packages/m3e_ui/lib/m3e_ui.dart)。

## 路由与弹层

| 场景 | 公共入口 | 接入要点 |
|---|---|---|
| 打开页面 | `InteractionPageRoute` / `InteractionPageRouteBuilder` | 接入统一的路由输入策略和页面背景 |
| 应用内对话框 | `showAppDialog` | 跟随背景模糊偏好，入口在 `lib/utils/dialog_utils.dart` |
| 包内对话框 | `showInteractionDialog` | 由 common_ui 提供统一交互 |
| 统一外壳的底部弹框 | `AppBottomSheet.show` / `showDraggable` | 自动套 `AppSheetScaffold`，包含标题、拖拽条与键盘处理 |
| 自定义外壳的底部弹框 | `showAppBottomSheet` | 调用方提供外壳和内容 |
| 弹出菜单 | `SwipeDismissiblePopupMenuButton` / `showSwipeDismissibleMenu` | 支持滑动菜单外空白区域关闭 |

路由与弹窗入口约定见 [AGENTS.md](../../../AGENTS.md)，对应守卫为 `test/architecture/interaction_entry_points_test.dart`。

- `AppBottomSheet.showDraggable` 的 `bodyBuilder` 收到的 `scrollController` 要传给内容滚动组件，才能联动拖拽缩放。表单可选 `AppSheetStyle.card`，该形态关闭下滑退出。参数见 [app_bottom_sheet.dart](../../../lib/widgets/common/app_bottom_sheet.dart)。
- 关闭根层弹框时使用弹框自己的 context，或显式选择 `rootNavigator`，让关闭操作落到承载弹框的 Navigator。
- 弹框专用 controller 由弹框 State 持有并在 `dispose` 中释放，覆盖退场动画仍在使用它的阶段。

## 页面状态、加载与刷新

| 场景 | 组件 | 接入要点 |
|---|---|---|
| 加载中到内容 | `AppLoadingSwitcher` | 传入 `loading`、`identity`、`loadingBuilder`、`child`，同一内容刷新时保留子树和滚动位置 |
| 空态 | `AppEmptyState` | `icon` 是 Widget，`title` 是必填文字，`message` 和 `action` 可选 |
| 双栏详情区空态 | `MasterDetailEmptyState` | 窗格背景由 `MasterDetailLayout` 统一铺设 |
| 错误页 | `ErrorView` | 提供错误信息、详情与重试入口 |
| 骨架屏 | `Skeleton` + `SkeletonBox` | 复用相应业务列表已有的骨架布局 |
| 分页列表底部 | `PagedListFooter` | 统一分页加载、错误与末尾提示 |
| 不定进度加载 | `LoadingSpinner` | M3E 关闭时自动回退转圈 |
| 确定进度 | `M3eCircularProgress` / `M3eLinearProgress` | 传入实际进度，线性组件也支持不定进度 |
| 下拉刷新 | `M3eRefreshIndicator` | 支持 `show()` 和二级动作，M3E 关闭且无二级动作时回退原生刷新 |

`AppLoadingSwitcher.identity` 应包含账号、查询等内容身份。错误和空结果通过 `child` 呈现，结束请求后同步更新 `loading`。组件实现见 [app_content_state.dart](../../../packages/common_ui/lib/src/app_content_state.dart)。

`UiDecor.cornerBadge` 由 `AppEmptyState` 消费，`UiDecor.loadingIndicator` 由 M3E 刷新圆片消费。普通 `LoadingSpinner` 和原生刷新回退分支使用各自的加载动画。应用级节日接入见 [fluxdo-theme](../fluxdo-theme/SKILL.md)。

## 控件

| 场景 | 组件 | 接入要点 |
|---|---|---|
| 联排单选按钮 | `M3eButtonGroup` + `M3eButtonGroupItem` | `selected` 为单个值，异步 `onSelected` 返回对应 Future，组件据此确认选择生效并反馈 |
| 开关、开关行 | `M3eSwitch` / `M3eSwitchListTile` | 开关行统一处理整行点击、语义节点和键盘焦点 |
| 自绘元素的按压反馈 | `M3eElasticPress` | 点击和语义仍由原控件负责 |
| FAB 展开菜单 | `M3eFabMenu` | 复用展开与收起交互 |
| M3E 底部导航 | `M3eNavigationBar` | 指示器跟随主题，应用主导航通过 `AdaptiveScaffold` 接入 |
| 动画曲线 | `M3eMotion` | 位置、尺寸、形状优先用 spatial，颜色、透明度优先用 effects |

`M3eButtonGroup` 是单选接口，多选需求先核对组件能力。M3E 的开关与回退由组件读取 `M3eFlags` 处理，调用方可直接使用公共入口。接口见 [m3e_button_group.dart](../../../packages/m3e_ui/lib/src/m3e_button_group.dart)。

## 分组列表与设置页

- 分组列表用 `SegmentedCardGroup` / `SegmentedCardItem`，由 `SegmentedCardStyle` 决定分段、描边或平铺。组装 children 前过滤隐藏项，让首尾圆角落在可见条目上。
- 懒加载列表里的分组（如首页置顶分组）逐项使用 `SegmentedCardItem(index:, count:, gap:)`，底色、圆角、分隔线和描边外框都由它按模式绘制，不再手写「整卡 + Divider」。条目内的按压面用 `SegmentedCardItem.borderRadiusOf` 对齐形状，`MorphingDialogAnchor` 等需要间距的地方用 `SegmentedCardItem.gapOf` 取当前模式的实际间距。参考 [pinned_topics_header.dart](../../../lib/widgets/topic/pinned_topics_header.dart)。
- 设置项在 `lib/settings/definitions/` 中使用 `SettingsGroup` 和 `SwitchModel`、`ActionModel`、`DoubleSliderModel`、`IntSliderModel`、`CustomModel` 描述，再交给 `SettingsGroupPage` 渲染。每项 `id` 用于搜索与 `highlightId` 定位，需要唯一。模型见 [settings_model.dart](../../../lib/settings/settings_model.dart)。
- 外观设置的条目 id 同步加入对应 `AppearanceSection.settingIds`，分区页面依赖这份映射筛选条目。入口见 [appearance_layout.dart](../../../lib/settings/definitions/appearance_layout.dart)。

## 外观与页面背景

- 圆角、图标强调色和表面色按主题 token 选取。自绘顶栏可用 `TopBarIconScope` 接入顶栏图标颜色，具体选型见 [fluxdo-theme](../fluxdo-theme/SKILL.md)。
- 话题卡片和正文等阅读内容用 `PageBackgroundScope.contentColor(context, 原有底色)`，背景启用时透出整页背景。选中与高亮色在该底色上叠加，骨架屏与加载后的内容使用一致的背景策略。
- 可收起标题栏、吸顶条和窗格底等区域需要遮住滚动内容时，用 `PageBackdrop(child: ...)` 绘制对齐整页的背景副本。无 child 的用法需要父级提供有限宽高，例如 `Positioned.fill`。实现见 [page_background.dart](../../../packages/common_ui/lib/src/page_background.dart)。
- `UiDecor` 由应用宿主注入装饰 builder，组件消费插槽。builder 保持稳定引用，减少无关重建。接口见 [ui_decor.dart](../../../packages/common_ui/lib/src/ui_decor.dart)。
- 玻璃材质按场景选 `GlassRecipe`，导航类外壳用 `GlassSurfaceFrame` 统一裁切、阴影和边缘光。

## 内容展示

| 场景 | 组件或入口 |
|---|---|
| 用户头像 | `SmartAvatar`，支持缓存直寻址、动图头像和 SVG |
| 网络图片 | `CachedImage`，按格式和目标尺寸选择解码路径 |
| 带 `:emoji:` 的短文本 | `EmojiText` |
| 相对时间 | `RelativeTimeText`，使用全局分钟心跳，长按显示精确时间 |
| 分类、标签色 | `ColorUtils.category(hex, theme)` |
| 轻提示 | `ToastService.showSuccess` / `showError` / `showInfo` |
| 带操作的提示 | `ToastService.show`，传入 `actionLabel` 与 `onAction` |
| 下载提示 | `ToastService.showDownload`，通过返回的 handle 更新进度与结果 |

展示组件位于 `lib/widgets/common/`，提示入口见 [toast_service.dart](../../../lib/services/toast_service.dart)。

## 布局与交互生命周期

- `AdaptiveScaffold` 负责手机底栏、宽屏侧栏及切换时的 body 保留。
- `MasterDetailLayout` 负责双栏和窄屏投影，窗格背景与空态按其类注释接入。
- `KeyboardInsetIsolation` 隔离后台常驻页的键盘尺寸变化，宿主传入 `active`，双栏可用 `requireFocus` 限定跟随键盘的窗格。
- `RouteMotionHoldMixin` 在转场期间暂缓展示更新。`identity` 包含内容身份，业务订阅和请求仍正常更新。窗格转场通过 `PageMotionScope` 提供相同信号。
- `InteractionGate.enabled` 在关闭确认时更新，让退场层及时让出输入。
- 横向滚动边缘渐隐可用 `FadingEdgeScrollView`。

## 验证

选择受影响组件的现有测试，并按仓库约定执行 analyze。检查实际入口中的加载、空态、错误、选中与禁用状态，以及当前改动涉及的明暗主题、自定义背景和布局切换。组件 API 与本指南有差异时，以源码签名和调用处为准并同步修正文档。
