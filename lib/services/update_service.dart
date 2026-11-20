import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';

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

/// Windows Inno Setup 安装包。digest 来自 GitHub API，优先于镜像校验文件。
class WindowsUpdateAsset {
  final String name;
  final String downloadUrl;
  final String? sha256Url;
  final String? sha256;
  final int size;

  const WindowsUpdateAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
    this.sha256Url,
    this.sha256,
  });

  bool get canVerify => sha256 != null || sha256Url != null;

  Map<String, dynamic> toJson() => {
    'name': name,
    'downloadUrl': downloadUrl,
    'size': size,
    'sha256Url': sha256Url,
    'sha256': sha256,
  };

  factory WindowsUpdateAsset.fromJson(Map<String, dynamic> json) =>
      WindowsUpdateAsset(
        name: json['name'] as String,
        downloadUrl: json['downloadUrl'] as String,
        size: json['size'] as int,
        sha256Url: json['sha256Url'] as String?,
        sha256: json['sha256'] as String?,
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
  final WindowsUpdateAsset? windowsAsset;

  UpdateInfo({
    required this.currentVersion,
    required this.remoteVersion,
    required this.releaseUrl,
    required this.releaseNotes,
    required this.hasUpdate,
    this.apkAssets = const [],
    this.windowsAsset,
  });

  Map<String, dynamic> toJson() => {
    'currentVersion': currentVersion,
    'remoteVersion': remoteVersion,
    'releaseUrl': releaseUrl,
    'releaseNotes': releaseNotes,
    'hasUpdate': hasUpdate,
    'apkAssets': apkAssets.map((e) => e.toJson()).toList(),
    'windowsAsset': windowsAsset?.toJson(),
  };

  factory UpdateInfo.fromJson(Map<String, dynamic> json) => UpdateInfo(
    currentVersion: json['currentVersion'] as String,
    remoteVersion: json['remoteVersion'] as String,
    releaseUrl: json['releaseUrl'] as String,
    releaseNotes: json['releaseNotes'] as String,
    hasUpdate: json['hasUpdate'] as bool,
    apkAssets:
        (json['apkAssets'] as List<dynamic>?)
            ?.map((e) => ApkAsset.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [],
    windowsAsset: json['windowsAsset'] == null
        ? null
        : WindowsUpdateAsset.fromJson(
            json['windowsAsset'] as Map<String, dynamic>,
          ),
  );
}

/// 应用更新检查服务
class UpdateService {
  static const String _repository = 'Lingyan000/fluxdo';
  static const String _apiUrl =
      'https://api.github.com/repos/$_repository/releases';
  static const String _autoCheckUpdateKey = 'auto_check_update';
  static const String _checkBetaUpdatesKey = 'check_beta_updates';
  static const String _githubProxyKey = 'github_proxy_url';
  static const String _cacheKey = 'update_cache';
  static const String _betaCacheKey = 'update_cache_with_beta';
  static const String _releaseVersion = String.fromEnvironment(
    'FLUXDO_RELEASE_VERSION',
  );

  // 缓存有效期（1 小时）
  static const Duration _cacheValidDuration = Duration(hours: 1);

  final Dio _dio;
  final SharedPreferences? _prefs;

  UpdateService({Dio? dio, this._prefs}) : _dio = dio ?? Dio();

  /// 获取自动检查更新设置
  bool getAutoCheckUpdate() {
    return _prefs?.getBool(_autoCheckUpdateKey) ?? true;
  }

  Future<bool> getCheckBetaUpdates() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    final version = _tryParseVersion(await getCurrentVersion());
    return _getOrSetCheckBetaUpdates(prefs, version?.isPreRelease ?? false);
  }

  Future<void> setCheckBetaUpdates(bool value) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await prefs.setBool(_checkBetaUpdatesKey, value);
  }

  Future<bool> _getOrSetCheckBetaUpdates(
    SharedPreferences prefs,
    bool defaultValue,
  ) async {
    final saved = prefs.getBool(_checkBetaUpdatesKey);
    if (saved != null) return saved;
    await prefs.setBool(_checkBetaUpdatesKey, defaultValue);
    return defaultValue;
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
    // Apple 平台的系统版本号会移除预发布标识，发版构建注入完整版本。
    if (_releaseVersion.isNotEmpty) return _releaseVersion;
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
    final current = _parseVersion(currentVersion);
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    final includeBeta = await _getOrSetCheckBetaUpdates(
      prefs,
      current.isPreRelease,
    );
    final cacheKey = includeBeta ? _betaCacheKey : _cacheKey;
    final cache = _readCache(prefs, cacheKey, currentVersion, current);
    // Beta 的 Release 会被后续版本复用，旧下载地址需要向服务器重新验证。
    final canReuseCache =
        cache != null && !_parseVersion(cache.info.remoteVersion).isPreRelease;

    if (useCache &&
        canReuseCache &&
        DateTime.now().difference(cache.checkedAt) <= _cacheValidDuration) {
      return cache.info;
    }

    try {
      final response = await _fetchReleases(
        includeBeta: includeBeta,
        etag: cache?.etag,
      );

      if (response.statusCode == 304) {
        await _writeCache(prefs, cacheKey, cache!.info, cache.etag);
        return cache.info;
      }

      final release = includeBeta
          ? await _findLatestRelease(response)
          : response.data as Map<String, dynamic>;
      if (release == null) {
        return UpdateInfo(
          currentVersion: currentVersion,
          remoteVersion: currentVersion,
          releaseUrl: 'https://github.com/$_repository/releases',
          releaseNotes: '',
          hasUpdate: false,
        );
      }

      final updateInfo = _parseUpdateInfo(release, currentVersion, current);
      // 多页结果不能只用第一页的 ETag 验证。
      final etag = _hasNextPage(response)
          ? null
          : response.headers.value('etag');
      await _writeCache(prefs, cacheKey, updateInfo, etag);
      return updateInfo;
    } on DioException catch (e) {
      // 403/429 速率限制时尝试使用缓存
      if (e.response?.statusCode == 403 || e.response?.statusCode == 429) {
        if (canReuseCache) return cache.info;
        throw Exception(t.update_rateLimited);
      }
      rethrow;
    }
  }

  Future<Response<dynamic>> _fetchReleases({
    required bool includeBeta,
    int page = 1,
    String? etag,
  }) {
    return _dio.get(
      includeBeta ? _apiUrl : '$_apiUrl/latest',
      queryParameters: includeBeta ? {'per_page': 100, 'page': page} : null,
      options: Options(
        responseType: ResponseType.json,
        headers: {
          'User-Agent': 'FluxDO-App',
          'Accept': 'application/vnd.github.v3+json',
          'If-None-Match': ?etag,
        },
        validateStatus: (status) =>
            status == 200 || (etag != null && status == 304),
      ),
    );
  }

  bool _hasNextPage(Response<dynamic> response) =>
      response.headers.value('link')?.contains('rel="next"') ?? false;

  Future<Map<String, dynamic>?> _findLatestRelease(
    Response<dynamic> firstPage,
  ) async {
    var response = firstPage;
    var page = 1;
    Map<String, dynamic>? latest;
    Version? latestVersion;

    while (true) {
      for (final release
          in (response.data as List).cast<Map<String, dynamic>>()) {
        final tag = release['tag_name'];
        if (release['draft'] == true || tag is! String) continue;

        // Releases 中也有 Flatpak 预构建层等非应用产物。
        final version = _tryParseVersion(tag);
        if (version == null) continue;
        if (latestVersion == null || version > latestVersion) {
          latest = release;
          latestVersion = version;
        }
      }
      if (!_hasNextPage(response)) return latest;
      response = await _fetchReleases(includeBeta: true, page: ++page);
    }
  }

  ({UpdateInfo info, DateTime checkedAt, String? etag})? _readCache(
    SharedPreferences prefs,
    String cacheKey,
    String currentVersion,
    Version current,
  ) {
    final cacheJson = prefs.getString(cacheKey);
    if (cacheJson == null) return null;
    try {
      final json = jsonDecode(cacheJson) as Map<String, dynamic>;
      final checkedAt =
          json['checkedAt'] as int? ??
          (cacheKey == _cacheKey ? prefs.getInt('update_cache_time') : null);
      if (checkedAt == null) return null;
      final cached = UpdateInfo.fromJson(json);
      return (
        info: UpdateInfo(
          currentVersion: currentVersion,
          remoteVersion: cached.remoteVersion,
          releaseUrl: cached.releaseUrl,
          releaseNotes: cached.releaseNotes,
          hasUpdate: _parseVersion(cached.remoteVersion) > current,
          apkAssets: cached.apkAssets,
          windowsAsset: cached.windowsAsset,
        ),
        checkedAt: DateTime.fromMillisecondsSinceEpoch(checkedAt),
        etag: json['etag'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  /// 缓存更新信息
  Future<void> _writeCache(
    SharedPreferences prefs,
    String cacheKey,
    UpdateInfo info,
    String? etag,
  ) async {
    await prefs.setString(
      cacheKey,
      jsonEncode({
        ...info.toJson(),
        'checkedAt': DateTime.now().millisecondsSinceEpoch,
        'etag': etag,
      }),
    );
  }

  /// 解析更新信息
  UpdateInfo _parseUpdateInfo(
    Map<String, dynamic> data,
    String currentVersion,
    Version current,
  ) {
    final remoteVersion = _withoutTagPrefix(data['tag_name'] as String);
    final releaseUrl = data['html_url'] as String;
    var releaseNotes = data['body'] as String? ?? '';

    // 移除 release_template.md 的内容
    // 模板通常以 <div align=center> 开始用于显示下载徽章
    const templateMarker = '<div align=center>';
    final markerIndex = releaseNotes.indexOf(templateMarker);
    if (markerIndex != -1) {
      releaseNotes = releaseNotes.substring(0, markerIndex).trim();
    }

    final hasUpdate = _parseVersion(remoteVersion) > current;

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
      windowsAsset: _parseWindowsAsset(assets),
    );
  }

  WindowsUpdateAsset? _parseWindowsAsset(List<dynamic> assets) {
    const installerName = 'fluxdo-windows-x86_64-setup.exe';
    Map<String, dynamic>? installer;
    String? checksumUrl;
    for (final value in assets) {
      final asset = value as Map<String, dynamic>;
      if (asset['name'] == installerName) installer = asset;
      if (asset['name'] == '$installerName.sha256') {
        checksumUrl = asset['browser_download_url'] as String?;
      }
    }
    if (installer == null) return null;
    final digest = installer['digest'] as String?;
    final match = RegExp(r'^sha256:([a-fA-F0-9]{64})$')
        .firstMatch(digest ?? '');
    return WindowsUpdateAsset(
      name: installerName,
      downloadUrl: installer['browser_download_url'] as String,
      size: installer['size'] as int? ?? 0,
      sha256Url: checksumUrl,
      sha256: match?.group(1)?.toLowerCase(),
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

      apkAssets.add(
        ApkAsset(
          downloadUrl: asset['browser_download_url'] as String,
          sha256Url: sha256Map[name],
          architecture: architecture,
          size: asset['size'] as int? ?? 0,
          name: name,
        ),
      );
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

  static String _withoutTagPrefix(String version) =>
      version.startsWith('v') ? version.substring(1) : version;

  static Version _parseVersion(String version) {
    // pub_semver 默认也比较构建元数据；更新顺序只比较核心版本和预发布标识。
    final parsed = Version.parse(_withoutTagPrefix(version));
    if (parsed.build.isEmpty) return parsed;
    return Version(
      parsed.major,
      parsed.minor,
      parsed.patch,
      pre: parsed.preRelease.isEmpty ? null : parsed.preRelease.join('.'),
    );
  }

  static Version? _tryParseVersion(String tag) {
    try {
      return _parseVersion(tag);
    } on FormatException {
      return null;
    }
  }
}
