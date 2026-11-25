import 'dart:io';

import 'package:dart_console/dart_console.dart';

final List<String> _scriptedPromptAnswers = _loadScriptedPromptAnswers();

class CliOption<T> {
  const CliOption({
    required this.value,
    required this.label,
    required this.detail,
    this.aliases = const <String>[],
    this.badge,
  });

  final T value;
  final String label;
  final String detail;
  final List<String> aliases;
  final String? badge;
}

class CliSummaryRow {
  const CliSummaryRow(
    this.label,
    this.value, {
    this.highlight = false,
    this.warning = false,
    this.dim = false,
  });

  final String label;
  final String value;
  final bool highlight;
  final bool warning;
  final bool dim;
}

/// 现代终端交互与排版工具。
///
/// 关键约束：
/// - TUI 菜单采用 ANSI 相对光标移动（`\r` + `\x1b[nA` + `\x1b[J`），
///   避免依赖终端绝对光标坐标在底部滚屏时发生错位重复渲染；
/// - 每行按终端列宽（含 CJK 宽字符）安全截断为单物理行，防止自动折行破坏行计数；
/// - 在 CI、无 TTY、`NO_COLOR` 或测试输入环境下自动降级为纯文本交互。
class CliUi {
  CliUi({Console? console}) : _console = console ?? Console();

  final Console _console;

  bool get canPrompt =>
      _scriptedPromptAnswers.isNotEmpty ||
      _stdinHasTerminal() ||
      _shellPromptSupported();

  bool get usesColor =>
      !_noColor() &&
      !_forcePlainUi() &&
      _stdoutHasTerminal() &&
      !_isDumbTerminal();

  bool get usesTui =>
      _scriptedPromptAnswers.isEmpty &&
      !_forcePlainUi() &&
      _stdinHasTerminal() &&
      _stdoutHasTerminal() &&
      !_isCiEnvironment() &&
      !_isDumbTerminal();

  int get _columns {
    try {
      final width = _console.windowWidth;
      if (width >= 40) return width;
    } catch (_) {
      // 某些非标准终端读取宽度可能抛异常，回退默认值。
    }
    return 80;
  }

  // ------------------------------------------------------------------ 样式辅助

  String _ansi(String code, String text) =>
      usesColor ? '\x1b[${code}m$text\x1b[0m' : text;

  String bold(String text) => _ansi('1', text);
  String dim(String text) => _ansi('2', text);
  String cyan(String text) => _ansi('36', text);
  String brightCyan(String text) => _ansi('96', text);
  String green(String text) => _ansi('32', text);
  String brightGreen(String text) => _ansi('92', text);
  String yellow(String text) => _ansi('33', text);
  String red(String text) => _ansi('31', text);
  String magenta(String text) => _ansi('35', text);
  String boldCyan(String text) => _ansi('1;96', text);
  String boldGreen(String text) => _ansi('1;92', text);
  String boldYellow(String text) => _ansi('1;93', text);
  String boldRed(String text) => _ansi('1;91', text);
  String boldWhite(String text) => _ansi('1;97', text);
  String badge(String text) =>
      usesColor ? '\x1b[1;30;46m $text \x1b[0m' : '[$text]';
  String warnBadge(String text) =>
      usesColor ? '\x1b[1;30;43m $text \x1b[0m' : '[$text]';

  // ------------------------------------------------------------------ 排版输出

  void intro(String title, {String? subtitle}) {
    stdout.writeln('');
    if (subtitle == null || subtitle.isEmpty) {
      stdout.writeln(badge(title));
    } else {
      stdout.writeln('${badge(title)}  ${dim(subtitle)}');
    }
    stdout.writeln('');
  }

  void outro(String message) {
    stdout.writeln('');
    stdout.writeln('${boldGreen('✔')}  ${boldWhite(message)}');
    stdout.writeln('');
  }

  void cancel([String message = '已取消']) {
    stdout.writeln('');
    stdout.writeln('${yellow('◼')}  ${dim(message)}');
    stdout.writeln('');
  }

