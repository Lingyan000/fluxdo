import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _nonCode = RegExp(
  r"""//[^\r\n]*|/\*[\s\S]*?\*/|'''[\s\S]*?'''|"""
  r'''"""[\s\S]*?"""|'''
  r"""'(?:\\.|[^'\\\r\n])*'|["](?:\\.|[^"\\\r\n])*["]""",
);
final _nonNewline = RegExp(r'[^\r\n]');
final _decoration = RegExp(r'\bInputDecoration\s*\(');
final _rawNone = RegExp(r'^InputBorder\s*\.\s*none$');
final _noSide = RegExp(r'^BorderSide\s*\.\s*none$');
final _shapeBorder = RegExp(
  r'^(?:(?:const|new)\s+)?(?:OutlineInputBorder|UnderlineInputBorder)\s*\(',
);
final _delimiters = RegExp(r'[()\[\]{},]');
final _argumentName = RegExp(r'^\s*(\w+)\s*:\s*');

Map<String, String> _arguments(String source, int start) {
  final arguments = <String, String>{};
  var depth = 0;
  var argumentStart = start;
  for (final match in _delimiters.allMatches(source, start)) {
    switch (match[0]) {
      case '(' || '[' || '{':
        depth++;
      case ')' || ']' || '}' when depth > 0:
        depth--;
      case ',' || ')' when depth == 0:
        final argument = source.substring(argumentStart, match.start);
        final name = _argumentName.matchAsPrefix(argument);
        if (name != null) {
          arguments[name[1]!] = argument.substring(name.end).trim();
        }
        if (match[0] == ')') return arguments;
        argumentStart = match.end;
    }
  }
  return arguments;
}

bool _hasNoStroke(String border) {
  if (_rawNone.hasMatch(border)) return true;
  final shape = _shapeBorder.matchAsPrefix(border);
  return shape != null &&
      _noSide.hasMatch(_arguments(border, shape.end)['borderSide'] ?? '');
}

bool _inheritsBorder(String? value) => value == null || value == 'null';

Iterable<int> _missingStateBorders(String content) sync* {
  final source = content.replaceAllMapped(
    _nonCode,
    (match) => match[0]!.replaceAll(_nonNewline, ' '),
  );
  for (final match in _decoration.allMatches(source)) {
    final arguments = _arguments(source, match.end);
    final border = arguments['border'];
    if (border == null || !_hasNoStroke(border)) continue;
    if (_inheritsBorder(arguments['enabledBorder']) ||
        _inheritsBorder(arguments['focusedBorder'])) {
      yield '\n'.allMatches(source.substring(0, match.start)).length + 1;
    }
  }
}

void main() {
  test('识别只覆盖默认边框或漏掉一种状态边框的输入框', () {
    expect(
      _missingStateBorders('''
InputDecoration(border: InputBorder.none);
InputDecoration(
  border: OutlineInputBorder(
    borderRadius: context.shapes.borderRadius(24),
    borderSide: BorderSide.none,
  ),
  enabledBorder: localBorder,
);
InputDecoration(
  border: const UnderlineInputBorder(borderSide: BorderSide.none),
  enabledBorder: null,
  focusedBorder: localBorder,
);
'''),
      [1, 2, 9],
    );
  });

  test('已接管状态边框、正常继承主题的输入框不报错', () {
    expect(
      _missingStateBorders('''
InputDecoration(
  border: OutlineInputBorder(borderSide: BorderSide.none),
  enabledBorder: localBorder,
  focusedBorder: localBorder,
);
InputDecoration(border: OutlineInputBorder());
InputDecoration(hintText: 'InputDecoration(border: InputBorder.none)');
InputDecoration().withoutBorder();
'''),
      isEmpty,
    );
  });

  test('无边框输入框不继承主题的常态和聚焦边框', () {
    final violations = <String>[];
    final sources = [
      Directory('lib'),
      ...Directory('packages')
          .listSync(followLinks: false)
          .whereType<Directory>()
          .map((package) => Directory('${package.path}/lib'))
          .where((directory) => directory.existsSync()),
    ];
    for (final file
        in sources
            .expand(
              (source) => source.listSync(recursive: true, followLinks: false),
            )
            .whereType<File>()) {
      if (!file.path.endsWith('.dart') || file.path.endsWith('.g.dart')) {
        continue;
      }
      for (final line in _missingStateBorders(file.readAsStringSync())) {
        violations.add('${file.path}:$line');
      }
    }
    expect(
      violations,
      isEmpty,
      reason: '无边框输入框用 withoutBorder()；自带底色和圆角的输入框用 InputFieldShell 绘制主题边线。',
    );
  });
}
