import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import 'package:uuid/uuid.dart';
import '../pages/settings_page.dart';
import '../pages/user_profile_page.dart';
import '../widgets/layout/auto_restore_master_detail_route.dart';

/// 平行视界导航栈里一层的内容种类。栈里可以混插话题层和个人资料层
/// （比如：话题 -> 点头像 -> 资料 -> 点资料里的链接 -> 另一个话题）。
enum PaneKind { topic, profile, settings }

/// 平行视界导航栈里的一层。
class PaneEntry {
  const PaneEntry.topic({
    required this.topicId,
    this.initialTitle,
    this.scrollToPostNumber,
    this.instanceId,
    this.highlightBoostUsername,
    this.initialRevisionPostNumber,
    this.initialRevisionNumber,
    this.autoOpenReply = false,
    this.autoReplyToPostNumber,
  }) : kind = PaneKind.topic,
       username = null;

  const PaneEntry.profile({required this.username})
    : kind = PaneKind.profile,
      topicId = null,
      initialTitle = null,
      scrollToPostNumber = null,
      instanceId = null,
      highlightBoostUsername = null,
      initialRevisionPostNumber = null,
      initialRevisionNumber = null,
      autoOpenReply = false,
      autoReplyToPostNumber = null;

  const PaneEntry.settings()
    : kind = PaneKind.settings,
      topicId = null,
      username = null,
      initialTitle = null,
      scrollToPostNumber = null,
      instanceId = null,
      highlightBoostUsername = null,
      initialRevisionPostNumber = null,
      initialRevisionNumber = null,
      autoOpenReply = false,
      autoReplyToPostNumber = null;

  final PaneKind kind;
  final int? topicId;
  final String? username;
  final String? initialTitle;
  final int? scrollToPostNumber;

  /// provider 实例 ID，用于布局切换时复用同一个 provider
  final String? instanceId;
  final String? highlightBoostUsername;
  final int? initialRevisionPostNumber;
  final int? initialRevisionNumber;

  /// 进入这一层后自动弹出回复框——草稿列表点进来时用（草稿的意义就是
  /// 接着写，不该让用户再手点一次回复）。
  final bool autoOpenReply;

  /// 自动弹出的回复框回复的目标楼层（null = 回复整个话题）。
  final int? autoReplyToPostNumber;
}

/// 平行视界（Master-Detail 模式）的导航栈状态。
///
/// - 从列表点开话题：[SelectedTopicNotifier.select] 清空栈重新开始，
///   跟以前单选逻辑一致。
/// - 在话题内容里点内部链接（跳到另一个话题/私信）：
///   [SelectedTopicNotifier.push] 压栈，不影响之前的层；栈深度 > 1 时
///   UI 层（[MasterDetailLayout] 消费方）应把列表区滑出隐藏，只显示
///   当前顶层内容。
/// - 关闭当前层：[SelectedTopicNotifier.pop] 退回上一层，栈空后等效于
///   [SelectedTopicNotifier.clear]（列表区域恢复显示）。
class SelectedTopicState {
  const SelectedTopicState({this.stack = const []});

  final List<PaneEntry> stack;

  PaneEntry? get _top => stack.isEmpty ? null : stack.last;

  /// 栈顶层完整数据，供 UI 层按 [PaneEntry.kind] 分发到具体面板组件。
  PaneEntry? get topEntry => _top;

  bool get hasSelection => stack.isNotEmpty;

  /// 栈深度 > 1：当前是通过内部链接跳转堆上来的，不是列表直接选中的。
  bool get isStacked => stack.length > 1;

  PaneKind? get kind => _top?.kind;
  int? get topicId => _top?.topicId;
  String? get username => _top?.username;
  String? get initialTitle => _top?.initialTitle;
  int? get scrollToPostNumber => _top?.scrollToPostNumber;
  String? get instanceId => _top?.instanceId;
  String? get highlightBoostUsername => _top?.highlightBoostUsername;
  int? get initialRevisionPostNumber => _top?.initialRevisionPostNumber;
  int? get initialRevisionNumber => _top?.initialRevisionNumber;
}

class SelectedTopicNotifier extends StateNotifier<SelectedTopicState> {
  SelectedTopicNotifier() : super(const SelectedTopicState());

