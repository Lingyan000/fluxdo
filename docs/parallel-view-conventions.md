# 平行视界（Master-Detail）接入约定

> 摘要版见 `lib/widgets/layout/master_detail_layout.dart` 顶部 dartdoc。
> 本文是长版：约定 + 背后的翻车案例，新页面接入平行视界前先读一遍。
>
> **2026-08 大修**：宽窄衔接从「合成路由顶替」全面改为「同树内联投影」，
> ESC 引入路由级自动兜底，双栏判定扣除 Rail 应占宽。旧机制
> （`_maybePushDetail` / `FullScreenPaneStack` / `RouteEscCloseBinding`）
> 已整体退役，本文按新架构重写。

## 架构速览

- **双栏容器**：`MasterDetailLayout`（`lib/widgets/layout/master_detail_layout.dart`）
  负责宽度判定（`canShowBothPanesFor`）、拖拽分隔、detail 槽铺底与默认空态、
  **窄屏投影态**（`projectDetailWhenNarrow`）。
- **导航栈**：detail 区**不是**嵌套 Navigator，而是每个宿主页各自一份
  `SelectedTopicProvider` 状态栈（`lib/providers/selected_topic_provider.dart`，
  全部具名实例集中定义在该文件），栈内可混插 `PaneKind { topic, profile, settings }`。
- **嵌入作用域**：`EmbeddedStackScope`（InheritedWidget）标记"当前 context
  处在哪个面板的栈里"，正文链接点击等统一靠它路由。
- **宽窄衔接**：**同树内联投影**。栈是唯一真相，宽屏=双栏、窄屏且栈非空=
  详情在宿主体内全宽投影；宽窄切换是同一棵树的布局重排，**不走导航栈**，
  详情/列表的 State（滚动/视频/输入态）原地保留。
- **返回链标准件**：`PaneProjectionBackScope`
  （`lib/widgets/layout/pane_projection_back_scope.dart`）统一承担投影态的
  系统返回 / Android 预测返回跟手 / 与根 PopScope 的协调。

现有宿主：首页（`selectedTopicProvider`）、私信（`selectedMessageProvider`）、
搜索（`selectedSearchProvider`）、追觅（`selectedSeekingProvider`）、
草稿（`selectedDraftPaneProvider`）、浏览历史（`selectedHistoryPaneProvider`）、
我的话题（`selectedMyTopicsPaneProvider`）、待审帖
（`selectedPendingPaneProvider`）、徽章页（`selectedBadgePaneProvider`）、
关注/粉丝（`selectedFollowPaneProvider`）、分类话题页
（`selectedCategoryPaneProvider(categoryId)` family）、标签话题页
（`selectedTagPaneProvider(tagName)` family）。

**「我的」页不是宿主**：它是导航枢纽，所有入口（资料/话题/设置…）
一律开新页面；宽屏仅静态双栏排版（左资料卡固定 360 + 右功能卡，
`resizableMaster: false`，无 panes、无 EmbeddedStackScope）。曾接入
右栏平行视界后退役——本页不存在"切换别的页面"的语义。

**用户资料页（全屏形态）是"内容页宿主"新形态**：栈空时资料页独占
全宽，**按本页实际可用宽度**（非屏宽）分流两版排版
（`UserProfileWideLayout`，`lib/utils/responsive.dart`）：
≥760px 宽版 = 左侧 360 定宽资料栏（头图背景全高+完整用户信息常驻）
+ 右侧 Tab 与列表占满（内容限宽居中）；<760px 竖版 = 原折叠头图形态。
骨架屏（`UserProfileSkeleton`）走同一条分流——loading 形态必须与
成品一致，否则数据到达瞬间跳版式。
点话题/回复后资料页收窄成左栏（拿到格子宽自动回竖版）、详情从右
滑入（对半分）；缩窄时详情转投影；窄屏点列表走真路由。由
`MasterDetailLayout.masterFillsWhenEmpty: true`（仅 `pinMaster: false`
生效）+ `selectedUserProfilePaneProvider(username)` family 实现。
该形态下**空态永不挂载**（栈空 = master 撑满自排版；空态画在右格区
会直接盖住 master 的右半边+带出一条假分隔线，实测截图踩中），
拖拽分隔柄在栈空时也不渲染。
嵌入形态（作为别的宿主的面板）不变——压宿主的栈。

