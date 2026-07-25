import 'dart:convert';

/// Parsed NewAPI-style provider credentials from free text / HTML.
class CcswitchCredentials {
  final String? baseUrl;
  final String? apiKey;
  final String? name;

  const CcswitchCredentials({
    this.baseUrl,
    this.apiKey,
    this.name,
  });

  bool get isComplete =>
      (baseUrl?.isNotEmpty ?? false) && (apiKey?.isNotEmpty ?? false);

  bool get hasAny =>
      (baseUrl?.isNotEmpty ?? false) ||
      (apiKey?.isNotEmpty ?? false) ||
      (name?.isNotEmpty ?? false);

  CcswitchCredentials copyWith({
    String? baseUrl,
    String? apiKey,
    String? name,
  }) {
    return CcswitchCredentials(
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      name: name ?? this.name,
    );
  }

  CcswitchCredentials merge(CcswitchCredentials other) {
    return CcswitchCredentials(
      baseUrl: other.baseUrl?.isNotEmpty == true ? other.baseUrl : baseUrl,
      apiKey: other.apiKey?.isNotEmpty == true ? other.apiKey : apiKey,
      name: other.name?.isNotEmpty == true ? other.name : name,
    );
  }

  @override
  String toString() =>
      'CcswitchCredentials(baseUrl: $baseUrl, apiKey: ${maskApiKey(apiKey)}, name: $name)';
}

/// Import target app for CC Switch deeplink.
enum CcswitchImportApp {
  claude,
  codex,
  gemini,
  all;

  static const List<CcswitchImportApp> storageValues = [
    claude,
    codex,
    gemini,
    all,
  ];

  static CcswitchImportApp fromString(String? value) {
    final mode = (value ?? '').trim().toLowerCase();
    return CcswitchImportApp.values.firstWhere(
      (e) => e.name == mode,
      orElse: () => CcswitchImportApp.codex,
    );
  }

  /// Concrete apps to open for this mode.
  List<CcswitchImportApp> get resolvedApps {
    if (this == CcswitchImportApp.all) {
      return const [
        CcswitchImportApp.claude,
        CcswitchImportApp.codex,
        CcswitchImportApp.gemini,
      ];
    }
    return [this];
  }
}

const Map<String, Map<String, String>> kCcswitchDefaultModels = {
  'claude': {
    'model': 'claude-sonnet-5',
    'haikuModel': 'claude-haiku-4-5-20251001',
    'sonnetModel': 'claude-sonnet-5',
    'opusModel': 'claude-opus-4-8',
  },
  'codex': {'model': 'gpt-5.5'},
  'gemini': {'model': 'gemini-3.5-flash'},
};

final RegExp _schemeUrlRe = RegExp(r'''https?://[^\s"'`<>]+''', caseSensitive: false);
final RegExp _bareHostRe = RegExp(
  r'''\b(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}(?::\d{1,5})?(?:/[^\s"'`<>]*)?(?![A-Za-z-])''',
);
final RegExp _skKeyRe = RegExp(r'\b(sk-[A-Za-z0-9._\-]{8,})\b');
final RegExp _bearerKeyRe =
    RegExp(r'\bBearer\s+([A-Za-z0-9._\-+=/]{16,})\b', caseSensitive: false);
final RegExp _skBase64Re = RegExp(r'c2st[A-Za-z0-9+/_-]+={0,2}');
final RegExp _base64TokenRe = RegExp(r'[A-Za-z0-9+/_-]{20,}={0,2}');
final RegExp _labeledKeyRe = RegExp(
  r'''(?:api[_\s-]?key|apikey|\bkey\b|token|auth[_\s-]?token|secret|access[_\s-]?token|密钥|金鑰|金钥|令牌)\s*[:=：]\s*["']?([^\s"'`,;]+)["']?''',
  caseSensitive: false,
);
final RegExp _labeledUrlRe = RegExp(
  r'''(?:base[_\s-]?url|api[_\s-]?url|\bapi\b|endpoint|host|\burl\b|地址|接口|域名)\s*[:=：]\s*["']?((?:https?://)?[^\s"'`,;]+)["']?''',
  caseSensitive: false,
);
final RegExp _labeledNameRe = RegExp(
  r'''(?:name|provider|title|名称|名稱)\s*[:=：]\s*["']?([^\n\r"'`,;]+)["']?''',
  caseSensitive: false,
);
final RegExp _queryKeyRe = RegExp(
  r'''[?&](?:api[_-]?key|apikey|key|token|access[_-]?token)=([^&\s"'`]+)''',
  caseSensitive: false,
);
final RegExp _markdownLinkRe =
    RegExp(r'\[([^\]]+)\]\((https?://[^)\s]+)\)', caseSensitive: false);
