import 'package:flutter/material.dart';
import '../../utils/platform_utils.dart';

import 'composer_tool_style.dart';
import 'composer_object_action.dart';
import 'composer_anchored_panel.dart';
import 'composer_chrome.dart';
export 'composer_object_action.dart';

Future<void> showComposerObjectMenu(
  BuildContext context,
  ComposerObjectSelection selection, {
  Offset? globalPosition,
  Rect? globalAnchorRect,
  VoidCallback? onClosed,
  List<ComposerObjectAction> additionalActions = const [],
}) async {
  final navigator = Navigator.of(context);
  final releaseChrome = ComposerChromeScope.maybeOf(context)?.hold();
  selection.onMenuVisibilityChanged?.call(true);
  ComposerObjectAction? action;
  try {
    final box = context.findRenderObject();
    final anchor =
        globalAnchorRect ??
        (globalPosition != null
            ? globalPosition & Size.zero
            : box is RenderBox
            ? box.localToGlobal(Offset.zero) & box.size
            : null);
    if (anchor == null) return;
    action = await showComposerAnchoredPanel<ComposerObjectAction>(
      context: context,
      requestFocus: PlatformUtils.isDesktop,
      globalAnchor: anchor,
      atPointer: globalPosition != null,
      globalViewport: globalPosition == null
          ? selection.menuViewport?.call()
          : null,
      builder: (menuContext) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item in [...additionalActions, ...selection.actions])
            TextButton.icon(
              onPressed: item.run == null
                  ? null
                  : () => Navigator.of(menuContext).pop(item),
              style: TextButton.styleFrom(
                minimumSize: Size(0, PlatformUtils.isDesktop ? 44 : 48),
                alignment: Alignment.centerLeft,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(7),
                ),
                foregroundColor: item.destructive
                    ? Theme.of(context).colorScheme.error
                    : Theme.of(context).colorScheme.onSurface,
              ),
              icon: Icon(item.icon, size: 19),
              label: Text(item.label),
            ),
        ],
      ),
    );
  } finally {
    releaseChrome?.call();
    selection.onMenuVisibilityChanged?.call(false);
    onClosed?.call();
  }
  if (navigator.mounted) action?.run?.call();
}

class ComposerObjectToolbar extends StatelessWidget {
  const ComposerObjectToolbar({
    super.key,
    required this.selection,
    this.menuAnchorKey,
  });
  final ComposerObjectSelection selection;
  final GlobalKey? menuAnchorKey;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onSecondaryTapUp: selection.onContextMenu == null
        ? null
        : (details) => selection.onContextMenu!(details.globalPosition),
    child: TextFieldTapRegion(
      child: IconButtonTheme(
        data: IconButtonThemeData(style: composerToolButtonStyle(context)),
        child: Row(
          key: const ValueKey('composer-object-toolbar'),
          children: [
            IconButton(
              tooltip: '退出选中',
              onPressed: selection.dismiss,
              icon: const Icon(Icons.close_rounded, size: 20),
            ),
            Expanded(
              child: Text(
                selection.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            if (selection.primary case final action?)
              TextButton.icon(
                onPressed: action.run,
                icon: Icon(action.icon, size: 20),
                label: Text(action.label),
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            IconButton(
              tooltip: '在后面输入',
              onPressed: selection.after,
              icon: const Icon(Icons.keyboard_return_rounded, size: 20),
            ),
            Builder(
              key: menuAnchorKey,
              builder: (buttonContext) => TextButton.icon(
                key: const ValueKey('composer-object-more'),
                onPressed: () =>
                    showComposerObjectMenu(buttonContext, selection),
                icon: const Icon(Icons.more_horiz_rounded, size: 20),
                label: const Text('更多'),
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
