import 'dart:async';

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../theme/accent_colors.dart';

/// 子引擎先绘制首帧，再读取偏好及连接宿主。初始化异常也有关闭和重试入口。
class MiniAppWindowStartup extends StatefulWidget {
  const MiniAppWindowStartup({
    super.key,
    required this.initialize,
    required this.onClose,
  });
  final Future<Widget> Function() initialize;
  final VoidCallback onClose;

  @override
  State<MiniAppWindowStartup> createState() => _MiniAppWindowStartupState();
}

class _MiniAppWindowStartupState extends State<MiniAppWindowStartup> {
  Widget? _application;
  Object? _error;
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final attempt = ++_attempt;
    setState(() {
      _error = null;
    });
    try {
      final application = await widget.initialize();
      if (mounted && attempt == _attempt) {
        setState(() => _application = application);
      }
    } catch (error) {
      if (mounted && attempt == _attempt) {
        setState(() {
          _error = error;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_application != null) return _application!;
    return TranslationProvider(
      child: Builder(
        builder: (context) => MaterialApp(
          // 启动页使用自己的 Navigator，不能把加载路由迁入完整 MainApp。
          locale: TranslationProvider.of(context).flutterLocale,
          supportedLocales: AppLocaleUtils.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: ThemeData(colorSchemeSeed: AccentColors.defaultSeed),
          darkTheme: ThemeData(
            brightness: Brightness.dark,
            colorSchemeSeed: AccentColors.defaultSeed,
          ),
          home: PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) widget.onClose();
            },
            child: Scaffold(
              appBar: AppBar(
                leading: CloseButton(onPressed: widget.onClose),
                title: const Text('FluxDO'),
              ),
              body: _error != null
                  ? AppEmptyState(
                      icon: const Icon(Symbols.error_rounded),
                      title: context.l10n.miniApp_launchFailed,
                      message: _error is TimeoutException
                          ? context.l10n.error_requestTimeoutRetry
                          : context.l10n.miniApp_metadataFailed,
                      action: FilledButton.icon(
                        onPressed: _load,
                        icon: const Icon(Symbols.refresh_rounded),
                        label: Text(context.l10n.miniApp_retry),
                      ),
                    )
                  : Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const LoadingSpinner(),
                          const SizedBox(height: 20),
                          Text(context.l10n.miniApp_launchPreparing),
                        ],
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
