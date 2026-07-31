import 'dart:io';

import 'package:dio/dio.dart';
import '../l10n/ai_l10n.dart';
import '../models/ai_provider.dart';
import '../utils/api_host_formatter.dart';

/// AI 供应商 API 服务
class AiProviderApiService {
  final HttpClientAdapter Function()? _adapterFactory;

  AiProviderApiService({HttpClientAdapter Function()? adapterFactory})
      : _adapterFactory = adapterFactory;

  /// 从 DioException 中提取用户友好的错误信息
  static String friendlyError(Object error) {
    final l10n = AiL10n.current;
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.transformTimeout:
          return l10n.connectionTimeoutError;
        case DioExceptionType.connectionError:
          return l10n.cannotConnectError;
        case DioExceptionType.badResponse:
          final statusCode = error.response?.statusCode;
          final body = error.response?.data;
          // 尝试从响应体中提取错误信息
          String? apiMessage;
          if (body is Map<String, dynamic>) {
            apiMessage = body['error'] is Map
                ? (body['error'] as Map)['message'] as String?
                : body['error'] as String?;
            apiMessage ??= body['message'] as String?;
          }
          if (statusCode == 401) {
            return l10n.apiKeyInvalidError;
          } else if (statusCode == 403) {
            return l10n.noAccessPermissionError;
          } else if (statusCode == 404) {
            return l10n.endpointNotFoundError;
          } else if (statusCode == 429) {
            return l10n.tooManyRequestsError;
          } else if (statusCode != null && statusCode >= 500) {
            return l10n.serverInternalError(statusCode);
          }
          if (apiMessage != null) {
            return apiMessage;
          }
          return l10n.requestFailed(statusCode ?? 0);
        case DioExceptionType.cancel:
          return l10n.requestCancelled;
        case DioExceptionType.badCertificate:
          return l10n.sslCertificateError;
        case DioExceptionType.unknown:
          if (error.error is SocketException) {
            return l10n.networkConnectionFailed;
          }
          return l10n.unknownNetworkError;
      }
    }
    return error.toString();
  }

  /// Anthropic 预定义模型列表
  static const List<AiModel> _anthropicModels = [
    AiModel(id: 'claude-sonnet-4-20250514', name: 'Claude Sonnet 4'),
    AiModel(id: 'claude-opus-4-20250514', name: 'Claude Opus 4'),
    AiModel(id: 'claude-3-5-haiku-20241022', name: 'Claude 3.5 Haiku'),
  ];

  Dio _createDio() {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
    ));
    if (_adapterFactory != null) {
      dio.httpClientAdapter = _adapterFactory!();
    }
    return dio;
  }

  /// 拉取模型列表
  Future<List<AiModel>> fetchModels(
    AiProviderType type,
    String baseUrl,
    String apiKey,
  ) async {
    switch (type) {
      case AiProviderType.openai:
      case AiProviderType.openaiResponse:
        return _fetchOpenAiModels(baseUrl, apiKey);
      case AiProviderType.gemini:
        return _fetchGeminiModels(baseUrl, apiKey);
      case AiProviderType.anthropic:
        return _anthropicModels;
    }
  }

  Future<List<AiModel>> _fetchOpenAiModels(
      String baseUrl, String apiKey) async {
    final dio = _createDio();
    try {
      final url = '${ApiHostFormatter.format(baseUrl)}/models';
      final response = await dio.get(
        url,
        options: Options(headers: {'Authorization': 'Bearer $apiKey'}),
      );
      final data = response.data as Map<String, dynamic>;
      final list = data['data'] as List<dynamic>? ?? [];
      final models = list.map((item) {
        final m = item as Map<String, dynamic>;
        return AiModel(id: m['id'] as String);
      }).toList();
      // 按 id 排序
      models.sort((a, b) => a.id.compareTo(b.id));
      return models;
    } finally {
      dio.close();
    }
  }

  Future<List<AiModel>> _fetchGeminiModels(
      String baseUrl, String apiKey) async {
    final dio = _createDio();
    try {
      // Gemini 直连端点是 /v1beta/models;baseUrl 由用户配,可能带
      // /v1beta、可能不带。format(apiVersion: 'v1beta') 自动补齐。
      final url =
          '${ApiHostFormatter.format(baseUrl, apiVersion: 'v1beta')}/models';
      final response = await dio.get(
        url,
        queryParameters: {'key': apiKey},
      );
      final data = response.data as Map<String, dynamic>;
      final list = data['models'] as List<dynamic>? ?? [];
      final models = list.map((item) {
        final m = item as Map<String, dynamic>;
        final name = m['name'] as String? ?? '';
        // Gemini 返回 models/gemini-xxx，取后半段作为 id
        final id = name.startsWith('models/') ? name.substring(7) : name;
        final displayName = m['displayName'] as String?;
        return AiModel(id: id, name: displayName);
      }).toList();
      models.sort((a, b) => a.id.compareTo(b.id));
      return models;
    } finally {
      dio.close();
    }
  }

  /// 测试指定模型是否可用（发送最小请求）
  ///
  /// 成功返回 null，失败返回错误信息
  Future<String?> testModel(
    AiProviderType type,
    String baseUrl,
    String apiKey,
    String modelId,
  ) async {
    final dio = _createDio();
    // OpenAI / Anthropic 端点都是 /v1/<endpoint>,Gemini 是
    // /v1beta/models/<id>:generateContent,分别按 provider 类型 format。
    final openAiUrl = ApiHostFormatter.format(baseUrl);
    final geminiUrl = ApiHostFormatter.format(baseUrl, apiVersion: 'v1beta');
    try {
      switch (type) {
        case AiProviderType.openai:
          await dio.post(
            '$openAiUrl/chat/completions',
            data: {
              'model': modelId,
              'messages': [
                {'role': 'user', 'content': 'hi'}
              ],
              'max_tokens': 1,
            },
            options: Options(headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            }),
          );

        case AiProviderType.openaiResponse:
          await dio.post(
            '$openAiUrl/responses',
            data: {
              'model': modelId,
              'input': 'hi',
              'max_output_tokens': 1,
            },
            options: Options(headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            }),
          );

        case AiProviderType.gemini:
          await dio.post(
            '$geminiUrl/models/$modelId:generateContent',
            queryParameters: {'key': apiKey},
            data: {
              'contents': [
                {
                  'parts': [
                    {'text': 'hi'}
                  ]
                }
              ],
              'generationConfig': {'maxOutputTokens': 1},
            },
            options: Options(headers: {
              'Content-Type': 'application/json',
            }),
          );

        case AiProviderType.anthropic:
          await dio.post(
            '$openAiUrl/messages',
            data: {
              'model': modelId,
              'max_tokens': 1,
              'messages': [
                {'role': 'user', 'content': 'hi'}
              ],
            },
            options: Options(headers: {
              'x-api-key': apiKey,
              'anthropic-version': '2023-06-01',
              'Content-Type': 'application/json',
            }),
          );
      }
      return null; // 成功
    } catch (e) {
      return friendlyError(e);
    } finally {
      dio.close();
    }
  }
}
