import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../../models/draft.dart';
import '../../../models/topic.dart';
import '../../../services/discourse/discourse_service.dart';
import '../../../services/draft_controller.dart';
import '../../../services/local_draft_store.dart';
import '../../../services/presence_service.dart';
import '../../../widgets/common/emoji_text_editing_controller.dart';

/// 正在写的回复里有内容时，又要回复另一楼的处理选择
enum ReplyTargetSwitch {
  /// 保留已写内容，只把回复对象换成新的楼层
  keepContent,

  /// 已写内容存为原回复对象的草稿，新开一条回复
  saveAndStartNew,
}

/// 话题页唯一的回复会话：回复对象、正在写的内容与草稿、引用插入。
///
/// 底栏快捷回复（以及将来的宽屏停靠编辑器）是它的呈现；展开到完整编辑器
/// 时内容随草稿交接过去，会话自身退回空闲。
///
/// 切换回复对象的规则：编辑器为空直接切换；有内容时由 [confirmSwitch]
/// 让用户选择保留内容改回复对象，或存草稿另开新回复。
class TopicReplySession extends ChangeNotifier {
  TopicReplySession({
    required this.topicId,
    required this.localStore,
    required this.confirmSwitch,
  });

  final int topicId;
  final LocalDraftStore localStore;

  /// 有未发内容时切换回复对象的确认；返回 null 表示取消
  final Future<ReplyTargetSwitch?> Function(Post? from, Post? to) confirmSwitch;

  /// 表情短代码显示成图片（文本值仍是原始短代码）
  final TextEditingController text = EmojiTextEditingController();
  final FocusNode focusNode = FocusNode();

  Post? _target;

  /// 快捷回复是否展开（底栏只监听它切换形态，不随每次输入重建）
  final ValueNotifier<bool> activeNotifier = ValueNotifier<bool>(false);

  /// 快捷回复面板是否在屏上（含展开 / 收起动画过程）：底栏的回复入口
  /// 据此隐藏，避免面板从它身上长出来时下面还留着一个
  final ValueNotifier<bool> presentedNotifier = ValueNotifier<bool>(false);
  bool _submitting = false;
  bool _restoring = false;
  bool _disposed = false;
  DraftController? _draft;
  PresenceService? _presence;
  AppLifecycleListener? _lifecycle;

  /// 回复对象；null 为回复话题本身
  Post? get target => _target;

  bool get active => activeNotifier.value;
  bool get submitting => _submitting;
  bool get hasContent => text.text.trim().isNotEmpty;

  /// 当前回复对象的草稿 key（底栏草稿预览按它读本地快照）
  String get draftKey =>
      Draft.replyKey(topicId, replyToPostNumber: _target?.postNumber);

  /// 展开快捷回复（可指定回复对象）。已有内容且对象不同时按规则确认。
  Future<void> open({Post? target}) async {
    final sameTarget = target?.id == _target?.id;
    if (_draft != null && !sameTarget) {
      if (hasContent) {
        final choice = await confirmSwitch(_target, target);
        if (choice == null || _disposed) return;
        switch (choice) {
          case ReplyTargetSwitch.keepContent:
            _retargetKeepingContent(target);
          case ReplyTargetSwitch.saveAndStartNew:
            await _releaseDraft();
            _target = target;
            _replaceText('');
            _bindDraft(load: true);
        }
      } else {
        await _releaseDraft();
        _target = target;
        _bindDraft(load: true);
      }
    } else if (_draft == null) {
      _target = target;
      _bindDraft(load: true);
    }
    _activate();
  }

  /// 插入引用：不切换回复对象（未展开时以 [target] 为对象展开）
  Future<void> insertQuote(String quote, {Post? target}) async {
    if (!active) {
      await open(target: _draft == null ? target : _target);
      if (_disposed || !active) return;
    }
    text.value = withQuoteInserted(text.value, quote);
    focusNode.requestFocus();
  }

