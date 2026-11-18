import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';

import '../../../l10n/s.dart';
import '../../../models/pending_post.dart';
import '../../../models/topic.dart';
import '../../../widgets/post/reply_sheet.dart';
import '../controllers/topic_reply_session.dart';

/// 宽屏停靠编辑器的状态：唯一一个回复编辑器，停靠在帖子列底部，
/// 后面的帖子照常可滚动、可点击。
///
/// 编辑器本体是完整的 [ReplySheet]（停靠形态）。插入引用与「保留内容改
/// 回复对象」都通过「取出完整正文 → 以完整正文重建编辑器」实现，纯文本
/// 与富文本模式走同一条初始内容导入路径。
class TopicDockedComposerController extends ChangeNotifier {
  TopicDockedComposerController({required this.confirmSwitch});

  /// 有未发内容时切换回复对象的确认（与底栏快捷回复同一规则）
  final Future<ReplyTargetSwitch?> Function(Post? from, Post? to) confirmSwitch;

  static const double minHeight = 220;
  static const double defaultHeightFactor = 0.45;
  static const double maxHeightFactor = 0.85;

  bool _open = false;
  bool _minimized = false;
  Post? _target;
  String? _initialContent;
  bool _initialContentIsComplete = false;
  GlobalKey _editorKey = GlobalKey();
  double? _height;

  bool get isOpen => _open;
  bool get minimized => _minimized;
  Post? get target => _target;
  String? get initialContent => _initialContent;
  bool get initialContentIsComplete => _initialContentIsComplete;
  Key get editorKey => _editorKey;

  /// 用户拖动后的高度；null 用默认比例
  double? get height => _height;

  ReplyComposerHandle? get _handle =>
      _editorKey.currentState as ReplyComposerHandle?;

  /// 打开（或切换到）回复 [target]；[quote] 非空时作为引用插入
  Future<void> open({Post? target, String? quote}) async {
    if (!_open) {
      _target = target;
      // 引用走编辑器原有语义：引用前缀 + 该回复对象的已存草稿
      _rebuild(initialContent: quote, complete: false);
      _open = true;
      _minimized = false;
      notifyListeners();
      return;
    }

    _minimized = false;
    final handle = _handle;
    if (quote != null) {
      // 引用不切换回复对象：取出正文追加引用后重建
      if (handle == null) return;
      final content = await handle.detachContent(deleteDraft: false);
      final value = TopicReplySession.withQuoteInserted(
        TextEditingValue(
          text: content,
          selection: TextSelection.collapsed(offset: content.length),
        ),
        quote,
      );
      _rebuild(initialContent: value.text, complete: true);
      notifyListeners();
      return;
    }

    if (target?.id == _target?.id) {
      notifyListeners();
      return;
    }
    if (handle != null && handle.hasContent) {
      final choice = await confirmSwitch(_target, target);
      if (choice == null) return;
      switch (choice) {
        case ReplyTargetSwitch.keepContent:
          // 正文整体迁到新对象，旧对象草稿作废
          final content = await handle.detachContent(deleteDraft: true);
          _target = target;
          _rebuild(initialContent: content, complete: true);
        case ReplyTargetSwitch.saveAndStartNew:
          // 旧编辑器卸载时自动存草稿；新对象加载自己的草稿
          _target = target;
          _rebuild(initialContent: null, complete: false);
      }
    } else {
      _target = target;
      _rebuild(initialContent: null, complete: false);
    }
    notifyListeners();
  }

  void _rebuild({required String? initialContent, required bool complete}) {
    _initialContent = initialContent;
    _initialContentIsComplete = complete;
    _editorKey = GlobalKey();
  }

  /// 编辑器自行关闭（关闭按钮 / 发送完成）
  void handleClosed() {
    _open = false;
    _minimized = false;
    _target = null;
    _initialContent = null;
    notifyListeners();
  }

  void toggleMinimized() {
    _minimized = !_minimized;
    // 最小化后编辑器仍挂载（只是不显示），焦点要收走，免得继续打字落进
    // 看不见的编辑器
    if (_minimized) FocusManager.instance.primaryFocus?.unfocus();
    notifyListeners();
  }

