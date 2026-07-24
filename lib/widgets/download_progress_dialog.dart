import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:paper_shaders/paper_shaders.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../l10n/s.dart';
import '../providers/apk_update_provider.dart';
import '../services/apk_download_service.dart';

/// APK 下载进度对话框
///
/// 状态完全从 [apkUpdateProvider] 读取；本身只是"观察者"，关闭弹窗不会取消下载。
class DownloadProgressDialog extends ConsumerWidget {
  const DownloadProgressDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const double dialogWidth = 300;
    const double dialogHeight = 340;
    final state = ref.watch(apkUpdateProvider);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: SizedBox(
          width: dialogWidth,
          height: dialogHeight,
          child: Stack(
            children: [
              Positioned.fill(child: _buildMeshBackground(context)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Spacer(),
                    _buildMainProgress(context, state),
                    const SizedBox(height: 32),
                    _buildStatusText(context, state),
                    const Spacer(),
                    _buildBottomAction(context, ref, state),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMeshBackground(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final colors = isDark
        ? [
            Color.lerp(colorScheme.primary, Colors.black, 0.6)!,
            Color.lerp(colorScheme.secondary, Colors.black, 0.65)!,
            Color.lerp(colorScheme.tertiary, Colors.black, 0.6)!,
            Color.lerp(colorScheme.inversePrimary, Colors.black, 0.7)!,
          ]
        : [
            Color.lerp(colorScheme.primary, Colors.white, 0.65)!,
            Color.lerp(colorScheme.secondary, Colors.white, 0.6)!,
            Color.lerp(colorScheme.tertiary, Colors.white, 0.65)!,
            Color.lerp(colorScheme.inversePrimary, Colors.white, 0.5)!,
          ];

    return MeshGradient(
      colors: colors,
      distortion: 0.8,
      swirl: 0.1,
      speed: 1,
    );
  }

  Color _contentColor(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? Colors.white : const Color(0xFF1e293b);
  }

  Color _subContentColor(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? Colors.white70 : const Color(0xFF64748b);
  }

  Widget _buildMainProgress(BuildContext context, ApkUpdateState state) {
    final status = state.status;
    final color = _contentColor(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (status == ApkDownloadStatus.downloading) {
      return Column(
        children: [
          Text(
            '${state.progress}%',
            style: TextStyle(
              fontSize: 64,
              fontWeight: FontWeight.w300,
              color: color,
              height: 1.0,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 16),
          M3eLinearProgress(
            value: state.progress / 100,
            color: color,
            trackColor: color.withValues(alpha: 0.1),
          ),
        ],
      );
    } else if (status == ApkDownloadStatus.verifying ||
        status == ApkDownloadStatus.idle) {
      return LoadingSpinner(size: 60, color: color);
    } else {
      IconData icon;
      Color iconColor = color;

      switch (status) {
        case ApkDownloadStatus.installing:
          icon = Symbols.install_mobile_rounded;
          break;
        case ApkDownloadStatus.completed:
          icon = Symbols.check_circle_rounded;
          break;
        case ApkDownloadStatus.error:
          icon = Symbols.error_rounded;
          iconColor = isDark ? Colors.white : Colors.red.shade700;
          break;
        default:
          icon = Symbols.download_rounded;
      }

      return Icon(icon, size: 72, color: iconColor);
    }
  }

  Widget _buildStatusText(BuildContext context, ApkUpdateState state) {
    return Text(
      _statusText(state),
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 13,
        color: _subContentColor(context),
        letterSpacing: 0.5,
      ),
    );
  }

  String _statusText(ApkUpdateState state) {
    final l10n = S.current;
    final assetName = state.asset?.name ?? '';
    switch (state.status) {
      case ApkDownloadStatus.idle:
        return l10n.download_connecting;
      case ApkDownloadStatus.downloading:
        return l10n.download_downloading(assetName);
      case ApkDownloadStatus.verifying:
        return l10n.download_verifying;
      case ApkDownloadStatus.installing:
        return l10n.download_installing;
      case ApkDownloadStatus.completed:
        return l10n.download_installStarted;
      case ApkDownloadStatus.error:
        return state.error ?? l10n.common_error;
    }
  }

  Widget _buildBottomAction(
      BuildContext context, WidgetRef ref, ApkUpdateState state) {
    final color = _contentColor(context);
    final subColor = _subContentColor(context);
    final l10n = S.current;

    switch (state.status) {
      case ApkDownloadStatus.error:
        final asset = state.asset;
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton(
              onPressed: () {
                ref.read(apkUpdateProvider.notifier).reset();
                Navigator.of(context).pop();
              },
              style: TextButton.styleFrom(foregroundColor: subColor),
              child: Text(l10n.common_close),
            ),
            const SizedBox(width: 16),
            TextButton(
              onPressed: asset == null
                  ? null
                  : () => ref.read(apkUpdateProvider.notifier).start(asset),
              style: TextButton.styleFrom(foregroundColor: color),
              child: Text(l10n.common_retry),
            ),
          ],
        );

      case ApkDownloadStatus.completed:
      case ApkDownloadStatus.installing:
        return TextButton(
          onPressed: () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(foregroundColor: subColor),
          child: Text(l10n.common_close),
        );

      case ApkDownloadStatus.idle:
      case ApkDownloadStatus.verifying:
      case ApkDownloadStatus.downloading:
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(
              onPressed: () async {
                await ref.read(apkUpdateProvider.notifier).cancel();
                if (context.mounted) Navigator.of(context).pop();
              },
              style: TextButton.styleFrom(
                foregroundColor: subColor.withValues(alpha: 0.6),
              ),
              child: Text(l10n.common_cancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(foregroundColor: color),
              child: Text(l10n.update_continueInBackground),
            ),
          ],
        );
    }
  }
}