## 动画语言（2026-08 定案:胶片带）

平行视界 = 一条水平胶片带 `[master 格, 层1格, 层2格, …]`
（`PaneFilmstrip`，`lib/widgets/layout/pane_filmstrip.dart`）：

- **每层内容永久住在自己的格子里**（Element 恒驻、keyed），压/退栈 =
  视口沿带平移，格子永不换家。宽屏露最后两格（倒二格=“上一层预览”，
  栈顶格=“详情”），投影露最后一格（全宽路由式）。300ms · easeOutCubic。
- **为什么是这个结构**：四轮自研层间动画全败（双活体槽/快照编排/
  修复版/延帧防线），共因是旧结构里内容要在 master/detail 两个槽之间
  **交接**——任何让旧画面多活一会的机制都撞上交接（排版缓存单亲契约
  断言、OverlayPortal 布局期激活、快照揭示错位）。胶片带没有交接：
  格子按 key 原地复用（PageView/Navigator 同款），出场格保留原实例在
  原格子演完滑出再移除。**禁止再走"跨槽搬内容+动画"的路线。**
- 附带治愈：压栈时预览格不再销毁重建——同一 Element 滑到左栏，滚动
  位置/视频/输入态全保。
- 宿主接口：`MasterDetailLayout.panes`（每层一格、稳定 key，
  `truncateOnPush: 非顶格`）+ `pinMaster`（false=首页/搜索/私信/追觅
  的"列表也在带上"形态；true=PaneHost/profile 的"列表钉死左栏"形态）；
  旧 `detail` 单格口保留兼容。
- 格子渲染契约：容器统一铺底(scaffoldBackgroundColor)、带外格
  Offstage+四关(焦点/命中/语义/ticker)、pinned 模式层带裁切在右格区。
- 预测返回跟手：`PaneProjectionBack.progress`（在 pane_filmstrip.dart）
  → 带内顶格右拖，露出的是真实下一层；commit 收尾 `suppressNextPaneSwitch`
  抑制清栈的二次动画。投影关闭（ESC/返回）直接 pop/clear，滑出由带
  动画自己演。
- 逃生口：`MasterDetailLayout.animatePanes: false` 退瞬切（结构收益
  独立于动画存在）。
- Rail 恒定：深层平行视界隐藏侧栏的旧联动已删（抽 72px 侧栏=外部
  几何跳变源）。

## 导航入口规则（2026-08 收敛）

一句话：**已在平行视界面板里的一切打开话题/资料动作，继续压当前栈
（`EmbeddedStackScope.maybePushTopic` / `openProfile`，返回 false 再退
全屏 push）；列表宿主页自己分流（宽屏 `select()` 进右栏，窄屏真路由）；
通知（大屏页面弹窗）/深链（恒全屏）/书签 workspace/稍后读浮层是刻意
独立机制，维持现状。**

- 话题体内入口已全部收敛：相关/建议话题、链接面板（post_links）、AI
  摘要跨话题链接、话题内搜索、预览弹窗（show 时捕获栈，pop 后压栈）。
- 新写"打开话题/资料"的代码**禁止**裸 `Navigator.push`——先试统一入口。

## 约定

### 1. 宽窄衔接：投影，不是合成路由

- 宿主给 `MasterDetailLayout` 传 `projectDetailWhenNarrow: true`（或直接用
  `MasterDetailPaneHost` 标准件，已内置），窄屏栈非空时详情自动全宽投影。
- 外层包 `PaneProjectionBackScope(stackProvider, isActive)`，投影态的
  系统返回（`isStacked ? pop : clear`）、Android 预测返回跟手、底栏隐藏
  联动（`hasActiveProjection`）自动获得。
- **禁止**再写"缩窄时把栈顶 push 成全屏路由"的前向衔接
  （`_maybePushDetail` 模式已整体退役）。