final RegExp _plainKeyRe = RegExp(r'\b([A-Za-z][A-Za-z0-9._-]{15,127})\b');
final RegExp _controlCharsRe = RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F]');

String cleanToken(String? value) {
  return (value ?? '')
      .trim()
      .replaceAll(RegExp(r'''^["'`]+|["'`,;]+$'''), '');
}

String stripMarkdownWrapper(String value) {
  final trimmed = cleanToken(value);
  final md = RegExp(r'^\[([^\]]*)\]\((https?://[^)\s]+)\)$', caseSensitive: false)
      .firstMatch(trimmed);
  if (md != null && (md.group(2)?.isNotEmpty ?? false)) {
    return cleanToken(md.group(2)!);
  }
  final bare =
      RegExp(r'^\[(https?://[^\]]+)\]$', caseSensitive: false).firstMatch(trimmed);
  if (bare != null && (bare.group(1)?.isNotEmpty ?? false)) {
    return cleanToken(bare.group(1)!);
  }
  return trimmed;
}

bool looksLikeUrl(String value) {
  final v = stripMarkdownWrapper(value);
  if (RegExp(r'^https?://', caseSensitive: false).hasMatch(v)) return true;
  return RegExp(
    r'^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}(?::\d{1,5})?(?:/\S*)?$',
  ).hasMatch(v);
}

bool looksLikeSkKey(String? value) {
  return RegExp(r'^sk-[A-Za-z0-9._\-]{8,}$', caseSensitive: false)
      .hasMatch((value ?? '').trim());
}

bool looksLikeSecretToken(String value) {
  final v = cleanToken(value);
  if (v.length < 16 || v.length > 256) return false;
  if (looksLikeUrl(v) || looksLikeSkKey(v)) return false;
  if (RegExp(r'\s').hasMatch(v)) return false;
  if (!RegExp(r'^[A-Za-z0-9._\-+=/+]+$').hasMatch(v)) return false;
  final hasLetter = RegExp(r'[A-Za-z]').hasMatch(v);
  final hasDigit = RegExp(r'\d').hasMatch(v);
  if (!hasLetter) return false;
  if (!(hasDigit ||
      RegExp(r'[_\-+/=]').hasMatch(v) ||
      (RegExp(r'[A-Z]').hasMatch(v) && RegExp(r'[a-z]').hasMatch(v)))) {
    return false;
  }
  if (RegExp(
    r'^(https?|baseurl|apikey|endpoint|gateway|proxy|relay|key|token|api)$',
    caseSensitive: false,
  ).hasMatch(v)) {
    return false;
  }
  return true;
}

bool looksLikeBase64Blob(String value) {
  final cleaned = value.trim().replaceAll(RegExp(r'\s+'), '');
  if (cleaned.length < 16) return false;
  if (!RegExp(r'^[A-Za-z0-9+/_-]+={0,2}$').hasMatch(cleaned)) return false;
  if (looksLikeSkKey(cleaned) || looksLikeUrl(cleaned)) return false;
  if (cleaned.startsWith('c2st')) return true;
  if (cleaned.length % 4 != 0) return false;
  return true;
}

String? decodeBase64Utf8(String input) {
  final cleaned = input.replaceAll(RegExp(r'\s+'), '');
  try {
    final normalized = base64.normalize(cleaned.replaceAll('-', '+').replaceAll('_', '/'));
    return utf8.decode(base64.decode(normalized), allowMalformed: true);
  } catch (_) {
    try {
      return utf8.decode(base64.decode(cleaned), allowMalformed: true);
    } catch (_) {
      return null;
    }
  }
}