  void step(String message) {
    stdout.writeln('${brightCyan('▸')}  ${boldWhite(message)}');
  }

  void success(String message) {
    stdout.writeln('${brightGreen('✔')}  $message');
  }

  void warn(String message) {
    stdout.writeln('${boldYellow('▲')}  ${yellow(message)}');
  }

  void error(String message) {
    stderr.writeln('${boldRed('✖')}  ${red(message)}');
  }

  void info(String message) {
    stdout.writeln('${dim('│')}  $message');
  }

  void summaryBox({
    required String title,
    required List<CliSummaryRow> rows,
    List<String> notes = const <String>[],
    bool isSuccess = false,
    bool isWarning = false,
  }) {
    final maxLabelWidth = rows.fold<int>(
      0,
      (max, row) => _maxInt(max, displayWidth(row.label)),
    );

    final contentLines = <String>[];
    for (final row in rows) {
      final paddedLabel = padRightDisplayWidth(row.label, maxLabelWidth);
      final styledLabel = dim(paddedLabel);
      final styledValue = row.warning
          ? boldYellow(row.value)
          : row.highlight
          ? boldCyan(row.value)
          : row.dim
          ? dim(row.value)
          : row.value;
      contentLines.add('$styledLabel  $styledValue');
    }

    final maxBoxInnerWidth = (_columns - 6).clamp(32, 92);
    final rowLines = List<String>.from(contentLines);
    final neededWidth = [
      displayWidth(title) + 4,
      for (final line in rowLines) displayWidth(stripAnsi(line)),
      for (final note in notes) displayWidth('▲ $note'),
    ].fold<int>(0, _maxInt);
    final innerWidth = neededWidth.clamp(32, maxBoxInnerWidth);

    final finalLines = <String>[...rowLines];
    if (notes.isNotEmpty) {
      if (finalLines.isNotEmpty) {
        finalLines.add('');
      }
      for (final note in notes) {
        final wrapped = _wrapText(note, innerWidth - 2);
        for (var i = 0; i < wrapped.length; i++) {
          final prefix = i == 0 ? '▲ ' : '  ';
          finalLines.add(yellow('$prefix${wrapped[i]}'));
        }
      }
    }

    final borderColor = isSuccess
        ? green
        : isWarning
        ? yellow
        : cyan;

    final titlePart = ' $title ';
    final topDashCount = (innerWidth + 2 - displayWidth(titlePart) - 1).clamp(
      1,
      200,
    );
    stdout.writeln(
      '${borderColor('╭─')}${boldWhite(titlePart)}${borderColor('${'─' * topDashCount}╮')}',
    );

    for (final rawLine in finalLines) {
      final truncated = truncateAnsi(rawLine, innerWidth);
      final pad = (innerWidth - displayWidth(stripAnsi(truncated))).clamp(
        0,
        200,
      );
      stdout.writeln(
        '${borderColor('│')} $truncated${' ' * pad} ${borderColor('│')}',
      );
    }

    stdout.writeln(borderColor('╰${'─' * (innerWidth + 2)}╯'));
  }

  // ------------------------------------------------------------------ 交互组件

  Future<T?> select<T>({
    required String title,
    required List<CliOption<T>> options,
    int defaultIndex = 0,
  }) async {
    if (options.isEmpty) {
      return null;
    }

    if (_scriptedPromptAnswers.isNotEmpty) {
      _printPlainMenu(title, options);
      return _selectFromPrompt(
        title: title,
        options: options,
        defaultIndex: defaultIndex,
      );
    }

    if (usesTui) {
      return _selectWithTui(
        title: title,
        options: options,
        defaultIndex: defaultIndex,
      );
    }

    _printPlainMenu(title, options);
    return _selectFromPrompt(
      title: title,
      options: options,
      defaultIndex: defaultIndex,
    );
  }

