import 'dart:io';

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../l10n/s.dart';
import 'session/development_connection.dart';

/// 只识别开发配对地址，返回后仍需用户主动连接和审阅开发权限。
class DevelopmentScanPage extends StatefulWidget {
  const DevelopmentScanPage({super.key});
  static bool get supported =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
  @override
  State<DevelopmentScanPage> createState() => _DevelopmentScanState();
}

class _DevelopmentScanState extends State<DevelopmentScanPage>
    with WidgetsBindingObserver {
  late final controller = MobileScannerController(
    formats: [BarcodeFormat.qrCode],
  );
  bool handled = false;
  bool invalid = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!controller.value.hasCameraPermission || handled) return;
    if (state == AppLifecycleState.resumed) {
      controller.start();
    } else {
      controller.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }

  void detect(BarcodeCapture capture) {
    if (!mounted || handled) return;
    for (final code in capture.barcodes) {
      final raw = code.rawValue;
      if (raw == null) continue;
      try {
        final uri = DevelopmentConnection.parse(raw);
        handled = true;
        controller.stop();
        Navigator.pop(context, uri.toString());
        return;
      } catch (_) {
        setState(() => invalid = true);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.l10n.metaverse_scanPairing)),
    body: Column(
      children: [
        Expanded(
          child: ClipRect(
            child: MobileScanner(
              controller: controller,
              onDetect: detect,
              errorBuilder: (_, _) => AppEmptyState(
                icon: const Icon(Symbols.no_photography_rounded),
                title: context.l10n.metaverse_cameraUnavailable,
                message: context.l10n.metaverse_pairingPasteFallback,
              ),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              invalid
                  ? context.l10n.metaverse_devInvalidPairing
                  : context.l10n.metaverse_scanPairingNote,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ),
      ],
    ),
  );
}
