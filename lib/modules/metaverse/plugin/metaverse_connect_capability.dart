import 'package:dio/dio.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

import '../../../services/linux_do_connect_navigator.dart';
import 'metaverse_plugin_manifest.dart';

/// Connect 负责应用会话内的授权交互，返回服务回调给插件继续处理。
class MetaverseConnectCapability {
  const MetaverseConnectCapability(this.client);
  final Dio client;

  static Uri callback(MetaversePluginManifest manifest, Uri authorization) {
    if (!LinuxDoConnectNavigator.isConnect(authorization)) {
      throw const MetaversePluginCallException('connect_invalid_authorization');
    }
    final raw = authorization.queryParameters['redirect_uri'];
    final callback = raw == null ? null : Uri.tryParse(raw);
    if (callback == null ||
        callback.hasFragment ||
        callback.hasQuery ||
        !manifest.capabilities.allowsCallback(callback)) {
      throw const MetaversePluginCallException('connect_callback_not_declared');
    }
    return callback;
  }

  Future<String> authorize(
    MetaversePluginManifest manifest,
    Uri authorization, {
    required bool Function() isActive,
  }) async {
    final expected = callback(manifest, authorization);
    final result = await LinuxDoConnectNavigator(client)
        .authorize(authorization, active: isActive);
    if (!isActive()) throw const PluginOperationCancelled();
    if (!manifest.capabilities.allowsCallback(result) ||
        result.origin != expected.origin ||
        result.path != expected.path) {
      throw const MetaversePluginCallException('connect_invalid_callback');
    }
    final state = authorization.queryParameters['state'];
    if (state != null && state != result.queryParameters['state']) {
      throw const MetaversePluginCallException('connect_state_mismatch');
    }
    return result.toString();
  }
}
