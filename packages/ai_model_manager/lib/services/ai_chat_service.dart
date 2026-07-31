import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as a;
import 'package:dio/dio.dart' show DioException, DioExceptionType;
import 'package:googleai_dart/googleai_dart.dart' as g;
import 'package:http/http.dart' as http;
import 'package:openai_dart/openai_dart.dart' as o;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../l10n/ai_l10n.dart';
import '../models/ai_chat_attachment.dart';
import '../models/ai_chat_message.dart';
import '../utils/api_host_formatter.dart';
import '../utils/model_capabilities.dart';
import 'ai_package_logger.dart';
import '../models/ai_provider.dart';

/// 流式响应中的事件类型（统一各 SDK 输出）
sealed class AiChatChunk {
  const AiChatChunk();
}

/// 正文文本增量
class TextDelta extends AiChatChunk {
  const TextDelta(this.text);
  final String text;
}

/// 思考块（reasoning）文本增量
/// - Anthropic: Extended Thinking 块
/// - OpenAI: reasoning_content / reasoning（DeepSeek R1 / OpenRouter / vLLM 等）
class ThinkingDelta extends AiChatChunk {
  const ThinkingDelta(this.text);
  final String text;
}

/// Token 用量报告，流结束时发送
class UsageReport extends AiChatChunk {
  const UsageReport({this.promptTokens, this.responseTokens, this.cachedTokens});
  final int? promptTokens;
  final int? responseTokens;
  final int? cachedTokens;
}

/// 模型生成的图片（gpt-image / DALL-E 等）
///
/// 字节已写到本地文件，调用方持久化 [localPath] 即可。
///
/// 渐进式生成（partial_images）会先发送若干 [partialImageIndex] != null 的中间帧
/// （草图），最后才发送 [partialImageIndex] == null 的终态图。
/// 上层在收到终态图时应清掉所有 partial 帧。
class ImageGenerated extends AiChatChunk {
  const ImageGenerated({
    required this.localPath,
    required this.mimeType,
    this.partialImageIndex,
  });
  final String localPath;
  final String mimeType;
  final int? partialImageIndex;

  bool get isPartial => partialImageIndex != null;
}

/// 流式请求的诊断统计,sendChatStream 内部各 _stream 方法会写入。
///
/// 关键用途:emptyResponseError 拼诊断信息时区分多个层次:
/// - `httpStatus` / `respBytes`:HTTP 层真实收到的状态码 / 字节数
///   - status=200 bytes=0 → 服务端 200 但 body 立即关流(代理 bug)
///   - status=200 bytes>0 sdkEvents=0 → SDK 解析器跟上游 SSE 格式不兼容
///   - status!=200 → 上游真的报错了
/// - `sdkEvents`:SDK 内部 await for 收到的原始 event 数
/// - 上层 `chunks`:yield 给 UI 的 chunk 数
class ChatStreamStats {
  int sdkEvents = 0;
  int? httpStatus;
  int respBytes = 0;
  String? respContentType;
}

/// AI 聊天服务：直接基于各 LLM provider 的 SDK 实现统一流式接口。
///
/// - OpenAI / OpenAI Responses → `openai_dart` 4.x
/// - Anthropic（含 Extended Thinking）→ `anthropic_sdk_dart`
/// - Gemini → `googleai_dart`
///
/// 所有 SDK 都基于 `package:http`，通过 [bridgedClient] 注入应用 dio 网络栈。
class AiChatService {
  AiChatService({
    this.bridgedClient,
    this.enablePartialImages = false,
  });

  /// 可选 http.Client。传 [DioBackedHttpClient] 即可让所有请求复用应用网络栈。
  final http.Client? bridgedClient;

  /// 是否启用 gpt-image 系列的渐进式生成（partial frames）。
  /// 默认 false；需要 OpenAI 已验证 organization 的账号才能开启，
  /// 未验证账号开启会让服务端立即关流（onDone 时 buffer 空，报错）。
  final bool enablePartialImages;

  Stream<AiChatChunk> sendChatStream({
    required AiProvider provider,
    required String model,
    required String apiKey,
    required List<AiChatMessage> messages,
    String? systemPrompt,
    ThinkingConfig thinkingConfig = const ThinkingConfig(),
    /// 仅图像生成路径使用：话题上下文摘要（含标题+正文楼层），
    /// 会被前置拼接到 image prompt 之前，让生成的图与话题相关。
    /// 文本聊天路径忽略此参数（话题上下文走 [messages] 注入）。
    String? imagePromptContext,
    /// 仅图像生成路径使用：用户在 PromptPreset 维度面板选择的 aspect。
    /// 取值 '1:1' / '16:9' / '9:16' / '4:3' / '3:4'，null = 用模型默认。
    String? imageAspect,
    /// 可取消的 HTTP client。外部 close 后底层 HTTP 连接立即断开，
    /// 不再等 stream 自然结束。未传则 fallback 到 [bridgedClient]。
    http.Client? requestClient,
    /// 可选的诊断统计对象,各 _stream 内部会写入 SDK 收到的原始 event 数。
    ChatStreamStats? stats,
  }) {
    final effectiveClient = requestClient ?? bridgedClient;
    // OpenAI 系图像模型（gpt-image-* / dall-e-* / grok-2-image / cogview /
    // qwen-image / sd / flux / midjourney 经 OpenAI 兼容代理等）走
    // /images/generations 端点。
    // 路由判断从「硬编码 prefix」改为「ModelCapabilities.isImageOutputModel
    // 正则」，覆盖所有主流图像生成模型 id。
    if (_isOpenAIImageRoute(provider, model)) {
      return _streamOpenAiImageGeneration(
        baseUrl: provider.baseUrl,
        apiKey: apiKey,
        model: model,
        messages: messages,
        contextSummary: imagePromptContext,
        imageAspect: imageAspect,
        httpClient: effectiveClient,
        stats: stats,
      );
    }
    if (_isGeminiImageRoute(provider, model)) {
      return _streamGeminiImageGeneration(
        baseUrl: provider.baseUrl,
        apiKey: apiKey,
        model: model,
        messages: messages,
        contextSummary: imagePromptContext,
        imageAspect: imageAspect,
        httpClient: effectiveClient,
        stats: stats,
      );
    }
    switch (provider.type) {
      case AiProviderType.openai:
        return _streamOpenAi(
          baseUrl: provider.baseUrl,
          apiKey: apiKey,
          model: model,
          messages: messages,
          systemPrompt: systemPrompt,
          thinkingConfig: thinkingConfig,
          httpClient: effectiveClient,
          stats: stats,
        );
      case AiProviderType.openaiResponse:
        return _streamOpenAiResponses(
          baseUrl: provider.baseUrl,
          apiKey: apiKey,
          model: model,
          messages: messages,
          systemPrompt: systemPrompt,
          httpClient: effectiveClient,
          stats: stats,
        );
      case AiProviderType.gemini:
        return _streamGemini(
          baseUrl: provider.baseUrl,
          apiKey: apiKey,
          model: model,
          messages: messages,
          systemPrompt: systemPrompt,
          thinkingConfig: thinkingConfig,
          httpClient: effectiveClient,
          stats: stats,
        );
      case AiProviderType.anthropic:
        return _streamAnthropic(
          baseUrl: provider.baseUrl,
          apiKey: apiKey,
          model: model,
          messages: messages,
          systemPrompt: systemPrompt,
          thinkingConfig: thinkingConfig,
          httpClient: effectiveClient,
          stats: stats,
        );
    }
  }