  Future<String?> input({
    required String prompt,
    String? defaultValue,
    String? placeholder,
    bool allowEmpty = false,
    String? Function(String value)? validator,
  }) async {
    while (true) {
      final hint = defaultValue != null && defaultValue.isNotEmpty
          ? ' ${dim('[$defaultValue]')}'
          : placeholder != null && placeholder.isNotEmpty
          ? ' ${dim('($placeholder)')}'
          : '';
      final prefix = usesColor ? '${boldCyan('◆')} ' : '';
      final promptText = '$prefix$prompt$hint: ';

      final raw = await _readLine(promptText, cancelOnEscape: true);
      if (raw == null) {
        return null;
      }

      final trimmed = raw.trim();
      final effectiveValue = trimmed.isEmpty ? (defaultValue ?? '') : trimmed;
      if (effectiveValue.isEmpty && !allowEmpty) {
        error('输入不能为空');
        continue;
      }

      final validationMessage = validator?.call(effectiveValue);
      if (validationMessage != null) {
        error(validationMessage);
        continue;
      }

      return effectiveValue;
    }
  }

  Future<bool?> confirm({
    required String prompt,
    bool defaultValue = false,
    String yesLabel = '确认',
    String noLabel = '取消',
  }) async {
    if (usesTui) {
      return _confirmWithTui(
        prompt: prompt,
        defaultValue: defaultValue,
        yesLabel: yesLabel,
        noLabel: noLabel,
      );
    }

    final suffix = defaultValue ? ' (Y/n) ' : ' (y/N) ';
    final reply = await _readLine('$prompt$suffix', cancelOnEscape: true);
    if (reply == null) {
      return null;
    }
    final normalized = reply.trim().toLowerCase();
    if (normalized.isEmpty) {
      return defaultValue;
    }
    if (normalized == 'y' || normalized == 'yes') {
      return true;
    }
    if (normalized == 'n' || normalized == 'no') {
      return false;
    }
    stdout.writeln('请输入 y/yes 或 n/no。');
    return confirm(
      prompt: prompt,
      defaultValue: defaultValue,
      yesLabel: yesLabel,
      noLabel: noLabel,
    );
  }

  // -------------------------------------------------------------- 纯文本回退

  void _printPlainMenu<T>(String title, List<CliOption<T>> options) {
    final maxLabel = options.fold<int>(
      8,
      (max, option) => _maxInt(max, displayWidth(option.label)),
    );
    stdout.writeln(title);
    for (var index = 0; index < options.length; index++) {
      final option = options[index];
      final padded = padRightDisplayWidth(option.label, maxLabel);
      final suffix = option.badge == null ? '' : ' [${option.badge}]';
      stdout.writeln('  ${index + 1}. $padded  ${option.detail}$suffix');
    }
  }

  Future<T?> _selectFromPrompt<T>({
    required String title,
    required List<CliOption<T>> options,
    required int defaultIndex,
  }) async {
    final safeDefault = defaultIndex.clamp(0, options.length - 1);
    while (true) {
      final input = await _readLine(
        '输入序号或名称 [${safeDefault + 1}]: ',
        cancelOnEscape: true,
      );
      if (input == null) {
        return null;
      }

      final raw = input.trim();
      if (_isCancelToken(raw)) {
        return null;
      }

      final selectedOption = _matchOption(raw, options, safeDefault);
      if (selectedOption != null) {
        stdout.writeln('');
        return selectedOption.value;
      }

      stdout.writeln(
        '请输入 1-${options.length} 之间的序号，或 ${_labelsForOptions(options)}。',
      );
    }
  }

  // -------------------------------------------------------------- 相对重绘 TUI

