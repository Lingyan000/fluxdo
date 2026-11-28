import 'package:app_icons/app_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';

/// 分组卡片内的折叠项：外框由分组绘制，展开箭头使用应用图标。
class MetaverseExpansionTile extends StatefulWidget {
  const MetaverseExpansionTile({
    super.key,
    required this.title,
    this.leading,
    this.subtitle,
    required this.children,
  });
  final Widget title;
  final Widget? leading, subtitle;
  final List<Widget> children;

  @override
  State<MetaverseExpansionTile> createState() => _MetaverseExpansionTileState();
}

class _MetaverseExpansionTileState extends State<MetaverseExpansionTile> {
  static const _duration = Duration(milliseconds: 200);
  bool _expanded = false;
  @override
  Widget build(BuildContext context) => ExpansionTile(
    title: widget.title,
    leading: widget.leading,
    subtitle: widget.subtitle,
    shape: const Border(),
    collapsedShape: const Border(),
    onExpansionChanged: (value) => setState(() => _expanded = value),
    trailing: AnimatedRotation(
      turns: _expanded ? .5 : 0,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : _duration,
      curve: M3eMotion.defaultSpatial.curveFor(_duration),
      child: const Icon(Symbols.expand_more_rounded),
    ),
    children: widget.children,
  );
}
