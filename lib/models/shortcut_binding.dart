import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 快捷键分类
enum ShortcutCategory {
  /// 导航类
  navigation,

  /// 内容类
  content,

  /// 话题类
  topic,

  /// 帖子类
  post,
}

/// 快捷键动作
enum ShortcutAction {
  /// 返回导航
  navigateBack,

  /// 返回导航（macOS Alt+←）
  navigateBackAlt,

  /// 打开搜索
  openSearch,

  /// 关闭浮层/返回
  closeOverlay,

  /// 打开设置
  openSettings,

  /// 刷新
  refresh,

  /// 显示快捷键帮助
  showShortcutHelp,

  /// 下一个条目（话题列表下一话题 / 帖子详情下一帖子）
  nextItem,

  /// 上一个条目
  previousItem,

  /// 打开选中条目
  openItem,

  /// 切换双栏焦点面板
  switchPane,

  /// 打开/关闭通知面板
  toggleNotifications,

  /// 切换到话题 Tab
  switchToTopics,

  /// 切换到个人 Tab
  switchToProfile,

  /// 创建话题
  createTopic,

  /// 上一个分类 Tab
  previousTab,

  /// 下一个分类 Tab
  nextTab,

  /// 切换 AI 面板
  toggleAiPanel,

  /// 跳转到指定楼层
  jumpToPost,

  /// 跳转到首个未读楼层
  goToUnreadPost,

  /// 回复话题
  replyTopic,

  /// 分享话题
  shareTopic,

  /// 收藏话题
  bookmarkTopic,

  /// 回复当前帖子
  replyPost,

  /// 引用当前帖子
  quotePost,

  /// 点赞当前帖子
  likePost,

  /// 分享当前帖子
  sharePost,

  /// 收藏当前帖子
  bookmarkPost,

  /// 编辑当前帖子
  editPost,

  /// 举报当前帖子
  flagPost,

  /// 删除当前帖子
  deletePost,
}

/// 单个快捷键绑定
class ShortcutBinding {
  final ShortcutAction action;
  final ShortcutCategory category;
  final SingleActivator defaultActivator;
  final SingleActivator? customActivator;

  const ShortcutBinding({
    required this.action,
    required this.category,
    required this.defaultActivator,
    this.customActivator,
  });

  /// 当前生效的激活器
  SingleActivator get activator => customActivator ?? defaultActivator;

  /// 是否已被用户自定义
  bool get isCustomized => customActivator != null;

  ShortcutBinding copyWith({
    SingleActivator? customActivator,
    bool clearCustom = false,
  }) {
    return ShortcutBinding(
      action: action,
      category: category,
      defaultActivator: defaultActivator,
      customActivator: clearCustom ? null : customActivator ?? this.customActivator,
    );
  }

  /// Shift 组合显示映射：Shift+基础键 → 直接显示符号
  static final _shiftDisplayMap = <LogicalKeyboardKey, String>{
    LogicalKeyboardKey.slash: '?',
    LogicalKeyboardKey.digit1: '!',
    LogicalKeyboardKey.digit2: '@',
    LogicalKeyboardKey.digit3: '#',
    LogicalKeyboardKey.semicolon: ':',
    LogicalKeyboardKey.backquote: '~',
    LogicalKeyboardKey.equal: '+',
    LogicalKeyboardKey.minus: '_',
  };

  /// 将 SingleActivator 格式化为可读字符串
  static String formatActivator(SingleActivator activator) {
    final parts = formatActivatorParts(activator);
    final isMac = !kIsWeb && Platform.isMacOS;
    return parts.join(isMac ? '' : '+');
  }

  /// 将 SingleActivator 格式化为键位片段（如 Ctrl / Shift / N）
  static List<String> formatActivatorParts(SingleActivator activator) {
    final parts = <String>[];
    final isMac = !kIsWeb && Platform.isMacOS;

    // 如果是 Shift+基础键 且有对应符号，直接显示符号（如 ? 而非 Shift+/）
    if (activator.shift &&
        !activator.control &&
        !activator.alt &&
        !activator.meta) {
      final symbol = _shiftDisplayMap[activator.trigger];
      if (symbol != null) return [symbol];
    }

    if (activator.control) parts.add(isMac ? '⌃' : 'Ctrl');
    if (activator.alt) parts.add(isMac ? '⌥' : 'Alt');
    if (activator.shift) parts.add(isMac ? '⇧' : 'Shift');
    if (activator.meta) {
      // Windows 上 meta = Win 键,显示 'Super' 不符习惯;Linux 保留 Super
      parts.add(isMac
          ? '⌘'
          : (!kIsWeb && Platform.isWindows ? 'Win' : 'Super'));
    }

    parts.add(_keyLabel(activator.trigger));
    return List.unmodifiable(parts);
  }

