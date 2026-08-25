import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/s.dart';

/// APK 资源信息
class ApkAsset {
  final String downloadUrl;
  final String? sha256Url;
  final String architecture;
  final int size;
  final String name;

  ApkAsset({
    required this.downloadUrl,
    this.sha256Url,
    required this.architecture,
    required this.size,
    required this.name,
  });

  Map<String, dynamic> toJson() => {
        'downloadUrl': downloadUrl,
        'sha256Url': sha256Url,
        'architecture': architecture,
        'size': size,
        'name': name,
      };

  factory ApkAsset.fromJson(Map<String, dynamic> json) => ApkAsset(
        downloadUrl: json['downloadUrl'] as String,
        sha256Url: json['sha256Url'] as String?,
        architecture: json['architecture'] as String,
        size: json['size'] as int,
        name: json['name'] as String,
      );
}

/// 更新信息模型
class UpdateInfo {
  final String currentVersion;
  final String remoteVersion;
  final String releaseUrl;
  final String releaseNotes;
  final bool hasUpdate;
  final List<ApkAsset> apkAssets;

  UpdateInfo({
    required this.currentVersion,
    required this.remoteVersion,
    required this.releaseUrl,
    required this.releaseNotes,
    required this.hasUpdate,
    this.apkAssets = const [],
  });

  Map<String, dynamic> toJson() => {
        'currentVersion': currentVersion,
        'remoteVersion': remoteVersion,
        'releaseUrl': releaseUrl,
        'releaseNotes': releaseNotes,
        'hasUpdate': hasUpdate,
        'apkAssets': apkAssets.map((e) => e.toJson()).toList(),
      };

  factory UpdateInfo.fromJson(Map<String, dynamic> json) => UpdateInfo(
        currentVersion: json['currentVersion'] as String,
        remoteVersion: json['remoteVersion'] as String,
        releaseUrl: json['releaseUrl'] as String,
        releaseNotes: json['releaseNotes'] as String,
        hasUpdate: json['hasUpdate'] as bool,
        apkAssets: (json['apkAssets'] as List<dynamic>?)
                ?.map((e) => ApkAsset.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
      );
}

/// 应用更新检查服务
class UpdateService {
  static const String _repository = 'Lingyan000/fluxdo';
  static const String _apiUrl =
      'https://api.github.com/repos/$_repository/releases/latest';
  static const String _autoCheckUpdateKey = 'auto_check_update';
  static const String _githubProxyKey = 'github_proxy_url';
  static const String _cacheKey = 'update_cache';
  static const String _cacheTimeKey = 'update_cache_time';
  static const String _etagKey = 'update_etag';

  // 缓存有效期（1 小时）
  static const Duration _cacheValidDuration = Duration(hours: 1);

  final Dio _dio;
  final SharedPreferences? _prefs;

  UpdateService({Dio? dio, SharedPreferences? prefs})
      : _dio = dio ?? Dio(),
        _prefs = prefs;

  /// 获取自动检查更新设置
  bool getAutoCheckUpdate() {
    return _prefs?.getBool(_autoCheckUpdateKey) ?? true;
  }

