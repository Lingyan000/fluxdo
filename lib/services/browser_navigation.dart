import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/theme_provider.dart';

enum BrowserSearchEngine {
  google('Google', 'www.google.com', '/search'),
  bing('Bing', 'www.bing.com', '/search'),
  duckDuckGo('DuckDuckGo', 'duckduckgo.com', '/');

  const BrowserSearchEngine(this.label, this.host, this.path);
  final String label;
  final String host;
  final String path;

  Uri search(String query) => Uri.https(host, path, {'q': query});
}

class BrowserSearchEngineNotifier extends Notifier<BrowserSearchEngine> {
  static const _key = 'browser_search_engine';

  @override
  BrowserSearchEngine build() {
    final name = ref.watch(sharedPreferencesProvider).getString(_key);
    return BrowserSearchEngine.values.firstWhere(
      (engine) => engine.name == name,
      orElse: () => BrowserSearchEngine.google,
    );
  }

  void select(BrowserSearchEngine engine) {
    state = engine;
    ref.read(sharedPreferencesProvider).setString(_key, engine.name);
  }
}

final browserSearchEngineProvider =
    NotifierProvider<BrowserSearchEngineNotifier, BrowserSearchEngine>(
      BrowserSearchEngineNotifier.new,
    );

/// 地址栏只直接导航 HTTP(S)；普通文本编码为搜索词，其他协议不交给网页执行。
class BrowserNavigationTarget {
  const BrowserNavigationTarget(this.uri, {this.isSearch = false});
  final Uri uri;
  final bool isSearch;

  static BrowserNavigationTarget? parse(
    String input,
    BrowserSearchEngine engine,
  ) {
    final text = input.trim();
    if (text.isEmpty) return null;
    if (RegExp(
      r'^(site|filetype|intitle|inurl|intext|before|after|related|cache):',
      caseSensitive: false,
    ).hasMatch(text)) {
      return BrowserNavigationTarget(engine.search(text), isSearch: true);
    }
    final withScheme = RegExp(
      r'^https?://',
      caseSensitive: false,
    ).hasMatch(text);
    final authority = text.split(RegExp(r'[/\?#]')).first;
    final hostPort = RegExp(r'^(localhost|[^\s:]+\.[^\s:]+):\d+($|/)')
        .hasMatch(text);
    final localPort = RegExp(r'^localhost:\d+($|/)').hasMatch(text);
    if (!withScheme &&
        !hostPort &&
        !localPort &&
        !text.startsWith('[') &&
        RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(text)) {
      return null;
    }
    final looksLikeHost =
        !RegExp(r'\s').hasMatch(authority) &&
        (authority.contains('.') ||
            authority == 'localhost' ||
            hostPort ||
            localPort ||
            authority.startsWith('['));
    if (withScheme || looksLikeHost) {
      final uri = Uri.tryParse(withScheme ? text : 'https://$text');
      if (uri == null ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          RegExp(r'\s').hasMatch(uri.host) ||
          uri.port > 65535) {
        return null;
      }
      return BrowserNavigationTarget(uri);
    }
    return BrowserNavigationTarget(engine.search(text), isSearch: true);
  }
}

String browserDisplayHost(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return '';
  final host = uri.host.startsWith('www.') ? uri.host.substring(4) : uri.host;
  return uri.hasPort ? '$host:${uri.port}' : host;
}