  static String _keyLabel(LogicalKeyboardKey key) {
    // 特殊按键映射
    final labels = <LogicalKeyboardKey, String>{
      LogicalKeyboardKey.arrowLeft: '←',
      LogicalKeyboardKey.arrowRight: '→',
      LogicalKeyboardKey.arrowUp: '↑',
      LogicalKeyboardKey.arrowDown: '↓',
      LogicalKeyboardKey.escape: 'Esc',
      LogicalKeyboardKey.slash: '/',
      LogicalKeyboardKey.question: '?',
      LogicalKeyboardKey.space: 'Space',
      LogicalKeyboardKey.enter: 'Enter',
      LogicalKeyboardKey.tab: 'Tab',
      LogicalKeyboardKey.backspace: 'Backspace',
      LogicalKeyboardKey.delete: 'Delete',
      LogicalKeyboardKey.f1: 'F1',
      LogicalKeyboardKey.f2: 'F2',
      LogicalKeyboardKey.f3: 'F3',
      LogicalKeyboardKey.f4: 'F4',
      LogicalKeyboardKey.f5: 'F5',
      LogicalKeyboardKey.f6: 'F6',
      LogicalKeyboardKey.f7: 'F7',
      LogicalKeyboardKey.f8: 'F8',
      LogicalKeyboardKey.f9: 'F9',
      LogicalKeyboardKey.f10: 'F10',
      LogicalKeyboardKey.f11: 'F11',
      LogicalKeyboardKey.f12: 'F12',
    };

    final label = labels[key];
    if (label != null) return label;

    // 使用 keyLabel
    final keyLabel = key.keyLabel;
    if (keyLabel.isNotEmpty) return keyLabel;

    return key.debugName ?? '?';
  }

  /// 将 SingleActivator 序列化为 JSON map
  static Map<String, dynamic> activatorToJson(SingleActivator activator) {
    return {
      'key': activator.trigger.keyId,
      'ctrl': activator.control,
      'shift': activator.shift,
      'alt': activator.alt,
      'meta': activator.meta,
    };
  }

  /// 从 JSON map 反序列化 SingleActivator
  static SingleActivator? activatorFromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final keyId = json['key'] as int?;
    if (keyId == null) return null;

    final key = LogicalKeyboardKey.findKeyByKeyId(keyId);
    if (key == null) return null;

    return SingleActivator(
      key,
      control: json['ctrl'] as bool? ?? false,
      shift: json['shift'] as bool? ?? false,
      alt: json['alt'] as bool? ?? false,
      meta: json['meta'] as bool? ?? false,
    );
  }
}

