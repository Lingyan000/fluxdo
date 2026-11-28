import 'dart:io';

import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart';
import 'package:local_auth_darwin/local_auth_darwin.dart';
import 'package:local_auth_darwin/types/auth_messages_macos.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/s.dart';
import 'storage/secret_store.dart';

class LdcBiometricException implements Exception {
  const LdcBiometricException();
}

/// LDC 的设备级付款确认。每笔交易重新认证，支付密码仅存系统安全存储。
class LdcBiometricPayment {
  LdcBiometricPayment({
    required this.accountId,
    required this.store,
    required this.preferences,
    required this.checkSession,
    Future<bool> Function()? available,
    Future<bool> Function(String)? authenticate,
  }) : _available = available ?? _deviceAvailable,
       _authenticate = authenticate ?? _authenticateDevice;

  final int accountId;
  final SecretStore store;
  final SharedPreferences preferences;
  final Future<void> Function() checkSession;
  final Future<bool> Function() _available;
  final Future<bool> Function(String) _authenticate;

  SecretKey get _key => SecretKey(
    namespace: 'ldc.payment',
    accountId: '$accountId',
    name: 'biometric_pin',
  );
  String get _enabledKey => 'ldc.payment.biometric.$accountId';
  bool get enabled => preferences.getBool(_enabledKey) == true;

  static Future<bool> _deviceAvailable() async {
    // Windows Hello 无法强制仅用生物识别，Linux 尚无对应实现。
    if (!(Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
      return false;
    }
    final auth = LocalAuthentication();
    return await auth.canCheckBiometrics &&
        (await auth.getAvailableBiometrics()).isNotEmpty;
  }

  static Future<bool> _authenticateDevice(String reason) =>
      LocalAuthentication().authenticate(
        localizedReason: reason,
        authMessages: [
          AndroidAuthMessages(
            signInTitle: S.current.ldc_biometricPay,
            signInHint: S.current.ldc_biometricHint,
            cancelButton: S.current.common_cancel,
          ),
          IOSAuthMessages(
            cancelButton: S.current.common_cancel,
            localizedFallbackTitle: '',
          ),
          MacOSAuthMessages(
            cancelButton: S.current.common_cancel,
            localizedFallbackTitle: '',
          ),
        ],
        biometricOnly: true,
        sensitiveTransaction: true,
        persistAcrossBackgrounding: false,
      );

  Future<bool> available() async {
    try {
      return await _available();
    } catch (_) {
      return false;
    }
  }

  Future<void> _confirm(String reason) async {
    await checkSession();
    try {
      if (!await _available() || !await _authenticate(reason)) {
        throw const LdcBiometricException();
      }
    } catch (_) {
      throw const LdcBiometricException();
    }
    await checkSession();
  }

  /// 仅在用户选择开启、且 LDC 已确认本次密码付款成功后调用。
  Future<void> enable(String password, String reason) async {
    if (!RegExp(r'^\d{6}$').hasMatch(password)) {
      throw const LdcBiometricException();
    }
    await _confirm(reason);
    await store.write(_key, password);
    try {
      await checkSession();
      if (!await preferences.setBool(_enabledKey, true)) {
        throw const LdcBiometricException();
      }
    } catch (_) {
      await store.delete(_key);
      rethrow;
    }
  }

  Future<String> unlock(String reason) async {
    if (!enabled) throw const LdcBiometricException();
    await _confirm(reason);
    final password = await store.read(_key);
    await checkSession();
    if (!enabled ||
        password == null ||
        !RegExp(r'^\d{6}$').hasMatch(password)) {
      throw const LdcBiometricException();
    }
    return password;
  }

  Future<void> disable() async {
    await preferences.remove(_enabledKey);
    await store.delete(_key);
  }
}
