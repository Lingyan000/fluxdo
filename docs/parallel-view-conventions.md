# 平行视界（Master-Detail）接入约定

> 摘要版见 `lib/widgets/layout/master_detail_layout.dart` 顶部 dartdoc。
> 本文是长版：约定 + 背后的翻车案例，新页面接入平行视界前先读一遍。

## 架构速览

- **双栏容器**：`MasterDetailLayout`（`lib/widgets/layout/master_detail_layout.dart`）
  负责宽度判定（`canShowBothPanesFor`）、拖拽分隔、detail 槽铺底与默认空态。
- **导航栈**：detail 区**不是**嵌套 Navigator，而是每个宿主页各自一份
  `SelectedTopicProvider` 状态栈（`lib/providers/selected_topic_provider.dart`）,
  栈内可混插 `PaneKind { topic, profile, settings }`。
- **嵌入作用域**：`EmbeddedStackScope`（InheritedWidget）标记"当前 context
  处在哪个面板的栈里"，正文链接点击等统一靠它路由。
- **窄屏回落**：窄屏用真正的 `Navigator.push` 全屏页；宽窄切换由
  `_maybePushDetail` / `AutoRestoreMasterDetailRoute` 双向衔接。

现有宿主：首页（`selectedTopicProvider`）、私信（`selectedMessageProvider`）、
搜索（`selectedSearchProvider`）、追觅（`selectedSeekingProvider`）、
草稿（`selectedDraftPaneProvider`）、「我的」右栏
（`selectedProfilePaneProvider`，容器暂为手写 Row）。

## 约定

### 1. 背景与空态

- detail 槽的背景由 `MasterDetailLayout` 统一铺 `scaffoldBackgroundColor`，
  **页面不要自己包 ColoredBox**。
- 自定义空态（`emptyDetail`）一律用 `MasterDetailEmptyState`，只定制
  icon / message / iconSize，不要自己拼 Center/Column。

> 翻车案例：内置空态曾是裸 `Center` 无铺底，桌面 acrylic/mica 下与左栏
> Scaffold 形成半透明色差断层（私信页最明显）；搜索页自己包 ColoredBox
> 修了但没下沉，三处空态三种样式。

### 2. detail 面板的 onBack

标准写法（回调内重读 provider，不闭包捕获 build 快照）：

```dart
onBack: () {
  final n = ref.read(provider.notifier);
  ref.read(provider).isStacked ? n.pop() : n.clear();
},
```

- 压栈时退一层;基础层（栈仅一层）清空右栏回空态。
- **不要**传 `isStacked ? pop : null`——基础层 ESC/返回会变成空操作，
  与其他宿主行为割裂（首页/私信曾如此，seeking 能关，用户视角就是
  "有的页面 ESC 能关有的不行"）。

### 3. 嵌入判定：scope，不是屏宽

判断"我是否处在嵌入面板里"**只有一个正确姿势**：

```dart
final scopeProvider = EmbeddedStackScope.maybeOf(context); // null = 不在
```

- `maybeOf` 走 `getElementForInheritedWidgetOfExactType`，不注册依赖，
  点击回调里调用安全。
- **禁止**用 `canShowBothPanesFor`（屏宽）推断自己是否嵌入：独立成屏的
  页面（底栏 tab / 全屏路由）在宽屏下会被误判为"有右栏"。
- `canShowBothPanesFor` 的唯一用途：**宿主页**决定列表点击该
  `select()` 进右栏还是 `Navigator.push` 全屏。

> 翻车案例：草稿页曾按屏宽分流，独立草稿 tab 里点一条草稿被
> `requestNavDestination(home)` 整屏切到首页——"点草稿=跳首页"。

### 3.1 页面即宿主，不做"寄生层"

一个页面若需要"列表 + 详情"形态，应**自己当宿主**——直接套标准件
`MasterDetailPaneHost`（`lib/widgets/layout/master_detail_pane_host.dart`，
参照 `DraftsPage` / `MyTopicsPage` / `BrowsingHistoryPage`）：传入自己的
`SelectedTopicProvider` 和列表 Widget，双栏组装、ESC 两段式、宽窄切换
自动获得；列表项点击自己按 `canShowBothPanesFor` 分流
（宽屏 `select()`，窄屏全屏 push）。
**不要**把整页塞进别的宿主的平行视界栈里当一层（早先草稿页的
`PaneKind.drafts` 嵌入形态：同一页面在不同宿主里三种表现、
"处理完自动抽层"的栈魔法不可预期，已整体退役）。
`PaneKind` 只保留真正的"详情内容"：topic / profile / settings。

### 4. ESC（closeOverlay）接入三选一

全局 `KeyboardShortcutHandler` 用 `HardwareKeyboard.addHandler` 监听，
**先于** Flutter 焦点管线执行；closeOverlay 在全局层无兜底动作，页面
必须显式接入其一：

| 场景 | 接法 | 参照 |
|---|---|---|
| 嵌入面板层 | `ShortcutScopeBinding(scope: detail)` 注册 closeOverlay → onEmbeddedBack | `TopicDetailPage`、`UserProfilePage` |
| 普通全屏路由 | `RouteEscCloseBinding`（shortcut_provider.dart） | `UserProfilePage` 非嵌入分支（同模式的封装） |
| 快捷键打开的全局路由/弹层 | `pushAppRoute` + `ShortcutSurfaceConfig` | 搜索/设置/新建话题 |

双栏宿主页的"右栏开着时 ESC 关右栏、右栏空了 ESC 关整页"两段式,
统一走 `PaneHostEscBinding`(shortcut_provider.dart):
`MasterDetailPaneHost` 已内置;自组双栏的宿主(首页/私信/追觅)在
build 里调 `_escBinding.sync(context, paneOpen: ...)` 接入。
**双栏宿主页自身必须接入**——detail scope 只在右栏有内容时才有注册,
右栏空态时 ESC 若无 context 层注册就会彻底落空(私信页曾因此 ESC
无效,这是与"跨 tab 串扰"并列的第三个失效根因)。

- **不要**新增 `CallbackShortcuts` / `KeyboardListener` 接 ESC：全局
  handler 先执行，局部实现只有在全局链路全部放行后才收到事件，两边
  同时处理会双 pop。存量局部实现（图片查看器、全屏视频）工作正常，
  不迁移也不模仿。
- 全局兜底 maybePop 已论证否决：同步 handler 无法感知"事件是否会被
  后续管线消费"，必然与自管理页面抢跑。
- 分发规则：焦点面板优先;closeOverlay 特例——activePane 在 master 且
  master 未注册时回退 detail（关右栏），导航动作不回退。
- **IndexedStack 常驻页必须传 enabled 谓词**：底栏 tab 页全部挂在同一
  IndexedStack、共享根路由，路由过滤分不出活跃 tab——非活跃 tab 的
  scope/surface 注册会截胡活跃 tab 的按键（实测：草稿 tab 的注册吞掉
  私信页 ESC；首页嵌入详情霸占 detail scope）。凡是可能被 IndexedStack
  常驻的页面/嵌入面板，注册时必须传 `enabled: () => widget.isActive`
  （嵌入面板用 `() => !embeddedMode || parentActive`），分发端按谓词
  过滤。独立路由页可不传（路由过滤够用）。

## 已知欠账

- 「我的」页右栏是手写 Row，未迁 `MasterDetailLayout`。
- 书签页是独立多标签工作台，不适用本约定。