/// 构建平台对应的默认快捷键绑定列表
List<ShortcutBinding> buildDefaultBindings() {
  final isMac = !kIsWeb && Platform.isMacOS;

  return [
    // ── 导航 ──
    ShortcutBinding(
      action: ShortcutAction.navigateBack,
      category: ShortcutCategory.navigation,
      defaultActivator: isMac
          ? const SingleActivator(LogicalKeyboardKey.bracketLeft, meta: true)
          : const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true),
    ),
    // macOS 额外的 Alt+← 返回
    if (isMac)
      const ShortcutBinding(
        action: ShortcutAction.navigateBackAlt,
        category: ShortcutCategory.navigation,
        defaultActivator:
            SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true),
      ),
    ShortcutBinding(
      action: ShortcutAction.openSearch,
      category: ShortcutCategory.navigation,
      defaultActivator: const SingleActivator(LogicalKeyboardKey.slash),
    ),
    ShortcutBinding(
      action: ShortcutAction.openSettings,
      category: ShortcutCategory.navigation,
      defaultActivator: isMac
          ? const SingleActivator(LogicalKeyboardKey.comma, meta: true)
          : const SingleActivator(LogicalKeyboardKey.comma, control: true),
    ),

    // ── 内容 ──
    const ShortcutBinding(
      action: ShortcutAction.closeOverlay,
      category: ShortcutCategory.content,
      defaultActivator: SingleActivator(LogicalKeyboardKey.escape),
    ),
    ShortcutBinding(
      action: ShortcutAction.refresh,
      category: ShortcutCategory.content,
      defaultActivator: isMac
          ? const SingleActivator(LogicalKeyboardKey.keyR, meta: true)
          : const SingleActivator(LogicalKeyboardKey.f5),
    ),
    const ShortcutBinding(
      action: ShortcutAction.showShortcutHelp,
      category: ShortcutCategory.content,
      defaultActivator:
          SingleActivator(LogicalKeyboardKey.slash, shift: true),
    ),
    const ShortcutBinding(
      action: ShortcutAction.nextItem,
      category: ShortcutCategory.content,
      defaultActivator: SingleActivator(LogicalKeyboardKey.keyJ),
    ),
    const ShortcutBinding(
      action: ShortcutAction.previousItem,
      category: ShortcutCategory.content,
      defaultActivator: SingleActivator(LogicalKeyboardKey.keyK),
    ),
    const ShortcutBinding(
      action: ShortcutAction.openItem,
      category: ShortcutCategory.content,
      defaultActivator: SingleActivator(LogicalKeyboardKey.enter),
    ),
    const ShortcutBinding(
      action: ShortcutAction.switchPane,
      category: ShortcutCategory.navigation,
      defaultActivator: SingleActivator(LogicalKeyboardKey.backquote),
    ),
    ShortcutBinding(
      action: ShortcutAction.toggleNotifications,
      category: ShortcutCategory.navigation,
      defaultActivator: isMac
          ? const SingleActivator(LogicalKeyboardKey.keyN, meta: true, shift: true)
          : const SingleActivator(LogicalKeyboardKey.keyN, control: true, shift: true),
    ),
    const ShortcutBinding(
      action: ShortcutAction.switchToTopics,
      category: ShortcutCategory.navigation,
      defaultActivator: SingleActivator(LogicalKeyboardKey.digit1, alt: true),
    ),
    const ShortcutBinding(
      action: ShortcutAction.switchToProfile,
      category: ShortcutCategory.navigation,
      defaultActivator: SingleActivator(LogicalKeyboardKey.digit2, alt: true),
    ),
    ShortcutBinding(
      action: ShortcutAction.createTopic,
      category: ShortcutCategory.content,
      defaultActivator: isMac
          ? const SingleActivator(LogicalKeyboardKey.keyN, meta: true)
          : const SingleActivator(LogicalKeyboardKey.keyN, control: true),
    ),
    const ShortcutBinding(
      action: ShortcutAction.previousTab,
      category: ShortcutCategory.navigation,
      defaultActivator: SingleActivator(LogicalKeyboardKey.bracketLeft, alt: true),
    ),
    const ShortcutBinding(
      action: ShortcutAction.nextTab,
      category: ShortcutCategory.navigation,
      defaultActivator: SingleActivator(LogicalKeyboardKey.bracketRight, alt: true),
    ),
    ShortcutBinding(
      action: ShortcutAction.toggleAiPanel,
      category: ShortcutCategory.content,
      defaultActivator: isMac
          ? const SingleActivator(LogicalKeyboardKey.keyL, meta: true)
          : const SingleActivator(LogicalKeyboardKey.keyL, control: true),
    ),

    // ── 话题 ──
    const ShortcutBinding(
      action: ShortcutAction.jumpToPost,
      category: ShortcutCategory.topic,
      defaultActivator: SingleActivator(
        LogicalKeyboardKey.digit3,
        shift: true,
      ),
    ),
    const ShortcutBinding(
      action: ShortcutAction.goToUnreadPost,
      category: ShortcutCategory.topic,
      defaultActivator: SingleActivator(LogicalKeyboardKey.keyL, shift: true),
    ),
    const ShortcutBinding(
      action: ShortcutAction.replyTopic,
      category: ShortcutCategory.topic,
      defaultActivator: SingleActivator(LogicalKeyboardKey.keyR, shift: true),
    ),
    const ShortcutBinding(
      action: ShortcutAction.shareTopic,
      category: ShortcutCategory.topic,
      defaultActivator: SingleActivator(LogicalKeyboardKey.keyS, shift: true),
    ),
    const ShortcutBinding(
      action: ShortcutAction.bookmarkTopic,
      category: ShortcutCategory.topic,
      defaultActivator: SingleActivator(LogicalKeyboardKey.keyF),
    ),

    // ── 帖子 ──
    const ShortcutBinding(
      action: ShortcutAction.replyPost,
      category: ShortcutCategory.post,
      defaultActivator: SingleActivator(LogicalKeyboardKey.keyR),
    ),
    const ShortcutBinding(
      action: ShortcutAction.quotePost,
      category: ShortcutCategory.post,
      defaultActivator: SingleActivator(LogicalKeyboardKey.keyQ),
    ),
    const ShortcutBinding(
      action: ShortcutAction.likePost,
      category: ShortcutCategory.post,
      defaultActivator: SingleActivator(LogicalKeyboardKey.keyL),
    ),
    const ShortcutBinding(
      action: ShortcutAction.sharePost,
      category: ShortcutCategory.post,
      defaultActivator: SingleActivator(LogicalKeyboardKey.keyS),
    ),
    const ShortcutBinding(
      action: ShortcutAction.bookmarkPost,
      category: ShortcutCategory.post,
      defaultActivator: SingleActivator(LogicalKeyboardKey.keyB),
    ),
    const ShortcutBinding(
      action: ShortcutAction.editPost,
      category: ShortcutCategory.post,
      defaultActivator: SingleActivator(LogicalKeyboardKey.keyE),
    ),
    const ShortcutBinding(
      action: ShortcutAction.flagPost,
      category: ShortcutCategory.post,
      defaultActivator: SingleActivator(
        LogicalKeyboardKey.digit1,
        shift: true,
      ),
    ),
    const ShortcutBinding(
      action: ShortcutAction.deletePost,
      category: ShortcutCategory.post,
      defaultActivator: SingleActivator(LogicalKeyboardKey.keyD),
    ),
  ];
}

bool shortcutActionSupported(ShortcutAction action) {
  return buildDefaultBindings().any((binding) => binding.action == action);
}
