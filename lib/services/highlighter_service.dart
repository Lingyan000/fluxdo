import 'dart:async';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/github.dart';
import 'package:re_highlight/styles/github-dark.dart';

/// 可序列化的高亮 token
class HighlightToken {
  final String type; // 'text', 'open', 'close'
  final String? content;
  final String? scope;

  const HighlightToken.text(String this.content) : type = 'text', scope = null;
  const HighlightToken.open(String this.scope) : type = 'open', content = null;
  const HighlightToken.close() : type = 'close', content = null, scope = null;

  Map<String, dynamic> toMap() => {'type': type, 'content': content, 'scope': scope};
  factory HighlightToken.fromMap(Map<String, dynamic> map) {
    switch (map['type']) {
      case 'text': return HighlightToken.text(map['content'] as String);
      case 'open': return HighlightToken.open(map['scope'] as String);
      default: return const HighlightToken.close();
    }
  }
}

/// 自定义渲染器，将高亮结果转为 token 列表
class _TokenListRenderer implements HighlightRenderer {
  final List<HighlightToken> tokens = [];

  @override
  void addText(String text) => tokens.add(HighlightToken.text(text));

  @override
  void openNode(DataNode node) {
    if (node.scope != null) tokens.add(HighlightToken.open(node.scope!));
  }

  @override
  void closeNode(DataNode node) {
    if (node.scope != null) tokens.add(const HighlightToken.close());
  }
}

/// 持久化的 Isolate Worker
class _HighlightWorker {
  static _HighlightWorker? _instance;

  Isolate? _isolate;
  SendPort? _sendPort;
  final _readyCompleter = Completer<void>();

  _HighlightWorker._();

  static _HighlightWorker get instance {
    _instance ??= _HighlightWorker._();
    return _instance!;
  }

  Future<void> ensureInitialized() async {
    if (_isolate != null) return _readyCompleter.future;

    final receivePort = ReceivePort();
    _isolate = await Isolate.spawn(_isolateMain, receivePort.sendPort);

    _sendPort = await receivePort.first as SendPort;
    _readyCompleter.complete();
  }

  static void _isolateMain(SendPort mainSendPort) {
    final receivePort = ReceivePort();
    mainSendPort.send(receivePort.sendPort);

    final highlight = Highlight();
    final registeredLanguages = <String>{};

    receivePort.listen((message) {
      if (message is Map<String, dynamic>) {
        final type = message['type'] as String;
        if (type == 'highlight') {
          final code = message['code'] as String;
          final language = message['language'] as String?;
          final fallbackLanguages = (message['fallbackLanguages'] as List).cast<String>();
          final replyPort = message['replyPort'] as SendPort;

          final result = _processHighlight(
            highlight,
            registeredLanguages,
            code,
            language,
            fallbackLanguages,
          );
          replyPort.send(result);
        } else if (type == 'shutdown') {
          receivePort.close();
          Isolate.exit();
        }
      }
    });
  }

  static List<Map<String, dynamic>> _processHighlight(
    Highlight highlight,
    Set<String> registeredLanguages,
    String code,
    String? language,
    List<String> fallbackLanguages,
  ) {
    // 按需注册语言
    void ensureLanguageRegistered(String lang) {
      if (!registeredLanguages.contains(lang) && builtinAllLanguages.containsKey(lang)) {
        highlight.registerLanguage(lang, builtinAllLanguages[lang]!);
        registeredLanguages.add(lang);
      }
    }

    HighlightResult result;
    if (language != null && language.isNotEmpty && language != 'plaintext') {
      ensureLanguageRegistered(language);
      try {
        result = highlight.highlight(code: code, language: language);
      } catch (e) {
        result = highlight.justTextHighlightResult(code);
      }
    } else {
      // 注册 fallback 语言用于自动检测
      for (final lang in fallbackLanguages) {
        ensureLanguageRegistered(lang);
      }
      result = highlight.highlightAuto(code, fallbackLanguages);
    }

    final renderer = _TokenListRenderer();
    result.render(renderer);
    return renderer.tokens.map((t) => t.toMap()).toList();
  }

  Future<List<Map<String, dynamic>>> highlight(String code, String? language, List<String> fallbackLanguages) async {
    await ensureInitialized();

    final receivePort = ReceivePort();
    _sendPort!.send({
      'type': 'highlight',
      'code': code,
      'language': language,
      'fallbackLanguages': fallbackLanguages,
      'replyPort': receivePort.sendPort,
    });

    return (await receivePort.first as List).cast<Map<String, dynamic>>();
  }

  void shutdown() {
    _sendPort?.send({'type': 'shutdown'});
    _isolate?.kill();
    _isolate = null;
    _sendPort = null;
    _instance = null;
  }
}

/// 单例服务，用于管理语法高亮器
class HighlighterService {
  static HighlighterService? _instance;
  static const _commonLanguages = [
    'json', 'javascript', 'typescript', 'python', 'java', 'kotlin',
    'go', 'rust', 'dart', 'c', 'cpp', 'csharp', 'php', 'ruby',
    'yaml', 'xml', 'html', 'css', 'bash', 'sql', 'markdown', 'swift',
    'objectivec', 'lua', 'perl', 'r', 'scala', 'groovy', 'powershell',
  ];

