import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:app_icons/app_icons.dart';
import 'package:chat_bottom_container/chat_bottom_container.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

import '../../../l10n/s.dart';
import '../../../models/chat/chat_channel.dart';
import '../../../models/chat/chat_message.dart';
import '../../../models/mention_user.dart';
import '../../../models/template.dart';
import '../../../providers/chat/chat_channels_provider.dart';
import '../../../providers/chat/chat_messages_provider.dart';
import '../../../providers/chat/chat_typing_provider.dart';
import '../../../providers/discourse_providers.dart';
import '../../../providers/message_bus/models.dart' show TypingUser;
import '../../../services/discourse_cache_manager.dart';
import '../../../services/emoji_handler.dart';
import '../../../services/toast_service.dart';
import '../../../utils/adaptive_menu.dart';
import '../../../utils/dialog_utils.dart';
import '../../../utils/fluxdo_render_callbacks.dart';
import '../../../utils/platform_utils.dart';
import '../../../utils/scroll_jump.dart';
import '../../../utils/emoji_shortcodes.dart';
import '../../../utils/time_utils.dart';
import '../../../utils/url_helper.dart';
import '../../../widgets/common/app_bottom_sheet.dart';
import '../../../widgets/common/hero_image.dart';
import '../../../widgets/common/emoji_text.dart';
import '../../../widgets/common/error_view.dart';
import '../../../widgets/common/height_reporter.dart';
import '../../../widgets/common/relative_time_text.dart';
import '../../../widgets/common/radial_long_press_menu.dart';
import '../../../widgets/common/smart_avatar.dart';
import '../../../widgets/user/avatar_action_menu.dart';
import '../../../widgets/user/user_card.dart';
import '../../../widgets/markdown_editor/emoji_popover.dart';
import '../../../widgets/markdown_editor/emoji_sticker_panel.dart';
import '../../../widgets/markdown_editor/markdown_renderer.dart';
import '../../image_viewer_page.dart';
import '../chat_list_page.dart' show ChatChannelAvatar, chatPreviewText;
import '../chat_channel_info_page.dart';
import '../chat_flag_sheet.dart';
import 'chat_composer_controller.dart';
import '../chat_search_page.dart';
import 'package:common_ui/common_ui.dart';
import 'chat_message_menu.dart';

part '_chat_composer.dart';
part '_chat_widgets.dart';
part '_message_bubble.dart';
part '_message_rows.dart';

/// 聊天窗:气泡流 + 底部常驻输入条
///
/// 视觉对齐 AiChatMessageItem(气泡)与 AiChatInput(输入条)。
/// [threadId] 非空时为 thread 面板形态:同一套气泡流,数据/订阅/发送
/// 全走 thread 维度,标题显示"消息串"。
class ChatChannelPage extends ConsumerStatefulWidget {
  final int channelId;
  final int? threadId;

  /// 非空:首屏锚点定位到这条消息并高亮(通知/链接直达)
  final int? initialMessageId;

  /// 桌面双栏嵌入形态:返回键走 [onEmbeddedBack] 而非 Navigator pop
  final bool embeddedMode;
  final VoidCallback? onEmbeddedBack;

  const ChatChannelPage({
    super.key,
    required this.channelId,
    this.threadId,
    this.initialMessageId,
    this.embeddedMode = false,
    this.onEmbeddedBack,
  });

  @override
  ConsumerState<ChatChannelPage> createState() => _ChatChannelPageState();
}

