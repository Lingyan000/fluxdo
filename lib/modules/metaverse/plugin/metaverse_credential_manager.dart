import 'dart:convert';

import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

import 'metaverse_credential.dart';
import 'metaverse_plugin_capabilities.dart';
import 'metaverse_plugin_manifest.dart';
import 'metaverse_plugin_network.dart';
import 'metaverse_plugin_store.dart';

class MetaverseCredentialManager {
  const MetaverseCredentialManager(this.manifest, this.store, this.network);
  final MetaversePluginManifest manifest;
  final MetaversePluginStore store;
  final MetaversePluginNetwork network;

  MetaverseCredentialSpec spec(Object? name) {
    final result = manifest.capabilities.credentials[name];
    if (result == null) {
      throw const MetaversePluginCallException('credential_not_declared');
    }
    return result;
  }

  Future<MetaverseCredential?> read(Object? name, int? accountId) async {
    final credential = await store.readCredential(manifest.id, spec(name).name);
    return credential?.validFor(accountId) == true ? credential : null;
  }

  Future<Map<String, Object?>> status(Object? name, int? accountId) async {
    final credential = await read(name, accountId);
    return {
      'authorized': credential != null,
      'expiresAt': credential?.expiresAt,
    };
  }

  /// 将远端 JSON 中指定的凭证直接保存，脚本只收到状态及可选的 JWT 声明。
  /// JWT 声明用于服务协议处理，签发方身份仍由插件的验证接口核对。
  Future<Map<String, Object?>> capture(
    Map<String, Object?> params, {
    required int? accountId,
    required bool Function() isActive,
  }) async {
    final declaration = spec(params['name']);
    final request = params['request'];
    final tokenPath = _path(params['tokenPath']);
    final expiryPath = params['expiresAtPath'] == null
        ? null
        : _path(params['expiresAtPath']);
    if (request is! Map<String, dynamic> ||
        request['credential'] != null ||
        request['auth'] == true) {
      throw const MetaversePluginCallException(
        'credential_capture_invalid_request',
      );
    }
    final revision = store.credentialRevision(manifest.id, declaration.name);
    void checkActive() {
      if (!isActive() ||
          store.credentialRevision(manifest.id, declaration.name) != revision) {
        throw const PluginOperationCancelled();
      }
    }

    checkActive();
    final response = await network.fetch(
      manifest,
      request: request,
      authToken: null,
      checkActive: checkActive,
    );
    final status = response['status'];
    if (status is! int || status < 200 || status >= 300) {
      throw MetaversePluginCallException('credential_capture_http_$status');
    }
    final body = _json(response['body'] as String);
    final secret = _select(body, tokenPath);
    Object? expiresAt = expiryPath == null ? null : _select(body, expiryPath);
    Map<String, dynamic>? claims;
    if (params['jwt'] == true) {
      if (secret is! String || secret.split('.').length != 3) {
        throw const MetaversePluginCallException('credential_invalid_jwt');
      }
      final Object? decoded;
      try {
        decoded = _json(
          utf8.decode(
            base64Url.decode(base64Url.normalize(secret.split('.')[1])),
          ),
        );
      } on FormatException {
        throw const MetaversePluginCallException('credential_invalid_jwt');
      }
      if (decoded is! Map<String, dynamic>) {
        throw const MetaversePluginCallException('credential_invalid_jwt');
      }
      claims = decoded;
      expiresAt ??= claims['exp'];
    }
    final credential = MetaverseCredential.parse({
      'secret': secret,
      'accountId': accountId,
      'expiresAt': expiresAt,
    });
    if (credential == null || !credential.validFor(accountId)) {
      throw const MetaversePluginCallException('credential_invalid');
    }
    await store.writeCredential(
      manifest.id,
      declaration.name,
      credential,
      isActive: isActive,
      revision: revision,
    );
    return {
      'authorized': true,
      'expiresAt': credential.expiresAt,
      'claims': ?claims,
    };
  }

  static List<Object> _path(Object? value) {
    if (value is! List ||
        value.isEmpty ||
        value.length > 16 ||
        value.any(
          (key) =>
              (key is! String || key.length > 128) && (key is! int || key < 0),
        )) {
      throw const MetaversePluginCallException('credential_invalid_selector');
    }
    return value.cast<Object>();
  }

  static Object? _json(String value) {
    try {
      return jsonDecode(value);
    } on FormatException {
      throw const MetaversePluginCallException('credential_invalid_response');
    }
  }

  static Object? _select(Object? value, List<Object> path) {
    for (final key in path) {
      value = switch ((value, key)) {
        (final Map map, final String name) => map[name],
        (final List list, final int index) when index < list.length =>
          list[index],
        _ => null,
      };
    }
    return value;
  }
}
