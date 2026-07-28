import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../l10n/s.dart';
import '../services/qr_login_service.dart';
import '../services/toast_service.dart';
import 'package:m3e_ui/m3e_ui.dart';

/// 待登录设备:扫描另一台已登录设备展示的登录二维码。
///
/// - Android / iOS / macOS:优先实时相机([mobile_scanner])
/// - Linux / Windows / 无相机:从相册选图,用 zxing2 解码
class QrLoginScanPage extends StatefulWidget {
  const QrLoginScanPage({super.key});

  @override
  State<QrLoginScanPage> createState() => _QrLoginScanPageState();
}

class _QrLoginScanPageState extends State<QrLoginScanPage> {
  MobileScannerController? _controller;
  bool _handling = false;
  bool _cameraSupported = false;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    _cameraSupported = _isCameraPlatform;
    if (_cameraSupported) {
      _controller = MobileScannerController(
        formats: const [BarcodeFormat.qrCode],
        detectionSpeed: DetectionSpeed.noDuplicates,
        autoStart: true,
      );
    }
  }

  bool get _isCameraPlatform {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handling) return;
    final raw = capture.barcodes
        .map((b) => b.rawValue)
        .whereType<String>()
        .map((s) => s.trim())
        .firstWhere((s) => s.isNotEmpty, orElse: () => '');
    if (raw.isEmpty) return;
    // 先快速过滤非本协议内容,避免误扫普通二维码就弹错误
    if (QrLoginService.instance.parsePayload(raw) == null) return;
    await _completeWithRaw(raw);
  }

  Future<void> _pickFromGallery() async {
    if (_handling) return;
    try {
      final file = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (file == null) return;
      setState(() => _statusMessage = S.current.login_qrDecodingImage);
      final bytes = await file.readAsBytes();
      final raw = await QrLoginService.instance.decodeQrFromImageBytes(bytes);
      if (!mounted) return;
      if (raw == null || raw.isEmpty) {
        ToastService.showError(S.current.login_qrNoCodeInImage);
        setState(() => _statusMessage = null);
        return;
      }
      await _completeWithRaw(raw);
    } catch (e) {
      debugPrint('[QrLoginScan] 相册选图失败: $e');
      if (mounted) {
        ToastService.showError(S.current.login_qrScanFailed);
        setState(() => _statusMessage = null);
      }
    }
  }

  Future<void> _completeWithRaw(String raw) async {
    if (_handling) return;
    setState(() {
      _handling = true;
      _statusMessage = S.current.login_qrLoggingIn;
    });
    // 暂停相机,避免重复触发
    try {
      await _controller?.stop();
    } catch (_) {}

    try {
      await QrLoginService.instance.loginWithScannedContent(raw);
      if (!mounted) return;
      ToastService.showSuccess(S.current.login_qrSuccess);
      Navigator.of(context).pop(true);
    } on QrLoginException catch (e) {
      if (!mounted) return;
      ToastService.showError(e.message);
      setState(() {
        _handling = false;
        _statusMessage = null;
      });
      try {
        await _controller?.start();
      } catch (_) {}
    } catch (e) {
      debugPrint('[QrLoginScan] 登录失败: $e');
      if (!mounted) return;
      ToastService.showError(S.current.login_qrScanFailed);
      setState(() {
        _handling = false;
        _statusMessage = null;
      });
      try {
        await _controller?.start();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.login_qrScanTitle),
        actions: [
          if (_cameraSupported)
            IconButton(
              tooltip: context.l10n.login_qrPickImage,
              onPressed: _handling ? null : _pickFromGallery,
              icon: const Icon(Symbols.photo_library_rounded),
            ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_cameraSupported && _controller != null)
            _buildCameraBody(theme, scheme)
          else
            _buildGalleryOnlyBody(theme, scheme),
          if (_handling || _statusMessage != null)
            ColoredBox(
              color: Colors.black.withValues(alpha: 0.45),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 24,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const LoadingSpinner(),
                      if (_statusMessage != null) ...[
                        const SizedBox(height: 16),
                        Text(_statusMessage!, style: theme.textTheme.bodyMedium),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCameraBody(ThemeData theme, ColorScheme scheme) {
    return Column(
      children: [
        Expanded(
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                MobileScanner(
                  controller: _controller!,
                  onDetect: _onDetect,
                  errorBuilder: (context, error) {
                    return _CameraErrorPane(
                      message: error.errorDetails?.message ?? error.toString(),
                      onPickImage: _pickFromGallery,
                    );
                  },
                ),
                // 简易取景框提示
                IgnorePointer(
                  child: Center(
                    child: Container(
                      width: 240,
                      height: 240,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.85),
                          width: 2.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              children: [
                Text(
                  context.l10n.login_qrScanHint,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _handling ? null : _pickFromGallery,
                  icon: const Icon(Symbols.photo_library_rounded, size: 20),
                  label: Text(context.l10n.login_qrPickImage),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGalleryOnlyBody(ThemeData theme, ColorScheme scheme) {
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Symbols.qr_code_scanner_rounded,
                size: 72,
                color: scheme.primary,
              ),
              const SizedBox(height: 20),
              Text(
                context.l10n.login_qrGalleryOnlyHint,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 28),
              FilledButton.icon(
                onPressed: _handling ? null : _pickFromGallery,
                icon: const Icon(Symbols.photo_library_rounded),
                label: Text(context.l10n.login_qrPickImage),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(220, 52),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CameraErrorPane extends StatelessWidget {
  const _CameraErrorPane({
    required this.message,
    required this.onPickImage,
  });

  final String message;
  final VoidCallback onPickImage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Symbols.no_photography_rounded,
                color: Colors.white70,
                size: 48,
              ),
              const SizedBox(height: 12),
              Text(
                context.l10n.login_qrCameraUnavailable,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.white70,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onPickImage,
                icon: const Icon(Symbols.photo_library_rounded),
                label: Text(context.l10n.login_qrPickImage),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
