// 图标统一迁移脚本：将 lib/ 与 test/ 下的 `Icons.*` 替换为 `Symbols.*_rounded`。
//
// 规则：
//   1. Icons.x_outlined / Icons.x_border / Icons.x_sharp → Symbols.x_rounded
//   2. Icons.x_outline_rounded / Icons.x_outlined_rounded → Symbols.x_rounded
//   3. Icons.x_rounded → Symbols.x_rounded
//   4. 裸 Icons.x（无后缀）→ Symbols.x_rounded
//      * 若该图标在项目中**同时**存在 _outlined / _border 变体，则在调用点旁加
//        `/* TODO(icons): 该处可能是激活态，按需追加 fill: 1 */` 注释。
//
// 别名修正（左：Material 旧名 → 右：Symbols 基础名，脚本会再补 `_rounded`）：
//   delete_outline → delete、error_outline → error、info_outline → info ……
//
// import 处理：若文件含 `Icons.` 且没有 material_symbols_icons import，
//   在第一个 `import 'package:material_ui/material_ui.dart';` 之后追加。
//
// 用法：
//   dart run tool/migrate_icons.dart            # dry-run，仅打印影响面
//   dart run tool/migrate_icons.dart --apply    # 真正写文件
//   dart run tool/migrate_icons.dart --apply --path lib/widgets/share

import 'dart:io';

const _materialImport = "import 'package:material_ui/material_ui.dart';";
const _symbolsImport =
    "import 'package:material_symbols_icons/symbols.dart';";

/// 别名：Material `Icons.` 的"非标"命名 → Symbols 规范命名。
const _aliasMap = <String, String>{
  // *_outline → 基础名
  'delete_outline': 'delete',
  'error_outline': 'error',
  'info_outline': 'info',
  'help_outline': 'help',
  'lock_outline': 'lock',
  'mail_outline': 'mail',
  'person_outline': 'person',
  'people_outline': 'group',
  'shield_outline': 'shield',
  'security_outline': 'security',
  'verified_user_outline': 'verified_user',
  'check_circle_outline': 'check_circle',
  'add_circle_outline': 'add_circle',
  'remove_circle_outline': 'remove_circle',
  'play_circle_outline': 'play_circle',
  'chat_bubble_outline': 'chat_bubble',
  'label_outline': 'label',
  'favorite_outline': 'favorite',
  'star_outline': 'star',
  'cancel_outlined': 'cancel',
  // *_border
  'bookmark_border': 'bookmark',
  'star_border': 'star',
  'favorite_border': 'favorite',
  // visibility / notifications / push_pin 系列
  'visibility_outlined': 'visibility',
  'visibility_off_outlined': 'visibility_off',
  'notifications_none': 'notifications',
  'notifications_outlined': 'notifications',
  'notifications_active_outlined': 'notifications_active',
  'push_pin_outlined': 'push_pin',
  // thumb / do_not_disturb 系列（_alt 在 Symbols 不存在）
  'thumb_up_alt_outlined': 'thumb_up',
  'thumb_down_alt_outlined': 'thumb_down',
  'do_not_disturb_alt_outlined': 'do_not_disturb_on',
  'do_not_disturb_alt': 'do_not_disturb_on',
};

void main(List<String> args) async {
  final apply = args.contains('--apply');
  final pathIdx = args.indexOf('--path');
  final root = pathIdx >= 0 && pathIdx + 1 < args.length
      ? args[pathIdx + 1]
      : 'lib';

  final dir = Directory(root);
  if (!dir.existsSync()) {
    stderr.writeln('目录不存在: $root');
    exit(2);
  }

  final files = dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .where((f) => !f.path.endsWith('lib/ui/app_icons.dart'))
      .where((f) => !f.path.contains('tool/migrate_icons.dart'))
      .toList();

  var changedFiles = 0;
  var changedSites = 0;
  final variantBaseNames = <String>{};

  // 第一遍：收集"存在 outline/border 变体"的基础名 —— 这些基础名的裸调用
  // 可能是激活态，需打 TODO 标记。
  final iconRefRe = RegExp(r'\bIcons\.([A-Za-z_][A-Za-z0-9_]*)');
  for (final f in files) {
    final src = f.readAsStringSync();
    for (final m in iconRefRe.allMatches(src)) {
      final name = m.group(1)!;
      final hint = _stateHint(name);
      if (hint != null) variantBaseNames.add(hint);
    }
  }

  for (final f in files) {
    final src = f.readAsStringSync();
    if (!src.contains('Icons.')) continue;

    var newSrc = src.replaceAllMapped(iconRefRe, (m) {
      final raw = m.group(1)!;
      final mapped = _mapName(raw, variantBaseNames);
      if (mapped == null) return m.group(0)!;
      changedSites += 1;
      final todoTag =
          mapped.todo ? ' /* TODO(icons): 可能为激活态，按需 fill:1 */' : '';
      return 'Symbols.${mapped.symbolName}$todoTag';
    });

    if (newSrc == src) continue;

    // 注入 import（在第一个 material.dart import 之后）
    if (!newSrc.contains('material_symbols_icons/symbols.dart')) {
      final idx = newSrc.indexOf(_materialImport);
      if (idx >= 0) {
        final insertAt = idx + _materialImport.length;
        newSrc =
            '${newSrc.substring(0, insertAt)}\n$_symbolsImport${newSrc.substring(insertAt)}';
      } else {
        final lines = newSrc.split('\n');
        var lastImport = -1;
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].startsWith('import ')) lastImport = i;
        }
        if (lastImport >= 0) {
          lines.insert(lastImport + 1, _symbolsImport);
          newSrc = lines.join('\n');
        }
      }
    }

    changedFiles += 1;
    if (apply) f.writeAsStringSync(newSrc);
  }

  stdout.writeln('扫描文件 ${files.length}，将改动 $changedFiles 个文件、'
      '$changedSites 个调用点。${apply ? "已写入。" : "(dry-run)"}');
}

class _Mapped {
  final String symbolName;
  final bool todo;
  _Mapped(this.symbolName, {this.todo = false});
}

String? _stateHint(String raw) {
  for (final suf in const ['_outlined', '_rounded', '_sharp', '_border']) {
    if (raw.endsWith(suf)) return raw.substring(0, raw.length - suf.length);
  }
  if (_aliasMap.containsKey(raw)) return _aliasMap[raw];
  return null;
}

_Mapped? _mapName(String raw, Set<String> baseNamesWithVariant) {
  // 0. 双后缀 *_outline_rounded / *_outlined_rounded → 去掉 outline，留 rounded
  for (final mid in const ['_outline_rounded', '_outlined_rounded']) {
    if (raw.endsWith(mid)) {
      final base = raw.substring(0, raw.length - mid.length);
      return _Mapped('${base}_rounded');
    }
  }

  // 1. alias 优先
  if (_aliasMap.containsKey(raw)) {
    return _Mapped('${_aliasMap[raw]}_rounded');
  }

  // 2. 去掉已有风格后缀
  for (final suf in const ['_outlined', '_rounded', '_sharp']) {
    if (raw.endsWith(suf)) {
      final base = raw.substring(0, raw.length - suf.length);
      return _Mapped('${base}_rounded');
    }
  }
  if (raw.endsWith('_border')) {
    final base = raw.substring(0, raw.length - '_border'.length);
    return _Mapped('${base}_rounded');
  }

  // 3. 裸名：若该基础名在项目中也以 outline/border 形式出现，标 TODO；否则普通替换。
  final todo = baseNamesWithVariant.contains(raw);
  return _Mapped('${raw}_rounded', todo: todo);
}
