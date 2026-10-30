import '../preloaded_data_service.dart';

/// 音视频按附件规则校验，不能用分片大小代替站点总大小上限。
abstract final class MediaUploadLimits {
  static int? fromSettings(Map<String, dynamic>? settings) {
    final raw = settings?['max_attachment_size_kb'];
    final kb = raw is num ? raw.toInt() : int.tryParse('$raw');
    return kb != null && kb > 0 ? kb * 1024 : null;
  }

  static Future<int?> load() async =>
      fromSettings(await PreloadedDataService().getSiteSettings());
}
