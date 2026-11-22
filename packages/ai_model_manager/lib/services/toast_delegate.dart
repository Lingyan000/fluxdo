import 'package:m3e_ui/m3e_ui.dart';
import 'package:material_ui/material_ui.dart';

/// 消息提示类型
enum AiToastType { success, error, info }

/// 消息提示代理
///
/// 由主项目注入具体实现，包内统一调用
class AiToastDelegate {
  static void Function(String message, {AiToastType type})? _showToast;

  /// 注入消息提示实现
  static void configure(
      void Function(String message, {AiToastType type}) showToast) {
    _showToast = showToast;
  }

  static void showSuccess(String message) {
    _showToast?.call(message, type: AiToastType.success);
  }

  static void showError(String message) {
    _showToast?.call(message, type: AiToastType.error);
  }

  static void showInfo(String message) {
    _showToast?.call(message, type: AiToastType.info);
  }

  /// 自定义加载指示器构建器，由主项目注入。
  /// 未注入时使用公共组件 [LoadingSpinner]。
  static Widget Function({Color? color, double size})? _loadingBuilder;

  static void configureLoading(
      Widget Function({Color? color, double size}) builder) {
    _loadingBuilder = builder;
  }

  static Widget buildLoading({Color? color, double size = 48}) {
    if (_loadingBuilder != null) {
      return _loadingBuilder!(color: color, size: size);
    }
    return LoadingSpinner(color: color, size: size);
  }
}
