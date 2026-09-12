import 'package:flutter/material.dart';
import '../../l10n/s.dart';

enum ComposerToolGroup {
  format,
  insert,
  editing;

  String get label => switch (this) {
    format => S.current.composer_toolsFormat,
    insert => S.current.composer_toolsInsert,
    editing => S.current.composer_toolsEditing,
  };
}

class ComposerToolAction {
  const ComposerToolAction({
    required this.label,
    required this.icon,
    required this.run,
    this.id = '',
    this.children = const [],
    this.searchText = '',
    this.group = ComposerToolGroup.format,
    this.shortcut,
    this.enabled = true,
    this.active = false,
    this.isPinned,
    this.togglePinned,
  });
  String get keyId => id.isEmpty ? label : id;
  final String id;
  final List<ComposerToolAction> children;
  final String label;
  final Widget icon;
  final VoidCallback run;
  final String searchText;
  final ComposerToolGroup group;
  final String? shortcut;
  final bool enabled;
  final bool active;
  final bool Function()? isPinned;
  final VoidCallback? togglePinned;
}
