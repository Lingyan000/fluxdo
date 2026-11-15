import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// 沉浸模式期间冻结系统安全区。
///
/// 图片查看器隐藏系统栏后，Android 的 viewPadding 上下归零。查看器是
/// 非不透明路由，底下的页面仍在台上跟着重建：聊天输入框的安全区占位
/// 收成 0、AppBar 顶部让位消失。退场时露出的是塌掉的布局，系统栏恢复
/// 后再长回来，形成闪烁。
///
/// [begin] 记下进入沉浸前的安全区，[ImmersiveInsetsHoldScope] 在此期间
/// 用它顶替根级 MediaQuery 里缩小的边。[release] 之后继续保持，直到
/// 真实安全区回到记录值（系统栏恢复是异步的，会晚一到几帧），超时兜底。
class ImmersiveInsetsHold {
  ImmersiveInsetsHold._();

  static final ValueNotifier<ImmersiveInsetsSnapshot?> _held = ValueNotifier(
    null,
  );
  static Timer? _releaseTimer;

  static const _releaseTimeout = Duration(seconds: 1);

  /// 进入沉浸前调用。已在冻结中则沿用最初记录的值。
  static void begin(MediaQueryData media) {
    _releaseTimer?.cancel();
    _releaseTimer = null;
    final current = _held.value;
    if (current != null) {
      if (current.releasing) {
        _held.value = current.copyWith(releasing: false);
      }
      return;
    }
    _held.value = ImmersiveInsetsSnapshot(
      size: media.size,
      viewPadding: media.viewPadding,
    );
  }

  /// 开始恢复系统栏时调用。真实安全区回来后由 scope 解除，超时强制解除。
  static void release() {
    final current = _held.value;
    if (current == null || current.releasing) return;
    _held.value = current.copyWith(releasing: true);
    _releaseTimer?.cancel();
    _releaseTimer = Timer(_releaseTimeout, _clear);
  }

  static void _clear() {
    _releaseTimer?.cancel();
    _releaseTimer = null;
    _held.value = null;
  }
}

@immutable
class ImmersiveInsetsSnapshot {
  const ImmersiveInsetsSnapshot({
    required this.size,
    required this.viewPadding,
    this.releasing = false,
  });

  /// 记录时的窗口尺寸。尺寸变了（旋转、分屏）说明安全区本就该变，不再顶替
  final Size size;
  final EdgeInsets viewPadding;
  final bool releasing;

  ImmersiveInsetsSnapshot copyWith({bool? releasing}) =>
      ImmersiveInsetsSnapshot(
        size: size,
        viewPadding: viewPadding,
        releasing: releasing ?? this.releasing,
      );
}

/// 挂在应用根部，按 [ImmersiveInsetsHold] 的记录改写 MediaQuery。
class ImmersiveInsetsHoldScope extends StatelessWidget {
  const ImmersiveInsetsHoldScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ImmersiveInsetsSnapshot?>(
      valueListenable: ImmersiveInsetsHold._held,
      child: child,
      builder: (context, held, child) {
        if (held == null) return child!;
        final media = MediaQuery.of(context);
        if (media.size != held.size) {
          _scheduleClear(held);
          return child!;
        }
        final real = media.viewPadding;
        final kept = held.viewPadding;
        if (held.releasing &&
            real.top >= kept.top &&
            real.bottom >= kept.bottom &&
            real.left >= kept.left &&
            real.right >= kept.right) {
          _scheduleClear(held);
          return child!;
        }
        final viewPadding = EdgeInsets.fromLTRB(
          math.max(real.left, kept.left),
          math.max(real.top, kept.top),
          math.max(real.right, kept.right),
          math.max(real.bottom, kept.bottom),
        );
        if (viewPadding == real) return child!;
        // padding = viewPadding 扣掉 viewInsets(键盘等)，与引擎口径一致
        final insets = media.viewInsets;
        final padding = EdgeInsets.fromLTRB(
          math.max(0.0, viewPadding.left - insets.left),
          math.max(0.0, viewPadding.top - insets.top),
          math.max(0.0, viewPadding.right - insets.right),
          math.max(0.0, viewPadding.bottom - insets.bottom),
        );
        return MediaQuery(
          data: media.copyWith(viewPadding: viewPadding, padding: padding),
          child: child!,
        );
      },
    );
  }

  /// 帧后解除；期间若又重新 begin(记录已换)则不动
  static void _scheduleClear(ImmersiveInsetsSnapshot held) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (identical(ImmersiveInsetsHold._held.value, held)) {
        ImmersiveInsetsHold._clear();
      }
    });
  }
}