  /// 在光标处插入引用块，前后各留一个空行避免与正文粘连；光标落在引用之后。
  /// 宽屏停靠编辑器重建正文时也用它，保持两端引用格式一致
  static TextEditingValue withQuoteInserted(
    TextEditingValue value,
    String quote,
  ) {
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final before = value.text.substring(0, selection.start);
    final after = value.text.substring(selection.end);
    final lead = before.isEmpty || before.endsWith('\n\n')
        ? ''
        : (before.endsWith('\n') ? '\n' : '\n\n');
    final insert = '$lead${quote.trimRight()}\n\n';
    return TextEditingValue(
      text: '$before$insert$after',
      selection: TextSelection.collapsed(offset: before.length + insert.length),
    );
  }

  /// 插入表情等短文本到光标处
  void insertText(String snippet) {
    final value = text.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    text.value = value
        .replaced(selection, snippet)
        .copyWith(
          selection: TextSelection.collapsed(
            offset: selection.start + snippet.length,
          ),
        );
  }

  /// 收起快捷回复；未发内容留作草稿
  void close() {
    if (!active) return;
    activeNotifier.value = false;
    focusNode.unfocus();
    _flushDraft();
    _leavePresence();
    notifyListeners();
  }

  /// 正在把内容交给完整编辑器（交接期间快捷回复面板留在原处，被展开的
  /// 编辑器盖住；交接结束后不播收起动画，直接消失）
  bool get handingOff => _handingOff;
  bool _handingOff = false;

  /// 交接第一步：返回回复对象与正文（草稿控制器另由
  /// [releaseDraftInBackground] 交出）。输入框保持焦点，让完整编辑器直接
  /// 接过焦点，键盘不会先收起再弹出。
  Future<({Post? target, String content})> prepareHandOff() async {
    final result = (target: _target, content: text.text);
    _handingOff = true;
    _leavePresence();
    return result;
  }

  /// 交出草稿控制器，让完整编辑器以同一 key 接手。不等保存完成（要等
  /// 服务端往返，会拖慢编辑器展开）：返回的 Future 在旧控制器保存落定后
  /// 完成，完整编辑器的草稿核对应先等它，草稿序号才接得上
  Future<void> releaseDraftInBackground() {
    final draft = _draft;
    if (draft == null) return Future<void>.value();
    _draft = null;
    final persisted = _persistNow(draft).catchError((Object e) {
      debugPrint('[TopicReplySession] 交接前保存草稿失败: $e');
    });
    return persisted.whenComplete(draft.dispose);
  }

  /// 直接打开完整编辑器（不经快捷回复）前调用：交出草稿控制器（见
  /// [releaseDraftInBackground]），返回保存落定的 Future
  Future<void> releaseForFullEditor() {
    if (active) return Future<void>.value();
    final released = releaseDraftInBackground();
    _replaceText('');
    _target = null;
    notifyListeners();
    return released;
  }

  /// 交接第二步：完整编辑器已接手，快捷回复退回空闲
  void finishHandOff() {
    _replaceText('');
    activeNotifier.value = false;
    _handingOff = false;
    notifyListeners();
  }

  /// 发送；[send] 执行校验与发送（共用 ReplySubmission 流程），返回是否成功
  Future<void> submit(
    Future<bool> Function(String content, Post? target, DraftController? draft)
    send,
  ) async {
    final content = text.text.trim();
    if (_submitting || content.isEmpty) return;
    _submitting = true;
    notifyListeners();
    try {
      final ok = await send(content, _target, _draft);
      if (_disposed) return;
      if (ok) {
        // 发送成功：草稿已由发送流程删除，回到回复话题的空白状态
        _draft?.dispose();
        _draft = null;
        _target = null;
        _replaceText('');
        activeNotifier.value = false;
        focusNode.unfocus();
        _leavePresence();
      }
    } finally {
      if (!_disposed) {
        _submitting = false;
        notifyListeners();
      }
    }
  }