String? tryDecodeBase64Candidate(String value) {
  final cleaned = value.trim().replaceAll(RegExp(r'\s+'), '');
  if (!looksLikeBase64Blob(cleaned)) return null;
  try {
    final decoded = decodeBase64Utf8(cleaned);
    if (decoded == null || decoded.isEmpty) return null;
    if (decoded == value || decoded == cleaned) return null;
    if (_controlCharsRe.hasMatch(decoded)) return null;
    return decoded;
  } catch (_) {
    return null;
  }
}

List<String> collectSkKeys(String text) {
  final keys = <String>[];
  for (final match in _skKeyRe.allMatches(text)) {
    final g = match.group(1);
    if (g != null) keys.add(cleanToken(g));
  }
  return keys;
}

bool looksLikePlainApiKey(String value) {
  final v = cleanToken(value);
  if (v.length < 16 || v.length > 128) return false;
  if (looksLikeUrl(v) || looksLikeSkKey(v)) return false;
  if (RegExp(r'\s').hasMatch(v)) return false;
  if (!RegExp(r'^[A-Za-z][A-Za-z0-9._-]*$').hasMatch(v)) return false;
  final hasLetter = RegExp(r'[A-Za-z]').hasMatch(v);
  final hasDigit = RegExp(r'\d').hasMatch(v);
  final hasHyphen = v.contains('-') || v.contains('_');
  if (!hasLetter) return false;
  if (!(hasDigit || hasHyphen)) return false;
  if (RegExp(
    r'^(https?|baseurl|apikey|endpoint|gateway|proxy|relay)$',
    caseSensitive: false,
  ).hasMatch(v)) {
    return false;
  }
  if (v.startsWith('c2st')) return false;
  if (looksLikeBase64Blob(v)) {
    final decoded = tryDecodeBase64Candidate(v);
    if (decoded != null &&
        (looksLikeSkKey(decoded) || collectSkKeys(decoded).isNotEmpty)) {
      return false;
    }
    if (RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(v) &&
        v.length % 4 == 0 &&
        !hasHyphen) {
      return false;
    }
  }
  return true;
}

String decodeSecretLayers(String value) {
  var current = cleanToken(value);
  for (var i = 0; i < 2; i++) {
    if (looksLikeSkKey(current)) return current;
    final decoded = tryDecodeBase64Candidate(current);
    if (decoded == null) break;
    final next = cleanToken(decoded);
    if (looksLikeSkKey(next)) return next;
    if (looksLikeSecretToken(next) || looksLikePlainApiKey(next)) {
      final nested = tryDecodeBase64Candidate(next);
      if (nested != null &&
          (looksLikeSkKey(nested) ||
              looksLikeSecretToken(nested) ||
              looksLikePlainApiKey(nested))) {
        current = next;
        continue;
      }
      return next;
    }
    final sk = collectSkKeys(next);
    if (sk.isNotEmpty) return sk.first;
    current = next;
  }
  return current;
}

String ensureHttps(String url) {
  final trimmed = stripMarkdownWrapper(url);
  if (RegExp(r'^https?://', caseSensitive: false).hasMatch(trimmed)) {
    return trimmed;
  }
  if (looksLikeUrl(trimmed)) return 'https://$trimmed';
  return trimmed;
}

String normalizeBaseUrl(String raw) {
  var url = ensureHttps(raw).replaceAll(RegExp(r'[),.;]+$'), '');
  try {
    final parsed = Uri.parse(url);
    final cleanedQuery = Map<String, String>.from(parsed.queryParameters)
      ..removeWhere(
        (key, _) => const {
          'api_key',
          'apiKey',
          'apikey',
          'key',
          'token',
          'access_token',
          'accessToken',
        }.contains(key),
      );
    var href = parsed
        .replace(queryParameters: cleanedQuery.isEmpty ? null : cleanedQuery, fragment: '')
        .toString();
    // Uri.toString may leave trailing ?/# when query/fragment empty; normalize.
    if (href.endsWith('?')) href = href.substring(0, href.length - 1);
    // Dart Uri keeps a bare trailing '#' after clearing fragment.
    if (href.endsWith('#')) href = href.substring(0, href.length - 1);
    href = href.replaceAll(RegExp(r'#+$'), '');
    href = href.replaceAll(RegExp(r'\?$'), '');
    if (href.endsWith('/') && (parsed.path.isEmpty || parsed.path == '/')) {
      href = href.substring(0, href.length - 1);
    } else if (href.endsWith('/') && parsed.path.length > 1) {
      href = href.replaceAll(RegExp(r'/+$'), '');
    }
    return href;
  } catch (_) {
    return url.replaceAll(RegExp(r'/+$'), '');
  }
}

