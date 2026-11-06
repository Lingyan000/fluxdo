import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';

import '../../l10n/s.dart';
import '../../pages/network_settings_page/network_settings_page.dart';
import '../../services/cf_challenge_service.dart';
import '../../services/network/exceptions/api_exception.dart';
import '../../services/toast_service.dart';
import '../../utils/dialog_utils.dart';
import 'app_bottom_sheet.dart';
import '../../utils/error_utils.dart';

/// 通用错误页面组件
/// 显示语义化的错误提示，并提供查看详情和重试功能
class ErrorView extends StatelessWidget {
  const ErrorView({
    super.key,
    required this.error,
    this.stackTrace,
    this.onRetry,
    this.icon,
    this.iconSize = 48,
    this.title,
    this.retryLabel,
    this.showDetails = true,
  });

  /// 错误对象
  final Object error;

  /// 堆栈跟踪（可选）
  final StackTrace? stackTrace;

  /// 重试回调
  final VoidCallback? onRetry;

  /// 自定义图标
  final IconData? icon;

  /// 图标大小
  final double iconSize;

  /// 自定义标题（默认为"加载失败"）
  final String? title;

  /// 自定义重试按钮文案（默认为"重试"）
  final String? retryLabel;

  /// 是否显示"查看详情"按钮
  final bool showDetails;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final errorInfo = ErrorUtils.getErrorInfo(error);
    final isCfChallengeError = _isCfChallengeError(error);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ErrorIconBadge(icon: icon ?? errorInfo.icon),
              const SizedBox(height: 24),
              Text(
                title ?? errorInfo.title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                errorInfo.message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 32),
              ..._buildActions(
                context,
                theme: theme,
                errorInfo: errorInfo,
                isCfChallengeError: isCfChallengeError,
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildActions(
    BuildContext context, {
    required ThemeData theme,
    required ErrorInfo errorInfo,
    required bool isCfChallengeError,
  }) {
    final widgets = <Widget>[];

    // 主按钮：CF 验证 / 重试
    if (isCfChallengeError) {
      widgets.add(
        _PrimaryButton(
          label: context.l10n.cf_manualVerifyAction,
          onPressed: () => _runManualCfVerify(context),
        ),
      );
    } else if (onRetry != null) {
      widgets.add(
        _PrimaryButton(
          label: retryLabel ?? context.l10n.common_retry,
          onPressed: onRetry!,
        ),
      );
    }

    // 辅助操作：横向排列的扁平 icon+文字按钮。
    // CF 验证 + 重试 / 网络设置 / 查看详情都收纳到这里，
    // 形成"一个主按钮 + 一排快捷入口"的清爽布局。
    final helperActions = <Widget>[
      if (isCfChallengeError && onRetry != null)
        _HelperAction(
          icon: Symbols.refresh_rounded,
          label: context.l10n.common_retry,
          onPressed: onRetry!,
        ),
      if (errorInfo.isNetworkError)
        _HelperAction(
          icon: Symbols.tune_rounded,
          label: context.l10n.error_openNetworkSettings,
          onPressed: () => _openNetworkSettings(context),
        ),
      if (showDetails)
        _HelperAction(
          icon: Symbols.info_rounded,
          label: context.l10n.common_viewDetails,
          onPressed: () => _showErrorDetails(context),
        ),
    ];

    if (helperActions.isNotEmpty) {
      if (widgets.isNotEmpty) widgets.add(const SizedBox(height: 16));
      widgets.add(
        Wrap(
          spacing: 4,
          runSpacing: 4,
          alignment: WrapAlignment.center,
          children: helperActions,
        ),
      );
    }

    return widgets;
  }

  bool _isCfChallengeError(Object error) {
    if (error is CfChallengeException) return true;
    if (error is DioException && error.error is CfChallengeException) {
      return true;
    }
    return false;
  }

  Future<void> _runManualCfVerify(BuildContext context) async {
    final result = await CfChallengeService().showManualVerifyNow(
      context,
      true,
    );
    if (!context.mounted) return;

    if (result == true) {
      ToastService.showSuccess(S.current.cfVerify_success);
      onRetry?.call();
      return;
    }

    if (result == false) {
      ToastService.showError(S.current.cf_verifyIncomplete);
      return;
    }

    ToastService.showError(S.current.cf_cannotOpenVerifyPage);
  }

  void _openNetworkSettings(BuildContext context) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const NetworkSettingsPage()));
  }

  void _showErrorDetails(BuildContext context) {
    final details = ErrorUtils.getErrorDetails(error, stackTrace);

    showAppBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ErrorDetailsSheet(details: details),
    );
  }
}

/// 错误详情底部弹窗
///
/// 风格对齐项目通用 sheet（书签/打赏/AI 模型选择等）：
/// 外层 margin 16 + 圆角 16 + surface 背景 + drag handle + 标题栏。
class ErrorDetailsSheet extends StatelessWidget {
  const ErrorDetailsSheet({super.key, required this.details});

