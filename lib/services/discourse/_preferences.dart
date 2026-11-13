part of 'discourse_service.dart';

/// 论坛偏好设置复用主站会话，变更请求交给调用方明确重试。
mixin _ForumPreferencesMixin on _DiscourseServiceBase {
  Future<ForumPreferences> getForumPreferences(String username) async {
    final response = await _dio.get('/u/${Uri.encodeComponent(username)}.json');
    final preload = PreloadedDataService();
    await preload.ensureLoaded();
    final user = Map<String, dynamic>.from(response.data['user'] as Map);
    user['sidebar_tag_names'] = (user['sidebar_tags'] as List? ?? [])
        .whereType<Map>()
        .map((tag) => tag['name'])
        .whereType<String>()
        .toList();
    return ForumPreferences(
      user: user,
      site: preload.siteSync ?? {},
      settings: preload.siteSettingsSync ?? {},
    );
  }

  Future<Map<String, dynamic>> _preferenceRequest(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? data,
  }) async {
    final response = await _dio.request<dynamic>(
      path,
      data: data,
      options: Options(
        method: method,
        contentType: Headers.formUrlEncodedContentType,
        listFormat: ListFormat.multiCompatible,
        extra: {
          FluxRequestKeys.noRecovery: method != 'GET',
          FluxRequestKeys.skipNetworkLog: true,
        },
      ),
    );
    if (response.data != null && response.data != '' && response.data is! Map) {
      throw const FormatException('Invalid preference response');
    }
    final result = response.data is Map
        ? Map<String, dynamic>.from(response.data as Map)
        : <String, dynamic>{};
    if (result['success'] == false ||
        result['failed'] != null ||
        result['error'] != null ||
        result['errors'] != null) {
      throw StateError(
        '${result['error'] ?? result['errors'] ?? result['message'] ?? S.current.forumPrefs_saveFailed}',
      );
    }
    return result;
  }

  Future<void> saveForumPreferences(
    String username,
    Map<String, dynamic> changes,
  ) async {
    if (changes.isEmpty) return;
    await _preferenceRequest(
      '/u/${Uri.encodeComponent(username)}.json',
      method: 'PUT',
      data: changes,
    );
  }

  Future<void> saveUserStatus(Map<String, dynamic>? status) async {
    await _preferenceRequest(
      '/user-status.json',
      method: status == null ? 'DELETE' : 'PUT',
      data: status,
    );
    _activeUserRequests.clear();
  }

  Future<Map<String, dynamic>> getPreferenceEmails(String username) =>
      _preferenceRequest('/u/${Uri.encodeComponent(username)}/emails.json');

  Future<void> changePreferenceUsername(
    String username,
    String newUsername,
  ) async {
    await _preferenceRequest(
      '/u/${Uri.encodeComponent(username)}/preferences/username',
      method: 'PUT',
      data: {'new_username': newUsername},
    );
    if (_username?.toLowerCase() == username.toLowerCase()) {
      _username = newUsername;
      await _storage.write(
        key: DiscourseService._usernameKey,
        value: newUsername,
      );
    }
  }

  Future<void> changePreferenceEmail(
    String username,
    String email, {
    bool add = false,
    bool primary = false,
    bool remove = false,
  }) async {
    await _preferenceRequest(
      '/u/${Uri.encodeComponent(username)}/preferences/${primary ? "primary-email" : "email"}.json',
      method: remove
          ? 'DELETE'
          : add
          ? 'POST'
          : 'PUT',
      data: {'email': email},
    );
  }

  Future<void> pickPreferenceAvatar(
    String username,
    int uploadId,
    String type,
  ) async {
    await _preferenceRequest(
      '/u/${Uri.encodeComponent(username)}/preferences/avatar/pick',
      method: 'PUT',
      data: {'upload_id': uploadId, 'type': type},
    );
    _activeUserRequests.remove(username);
  }

  Future<void> featureProfileTopic(String username, int? topicId) async {
    await _preferenceRequest(
      '/u/${Uri.encodeComponent(username)}/${topicId == null ? "clear-featured-topic" : "feature-topic"}',
      method: 'PUT',
      data: topicId == null ? null : {'topic_id': topicId},
    );
  }

  Future<void> sendPreferencePasswordReset(String username) async {
    await _preferenceRequest(
      '/session/forgot_password.json',
      method: 'POST',
      data: {'login': username},
    );
  }

  Future<void> removePreferencePassword(String username) async {
    await _preferenceRequest(
      '/u/${Uri.encodeComponent(username)}/remove-password',
      method: 'PUT',
    );
  }

  Future<void> exportPreferenceArchive() async {
    await _preferenceRequest(
      '/export_csv/export_entity.json',
      method: 'POST',
      data: {'entity': 'user_archive'},
    );
  }

  Future<void> deletePreferenceAccount(String username) async {
    await _preferenceRequest(
      '/u/${Uri.encodeComponent(username)}.json',
      method: 'DELETE',
    );
  }

  Future<bool> isPreferenceSessionTrusted() async {
    final result = (await _dio.get('/u/trusted-session.json')).data;
    return result['success'] == true || result['success'] == 'OK';
  }

  Future<void> confirmPreferenceSession(String password) async {
    await _preferenceRequest(
      '/u/confirm-session.json',
      method: 'POST',
      data: {'password': password},
    );
  }

  Future<Map<String, dynamic>> getPreferenceSecondFactors() =>
      _preferenceRequest('/u/second_factors.json', method: 'POST');

  Future<Map<String, dynamic>> createPreferenceTotp() =>
      _preferenceRequest('/u/create_second_factor_totp.json', method: 'POST');

  Future<void> enablePreferenceTotp(String token, String name) async {
    await _preferenceRequest(
      '/u/enable_second_factor_totp.json',
      method: 'POST',
      data: {'second_factor_token': token, 'name': name},
    );
  }

  Future<void> updatePreferenceSecondFactor(
    Object id,
    String name, {
    bool remove = false,
    bool securityKey = false,
  }) async {
    await _preferenceRequest(
      '/u/${securityKey ? "security_key" : "second_factor"}.json',
      method: 'PUT',
      data: {
        'id': id,
        'name': name,
        'disable': remove,
        if (!securityKey) 'second_factor_target': 1,
      },
    );
  }

  Future<Map<String, dynamic>> generatePreferenceBackupCodes() =>
      _preferenceRequest('/u/second_factors_backup.json', method: 'PUT');

  Future<void> revokePreferenceSession(String username, Object tokenId) async {
    await _preferenceRequest(
      '/u/${Uri.encodeComponent(username)}/preferences/revoke-auth-token',
      method: 'POST',
      data: {'token_id': tokenId},
    );
  }

  Future<void> revokePreferenceAccount(
    String username,
    String providerName,
  ) async {
    await _preferenceRequest(
      '/u/${Uri.encodeComponent(username)}/preferences/revoke-account',
      method: 'POST',
      data: {'provider_name': providerName},
    );
  }

  Future<void> updatePreferencePasskey(
    Object id, {
    String? name,
    bool remove = false,
  }) async {
    await _preferenceRequest(
      '/u/${remove ? "delete" : "rename"}_passkey/$id',
      method: remove ? 'DELETE' : 'PUT',
      data: remove ? null : {'name': name},
    );
  }

  Future<void> revokePreferenceApp(Object id, {bool restore = false}) async {
    await _preferenceRequest(
      '/user-api-key/${restore ? "undo-revoke" : "revoke"}',
      method: 'POST',
      data: {'id': id},
    );
  }

  Future<Map<String, dynamic>> preferenceCalendarSubscription({
    bool generate = false,
    bool revoke = false,
  }) => _preferenceRequest(
    '/calendar-subscriptions.json',
    method: revoke
        ? 'DELETE'
        : generate
        ? 'POST'
        : 'GET',
  );
}