String? firstMatch(RegExp re, String text) {
  final match = re.firstMatch(text);
  final g = match?.group(1);
  return g != null ? cleanToken(g) : null;
}

List<String> collectUrls(String text) {
  final urls = <String>[];
  final seen = <String>{};
  for (final match in _schemeUrlRe.allMatches(text)) {
    final value = cleanToken(match.group(0)!).replaceAll(RegExp(r'[),.;]+$'), '');
    if (looksLikeUrl(value) && seen.add(value)) urls.add(value);
  }
  for (final match in _bareHostRe.allMatches(text)) {
    final value = cleanToken(match.group(0)!).replaceAll(RegExp(r'[),.;]+$'), '');
    if (!looksLikeUrl(value)) continue;
    if (looksLikeBase64Blob(value) || looksLikeSkKey(value)) continue;
    if (!seen.contains(value) && !urls.any((u) => u.contains(value))) {
      seen.add(value);
      urls.add(value);
    }
  }
  return urls;
}

void _pushUnique(List<String> items, Set<String> seen, String value) {
  final cleaned = cleanToken(value);
  if (cleaned.isEmpty || !seen.add(cleaned)) return;
  items.add(cleaned);
}

List<String> collectPlainKeys(String text) {
  final keys = <String>[];
  final seen = <String>{};
  for (final match in _plainKeyRe.allMatches(text)) {
    final token = match.group(1) != null ? cleanToken(match.group(1)!) : '';
    if (token.isEmpty || !looksLikePlainApiKey(token) || looksLikeUrl(token)) {
      continue;
    }
    _pushUnique(keys, seen, token);
  }
  return keys;
}

class _MarkdownLink {
  final String name;
  final String url;
  const _MarkdownLink(this.name, this.url);
}

List<_MarkdownLink> extractMarkdownLinks(String text) {
  final links = <_MarkdownLink>[];
  for (final match in _markdownLinkRe.allMatches(text)) {
    final name = match.group(1) != null ? cleanToken(match.group(1)!) : '';
    final url = match.group(2) != null
        ? cleanToken(match.group(2)!).replaceAll(RegExp(r'[),.;]+$'), '')
        : '';
    if (url.isEmpty || !looksLikeUrl(url)) continue;
    links.add(
      _MarkdownLink(name.isNotEmpty && !looksLikeUrl(name) ? name : '', url),
    );
  }
  return links;
}

List<String> collectDecodedBase64Keys(String text) {
  final keys = <String>[];
  final seen = <String>{};
  final candidates = <String>[];
  for (final match in _skBase64Re.allMatches(text)) {
    candidates.add(cleanToken(match.group(0)!));
  }
  for (final match in _base64TokenRe.allMatches(text)) {
    final token = cleanToken(match.group(0)!);
    candidates.add(token);
    final c2stIdx = token.indexOf('c2st');
    if (c2stIdx > 0) candidates.add(token.substring(c2stIdx));
  }
  for (final candidate in candidates) {
    final decoded = decodeSecretLayers(candidate);
    if (looksLikeSkKey(decoded)) {
      _pushUnique(keys, seen, decoded);
      continue;
    }
    for (final sk in collectSkKeys(decoded)) {
      _pushUnique(keys, seen, sk);
    }
    if (decoded != candidate &&
        (looksLikeSecretToken(decoded) || looksLikePlainApiKey(decoded))) {
      _pushUnique(keys, seen, decoded);
    }
  }
  return keys;
}

String? _pickFrom(Map source, List<String> keys) {
  for (final key in keys) {
    final value = source[key];
    if (value is String && value.trim().isNotEmpty) return cleanToken(value);
  }
  final lowerEntries = <String, dynamic>{};
  source.forEach((k, v) {
    if (k is String) lowerEntries[k.toLowerCase()] = v;
  });
  for (final key in keys) {
    final value = lowerEntries[key.toLowerCase()];
    if (value is String && value.trim().isNotEmpty) return cleanToken(value);
  }
  return null;
}