  Future<T?> _selectWithTui<T>({
    required String title,
    required List<CliOption<T>> options,
    required int defaultIndex,
  }) async {
    var selectedIndex = defaultIndex.clamp(0, options.length - 1);
    final maxLabelWidth = options.fold<int>(
      6,
      (max, option) => _maxInt(max, displayWidth(option.label)),
    );
    const helpText = '↑/↓ 选择 · Enter 确认 · 数字/快捷键直达 · q/Esc 取消';

    final block = RelativeRenderBlock();
    CliOption<T>? resultOption;
    var cancelled = false;

    List<String> buildFrame() {
      final width = _columns;
      final lines = <String>[
        truncateAnsi('${boldCyan('◆')}  ${boldWhite(title)}', width),
        truncateAnsi('${dim('│')}  ${dim(helpText)}', width),
      ];
      for (var index = 0; index < options.length; index++) {
        final option = options[index];
        final isSelected = index == selectedIndex;
        final paddedLabel = padRightDisplayWidth(option.label, maxLabelWidth);
        final numTag = dim('${index + 1}');
        final badgeText = option.badge == null
            ? ''
            : ' ${isSelected ? badge(option.badge!) : dim('[${option.badge}]')}';
        if (isSelected) {
          lines.add(
            truncateAnsi(
              '${brightCyan('│')}  ${boldCyan('❯')} $numTag  ${boldCyan(paddedLabel)}  ${option.detail}$badgeText',
              width,
            ),
          );
        } else {
          lines.add(
            truncateAnsi(
              '${dim('│')}    $numTag  $paddedLabel  ${dim(option.detail)}$badgeText',
              width,
            ),
          );
        }
      }
      return lines;
    }

    _console.hideCursor();
    try {
      block.render(buildFrame());
      while (true) {
        final key = _console.readKey();

        if (!key.isControl) {
          final char = key.char.trim().toLowerCase();
          if (char.isEmpty) {
            if (key.char == ' ') {
              resultOption = options[selectedIndex];
              return resultOption.value;
            }
            continue;
          }
          if (_isCancelToken(char)) {
            cancelled = true;
            return null;
          }

          final selectedByText = _matchOption(
            char,
            options,
            selectedIndex,
          );
          if (selectedByText != null) {
            selectedIndex = options.indexOf(selectedByText);
            resultOption = selectedByText;
            return selectedByText.value;
          }

          if (char == 'k') {
            selectedIndex =
                (selectedIndex - 1 + options.length) % options.length;
            block.render(buildFrame());
            continue;
          }
          if (char == 'j') {
            selectedIndex = (selectedIndex + 1) % options.length;
            block.render(buildFrame());
            continue;
          }
        }

        switch (key.controlChar) {
          case ControlCharacter.arrowUp:
          case ControlCharacter.arrowLeft:
            selectedIndex =
                (selectedIndex - 1 + options.length) % options.length;
            block.render(buildFrame());
          case ControlCharacter.arrowDown:
          case ControlCharacter.arrowRight:
            selectedIndex = (selectedIndex + 1) % options.length;
            block.render(buildFrame());
          case ControlCharacter.home:
            selectedIndex = 0;
            block.render(buildFrame());
          case ControlCharacter.end:
            selectedIndex = options.length - 1;
            block.render(buildFrame());
          case ControlCharacter.enter:
            resultOption = options[selectedIndex];
            return resultOption.value;
          case ControlCharacter.escape:
          case ControlCharacter.ctrlC:
            cancelled = true;
            return null;
          default:
            break;
        }
      }
    } finally {
      block.clear();
      _console.resetColorAttributes();
      _console.showCursor();
      if (resultOption != null) {
        final summaryDetail = resultOption.detail.isEmpty
            ? ''
            : '  ${dim(resultOption.detail)}';
        stdout.writeln(
          truncateAnsi(
            '${brightGreen('✔')}  ${boldWhite(title)}  ${brightCyan(resultOption.label)}$summaryDetail',
            _columns,
          ),
        );
      } else if (cancelled) {
        stdout.writeln('${yellow('✖')}  ${boldWhite(title)}  ${dim('已取消')}');
      }
    }
  }

