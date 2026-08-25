/// 加解密工具箱 —— 密码记忆（最近使用密码列表）。
///
/// 存储走 [SecretStore]（系统安全存储，flutter_secure_storage），
/// 最多保留 [maxEntries] 条最近使用的密码（去重置顶）。
/// 是否启用由用户设置「记住加密密码」控制（preferencesProvider）。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/secret_store.dart';

class CryptoKeyStore {
  CryptoKeyStore._();

  static const int maxEntries = 5;

  static const SecretKey _storageKey = SecretKey(
    namespace: 'crypto',
    name: 'remembered_passwords',
    fallbackPolicy: SecretFallbackPolicy.memoryOnly,
  );

  /// 读取记住的密码（最近使用在前）。存储不可用/损坏时返回空列表。
  static Future<List<String>> readPasswords(SecretStore store) async {
    try {
      final raw = await store.read(_storageKey);
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded.whereType<String>().take(maxEntries).toList();
    } catch (_) {
      return const [];
    }
  }

  /// 记住一条密码：去重置顶，超出上限裁掉最旧的。
  static Future<void> rememberPassword(
      SecretStore store, String password) async {
    final password_ = password.trim();
    if (password_.isEmpty) return;
    final current = await readPasswords(store);
    final next = <String>[
      password_,
      ...current.where((p) => p != password_),
    ].take(maxEntries).toList();
    try {
      await store.write(_storageKey, jsonEncode(next));
    } catch (_) {
      // 存储不可用（fallback 也失败）时静默放弃 —— 记忆密码是增强功能
    }
  }

  /// 清除全部记住的密码（设置页操作）。
  static Future<void> clear(SecretStore store) async {
    try {
      await store.delete(_storageKey);
    } catch (_) {
      // 忽略
    }
  }
}

/// 最近使用密码列表 Provider（同步快照 + 刷新方法）。
///
/// 弹窗打开时 watch 一次；记住新密码后调 refresh 更新。
class CryptoRememberedPasswords extends Notifier<List<String>> {
  @override
  List<String> build() => const [];

  Future<void> refresh(SecretStore store) async {
    state = await CryptoKeyStore.readPasswords(store);
  }
}

final cryptoRememberedPasswordsProvider =
    NotifierProvider<CryptoRememberedPasswords, List<String>>(
  CryptoRememberedPasswords.new,
);