> 翻车案例（本次大修的直接动因）：旧合成路由机制"push 时故意不清栈 +
> 首页 didUpdateWidget 重激活时把布局判断标志清 null"叠加，宽屏开话题→
> 缩窄→之后**每次切回首页 tab 该话题都自动全屏弹出且关不掉**（窄屏下
> 没有任何路径能清掉单层选中）。同树投影从结构上消灭了这一类时序 bug：
> 没有合成 push，就没有"粘住的选中"。

- **反向桥保留**：窄屏点列表走真路由 push（保原生转场/侧滑/预测返回），
  变宽时 `TopicDetailPage._maybeSwitchToMasterDetail` 把自己写回栈并退场；
  `EmbeddedStackScope.openProfile/openSettings` 的窄屏临时路由
  （`AutoRestoreMasterDetailRoute`）同理。**窄屏点击不写栈**——真路由与
  投影互斥，不会双渲染。

### 2. 背景与空态

- detail 槽的背景由 `MasterDetailLayout` 统一铺 `scaffoldBackgroundColor`，
  **页面不要自己包 ColoredBox**。
- 自定义空态（`emptyDetail`）一律用 `MasterDetailEmptyState`，只定制
  icon / message / iconSize，不要自己拼 Center/Column。

### 3. detail 面板的 onBack

标准写法（回调内重读 provider，不闭包捕获 build 快照）：

```dart
onBack: () {
  final n = ref.read(provider.notifier);
  ref.read(provider).isStacked ? n.pop() : n.clear();
},
```

- 压栈时退一层；基础层（栈仅一层）清空右栏回空态。投影态的返回走同一段
  语义（`PaneProjectionBackScope` 内置），宽窄行为一致。
- **不要**传 `isStacked ? pop : null`——基础层 ESC/返回会变成空操作。

### 4. 嵌入判定：scope，不是屏宽

判断"我是否处在嵌入面板里"**只有一个正确姿势**：

```dart
final scopeProvider = EmbeddedStackScope.maybeOf(context); // null = 不在
```

- **禁止**用 `canShowBothPanesFor`（屏宽）推断自己是否嵌入。
- `canShowBothPanesFor` 的唯一用途：**宿主页**决定列表点击该
  `select()` 进右栏还是 `Navigator.push` 全屏。
- 判定口径（2026-08 起）：`窗宽 − Rail 应占宽 ≥ master + minDetail`。
  Rail 应占宽由 `NavChromeMetrics`（`lib/utils/nav_chrome_metrics.dart`）
  记账——取**形态宽**（断点决定），不取"当前可见宽"：
  `hideNavigationRail`（深层平行视界临时藏 Rail）不改判定，否则
  pop 一层→Rail 回来→宽度不够→塌成投影，模式翻转振荡。
- 栏宽契约常量收口在 `PaneBreakpoints`（`lib/utils/responsive.dart`），
  新宿主从这里取数，不要再散落魔数。

### 4.1 页面即宿主，不做"寄生层"

一个页面若需要"列表 + 详情"形态，应**自己当宿主**——直接套标准件
`MasterDetailPaneHost`（参照 `DraftsPage` / `MyTopicsPage` /
`BrowsingHistoryPage`）：传入自己的 `SelectedTopicProvider`（定义加到
`selected_topic_provider.dart`，不要散落页面文件）和列表 Widget，
双栏组装、ESC 两段式、窄屏投影、返回链自动获得。
`PaneKind` 只保留真正的"详情内容"：topic / profile / settings。

### 5. ESC（closeOverlay）

全局 `KeyboardShortcutHandler` 用 `HardwareKeyboard.addHandler` 监听
（仅桌面注册），分发序：**surface → 页面 context/scope 回调 →
路由级自动兜底 → 全局动作**。