  // LRU 缓存
  final _cache = <String, List<HighlightToken>>{};
  static const _maxCacheSize = 50;

  /// 高亮熔断阈值 —— 对齐 discourse 网页端 highlight-syntax.js:
  /// 超大代码块任何语言都不高亮("Large code blocks can cause crashes or
  /// slowdowns");lang-auto 需跑多语言探测,成本更高,阈值狠得多。
  static const maxHighlightLength = 30000;
  static const maxAutoHighlightLength = 1000;

  /// 是否跳过高亮(网页端同款两道熔断)。
  ///
  /// [language] 传 cooked 提取的原始语言标识('auto' / null / 'json' ...),
  /// 显式语言只受 [maxHighlightLength] 约束;auto/无语言另受
  /// [maxAutoHighlightLength] 约束。命中时调用方应保持纯 monospace 显示,
  /// 与网页端行为一致。
  bool shouldSkipHighlight(String code, String? language) {
    if (code.length > maxHighlightLength) return true;
    final isAuto = language == null || language.isEmpty || language == 'auto';
    return isAuto && code.length > maxAutoHighlightLength;
  }

  // 并发限制器：避免大量代码块同时创建 ReceivePort 等待结果
  int _activeRequests = 0;
  static const _maxConcurrentRequests = 3;
  final _pendingQueue = <Completer<void>>[];

  // 预加载的字体 TextStyle
  TextStyle? _firaCodeStyle;

  HighlighterService._();

  static HighlighterService get instance {
    _instance ??= HighlighterService._();
    return _instance!;
  }

  /// 初始化服务（预加载字体和 Isolate Worker）
  Future<void> initialize() async {
    // 预加载 FiraCode 字体
    _firaCodeStyle = GoogleFonts.firaCode(fontSize: 13, height: 1.5);
    // 预热 Isolate Worker
    await _HighlightWorker.instance.ensureInitialized();
  }

  /// 获取预加载的字体样式
  TextStyle get firaCodeStyle => _firaCodeStyle ?? GoogleFonts.firaCode(fontSize: 13, height: 1.5);

  String _cacheKey(String code, String? language) => '${language ?? 'auto'}:${code.hashCode}';

