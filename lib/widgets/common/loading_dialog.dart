import 'package:flutter/material.dart';
import '../../utils/dialog_utils.dart';
import 'package:m3e_ui/m3e_ui.dart';

/// 显示 Loading 对话框
///
/// 用法:
/// ```dart
/// LoadingDialog.show(context, message: '正在加载...');
/// // 操作完成后
/// LoadingDialog.hide(context);
/// ```
class LoadingDialog {
  static LoadingDialogController show(BuildContext context, {String? message}) {
    final navigator = Navigator.of(context, rootNavigator: true);
    final controller = LoadingDialogController._(navigator);
    showAppDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black26,
      builder: (context) => _LoadingDialogContent(message: message),
    ).whenComplete(controller._markClosed);
    return controller;
  }

  /// 关闭 loading 弹窗(不推荐)。
  ///
  /// 裸 pop 当前 context 所在的根 navigator,有两个陷阱:
  /// - 调用方通常写成 `if (mounted) hide(context)`,而 loading 期间若发生
  ///   provider 树重建/页面销毁,mounted 会变 false,这行被跳过 → 弹窗永久
  ///   留屏(登出卡「正在退出…」就是这个成因);
  /// - 期间若又压入了别的路由,pop 会关错对象。
  ///
  /// 请改用 [show] 返回的 [LoadingDialogController.hide]:它持有
  /// NavigatorState、带幂等标记与 mounted/canPop 检查,不依赖调用方 widget
  /// 的生命周期。
  @Deprecated('改用 show() 返回的 controller.hide()')
  static void hide(BuildContext context) {
    Navigator.of(context, rootNavigator: true).pop();
  }
}

class LoadingDialogController {
  LoadingDialogController._(this._navigator);

  final NavigatorState _navigator;
  bool _closed = false;

  void hide() {
    if (_closed) return;
    _closed = true;
    if (_navigator.mounted && _navigator.canPop()) {
      _navigator.pop();
    }
  }

  void _markClosed() {
    _closed = true;
  }
}

class _LoadingDialogContent extends StatelessWidget {
  final String? message;

  const _LoadingDialogContent({this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 20,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const LoadingSpinner(size: 36),
            if (message != null) ...[
              const SizedBox(height: 16),
              Text(
                message!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