  /// 从列表选中话题：清空栈重新开始（点了另一个话题，不是内部链接跳转）。
  void select({
    required int topicId,
    String? initialTitle,
    int? scrollToPostNumber,
    String? instanceId,
    String? highlightBoostUsername,
    int? initialRevisionPostNumber,
    int? initialRevisionNumber,
    bool autoOpenReply = false,
    int? autoReplyToPostNumber,
  }) {
    state = SelectedTopicState(
      stack: [
        PaneEntry.topic(
          autoOpenReply: autoOpenReply,
          autoReplyToPostNumber: autoReplyToPostNumber,
          topicId: topicId,
          initialTitle: initialTitle,
          scrollToPostNumber: scrollToPostNumber,
          // 最初从列表进入的这一层也必须持有稳定实例 ID。否则它在
          // 平行视界里从 detail 搬到 master 时会生成新的 provider key，
          // 已加载的分页数据会全部失配并重新请求。
          instanceId: instanceId ?? const Uuid().v4(),
          highlightBoostUsername: highlightBoostUsername,
          initialRevisionPostNumber: initialRevisionPostNumber,
          initialRevisionNumber: initialRevisionNumber,
        ),
      ],
    );
  }

  /// 话题内容里点内部链接跳转到另一个话题：压栈，保留之前的层。
  ///
  /// instanceId 不传时在这里当场生成一个、永久绑定在这个栈层上——
  /// [topicDetailProvider] 用 (topicId, instanceId) 做 family key，且自带
  /// 30 秒 keepAlive 缓存宽限期，本来应该做到"退栈几秒内返回不用重新
  /// 请求"。但之前 instanceId 是靠调用方（topics_screen.dart 的
  /// `_getOrCreateInstanceId`）一个只记得"最后一个话题"的单槽缓存去猜，
  /// 只要中途看过别的话题就会把之前的 instanceId 忘掉，退栈时生成一个
  /// 全新的、从没被缓存过的 instanceId——30 秒缓存形同虚设，永远命中不上，
  /// 表现为"平行视界一变动就完全重新请求"。在这里当场生成并让它跟着
  /// PaneEntry 一起被保留在栈里，才能保证同一层的话题从头到尾都是同一个
  /// provider key。
  void push({
    required int topicId,
    String? initialTitle,
    int? scrollToPostNumber,
    String? instanceId,
    String? highlightBoostUsername,
    int? initialRevisionPostNumber,
    int? initialRevisionNumber,
    bool autoOpenReply = false,
    int? autoReplyToPostNumber,
  }) {
    state = SelectedTopicState(
      stack: [
        ...state.stack,
        PaneEntry.topic(
          autoOpenReply: autoOpenReply,
          autoReplyToPostNumber: autoReplyToPostNumber,
          topicId: topicId,
          initialTitle: initialTitle,
          scrollToPostNumber: scrollToPostNumber,
          instanceId: instanceId ?? const Uuid().v4(),
          highlightBoostUsername: highlightBoostUsername,
          initialRevisionPostNumber: initialRevisionPostNumber,
          initialRevisionNumber: initialRevisionNumber,
        ),
      ],
    );
  }

  /// 列表项点击跳话题：替换栈顶，不新增层。
  ///
  /// 跟 [push] 的区别是语义来源不同——[push] 对应"正文里点内部链接"，
  /// 每次都是新内容，理应压栈；这个对应"在某个列表（比如个人资料页的
  /// 话题/回复列表）里连续点开不同项"，用户心智是"看列表里的另一项"，
  /// 不该每点一次就多叠一层，不然逛几个列表项平行视界就没法收场了。
  /// 栈为空时退化成 [push]。
  void replaceTop({
    required int topicId,
    String? initialTitle,
    int? scrollToPostNumber,
    String? instanceId,
  }) {
    if (state.stack.isEmpty) {
      push(
        topicId: topicId,
        initialTitle: initialTitle,
        scrollToPostNumber: scrollToPostNumber,
        instanceId: instanceId,
      );
      return;
    }
    state = SelectedTopicState(
      stack: [
        ...state.stack.take(state.stack.length - 1),
        PaneEntry.topic(
          topicId: topicId,
          initialTitle: initialTitle,
          scrollToPostNumber: scrollToPostNumber,
          instanceId: instanceId ?? const Uuid().v4(),
        ),
      ],
    );
  }