CcswitchCredentials? extractFromRecord(Map record) {
  final nestedSources = <Map>[record];
  for (final nestedKey in const ['config', 'env', 'data', 'provider', 'settings']) {
    final nested = record[nestedKey];
    if (nested is Map && nested is! List) nestedSources.add(nested);
  }
  String? baseUrl;
  String? apiKey;
  String? name;
  for (final source in nestedSources) {
    baseUrl ??= _pickFrom(source, const [
      'baseUrl',
      'base_url',
      'apiUrl',
      'api_url',
      'endpoint',
      'url',
      'host',
      'ANTHROPIC_BASE_URL',
      'OPENAI_BASE_URL',
      'GOOGLE_GEMINI_BASE_URL',
      'GEMINI_BASE_URL',
    ]);
    apiKey ??= _pickFrom(source, const [
      'apiKey',
      'api_key',
      'token',
      'authToken',
      'auth_token',
      'accessToken',
      'access_token',
      'secret',
      'key',
      'ANTHROPIC_AUTH_TOKEN',
      'ANTHROPIC_API_KEY',
      'OPENAI_API_KEY',
      'GEMINI_API_KEY',
    ]);
    name ??= _pickFrom(source, const [
      'name',
      'title',
      'provider',
      'providerName',
      'provider_name',
    ]);
  }
  if (baseUrl == null && apiKey == null && name == null) return null;
  return CcswitchCredentials(
    baseUrl: baseUrl != null ? normalizeBaseUrl(baseUrl) : null,
    apiKey: apiKey,
    name: name,
  );
}

CcswitchCredentials? tryParseJson(String text) {
  final trimmed = text.trim();
  if (!(trimmed.startsWith('{') || trimmed.startsWith('['))) return null;
  try {
    final parsed = jsonDecode(trimmed);
    if (parsed is List) {
      for (final item in parsed) {
        if (item is Map) {
          final extracted = extractFromRecord(item);
          if (extracted != null &&
              ((extracted.baseUrl?.isNotEmpty ?? false) ||
                  (extracted.apiKey?.isNotEmpty ?? false))) {
            return extracted;
          }
        }
      }
      return null;
    }
    if (parsed is Map) return extractFromRecord(parsed);
  } catch (_) {
    return null;
  }
  return null;
}

String? extractQueryKey(String url) {
  try {
    final parsed = Uri.parse(ensureHttps(url));
    for (final key in const [
      'api_key',
      'apiKey',
      'apikey',
      'key',
      'token',
      'access_token',
      'accessToken',
    ]) {
      final value = parsed.queryParameters[key];
      if (value != null && value.isNotEmpty) return cleanToken(value);
    }
  } catch (_) {}
  final match = _queryKeyRe.firstMatch(url);
  if (match?.group(1) != null) {
    try {
      return cleanToken(Uri.decodeComponent(match!.group(1)!));
    } catch (_) {
      return cleanToken(match!.group(1)!);
    }
  }
  return null;
}

String decodeApiKeyIfNeeded(String apiKey) {
  final trimmed = cleanToken(apiKey);
  if (looksLikeSkKey(trimmed)) return trimmed;
  final decoded = decodeSecretLayers(trimmed);
  if (decoded != trimmed) return decoded;
  final oneShot = tryDecodeBase64Candidate(trimmed);
  if (oneShot != null) {
    if (looksLikeSkKey(oneShot)) return cleanToken(oneShot);
    final nested = parseNewApiClipboard(oneShot);
    if (nested?.apiKey != null) return nested!.apiKey!;
    final sk = collectSkKeys(oneShot);
    if (sk.isNotEmpty) return sk.first;
    if (looksLikeSecretToken(oneShot) || looksLikePlainApiKey(oneShot)) {
      return cleanToken(oneShot);
    }
  }
  return trimmed;
}

