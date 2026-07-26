/// 音视频改名上传公共链路(社区「媒体上传」脚本思路的 App 端实现):
/// 选文件 → 4MB 前置检查 → `.xz` 改名上传(绕站点扩展名白名单)→
/// 生成 `<audio>/<video>` HTML 标签文本插 raw(cook 原样保留)。
///
/// 播放兼容:标签 `type` 写原文件真实 MIME(网页端浏览器/本 app
/// AVFoundation 按它选解码器);`src` 用 `/uploads/short-url/<b62>.xz`
/// 相对路径(Rails 动态路由 302 到真实存储,CDN 域名下会 404)。
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:mime/mime.dart' show lookupMimeType;
import 'package:path_provider/path_provider.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../services/app_error_handler.dart';
import '../../services/discourse/discourse_service.dart';
import '../../services/media_transcoder/media_compressor.dart';
import '../../services/media_transcoder/media_transcoder.dart';

/// `upload://<base62>.<ext>` → `/uploads/short-url/<base62>.xz` 播放路径。
String mediaShortUrlToXzPath(String shortUrl) {
  if (shortUrl.startsWith('upload://')) {
    final token = shortUrl.substring('upload://'.length);
    final dot = token.lastIndexOf('.');
    final stem = dot > 0 ? token.substring(0, dot) : token;
    return '/uploads/short-url/$stem.xz';
  }
  // 兜底:服务端未返回短链(直返 url)时仅换扩展
  final dot = shortUrl.lastIndexOf('.');
  return dot > 0 ? '${shortUrl.substring(0, dot)}.xz' : shortUrl;
}

/// 生成插入 raw 的媒体 HTML 标签。[voice] = 语音消息(包 `[wrap=voice]`
/// 壳,本 app 渲染语音条,网页端无样式影响)。
String buildMediaTag({
  required bool isAudio,
  required String srcPath,
  required String mime,
  bool voice = false,
}) {
  if (isAudio) {
    final tag =
        '<audio controls>\n  <source src="$srcPath" type="$mime">\n</audio>';
    return voice ? '[wrap=voice]\n$tag\n[/wrap]' : tag;
  }
  return '<video width="640" height="360" controls>\n'
      '  <source src="$srcPath" type="$mime">\n'
      '</video>';
}

/// 已有本地媒体文件 → 上传 → 标签文本。失败弹 SnackBar 并返回 null
/// (4MB 超限的提示文案来自 [uploadMediaAsXz] 的异常信息)。
Future<String?> uploadMediaFileAsTag(
  BuildContext context, {
  required String path,
  required String name,
  required bool isAudio,
  bool voice = false,
}) async {
  try {
    var uploadPath = path;
    var uploadName = name;
    // 超 4MB 先压缩(原生转码,进度对话框可取消);压缩产物换用
    // 新文件名算 MIME(m4a/mp4)。取消/失败返回 null(已提示)。
    final size = await File(path).length();
    if (size >= kMaxMediaBytes) {
      if (!context.mounted) return null;
      final compressed = await compressMediaWithDialog(
        context,
        path: path,
        isAudio: isAudio,
      );
      if (compressed == null) return null;
      uploadPath = compressed;
      uploadName = compressed.split(Platform.pathSeparator).last;
    }
    final mime = lookupMimeType(uploadName) ??
        (isAudio ? 'audio/mpeg' : 'video/mp4');
    final result = await DiscourseService().uploadMediaAsXz(uploadPath);
    return buildMediaTag(
      isAudio: isAudio,
      srcPath: mediaShortUrlToXzPath(result.shortUrl),
      mime: mime,
      voice: voice,
    );
  } catch (e, s) {
    if (context.mounted) {
      final msg = e is Exception
          ? e.toString().replaceFirst('Exception: ', '')
          : '媒体上传失败';
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(msg)));
    } else {
      AppErrorHandler.handleUnexpected(e, s);
    }
    return null;
  }
}

/// 选择音/视频文件并上传,返回标签文本;取消/失败返回 null。
Future<String?> pickAndUploadMediaTag(
  BuildContext context, {
  required bool isAudio,
}) async {
  final picked = await FilePicker.platform.pickFiles(
    type: isAudio ? FileType.audio : FileType.video,
  );
  final file = picked?.files.single;
  final path = file?.path;
  if (file == null || path == null || !context.mounted) return null;
  return uploadMediaFileAsTag(
    context,
    path: path,
    name: file.name,
    isAudio: isAudio,
  );
}

/// 超限媒体压缩(模态进度对话框,可取消)。返回压缩后文件路径;
/// null = 取消 / 失败 / 平台不支持(失败已 SnackBar 提示)。
Future<String?> compressMediaWithDialog(
  BuildContext context, {
  required String path,
  required bool isAudio,
}) async {
  final transcoder = MediaTranscoder.forCurrentPlatform();
  if (transcoder == null) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('当前平台不支持压缩,请压到 4MB 内再上传')),
    );
    return null;
  }
  final tempDir = await getTemporaryDirectory();
  if (!context.mounted) return null;

  final status = ValueNotifier<String>('准备压缩…');
  final resultFuture = compressMediaToFit(
    transcoder,
    path,
    isAudio: isAudio,
    outputDir: tempDir.path,
    onStatus: (s) => status.value = s,
  );

  final result = await showDialog<CompressResult>(
    context: context,
    barrierDismissible: false,
    builder: (dialogCtx) => _CompressProgressDialog(
      transcoder: transcoder,
      status: status,
      resultFuture: resultFuture,
    ),
  );
  status.dispose();
  // 对话框被意外关闭(极端路径)也要等结果收尾
  final r = result ?? await resultFuture;
  if (r.isOk) return r.path;
  if (!r.cancelled && r.error != null && context.mounted) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(r.error!)));
  }
  return null;
}

class _CompressProgressDialog extends StatefulWidget {
  const _CompressProgressDialog({
    required this.transcoder,
    required this.status,
    required this.resultFuture,
  });

  final MediaTranscoder transcoder;
  final ValueNotifier<String> status;
  final Future<CompressResult> resultFuture;

  @override
  State<_CompressProgressDialog> createState() =>
      _CompressProgressDialogState();
}

class _CompressProgressDialogState extends State<_CompressProgressDialog> {
  Timer? _timer;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 300), (_) async {
      final p = await widget.transcoder.progress();
      if (mounted) setState(() => _progress = p);
    });
    widget.resultFuture.then((r) {
      if (mounted) Navigator.of(context).pop(r);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('压缩媒体'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ValueListenableBuilder<String>(
            valueListenable: widget.status,
            builder: (_, s, _) => Align(
              alignment: Alignment.centerLeft,
              child: Text(s, style: Theme.of(context).textTheme.bodySmall),
            ),
          ),
          const SizedBox(height: 12),
          M3eLinearProgress(
            value: _progress <= 0 ? null : _progress.clamp(0.0, 1.0),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => widget.transcoder.cancel(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
