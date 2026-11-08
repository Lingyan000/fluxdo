# Flutter 十字滑动与动画打断调研

调研日期：2026-11-08。目标场景：横向分页、抽屉关闭、返回回弹还在运动时，下一次纵向滑动可以立即操作列表。

## 结论

有人研究并实现了相关机制，有可借鉴的开源代码。本次没有找到一个开箱即用、同时覆盖 Flutter 分页、浮层、抽屉和返回转场的通用包。应分别处理命中路径、方向仲裁和动画取消，不能只调滚动物理参数。

vivo 的 OriginOS 官网明确介绍了“首帧交互可打断”，描述上下左右操作可以打断先前运动。这与我们追求的体验一致，但本次没有找到其公开实现源码，不能推断它具体采用哪套机制。[vivo 官方介绍](https://www.vivo.com.cn/originos)

这里的“十字滑动”主要指抬手后快速换方向，新手势能接管旧动画。手指不抬起、在同一个 pointer 序列中从横轴切换纵轴，是另一种需求；当前实现不迁移已经胜出的手势。

## 已有工作及可借鉴范围

| 来源 | 已确认的机制 | 对本项目的意义 |
| --- | --- | --- |
| [Flutter issue #148318](https://github.com/flutter/flutter/issues/148318) | 分页动画期间子内容不接收输入，想操作下一页内容的滑动会被分页截走；调研时仍为 open | 与横滑后立即竖滑的问题直接对应，不能认为只升级 SDK 就一定解决 |
| [Flutter PR #145848](https://github.com/flutter/flutter/pull/145848) | 2024-07-02 合并；最终变更让越界回弹时子内容接收输入 | 修的是越界状态，普通分页吸附、应用自己加的遮罩仍需处理 |
| [React Native Gesture Handler 抽屉](https://github.com/software-mansion/react-native-gesture-handler/blob/f219ea0711ff2ef80d6ae69f6f4a98930d76e206/packages/react-native-gesture-handler/src/components/ReanimatedDrawerLayout.tsx#L367) | 遮罩是否接收输入由逻辑开关决定，动画开始时就更新开关；视觉进度单独驱动 | 直接借鉴“开始关闭就放行新触摸”，无需等透明度或位移归零 |
| [Compose MutatorMutex](https://developer.android.com/reference/kotlin/androidx/compose/foundation/MutatorMutex) | 同优先级或更高优先级的新操作可以取消旧操作 | 借鉴动画所有权与取消机制，避免旧动画完成回调覆盖新拖拽 |
| [Compose draggable](https://developer.android.com/reference/kotlin/androidx/compose/foundation/gestures/draggable.modifier) | `startDragImmediately` 可用于抓住仍在运动的内容 | 按下立即认领会影响其他手势竞争；不能给所有横纵滚动同时强行开启 |

RNGH 源码还有两个值得区分的细节：其横向拖动设置了纵向失败阈值，避免竖滑激活横拖；但该抽屉在 settling 期间禁用 pan。因此我们借鉴它的输入状态分离，不能把它描述为已经实现任意方向、任意阶段的完整重抓。[对应源码](https://github.com/software-mansion/react-native-gesture-handler/blob/f219ea0711ff2ef80d6ae69f6f4a98930d76e206/packages/react-native-gesture-handler/src/components/ReanimatedDrawerLayout.tsx#L547)

“原生应用没有问题”不能理解为原生框架无条件保证这种体验。Flutter issue 作者也记录了 Kotlin 原生示例的类似现象；这仅是该示例的观察，说明具体组件和协调策略同样重要，不代表所有原生应用都如此。[问题复现与讨论](https://github.com/flutter/flutter/issues/148318)

## Flutter 包筛选

以下是按这些包公开用途对本项目场景的评估，并非对所有组合用法的穷尽测试。

| 包 | 主要处理什么 | 本次选择 |
| --- | --- | --- |
| [extended_nested_scroll_view](https://pub.dev/packages/extended_nested_scroll_view) | 外层头部和内层列表、多个 tab 滚动协调 | 项目已使用；它不负责我们自定义抽屉的遮罩命中 |
| [flutter_nested_scroll](https://pub.dev/packages/flutter_nested_scroll) | 类似 Compose 的预滚动、剩余滚动及 fling 消耗链 | 有架构参考价值；替换控制器也无法让被遮罩挡住的列表收到 down |
| [nested_scrollables](https://pub.dev/packages/nested_scrollables) | 同轴嵌套传递；分页优先回到整页再交给子滚动 | 与跨方向立即交接的目标不完全一致，本次不引入 |
| [smooth_sheets](https://pub.dev/packages/smooth_sheets) | sheet 与内容滚动、导航配合 | 可用于后续研究底部浮层，不能直接替代首页分页和抽屉协调 |

## 项目根因与实现

### 1. 命中路径先于方向识别

首页 `ControlledCategoryDrawer` 在动画值大于零时保留整屏不透明命中遮罩。原来关闭只改变弹簧目标，遮罩直到动画归零才撤掉。此时下一次 down 命中侧栏，底层列表没有进入候选路径；后续再调横纵阈值，列表也无法争到这一手势。

新增 `InteractionGate`，将“是否接收新输入”与“是否还在屏幕上绘制”分开。关闭决定同步把输入开关关掉，视觉弹簧继续运行；打开、重新拖动、预测返回取消时恢复输入。

开关监听直接更新 `RenderIgnorePointer`，不等待下一次 build，覆盖同一帧内的下一次触摸。已经开始的 pointer 序列仍走原路径，所以关闭遮罩的那次点击不会穿透成底层点击。这个行为与 RNGH 抽屉的逻辑状态分离思路相符，但实现使用 Flutter 的渲染命中机制，没有复制其代码。

### 2. 嵌套滚动仍需单独处理

先前的 `DesktopScrollInteractionBinding` / `DesktopScrollInteractionBehavior` 修改，让仍在惯性或程序化滚动中的 Scrollable 在新触屏 down 命中前暴露内部滚动容器，再由 Flutter 原有的按下暂停与方向识别处理。轻点仍只停止惯性，不额外触发内容按钮，也不打断另一根手指正在进行的拖动。

它仅调整 Scrollable 自己的输入屏蔽，不能绕过业务遮罩；这就是先前滚动测试通过、真实侧栏仍然出问题的原因。首页首缘向右拉出抽屉仍通过原有的分页物理桥接。

这段滚动适配读取了 Flutter 受保护的 activity 与输入开关 API，SDK 升级时必须回归。当前开启触摸重采样时会回退框架默认行为；它不是任意 Flutter 配置下的全局保证。新加的侧栏 `InteractionGate` 本身不依赖这些受保护 API。

### 3. 动画只有当前操作可以收尾

侧栏使用可取消的动画 future 和操作代次，旧动画取消后不再把位置写回旧终点。即使在打开动画首帧之前立即关闭，也会停止旧动画。销毁时取消动画并避免移除返回历史触发再次关闭。

先前的全屏返回改动保留回弹中的控制器，支持再次按住继续或反向拖动，并正确处理取消和 Navigator 手势计数。它与抽屉共享的是操作原则，仍需要各自的组件生命周期实现。

### 4. 应用级统一接入

本轮把规则收敛到 `packages/common_ui/lib/src/route_interaction.dart`，配合已有滚动 Binding 和 `InteractionGate`。统一的是输入所有权，组件继续使用各自的动画；无需修改 Flutter SDK。

| 阶段 | 新输入规则 |
| --- | --- |
| 手指仍在拖动返回 | 保留框架拦截，避免第二根手指误操作页面 |
| 取消返回后的自动回弹 | 当前页面可接收新的纵向滚动，横向返回仍可再次接管 |
| 已确认关闭或 pop | 退出层及其遮罩立即停止命中新触摸，视觉继续收尾 |

`RouteInteractionObserver` 记录返回手势所属路由，结合其控制器是否正在自动运行判断回弹。保留 `Navigator.userGestureInProgress` 到真正收尾，避免破坏 Cupertino 转场和 Hero。`RouteContentInteraction` 必须紧贴 `buildTransitions` 的原始 child，只临时开放框架自己的 `IgnorePointer`，不会递归开放业务禁用区域。

`RouteInputGate` 读取同步的 `route.isActive`，对退出路由的内容和 barrier 都生效。消耗 `LocalHistoryEntry`、取消预测返回不会把仍然有效的模态层放行。Navigator 在 pop 同帧还会暂时开启自身 `AbsorbPointer`；Binding 在命中期间只对已确认 pop、下层仍为当前路由的 Navigator 临时解除此 guard，随后恢复。其间再次 push/replace/remove 会撤销许可。

普通不透明页面下面的路由可能仍处于 offstage，需要下一次布局才能重新参与命中；因此这里保证可在退出动画期间操作，不保证所有页面都在 pop 同一帧可操作。弹窗等已布局底层的场景覆盖了同帧接续。

已接入范围：

- 根 Navigator、设置内栏 Navigator、用户卡片菜单 Navigator；普通和全屏返回两套全平台转场主题。
- `lib` 中普通页面路由统一为 `InteractionPageRoute` / `InteractionPageRouteBuilder`，普通 Material 弹窗使用 `showInteractionDialog`；原有应用弹窗、通用弹窗、底部 sheet 在公共实现中接入。
- 自定义菜单与子菜单、编辑器锚点面板、赞赏作者弹层、浏览器页面转场。独立引擎的接入要求见下文。
- 分类侧栏、通知侧栏、图片长按菜单、表情浮层、反应选择器、引导遮罩、应用链接横幅使用同步输入开关。重新打开的浮层拥有自己的开关，避免旧 entry 收尾干扰新 entry。
- 平行视界在预测返回确认时立即退逻辑栈，退出格从手指当前位置继续滑出，下层在新布局后接受输入。回弹使用可取消 future 和代次；退出进度只交给对应宿主，并在帧末失效。

### 5. 新页面的接入约定

1. 普通页面使用 `InteractionPageRoute`，自定义 `pageBuilder` 使用 `InteractionPageRouteBuilder`；弹窗沿用 `showAppDialog` / `showAppGeneralDialog` / `showAppBottomSheet`，需要标准 Material 弹窗外观时使用 `showInteractionDialog`。
2. 每个新增 Navigator 注册一个随 State 持久保存的 `RouteInteractionObserver`，不要在 build 中反复创建。主题的 `PageTransitionsBuilder` 用 `InterruptiblePageTransitionsBuilder` 装饰。
3. 自定义 `PopupRoute` 使用 `InterruptibleRoute`。如果覆盖 `buildTransitions` 或 `buildModalBarrier`，调用 super，或显式补 `RouteInputGate`；原始内容 child 外紧贴 `RouteContentInteraction`。只装饰主题不能覆盖路由 barrier，所以仍需使用公共路由类。
4. 非路由 `OverlayEntry` 使用 `InteractionGate`，确认关闭时同步置 false，动画结束后再移除；重开、取消关闭和销毁要明确处理各自状态。
5. 独立 Flutter 引擎也要初始化 `FluxdoWidgetsBinding` 并使用应用滚动策略。平台 WebView 内部手势不由这些 Flutter 包装器接管。

`test/architecture/interaction_entry_points_test.dart` 检查应用源码中的普通路由和弹窗入口，防止后续页面直接使用未接入的框架构造函数。它不替代自定义 route/overlay 的行为测试。

路由适配依赖当前 Flutter 3.47.4 的受保护 `TransitionRoute.controller` 以及 `_ModalScope`、Navigator 的渲染结构；升级 SDK 时需要运行下面的回归，特别是同帧 pop、取消回弹、业务 IgnorePointer 和模态隔离。它是应用公共层的适配，不是 Flutter 官方提供的一个全局开关。

## 验证结果

真实 `ControlledCategoryDrawer` 与底层测试列表的组件测试共 19 项通过，覆盖：

- 遮罩点击关闭后，同一帧、16 ms、80 ms 内开始上下滑；起点分别位于仍可见的面板区域及遮罩区域，包含轻微横向偏移。
- 向左拖动关闭后立即竖滑。
- 关闭时那一次点击不穿透，同帧下一次点击可操作列表。
- 预测返回提交后放行，取消后保持侧栏拦截。
- 关闭弹簧中重新拖出、打开首帧前关闭、关闭途中销毁。

曾临时恢复旧版“关闭期间持续拦截”的行为，对其中一条同帧竖滑测试做反向验证：列表位移为 0，测试按预期失败；随后恢复修复。

侧栏阶段相关回归共 **117 项通过**，包括侧栏、触摸横纵交接、桌面滚动、全屏返回、预测返回、宿主布局和编辑器对象选择。

本轮新增路由与浮层测试，覆盖弹窗/通用弹窗/sheet/Material dialog/菜单关闭后 0、16、80 ms 接续、模态层叠加、LocalHistory、关闭点击不穿透、同帧重开、嵌套 Navigator、Android/iOS 返回回弹、普通页面退出、预测返回提交/取消，以及业务 IgnorePointer 保持禁用。平行视界还覆盖连续取消后再次拖动、提交立即退栈、退出位置连续、跨宿主进度隔离与过期。

开发工作区相关回归 **255 项全部通过**，包含本轮新增用例以及滚动、侧栏、预测返回生命周期/Hero/sheet、编辑器对象选择、快捷键、浏览器收起恢复和导航测试。拆分其他并行功能后，独立提交快照再次通过 **85 项核心测试**。两轮静态分析 `lib`、`packages/common_ui/lib` 与新增测试均无 error / warning，仓库仍有 info 级风格提示；`git diff --check` 通过。

复现提交快照的核心回归（项目根目录，依赖和本地化生成产物已准备，PowerShell）：

```powershell
$gestureTests = @(
  'test/widgets/topic/category_drawer_interruption_test.dart',
  'test/architecture/interaction_entry_points_test.dart',
  'test/widgets/common/fullscreen_swipe_back_test.dart',
  'test/widgets/common/touch_scroll_interruption_test.dart',
  'test/widgets/common/route_interruption_test.dart',
  'test/widgets/common/overlay_interruption_test.dart',
  'test/widgets/layout/pane_projection_test.dart',
  'test/widgets/layout/pane_filmstrip_test.dart'
)
flutter test --no-pub --reporter expanded @gestureTests
```

## 尚未验证的边界

组件测试使用真实侧栏、弹层和受控底层列表，并非整页生产数据与设备触摸链路的端到端验证。Android/iOS 的测试平台变体不能替代真机手感、帧耗时或 vivo 系统行为对比；目前尚未完成这些真机验证。

当前保证的是已接入入口中抬手后的新手势接管。第三方自带的 route/overlay、WebView 原生内容、同一 pointer 不抬手换轴不在此范围。真机重点观察首页分页吸附后的方向交接、侧栏关闭后经首页分页重新横向拉出，以及快速连续导航。后续发现遗漏仍按命中路径、横纵竞争、旧动画取消的顺序定位。