String? guessNameFromFreeText(String text) {
  var cleaned = text
      .replaceAllMapped(_markdownLinkRe, (m) => ' ${m.group(1)} ')
      .replaceAll(_skBase64Re, ' ')
      .replaceAll(_base64TokenRe, ' ')
      .replaceAll(_schemeUrlRe, ' ')
      .replaceAll(_skKeyRe, ' ');
  cleaned = cleaned.replaceAll(
    RegExp(
      r'(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}\d*',
    ),
    ' ',
  );
  cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
  final match = RegExp(
    r'\b([A-Z][A-Za-z0-9._+]{0,40}API)\s*[-–—]\s*([A-Za-z][A-Za-z0-9 ._+]{0,60}?(?:API Gateway|Gateway|Proxy|Relay))\b',
  ).firstMatch(cleaned);
  if (match == null) return null;
  final name = ('${match.group(1)} - ${match.group(2)}')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (name.length < 3 || name.length > 64) return null;
  return name;
}

CcswitchCredentials parseOnce(String text) {
  String? baseUrl;
  String? apiKey;
  String? name;

  final jsonPart = tryParseJson(text);
  if (jsonPart != null) {
    baseUrl = jsonPart.baseUrl;
    apiKey = jsonPart.apiKey;
    name = jsonPart.name;
  }

  final mdLinks = extractMarkdownLinks(text);
  if (mdLinks.isNotEmpty) {
    baseUrl ??= normalizeBaseUrl(mdLinks.first.url);
    if (mdLinks.first.name.isNotEmpty) name ??= mdLinks.first.name;
  }

  final labeledUrl = firstMatch(_labeledUrlRe, text);
  if (labeledUrl != null) {
    final unwrapped = stripMarkdownWrapper(labeledUrl);
    if (looksLikeUrl(unwrapped)) baseUrl ??= normalizeBaseUrl(unwrapped);
  }

  final labeledKey = firstMatch(_labeledKeyRe, text);
  if (labeledKey != null) apiKey ??= stripMarkdownWrapper(labeledKey);

  final labeledName = firstMatch(_labeledNameRe, text);
  if (labeledName != null) name ??= labeledName;

  final urls = collectUrls(text);
  if (baseUrl == null && urls.isNotEmpty) {
    baseUrl = normalizeBaseUrl(urls.first);
  }

  if (apiKey == null) {
    for (final u in urls) {
      final queryKey = extractQueryKey(u);
      if (queryKey != null) {
        apiKey = queryKey;
        break;
      }
    }
  }
  if (apiKey == null) {
    final bearer = firstMatch(_bearerKeyRe, text);
    if (bearer != null) apiKey = bearer;
  }
  if (apiKey == null) {
    final sk = collectSkKeys(text);
    if (sk.isNotEmpty) apiKey = sk.first;
  }
  if (apiKey == null) {
    final decodedKey = collectDecodedBase64Keys(text);
    if (decodedKey.isNotEmpty) apiKey = decodedKey.first;
  }
  if (apiKey == null) {
    final plainKey = collectPlainKeys(text);
    if (plainKey.isNotEmpty) apiKey = plainKey.first;
  }

  if (baseUrl == null || apiKey == null) {
    final lines = text
        .split(RegExp(r'\r?\n'))
        .map(cleanToken)
        .where((line) => line.isNotEmpty);
    for (final line in lines) {
      final md = extractMarkdownLinks(line);
      if (md.isNotEmpty) {
        baseUrl ??= normalizeBaseUrl(md.first.url);
        if (name == null && md.first.name.isNotEmpty) name = md.first.name;
        continue;
      }
      final lineUrlLabeled = firstMatch(_labeledUrlRe, line);
      if (baseUrl == null && lineUrlLabeled != null) {
        final unwrapped = stripMarkdownWrapper(lineUrlLabeled);
        if (looksLikeUrl(unwrapped)) {
          baseUrl = normalizeBaseUrl(unwrapped);
          continue;
        }
      }
      final lineKeyLabeled = firstMatch(_labeledKeyRe, line);
      if (apiKey == null && lineKeyLabeled != null) {
        apiKey = stripMarkdownWrapper(lineKeyLabeled);
        continue;
      }
      if (baseUrl == null && looksLikeUrl(line)) {
        baseUrl = normalizeBaseUrl(line);
        continue;
      }
      if (apiKey == null && looksLikeSkKey(line)) {
        apiKey = line;
        continue;
      }
      if (apiKey == null) {
        final decodedKeys = collectDecodedBase64Keys(line);
        if (decodedKeys.isNotEmpty) {
          apiKey = decodedKeys.first;
          continue;
        }
      }
      if (apiKey == null &&
          looksLikeBase64Blob(line) &&
          !looksLikeUrl(line) &&
          line.length >= 16) {
        apiKey = line;
        continue;
      }
      if (apiKey == null && looksLikePlainApiKey(line)) {
        apiKey = line;
      }
    }
  }

  name ??= guessNameFromFreeText(text);
  return CcswitchCredentials(baseUrl: baseUrl, apiKey: apiKey, name: name);
}