  final String details;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AppSheetScaffold(
      contentPadding: EdgeInsets.zero,
      showTitleDivider: true,
      titleWidget: Row(
        children: [
          Icon(
            Symbols.bug_report_rounded,
            size: 20,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 8),
          Text(
            context.l10n.common_errorDetails,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Symbols.content_copy_rounded, size: 20),
          tooltip: context.l10n.common_copy,
          onPressed: () {
            Clipboard.setData(ClipboardData(text: details));
            ToastService.showSuccess(S.current.common_copiedToClipboard);
          },
        ),
      ],
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: SelectableText(
          details,
          style: theme.textTheme.bodySmall?.copyWith(
            fontFamily: 'monospace',
            height: 1.5,
          ),
        ),
      ),
    );
  }
}

/// Sliver 版本的错误视图（用于 CustomScrollView）
class SliverErrorView extends StatelessWidget {
  const SliverErrorView({
    super.key,
    required this.error,
    this.stackTrace,
    this.onRetry,
    this.icon,
    this.iconSize = 48,
    this.title,
    this.retryLabel,
    this.showDetails = true,
  });

  final Object error;
  final StackTrace? stackTrace;
  final VoidCallback? onRetry;
  final IconData? icon;
  final double iconSize;
  final String? title;
  final String? retryLabel;
  final bool showDetails;

  @override
  Widget build(BuildContext context) {
    return SliverFillRemaining(
      hasScrollBody: false,
      child: ErrorView(
        error: error,
        stackTrace: stackTrace,
        onRetry: onRetry,
        icon: icon,
        iconSize: iconSize,
        title: title,
        retryLabel: retryLabel,
        showDetails: showDetails,
      ),
    );
  }
}

/// 行内错误视图：用于卡片内/列表项内的局部错误，不占满整屏。
///
/// 风格：errorContainer 淡色底 + 圆角 12 + Row(icon + 文字 + 可选重试)。
/// 与 ErrorView 共享同一套错误信息源（ErrorUtils.getErrorInfo），
/// 但形态更紧凑，适合 topic summary 卡、AI 消息气泡、stats 卡等场景。
class InlineErrorView extends StatelessWidget {
  const InlineErrorView({
    super.key,
    required this.error,
    this.onRetry,
    this.message,
    this.compact = false,
  });

  /// 错误对象
  final Object error;

  /// 重试回调
  final VoidCallback? onRetry;

  /// 自定义错误文案。null 时取 ErrorUtils.getErrorInfo(error).title。
  final String? message;

  /// 紧凑模式：更小的图标和内边距，适合放在小卡片里。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final errorInfo = ErrorUtils.getErrorInfo(error);
    final padding = compact
        ? const EdgeInsets.symmetric(horizontal: 12, vertical: 10)
        : const EdgeInsets.all(16);
    final iconSize = compact ? 18.0 : 20.0;
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      padding: padding,
      decoration: ShapeDecoration(
        color: isDark
            ? theme.colorScheme.error.withValues(alpha: 0.08)
            : theme.colorScheme.errorContainer.withValues(alpha: 0.4),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      child: Row(
        children: [
          Icon(errorInfo.icon, size: iconSize, color: theme.colorScheme.error),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message ?? errorInfo.title,
              style:
                  (compact
                          ? theme.textTheme.bodySmall
                          : theme.textTheme.bodyMedium)
                      ?.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w500,
                      ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: theme.colorScheme.primary,
                textStyle: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: Text(context.l10n.common_retry),
            ),
          ],
        ],
      ),
    );
  }
}

/// 错误图标徽章：圆角方形容器 + 淡色背景 + 主色图标。
/// 给图标一个"家"，是整页的视觉焦点。
class _ErrorIconBadge extends StatelessWidget {
  const _ErrorIconBadge({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    // 暗色模式下用更高对比的容器色，浅色用 errorContainer
    final bgColor = isDark
        ? theme.colorScheme.error.withValues(alpha: 0.12)
        : theme.colorScheme.errorContainer.withValues(alpha: 0.6);
    final fgColor = isDark
        ? theme.colorScheme.error
        : theme.colorScheme.onErrorContainer;

    return Container(
      width: 72,
      height: 72,
      decoration: ShapeDecoration(
        color: bgColor,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(22),
        ),
      ),
      child: Icon(icon, size: 36, color: fgColor),
    );
  }
}

/// 主操作按钮：内嵌胶囊（自适应宽度），48 高，加粗文字。
/// 不强求全宽，让按钮回归"自然尺寸"，更精致。
class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 48,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          shape: const RoundedSuperellipseBorder(
            borderRadius: BorderRadius.all(Radius.circular(9999)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 36),
          textStyle: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
          elevation: 0,
        ),
        child: Text(label),
      ),
    );
  }
}

/// 辅助操作：上 icon + 下小字的扁平按钮。
/// 多个时横向排列，视觉权重低，类似 Notion / 微信错误页底部的快捷入口。
class _HelperAction extends StatelessWidget {
  const _HelperAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onPressed,
      customBorder: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 6),
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