  /// 获取自定义 GitHub 反代前缀（空字符串表示未配置，直连）
  static Future<String> getGithubProxy() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_githubProxyKey) ?? '';
  }

  /// 保存自定义 GitHub 反代前缀，传空字符串表示清除
  static Future<void> setGithubProxy(String url) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = normalizeGithubProxy(url);
    if (normalized.isEmpty) {
      await prefs.remove(_githubProxyKey);
    } else {
      await prefs.setString(_githubProxyKey, normalized);
    }
  }

  /// 规范化反代前缀：去空白、补末尾斜杠
  static String normalizeGithubProxy(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return '';
    if (!url.endsWith('/')) url = '$url/';
    return url;
  }

  /// 校验反代前缀是否为合法的 http(s) 地址
  static bool isValidGithubProxy(String raw) {
    final uri = Uri.tryParse(normalizeGithubProxy(raw));
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  /// 将反代前缀拼接到原始下载链接前（gh-proxy 系通用格式：前缀 + 完整原始 URL）
  static String applyGithubProxy(String url, String proxy) {
    final prefix = normalizeGithubProxy(proxy);
    if (prefix.isEmpty) return url;
    // 已经带前缀的链接不重复拼接
    if (url.startsWith(prefix)) return url;
    return '$prefix$url';
  }

  /// 设置自动检查更新
  Future<void> setAutoCheckUpdate(bool value) async {
    await _prefs?.setBool(_autoCheckUpdateKey, value);
  }

  /// 获取当前应用版本号
  Future<String> getCurrentVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    return packageInfo.version;
  }

  /// 获取设备 CPU 架构
  ///
  /// 返回 GitHub Release 中使用的架构名称：
  /// - arm64-v8a
  /// - armeabi-v7a
  /// - x86_64
  Future<String?> getDeviceArchitecture() async {
    if (!Platform.isAndroid) return null;

    try {
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = await deviceInfo.androidInfo;
      final abis = androidInfo.supportedAbis;

      if (abis.isEmpty) return null;

      // 按优先级匹配架构
      final architectureMap = {
        'arm64-v8a': 'arm64-v8a',
        'armeabi-v7a': 'armeabi-v7a',
        'x86_64': 'x86_64',
        'x86': 'x86_64', // x86 设备通常兼容 x86_64
      };

      for (final abi in abis) {
        if (architectureMap.containsKey(abi)) {
          return architectureMap[abi];
        }
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  /// 自动检查更新（应用启动时调用）
  ///
  /// 如果设置中禁用了自动检查，则不执行
  /// 返回 [UpdateInfo] 如果有更新，否则返回 null
  Future<UpdateInfo?> autoCheckUpdate() async {
    if (!getAutoCheckUpdate()) return null;

    try {
      // 自动检查使用缓存
      final updateInfo = await checkForUpdate(useCache: true);
      return updateInfo.hasUpdate ? updateInfo : null;
    } catch (e) {
      // 自动检查失败时静默处理
      return null;
    }
  }

  /// 检查更新
  ///
  /// [useCache] 是否使用缓存，默认 false（手动检查强制刷新）
  /// 返回 [UpdateInfo] 如果检查成功
  /// 抛出异常如果检查失败
  Future<UpdateInfo> checkForUpdate({bool useCache = false}) async {
    final currentVersion = await getCurrentVersion();

    // 检查缓存是否有效
    if (useCache && _prefs != null) {
      final cachedInfo = _getCachedUpdateInfo(currentVersion);
      if (cachedInfo != null) {
        return cachedInfo;
      }
    }

    // 获取存储的 ETag
    final storedEtag = _prefs?.getString(_etagKey);

    try {
      final response = await _dio.get(
        _apiUrl,
        options: Options(
          responseType: ResponseType.json,
          headers: {
            'User-Agent': 'FluxDO-App',
            'Accept': 'application/vnd.github.v3+json',
            if (storedEtag != null) 'If-None-Match': storedEtag,
          },
          validateStatus: (status) =>
              status != null && (status == 200 || status == 304),
        ),
      );

      // 304 Not Modified - 使用缓存
      if (response.statusCode == 304) {
        final cachedInfo =
            _getCachedUpdateInfo(currentVersion, ignoreExpiry: true);
        if (cachedInfo != null) {
          // 更新缓存时间
          await _prefs?.setInt(
              _cacheTimeKey, DateTime.now().millisecondsSinceEpoch);
          return cachedInfo;
        }
      }

      // 保存 ETag
      final newEtag = response.headers.value('etag');
      if (newEtag != null) {
        await _prefs?.setString(_etagKey, newEtag);
      }

      final data = response.data as Map<String, dynamic>;
      final updateInfo = _parseUpdateInfo(data, currentVersion);

      // 缓存结果
      await _cacheUpdateInfo(updateInfo);

      return updateInfo;
    } on DioException catch (e) {
      // 403/429 速率限制时尝试使用缓存
      if (e.response?.statusCode == 403 || e.response?.statusCode == 429) {
        final cachedInfo =
            _getCachedUpdateInfo(currentVersion, ignoreExpiry: true);
        if (cachedInfo != null) {
          return cachedInfo;
        }
        throw Exception(S.current.update_rateLimited);
      }
      rethrow;
    }
  }

  /// 从缓存获取更新信息
  UpdateInfo? _getCachedUpdateInfo(String currentVersion,
      {bool ignoreExpiry = false}) {
    if (_prefs == null) return null;

    final cacheJson = _prefs.getString(_cacheKey);
    final cacheTime = _prefs.getInt(_cacheTimeKey);

    if (cacheJson == null || cacheTime == null) return null;

    // 检查缓存是否过期
    if (!ignoreExpiry) {
      final cacheDate = DateTime.fromMillisecondsSinceEpoch(cacheTime);
      if (DateTime.now().difference(cacheDate) > _cacheValidDuration) {
        return null;
      }
    }

    try {
      final cached =
          UpdateInfo.fromJson(jsonDecode(cacheJson) as Map<String, dynamic>);

      // 重新计算 hasUpdate（因为当前版本可能已变化）
      final hasUpdate = _compareVersions(cached.remoteVersion, currentVersion) > 0;

      return UpdateInfo(
        currentVersion: currentVersion,
        remoteVersion: cached.remoteVersion,
        releaseUrl: cached.releaseUrl,
        releaseNotes: cached.releaseNotes,
        hasUpdate: hasUpdate,
        apkAssets: cached.apkAssets,
      );
    } catch (e) {
      return null;
    }
  }

  /// 缓存更新信息
  Future<void> _cacheUpdateInfo(UpdateInfo info) async {
    if (_prefs == null) return;

    await _prefs.setString(_cacheKey, jsonEncode(info.toJson()));
    await _prefs.setInt(_cacheTimeKey, DateTime.now().millisecondsSinceEpoch);
  }

  /// 解析更新信息
  UpdateInfo _parseUpdateInfo(Map<String, dynamic> data, String currentVersion) {
    final remoteVersion = (data['tag_name'] as String).replaceAll('v', '');
    final releaseUrl = data['html_url'] as String;
    var releaseNotes = data['body'] as String? ?? '';

    // 移除 release_template.md 的内容
    // 模板通常以 <div align=center> 开始用于显示下载徽章
    const templateMarker = '<div align=center>';
    final markerIndex = releaseNotes.indexOf(templateMarker);
    if (markerIndex != -1) {
      releaseNotes = releaseNotes.substring(0, markerIndex).trim();
    }

    final hasUpdate = _compareVersions(remoteVersion, currentVersion) > 0;

    // 解析 APK 资源
    final assets = data['assets'] as List<dynamic>? ?? [];
    final apkAssets = _parseApkAssets(assets);

    return UpdateInfo(
      currentVersion: currentVersion,
      remoteVersion: remoteVersion,
      releaseUrl: releaseUrl,
      releaseNotes: releaseNotes,
      hasUpdate: hasUpdate,
      apkAssets: apkAssets,
    );
  }

  /// 解析 GitHub Release 中的 APK 资源
  List<ApkAsset> _parseApkAssets(List<dynamic> assets) {
    final apkAssets = <ApkAsset>[];
    final sha256Map = <String, String>{};

    // 首先收集所有 sha256 文件的下载链接
    for (final asset in assets) {
      final name = asset['name'] as String? ?? '';
      if (name.endsWith('.sha256')) {
        final apkName = name.replaceAll('.sha256', '');
        sha256Map[apkName] = asset['browser_download_url'] as String;
      }
    }

    // 然后解析 APK 文件
    for (final asset in assets) {
      final name = asset['name'] as String? ?? '';
      if (!name.endsWith('.apk')) continue;

      // 从文件名中提取架构
      // 例如：fluxdo-0.1.11-arm64-v8a.apk
      final architecture = _extractArchitecture(name);
      if (architecture == null) continue;

      apkAssets.add(ApkAsset(
        downloadUrl: asset['browser_download_url'] as String,
        sha256Url: sha256Map[name],
        architecture: architecture,
        size: asset['size'] as int? ?? 0,
        name: name,
      ));
    }

    return apkAssets;
  }

  /// 从 APK 文件名中提取架构
  String? _extractArchitecture(String fileName) {
    const architectures = ['arm64-v8a', 'armeabi-v7a', 'x86_64'];
    for (final arch in architectures) {
      if (fileName.contains(arch)) {
        return arch;
      }
    }
    return null;
  }

  /// 获取匹配当前设备架构的 APK 资源
  Future<ApkAsset?> getMatchingApkAsset(UpdateInfo updateInfo) async {
    final architecture = await getDeviceArchitecture();
    if (architecture == null) return null;

    for (final asset in updateInfo.apkAssets) {
      if (asset.architecture == architecture) {
        return asset;
      }
    }

    return null;
  }

  /// 比较两个版本号
  ///
  /// 返回值:
  /// - 正数: v1 > v2
  /// - 0: v1 == v2
  /// - 负数: v1 < v2
  int _compareVersions(String v1, String v2) {
    final parts1 = v1.split('.').map(int.parse).toList();
    final parts2 = v2.split('.').map(int.parse).toList();

    for (int i = 0; i < 3; i++) {
      final p1 = i < parts1.length ? parts1[i] : 0;
      final p2 = i < parts2.length ? parts2[i] : 0;
      if (p1 != p2) return p1.compareTo(p2);
    }
    return 0;
  }
}