/// Partial parse: returns credentials if either baseUrl or apiKey is found.
CcswitchCredentials? parseNewApiClipboardPartial(String? rawText) {
  if (rawText == null || rawText.trim().isEmpty) return null;
  final candidates = <String>[rawText.trim()];
  final wholeDecoded = tryDecodeBase64Candidate(rawText);
  if (wholeDecoded != null && wholeDecoded != rawText.trim()) {
    candidates.add(wholeDecoded);
  }
  String? baseUrl;
  String? apiKey;
  String? name;
  for (final candidate in candidates) {
    final parsed = parseOnce(candidate);
    baseUrl ??= parsed.baseUrl;
    apiKey ??= parsed.apiKey;
    name ??= parsed.name;
    if (baseUrl != null && apiKey != null) break;
  }
  if (baseUrl == null && apiKey == null) return null;
  return CcswitchCredentials(
    baseUrl: baseUrl != null ? normalizeBaseUrl(baseUrl) : null,
    apiKey: apiKey != null ? decodeApiKeyIfNeeded(apiKey) : null,
    name: name?.trim().isNotEmpty == true ? name!.trim() : null,
  );
}

/// Full parse: requires both baseUrl and apiKey.
CcswitchCredentials? parseNewApiClipboard(String? rawText) {
  final partial = parseNewApiClipboardPartial(rawText);
  if (partial == null || !partial.isComplete) return null;
  return CcswitchCredentials(
    baseUrl: partial.baseUrl,
    apiKey: partial.apiKey,
    name: partial.name,
  );
}

/// Convert Discourse cooked HTML to plain text for credential scanning.
String cookedHtmlToCredentialText(String html) {
  var text = html
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<p[^>]*>', caseSensitive: false), '\n')
      .replaceAll('</p>', '\n')
      .replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '- ')
      .replaceAll('</li>', '\n')
      .replaceAll(RegExp(r'<code[^>]*>', caseSensitive: false), '')
      .replaceAll('</code>', '')
      .replaceAll(RegExp(r'<pre[^>]*>', caseSensitive: false), '\n')
      .replaceAll('</pre>', '\n')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
  text = text.replaceAll(RegExp(r'<[^>]+>'), '');
  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return text.trim();
}

CcswitchCredentials? detectCredentialsFromCooked(String? cookedHtml) {
  if (cookedHtml == null || cookedHtml.trim().isEmpty) return null;
  return parseNewApiClipboardPartial(cookedHtmlToCredentialText(cookedHtml));
}

String maskApiKey(String? key) {
  if (key == null || key.isEmpty) return '';
  if (key.length <= 12) return key;
  return '${key.substring(0, 6)}…${key.substring(key.length - 4)}';
}

String defaultProviderName(
  CcswitchCredentials credentials, {
  DateTime? now,
}) {
  final t = now ?? DateTime.now();
  final stamp =
      '${t.month}月${t.day}日 ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  if (credentials.name != null && credentials.name!.trim().isNotEmpty) {
    return '$stamp ${credentials.name!.trim()}';
  }
  return '$stamp ${credentials.baseUrl ?? ''}';
}

String utf8ToBase64(String text) {
  return base64Encode(utf8.encode(text));
}