  /// master 面板"上一层预览"里点开新内容：截断掉当前栈顶（右侧 detail
  /// 正显示的那层），保留预览这一层本身，再压入新内容——效果是"替换
  /// 右边"，而不是在已经很深的栈上继续叠层，也不是脱离栈变成全屏。
  /// 栈深度 < 2（没有"上一层"可言）时退化成 [push]。
  void pushTruncating({
    required int topicId,
    String? initialTitle,
    int? scrollToPostNumber,
    String? instanceId,
    bool autoOpenReply = false,
    int? autoReplyToPostNumber,
  }) {
    if (state.stack.length < 2) {
      push(
        topicId: topicId,
        initialTitle: initialTitle,
        scrollToPostNumber: scrollToPostNumber,
        instanceId: instanceId,
        autoOpenReply: autoOpenReply,
        autoReplyToPostNumber: autoReplyToPostNumber,
      );
      return;
    }
    state = SelectedTopicState(
      stack: [
        ...state.stack.take(state.stack.length - 1),
        PaneEntry.topic(
          autoOpenReply: autoOpenReply,
          autoReplyToPostNumber: autoReplyToPostNumber,
          topicId: topicId,
          initialTitle: initialTitle,
          scrollToPostNumber: scrollToPostNumber,
          instanceId: instanceId ?? const Uuid().v4(),
        ),
      ],
    );
  }

  /// 更新栈顶话题的恢复信息，但保留整个平行视界历史。
  ///
  /// 窗口由宽变窄时，栈顶话题会临时以全屏路由继续浏览；再次变宽时只需
  /// 把最新标题、楼层和 provider 实例写回栈顶，不能调用 [select] 把此前
  /// 的话题/资料层全部清掉。
  void updateTopTopic({
    required int topicId,
    String? initialTitle,
    int? scrollToPostNumber,
    String? instanceId,
  }) {
    final current = state.topEntry;
    if (current == null ||
        current.kind != PaneKind.topic ||
        current.topicId != topicId) {
      return;
    }

    state = SelectedTopicState(
      stack: [
        ...state.stack.take(state.stack.length - 1),
        PaneEntry.topic(
          topicId: topicId,
          initialTitle: initialTitle ?? current.initialTitle,
          scrollToPostNumber: scrollToPostNumber ?? current.scrollToPostNumber,
          instanceId: instanceId ?? current.instanceId,
          highlightBoostUsername: current.highlightBoostUsername,
          initialRevisionPostNumber: current.initialRevisionPostNumber,
          initialRevisionNumber: current.initialRevisionNumber,
          autoOpenReply: current.autoOpenReply,
          autoReplyToPostNumber: current.autoReplyToPostNumber,
        ),
      ],
    );
  }

  /// 点用户名/头像跳个人资料：压栈，保留之前的层（话题不退出，资料显示
  /// 在右侧顶替）。
  void pushProfile(String username) {
    state = SelectedTopicState(
      stack: [
        ...state.stack,
        PaneEntry.profile(username: username),
      ],
    );
  }

  /// 从搜索结果直接选择用户资料：清空旧搜索详情栈，以该资料作为第一层。
  void selectProfile(String username) {
    state = SelectedTopicState(stack: [PaneEntry.profile(username: username)]);
  }

  /// 打开设置：压栈，保留之前的层。
  void pushSettings() {
    state = SelectedTopicState(
      stack: [...state.stack, const PaneEntry.settings()],
    );
  }

  /// master 面板"上一层预览"里点头像/用户名跳资料：截断当前栈顶后压入，
  /// 语义同 [pushTruncating]。
  void pushProfileTruncating(String username) {
    if (state.stack.length < 2) {
      pushProfile(username);
      return;
    }
    state = SelectedTopicState(
      stack: [
        ...state.stack.take(state.stack.length - 1),
        PaneEntry.profile(username: username),
      ],
    );
  }

  /// master 面板"上一层预览"里打开设置：截断当前栈顶后压入，语义同
  /// [pushTruncating]。
  void pushSettingsTruncating() {
    if (state.stack.length < 2) {
      pushSettings();
      return;
    }
    state = SelectedTopicState(
      stack: [
        ...state.stack.take(state.stack.length - 1),
        const PaneEntry.settings(),
      ],
    );
  }

  /// 关闭当前层，退回上一层。栈已空时是 no-op。
  void pop() {
    if (state.stack.isEmpty) return;
    state = SelectedTopicState(
      stack: state.stack.sublist(0, state.stack.length - 1),
    );
  }

