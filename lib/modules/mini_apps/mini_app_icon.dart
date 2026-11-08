import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../widgets/content/discourse_image.dart';
import 'mini_app.dart';

class MiniAppIcon extends StatelessWidget {
  const MiniAppIcon(this.app, {super.key, this.size = 56});
  final MiniApp app;
  final double size;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A stable monogram makes missing artwork distinguishable in the launcher.
    final palette =
        app.id.codeUnits.fold<int>(0, (sum, unit) => sum + unit) % 3;
    final (background, foreground) = [
      (scheme.primaryContainer, scheme.onPrimaryContainer),
      (scheme.secondaryContainer, scheme.onSecondaryContainer),
      (scheme.tertiaryContainer, scheme.onTertiaryContainer),
    ][palette];
    Widget fallback(BuildContext context) => ColoredBox(
      color: background,
      child: Center(
        child: app.name.trim().isNotEmpty
            ? Text(
                app.name.trim().characters.first.toUpperCase(),
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  fontSize: size * .44,
                  fontWeight: FontWeight.w700,
                  color: foreground,
                ),
              )
            : Icon(Symbols.apps_rounded, size: size * .48, color: foreground),
      ),
    );
    return SizedBox.square(
      dimension: size,
      child: ClipRSuperellipse(
        borderRadius: BorderRadius.circular(size * .3),
        child: app.iconUrl.isEmpty
            ? fallback(context)
            : DiscourseImage(
                url: app.iconUrl,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: fallback,
                placeholderBuilder: fallback,
              ),
      ),
    );
  }
}