  /// 检测是否为 OpenAI 系（含 OpenAI 兼容代理）图像生成模型。
  /// 覆盖：gpt-image-* / chatgpt-image-* / dall-e-* / grok-2-image /
  /// cogview / qwen-image / sd / flux / midjourney 等所有走
  /// /v1/images/generations 端点的模型。
  ///
  /// Gemini 自己的 image 模型（gemini-*-image / imagen-*）走 [_isGeminiImageRoute]。
  bool _isOpenAIImageRoute(AiProvider provider, String modelId) {
    if (provider.type != AiProviderType.openai &&
        provider.type != AiProviderType.openaiResponse) {
      return false;
    }
    return ModelCapabilities.isImageOutputModel(modelId);
  }

  /// 检测是否为 Google 原生图像生成模型。
  /// 覆盖：gemini-2.5-flash-image / gemini-3-(flash|pro)-image / imagen-* 等。
  bool _isGeminiImageRoute(AiProvider provider, String modelId) {
    if (provider.type != AiProviderType.gemini) return false;
    return ModelCapabilities.isImageOutputModel(modelId);
  }

  // ────────────────────────── OpenAI Chat Completions ──────────────────────────

  Stream<AiChatChunk> _streamOpenAi({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<AiChatMessage> messages,
    String? systemPrompt,
    ThinkingConfig thinkingConfig = const ThinkingConfig(),
    http.Client? httpClient,
    ChatStreamStats? stats,
  }) async* {
    final client = _createOpenAIClient(baseUrl, apiKey, httpClient: httpClient);
    try {
      final request = o.ChatCompletionCreateRequest(
        model: model,
        messages: _toOpenAiMessages(systemPrompt, messages),
        streamOptions: const o.StreamOptions(includeUsage: true),
        reasoningEffort: _toOpenAiReasoningEffort(thinkingConfig),
      );
      int? promptTokens;
      int? responseTokens;
      int? cachedTokens;
      try {
        await for (final event in client.chat.completions.createStream(
          request,
        )) {
          stats?.sdkEvents++;
          final delta = event.choices?.firstOrNull?.delta;
          if (delta != null) {
            final text = delta.content;
            if (text != null && text.isNotEmpty) yield TextDelta(text);
            final reasoning = delta.reasoningContent ?? delta.reasoning;
            if (reasoning != null && reasoning.isNotEmpty) {
              yield ThinkingDelta(reasoning);
            }
          }
          final usage = event.usage;
          if (usage != null) {
            promptTokens = usage.promptTokens;
            responseTokens = usage.completionTokens;
            cachedTokens = usage.promptTokensDetails?.cachedTokens;
          }
        }
      } catch (e) {
        throw _mapError(e);
      }
      if (promptTokens != null || responseTokens != null) {
        yield UsageReport(
          promptTokens: promptTokens,
          responseTokens: responseTokens,
          cachedTokens: cachedTokens,
        );
      }
    } finally {
      client.close();
    }
  }

