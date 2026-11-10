import 'dart:async';

import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:fluxdo/services/network/cookie/cookie_full_info.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';
import 'package:fluxdo/services/network/cookie/raw_cookie_writer.dart';

const origin = 'https://linux.do';

CanonicalCookie token(
  String value, {
  int version = 1,
  String name = '_t',
  String path = '/',
}) => CanonicalCookie(
  name: name,
  value: value,
  version: version,
  domain: 'linux.do',
  path: path,
  secure: true,
  httpOnly: true,
  hostOnly: true,
  expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
);

CookieFullInfo info(CanonicalCookie cookie) => CookieFullInfo(
  name: cookie.name,
  value: cookie.value,
  domain: cookie.domain,
  path: cookie.path,
  isSecure: cookie.secure,
  isHttpOnly: cookie.httpOnly,
);

class MemoryJar implements CookieJarService {
  List<CanonicalCookie> cookies = [token('old')];
  @override
  bool get isInitialized => true;
  @override
  Future<void> initialize() async {}
  @override
  Future<int> enforceAuthCookiePolicy({
    String reason = 'unknown',
    Iterable<String>? names,
  }) async => 0;
  @override
  Future<List<CanonicalCookie>> loadAllCanonicalCookies() async =>
      List.of(cookies);
  @override
  Future<List<CanonicalCookie>> loadCanonicalCookiesForRequest(Uri uri) async =>
      cookies
          .where(
            (c) =>
                uri.path.isEmpty ? c.path == '/' : uri.path.startsWith(c.path),
          )
          .toList();
  @override
  Future<CanonicalCookie?> getCanonicalCookie(String name) async {
    for (final cookie in cookies) {
      if (cookie.name == name) return cookie;
    }
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

class MemoryWriter implements RawCookieWriter {
  List<CookieFullInfo> cookies = [];
  Completer<void>? holdDelete;
  Completer<void>? holdCount;
  Completer<void>? holdRead;
  Completer<void>? holdWrite;
  final deleteStarted = Completer<void>();
  final countStarted = Completer<void>();
  final readStarted = Completer<void>();
  final writeStarted = Completer<void>();
  int deletes = 0;
  int writes = 0;
  int reads = 0;
  int activeReads = 0;
  int maxActiveReads = 0;
  bool acceptWrites = true;
  bool acceptDeletes = true;

  @override
  void invalidateReads() {}
  @override
  Future<void> clearSharedAuthCookieCopies(
    String url,
    Iterable<String> names,
  ) async {}
  @override
  Future<List<CookieFullInfo>> getAllCookieInfos(String url) async {
    reads++;
    activeReads++;
    if (activeReads > maxActiveReads) maxActiveReads = activeReads;
    if (!readStarted.isCompleted) readStarted.complete();
    final wait = holdRead;
    holdRead = null;
    await wait?.future;
    activeReads--;
    return List.of(cookies);
  }

  @override
  Future<int> countCookiesByName(String url, String name) async {
    if (!countStarted.isCompleted) countStarted.complete();
    final wait = holdCount;
    holdCount = null;
    await wait?.future;
    return cookies.where((cookie) => cookie.name == name).length;
  }

  @override
  Future<int> nukeAllVariants({
    required String url,
    required String name,
    required List<String?> domainCandidates,
    required List<String> pathCandidates,
  }) async {
    deletes++;
    if (!deleteStarted.isCompleted) deleteStarted.complete();
    final wait = holdDelete;
    holdDelete = null;
    await wait?.future;
    final before = cookies.length;
    if (acceptDeletes) cookies.removeWhere((cookie) => cookie.name == name);
    return before - cookies.length;
  }

  @override
  Future<bool> setRawCookie(
    String url,
    String header, {
    bool writeSharedStorage = true,
  }) async {
    writes++;
    if (!writeStarted.isCompleted) writeStarted.complete();
    final wait = holdWrite;
    holdWrite = null;
    await wait?.future;
    if (!acceptWrites) return false;
    final cookie = SetCookieParser.parse(header, uri: Uri.parse(url));
    cookies.removeWhere(
      (old) =>
          old.name == cookie.name &&
          old.path == cookie.path &&
          old.domain == cookie.domain,
    );
    cookies.add(info(cookie));
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}