| 场景 | 接法 | 说明 |
|---|---|---|
| 嵌入面板层 | `ShortcutScopeBinding(scope: detail)` 注册 closeOverlay → onEmbeddedBack | `TopicDetailPage`、`UserProfilePage`；可先退页内搜索等定制语义。**master 预览位（`onEmbeddedBack == null`）不得注册 closeOverlay**——空操作回调会在 detail scope 合并时按注册序盖掉真面板的关闭回调，ESC 变成"被吃掉但没反应" |
| 双栏宿主页 | `PaneHostEscBinding.sync(paneOpen: 栈非空)` | 栈非空（右栏开/投影开）让分发落 detail scope；栈空注册 maybePop。`MasterDetailPaneHost` 已内置 |
| **普通全屏路由** | **无需接入** | `EscFallbackObserver`（`lib/widgets/esc_fallback_observer.dart`）在 push 时自动登记，ESC 自动 maybePop（尊重 PopScope，编辑器弹确认是期望语义） |
| 快捷键打开的全局路由/弹层 | `pushAppRoute` + `ShortcutSurfaceConfig` | 搜索/设置/新建话题/通知 |

- **路由级自动兜底**（2026-08 起）：根 Navigator 与设置页内栏各挂一个
  `EscFallbackObserver`，全屏 PageRoute push 自动登记、pop 注销；分发端
  在 context 回调之后、全局动作之前查登记表，栈顶 isCurrent 才 maybePop。
  旧的"逐页显式接入"约定作废（50+ 页零接入正是它腐烂的证据），
  `RouteEscCloseBinding` 已删除。
- 早年否决的是**无差别全局 maybePop**（同步 handler 无法感知事件是否被
  后续管线消费，与图片查看器等自管理页抢跑）；observer 按 route 精确登记
  + isCurrent 过滤不属其列。图片查看器/全屏视频的本地实现保留不迁移：
  全局消费后事件不进焦点管线，无双 pop。
- 设置页嵌套 Navigator：内栏子页登记兜底（有子页 ESC 先退子页），内栏
  基层 isFirst 不登记，落回设置页 surface 关整页——修掉了旧的"宽屏设置
  ESC 直接关整页"。
- **route 类 surface 对 closeOverlay 让位给页内 detail 面板**：搜索页这类
  「自身是 surface 的宿主页」开着右栏话题时，ESC 语义必须是先关话题、
  再关整页——分发端在 surface 层检测「当前路由的 detail scope 注册了
  closeOverlay」则 pass，落到 context 回调去关面板；detail 注册随面板
  关闭消失后，下一次 ESC 才走 surface.onClose 关整页。panel/overlay 类
  surface（通知面板等）浮在页面之上，不让位。
- **退层类动作不吃 key repeat**：closeOverlay / navigateBack(Alt) 在分发
  入口对 `KeyRepeatEvent` 消费不执行（`keyboard_shortcut_handler.dart`）。
  按住 Esc（或系统重复率调快）时 repeat 以数十毫秒一发连打，接上路由级
  兜底后会把整条路由栈一口气退光；退层是离散语义，一次按压只退一层。
- **IndexedStack 常驻页必须传 enabled 谓词**（不变）：注册时
  `enabled: () => widget.isActive`（嵌入面板 `!embeddedMode || parentActive`），
  否则非活跃 tab 的注册截胡活跃 tab 按键。
- **不要**新增 `CallbackShortcuts` / `KeyboardListener` 接 ESC。

### 6. 投影态的周边语义

- 投影开着时底栏自动隐藏（main.dart 读 `hasActiveProjection` 传
  `AdaptiveScaffold.hideBottomNavigation`）；FAB 在 master 槽内，投影时
  随之被盖。
- 首页侧栏点板块 / 底栏重复点首页：投影态语义 = 清栈回列表
  （`collapseToTop` 对单层是 no-op，投影会挡住列表，必须 clear）。
- 投影判定经 `LayoutLock` 冻结（全屏视频/iframe 期间不切结构）。

## 已知限制

- 设置页 detail 是嵌套 Navigator 范式（目录+子页导航，非列表+详情栈），
  缩窄丢内栏内容维持现状。
- chat 未迁入本约定（`StateProvider<int?>` 无栈简版，缩窄无害）。
- iOS/iPad 投影态无边缘侧滑（返回靠面板 AppBar 返回键；iPhone 纯窄设备
  栈恒空，不出现投影态）。
- 书签页是独立多标签工作台，不适用本约定。
