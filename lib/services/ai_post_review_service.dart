import 'dart:async';
import 'dart:convert';

import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:shared_preferences/shared_preferences.dart';

class AiPostReviewException implements Exception {
  AiPostReviewException(this.message, {this.details});

  final String message;
  final String? details;

  @override
  String toString() => message;
}

enum AiPostReviewTarget { topic, reply }

enum AiPostReviewLevel { low, medium, high }

class AiPostReviewRequest {
  const AiPostReviewRequest({
    required this.provider,
    required this.model,
    required this.title,
    required this.content,
    required this.target,
    this.categoryName,
    this.categoryDescription,
    this.tags = const [],
  });

  final AiProvider provider;
  final AiModel model;
  final String? title;
  final String content;
  final AiPostReviewTarget target;
  final String? categoryName;
  final String? categoryDescription;
  final List<String> tags;
}

class AiPostReviewResult {
  const AiPostReviewResult({
    required this.level,
    required this.suggestions,
    required this.usedCachedGuidelines,
    required this.rawResponse,
  });

  final AiPostReviewLevel level;
  final List<String> suggestions;
  final bool usedCachedGuidelines;
  final String rawResponse;
}

class _GuidelinesLoadResult {
  const _GuidelinesLoadResult({required this.text, required this.usedCache});

  final String text;
  final bool usedCache;
}

typedef AiPostReviewApiKeyLoader = Future<String?> Function(String providerId);
typedef AiPostReviewGuidelinesFetcher = Future<String> Function();

class AiPostReviewService {
  AiPostReviewService({
    required SharedPreferences prefs,
    required AiChatService chatService,
    required AiPostReviewApiKeyLoader apiKeyLoader,
    Dio? dio,
    AiPostReviewGuidelinesFetcher? guidelinesFetcher,
  }) : _prefs = prefs,
       _chatService = chatService,
       _apiKeyLoader = apiKeyLoader,
       _dio = dio,
       _guidelinesFetcher = guidelinesFetcher;

  static const guidelinesUrl = 'https://linux.do/guidelines';
  static const _guidelinesCacheKey = 'ai_post_review_guidelines_cache';
  static const _guidelinesCacheUpdatedAtKey =
      'ai_post_review_guidelines_cache_updated_at';
  static const _maxGuidelinesChars = 12000;
  static const _guidelinesReceiveTimeout = Duration(seconds: 10);
  static const _guidelinesOverallTimeout = Duration(seconds: 12);

  final SharedPreferences _prefs;
  final AiChatService _chatService;
  final AiPostReviewApiKeyLoader _apiKeyLoader;
  final Dio? _dio;
  final AiPostReviewGuidelinesFetcher? _guidelinesFetcher;

  Future<AiPostReviewResult> review(AiPostReviewRequest request) async {
    if (!request.model.output.contains(Modality.text)) {
      throw AiPostReviewException('请选择支持文本输出的 AI 模型。');
    }

    final apiKey = await _apiKeyLoader(request.provider.id);
    if (apiKey == null || apiKey.trim().isEmpty) {
      throw AiPostReviewException('无法读取审核模型的 API Key，请重新配置该 AI 提供商。');
    }

    final guidelines = await _loadGuidelines();
    final response = StringBuffer();
    try {
      await for (final chunk in _chatService.sendChatStream(
        provider: request.provider,
        model: request.model.id,
        apiKey: apiKey.trim(),
        systemPrompt: buildSystemPrompt(guidelines.text),
        messages: [
          AiChatMessage(
            id: 'post-review-request',
            role: ChatRole.user,
            content: buildUserPrompt(request),
            createdAt: DateTime.now(),
          ),
        ],
        thinkingConfig: const ThinkingConfig(),
      )) {
        if (chunk is TextDelta) {
          response.write(chunk.text);
        }
      }
    } catch (error, stackTrace) {
      throw AiPostReviewException(
        'AI 审核失败，请稍后重试。',
        details: '$error\n$stackTrace',
      );
    }

    final raw = response.toString().trim();
    if (raw.isEmpty) {
      throw AiPostReviewException('AI 没有返回审核意见，请稍后重试。');
    }

    return parseResult(raw, usedCachedGuidelines: guidelines.usedCache);
  }