  /// 左栏切换到信息流、分类或标签时，保留右侧当前内容，但丢弃已经被
  /// 左栏替换掉的历史层。否则 [isStacked] 仍为 true，布局会继续用倒数
  /// 第二层覆盖左栏，让用户点击分类后看起来毫无反应。
  void collapseToTop() {
    final top = state.topEntry;
    if (top == null || state.stack.length == 1) return;
    state = SelectedTopicState(stack: [top]);
  }

  /// 消费掉栈顶的"自动打开回复框"意图。
  ///
  /// 这个标记必须**用一次就清**：它挂在 PaneEntry 上，只要还是 true，
  /// 任何导致话题面板重建的事（草稿层被抽掉、栈变动、tab 切换）都会让
  /// 它再触发一次 —— 实测发完私信回复框又自己弹出来。页面里的
  /// `_autoOpenReplyHandled` 是 State 字段，面板一重建就跟着重置，
  /// 拦不住，所以得在状态源头清。
  void consumeAutoOpenReply() {
    final top = state.topEntry;
    if (top == null || top.kind != PaneKind.topic) return;
    if (!top.autoOpenReply && top.autoReplyToPostNumber == null) return;
    state = SelectedTopicState(
      stack: [
        ...state.stack.take(state.stack.length - 1),
        PaneEntry.topic(
          topicId: top.topicId!,
          initialTitle: top.initialTitle,
          scrollToPostNumber: top.scrollToPostNumber,
          instanceId: top.instanceId,
          highlightBoostUsername: top.highlightBoostUsername,
          initialRevisionPostNumber: top.initialRevisionPostNumber,
          initialRevisionNumber: top.initialRevisionNumber,
          // 就是这里：清掉，别再弹第二次
        ),
      ],
    );
  }

  void clear() {
    state = const SelectedTopicState();
  }
}

typedef SelectedTopicProvider =
    StateNotifierProvider<SelectedTopicNotifier, SelectedTopicState>;

/// 首页话题列表的导航栈。
final selectedTopicProvider = SelectedTopicProvider((ref) {
  return SelectedTopicNotifier();
});

/// 私信列表的导航栈——跟首页话题列表各自独立一份状态，切 tab 互不干扰，
/// 但复用同一套 push/pop/select/clear 语义。
final selectedMessageProvider = SelectedTopicProvider((ref) {
  return SelectedTopicNotifier();
});

// 「我的」页右栏栈(selectedProfilePaneProvider)已退役:该页是导航
// 枢纽,所有入口一律开新页面,不做右栏平行视界(用户拍板)。

/// 用户资料页(全屏形态)右栏的平行视界栈,按 username family 隔离
/// (资料页可叠开多个:话题里点头像→资料→再开别人资料)。资料页
/// 自己是宿主:宽屏点话题/回复列表进右栏,缩窄投影,窄屏真路由。
/// 嵌入形态(在别的宿主栈里)不用它——压宿主的栈。
final selectedUserProfilePaneProvider = StateNotifierProvider.family<
  SelectedTopicNotifier,
  SelectedTopicState,
  String
>((ref, _) {
  return SelectedTopicNotifier();
});

/// 搜索页自己的平行视界导航栈，与首页话题、私信历史完全隔离。
final selectedSearchProvider = SelectedTopicProvider((ref) {
  return SelectedTopicNotifier();
});

/// 追觅（视奸）面板自己的平行视界栈。不能复用首页或搜索栈，否则切换
/// 导航项时两个页面会互相继承对方正在查看的话题/资料。
final selectedSeekingProvider = SelectedTopicProvider((ref) {
  return SelectedTopicNotifier();
});

/// 草稿页右栏的平行视界栈——独立于首页/私信/搜索，草稿页自己是宿主。
final selectedDraftPaneProvider = SelectedTopicProvider((ref) {
  return SelectedTopicNotifier();
});

/// 浏览历史页右栏的平行视界栈。
final selectedHistoryPaneProvider = SelectedTopicProvider((ref) {
  return SelectedTopicNotifier();
});

/// 「我的话题」页右栏的平行视界栈。
final selectedMyTopicsPaneProvider = SelectedTopicProvider((ref) {
  return SelectedTopicNotifier();
});

/// 待审帖列表页右栏的平行视界栈。
final selectedPendingPaneProvider = SelectedTopicProvider((ref) {
  return SelectedTopicNotifier();
});

/// 徽章详情页右栏的平行视界栈(获得者话题列表)。
final selectedBadgePaneProvider = SelectedTopicProvider((ref) {
  return SelectedTopicNotifier();
});

