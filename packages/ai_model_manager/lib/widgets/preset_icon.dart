import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';

/// 把 PromptPreset.iconRaw 渲染成一个 Widget
///
/// iconRaw 可以是：
/// - emoji 字符（首 rune > 0xFF）：直接用 Text 渲染
/// - Material icon name（小写下划线）：查表
/// - 未知：fallback 到 Symbols.auto_awesome_rounded
class PresetIcon extends StatelessWidget {
  const PresetIcon({
    super.key,
    required this.iconRaw,
    this.size = 18,
    this.color,
  });

  final String iconRaw;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    if (_looksLikeEmoji(iconRaw)) {
      // emoji 用 Text，字号略小一点保证视觉等高
      return Text(
        iconRaw,
        style: TextStyle(fontSize: size * 0.95, height: 1),
      );
    }
    final icon = _materialIconMap[iconRaw] ?? Symbols.auto_awesome_rounded;
    return Icon(icon, size: size, color: color);
  }

  static bool _looksLikeEmoji(String s) {
    if (s.isEmpty) return false;
    final first = s.runes.first;
    // 排除 ASCII 字母、数字、下划线、冒号等
    if (first < 0x80) return false;
    return true;
  }
}

/// 暴露给 IconEmojiPicker 使用的 outlined icon 候选集
const List<String> kBuiltInIconNames = [
  'image_outlined',
  'brush_outlined',
  'draw_outlined',
  'palette_outlined',
  'auto_awesome_outlined',
  'lightbulb_outlined',
  'summarize_outlined',
  'translate_outlined',
  'question_answer_outlined',
  'smart_toy_outlined',
  'emoji_emotions_outlined',
  'camera_alt_outlined',
  'movie_outlined',
  'map_outlined',
  'favorite_outline',
  'star_outline',
  'share_outlined',
  'crop_din_outlined',
  'view_in_ar_outlined',
  'sticky_note_2_outlined',
  'grid_4x4',
];

/// Material icon name → IconData 映射
const Map<String, IconData> _materialIconMap = {
  'image_outlined': Symbols.image_rounded,
  'brush_outlined': Symbols.brush_rounded,
  'draw_outlined': Symbols.draw_rounded,
  'palette_outlined': Symbols.palette_rounded,
  'auto_awesome_outlined': Symbols.auto_awesome_rounded,
  'lightbulb_outlined': Symbols.lightbulb_rounded,
  'summarize_outlined': Symbols.summarize_rounded,
  'translate_outlined': Symbols.translate_rounded,
  'question_answer_outlined': Symbols.question_answer_rounded,
  'smart_toy_outlined': Symbols.smart_toy_rounded,
  'emoji_emotions_outlined': Symbols.emoji_emotions_rounded,
  'camera_alt_outlined': Symbols.camera_alt_rounded,
  'movie_outlined': Symbols.movie_rounded,
  'map_outlined': Symbols.map_rounded,
  'favorite_outline': Symbols.favorite_rounded,
  'star_outline': Symbols.star_rounded,
  'share_outlined': Symbols.share_rounded,
  'crop_din_outlined': Symbols.crop_din_rounded,
  'view_in_ar_outlined': Symbols.view_in_ar_rounded,
  'sticky_note_2_outlined': Symbols.sticky_note_2_rounded,
  'grid_4x4': Symbols.grid_4x4_rounded,
  // 兼容历史 chip 用的图标（防止预设 iconRaw 找不到时降级）
  'image': Symbols.image_rounded,
  'brush': Symbols.brush_rounded,
  'draw': Symbols.draw_rounded,
};
