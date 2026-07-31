import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// 控制哪个 Hero tag 对应的图片应该在底层页面隐藏
/// 用于解决 opaque: false 路由中 Hero 切换不更新的问题
class HeroVisibilityController extends ChangeNotifier {
  HeroVisibilityController._();
  static final HeroVisibilityController instance = HeroVisibilityController._();

  String? _hiddenHeroTag;
  bool _isPopping = false;
  bool _notifyScheduled = false;

  /// 源端缩略图注册表:heroTag → 挂载中的 BuildContext。
  /// 查看器翻页时借此把源缩略图滚进可视区,保证 pop 时 Hero 有目的地。
  final Map<String, BuildContext> _sources = {};

  /// 源页注册的"按 heroTag 滚到附近"能力(段级粗滚,滚后源缩略图
  /// 构建并注册,再由 [ensureSourceVisible] 二次精确化)。
  Future<void> Function(String heroTag)? sourceScrollResolver;

  /// 当前应该隐藏的 hero tag
  String? get hiddenHeroTag => _hiddenHeroTag;

  /// 是否正在 pop 飞行结束
  bool get isPopping => _isPopping;

  /// 源缩略图挂载时注册(HeroImage 调用)
  void registerSource(String tag, BuildContext context) {
    _sources[tag] = context;
  }

  /// 源缩略图卸载时注销;校验 context 匹配,避免同 tag 新实例先注册、
  /// 旧实例后 dispose 时误删新注册。
  void unregisterSource(String tag, BuildContext context) {
    if (identical(_sources[tag], context)) {
      _sources.remove(tag);
    }
  }

  /// 把 [tag] 对应的源缩略图滚进可视区(供查看器翻页时预滚,
  /// 保证之后任意 pop 路径 Hero 都能飞回原位)。
  ///
  /// 失败静默:降级 = pop 时无飞行,整页渐隐。
  Future<void> ensureSourceVisible(String tag) async {
    try {
      if (_tryEnsureVisible(tag)) return;
      // 未注册(源缩略图已被列表回收):请求源页段级粗滚,
      // 等它构建注册后再精确化一次。
      final resolver = sourceScrollResolver;
      if (resolver == null) return;
      await resolver(tag);
      _tryEnsureVisible(tag);
    } catch (_) {
      // 静默降级
    }
  }

  bool _tryEnsureVisible(String tag) {
    final context = _sources[tag];
    if (context == null || !context.mounted) return false;
    Scrollable.ensureVisible(
      context,
      alignment: 0.5,
      duration: Duration.zero,
    );
    return true;
  }

  /// 设置当前应该隐藏的 hero tag（静默版，不触发通知）
  /// 用于 initState 中初始化，避免构建期间触发 rebuild
  void setHiddenTagSilent(String? tag) {
    _hiddenHeroTag = tag;
    _isPopping = false;
  }

  /// 设置当前应该隐藏的 hero tag（带通知）
  void setHiddenTag(String? tag) {
    if (_hiddenHeroTag == tag && !_isPopping) return;
    _hiddenHeroTag = tag;
    _isPopping = false;
    _safeNotify();
  }

  /// Pop 飞行结束时调用
  /// 从动画状态监听器调用，在 handleBeginFrame 阶段（build 之前），
  /// 直接通知以确保同帧内 rebuild，避免闪烁
  void startPopping() {
    if (_isPopping) return;
    _isPopping = true;
    notifyListeners();
  }

  /// 清除所有状态(dispose 时调用)。
  ///
  /// 必须 post-frame 异步通知:
  /// - 如果 push Hero 飞行被中断 + viewer pop 没有完整 startPopping flow,
  ///   _hiddenHeroTag 还停留在最后 setHidden 的值,source 的 Opacity 锁在 0
  /// - 同步 notifyListeners 在 dispose 阶段会触发 widget tree 锁定异常
  /// - 走 _safeNotify(post-frame callback),帧结束后才通知 source rebuild
  void clear() {
    _hiddenHeroTag = null;
    _isPopping = false;
    _safeNotify();
  }

  /// 统一延迟到帧结束后通知，避免在 build/dispose/动画期间触发 rebuild
  void _safeNotify() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      notifyListeners();
    });
  }
}
