import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;

import '../../l10n/s.dart';
import '../../utils/adaptive_menu.dart';
import 'mini_app_engine.dart';

String miniAppEngineLabel(BuildContext context, MiniAppEngine engine) =>
    engine == MiniAppEngine.web
    ? context.l10n.miniApp_engineWeb
    : context.l10n.miniApp_engineLightweight;

Future<MiniAppEngine?> showMiniAppEnginePicker(
  BuildContext context, {
  required MiniAppEngine current,
  bool restarting = false,
  bool blur = true,
  BuildContext? anchorContext,
  ValueChanged<double>? onBlurSigmaChanged,
  ValueListenable<bool>? blurReady,
}) => showAdaptiveMenu<MiniAppEngine>(
  context: context,
  blur: blur,
  anchorContext: anchorContext,
  title: restarting
      ? context.l10n.miniApp_engineRestart
      : context.l10n.miniApp_engine,
  onBlurSigmaChanged: onBlurSigmaChanged,
  blurReady: blurReady,
  items: [
    for (final engine in MiniAppEngine.values)
      AdaptiveMenuItem(
        value: engine,
        icon: engine == current
            ? Symbols.check_circle_rounded
            : Symbols.radio_button_unchecked_rounded,
        label: miniAppEngineLabel(context, engine),
        subtitle: engine == MiniAppEngine.web
            ? context.l10n.miniApp_engineWebDescription
            : context.l10n.miniApp_engineLightweightDescription,
      ),
  ],
);