Map<String, dynamic>? buildProviderConfig(
  CcswitchImportApp app,
  CcswitchCredentials credentials, {
  String? name,
}) {
  final models = kCcswitchDefaultModels[app.name] ?? const <String, String>{};
  final endpoint = credentials.baseUrl;
  final apiKey = credentials.apiKey;
  if (endpoint == null || apiKey == null) return null;

  switch (app) {
    case CcswitchImportApp.claude:
      return {
        'env': {
          'ANTHROPIC_AUTH_TOKEN': apiKey,
          'ANTHROPIC_BASE_URL': endpoint,
          'ANTHROPIC_MODEL': models['model'],
          'ANTHROPIC_DEFAULT_HAIKU_MODEL': models['haikuModel'],
          'ANTHROPIC_DEFAULT_SONNET_MODEL': models['sonnetModel'],
          'ANTHROPIC_DEFAULT_OPUS_MODEL': models['opusModel'],
        },
      };
    case CcswitchImportApp.codex:
      final providerName =
          jsonEncode(name ?? defaultProviderName(credentials));
      final model = jsonEncode(models['model'] ?? 'gpt-5.5');
      final baseUrl =
          jsonEncode((endpoint).replaceAll(RegExp(r'/+$'), ''));
      final configToml = 'model_provider = "custom"\n'
          'model = $model\n'
          'model_reasoning_effort = "high"\n'
          'disable_response_storage = true\n\n'
          '[model_providers.custom]\n'
          'name = $providerName\n'
          'base_url = $baseUrl\n'
          'wire_api = "responses"\n'
          'requires_openai_auth = true\n';
      return {
        'auth': {'OPENAI_API_KEY': apiKey},
        'config': configToml,
      };
    case CcswitchImportApp.gemini:
      return {
        'GEMINI_API_KEY': apiKey,
        'GOOGLE_GEMINI_BASE_URL': endpoint,
        'GEMINI_MODEL': models['model'],
      };
    case CcswitchImportApp.all:
      return null;
  }
}

/// Build official `ccswitch://v1/import` deeplink for a single app.
String buildCcswitchDeeplink(
  CcswitchImportApp app,
  CcswitchCredentials credentials, {
  String? name,
  String? notes = '填入 CC Switch（FluxDO）',
  bool includeNotes = true,
  DateTime? now,
}) {
  assert(app != CcswitchImportApp.all, 'Use buildCcswitchDeeplinks for all');
  final targetApp = app;
  final models = kCcswitchDefaultModels[targetApp.name] ?? const <String, String>{};
  final providerName =
      name ?? defaultProviderName(credentials, now: now);
  final params = <String, String>{
    'resource': 'provider',
    'app': targetApp.name,
    'name': providerName,
    'endpoint': credentials.baseUrl ?? '',
    'apiKey': credentials.apiKey ?? '',
    'homepage': credentials.baseUrl ?? '',
  };
  final model = models['model'];
  if (model != null && model.isNotEmpty) params['model'] = model;
  if (targetApp == CcswitchImportApp.claude) {
    final haiku = models['haikuModel'];
    final sonnet = models['sonnetModel'];
    final opus = models['opusModel'];
    if (haiku != null) params['haikuModel'] = haiku;
    if (sonnet != null) params['sonnetModel'] = sonnet;
    if (opus != null) params['opusModel'] = opus;
  }
  if (includeNotes && notes != null && notes.isNotEmpty) {
    params['notes'] = notes;
  }
  final configObj = buildProviderConfig(
    targetApp,
    credentials,
    name: providerName,
  );
  if (configObj != null) {
    params['configFormat'] = 'json';
    params['config'] = utf8ToBase64(jsonEncode(configObj));
  }
  final query = params.entries
      .map(
        (e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
      )
      .join('&');
  return 'ccswitch://v1/import?$query';
}

/// Build deeplinks for the selected app mode (expands `all`).
List<String> buildCcswitchDeeplinks(
  CcswitchImportApp appMode,
  CcswitchCredentials credentials, {
  String? name,
  String? notes = '填入 CC Switch（FluxDO）',
  bool includeNotes = true,
  DateTime? now,
}) {
  return appMode.resolvedApps
      .map(
        (app) => buildCcswitchDeeplink(
          app,
          credentials,
          name: name,
          notes: notes,
          includeNotes: includeNotes,
          now: now,
        ),
      )
      .toList(growable: false);
}