  Future<bool?> _confirmWithTui({
    required String prompt,
    required bool defaultValue,
    required String yesLabel,
    required String noLabel,
  }) async {
    var value = defaultValue;
    final block = RelativeRenderBlock();
    bool? finalValue;

    List<String> buildFrame() {
      final yesPart = value
          ? boldGreen('● $yesLabel')
          : dim('○ $yesLabel');
      final noPart = !value ? boldYellow('● $noLabel') : dim('○ $noLabel');
      return [
        truncateAnsi(
          '${boldCyan('◆')}  ${boldWhite(prompt)}   $yesPart   $noPart   ${dim('(←/→ 切换 · y/n · Enter)')}',
          _columns,
        ),
      ];
    }

    _console.hideCursor();
    try {
      block.render(buildFrame());
      while (true) {
        final key = _console.readKey();
        if (!key.isControl) {
          final char = key.char.trim().toLowerCase();
          if (char == 'y') {
            finalValue = true;
            return true;
          }
          if (char == 'n') {
            finalValue = false;
            return false;
          }
          if (_isCancelToken(char)) {
            return null;
          }
          if (key.char == ' ') {
            value = !value;
            block.render(buildFrame());
            continue;
          }
        }

        switch (key.controlChar) {
          case ControlCharacter.arrowLeft:
          case ControlCharacter.arrowRight:
          case ControlCharacter.arrowUp:
          case ControlCharacter.arrowDown:
          case ControlCharacter.tab:
            value = !value;
            block.render(buildFrame());
          case ControlCharacter.enter:
            finalValue = value;
            return value;
          case ControlCharacter.escape:
          case ControlCharacter.ctrlC:
            return null;
          default:
            break;
        }
      }
    } finally {
      block.clear();
      _console.resetColorAttributes();
      _console.showCursor();
      if (finalValue != null) {
        final label = finalValue ? brightGreen(yesLabel) : yellow(noLabel);
        stdout.writeln('${brightGreen('✔')}  ${boldWhite(prompt)}  $label');
      } else {
        stdout.writeln('${yellow('✖')}  ${boldWhite(prompt)}  ${dim('已取消')}');
      }
    }
  }

  Future<String?> _readLine(
    String prompt, {
    bool cancelOnEscape = false,
  }) async {
    final scripted = _consumeScriptedPromptAnswer();
    if (scripted != null) {
      stdout.writeln('$prompt$scripted');
      return scripted;
    }

    if (usesTui) {
      stdout.write(prompt);
      return _console.readLine(
        cancelOnBreak: true,
        cancelOnEscape: cancelOnEscape,
        cancelOnEOF: true,
      );
    }

    final directReply = _readLineFromStdin(prompt);
    if (directReply != null) {
      return directReply;
    }

    return _readLineViaShell(prompt);
  }
}

/// 基于 ANSI 相对光标移动的块级渲染器。
///
/// 不依赖绝对行号，即使菜单在终端最底行触发滚屏，重绘时仍能精准回到块首覆写，
/// 彻底避免上下键切换时菜单重复堆叠。
class RelativeRenderBlock {
  int _renderedLines = 0;

  int get renderedLines => _renderedLines;

  void render(List<String> lines, {StringSink? sink}) {
    final out = sink ?? stdout;
    final buffer = StringBuffer();
    _writeClearPrefix(buffer);
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) buffer.write('\n');
      buffer.write(lines[i]);
    }
    out.write(buffer.toString());
    _renderedLines = lines.length;
  }

  void clear({StringSink? sink}) {
    if (_renderedLines == 0) return;
    final out = sink ?? stdout;
    final buffer = StringBuffer();
    _writeClearPrefix(buffer);
    out.write(buffer.toString());
    _renderedLines = 0;
  }

  void _writeClearPrefix(StringBuffer buffer) {
    if (_renderedLines == 0) return;
    buffer.write('\r');
    if (_renderedLines > 1) {
      buffer.write('\x1b[${_renderedLines - 1}A');
    }
    buffer.write('\x1b[J');
  }
}

// ------------------------------------------------------------------ 文本宽度工具

final _ansiEscapePattern = RegExp(r'\x1b\[[0-9;]*[A-Za-z]');

String stripAnsi(String text) => text.replaceAll(_ansiEscapePattern, '');

/// 计算文本在等宽终端中的显示列宽（ASCII 占 1 列，CJK / 全角符号占 2 列）。
int displayWidth(String text) {
  var width = 0;
  for (final rune in stripAnsi(text).runes) {
    width += _runeDisplayWidth(rune);
  }
  return width;
}

String padRightDisplayWidth(String text, int targetWidth) {
  final current = displayWidth(text);
  if (current >= targetWidth) return text;
  return '$text${' ' * (targetWidth - current)}';
}