  /// 对 5xx 错误自动重试（含 502/503/504 上游代理超时）。
  ///
  /// openai_dart 4.x 默认只对幂等方法（GET/PUT/DELETE 等）重试 5xx，
  /// POST 不重试。而代理服务器（one-api / aihubmix）的 504 通常不是
  /// OpenAI 真的故障，重试一下大概率能成功。Cherry Studio 用的 Vercel AI SDK
  /// 默认对 POST 也重试 5xx，体验更好。
  Future<T> _withServerErrorRetry<T>(
    Future<T> Function() task, {
    int maxAttempts = 3,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await task();
      } catch (e) {
        lastError = e;
        final shouldRetry = _isTransientServerError(e) && attempt < maxAttempts;
        if (!shouldRetry) rethrow;
        // 指数退避：2s, 4s, 8s（最多 8s）
        final waitSec = 1 << attempt;
        await Future<void>.delayed(Duration(seconds: waitSec.clamp(2, 8)));
      }
    }
    throw lastError!;
  }

  bool _isTransientServerError(Object e) {
    if (e is o.InternalServerException) {
      // 502 / 503 / 504 是典型的上游瞬时问题，500 可能是 OpenAI 真的故障也重试
      return e.statusCode >= 500 && e.statusCode < 600;
    }
    if (e is a.AnthropicClientException) {
      // Anthropic 走代理同样会遇到 5xx 瞬时问题(one-api / 自建反代)
      final code = e.code;
      return code != null && code >= 500 && code < 600;
    }
    return false;
  }

  // ────────────────────────── OpenAI Images API（gpt-image / DALL-E） ──────────────────────────

  Stream<AiChatChunk> _streamOpenAiImageGeneration({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<AiChatMessage> messages,
    String? contextSummary,
    String? imageAspect,
    http.Client? httpClient,
    ChatStreamStats? stats,
  }) async* {
    // 提取最后一条 user 消息作为 prompt
    AiChatMessage? lastUser;
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role == ChatRole.user) {
        lastUser = messages[i];
        break;
      }
    }
    final userPrompt = (lastUser?.content ?? '').trim();
    if (userPrompt.isEmpty) {
      throw Exception(AiL10n.current.emptyResponseError);
    }
    // 拼接话题上下文（如果有），让生成的图与话题相关
    final prompt = _buildImagePrompt(contextSummary, userPrompt);
    final size = _aspectToOpenAiSize(imageAspect);

    final inputAttachments = lastUser?.attachments ?? const [];
    final hasInput = inputAttachments.isNotEmpty;

    final client = _createOpenAIClient(baseUrl, apiKey, httpClient: httpClient);
    try {
      // gpt-image 系列原生支持流式 partial frames（先发草图后发终态）。
      // dall-e-2/3 不支持 stream，会被 SDK 自动忽略 stream 参数走非流式。
      // 用 partialImages: 2 让用户更早看到雏形（5-10s 出第一张草图，30s 出终态）。
      final supportsPartial = _supportsPartialImages(model);
      final partialImages = supportsPartial ? 2 : null;

      try {
        if (hasInput) {
          final att = inputAttachments.first;
          final bytes = await _attachmentBytes(att);
          if (supportsPartial) {
            yield* _consumeImageEditStream(
              client.images.editStream(
                o.ImageEditRequest(
                  model: model,
                  prompt: prompt,
                  image: bytes,
                  imageFilename: 'input.${_extFromMime(att.mimeType)}',
                  partialImages: partialImages,
                  size: size,
                ),
              ),
              stats: stats,
            );
          } else {
            // 504/502/503 自动重试 3 次（绕过 openai_dart 4.x 对 POST 不重试的限制）
            final response = await _withServerErrorRetry(() => client.images.edit(
              o.ImageEditRequest(
                model: model,
                prompt: prompt,
                image: bytes,
                imageFilename: 'input.${_extFromMime(att.mimeType)}',
                size: size,
              ),
            ));
            yield* _emitImageResponse(response);
          }
        } else {
          if (supportsPartial) {
            yield* _consumeImageGenStream(
              client.images.generateStream(
                o.ImageGenerationRequest(
                  model: model,
                  prompt: prompt,
                  partialImages: partialImages,
                  size: size,
                ),
              ),
              stats: stats,
            );
          } else {
            final response = await _withServerErrorRetry(() => client.images.generate(
              o.ImageGenerationRequest(model: model, prompt: prompt, size: size),
            ));
            yield* _emitImageResponse(response);
          }
        }
      } catch (e) {
        throw _mapError(e);
      }
    } finally {
      client.close();
    }
  }

  /// 把 PromptPreset 的 aspect ('1:1' / '16:9' / ...) 映射到 OpenAI ImageSize。
  ///
  /// gpt-image-1 / chatgpt-image 支持 `auto` + 1024x1024 / 1536x1024 / 1024x1536。
  /// dall-e-3 支持 1024x1024 / 1792x1024 / 1024x1792。
  /// dall-e-2 仅 256/512/1024 方图。
  ///
  /// 我们用一个尽量兼容的映射：1:1 → 1024，16:9/4:3 偏宽 → 1792x1024，
  /// 9:16/3:4 偏高 → 1024x1792。null 或未识别值返回 null（用模型默认）。
  o.ImageSize? _aspectToOpenAiSize(String? aspect) {
    if (aspect == null || aspect.isEmpty) return null;
    switch (aspect) {
      case '1:1':
        return o.ImageSize.size1024x1024;
      case '16:9':
      case '4:3':
        return o.ImageSize.size1792x1024;
      case '9:16':
      case '3:4':
        return o.ImageSize.size1024x1792;
      default:
        return null;
    }
  }

  /// 是否启用 streaming + partial_images。
  ///
  /// 默认关闭（构造时 [enablePartialImages] 默认 false）：
  /// - OpenAI gpt-image streaming 要求 organization 完成 verification，
  ///   未验证的 org 会收到 200 响应但 stream 立即关闭、无任何事件
  /// - 用户在设置里主动启用后才走 stream 路径
  /// - 仅 gpt-image-* / chatgpt-image-* 系列支持，dall-e 系列即使开启也走非流式
  bool _supportsPartialImages(String modelId) {
    if (!enablePartialImages) return false;
    final id = modelId.toLowerCase();
    return id.startsWith('gpt-image-') || id.startsWith('chatgpt-image-');
  }

  /// 消费 generateStream 事件流，把 partial 帧和终态帧统一映射成 [ImageGenerated]
  Stream<AiChatChunk> _consumeImageGenStream(
    Stream<o.ImageGenStreamEvent> stream, {
    ChatStreamStats? stats,
  }) async* {
    await for (final event in stream) {
      stats?.sdkEvents++;
      switch (event) {
        case o.ImageGenPartialImageEvent e:
          final mime = _outputFormatToMime(e.outputFormat);
          final localPath = await _decodeAndSave(e.b64Json, mime);
          yield ImageGenerated(
            localPath: localPath,
            mimeType: mime,
            partialImageIndex: e.partialImageIndex,
          );
        case o.ImageGenCompletedEvent e:
          final mime = _outputFormatToMime(e.outputFormat);
          final localPath = await _decodeAndSave(e.b64Json, mime);
          yield ImageGenerated(localPath: localPath, mimeType: mime);
          yield UsageReport(
            promptTokens: e.usage.inputTokens,
            responseTokens: e.usage.outputTokens,
          );
        case o.ImageGenUnknownEvent _:
          break;
      }
    }
  }

  /// 消费 editStream 事件流，同 [_consumeImageGenStream] 风格
  Stream<AiChatChunk> _consumeImageEditStream(
    Stream<o.ImageEditStreamEvent> stream, {
    ChatStreamStats? stats,
  }) async* {
    await for (final event in stream) {
      stats?.sdkEvents++;
      switch (event) {
        case o.ImageEditPartialImageEvent e:
          final mime = _outputFormatToMime(e.outputFormat);
          final localPath = await _decodeAndSave(e.b64Json, mime);
          yield ImageGenerated(
            localPath: localPath,
            mimeType: mime,
            partialImageIndex: e.partialImageIndex,
          );
        case o.ImageEditCompletedEvent e:
          final mime = _outputFormatToMime(e.outputFormat);
          final localPath = await _decodeAndSave(e.b64Json, mime);
          yield ImageGenerated(localPath: localPath, mimeType: mime);
          yield UsageReport(
            promptTokens: e.usage.inputTokens,
            responseTokens: e.usage.outputTokens,
          );
        case o.ImageEditUnknownEvent _:
          break;
      }
    }
  }

  String _outputFormatToMime(o.ImageOutputFormat fmt) {
    switch (fmt.toJson()) {
      case 'jpeg':
      case 'jpg':
        return 'image/jpeg';
      case 'webp':
        return 'image/webp';
      case 'png':
      default:
        return 'image/png';
    }
  }

  Future<String> _decodeAndSave(String b64, String mime) async {
    final cleaned = b64.replaceAll(RegExp(r'\s'), '');
    final Uint8List bytes;
    try {
      bytes = base64Decode(cleaned);
    } catch (e) {
      throw Exception('Failed to decode image base64: $e');
    }
    return _saveImageBytes(bytes, mime);
  }

  /// 非流式响应回退：dall-e 系列走这里
  Stream<AiChatChunk> _emitImageResponse(o.ImageResponse response) async* {
    final outputMime = _imageResponseMime(response);
    for (final image in response.data) {
      final url = image.url;
      if (url != null && url.isNotEmpty) {
        final bytes = await _downloadImage(url);
        final localPath = await _saveImageBytes(bytes, outputMime);
        yield ImageGenerated(localPath: localPath, mimeType: outputMime);
        continue;
      }
      final b64 = image.b64Json;
      if (b64 == null || b64.isEmpty) continue;
      final localPath = await _decodeAndSave(b64, outputMime);
      yield ImageGenerated(localPath: localPath, mimeType: outputMime);
    }
    final usage = response.usage;
    if (usage != null) {
      yield UsageReport(
        promptTokens: usage.inputTokens,
        responseTokens: usage.outputTokens,
      );
    }
  }

  Future<Uint8List> _attachmentBytes(AiChatAttachment att) async {
    final base64Data = att.base64Data;
    if (base64Data != null && base64Data.isNotEmpty) {
      return base64Decode(base64Data.replaceAll(RegExp(r'\s'), ''));
    }
    final localPath = att.localPath;
    if (localPath != null && localPath.isNotEmpty) {
      return File(localPath).readAsBytes();
    }
    final remoteUrl = att.remoteUrl;
    if (remoteUrl != null && remoteUrl.isNotEmpty) {
      return _downloadImage(remoteUrl);
    }
    throw Exception('Attachment has no usable image source');
  }

  Future<Uint8List> _downloadImage(String url) async {
    final client = bridgedClient ?? http.Client();
    try {
      final resp = await client.get(Uri.parse(url));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('Failed to download image: HTTP ${resp.statusCode}');
      }
      return resp.bodyBytes;
    } finally {
      // 仅当 fallback http.Client() 时关闭；bridgedClient 由外部管理
      if (bridgedClient == null) client.close();
    }
  }

  Future<String> _saveImageBytes(Uint8List bytes, String mime) async {
    final dir = await getApplicationDocumentsDirectory();
    final imagesDir = Directory(p.join(dir.path, 'ai_generated_images'));
    if (!imagesDir.existsSync()) imagesDir.createSync(recursive: true);
    final ext = _extFromMime(mime);
    final filename = '${DateTime.now().millisecondsSinceEpoch}_'
        '${const Uuid().v4().substring(0, 8)}.$ext';
    final file = File(p.join(imagesDir.path, filename));
    await file.writeAsBytes(bytes);
    return file.path;
  }

  String _imageResponseMime(o.ImageResponse response) {
    final fmt = response.outputFormat?.toJson();
    switch (fmt) {
      case 'jpeg':
      case 'jpg':
        return 'image/jpeg';
      case 'webp':
        return 'image/webp';
      case 'png':
        return 'image/png';
    }
    // gpt-image 系列默认 png
    return 'image/png';
  }

  String _extFromMime(String mime) {
    switch (mime.toLowerCase()) {
      case 'image/jpeg':
      case 'image/jpg':
        return 'jpg';
      case 'image/webp':
        return 'webp';
      case 'image/gif':
        return 'gif';
      case 'image/png':
      default:
        return 'png';
    }
  }

  // ────────────────────────── OpenAI Responses API ──────────────────────────

  Stream<AiChatChunk> _streamOpenAiResponses({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<AiChatMessage> messages,
    String? systemPrompt,
    http.Client? httpClient,
    ChatStreamStats? stats,
  }) async* {
    final client = _createOpenAIClient(baseUrl, apiKey, httpClient: httpClient);
    try {
      final request = o.CreateResponseRequest(
        model: model,
        input: _toResponsesInput(messages),
        instructions: systemPrompt,
      );
      int? promptTokens;
      int? responseTokens;
      try {
        await for (final event in client.responses.createStream(request)) {
          stats?.sdkEvents++;
          switch (event) {
            case final o.OutputTextDeltaEvent e:
              if (e.delta.isNotEmpty) yield TextDelta(e.delta);
            case final o.ResponseCompletedEvent e:
              promptTokens = e.response.usage?.inputTokens;
              responseTokens = e.response.usage?.outputTokens;
            case final o.ResponseFailedEvent e:
              throw Exception(
                e.response.error?.message ?? 'Responses API failed',
              );
            default:
              break;
          }
        }
      } catch (e) {
        throw _mapError(e);
      }
      if (promptTokens != null || responseTokens != null) {
        yield UsageReport(
          promptTokens: promptTokens,
          responseTokens: responseTokens,
        );
      }
    } finally {
      client.close();
    }
  }

  o.OpenAIClient _createOpenAIClient(String baseUrl, String apiKey,
      {http.Client? httpClient}) {
    return o.OpenAIClient(
      config: o.OpenAIConfig(
        authProvider: o.ApiKeyProvider(apiKey),
        baseUrl: ApiHostFormatter.format(baseUrl),
      ),
      httpClient: httpClient ?? bridgedClient,
    );
  }

  // ────────────────────────── Gemini ──────────────────────────

  Stream<AiChatChunk> _streamGemini({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<AiChatMessage> messages,
    String? systemPrompt,
    ThinkingConfig thinkingConfig = const ThinkingConfig(),
    http.Client? httpClient,
    ChatStreamStats? stats,
  }) async* {
    final client = g.GoogleAIClient(
      config: g.GoogleAIConfig(
        authProvider: g.ApiKeyProvider(apiKey),
        // googleai_dart 自己拼 /v1beta,baseUrl 不能含版本号。
        // 先 format(supportApiVersion=false) 处理 # 转义 + 去尾斜杠,
        // 再 _stripGeminiVersion 去掉用户可能配的 /v1beta。
        baseUrl: baseUrl.isEmpty
            ? 'https://generativelanguage.googleapis.com'
            : _stripGeminiVersion(
                ApiHostFormatter.format(baseUrl, supportApiVersion: false),
              ),
        apiMode: g.ApiMode.googleAI,
      ),
      httpClient: httpClient ?? bridgedClient,
    );
    try {
      final request = g.GenerateContentRequest(
        contents: _toGeminiContents(messages),
        systemInstruction: systemPrompt == null
            ? null
            : g.Content(parts: [g.Part.text(systemPrompt)]),
        generationConfig: thinkingConfig.level == ThinkingLevel.off
            ? null
            : g.GenerationConfig(
                thinkingConfig: _toGeminiThinkingConfig(thinkingConfig),
              ),
      );
      int? promptTokens;
      int? responseTokens;
      try {
        await for (final response in client.models.streamGenerateContent(
          model: model,
          request: request,
        )) {
          stats?.sdkEvents++;
          final parts = response.candidates?.firstOrNull?.content?.parts ?? [];
          for (final part in parts) {
            if (part is g.TextPart && part.text.isNotEmpty) {
              if (part.thought == true) {
                yield ThinkingDelta(part.text);
              } else {
                yield TextDelta(part.text);
              }
            }
          }
          final usage = response.usageMetadata;
          if (usage != null) {
            promptTokens = usage.promptTokenCount;
            responseTokens = usage.candidatesTokenCount;
          }
        }
      } catch (e) {
        throw _mapError(e);
      }
      if (promptTokens != null || responseTokens != null) {
        yield UsageReport(
          promptTokens: promptTokens,
          responseTokens: responseTokens,
        );
      }
    } finally {
      client.close();
    }
  }

  // ────────────────────────── Gemini Image (gemini-*-image / imagen-*) ──────────────────────────

  /// Google 原生图像生成。
  ///
  /// 跟 Chat 不同：走 `streamGenerateContent` + `generationConfig.responseModalities=[image,text]`，
  /// 响应里 candidates[0].content.parts 含 [InlineDataPart]（mime + base64）。
  ///
  /// gemini-2.5-flash-image / gemini-3-flash-image 系列原生支持流式，
  /// 可能边描述边出图（多个 part）；imagen-* 走 Vertex 端点不在本路径覆盖。
  Stream<AiChatChunk> _streamGeminiImageGeneration({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<AiChatMessage> messages,
    String? contextSummary,
    String? imageAspect,
    http.Client? httpClient,
    ChatStreamStats? stats,
  }) async* {
    AiChatMessage? lastUser;
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role == ChatRole.user) {
        lastUser = messages[i];
        break;
      }
    }
    final userPrompt = (lastUser?.content ?? '').trim();
    if (userPrompt.isEmpty) {
      throw Exception(AiL10n.current.emptyResponseError);
    }
    // Gemini 通过修改 messages 注入 context 比较麻烦，
    // 我们直接把 contextSummary 拼到最后一条 user prompt 前。
    // 同时要把这条 user content 改成增强版，重建 contents。
    final prompt = _buildImagePrompt(contextSummary, userPrompt);

    final client = g.GoogleAIClient(
      config: g.GoogleAIConfig(
        authProvider: g.ApiKeyProvider(apiKey),
        // googleai_dart 自己拼 /v1beta,baseUrl 不能含版本号。
        // 先 format(supportApiVersion=false) 处理 # 转义 + 去尾斜杠,
        // 再 _stripGeminiVersion 去掉用户可能配的 /v1beta。
        baseUrl: baseUrl.isEmpty
            ? 'https://generativelanguage.googleapis.com'
            : _stripGeminiVersion(
                ApiHostFormatter.format(baseUrl, supportApiVersion: false),
              ),
        apiMode: g.ApiMode.googleAI,
      ),
      httpClient: httpClient ?? bridgedClient,
    );

    try {
      // 复用普通 chat 的消息转换（带附件作为输入图，也支持 image edit 场景）；
      // 但要把最后一条 user 文本替换成增强版 prompt（拼了话题上下文）
      final messagesWithEnhancedPrompt = _replaceLastUserContent(messages, prompt);
      final contents = _toGeminiContents(messagesWithEnhancedPrompt);
      final request = g.GenerateContentRequest(
        contents: contents,
        generationConfig: g.GenerationConfig(
          // 关键：要求模型同时输出图像和文本（image-only 会拒绝纯文本 prompt）
          responseModalities: const ['IMAGE', 'TEXT'],
          // aspect ratio 用 imageConfig.aspectRatio 透传（gemini-3-image preview 支持）
          imageConfig: imageAspect != null
              ? g.ImageConfig(aspectRatio: imageAspect)
              : null,
        ),
      );

      int? promptTokens;
      int? responseTokens;
      try {
        await for (final response in client.models.streamGenerateContent(
          model: model,
          request: request,
        )) {
          stats?.sdkEvents++;
          final parts =
              response.candidates?.firstOrNull?.content?.parts ?? const [];
          for (final part in parts) {
            if (part is g.TextPart && part.text.isNotEmpty) {
              yield TextDelta(part.text);
            } else if (part is g.InlineDataPart) {
              final blob = part.inlineData;
              final cleaned = blob.data.replaceAll(RegExp(r'\s'), '');
              try {
                final bytes = base64Decode(cleaned);
                final mime = blob.mimeType.isEmpty ? 'image/png' : blob.mimeType;
                final localPath = await _saveImageBytes(bytes, mime);
                yield ImageGenerated(localPath: localPath, mimeType: mime);
              } catch (_) {
                // 单帧解码失败不中断后续 part
              }
            }
          }
          final usage = response.usageMetadata;
          if (usage != null) {
            promptTokens = usage.promptTokenCount;
            responseTokens = usage.candidatesTokenCount;
          }
        }
      } catch (e) {
        throw _mapError(e);
      }

      if (promptTokens != null || responseTokens != null) {
        yield UsageReport(
          promptTokens: promptTokens,
          responseTokens: responseTokens,
        );
      }
    } finally {
      client.close();
    }
  }

  // ────────────────────────── Anthropic（含 Extended Thinking） ──────────────────────────

  Stream<AiChatChunk> _streamAnthropic({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<AiChatMessage> messages,
    String? systemPrompt,
    ThinkingConfig thinkingConfig = const ThinkingConfig(),
    http.Client? httpClient,
    ChatStreamStats? stats,
  }) async* {
    final effectiveClient = httpClient ?? bridgedClient;
    // anthropic_sdk_dart 拼 URL 是 `baseUrl + /messages`,不自动补 /v1,
    // 所以这里要预先 format 好。formatApiHost 已包含 /v1,SDK 直接拼出
    // baseUrl/v1/messages。
    final formattedBaseUrl = ApiHostFormatter.format(baseUrl);
    final client = a.AnthropicClient(
      apiKey: apiKey,
      baseUrl: formattedBaseUrl.isEmpty ? null : formattedBaseUrl,
      // 包一层统计 client,把 HTTP 层的真实 status / 字节数记到 stats,
      // 区分「上游 200 但 body 立即关」vs「SDK 解析器跟上游 SSE 格式不兼容」。
      client: stats == null
          ? effectiveClient
          : _StatsHttpClient(effectiveClient ?? http.Client(), stats),
    );

    final budgetTokens = _toAnthropicBudget(thinkingConfig);
    final request = a.CreateMessageRequest(
      model: a.Model.modelId(model),
      messages: _toAnthropicMessages(messages),
      maxTokens: thinkingConfig.isEnabled ? 16384 : 8192,
      system: systemPrompt == null
          ? null
          : a.CreateMessageRequestSystem.blocks([
              a.Block.text(
                text: systemPrompt,
                cacheControl: const a.CacheControlEphemeral(),
              ),
            ]),
      thinking: budgetTokens != null
          ? a.ThinkingConfig.enabled(
              type: a.ThinkingConfigEnabledType.enabled,
              budgetTokens: budgetTokens,
            )
          : null,
    );

    int? promptTokens;
    int? responseTokens;
    int? cachedTokens;
    try {
      // 5xx 自动重试,仅在 yield 任何 chunk 之前重试。一旦上层收到第一个
      // text/thinking,重试就会让 UI 文本回滚重出,体验差;所以用 hasYielded
      // 标记,触发 yield 之后再失败就直接抛。
      var hasYielded = false;
      Object? lastError;
      const maxAttempts = 3;
      for (var i = 1; i <= maxAttempts; i++) {
        try {
          await for (final event
              in client.createMessageStream(request: request)) {
            stats?.sdkEvents++;
            switch (event) {
              case final a.MessageStartEvent e:
                promptTokens = e.message.usage?.inputTokens;
                responseTokens = e.message.usage?.outputTokens;
                cachedTokens = e.message.usage?.cacheReadInputTokens;
              case final a.ContentBlockDeltaEvent e:
                switch (e.delta) {
                  case final a.TextBlockDelta d:
                    if (d.text.isNotEmpty) {
                      hasYielded = true;
                      yield TextDelta(d.text);
                    }
                  case final a.ThinkingBlockDelta d:
                    if (d.thinking.isNotEmpty) {
                      hasYielded = true;
                      yield ThinkingDelta(d.thinking);
                    }
                  default:
                    break;
                }
              case final a.MessageDeltaEvent e:
                // MessageDelta 阶段的 usage 是 output 的最终值
                responseTokens = e.usage.outputTokens;
              default:
                break;
            }
          }
          lastError = null;
          break;
        } catch (e) {
          lastError = e;
          final canRetry =
              !hasYielded && i < maxAttempts && _isTransientServerError(e);
          if (!canRetry) break;
          await Future<void>.delayed(Duration(seconds: (1 << i).clamp(2, 8)));
        }
      }
      if (lastError != null) throw _mapError(lastError);
    } finally {
      // 仅当我们没传入外部 client 时才关闭 SDK 内部 client。
      // anthropic_sdk_dart 的 endSession() 会无脑 close 我们传入的
      // bridgedClient / requestClient,否则会污染后续请求。
      if (httpClient == null && bridgedClient == null) {
        client.endSession();
      }
    }

    if (promptTokens != null || responseTokens != null) {
      yield UsageReport(
        promptTokens: promptTokens,
        responseTokens: responseTokens,
        cachedTokens: cachedTokens,
      );
    }
  }

  // ────────────────────────── 消息转换：OpenAI Chat Completions ──────────────────────────

  List<o.ChatMessage> _toOpenAiMessages(
    String? systemPrompt,
    List<AiChatMessage> history,
  ) {
    final result = <o.ChatMessage>[];
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      result.add(o.ChatMessage.system(systemPrompt));
    }
    for (final msg in history) {
      switch (msg.role) {
        case ChatRole.system:
          result.add(o.ChatMessage.system(msg.content));
        case ChatRole.user:
          final attachments = msg.attachments;
          if (attachments == null || attachments.isEmpty) {
            result.add(o.ChatMessage.user(msg.content));
          } else {
            final parts = <o.ContentPart>[
              if (msg.content.isNotEmpty) o.ContentPart.text(msg.content),
              for (final att in attachments)
                if (_openAiImagePart(att) case final p?) p,
            ];
            result.add(o.ChatMessage.user(parts));
          }
        case ChatRole.assistant:
          if (msg.content.isEmpty) continue;
          result.add(o.ChatMessage.assistant(content: msg.content));
      }
    }
    return result;
  }

  o.ContentPart? _openAiImagePart(AiChatAttachment att) {
    final remote = att.remoteUrl;
    if (remote != null && remote.isNotEmpty) {
      return o.ContentPart.imageUrl(remote);
    }
    final base64Data = att.base64Data;
    if (base64Data != null && base64Data.isNotEmpty) {
      return o.ContentPart.imageBase64(
        data: base64Data,
        mediaType: att.mimeType,
      );
    }
    final localPath = att.localPath;
    if (localPath != null && localPath.isNotEmpty) {
      final bytes = File(localPath).readAsBytesSync();
      return o.ContentPart.imageBase64(
        data: base64Encode(bytes),
        mediaType: att.mimeType,
      );
    }
    return null;
  }

  // ────────────────────────── 消息转换：OpenAI Responses ──────────────────────────

  o.ResponseInput _toResponsesInput(List<AiChatMessage> history) {
    if (history.length == 1 && history.first.role == ChatRole.user) {
      final only = history.first;
      if (only.attachments == null || only.attachments!.isEmpty) {
        return o.ResponseInput.text(only.content);
      }
    }
    final items = <o.Item>[];
    for (final msg in history) {
      switch (msg.role) {
        case ChatRole.system:
          items.add(o.MessageItem.systemText(msg.content));
        case ChatRole.user:
          final attachments = msg.attachments ?? const [];
          if (attachments.isEmpty) {
            items.add(o.MessageItem.userText(msg.content));
          } else {
            final contents = <o.InputContent>[
              if (msg.content.isNotEmpty) o.InputContent.text(msg.content),
              for (final att in attachments)
                if (_responsesImageContent(att) case final c?) c,
            ];
            items.add(o.MessageItem.user(contents));
          }
        case ChatRole.assistant:
          if (msg.content.isEmpty) continue;
          items.add(o.MessageItem.assistantText(msg.content));
      }
    }
    return o.ResponseInput.items(items);
  }

  o.InputContent? _responsesImageContent(AiChatAttachment att) {
    final remote = att.remoteUrl;
    if (remote != null && remote.isNotEmpty) {
      return o.InputContent.imageUrl(remote);
    }
    final base64Data = att.base64Data;
    if (base64Data != null && base64Data.isNotEmpty) {
      return o.InputContent.imageUrl(
        'data:${att.mimeType};base64,$base64Data',
      );
    }
    final localPath = att.localPath;
    if (localPath != null && localPath.isNotEmpty) {
      final bytes = File(localPath).readAsBytesSync();
      return o.InputContent.imageUrl(
        'data:${att.mimeType};base64,${base64Encode(bytes)}',
      );
    }
    return null;
  }

  // ────────────────────────── 消息转换：Gemini ──────────────────────────

  List<g.Content> _toGeminiContents(List<AiChatMessage> history) {
    final result = <g.Content>[];
    for (final msg in history) {
      switch (msg.role) {
        case ChatRole.system:
          // Gemini 用顶层 systemInstruction，跳过历史中的 system
          continue;
        case ChatRole.user:
          final parts = <g.Part>[
            if (msg.content.isNotEmpty) g.Part.text(msg.content),
            for (final att in msg.attachments ?? const [])
              if (_geminiImagePart(att) case final p?) p,
          ];
          if (parts.isEmpty) continue;
          result.add(g.Content(role: 'user', parts: parts));
        case ChatRole.assistant:
          if (msg.content.isEmpty) continue;
          result.add(
            g.Content(role: 'model', parts: [g.Part.text(msg.content)]),
          );
      }
    }
    return result;
  }

  g.Part? _geminiImagePart(AiChatAttachment att) {
    final base64Data = att.base64Data;
    if (base64Data != null && base64Data.isNotEmpty) {
      return g.Part.base64(base64Data, att.mimeType);
    }
    final localPath = att.localPath;
    if (localPath != null && localPath.isNotEmpty) {
      final bytes = File(localPath).readAsBytesSync();
      return g.Part.bytes(bytes, att.mimeType);
    }
    final remote = att.remoteUrl;
    if (remote != null && remote.isNotEmpty) {
      // Gemini 不支持外链图片直传，需要先用 Files API 上传，本期降级为不带
      return null;
    }
    return null;
  }

  // ────────────────────────── 消息转换：Anthropic ──────────────────────────

  List<a.Message> _toAnthropicMessages(List<AiChatMessage> history) {
    final result = <a.Message>[];
    for (final msg in history) {
      final isContext = msg.id == 'context-user' || msg.id == 'context-assistant';
      switch (msg.role) {
        case ChatRole.system:
          continue;
        case ChatRole.user:
          result.add(
            a.Message(
              role: a.MessageRole.user,
              content: _toAnthropicContent(msg, cache: isContext),
            ),
          );
        case ChatRole.assistant:
          if (msg.content.isEmpty) continue;
          result.add(
            a.Message(
              role: a.MessageRole.assistant,
              content: isContext
                  ? a.MessageContent.blocks([
                      a.Block.text(
                        text: msg.content,
                        cacheControl: const a.CacheControlEphemeral(),
                      ),
                    ])
                  : a.MessageContent.text(msg.content),
            ),
          );
      }
    }
    return result;
  }

  a.MessageContent _toAnthropicContent(AiChatMessage msg,
      {bool cache = false}) {
    final attachments = msg.attachments;
    if (attachments == null || attachments.isEmpty) {
      if (cache) {
        return a.MessageContent.blocks([
          a.Block.text(
            text: msg.content,
            cacheControl: const a.CacheControlEphemeral(),
          ),
        ]);
      }
      return a.MessageContent.text(msg.content);
    }
    final blocks = <a.Block>[
      if (msg.content.isNotEmpty)
        a.Block.text(
          text: msg.content,
          cacheControl: cache ? const a.CacheControlEphemeral() : null,
        ),
      for (final att in attachments)
        if (_anthropicImageBlock(att) case final block?) block,
    ];
    if (blocks.isEmpty) return a.MessageContent.text(msg.content);
    return a.MessageContent.blocks(blocks);
  }

  a.Block? _anthropicImageBlock(AiChatAttachment att) {
    final mediaType = _toAnthropicMediaType(att.mimeType);
    if (mediaType == null) return null;
    final remote = att.remoteUrl;
    if (remote != null && remote.isNotEmpty) {
      return a.Block.image(
        source: a.ImageBlockSource.urlImageSource(type: 'url', url: remote),
      );
    }
    final base64Data = att.base64Data;
    if (base64Data != null && base64Data.isNotEmpty) {
      return a.Block.image(
        source: a.ImageBlockSource.base64ImageSource(
          type: 'base64',
          mediaType: mediaType,
          data: base64Data,
        ),
      );
    }
    final localPath = att.localPath;
    if (localPath != null && localPath.isNotEmpty) {
      final bytes = File(localPath).readAsBytesSync();
      return a.Block.image(
        source: a.ImageBlockSource.base64ImageSource(
          type: 'base64',
          mediaType: mediaType,
          data: base64Encode(bytes),
        ),
      );
    }
    return null;
  }

  a.Base64ImageSourceMediaType? _toAnthropicMediaType(String mime) {
    switch (mime.toLowerCase()) {
      case 'image/jpeg':
      case 'image/jpg':
        return a.Base64ImageSourceMediaType.imageJpeg;
      case 'image/png':
        return a.Base64ImageSourceMediaType.imagePng;
      case 'image/gif':
        return a.Base64ImageSourceMediaType.imageGif;
      case 'image/webp':
        return a.Base64ImageSourceMediaType.imageWebp;
    }
    return null;
  }

  // ────────────────────────── 错误映射 ──────────────────────────

  Exception _mapError(Object error) {
    final l10n = AiL10n.current;
    if (error is http.ClientException || error is SocketException) {
      return Exception(l10n.networkConnectionFailed);
    }
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.transformTimeout:
          return Exception(l10n.connectionTimeoutError);
        case DioExceptionType.connectionError:
          return Exception(l10n.cannotConnectError);
        case DioExceptionType.cancel:
          return Exception(l10n.requestCancelled);
        case DioExceptionType.badCertificate:
          return Exception(l10n.sslCertificateError);
        case DioExceptionType.badResponse:
          return Exception(_statusCodeMessage(error.response?.statusCode));
        case DioExceptionType.unknown:
          return Exception(l10n.unknownNetworkError);
      }
    }
    if (error is o.OpenAIException) {
      // openai_dart 4.x 的 ApiException 体系：按 HTTP status 给具体提示
      if (error is o.AuthenticationException) {
        return Exception(l10n.apiKeyInvalidError);
      }
      if (error is o.PermissionDeniedException) {
        return Exception(l10n.noAccessPermissionError);
      }
      if (error is o.NotFoundException) {
        return Exception(l10n.endpointNotFoundError);
      }
      if (error is o.RateLimitException) {
        return Exception(l10n.tooManyRequestsError);
      }
      if (error is o.BadRequestException) {
        // 400 通常含模型/参数级别的具体原因，把 OpenAI 原始 message 透出来
        return Exception(error.message);
      }
      if (error is o.InternalServerException) {
        return Exception(_serverErrorMessage(error.statusCode, error.message));
      }
      if (error is o.RequestTimeoutException) {
        return Exception(l10n.connectionTimeoutError);
      }
      if (error is o.ConnectionException) {
        return Exception(l10n.cannotConnectError);
      }
      // 兜底：包含 status 信息的通用错误
      return Exception(error.toString());
    }
    if (error is a.AnthropicClientException) {
      return _mapAnthropicError(error);
    }
    return Exception(error.toString());
  }

  /// Anthropic SDK 把上游所有非 2xx 都简单包成 `'Unsuccessful response'`,
  /// 字符串本身没信息。这里按 status code 给出跟 OpenAI 一致的友好提示,
  /// 并把 body 里的 message 抠出来透传(代理返回的诸如「余额不足」「模型不存在」
  /// 等具体说明)。
  Exception _mapAnthropicError(a.AnthropicClientException error) {
    final l10n = AiL10n.current;
    final code = error.code;
    final upstreamMsg = _extractAnthropicErrorMessage(error.body);
    final suffix = upstreamMsg == null ? '' : ': $upstreamMsg';
    // 写到应用日志,排查「每次第一次必败重试就好」类问题时能拿到真实 status。
    // Anthropic SDK 把所有非 2xx 都包成 'Unsuccessful response',
    // 不打这条日志就看不到 code 到底是几。
    AiPackageLogger.warning(
      'AiChat',
      'anthropicError code=$code msg=${upstreamMsg ?? error.message}',
    );
    switch (code) {
      case 401:
        return Exception(l10n.apiKeyInvalidError);
      case 403:
        return Exception(l10n.noAccessPermissionError);
      case 404:
        return Exception(l10n.endpointNotFoundError);
      case 429:
        return Exception('${l10n.tooManyRequestsError}$suffix');
      case 400:
        return Exception(upstreamMsg ?? error.message);
      case 500:
      case 502:
      case 503:
      case 504:
        return Exception(_serverErrorMessage(code!, upstreamMsg));
      default:
        if (code != null) {
          return Exception('HTTP $code$suffix');
        }
        return Exception(error.message);
    }
  }

  /// 从 Anthropic 错误响应 body 里提取真正的错误说明。
  /// body 形态因代理而异:
  /// - 官方 `{"type":"error","error":{"type":"invalid_request_error","message":"..."}}`
  /// - 部分代理 `{"error":{"message":"..."}}`
  /// - 部分代理 `{"message":"..."}` / 纯字符串
  String? _extractAnthropicErrorMessage(Object? body) {
    if (body == null) return null;
    try {
      final decoded = body is String ? jsonDecode(body) : body;
      if (decoded is Map<String, dynamic>) {
        final err = decoded['error'];
        if (err is Map<String, dynamic>) {
          final msg = err['message'];
          if (msg is String && msg.isNotEmpty) return msg;
        }
        if (err is String && err.isNotEmpty) return err;
        final topMsg = decoded['message'];
        if (topMsg is String && topMsg.isNotEmpty) return topMsg;
      }
      if (decoded is String && decoded.isNotEmpty) return decoded;
    } catch (_) {
      // body 不是合法 JSON,退化用原始字符串(截断防过长)
      final raw = body.toString();
      if (raw.isEmpty) return null;
      return raw.length > 200 ? '${raw.substring(0, 200)}…' : raw;
    }
    return null;
  }

  /// 5xx 错误细分。代理服务器（one-api / aihubmix / 自建反代）转 OpenAI 时
  /// 经常返回 502/504，gpt-image 这种慢请求尤其容易触发。
  String _serverErrorMessage(int code, String? raw) {
    final l10n = AiL10n.current;
    switch (code) {
      case 502:
        return l10n.upstreamBadGatewayError;
      case 503:
        return l10n.upstreamUnavailableError;
      case 504:
        return l10n.upstreamGatewayTimeoutError;
    }
    return l10n.serverInternalError(code);
  }

  String _statusCodeMessage(int? code) {
    final l10n = AiL10n.current;
    switch (code) {
      case 401:
        return l10n.apiKeyInvalidError;
      case 403:
        return l10n.noAccessPermissionError;
      case 404:
        return l10n.endpointNotFoundError;
      case 429:
        return l10n.tooManyRequestsError;
    }
    if (code != null && code >= 500) return _serverErrorMessage(code, null);
    return l10n.requestFailed(code ?? 0);
  }

  // ────────────────────────── 图像 prompt 工具 ──────────────────────────

  /// 把话题上下文摘要拼到用户的 image prompt 之前，让生成的图与话题相关。
  /// 模板含「不要在图中嵌字」的指令避免乱出文字。
  /// 上下文为空时直接返回原 prompt。
  String _buildImagePrompt(String? contextSummary, String userPrompt) {
    final ctx = contextSummary?.trim() ?? '';
    if (ctx.isEmpty) return userPrompt;
    // 防止 context 过长爆 prompt 限额（OpenAI gpt-image 单 prompt 32000 字符
    // 上限，但太长 image 模型容易跑偏；安全截断 4000 字符）
    final trimmedCtx = ctx.length > 4000 ? '${ctx.substring(0, 4000)}…' : ctx;
    return AiL10n.current.imageContextPromptTemplate(trimmedCtx, userPrompt);
  }

  /// 把 messages 列表里**最后一条** user 消息的 content 替换成新值。
  /// 用于 Gemini image gen 路径：把拼了话题上下文的 prompt 替换进去，
  /// 不影响其他消息（含附件等）。
  List<AiChatMessage> _replaceLastUserContent(
    List<AiChatMessage> messages,
    String newContent,
  ) {
    final result = [...messages];
    for (var i = result.length - 1; i >= 0; i--) {
      if (result[i].role == ChatRole.user) {
        result[i] = result[i].copyWith(content: newContent);
        break;
      }
    }
    return result;
  }

  // ────────────────────────── URL 处理 ──────────────────────────

  String _trimTrailingSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  /// googleai_dart 的 baseUrl 不应包含 `/v1beta` 路径，它会自己加。
  String _stripGeminiVersion(String url) {
    final trimmed = _trimTrailingSlash(url);
    for (final suffix in const ['/v1beta', '/v1']) {
      if (trimmed.endsWith(suffix)) {
        return trimmed.substring(0, trimmed.length - suffix.length);
      }
    }
    return trimmed;
  }

  // ────────────────────────── ThinkingLevel 映射 ──────────────────────────

  static o.ReasoningEffort? _toOpenAiReasoningEffort(ThinkingConfig config) {
    return switch (config.level) {
      ThinkingLevel.off => null,
      ThinkingLevel.auto => o.ReasoningEffort.medium,
      ThinkingLevel.low => o.ReasoningEffort.low,
      ThinkingLevel.medium => o.ReasoningEffort.medium,
      ThinkingLevel.high => o.ReasoningEffort.high,
      ThinkingLevel.custom => o.ReasoningEffort.high,
    };
  }

  static g.ThinkingConfig? _toGeminiThinkingConfig(ThinkingConfig config) {
    if (config.level == ThinkingLevel.off) return null;
    if (config.level == ThinkingLevel.custom) {
      return g.ThinkingConfig(
        includeThoughts: true,
        thinkingBudget: config.customBudget,
      );
    }
    return g.ThinkingConfig(
      includeThoughts: true,
      thinkingLevel: switch (config.level) {
        ThinkingLevel.auto => g.ThinkingLevel.unspecified,
        ThinkingLevel.low => g.ThinkingLevel.low,
        ThinkingLevel.medium => g.ThinkingLevel.medium,
        ThinkingLevel.high => g.ThinkingLevel.high,
        _ => g.ThinkingLevel.unspecified,
      },
    );
  }

  static int? _toAnthropicBudget(ThinkingConfig config) {
    return switch (config.level) {
      ThinkingLevel.off => null,
      ThinkingLevel.auto => 8192,
      ThinkingLevel.low => 1024,
      ThinkingLevel.medium => 8192,
      ThinkingLevel.high => 32000,
      ThinkingLevel.custom => config.customBudget,
    };
  }
}

/// HTTP 层字节统计包装,把 status / content-type / 响应字节数写到 [stats]。
///
/// 用于诊断「未收到 AI 回复」时区分:
/// - status=200 respBytes=0       → 上游 200 但 body 立即关流(代理 bug)
/// - status=200 respBytes>0 sdkEvents=0 → SDK SSE 解析器跟上游格式不兼容
/// - status>=400                  → 上游真的返回了错误,但 SDK 没正确抛
///
/// 字节统计是流式累加,不缓冲响应体。
class _StatsHttpClient extends http.BaseClient {
  _StatsHttpClient(this._inner, this._stats);

  final http.Client _inner;
  final ChatStreamStats _stats;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request);
    _stats.httpStatus = response.statusCode;
    _stats.respContentType = response.headers['content-type'];
    final countedStream = response.stream.map<List<int>>((chunk) {
      _stats.respBytes += chunk.length;
      return chunk;
    });
    return http.StreamedResponse(
      countedStream,
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() {
    // 不关 _inner:它通常是 sendChatStream 传入的 effectiveClient,
    // 生命周期归调用方管理(自然结束时不应 close,会截断后续请求)。
  }
}
