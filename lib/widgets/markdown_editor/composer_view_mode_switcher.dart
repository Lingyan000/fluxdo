import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../l10n/s.dart';
import 'composer_page_chrome.dart';

enum ComposerViewMode { rich, source, preview }

extension ComposerViewModeX on ComposerViewMode {
  IconData get icon => switch (this) {
    ComposerViewMode.rich => Symbols.wysiwyg_rounded,
    ComposerViewMode.source => Symbols.code_rounded,
    ComposerViewMode.preview => AppIcons.book,
  };

  String get label => switch (this) {
    ComposerViewMode.rich => S.current.composerView_rich,
    ComposerViewMode.source => S.current.composerView_source,
    ComposerViewMode.preview => S.current.composerView_preview,
  };
}

/// 固定图标入口，图标和提示说明可切换至的编辑模式。
class ComposerModeButton extends StatelessWidget {
  const ComposerModeButton({super.key, required this.rich, this.onPressed});

  final bool rich;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip:
        '${S.current.composerView_switch}: '
        '${rich ? S.current.composerView_source : S.current.composerView_rich}',
    onPressed: onPressed,
    icon: Icon(rich ? Symbols.code_rounded : Symbols.wysiwyg_rounded, size: 21),
  );
}

/// 预览是独立开关，退出时不改变富文本/源码模式。
class ComposerPreviewButton extends StatelessWidget {
  const ComposerPreviewButton({
    super.key,
    required this.previewing,
    required this.onPressed,
  });

  final bool previewing;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => ComposerActionButton(
    label: previewing ? S.current.common_exitPreview : S.current.common_preview,
    onPressed: onPressed,
    color: previewing ? Theme.of(context).colorScheme.primary : null,
    icon: previewing ? Symbols.edit_rounded : AppIcons.book,
  );
}