  void _addToCache(String key, List<HighlightToken> tokens) {
    if (_cache.length >= _maxCacheSize) {
      // 移除最早的条目
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = tokens;
  }

  /// 异步获取高亮 tokens（带并发限制）
  Future<List<HighlightToken>> highlightAsync(String code, {String? language}) async {
    // 网页端同款熔断:超大块 / lang-auto 大块直接纯文本,不进 isolate
    if (shouldSkipHighlight(code, language)) {
      return [HighlightToken.text(code)];
    }

    final key = _cacheKey(code, language);
    if (_cache.containsKey(key)) {
      // 移到末尾（LRU）
      final tokens = _cache.remove(key)!;
      _cache[key] = tokens;
      return tokens;
    }

    // 并发限制：超过上限时排队等待
    if (_activeRequests >= _maxConcurrentRequests) {
      final completer = Completer<void>();
      _pendingQueue.add(completer);
      await completer.future;
    }
    _activeRequests++;

    try {
      final normalizedLang = _normalizeLanguage(language, code);
      final tokenMaps = await _HighlightWorker.instance.highlight(code, normalizedLang, _commonLanguages);
      final tokens = tokenMaps.map((m) => HighlightToken.fromMap(m)).toList();

      _addToCache(key, tokens);
      return tokens;
    } finally {
      _activeRequests--;
      if (_pendingQueue.isNotEmpty) {
        _pendingQueue.removeAt(0).complete();
      }
    }
  }

  /// 将 tokens 转换为 TextSpan
  ///
  /// 扁平化输出:按 scope 栈折叠出每个 text token 的等效样式(与原嵌套
  /// wrapper 的 TextStyle 继承链等价),相邻同样式 token 合并为单个 span。
  /// 大代码块 token 数以千计,嵌套树 + 逐 token span 是主线程排版大头,
  /// 合并后 span 数下降一个量级。
  TextSpan tokensToSpan(List<HighlightToken> tokens, {
    bool isDark = false,
    TextStyle? baseStyle,
  }) {
    final theme = isDark ? githubDarkTheme : githubTheme;
    final base = baseStyle ?? firaCodeStyle;

    final spans = <InlineSpan>[];
    final scopeStack = <String>[];
    // scope 栈签名 → 折叠样式缓存(数千 token 通常只在少数几种签名间切换)
    final styleCache = <String, TextStyle?>{};
    final buffer = StringBuffer();
    TextStyle? currentStyle;
    String? currentSig;

    void flush() {
      if (buffer.isEmpty) return;
      spans.add(TextSpan(text: buffer.toString(), style: currentStyle));
      buffer.clear();
    }

    TextStyle? resolveStyle() {
      TextStyle? style;
      for (final scope in scopeStack) {
        final scopeStyle = theme[scope];
        if (scopeStyle != null) {
          style = style == null ? scopeStyle : style.merge(scopeStyle);
        }
      }
      return style;
    }

    for (final token in tokens) {
      switch (token.type) {
        case 'text':
          final sig = scopeStack.join(' ');
          if (sig != currentSig) {
            flush();
            currentSig = sig;
            currentStyle = styleCache.putIfAbsent(sig, resolveStyle);
          }
          buffer.write(token.content);
          break;
        case 'open':
          scopeStack.add(token.scope!);
          break;
        case 'close':
          if (scopeStack.isNotEmpty) scopeStack.removeLast();
          break;
      }
    }
    flush();

    return TextSpan(style: base, children: spans.isEmpty ? [const TextSpan(text: '')] : spans);
  }

  /// 构建高亮代码块 Widget
  Widget buildHighlightView(
    String code, {
    String? language,
    bool isDark = false,
    Color? backgroundColor,
    EdgeInsets padding = const EdgeInsets.all(12),
    TextStyle? textStyle,
    bool showLineNumbers = false,
  }) {
    return HighlightCodeBlock(
      code: code,
      language: language,
      isDark: isDark,
      backgroundColor: backgroundColor,
      padding: padding,
      textStyle: textStyle,
      showLineNumbers: showLineNumbers,
    );
  }

  String? _normalizeLanguage(String? lang, [String? code]) {
    if (lang == null || lang.isEmpty || lang == 'auto') {
      if (code != null && code.isNotEmpty) {
        return _detectLanguage(code);
      }
      return null;
    }
    final normalized = lang.toLowerCase();
    return switch (normalized) {
      'js' => 'javascript',
      'ts' => 'typescript',
      'py' => 'python',
      'rb' => 'ruby',
      'yml' => 'yaml',
      'sh' => 'bash',
      'objc' || 'obj-c' => 'objectivec',
      _ => normalized,
    };
  }

  String? _detectLanguage(String code) {
    final trimmed = code.trim();
    if ((trimmed.startsWith('{') && trimmed.endsWith('}')) ||
        (trimmed.startsWith('[') && trimmed.endsWith(']'))) {
      if (trimmed.contains(':') && trimmed.contains('"')) return 'json';
    }
    if (trimmed.startsWith('<') && trimmed.contains('>')) {
      if (trimmed.contains('<html')) return 'html';
      if (trimmed.startsWith('<?xml')) return 'xml';
    }
    if (trimmed.startsWith('#!') && trimmed.contains('bash')) return 'bash';
    if (RegExp(r'^(sudo|apt|npm|yarn|pip|git|docker)\s').hasMatch(trimmed)) return 'bash';
    if (RegExp(r'^(def |class |import |from \w+ import )').hasMatch(trimmed)) return 'python';
    if (RegExp(r'^(function |const |let |var |export )').hasMatch(trimmed)) return 'javascript';
    if (trimmed.contains("import 'package:")) return 'dart';
    if (RegExp(r'^\w+:\s*(\n|$)').hasMatch(trimmed) && !trimmed.contains('{')) return 'yaml';
    if (RegExp(r'^(SELECT|INSERT|UPDATE|CREATE)\s', caseSensitive: false).hasMatch(trimmed)) return 'sql';
    return null;
  }
}

/// 异步高亮代码块组件
class HighlightCodeBlock extends StatefulWidget {
  final String code;
  final String? language;
  final bool isDark;
  final Color? backgroundColor;
  final EdgeInsets padding;
  final TextStyle? textStyle;
  final bool showLineNumbers;

  const HighlightCodeBlock({
    super.key,
    required this.code,
    this.language,
    this.isDark = false,
    this.backgroundColor,
    this.padding = const EdgeInsets.all(12),
    this.textStyle,
    this.showLineNumbers = false,
  });

  @override
  State<HighlightCodeBlock> createState() => _HighlightCodeBlockState();
}

class _HighlightCodeBlockState extends State<HighlightCodeBlock> {
  List<HighlightToken>? _tokens;

  @override
  void initState() {
    super.initState();
    _loadHighlight();
  }

  @override
  void didUpdateWidget(HighlightCodeBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.code != widget.code || oldWidget.language != widget.language) {
      _loadHighlight();
    }
  }

  Future<void> _loadHighlight() async {
    try {
      final tokens = await HighlighterService.instance.highlightAsync(
        widget.code,
        language: widget.language,
      );
      if (mounted) setState(() => _tokens = tokens);
    } catch (e) {
      // 高亮失败，保持显示纯文本
    }
  }

  @override
  Widget build(BuildContext context) {
    final baseStyle = widget.textStyle ?? HighlighterService.instance.firaCodeStyle;

    final textSpan = _tokens != null
        ? HighlighterService.instance.tokensToSpan(
            _tokens!,
            isDark: widget.isDark,
            baseStyle: baseStyle,
          )
        : TextSpan(text: widget.code, style: baseStyle);

    return Container(
      color: widget.backgroundColor,
      padding: widget.padding,
      child: SelectableText.rich(textSpan),
    );
  }
}