/// 按显示列宽截断带 ANSI 颜色码的文本，保证输出严格不超过 [maxColumns] 列。
String truncateAnsi(String text, int maxColumns) {
  if (maxColumns <= 0) return '';
  if (displayWidth(text) <= maxColumns) return text;

  final limit = maxColumns <= 1 ? maxColumns : maxColumns - 1;
  final buffer = StringBuffer();
  var used = 0;
  var hasAnsi = false;
  var index = 0;

  while (index < text.length) {
    if (text.codeUnitAt(index) == 0x1b) {
      final match = _ansiEscapePattern.matchAsPrefix(text, index);
      if (match != null) {
        buffer.write(match.group(0));
        hasAnsi = true;
        index = match.end;
        continue;
      }
    }

    final rune = _runeAt(text, index);
    final charLen = rune > 0xFFFF ? 2 : 1;
    final runeWidth = _runeDisplayWidth(rune);
    if (used + runeWidth > limit) {
      break;
    }
    buffer.write(text.substring(index, index + charLen));
    used += runeWidth;
    index += charLen;
  }

  if (maxColumns > 1) {
    buffer.write('…');
  }
  if (hasAnsi) {
    buffer.write('\x1b[0m');
  }
  return buffer.toString();
}

int _runeAt(String text, int index) {
  final first = text.codeUnitAt(index);
  if (first >= 0xD800 && first <= 0xDBFF && index + 1 < text.length) {
    final second = text.codeUnitAt(index + 1);
    if (second >= 0xDC00 && second <= 0xDFFF) {
      return 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00);
    }
  }
  return first;
}

int _runeDisplayWidth(int rune) {
  if (rune < 0x20 || (rune >= 0x7F && rune < 0xA0)) return 0;
  // 常见全角 / CJK / 符号区块
  if ((rune >= 0x1100 && rune <= 0x115F) ||
      rune == 0x2329 ||
      rune == 0x232A ||
      (rune >= 0x2E80 && rune <= 0xA4CF && rune != 0x303F) ||
      (rune >= 0xAC00 && rune <= 0xD7A3) ||
      (rune >= 0xF900 && rune <= 0xFAFF) ||
      (rune >= 0xFE10 && rune <= 0xFE19) ||
      (rune >= 0xFE30 && rune <= 0xFE6F) ||
      (rune >= 0xFF00 && rune <= 0xFF60) ||
      (rune >= 0xFFE0 && rune <= 0xFFE6) ||
      (rune >= 0x1F300 && rune <= 0x1FAFF) ||
      (rune >= 0x20000 && rune <= 0x3FFFD)) {
    return 2;
  }
  return 1;
}

int _maxInt(int a, int b) => a > b ? a : b;

List<String> _wrapText(String text, int maxColumns) {
  if (maxColumns <= 2 || displayWidth(text) <= maxColumns) {
    return [text];
  }
  final lines = <String>[];
  final buffer = StringBuffer();
  var used = 0;
  var index = 0;
  while (index < text.length) {
    final rune = _runeAt(text, index);
    final charLen = rune > 0xFFFF ? 2 : 1;
    final runeWidth = _runeDisplayWidth(rune);
    if (used + runeWidth > maxColumns && buffer.isNotEmpty) {
      lines.add(buffer.toString());
      buffer.clear();
      used = 0;
    }
    buffer.write(text.substring(index, index + charLen));
    used += runeWidth;
    index += charLen;
  }
  if (buffer.isNotEmpty) {
    lines.add(buffer.toString());
  }
  return lines;
}

// ------------------------------------------------------------------ 底层输入与环境

String? _readLineFromStdin(String prompt) {
  if (!_stdinHasTerminal()) {
    return null;
  }

  stdout.write(prompt);
  try {
    return stdin.readLineSync();
  } on StdinException {
    return null;
  }
}

