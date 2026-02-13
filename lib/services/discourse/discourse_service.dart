import 'package:flutter/foundation.dart' hide Category;
import 'package:flutter/material.dart' hide Badge;
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:fluxdo/services/message_bus_service.dart';
import '../../models/topic.dart';
import '../../models/topic_vote.dart';
import '../../models/user.dart';
import '../../models/user_action.dart';
import '../../models/notification.dart';
import '../../models/category.dart';
import '../../models/search_result.dart';
import '../../models/emoji.dart';
import '../../models/badge.dart';
import '../../models/tag_search_result.dart';
import '../../models/mention_user.dart';
import '../../models/draft.dart';

import '../../constants.dart';
import '../../providers/message_bus_providers.dart';
import '../network/cookie/cookie_sync_service.dart';
import '../network/cookie/cookie_jar_service.dart';
import '../cf_challenge_service.dart';
import '../network/discourse_dio.dart';
import '../preloaded_data_service.dart';
import '../auth_log_service.dart';

part '_auth.dart';
part '_topics.dart';
part '_posts.dart';
part '_users.dart';
part '_search.dart';
part '_notifications.dart';
part '_uploads.dart';
part '_voting.dart';
part '_presence.dart';
part '_categories.dart';
part '_utils.dart';
part '_drafts.dart';

/// 基类，包含所有共享字段
abstract class _DiscourseServiceBase {
  Dio get _dio;
  FlutterSecureStorage get _storage;
  CookieSyncService get _cookieSync;
  CookieJarService get _cookieJar;
  CfChallengeService get _cfChallenge;

  String? get _tToken;
  set _tToken(String? value);
  String? get _username;
  set _username(String? value);
  bool get _credentialsLoaded;
  set _credentialsLoaded(bool value);
  bool get _isLoggingOut;
  set _isLoggingOut(bool value);

  UserSummary? get _cachedUserSummary;
  set _cachedUserSummary(UserSummary? value);
  String? get _cachedUserSummaryUsername;
  set _cachedUserSummaryUsername(String? value);
  DateTime? get _userSummaryCacheTime;
  set _userSummaryCacheTime(DateTime? value);

  ValueNotifier<User?> get currentUserNotifier;
  StreamController<String> get _authErrorController;
  StreamController<void> get _authStateController;
  Map<String, String> get _urlCache;

  bool get isAuthenticated;

  // 共享工具方法
  Exception _handleDioError(DioException error);
  Never _throwApiError(DioException e);
  Future<void> _loadStoredCredentials();
}

/// Linux.do API 服务
class DiscourseService extends _DiscourseServiceBase
    with
        _AuthMixin,
        _TopicsMixin,
        _PostsMixin,
        _UsersMixin,
        _SearchMixin,
        _NotificationsMixin,
        _UploadsMixin,
        _VotingMixin,
        _PresenceMixin,
        _CategoriesMixin,
        _UtilsMixin,
        _DraftsMixin {
  static const String baseUrl = AppConstants.baseUrl;
  static const String _usernameKey = 'linux_do_username';
  static const _summaryCacheDuration = Duration(minutes: 5);

  @override
  final Dio _dio;
  @override
  final FlutterSecureStorage _storage;
  @override
  final CookieSyncService _cookieSync = CookieSyncService();
  @override
  final CookieJarService _cookieJar = CookieJarService();
  @override
  final CfChallengeService _cfChallenge = CfChallengeService();

  @override
  String? _tToken;
  @override
  String? _username;
  @override
  bool _credentialsLoaded = false;
  @override
  bool _isLoggingOut = false;

  @override
  UserSummary? _cachedUserSummary;
  @override
  String? _cachedUserSummaryUsername;
  @override
  DateTime? _userSummaryCacheTime;

  @override
  final ValueNotifier<User?> currentUserNotifier = ValueNotifier<User?>(null);

  @override
  // ignore: close_sinks
  final _authErrorController = StreamController<String>.broadcast();
  Stream<String> get authErrorStream => _authErrorController.stream;

  @override
  // ignore: close_sinks
  final _authStateController = StreamController<void>.broadcast();
  Stream<void> get authStateStream => _authStateController.stream;

  @override
  final Map<String, String> _urlCache = {};

  static final DiscourseService _instance = DiscourseService._internal();
  factory DiscourseService() => _instance;

  CookieSyncService get cookieSync => _cookieSync;

  @override
  bool get isAuthenticated => _tToken != null && _tToken!.isNotEmpty;

  DiscourseService._internal()
      : _dio = DiscourseDio.create(
          defaultHeaders: {
            'Accept': 'application/json;q=0.9, text/plain;q=0.8, */*;q=0.5',
            'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
            'X-Requested-With': 'XMLHttpRequest',
          },
        ),
        _storage = const FlutterSecureStorage() {
    _initInterceptors();
  }

  // ========== 共享工具方法 ==========

  /// 处理 Dio 错误
  @override
  Exception _handleDioError(DioException error) {
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout) {
      return TimeoutException(error.message);
    }
    if (error.response != null) {
      final statusCode = error.response!.statusCode;
      final errorMessage = error.response!.data.toString();
      return Exception('HTTP $statusCode: $errorMessage');
    }
    return Exception(error.message ?? 'Unknown Dio error');
  }

  /// 从 DioException 中提取 Discourse API 错误消息并抛出
  @override
  Never _throwApiError(DioException e) {
    if (e.response?.data is Map) {
      final data = e.response!.data as Map;
      if (data['errors'] != null && data['errors'] is List) {
        throw Exception((data['errors'] as List).join('\n'));
      }
    }
    throw e;
  }

  /// 加载存储的凭证
  @override
  Future<void> _loadStoredCredentials() async {
    _tToken = await _cookieJar.getTToken();
    _username = await _storage.read(key: _usernameKey);
  }
}
