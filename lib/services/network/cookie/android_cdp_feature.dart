import 'dart:io' show Platform;

import 'package:shared_preferences/shared_preferences.dart';

import '../../app_logger.dart';

class AndroidCdpFeature {
  AndroidCdpFeature._();

  static const String prefKey = 'pref_android_native_cdp';
  static const bool _forceDisabled = true;
  static bool _enabled = false;
  static bool _initialized = false;

  static bool get isEnabled =>
      Platform.isAndroid && !_forceDisabled && _enabled;

  static Future<void> initialize(SharedPreferences prefs) async {
    _enabled = _forceDisabled ? false : (prefs.getBool(prefKey) ?? false);
    if (_forceDisabled && prefs.getBool(prefKey) != false) {
      await prefs.setBool(prefKey, false);
    }
    _initialized = true;
    AppLogger.info(
      _forceDisabled
          ? 'Android native CDP force disabled'
          : 'Android native CDP ${_enabled ? 'enabled' : 'disabled'}',
      tag: 'AndroidCdp',
    );
  }

  static Future<void> setEnabled(bool enabled) async {
    _enabled = _forceDisabled ? false : enabled;
    _initialized = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKey, _enabled);
    AppLogger.warning(
      _forceDisabled
          ? 'Android native CDP force disabled'
          : 'Android native CDP switched ${enabled ? 'on' : 'off'}',
      tag: 'AndroidCdp',
    );
  }

  static bool get isInitialized => _initialized;
}