Future<String?> _readLineViaShell(String prompt) async {
  File? replyFile;
  try {
    replyFile = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'fluxdo_cli_prompt_${pid}_${DateTime.now().microsecondsSinceEpoch}.txt',
    );
    final environment = Map<String, String>.from(Platform.environment)
      ..['FLUXDO_CLI_PROMPT'] = stripAnsi(prompt)
      ..['FLUXDO_CLI_REPLY_FILE'] = replyFile.path;

    final executable = Platform.isWindows ? 'powershell' : 'sh';
    final arguments = Platform.isWindows
        ? const [
            '-NoLogo',
            '-NoProfile',
            '-Command',
            r"$reply = Read-Host $env:FLUXDO_CLI_PROMPT; if ($null -eq $reply) { exit 2 }; Set-Content -LiteralPath $env:FLUXDO_CLI_REPLY_FILE -NoNewline -Value $reply; exit 0",
          ]
        : [
            '-c',
            r'printf "%s" "$FLUXDO_CLI_PROMPT" > /dev/tty; '
                r'IFS= read -r reply < /dev/tty || exit 2; '
                r'printf "%s" "$reply" > "$FLUXDO_CLI_REPLY_FILE"',
          ];

    final process = await Process.start(
      executable,
      arguments,
      mode: ProcessStartMode.inheritStdio,
      runInShell: Platform.isWindows,
      environment: environment,
    );
    final exitCode = await process.exitCode;
    if (exitCode != 0 || !replyFile.existsSync()) {
      return null;
    }

    return replyFile.readAsStringSync();
  } on ProcessException {
    return null;
  } on FileSystemException {
    return null;
  } finally {
    try {
      replyFile?.deleteSync();
    } on FileSystemException {
      // ignore cleanup failure
    }
  }
}

CliOption<T>? _matchOption<T>(
  String raw,
  List<CliOption<T>> options,
  int defaultIndex,
) {
  if (raw.isEmpty) {
    return options[defaultIndex.clamp(0, options.length - 1)];
  }

  final asIndex = int.tryParse(raw);
  if (asIndex != null && asIndex >= 1 && asIndex <= options.length) {
    return options[asIndex - 1];
  }

  final normalized = raw.trim().toLowerCase();
  for (final option in options) {
    if (normalized == option.label.toLowerCase()) {
      return option;
    }
    if (option.aliases.any((alias) => normalized == alias.toLowerCase())) {
      return option;
    }
  }

  return null;
}

String _labelsForOptions<T>(List<CliOption<T>> options) {
  return options.map((option) => option.label).join(' / ');
}

bool _isCancelToken(String value) {
  final normalized = value.trim().toLowerCase();
  return normalized == 'q' || normalized == 'quit' || normalized == 'exit';
}

bool _stdinHasTerminal() {
  try {
    return stdin.hasTerminal;
  } on StdinException {
    return false;
  }
}

bool _stdoutHasTerminal() {
  try {
    return stdout.hasTerminal;
  } on StdoutException {
    return false;
  }
}

bool _shellPromptSupported() =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

bool _isCiEnvironment() {
  final ci = Platform.environment['CI']?.trim().toLowerCase();
  return ci == '1' || ci == 'true';
}

bool _isDumbTerminal() =>
    Platform.environment['TERM']?.trim().toLowerCase() == 'dumb';

bool _forcePlainUi() {
  final value = Platform.environment['FLUXDO_CLI_FORCE_PLAIN']
      ?.trim()
      .toLowerCase();
  return value == '1' || value == 'true' || value == 'yes';
}

bool _noColor() => Platform.environment.containsKey('NO_COLOR');

List<String> _loadScriptedPromptAnswers() {
  final raw =
      Platform.environment['FLUXDO_CLI_TEST_INPUTS']?.trim() ??
      Platform.environment['FLUXDO_RELEASE_TEST_INPUTS']?.trim();
  if (raw == null || raw.isEmpty) {
    return <String>[];
  }
  return raw.split('|').map((item) => item.trim()).toList();
}

String? _consumeScriptedPromptAnswer() {
  if (_scriptedPromptAnswers.isEmpty) {
    return null;
  }
  return _scriptedPromptAnswers.removeAt(0);
}
