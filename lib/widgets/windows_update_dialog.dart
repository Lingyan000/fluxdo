import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/s.dart';
import '../services/update_service.dart';
import '../services/windows_update_service.dart';

class WindowsUpdateDialog extends StatefulWidget {
  final WindowsUpdateAsset asset;
  final String releaseUrl;

  const WindowsUpdateDialog({
    super.key,
    required this.asset,
    required this.releaseUrl,
  });

  @override
  State<WindowsUpdateDialog> createState() => _WindowsUpdateDialogState();
}

class _WindowsUpdateDialogState extends State<WindowsUpdateDialog> {
  final _service = WindowsUpdateService();
  CancelToken _cancelToken = CancelToken();
  WindowsUpdateDownload? _download;
  WindowsUpdateStage? _stage;
  double? _progress;
  Object? _error;
  bool _installing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_startDownload());
  }

  Future<void> _startDownload() async {
    _cancelToken = CancelToken();
    setState(() {
      _error = null;
      _stage = null;
      _progress = null;
    });
    try {
      final download = await _service.download(
        widget.asset,
        cancelToken: _cancelToken,
        onProgress: (stage, progress) {
          if (mounted) {
            setState(() {
              _stage = stage;
              _progress = progress;
            });
          }
        },
      );
      if (!mounted) {
        await download.delete();
        return;
      }
      setState(() => _download = download);
    } catch (error) {
      if (mounted && !_cancelToken.isCancelled) {
        setState(() => _error = error);
      }
    }
  }

  Future<void> _install() async {
    setState(() {
      _installing = true;
      _error = null;
    });
    try {
      await WindowsUpdateService.install(_download!);
    } catch (error) {
      if (mounted) {
        setState(() {
          _installing = false;
          _error = error;
        });
      }
    }
  }

  @override
  void dispose() {
    _cancelToken.cancel();
    // 启动安装器后由其持有安装包；应用退出时不能删除正在使用的文件。
    if (!_installing && _download != null) {
      unawaited(
        _download!.delete().catchError((Object error) {
          debugPrint('Unable to clean update download: $error');
        }),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    String message;
    if (_error != null) {
      message = _download != null
          ? l10n.update_windowsInstallFailed
          : _error is WindowsUpdateException
          ? l10n.download_checksumFailed
          : l10n.download_failed('$_error');
    } else if (_installing) {
      message = l10n.update_windowsInstalling;
    } else if (_download != null) {
      message = l10n.update_windowsReady;
    } else {
      message = switch (_stage) {
        null => l10n.download_connecting,
        WindowsUpdateStage.downloading => l10n.download_downloading(
          widget.asset.name,
        ),
        WindowsUpdateStage.verifying => l10n.download_verifying,
      };
    }

    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(l10n.update_now),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message),
              if (_error == null && _download == null) ...[
                const SizedBox(height: 20),
                LinearProgressIndicator(value: _progress),
                if (_progress != null) ...[
                  const SizedBox(height: 8),
                  Text('${(_progress! * 100).round()}%'),
                ],
              ],
              if (_installing) ...[
                const SizedBox(height: 20),
                const LinearProgressIndicator(),
              ],
            ],
          ),
        ),
        actions: [
          if (!_installing) ...[
            if (_error != null)
              TextButton(
                onPressed: () => launchUrl(
                  Uri.parse(widget.releaseUrl),
                  mode: LaunchMode.externalApplication,
                ),
                child: Text(l10n.common_viewDetails),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                _download == null ? l10n.common_cancel : l10n.common_later,
              ),
            ),
            if (_download != null)
              FilledButton(
                onPressed: _install,
                child: Text(l10n.update_windowsInstallRestart),
              )
            else if (_error != null)
              FilledButton(
                onPressed: _startDownload,
                child: Text(l10n.common_retry),
              ),
          ],
        ],
      ),
    );
  }
}
