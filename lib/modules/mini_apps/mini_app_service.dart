import 'package:dio/dio.dart';

import '../../services/discourse/discourse_service.dart';
import '../../services/auth_session.dart';
import 'mini_app.dart';
import 'mini_app_url.dart';
import '../../constants.dart';

class MiniAppService {
  MiniAppService({Dio? dio}) : _dio = dio ?? DiscourseService().dio;
  final Dio _dio;

  String actionUrl(MiniAppDetails details, String action) {
    if (!{'favorite', 'rating', 'tip', 'report'}.contains(action)) {
      throw const FormatException('Invalid action');
    }
    final base = Uri.parse(AppConstants.baseUrl);
    final value = details.configuration['${action}Url'];
    if (value is! String) throw const FormatException('Missing action URL');
    final uri = base.resolve(value);
    final prefix = base.path.replaceFirst(RegExp(r'/$'), '');
    if (uri.origin != base.origin ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.path !=
            '$prefix/mini-app-api/production/${details.app.id}/$action') {
      throw const FormatException('Invalid action URL');
    }
    return uri.toString();
  }

  Future<bool> favorite(MiniAppDetails details, bool value) async {
    final response = await _dio.request(
      actionUrl(details, 'favorite'),
      options: Options(method: value ? 'PUT' : 'DELETE'),
    );
    final result = (response.data as Map)['is_favorited'];
    if (result is! bool) {
      throw const FormatException('Invalid favorite response');
    }
    return result;
  }

  Future<void> rate(MiniAppDetails details, int score) async {
    if (score < 1 || score > 5) throw const FormatException('Invalid rating');
    await _dio.put(actionUrl(details, 'rating'), data: {'score': score});
  }

  Future<Map<String, dynamic>> tipStatus(MiniAppDetails details) async =>
      (await _dio.get(actionUrl(details, 'tip'))).data as Map<String, dynamic>;

  Future<Map<String, dynamic>> tip(
    MiniAppDetails details,
    int amount,
    String requestId,
  ) async =>
      (await _dio.post(
            actionUrl(details, 'tip'),
            data: {'amount': amount, 'request_id': requestId},
          )).data
          as Map<String, dynamic>;

  Future<List<Map<String, dynamic>>> reportTypes() async {
    final data = (await _dio.get('/site.json')).data as Map<String, dynamic>;
    // Discourse's site.flagTypes is computed from post_action_types, rather
    // than a JSON field named flag_types.
    return (data['post_action_types'] as List)
        .cast<Map<String, dynamic>>()
        .where(
          (f) =>
              f['is_flag'] == true &&
              f['enabled'] == true &&
              f['name_key'] != 'notify_user' &&
              (f['applies_to'] as List?)?.contains('DiscourseMiniApp::App') ==
                  true,
        )
        .toList();
  }

  Future<void> report(
    MiniAppDetails details,
    int flagType,
    String message,
  ) async {
    // A release may have changed while the runtime was open. Do not report a
    // newer release using metadata from an older running application.
    final generation = AuthSession().generation;
    final fresh = await this.details(details.app.id);
    if (!AuthSession().isValid(generation)) {
      throw StateError('Session changed');
    }
    if (fresh.feedback['release_id'] != details.feedback['release_id']) {
      throw const FormatException(
        'Application version changed; reopen before reporting',
      );
    }
    await _dio.post(
      actionUrl(details, 'report'),
      data: {
        'flag_type_id': flagType,
        'release_id': details.feedback['release_id'],
        if (message.trim().isNotEmpty) 'message': message.trim(),
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
  }

  Future<MiniAppDirectory> directory({
    required String sort,
    required String query,
    required bool favorites,
    required int page,
  }) async {
    final response = await _dio.get(
      '/mini-app-api/apps.json',
      queryParameters: {
        'sort': sort,
        'q': query,
        'page': page,
        'favorite': favorites,
      },
    );
    return MiniAppDirectory.fromJson(response.data as Map<String, dynamic>);
  }

  Future<MiniAppDetails> details(String appId) async {
    if (!MiniAppUrl.validId(appId)) {
      throw const FormatException('Invalid mini-app ID');
    }
    final response = await _dio.get('/mini-app-api/production/$appId/info');
    final details = MiniAppDetails.fromJson(
      response.data as Map<String, dynamic>,
    );
    if (details.app.id != appId) {
      throw const FormatException('Mini-app ID mismatch');
    }
    return details;
  }
}
