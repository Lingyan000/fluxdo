import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../constants.dart';
import '../../providers/core_providers.dart';
import '../../providers/theme_provider.dart';
import 'mini_app.dart';
import 'mini_app_service.dart';
import 'mini_app_window_bridge.dart';

final miniAppServiceProvider = Provider((ref) => MiniAppService());
final miniAppDetailsProvider = FutureProvider.autoDispose
    .family<MiniAppDetails, String>((ref, id) {
      ref.watch(authStateProvider);
      ref.watch(currentUserProvider.select((v) => v.value?.id));
      final sub = MiniAppWindowBridge.updates.stream
          .where((value) => value == id)
          .listen((_) => ref.invalidateSelf());
      ref.onDispose(sub.cancel);
      return ref.watch(miniAppServiceProvider).details(id);
    });

final miniAppRecentsProvider = Provider.autoDispose<MiniAppRecents>((ref) {
  final userId = ref.watch(currentUserProvider.select((v) => v.value?.id));
  final store = MiniAppRecents(
    ref.watch(sharedPreferencesProvider),
    '${AppConstants.baseUrl}|${userId ?? 'guest'}',
  );
  ref.onDispose(store.dispose);
  return store;
});

class MiniAppRecents extends ChangeNotifier {
  MiniAppRecents(this._prefs, String account)
    : _key = 'mini_app_recents_$account' {
    try {
      final json = jsonDecode(_prefs.getString(_key) ?? '[]') as List;
      apps = json
          .take(12)
          .map((e) => MiniApp.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      apps = [];
    }
  }
  final SharedPreferences _prefs;
  final String _key;
  List<MiniApp> apps = [];
  void record(MiniApp app) {
    apps = [app, ...apps.where((e) => e.id != app.id)].take(12).toList();
    _prefs.setString(_key, jsonEncode(apps.map((e) => e.toJson()).toList()));
    notifyListeners();
  }
}