  void resizeBy(double delta, double maxHeight) {
    final current =
        _height ?? maxHeight / maxHeightFactor * defaultHeightFactor;
    _height = (current - delta).clamp(minHeight, maxHeight);
    notifyListeners();
  }
}

/// 停靠编辑器宿主：帖子列底部的卡片，顶部手柄拖动调高度、可最小化
class TopicDockedComposer extends StatelessWidget {
  const TopicDockedComposer({
    super.key,
    required this.controller,
    required this.topicId,
    required this.onPosted,
    this.categoryId,
    this.topicTitle,
    this.isPrivateMessageTopic = false,
    this.isPmWithNonHumanUser = false,
    this.onEnqueued,
  });

  final TopicDockedComposerController controller;
  final int topicId;
  final ValueChanged<Post> onPosted;
  final int? categoryId;
  final String? topicTitle;
  final bool isPrivateMessageTopic;
  final bool isPmWithNonHumanUser;
  final ValueChanged<PendingPost>? onEnqueued;

  static const double _handleHeight = 20;
  static const double _minimizedHeight = 48;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxHeight =
            constraints.maxHeight *
            TopicDockedComposerController.maxHeightFactor;
        return ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final height = controller.minimized
                ? _minimizedHeight
                : (controller.height ??
                          constraints.maxHeight *
                              TopicDockedComposerController.defaultHeightFactor)
                      .clamp(
                        TopicDockedComposerController.minHeight,
                        maxHeight,
                      );
            return Align(
              alignment: Alignment.bottomCenter,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                height: height,
                child: Material(
                  color: theme.colorScheme.surface,
                  elevation: 8,
                  shadowColor: Colors.black38,
                  clipBehavior: Clip.antiAlias,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.vertical(
                      top: context.shapes.radius(16),
                    ),
                  ),
                  child: Column(
                    children: [
                      _buildHandle(context, theme, maxHeight),
                      Expanded(
                        // 最小化时编辑器保持挂载（状态、草稿不丢），只是不显示
                        child: Offstage(
                          offstage: controller.minimized,
                          child: ReplySheet(
                            key: controller.editorKey,
                            topicId: topicId,
                            categoryId: categoryId,
                            replyToPost: controller.target,
                            initialContent: controller.initialContent,
                            initialContentIsComplete:
                                controller.initialContentIsComplete,
                            topicTitle: topicTitle,
                            isPrivateMessageTopic: isPrivateMessageTopic,
                            isPmWithNonHumanUser: isPmWithNonHumanUser,
                            onEnqueued: onEnqueued,
                            onDockedClose: (post) {
                              controller.handleClosed();
                              if (post != null) onPosted(post);
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 顶部手柄：拖动调整高度；最小化时显示回复对象，点击恢复
  Widget _buildHandle(BuildContext context, ThemeData theme, double maxHeight) {
    final l10n = context.l10n;
    final target = controller.target;
    final minimized = controller.minimized;
    return MouseRegion(
      cursor: minimized
          ? SystemMouseCursors.click
          : SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: minimized ? controller.toggleMinimized : null,
        onVerticalDragUpdate: minimized
            ? null
            : (d) => controller.resizeBy(d.delta.dy, maxHeight),
        // 撑满整行宽度：否则 Stack 收缩到拖动条宽，收起箭头会压在拖动条上
        child: SizedBox(
          width: double.infinity,
          height: minimized ? _minimizedHeight : _handleHeight,
          child: minimized
              ? Row(
                  children: [
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        target == null
                            ? l10n.topicDetail_replyEntryHint
                            : l10n.topicDetail_quickReplyReplyingTo(
                                target.postNumber,
                                target.username,
                              ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge,
                      ),
                    ),
                    Icon(
                      Symbols.keyboard_arrow_up_rounded,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 16),
                  ],
                )
              : Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 32,
                      height: 4,
                      decoration: ShapeDecoration(
                        color: theme.colorScheme.outlineVariant,
                        shape: RoundedSuperellipseBorder(
                          borderRadius: context.shapes.borderRadius(2),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 16,
                      top: 0,
                      bottom: 0,
                      child: Tooltip(
                        message: l10n.topicDetail_quickReplyCollapse,
                        child: InkResponse(
                          onTap: controller.toggleMinimized,
                          radius: 14,
                          child: Icon(
                            Symbols.keyboard_arrow_down_rounded,
                            size: 18,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