  Future<_GuidelinesLoadResult> _loadGuidelines() async {
    try {
      final html = await (_guidelinesFetcher?.call() ?? _fetchGuidelinesHtml());
      final text = extractGuidelinesText(html);
      validateGuidelinesText(text);
      await _prefs.setString(_guidelinesCacheKey, text);
      await _prefs.setInt(
        _guidelinesCacheUpdatedAtKey,
        DateTime.now().millisecondsSinceEpoch,
      );
      return _GuidelinesLoadResult(text: text, usedCache: false);
    } catch (error, stackTrace) {
      final cached = _prefs.getString(_guidelinesCacheKey);
      if (cached != null && cached.trim().isNotEmpty) {
        return _GuidelinesLoadResult(text: cached, usedCache: true);
      }
      throw AiPostReviewException(
        '无法获取 Linux.do 社区准则，也没有可用缓存。',
        details: '$error\n$stackTrace',
      );
    }
  }

  Future<String> _fetchGuidelinesHtml() async {
    final dio = _dio;
    if (dio == null) {
      throw StateError('缺少网络客户端。');
    }
    final response = await dio
        .get<String>(
          guidelinesUrl,
          options: Options(
            responseType: ResponseType.plain,
            receiveTimeout: _guidelinesReceiveTimeout,
          ),
        )
        .timeout(_guidelinesOverallTimeout);
    return response.data ?? '';
  }

  @visibleForTesting
  static String extractGuidelinesText(String html) {
    final document = html_parser.parse(html);
    document
        .querySelectorAll('script, style, noscript, svg, nav, footer')
        .forEach((element) => element.remove());

    final source =
        document.querySelector('main') ??
        document.querySelector('.container') ??
        document.body ??
        document.documentElement;
    final text = source?.text ?? html;
    final normalized = text
        .replaceAll(RegExp(r'\r\n?'), '\n')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    if (normalized.length <= _maxGuidelinesChars) return normalized;
    return normalized.substring(0, _maxGuidelinesChars);
  }

  @visibleForTesting
  static String buildSystemPrompt(String guidelines) {
    return '''
你是 Linux.do 社区发帖前的本地 AI 审核助手。你的任务是根据社区准则帮助用户发现可能需要修改的地方。

硬性要求，必须遵守：
1. 只输出整体优先级和 1-3 条建议修改方向，不得提供完整改写内容。
2. 不得输出可直接复制发布的完整帖子、完整回复、完整标题或完整正文。
3. 不要替用户整段重写；可以指出哪些位置需要删减、补充、弱化、换一种表达、补充上下文或调整语气。
4. 审核结果只是建议，不要说“禁止发布”或“必须拦截”。
5. 必须返回严格 JSON，不要包裹 Markdown 代码块。
6. 少输出废话，每条建议用一句短句表达，最多 3 条。
7. 如果有分区、分区说明或标签信息，请检查内容是否适合当前分区和标签。

优先级定义：
- low：基本可发布，只有轻微措辞、格式或信息补充建议。
- medium：建议发布前调整，例如分区/标签可能不准、语气不稳、信息缺失。
- high：存在明显违反社区准则、隐私泄露、人身攻击、引战或高风险表达。

返回 JSON 格式：
{
  "level": "low 或 medium 或 high",
  "suggestions": ["建议修改方向；只能给方向，不能给完整改写文本；最多 3 条"]
}

社区准则：
$guidelines
''';
  }