class _ChatChannelPageState extends ConsumerState<ChatChannelPage>
    with WidgetsBindingObserver {
  final AutoScrollController _scrollController = AutoScrollController();
  final ChatComposerController _inputController = ChatComposerController();
  final FocusNode _inputFocus = FocusNode();
  bool _canSend = false;

  /// 编辑态:非空表示输入条在编辑这条消息
  ChatMessage? _editing;

  /// 回复态:非空表示发送时带 in_reply_to_id
  ChatMessage? _replyingTo;

  /// 正在输入上报器(击键 enter presence,5s 静默/发送时 leave;
  /// hide_presence 用户完全静默)
  late final ChatTypingReporter _typingReporter = ChatTypingReporter(
    () => ref.read(discourseServiceProvider),
    widget.channelId,
    isEnabled: () => ref.read(currentUserProvider).value?.hidePresence != true,
  );

  /// 高亮的消息 id(定位跳转落点,3s 后淡出)
  int? _highlightedMessageId;

  /// 换窗口请求在途(盖整屏转圈;只在请求期间为 true,定位阶段已复位)
  bool _jumping = false;

  /// 跳转重入闸门(连点横幅时后一次直接忽略,不打断前一次)
  bool _jumpLock = false;

  /// 置顶横幅实占高度(浮在列表之上,跳转落点据此避让)。
  /// 只在跳转时读一次,不驱动重建,故用普通字段而非 ValueNotifier
  double _pinnedBannerHeight = 0;

  /// 落点收尾的最大重试帧数(每帧铺开一屏,够覆盖锚点窗口的 50 条)
  static const _settleMaxRetry = 10;

  /// 首屏锚点是否已收尾(ref.listen 只在状态变化时 fire,provider 已有
  /// 数据时不会回调,故 build 里也补一次判定,由这个标志去重)
  bool _settledAnchor = false;

  /// 活动锚点(进入时=widget.initialMessageId;"回到最新"时清空并原地
  /// 换 provider key 重载,不再整页路由替换)
  int? _anchorMessageId;

  /// 频道置顶消息(站点开 chat_pinned_messages 才有;进频道拉一次,
  /// pin/unpin 广播增量维护);多条时横幅点击轮换
  List<ChatMessage> _pins = const [];
  int _pinCursor = 0;

  /// 已展开的删除消息 id(官方口径:连续删除段折叠成一行,点击整段展开)
  final Set<int> _expandedDeletedIds = {};
  Timer? _highlightTimer;

  /// 多选模式:非空集合语义由 _selecting 承担(空集合=选择模式刚开启)
  bool _selecting = false;
  final Set<int> _selectedIds = {};

  /// 离开底部(reverse 列表 pixels>阈值)时显示"回到底部"浮钮
  /// 离底跟踪之外,滚动进行中标志:桌面 hover 工具条在滚动时抑制,
  /// 否则光标不动、气泡从下面划过,onEnter/onExit 连环触发 → 工具条
  /// 在不同消息上反复闪现(用户点名)。滚动停止 160ms 后复位。
  bool _awayFromBottom = false;
  final ValueNotifier<bool> _scrolling = ValueNotifier<bool>(false);
  Timer? _scrollIdleTimer;

  /// 悬浮输入条实占高度(卡 + 安全区 + 键盘/表情面板占位)。
  /// 输入条是浮在消息流之上的(TG 口径:内容能滚到它下面),父级量不到
  /// 这个数,由 HeightReporter 在输入条布局后回传;列表拿它做底部避让、
  /// "回到底部"浮钮拿它定位。
  ///
  /// 走 ValueNotifier 而非 setState:键盘弹出期间这个值逐帧在变,setState
  /// 会把整页(含列表 delegate)重建一遍。
  final ValueNotifier<double> _composerHeight = ValueNotifier<double>(0);

  /// 草稿:击键节流上报(对齐网页版 drafts 自动保存);进场回填
  Timer? _draftDebounce;
  String _lastSavedDraft = '';

  /// 已读上报去抖(官方 READ_INTERVAL_MS=1s:滚动/新消息触发都走它)
  Timer? _readDebounce;

  /// 前台判定(官方 userIsPresent):后台时不上报,回前台补报
  bool _userPresent = true;

  /// 列表 key:量各消息行相对视口的位置(可见已读口径)
  final GlobalKey _listKey = GlobalKey();

  /// composer key:返回键先收表情面板再退页(编辑器同款拦截)
  final GlobalKey<_ChatComposerState> _composerKey = GlobalKey();

  /// composer 面板开合(canPop 驱动:必须是页面级状态,composer 内部
  /// setState 不重建页面,快照会失真导致返回键直接退页)
  bool _composerPanelOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
    _inputController.addListener(() {
      final canSend = _inputController.text.trim().isNotEmpty;
      if (canSend != _canSend) setState(() => _canSend = canSend);
      if (_inputController.text.isNotEmpty) _typingReporter.onTyping();
      _scheduleDraftSave();
    });
    // 定位模式:锚点窗口由 provider key 带着首屏拉,滚动+高亮等首屏就绪
    // 后统一走 _settleOnMessage(高亮不在这里起,否则 3s 计时会在网络
    // 返回前就跑完,用户看不到落点)
    _anchorMessageId = widget.initialMessageId;
    if (widget.threadId == null) _loadPins();
    _restoreDraft();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 离开频道立即补报一次(官方 teardown 同款;去抖窗口内的滚动不丢)
    _readDebounce?.cancel();
    _reportVisibleRead();
    _typingReporter.dispose();
    _highlightTimer?.cancel();
    _scrollIdleTimer?.cancel();
    _scrolling.dispose();
    _composerHeight.dispose();
    _draftDebounce?.cancel();
    // 退出即存(不等节流窗口;编辑态不算草稿)
    if (_editing == null && _inputController.text != _lastSavedDraft) {
      _persistDraft(_inputController.text);
    }
    _scrollController.dispose();
    _inputController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final present = state == AppLifecycleState.resumed;
    if (present && !_userPresent) {
      _userPresent = true;
      // 回前台补报(官方 onUserPresent 同款)
      _scheduleMarkRead();
    } else {
      _userPresent = present;
    }
  }

  /// 进场回填草稿:current_user.chat_drafts 只在登录时下发一次,
  /// 本会话内新存的草稿以服务端为准——这里只做冷启动回填,够用
  void _restoreDraft() {
    final drafts = ref.read(currentUserProvider).value?.chatDrafts;
    if (drafts == null) return;
    final match = drafts.where((d) {
      final sameChannel = d['channel_id'] == widget.channelId;
      final draftThreadId = d['thread_id'] as int?;
      return sameChannel && draftThreadId == widget.threadId;
    }).firstOrNull;
    final dataRaw = match?['data'];
    if (dataRaw is! String || dataRaw.isEmpty) return;
    try {
      final data = jsonDecode(dataRaw) as Map<String, dynamic>;
      final message = data['message'] as String?;
      if (message != null &&
          message.isNotEmpty &&
          _inputController.text.isEmpty) {
        _inputController.text = message;
        _lastSavedDraft = message;
      }
    } catch (_) {
      // 草稿损坏静默忽略
    }
  }

  void _scheduleDraftSave() {
    if (_editing != null) return; // 编辑态不覆盖草稿
    _draftDebounce?.cancel();
    _draftDebounce = Timer(const Duration(seconds: 2), () {
      final text = _inputController.text;
      if (text == _lastSavedDraft) return;
      _persistDraft(text);
    });
  }

  void _persistDraft(String text) {
    _lastSavedDraft = text;
    unawaited(
      ref
          .read(discourseServiceProvider)
          .saveChatDraft(
            widget.channelId,
            threadId: widget.threadId,
            data: text.trim().isEmpty ? null : {'message': text},
          ),
    );
  }

  void _flashHighlight(int messageId) {
    _highlightTimer?.cancel();
    setState(() => _highlightedMessageId = messageId);
    _highlightTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _highlightedMessageId = null);
    });
  }

  /// 跳到某条消息:已在窗口内→滚动+高亮;窗口外→整页按锚点重进
  Future<void> _loadPins() async {
    try {
      final pins = await ref
          .read(discourseServiceProvider)
          .getChannelPins(widget.channelId);
      if (!mounted) return;
      setState(() {
        _pins = pins;
        _pinCursor = 0;
      });
      // 打开频道即视为看过置顶(顶栏徽记语义,静默失败无害)
      if (pins.isNotEmpty) {
        unawaited(
          ref
              .read(discourseServiceProvider)
              .markChannelPinsRead(widget.channelId)
              .catchError((_) {}),
        );
      }
    } catch (_) {
      // 站点未开 chat_pinned_messages 时 404,静默
    }
  }

  /// pin/unpin 广播落到消息流后,横幅列表跟着增删
  void _syncPinsFromMessages(List<ChatMessage> messages) {
    var changed = false;
    final pins = [..._pins];
    for (final m in messages) {
      final index = pins.indexWhere((p) => p.id == m.id);
      if (m.pinned && index < 0) {
        pins.add(m);
        changed = true;
      } else if (!m.pinned && index >= 0) {
        pins.removeAt(index);
        changed = true;
      } else if (index >= 0) {
        pins[index] = m;
      }
    }
    if (changed && mounted) {
      setState(() {
        _pins = pins;
        if (_pinCursor >= pins.length) _pinCursor = 0;
      });
    }
  }

  /// 跳到某条消息:窗口内→测几何瞬移;窗口外→原地换锚点窗口再瞬移
  ///
  /// 不再整页 pushReplacement(转场闪断,且丢滚动位置/草稿/多选态),
  /// 与 [_jumpToLatest] 同一口径:路由不动。
  ///
  /// 定位不走 scrollToIndex:目标 tag 未挂载时它会用最近 tag 的几何
  /// 外推、每步一小段 animateTo 逐步逼近,气泡行高可变又没给
  /// suggestedRowHeight,外推常常一步不动就提前 break —— 表现为"滚一点
  /// 就停,第二次点才对"(第二次目标已挂载,走的是快路径)。这里改成
  /// 先确保目标在窗口内,再按真实几何一次 jumpTo。
  Future<void> _jumpToMessage(int messageId) async {
    if (_jumpLock) return;
    _jumpLock = true;
    try {
      final state = ref.read(chatMessagesProvider(_streamKey)).value;
      final inWindowNow =
          state?.messages.any((m) => m.id == messageId) ?? false;
      // 只有真要请求才盖转圈:已在窗口内时盖一下再撤是无谓闪烁
      if (!inWindowNow) setState(() => _jumping = true);
      try {
        final inWindow = await _notifier.loadWindowAround(messageId);
        if (!mounted) return;
        if (!inWindow) {
          // 服务端锚点窗口里没有它:多半已被删除
          ToastService.showError(S.current.error_notFoundOrDeleted);
          return;
        }
      } catch (_) {
        // 换窗口失败(网络等):旧窗口没动,提示一下即可
        if (mounted) ToastService.showError(S.current.error_loadFailed);
        return;
      } finally {
        // 撤转圈必须在定位之前:转圈盖着时列表是卸载状态,
        // AutoScrollTag 不在 tagMap 里,几何永远测不到
        if (_jumping) {
          if (mounted) {
            setState(() => _jumping = false);
          } else {
            _jumping = false;
          }
        }
      }
      await _settleOnMessage(messageId);
    } finally {
      _jumpLock = false;
    }
  }

  /// 落点收尾:目标行挂载后按真实几何瞬移 + 高亮
  ///
  /// 目标可能"在窗口内但还没挂载"(在 ListView 缓存区外,tagMap 里没有),
  /// 此时测不到几何,等下一帧重试;列表每帧会多铺一点,几帧内必然挂上。
  /// 参照话题详情页 _finalizeInitialPosition 的 postFrame+retry 模式。
  Future<void> _settleOnMessage(int messageId, {int retry = 0}) async {
    await SchedulerBinding.instance.endOfFrame;
    if (!mounted) return;

    // 列表刚从转圈切回来时要等一帧才有 client,不能当失败退出
    if (!_scrollController.hasClients) {
      if (retry >= _settleMaxRetry) return;
      await _settleOnMessage(messageId, retry: retry + 1);
      return;
    }

    // reverse 列表:getOffsetToReveal 的 alignment 相对滚动前缘(视觉下方),
    // 要贴视觉顶得传 1
    final offset = _scrollController.topAlignOffsetForScrollIndex(
      messageId,
      alignment: 1.0,
    );
    if (offset == null) {
      if (retry >= _settleMaxRetry) {
        // 极端情况(行始终没挂上):退回包内爬行定位,尽力而为
        unawaited(
          _scrollController.scrollToIndex(
            messageId,
            preferPosition: AutoScrollPosition.middle,
            duration: const Duration(milliseconds: 250),
          ),
        );
        _flashHighlight(messageId);
        return;
      }
      // 逼近目标:先让列表往目标方向铺开,下一帧再测。
      // 每次重试都推一把 —— 一次推动只铺开一屏,目标远在缓存区外时
      // 要连推几帧才够得着
      _nudgeTowards(messageId);
      await _settleOnMessage(messageId, retry: retry + 1);
      return;
    }

    final position = _scrollController.position;
    // 顶对齐会让目标压在置顶横幅底下(横幅浮在列表之上,不占列表空间),
    // 落点退掉横幅高度让它整条露出来 —— 不额外留白,消息自己的行间距
    // 就是视觉呼吸位。
    // reverse 列表沿 AxisDirection.up 滚动:pixels 增大 = 视口移向更旧的
    // 消息 = 目标相对视口往下移,所以是 +avoid(方向由 scroll_jump_test
    // 的"浮层避让方向"用例钉住)
    final avoid = _pins.isEmpty ? 0.0 : _pinnedBannerHeight;
    // jumpTo 而非 animateTo:动画期 velocity≠0,期间若列表重新布局导致
    // maxScrollExtent 收缩,位置会留在边界外并被弹回(详见 scroll_jump.dart)
    _scrollController.jumpTo(
      (offset + avoid).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
    // 高亮计时到落点才起:重载慢于 3s 时提前起会让用户看不到落点
    _flashHighlight(messageId);
    // 构造性定位不产生滚动事件,落点可能正处在分页触发区,主动评估一次
    _onScroll();
  }

  /// 目标未挂载时朝它的方向推一把,让 ListView 下一帧把它铺出来
  void _nudgeTowards(int messageId) {
    if (!_scrollController.hasClients) return;
    final anchored = _scrollController.tagMap.keys;
    if (anchored.isEmpty) return;
    // reverse 列表:消息 id 越小(越旧)越靠 pixels 大的一侧
    final nearest = messageId < anchored.reduce(math.min)
        ? anchored.reduce(math.min)
        : anchored.reduce(math.max);
    final nearestOffset = _scrollController.topAlignOffsetForScrollIndex(
      nearest,
      alignment: 1.0,
    );
    if (nearestOffset == null) return;
    final position = _scrollController.position;
    _scrollController.jumpTo(
      nearestOffset.clamp(position.minScrollExtent, position.maxScrollExtent),
    );
  }

  /// 会话内搜索(channel_id 限定,点结果锚点跳转)
  void _openInChannelSearch() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatSearchPage(channelId: widget.channelId),
      ),
    );
  }

  /// AI 总结近期消息:选时间档 → 请求 → 弹层渲染 markdown
  Future<void> _summarize() async {
    const options = [1, 3, 6, 12, 24, 72, 168];
    final since = await AppBottomSheet.show<int>(
      context: context,
      title: S.current.chat_summarize,
      showCloseButton: false,
      contentPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final h in options)
            ListTile(
              title: Text(
                h < 24
                    ? sheetContext.l10n.chat_summarizeHours(h)
                    : sheetContext.l10n.chat_summarizeDays(h ~/ 24),
              ),
              onTap: () => Navigator.pop(sheetContext, h),
            ),
        ],
      ),
    );
    if (since == null || !mounted) return;
    // 慢请求:骨架弹层等待,完成后原地换渲染。
    // future 必须在 bodyBuilder 外创建一次——DraggableScrollableSheet
    // 拖动会反复 rebuild,内联创建等于拖一下请求一次
    final future = ref
        .read(discourseServiceProvider)
        .summarizeChatChannel(widget.channelId, sinceHours: since);
    unawaited(
      AppBottomSheet.showDraggable<void>(
        context: context,
        title: S.current.chat_summarize,
        initialSize: 0.6,
        bodyBuilder: (sheetContext, scrollController) => FutureBuilder<String>(
          future: future,
          builder: (futureContext, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: LoadingSpinner());
            }
            if (snapshot.hasError) {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Text(snapshot.error.toString()),
              );
            }
            final summary = snapshot.data ?? '';
            return SingleChildScrollView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              // 总结是 AI 生成的 markdown(含 /t/-/... 消息链接),
              // cook 后走新引擎渲染,链接可点
              child: MarkdownBody(data: summary),
            );
          },
        ),
      ),
    );
  }

  /// 当前频道(DM 与公共频道双列表查找——只查 DM 会让公共频道
  /// 处处拿到 null:标题不可点/能力位全关/回复分流失效)
  ChatChannel? _findChannel() {
    final state = ref.read(chatChannelsProvider).value;
    if (state == null) return null;
    return [
      ...state.directMessageChannels,
      ...state.publicChannels,
    ].where((c) => c.id == widget.channelId).firstOrNull;
  }

  ChatStreamKey get _streamKey => (
    channelId: widget.channelId,
    threadId: widget.threadId,
    targetMessageId: _anchorMessageId,
  );

  ChatMessagesNotifier get _notifier =>
      ref.read(chatMessagesProvider(_streamKey).notifier);

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    // 列表 reverse:true —— pixels 越大越接近历史顶部
    if (position.pixels > position.maxScrollExtent - 400) {
      _notifier.loadPast();
    }
    if (position.pixels < 200) {
      _notifier.loadFuture();
    }
    // 已读上报(官方口径:滚动即触发,1s 去抖,报视口内可见的最新消息
    // ——历史区渐进推进,不只贴底才报)
    _scheduleMarkRead();
    final away = position.pixels > 600;
    if (away != _awayFromBottom) {
      setState(() => _awayFromBottom = away);
    }
    // 滚动进行中:抑制 hover 工具条;停止 160ms 后复位
    if (!_scrolling.value) _scrolling.value = true;
    _scrollIdleTimer?.cancel();
    _scrollIdleTimer = Timer(const Duration(milliseconds: 160), () {
      _scrolling.value = false;
    });
  }

  /// 回到最新:窗口含最新页直接滚底;不含最新页(锚点定位/往新翻页
  /// 未到底)时清锚点原地重载——provider key 变化自动拉最新窗口,
  /// 页面路由不动(旧版整页 pushReplacement 有转场闪断)
  void _jumpToLatest() {
    final state = ref.read(chatMessagesProvider(_streamKey)).value;
    if (state != null && !state.canLoadMoreFuture) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
      return;
    }
    if (_anchorMessageId != null) {
      // key 变化 → 新 provider 按 fetchFromLastRead 拉最新窗口
      setState(() => _anchorMessageId = null);
    } else {
      // 无锚点但窗口不含最新页:同 key 强制重载
      ref.invalidate(chatMessagesProvider(_streamKey));
    }
  }

  Future<void> _send({List<int> uploadIds = const []}) async {
    final text = _inputController.text;
    if (text.trim().isEmpty && uploadIds.isEmpty) return;
    _typingReporter.stop();
    // 发送即清草稿意图:服务端发送成功会自动清 draft 记录,本地只需
    // 取消待发的节流保存并同步基线
    _draftDebounce?.cancel();
    _lastSavedDraft = '';

    // 编辑态:提交编辑而不是发新消息
    final editing = _editing;
    if (editing != null) {
      _inputController.clear();
      setState(() => _editing = null);
      try {
        await _notifier.edit(editing.id, text);
      } catch (e) {
        if (mounted) {
          // 编辑失败:恢复编辑态让用户重试,不丢草稿
          _inputController.text = text;
          setState(() => _editing = editing);
        }
      }
      return;
    }

    final replyTo = _replyingTo;
    _inputController.clear();
    if (replyTo != null) setState(() => _replyingTo = null);
    // 发送后滚回底部(reverse 列表底部是 0)
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
    await _notifier.send(text, inReplyToId: replyTo?.id, uploadIds: uploadIds);
  }

  /// 表情包直发:不经输入框,选中即独立成一条消息发出;
  /// 带回复上下文时作为回复发出并清除回复条
  Future<void> _sendSticker(String markdown) async {
    final replyTo = _replyingTo;
    if (replyTo != null) setState(() => _replyingTo = null);
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
    await _notifier.send(markdown, inReplyToId: replyTo?.id);
  }

  /// 长按头像菜单的 @提及:光标处插入 @username ,聚焦输入框
  void _mentionUser(String username) {
    final controller = _inputController;
    final value = controller.value;
    final sel = value.selection;
    final start = sel.isValid ? sel.start : value.text.length;
    final end = sel.isValid ? sel.end : value.text.length;
    // 前一字符非空白时补个空格,避免粘连成无效提及
    final needLeadingSpace =
        start > 0 && !value.text.substring(start - 1, start).trim().isEmpty;
    final insert = '${needLeadingSpace ? ' ' : ''}@$username ';
    controller.value = TextEditingValue(
      text: value.text.replaceRange(start, end, insert),
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
    _inputFocus.requestFocus();
  }

  /// 触发消息菜单:移动=长按 overlay;桌面=锚点菜单(右键位置或
  /// hover 工具条按钮位置)。
  Future<void> _onMessageMenu(
    ChatMessage message,
    bool isSelf, {
    Rect? bubbleRect,
    Widget Function(BuildContext)? bubbleBuilder,
    Offset? anchorPosition,
  }) async {
    if (message.isStaged) return;
    final channel = _findChannel();
    final caps = ChatMessageCaps.compute(
      message: message,
      isSelf: isSelf,
      channel: channel,
    );
    final quickReactions = await loadQuickReactions();
    if (!mounted) return;

    // 长按前表情面板开着:浮层 push/pop 会让输入框失焦/恢复,触发
    // 面板容器的焦点监听把表情面板切成键盘(弹键盘,用户点名)。
    // 取消浮层后恢复表情面板;选了动作则不恢复(按动作走,如回复要
    // 输入键盘)。
    final wasEmojiPanel = _composerKey.currentState?.isEmojiPanelOpen ?? false;
    final ChatMessageMenuResult? result;
    if (PlatformUtils.isDesktop && anchorPosition != null) {
      result = await showChatMessageContextMenu(
        context: context,
        globalPosition: anchorPosition,
        message: message,
        isSelf: isSelf,
        caps: caps,
        quickReactions: quickReactions,
      );
    } else if (bubbleRect != null && bubbleBuilder != null) {
      result = await showChatMessageActionsOverlay(
        context: context,
        bubbleRect: bubbleRect,
        bubbleBuilder: bubbleBuilder,
        message: message,
        caps: caps,
        quickReactions: quickReactions,
      );
    } else {
      return;
    }
    if (result == null || !mounted) {
      // 取消浮层:恢复长按前的表情面板(不弹键盘)
      if (wasEmojiPanel && mounted) {
        _composerKey.currentState?.restoreEmojiPanel();
      }
      return;
    }
    final (action, emoji) = result;

    if (emoji != null) {
      unawaited(bumpRecentReaction(emoji));
      await _notifier.toggleReaction(message.id, emoji);
      return;
    }
    switch (action) {
      case ChatMessageAction.reply:
        await _startReply(message);
      case ChatMessageAction.copyLink:
        copyChatMessageLink(message);
      case ChatMessageAction.copyText:
        copyChatMessageText(message);
      case ChatMessageAction.edit:
        setState(() {
          _replyingTo = null;
          _editing = message;
          _inputController.text = message.message;
        });
        _inputFocus.requestFocus();
      case ChatMessageAction.delete:
        final confirmed = await showAppDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(dialogContext.l10n.chat_deleteConfirm),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(dialogContext.l10n.common_cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(
                  dialogContext.l10n.chat_menuDelete,
                  style: TextStyle(
                    color: Theme.of(dialogContext).colorScheme.error,
                  ),
                ),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          await _notifier.delete(message.id);
        }
      case ChatMessageAction.flag:
        await showChatFlagSheet(context: context, message: message);
      case ChatMessageAction.select:
        setState(() {
          _selecting = true;
          _selectedIds
            ..clear()
            ..add(message.id);
        });
      case ChatMessageAction.restore:
        await _notifier.restore(message.id);
      case ChatMessageAction.bookmark:
        try {
          await _notifier.toggleBookmark(message.id);
        } catch (e) {
          ToastService.showError(e.toString());
        }
      case ChatMessageAction.pin:
      case ChatMessageAction.unpin:
        try {
          await _notifier.togglePin(
            message.id,
            pin: action == ChatMessageAction.pin,
          );
        } catch (e) {
          ToastService.showError(e.toString());
        }
      case null:
        break;
    }
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelected(int messageId) {
    setState(() {
      if (!_selectedIds.add(messageId)) _selectedIds.remove(messageId);
    });
  }

  /// 引用所选:服务端生成 transcript markdown,复制到剪贴板
  Future<void> _quoteSelected() async {
    if (_selectedIds.isEmpty) return;
    try {
      final markdown = await ref
          .read(discourseServiceProvider)
          .quoteChatMessages(widget.channelId, _selectedIds.toList()..sort());
      if (markdown.isNotEmpty) {
        await Clipboard.setData(ClipboardData(text: markdown));
        ToastService.showSuccess(S.current.chat_quoteCopied);
      }
      _exitSelection();
    } catch (e) {
      ToastService.showError(e.toString());
    }
  }

  /// 复制所选原文(按 id 顺序拼接)
  void _copySelected() {
    final state = ref.read(chatMessagesProvider(_streamKey)).value;
    if (state == null || _selectedIds.isEmpty) return;
    final texts = [
      for (final m in state.messages)
        if (_selectedIds.contains(m.id) && !m.isDeleted) m.message,
    ];
    Clipboard.setData(ClipboardData(text: texts.join('\n\n')));
    ToastService.showSuccess(S.current.common_copiedToClipboard);
    _exitSelection();
  }

  /// 批量删除所选(仅自己的可删;工具栏按钮已按此禁用)
  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          dialogContext.l10n.chat_deleteSelectedConfirm(_selectedIds.length),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(dialogContext.l10n.common_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              dialogContext.l10n.chat_menuDelete,
              style: TextStyle(
                color: Theme.of(dialogContext).colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref
          .read(discourseServiceProvider)
          .deleteChatMessages(widget.channelId, _selectedIds.toList());
      _exitSelection();
    } catch (e) {
      ToastService.showError(e.toString());
    }
  }

  /// 所选是否全部可删(全是自己的,或频道允许删他人)
  bool _canDeleteSelected() {
    final state = ref.read(chatMessagesProvider(_streamKey)).value;
    final channel = _findChannel();
    final currentUserId = ref.read(currentUserProvider).value?.id;
    if (state == null || currentUserId == null) return false;
    for (final m in state.messages) {
      if (!_selectedIds.contains(m.id)) continue;
      final isSelf = m.user?.id == currentUserId;
      final can = isSelf
          ? (channel?.canDeleteSelf ?? true)
          : (channel?.canDeleteOthers ?? false);
      if (!can) return false;
    }
    return true;
  }

  /// 打开 thread 面板(窄屏 push,宽屏也 push——thread 是临时查看面)
  void _openThread(int threadId) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ChatChannelPage(channelId: widget.channelId, threadId: threadId),
      ),
    );
  }

  /// 回复语义分流(对齐网页版):
  /// - threading 频道 + 主流:回复 = 进消息串(已有串直接进,没有则建),
  ///   平面 in_reply_to 的 sent 广播只发 thread 子通道,主流对账不到
  /// - 非 threading 频道 / thread 面板内:平面 in_reply_to 回复态
  Future<void> _startReply(ChatMessage message) async {
    final channel = _findChannel();
    final threading = channel?.threadingEnabled ?? false;

    if (threading && widget.threadId == null && !message.isStaged) {
      try {
        final existingThreadId = message.thread?.id ?? message.threadId;
        final threadId =
            existingThreadId ??
            await ref
                .read(discourseServiceProvider)
                .createChatThread(
                  widget.channelId,
                  originalMessageId: message.id,
                );
        if (!mounted) return;
        _openThread(threadId);
      } catch (e) {
        ToastService.showError(e.toString());
      }
      return;
    }

    setState(() {
      _editing = null;
      _replyingTo = message;
    });
    _inputFocus.requestFocus();
  }

  Future<void> _onQuickReact(ChatMessage message, String emoji) async {
    unawaited(bumpRecentReaction(emoji));
    await _notifier.toggleReaction(message.id, emoji);
  }

  /// 在窗口底部即把已读位推进到窗口内最新一条(渐进上报,服务端单调)。
  /// 不再要求窗口含全站最新页:锚点进入大量未读时那个条件永不满足,
  /// 已读永不上报,列表徽章永不清(网页版进一下频道才好=它替我们报了)。
  void _scheduleMarkRead() {
    _readDebounce?.cancel();
    _readDebounce = Timer(const Duration(seconds: 1), () {
      if (mounted) _reportVisibleRead();
    });
  }

  /// 视口内底缘完全可见的最新消息 id(官方 firstVisibleMessageId 口径,
  /// reverse 列表下即"看到哪");量不到时返回 null
  int? _lastVisibleMessageId() {
    if (!_scrollController.hasClients) return null;
    final listBox = _listKey.currentContext?.findRenderObject() as RenderBox?;
    if (listBox == null || !listBox.attached) return null;
    final listTop = listBox.localToGlobal(Offset.zero).dy;
    // 列表铺到屏幕底,输入条悬浮在它上面——被条盖住的行不算"看到了",
    // 可视下界要把条的高度扣回去(否则滚动时会把压在条底下的消息
    // 一并标成已读)
    final listBottom = listTop + listBox.size.height - _composerHeight.value;
    int? best;
    // AutoScrollTag 注册表:key=消息 id(缓存区外的行不在表里,
    // 缓存区内但视口外的行由位置判定滤掉)
    for (final entry in _scrollController.tagMap.entries) {
      final box = entry.value.context.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      final bottom = box.localToGlobal(Offset.zero).dy + box.size.height;
      if (bottom <= listBottom + 1 && bottom >= listTop) {
        if (best == null || entry.key > best) best = entry.key;
      }
    }
    return best;
  }

  void _reportVisibleRead() {
    // 官方三道门:在场 + 已 follow 频道 + 有内容
    if (!_userPresent) return;
    final channel = _findChannel();
    if (channel?.currentUserMembership?.following != true) return;
    final state = ref.read(chatMessagesProvider(_streamKey)).value;
    if (state == null || state.messages.isEmpty) return;
    var visibleId = _lastVisibleMessageId();
    // 量不到(极端时序/行全在缓存外)退回贴底口径,不误报深处消息
    if (visibleId == null &&
        _scrollController.hasClients &&
        _scrollController.position.pixels <= 100) {
      visibleId = state.messages.where((m) => !m.isStaged).lastOrNull?.id;
    }
    if (visibleId != null) _notifier.markReadUpTo(visibleId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final messagesAsync = ref.watch(chatMessagesProvider(_streamKey));
    final channelsState = ref.watch(chatChannelsProvider).value;
    final channel = channelsState == null
        ? null
        : [
            ...channelsState.directMessageChannels,
            ...channelsState.publicChannels,
          ].where((c) => c.id == widget.channelId).firstOrNull;

    ref.listen(chatMessagesProvider(_streamKey), (prev, next) {
      final state = next.value;
      if (state == null) return;
      // 锚点模式首屏就绪:滚到目标消息并高亮(仅一次,prev 无数据时)
      // 与跳转同源,走同一套落点收尾
      final target = _anchorMessageId;
      if (target != null && prev?.value == null && !_settledAnchor) {
        _settledAnchor = true;
        unawaited(_settleOnMessage(target));
      }
      _scheduleMarkRead();
      if (widget.threadId == null) _syncPinsFromMessages(state.messages);
    });

    // provider 已有数据时上面的 listen 不会 fire(它只在状态变化时回调),
    // 首屏锚点会永远等不到滚动 —— 这里补一次同样的判定。
    // _settleOnMessage 首句就 await endOfFrame,不会在 build 期间动状态
    final anchor = _anchorMessageId;
    if (anchor != null && !_settledAnchor && messagesAsync.value != null) {
      _settledAnchor = true;
      unawaited(_settleOnMessage(anchor));
    }

    return PopScope(
      // 移动端表情面板开着时,返回键先收面板(编辑器同款),不退页
      canPop: PlatformUtils.isDesktop || !_composerPanelOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _composerKey.currentState?.closePanel();
      },
      child: Scaffold(
        // 键盘让位由 ChatBottomPanelContainer 的占位承担(编辑器同款),
        // Scaffold 再 resize 会双重抬升
        resizeToAvoidBottomInset: false,
        appBar: _selecting
            ? AppBar(
                leading: IconButton(
                  icon: const Icon(Symbols.close_rounded),
                  onPressed: _exitSelection,
                ),
                title: Text(
                  context.l10n.chat_selectedCount(_selectedIds.length),
                ),
              )
            : AppBar(
                automaticallyImplyLeading: !widget.embeddedMode,
                leading: widget.embeddedMode && widget.onEmbeddedBack != null
                    ? BackButton(onPressed: widget.onEmbeddedBack)
                    : null,
                titleSpacing: 0,
                title: _buildTitle(channel),
                actions: [
                  SwipeDismissiblePopupMenuButton<String>(
                    icon: const Icon(Symbols.more_vert_rounded),
                    onSelected: (value) {
                      switch (value) {
                        case 'search':
                          _openInChannelSearch();
                        case 'summarize':
                          _summarize();
                        case 'refresh':
                          // 整流重载:重拉频道详情+消息窗口+重订阅 bus
                          // (断连漏消息/漏事件时的手动兜底)
                          ref.invalidate(chatMessagesProvider(_streamKey));
                      }
                    },
                    itemBuilder: (menuContext) => [
                      PopupMenuItem(
                        value: 'search',
                        child: Row(
                          children: [
                            const Icon(Symbols.search_rounded, size: 20),
                            const SizedBox(width: 12),
                            Text(menuContext.l10n.chat_searchInChannel),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'summarize',
                        child: Row(
                          children: [
                            const Icon(Symbols.summarize_rounded, size: 20),
                            const SizedBox(width: 12),
                            Text(menuContext.l10n.chat_summarize),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'refresh',
                        child: Row(
                          children: [
                            const Icon(Symbols.refresh_rounded, size: 20),
                            const SizedBox(width: 12),
                            Text(menuContext.l10n.chat_refresh),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
        body: Stack(
          children: [
            // 消息流铺满整页:内容能滚到输入条下方(TG 口径),不再被
            // Expanded 切在条上沿。静止时的底部避让由列表自己的
            // 避让位承担(见 _buildMessageList),值取 _composerHeight
            Positioned.fill(
              child: messagesAsync.when(
                // 跳转换窗口期间同样整屏转圈(与首屏加载一个观感)。
                // 由页面自己的 _jumping 驱动、不进 provider 状态:标志位
                // 放进 state 会被 MessageBus 广播的 copyWith 带着走,
                // 广播频繁的大频道里极易固化成永久 loading
                data: (state) => _jumping
                    ? const Center(child: LoadingSpinner())
                    : _buildMessageList(theme, state),
                loading: () => const Center(child: LoadingSpinner()),
                error: (error, stack) => ErrorView(
                  error: error,
                  stackTrace: stack,
                  onRetry: () =>
                      ref.invalidate(chatMessagesProvider(_streamKey)),
                ),
              ),
            ),
            // 置顶横幅:顶栏下,点击跳转,多条轮换
            if (_pins.isNotEmpty)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                // 横幅浮在列表之上(列表铺满整页),跳转落点要扣掉它的
                // 高度才不会顶死在它下沿 —— 与输入条同一套量法
                child: HeightReporter(
                  onHeight: (height) => _pinnedBannerHeight = height,
                  child: _PinnedBanner(
                    pins: _pins,
                    cursor: _pinCursor % _pins.length,
                    onTap: () async {
                      final pin = _pins[_pinCursor % _pins.length];
                      await _jumpToMessage(pin.id);
                      // 轮换放在跳转之后:跳失败时不该把指示器推到下一条
                      if (!mounted) return;
                      setState(
                        () => _pinCursor = (_pinCursor + 1) % _pins.length,
                      );
                    },
                  ),
                ),
              ),
            // 回到底部浮钮(离底/锚点模式时出现):钉在输入条上沿
            ValueListenableBuilder<double>(
              valueListenable: _composerHeight,
              builder: (context, composerHeight, child) => Positioned(
                right: 16,
                bottom: composerHeight + 12,
                child: child!,
              ),
              child: AnimatedScale(
                scale:
                    _awayFromBottom ||
                        (messagesAsync.value?.canLoadMoreFuture ?? false)
                    ? 1
                    : 0,
                duration: const Duration(milliseconds: 150),
                child: FloatingActionButton.small(
                  heroTag: 'chatJumpBottom_${widget.channelId}',
                  elevation: 2,
                  onPressed: _jumpToLatest,
                  child: const Icon(Symbols.keyboard_double_arrow_down_rounded),
                ),
              ),
            ),
            // 输入条/多选工具条:悬浮贴底,高度回传给列表做避让
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: HeightReporter(
                onHeight: (height) => _composerHeight.value = height,
                child: _selecting
                    ? _SelectionToolbar(
                        count: _selectedIds.length,
                        canDelete:
                            _selectedIds.isNotEmpty && _canDeleteSelected(),
                        onQuote: _quoteSelected,
                        onCopy: _copySelected,
                        onDelete: _deleteSelected,
                      )
                    : _ChatComposer(
                        key: _composerKey,
                        onPanelOpenChanged: (open) {
                          if (mounted && _composerPanelOpen != open) {
                            setState(() => _composerPanelOpen = open);
                          }
                        },
                        controller: _inputController,
                        focusNode: _inputFocus,
                        canSend: _canSend,
                        editing: _editing,
                        replyingTo: _replyingTo,
                        onSend: (uploadIds) => _send(uploadIds: uploadIds),
                        onSendSticker: _sendSticker,
                        onCancelContext: () => setState(() {
                          if (_editing != null) _inputController.clear();
                          _editing = null;
                          _replyingTo = null;
                        }),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTitle(ChatChannel? channel) {
    final theme = Theme.of(context);
    // thread 面板:标题固定"消息串",副标题带频道名
    if (widget.threadId != null) {
      final channelTitle = channel?.title?.isNotEmpty == true
          ? channel!.title!
          : channel?.dmUsers.map((u) => u.username).join(', ') ?? '';
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.chat_threadTitle,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (channelTitle.isNotEmpty)
              Text(
                channelTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      );
    }
    if (channel == null) return const SizedBox.shrink();
    final title = channel.title?.isNotEmpty == true
        ? channel.title!
        : channel.dmUsers.map((u) => u.username).join(', ');
    return InkWell(
      // 标题统一进会话详情页(成员管理/退出;1:1 里再跳资料)
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatChannelInfoPage(channelId: widget.channelId),
        ),
      ),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ChatChannelAvatar(channel: channel, radius: 17),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  _buildSubtitle(theme, channel),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶栏副标题:有人输入时显示"xxx 正在输入…"(主色+动画点),
  /// 空闲回落成员数;1:1 DM 空闲无副标题
  Widget _buildSubtitle(ThemeData theme, ChatChannel channel) {
    final typingUsers = widget.threadId == null
        ? ref.watch(chatTypingProvider(widget.channelId))
        : const <TypingUser>[];
    if (typingUsers.isNotEmpty) {
      return _TypingSubtitle(
        text: typingUsers.length == 1
            ? context.l10n.chat_typingOne(typingUsers.first.username)
            : context.l10n.chat_typingMany(typingUsers.length),
        style: theme.textTheme.labelSmall!.copyWith(
          color: theme.colorScheme.primary,
        ),
      );
    }
    if ((channel.isGroupDm || channel.isPublicChannel) &&
        (channel.membershipsCount ?? 0) > 0) {
      return Text(
        context.l10n.chat_memberCount(channel.membershipsCount!),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildMessageList(ThemeData theme, ChatMessagesState state) {
    if (state.messages.isEmpty) {
      return Center(
        child: Text(
          context.l10n.chat_noMessages,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final currentUserId = ref.watch(currentUserProvider).value?.id;
    // reverse 列表:index 0 = 最新消息,渲染时倒着取
    final messages = state.messages;

    return ListView.builder(
      key: _listKey,
      controller: _scrollController,
      reverse: true,
      // 水平边距由行自管(桌面宽/移动窄),列表层不再叠一层
      padding: const EdgeInsets.symmetric(vertical: 8),
      // +1 = 悬浮输入条的避让位(reverse 列表 index 0 在视觉最底)
      itemCount: messages.length + 1 + (state.loadingPast ? 1 : 0),
      itemBuilder: (context, rawIndex) {
        // 避让位做成列表首项、而不是列表的 bottom padding:键盘弹出
        // 期间输入条高度逐帧在变,改 padding 等于每帧换一个新的
        // delegate(可见行全量 rebuild);换成这一个 SizedBox,逐帧
        // 变化只触发重新布局。
        if (rawIndex == 0) {
          return ValueListenableBuilder<double>(
            valueListenable: _composerHeight,
            builder: (context, height, _) => SizedBox(height: height),
          );
        }
        final index = rawIndex - 1;
        if (index >= messages.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Center(
              child: SizedBox(width: 22, height: 22, child: LoadingSpinner()),
            ),
          );
        }
        final i = messages.length - 1 - index;
        final message = messages[i];
        final prev = i > 0 ? messages[i - 1] : null;

        // 删除折叠(官方 shouldRender 口径):连续删除段里,只有最新一条
        // 渲染折叠入口,更早的同段消息不渲染;展开后逐条正常渲染
        bool collapsedDeleted(ChatMessage m) =>
            m.isDeleted && !_expandedDeletedIds.contains(m.id);
        final next = i + 1 < messages.length ? messages[i + 1] : null;
        if (collapsedDeleted(message) &&
            next != null &&
            collapsedDeleted(next)) {
          return const SizedBox.shrink();
        }
        var deletedRunCount = 0;
        if (collapsedDeleted(message)) {
          for (var j = i; j >= 0 && collapsedDeleted(messages[j]); j--) {
            deletedRunCount++;
          }
        }
        final isSelf =
            currentUserId != null && message.user?.id == currentUserId;
        // 同人 5 分钟内连续消息聚簇:只有簇首显示头像和名字
        final clustered =
            prev != null &&
            prev.user?.id == message.user?.id &&
            !prev.isDeleted &&
            message.createdAt != null &&
            prev.createdAt != null &&
            message.createdAt!.difference(prev.createdAt!).inMinutes < 5;
        final showDayDivider =
            prev == null ||
            (message.createdAt != null &&
                prev.createdAt != null &&
                !_sameDay(message.createdAt!, prev.createdAt!));
        final showUnreadDivider =
            state.initialLastReadId != null &&
            prev != null &&
            prev.id == state.initialLastReadId &&
            message.id > state.initialLastReadId! &&
            !isSelf;

        return AutoScrollTag(
          key: ValueKey('chat_msg_${message.id}'),
          controller: _scrollController,
          index: message.id,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showDayDivider && message.createdAt != null)
                _DayDivider(date: message.createdAt!),
              if (showUnreadDivider) const _UnreadDivider(),
              _wrapSelectable(
                message,
                _MessageBubble(
                  message: message,
                  isSelf: isSelf,
                  clustered: clustered && !showDayDivider && !showUnreadDivider,
                  scrolling: _scrolling,
                  highlighted: _highlightedMessageId == message.id,
                  onMenuRequested:
                      (bubbleRect, bubbleBuilder, anchorPosition) =>
                          _onMessageMenu(
                            message,
                            isSelf,
                            bubbleRect: bubbleRect,
                            bubbleBuilder: bubbleBuilder,
                            anchorPosition: anchorPosition,
                          ),
                  onQuickReply: () => _startReply(message),
                  onQuickReact: (emoji) => _onQuickReact(message, emoji),
                  onReactionTap: (emoji) => _onQuickReact(message, emoji),
                  onReplyRefTap: message.inReplyTo != null
                      ? () => _jumpToMessage(message.inReplyTo!.id)
                      : null,
                  // thread 面板里不再嵌套入口
                  onOpenThread:
                      widget.threadId == null &&
                          message.thread != null &&
                          message.thread!.replyCount > 0
                      ? () => _openThread(message.thread!.id)
                      : null,
                  onRetry: message.sendState == ChatMessageSendState.failed
                      ? () => _notifier.resend(message.stagedId!)
                      : null,
                  onDiscard: message.sendState == ChatMessageSendState.failed
                      ? () => _notifier.removeStaged(message.stagedId!)
                      : null,
                  onMentionUser: _mentionUser,
                  onToggleBookmark: () async {
                    try {
                      await _notifier.toggleBookmark(message.id);
                    } catch (e) {
                      ToastService.showError(e.toString());
                    }
                  },
                  deletedRunCount: deletedRunCount,
                  deletedExpanded: message.isDeleted
                      ? _expandedDeletedIds.contains(message.id)
                      : false,
                  onExpandDeleted: deletedRunCount > 0
                      ? () => setState(() {
                          for (
                            var j = i;
                            j >= 0 && messages[j].isDeleted;
                            j--
                          ) {
                            _expandedDeletedIds.add(messages[j].id);
                          }
                        })
                      : null,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 选择模式:气泡左侧勾选圈,整行点击 toggle 并吞掉气泡内交互
  Widget _wrapSelectable(ChatMessage message, Widget bubble) {
    if (!_selecting) return bubble;
    final selectable = !message.isStaged && !message.isDeleted;
    final selected = _selectedIds.contains(message.id);
    final theme = Theme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: selectable ? () => _toggleSelected(message.id) : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Icon(
              selected ? Symbols.check_circle_rounded : Symbols.circle_rounded,
              fill: selected ? 1 : 0,
              size: 22,
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
            ),
          ),
          Expanded(child: IgnorePointer(child: bubble)),
        ],
      ),
    );
  }

  static bool _sameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }
}