/// 关注/粉丝列表页右栏的平行视界栈(点用户开资料)。
final selectedFollowPaneProvider = SelectedTopicProvider((ref) {
  return SelectedTopicNotifier();
});

/// 分类话题页右栏的平行视界栈,按 categoryId family 隔离(分类页可
/// 叠开多个:话题里点分类→再点别的分类,共享单例会互相踩栈)。普通
/// family 而非 autoDispose:宿主组件链(PaneHost/投影 scope)吃的是
/// SelectedTopicProvider(non-autodispose)类型;残留代价只是每个访问
/// 过的分类一个空栈对象。同一分类叠开两层共享一份栈,极罕见,
/// clearOnInit 兜底。
final selectedCategoryPaneProvider = StateNotifierProvider.family<
  SelectedTopicNotifier,
  SelectedTopicState,
  int
>((ref, _) {
  return SelectedTopicNotifier();
});

/// 标签话题页右栏的平行视界栈(按 tagName family 隔离,见分类页注释)。
final selectedTagPaneProvider = StateNotifierProvider.family<
  SelectedTopicNotifier,
  SelectedTopicState,
  String
>((ref, _) {
  return SelectedTopicNotifier();
});

/// 窄屏临时路由携带的平行视界恢复上下文。
class FullScreenPaneRestoreScope extends InheritedWidget {
  const FullScreenPaneRestoreScope({
    super.key,
    required this.stackProvider,
    required this.restoreCurrentPane,
    required super.child,
  });

  final SelectedTopicProvider stackProvider;
  final VoidCallback restoreCurrentPane;

  static FullScreenPaneRestoreScope? maybeOf(BuildContext context) {
    final element = context
        .getElementForInheritedWidgetOfExactType<FullScreenPaneRestoreScope>();
    return element?.widget as FullScreenPaneRestoreScope?;
  }

  @override
  bool updateShouldNotify(FullScreenPaneRestoreScope oldWidget) =>
      stackProvider != oldWidget.stackProvider ||
      restoreCurrentPane != oldWidget.restoreCurrentPane;
}

/// 标记"当前 context 处在哪个平行视界嵌入面板里"，内部链接点击时靠它
/// 判断该压到哪个栈（首页话题栈还是私信栈）。
///
/// 用 InheritedWidget 而不是全局可变状态（早期版本用过
/// `StateProvider<SelectedTopicProvider?>`，靠 initState/dispose 设置/
/// 清除全局唯一值）——IndexedStack 里首页跟私信的嵌入面板经常同时挂载
/// （切 tab 不销毁），两边的 initState 各自的 postFrameCallback 会互相
/// 覆盖那个全局值，导致"私信详情里点链接却被当成了首页的嵌入面板"这类
/// 错乱（实测复现：私信内点话题链接直接全屏打开，而不是压栈）。
/// InheritedWidget 按 widget 树最近祖先解析，天然按面板隔离，不会互相
/// 踩踏。
class EmbeddedStackScope extends InheritedWidget {
  const EmbeddedStackScope({
    super.key,
    required this.stackProvider,
    this.truncateOnPush = false,
    required super.child,
  });

  final SelectedTopicProvider stackProvider;

  /// true = 这份内容是 master 面板里的"上一层预览"，不是当前可交互的
  /// 栈顶。这一层触发的 push/openProfile/openSettings 应该"替换右侧
  /// 正显示的那层"（截断栈顶后压入），而不是在已经很深的栈上继续叠层。
  final bool truncateOnPush;

  /// 找不到祖先（不在任何嵌入面板里，如全屏 Navigator push 出来的详情页）
  /// 时返回 null。不订阅重建（一次性读取，跟 ref.read 语义一致）。
  static SelectedTopicProvider? maybeOf(BuildContext context) {
    return _maybeScopeOf(context)?.stackProvider;
  }

  /// 当前 context 是否处在 master 面板"上一层预览"里——[UserProfilePage]
  /// 等页面自己手写的列表点击逻辑（区分"替换我自己上次点开的" vs
  /// "新压一层"）需要靠这个短路成统一的截断替换语义。
  static bool isTruncating(BuildContext context) =>
      _maybeScopeOf(context)?.truncateOnPush ?? false;

  static EmbeddedStackScope? _maybeScopeOf(BuildContext context) {
    final element = context
        .getElementForInheritedWidgetOfExactType<EmbeddedStackScope>();
    return element?.widget as EmbeddedStackScope?;
  }