  @visibleForTesting
  static String buildUserPrompt(AiPostReviewRequest request) {
    final targetName = switch (request.target) {
      AiPostReviewTarget.topic => '新建主题',
      AiPostReviewTarget.reply => '回帖',
    };
    final title = request.title?.trim();
    final categoryName = request.categoryName?.trim();
    final categoryDescription = request.categoryDescription?.trim();
    final tags = request.tags
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toList(growable: false);
    return '''
请审核下面这次$targetName的内容。

当前分区：
${categoryName == null || categoryName.isEmpty ? '（未提供分区）' : categoryName}

分区说明：
${categoryDescription == null || categoryDescription.isEmpty ? '（未提供分区说明）' : categoryDescription}

已选标签：
${tags.isEmpty ? '（未选择标签）' : tags.join('、')}

标题：
${title == null || title.isEmpty ? '（未提供标题）' : title}

正文：
${request.content.trim()}
''';
  }

  @visibleForTesting
  static AiPostReviewResult parseResult(
    String raw, {
    required bool usedCachedGuidelines,
  }) {
    final cleaned = _stripJsonFence(raw);
    try {
      final decoded = jsonDecode(cleaned) as Map<String, dynamic>;
      final suggestions = _readStringList(
        decoded['suggestions'],
      ).map(_hideLikelyFullRewrite).take(3).toList(growable: false);
      return AiPostReviewResult(
        level: _parseLevel(decoded['level']),
        suggestions: suggestions.isEmpty
            ? const ['未发现明显需要调整的地方。']
            : suggestions,
        usedCachedGuidelines: usedCachedGuidelines,
        rawResponse: raw,
      );
    } catch (_) {
      return AiPostReviewResult(
        level: AiPostReviewLevel.medium,
        suggestions: const ['AI 返回了非标准格式，请重新审核一次，或根据社区准则自行检查内容。'],
        usedCachedGuidelines: usedCachedGuidelines,
        rawResponse: raw,
      );
    }
  }

  static AiPostReviewLevel _parseLevel(Object? value) {
    final normalized = value?.toString().trim().toLowerCase();
    return switch (normalized) {
      'low' || '低' => AiPostReviewLevel.low,
      'medium' || 'middle' || '中' => AiPostReviewLevel.medium,
      'high' || '高' => AiPostReviewLevel.high,
      _ => AiPostReviewLevel.medium,
    };
  }

  static String _stripJsonFence(String raw) {
    final trimmed = raw.trim();
    final match = RegExp(
      r'^```(?:json)?\s*([\s\S]*?)\s*```$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    return match?.group(1)?.trim() ?? trimmed;
  }

  static List<String> _readStringList(Object? value) {
    if (value is List) {
      return value
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }
    if (value is String && value.trim().isNotEmpty) {
      return [value.trim()];
    }
    return const [];
  }

  @visibleForTesting
  static void validateGuidelinesText(String text) {
    final normalized = text.trim();
    if (normalized.length < 80) {
      throw StateError('社区准则内容过短，可能获取到了异常页面。');
    }
    final hasGuidelineKeyword = RegExp(
      r'(社区准则|社群準則|文明|友善|尊重|AI|人工智能|广告|垃圾信息|骚扰|騷擾)',
      caseSensitive: false,
    ).hasMatch(normalized);
    final looksLikeChallenge = RegExp(
      r'(cloudflare|enable javascript|checking your browser|access denied|just a moment|请启用|請啟用)',
      caseSensitive: false,
    ).hasMatch(normalized);
    if (!hasGuidelineKeyword || looksLikeChallenge) {
      throw StateError('社区准则内容校验失败，可能获取到了异常页面。');
    }
  }

  static String _hideLikelyFullRewrite(String value) {
    final normalized = value.trim();
    final looksTooLong = normalized.length > 360;
    final hasMultiParagraph = RegExp(r'\n\s*\n').hasMatch(normalized);
    final hasRewriteMarker = RegExp(
      r'(完整改写|改写如下|可直接使用|直接发布|标题[:：].*正文[:：])',
      caseSensitive: false,
      dotAll: true,
    ).hasMatch(normalized);
    if (looksTooLong || hasMultiParagraph || hasRewriteMarker) {
      return 'AI 返回了疑似完整改写内容，已隐藏；请重新审核或只参考需要调整的位置和方向。';
    }
    return normalized;
  }
}