  /// 清除回复对象，改为回复话题（内容保留，不需要确认）
  void clearTarget() {
    if (_target == null) return;
    _retargetKeepingContent(null);
    notifyListeners();
  }

  /// 内容整体挪到新对象：旧对象的草稿随之作废
  void _retargetKeepingContent(Post? target) {
    final old = _draft;
    if (old != null) {
      old.disable();
      unawaited(old.deleteDraft().whenComplete(old.dispose));
    }
    _draft = null;
    _target = target;
    _bindDraft(load: false);
    _scheduleSave();
  }

  // ===== 内部 =====

  void _activate() {
    if (!active) {
      activeNotifier.value = true;
      _presence ??= PresenceService(DiscourseService())
        ..enterReplyChannel(topicId);
      _lifecycle ??= AppLifecycleListener(
        onInactive: _flushDraft,
        onPause: _flushDraft,
      );
    }
    notifyListeners();
    focusNode.requestFocus();
  }

  void _bindDraft({required bool load}) {
    final key = draftKey;
    final controller = DraftController(draftKey: key, localStore: localStore);
    _draft = controller;
    _clearedByUser = false;
    _lastText = text.text;
    text.removeListener(_onTextChanged);
    text.addListener(_onTextChanged);
    if (!load) return;
    unawaited(() async {
      try {
        final draft = await controller.loadDraft();
        if (_disposed || _draft != controller) return;
        // 加载期间用户已开始输入则不覆盖
        final reply = draft?.data.reply;
        if (reply != null && reply.trim().isNotEmpty && !hasContent) {
          _replaceText(reply);
        }
      } catch (e) {
        debugPrint('[TopicReplySession] 加载草稿失败: $e');
      }
    }());
  }

  Future<void> _releaseDraft() async {
    final draft = _draft;
    if (draft == null) return;
    _draft = null;
    await _persistNow(draft);
    draft.dispose();
  }

  /// 用户在本次编辑中把已有内容删光了：草稿应随之删除。只认「有内容 →
  /// 变空」的编辑——打开时点一下输入框（只动了光标）、草稿仍在加载时的
  /// 空白都不算，免得误删服务端上的草稿
  bool _clearedByUser = false;

  /// 上次看到的正文：控制器在只移动光标 / 选区时也会通知，那不是编辑
  String _lastText = '';

  void _onTextChanged() {
    final current = text.text;
    if (current == _lastText) return;
    final hadContent = _lastText.trim().isNotEmpty;
    _lastText = current;
    if (_restoring) return;
    if (hasContent) {
      _clearedByUser = false;
    } else if (hadContent) {
      _clearedByUser = true;
    }
    _scheduleSave();
    notifyListeners();
  }

  /// 内容变化（含清空）一律交给草稿控制器：清空时它会把草稿记为待删除，
  /// 本地快照随之变空，底栏不会留着清空前的旧内容
  void _scheduleSave() {
    _draft?.scheduleSave(_draftData());
  }

  /// 收起 / 切到后台时立即落盘：有内容保存，被用户清空则删除
  void _flushDraft() {
    final draft = _draft;
    if (draft != null) unawaited(_persistNow(draft));
  }

  Future<void> _persistNow(DraftController draft) async {
    if (hasContent) {
      await draft.saveNow(_draftData());
    } else if (_clearedByUser) {
      await draft.deleteDraft();
    }
  }

  DraftData _draftData() => DraftData(
    reply: text.text,
    action: 'reply',
    replyToPostNumber: _target?.postNumber,
    archetypeId: 'regular',
  );

  void _replaceText(String value) {
    _restoring = true;
    try {
      text.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
    } finally {
      _restoring = false;
    }
  }

  void _leavePresence() {
    _presence?.dispose();
    _presence = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _flushDraft();
    _draft?.dispose();
    _leavePresence();
    _lifecycle?.dispose();
    text.dispose();
    focusNode.dispose();
    activeNotifier.dispose();
    presentedNotifier.dispose();
    super.dispose();
  }
}