  @override
  bool updateShouldNotify(EmbeddedStackScope oldWidget) =>
      stackProvider != oldWidget.stackProvider ||
      truncateOnPush != oldWidget.truncateOnPush;

  /// 在嵌入面板里打开话题时压入当前平行视界栈。
  ///
  /// 返回 `true` 表示已经由面板栈接管；返回 `false` 时调用方应按普通全屏
  /// 页面处理。这里只负责状态，不依赖具体页面类，避免导航基础层反向依赖
  /// 话题详情页面。
  /// [replaceTop] = 用新内容**替换**右栏当前层而不是叠一层。草稿列表点
  /// 某条草稿属于"在列表里看另一项",不该每点一次就多叠一层。
  static bool maybePushTopic(
    BuildContext context, {
    required int topicId,
    String? initialTitle,
    int? scrollToPostNumber,
    bool autoOpenReply = false,
    int? autoReplyToPostNumber,
    bool replaceTop = false,
  }) {
    final scope = _maybeScopeOf(context);
    if (scope == null) return false;
    final container = ProviderScope.containerOf(context, listen: false);
    final notifier = container.read(scope.stackProvider.notifier);
    if (scope.truncateOnPush || replaceTop) {
      notifier.pushTruncating(
        topicId: topicId,
        initialTitle: initialTitle,
        scrollToPostNumber: scrollToPostNumber,
        autoOpenReply: autoOpenReply,
        autoReplyToPostNumber: autoReplyToPostNumber,
      );
    } else {
      notifier.push(
        topicId: topicId,
        initialTitle: initialTitle,
        scrollToPostNumber: scrollToPostNumber,
        autoOpenReply: autoOpenReply,
        autoReplyToPostNumber: autoReplyToPostNumber,
      );
    }
    return true;
  }

  /// 打开用户资料的统一入口：在嵌入面板里（头像/用户名点击）就压栈显示
  /// 平行视界，不在（比如设置页、独立弹窗）就照旧全屏 push。所有点头像
  /// /用户名跳资料页的地方都应该走这个，别再各自手写 Navigator.push。
  static void openProfile(BuildContext context, String username) {
    final restoreScope = FullScreenPaneRestoreScope.maybeOf(context);
    if (restoreScope != null) {
      final container = ProviderScope.containerOf(context, listen: false);
      final notifier = container.read(restoreScope.stackProvider.notifier);
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (routeContext) {
            void restoreProfilePane() {
              restoreScope.restoreCurrentPane();
              notifier.pushProfile(username);
            }

            void restoreProfileRoute() {
              final route = ModalRoute.of(routeContext);
              final navigator = Navigator.of(routeContext);
              restoreProfilePane();
              if (route == null || !route.isActive) return;
              navigator.removeRoute(route);
            }

            return AutoRestoreMasterDetailRoute(
              onRestore: restoreProfilePane,
              child: FullScreenPaneRestoreScope(
                stackProvider: restoreScope.stackProvider,
                restoreCurrentPane: restoreProfileRoute,
                child: UserProfilePage(username: username),
              ),
            );
          },
        ),
      );
      return;
    }

    final scope = _maybeScopeOf(context);
    if (scope != null) {
      final container = ProviderScope.containerOf(context, listen: false);
      final notifier = container.read(scope.stackProvider.notifier);
      if (scope.truncateOnPush) {
        notifier.pushProfileTruncating(username);
      } else {
        notifier.pushProfile(username);
      }
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => UserProfilePage(username: username)),
    );
  }

  /// 打开设置的统一入口：嵌入面板里压栈显示平行视界，不在就全屏 push。
  static void openSettings(BuildContext context) {
    final scope = _maybeScopeOf(context);
    if (scope != null) {
      final container = ProviderScope.containerOf(context, listen: false);
      final notifier = container.read(scope.stackProvider.notifier);
      if (scope.truncateOnPush) {
        notifier.pushSettingsTruncating();
      } else {
        notifier.pushSettings();
      }
      return;
    }
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SettingsPage()));
  }
}

typedef DetailScrollPositionKey = ({int topicId, String instanceId});

/// 嵌入式详情页的当前浏览位置。
///
/// 必须与 [topicDetailProvider] 一样按 `(topicId, instanceId)` 隔离；只按
/// topicId 会让同一话题的不同平行视界层互相覆盖位置。
final detailScrollPositionProvider =
    StateProvider.family<int?, DetailScrollPositionKey>((ref, key) => null);
