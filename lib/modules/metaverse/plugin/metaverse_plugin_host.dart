import 'metaverse_event_stream.dart';
import 'metaverse_task.dart';
import 'metaverse_ui_validator.dart';
import 'metaverse_component_contract.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/widgets.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';
import 'package:rfw/rfw.dart';

import '../../../services/log/log_policy.dart';
import '../../../services/log/log_writer.dart';
import '../../../utils/link_launcher.dart' show LinkOpenMode;

import 'metaverse_plugin_installer.dart';
import 'metaverse_plugin_manifest.dart';
import 'metaverse_plugin_permission.dart';
import 'metaverse_plugin_network.dart';
import 'metaverse_plugin_store.dart';
import 'metaverse_credential_manager.dart';
import 'metaverse_plugin_capabilities.dart';
import 'metaverse_forum_request.dart';
import 'ui/metaverse_widget_library.dart';

/// 宿主里需要界面或应用状态才能完成的操作，由上层（provider 层）实现。
abstract class MetaversePluginHostDelegate {
  Map<String, Object?> environment() => const {'locale':'zh', 'platform':'unknown'};
  Future<void> prepareStart() async {}
  void onHealthy() {}
  void onStartFailed() {}
  void onShutdown() {}
  bool dismissModal(BuildContext context, String page) => false;
  Future<bool> requestPermissions(BuildContext context, Set<MetaversePluginPermission> missing,
      {required void Function() checkActive}) async => false;
  Future<bool> confirmBackground(BuildContext context, String task) async => false;
  Future<bool> confirmNotifications(BuildContext context) async => false;
  Future<Object?> taskOperation(String method, Map<String, Object?> params, {required void Function() checkActive}) =>
      Future.error(const MetaversePluginCallException('task_unavailable'));

  Future<Object?> readForum(MetaverseForumRequest request, {required void Function() checkActive}) =>
      Future.error(const MetaversePluginCallException('forum_unavailable'));
  Future<void> openForum(BuildContext context, MetaverseForumDestination destination) =>
      Future.error(const MetaversePluginCallException('forum_unavailable'));
  int? currentAccountId() => null;

  Future<bool> confirm(BuildContext context, Map<String, Object?> options) =>
      Future.error(const MetaversePluginCallException('confirmation_unavailable'));

  Future<String?> authorizeConnect(BuildContext context, Uri authorization) =>
      Future.error(const MetaversePluginCallException('connect_unavailable'));
  Future<bool> requestCredential(BuildContext context, String name) =>
      Future.error(
        const MetaversePluginCallException('credential_input_unavailable'),
      );

  Future<Object?> requestPayment(
    BuildContext context, {
    required MetaversePaymentProvider provider,
    required Uri url,
    required String reference,
    required Object amount,
  }) => Future.error(const MetaversePluginCallException('payment_unavailable'));

  /// 当前登录用户名，未登录为 null。
  String? currentUsername();

  /// 向用户索取凭证并保存。返回 false 表示用户取消。
  Future<bool> requestAuth(
    BuildContext context,
    MetaversePluginManifest manifest,
  );

  /// 打开插件的一个页面（不等待页面关闭）。
  void openPage(
    BuildContext context,
    MetaversePluginManifest manifest,
    String page,
    Map<String, Object?> params,
  );

  void replacePage(BuildContext context, MetaversePluginManifest manifest,
      String page, Map<String, Object?> params) =>
      throw const MetaversePluginCallException('navigation_replace_unavailable');

  /// 打开外部链接；是否需要离站确认由应用的链接安全策略决定。
  Future<void> openUrl(BuildContext context, Uri url);

  /// 打开内置浏览器页面，浏览器会话由宿主管理。
  Future<void> openWebSession(BuildContext context, Uri url);

  Future<void> openBrowser(BuildContext context, Uri url, LinkOpenMode mode) =>
      mode == LinkOpenMode.inApp
          ? openWebSession(context, url)
          : openUrl(context, url);

  void toast(String message, String type);

  /// 插件脚本失效，需要挂起。
  void onSuspended(String pluginId, String reason);
}

/// 一个已安装插件的运行实例：按需启动脚本，并实现脚本能调用的全部宿主能力。
///
/// 这里是权限边界：脚本发来的每个调用都按清单声明重新检查，不信任任何
/// 来自脚本的断言。
class MetaversePluginHost implements MetaversePluginBridge {
  MetaversePluginHost({
    required this.manifest,
    required this._store,
    required this._network,
    this.dohNetwork,
    this.canSuggestDoh,
    required this._engineFactory,
    required this._delegate,
    this.idleTimeout = const Duration(seconds: 30),
    this._clock = DateTime.now,
    this.codeLoader,
    this.imageCacheSource,
    this._blockedPermissions = const {},
  });

  static const _maxStorageKey = 128;
  static const _maxToast = 200;
  static const _toastInterval = Duration(seconds: 1);

  /// 用户操作之后多久内，脚本可以发起跳转、打开链接、索取授权。
  ///
  /// 和浏览器的"用户激活"是同一个思路：这些操作会把用户带离当前界面，只能
  /// 是点击的结果，不能由脚本在加载时或定时器里自行触发。窗口留得比较宽，
  /// 因为点击之后常常要先等一次网络请求。
  static const activationWindow = Duration(seconds: 10);

  final MetaversePluginManifest manifest;
  /// 只有正式安装的来源可使用持久图片缓存；开发预览不能读写正式数据。
  final String? imageCacheSource;
  Set<MetaversePluginPermission> _blockedPermissions;
  Set<MetaversePluginPermission> get blockedPermissions => _blockedPermissions;

  Future<bool> _askPermissions(Set<MetaversePluginPermission> missing,
      void Function() checkActive) {
    final source = _activatedSurface;
    void checkRequest() {
      checkActive();
      if (_retired || source == null || !source.foreground || !source.appForeground ||
          _runtime?.owns(source) != true || _surfaceContexts[source]?.mounted != true) {
        throw const PluginOperationCancelled();
      }
    }
    return _userInitiatedUi((context) async {
      checkRequest();
      final accepted = await _delegate.requestPermissions(context, missing, checkActive: checkRequest);
      if (!accepted) return false;
      checkRequest();
      if (missing.any(blockedPermissions.contains)) {
        applyGrantedPermissions(Set.unmodifiable(blockedPermissions.difference(missing)));
      }
      return accepted;
    }, renewOnAcceptance: true);
  }

  /// 仅在宿主已确认并持久化新增授权时保留正在等待结果的界面。撤销仍回收实例。
  void applyGrantedPermissions(Set<MetaversePluginPermission> next) {
    if (!blockedPermissions.containsAll(next)) throw StateError('撤销权限须回收实例');
    _blockedPermissions = next;
  }
  bool _retired = false;

  void _requirePermission(MetaversePluginPermission permission) {
    if (blockedPermissions.contains(permission)) {
      throw MetaversePluginCallException('permission_denied:${permission.name}');
    }
  }
  final MetaversePluginStore _store;
  final MetaversePluginNetwork _network;
  late final _credentials = MetaverseCredentialManager(manifest, _store, _network);
  final MetaversePluginNetwork? dohNetwork;
  final bool Function()? canSuggestDoh;
  final dnsRetryHost = ValueNotifier<String?>(null);
  String? _dohHost;

  /// 仅由宿主界面点击触发。本运行实例中，仅该域名的公开读取使用备用解析。
  void enableDohForFailedHost(String host) {
    if (dnsRetryHost.value != host) return;
    _dohHost = host;
    dnsRetryHost.value = null;
  }

  final MetaverseScriptEngineFactory _engineFactory;
  final MetaversePluginHostDelegate _delegate;
  final DateTime Function() _clock;

  /// 最后一块界面关闭后多久释放脚本引擎。
  final Duration idleTimeout;

  String get id => manifest.id;

  /// 保留打开的页面、交互弹层和正在启动的实例，自动更新不能打断它们。
  bool get hasUpdateBlocker => _uiBusy || _preparedNavigation != null ||
      (_starting != null && _runtime == null) || (_runtime != null && !_runtime!.isIdle) ||
      (_runtime?.surfaces.any((s) => s.kind != 'card' || s.foreground) ?? false);
  bool get hasPendingInteraction => _uiBusy || _preparedNavigation != null ||
      (_runtime != null && !_runtime!.isIdle) || (_starting != null && _runtime == null);

  void notifyConfiguration(String event) {
    final runtime = _runtime;
    if (runtime == null) return;
    for (final surface in runtime.surfaces.where((s) => s.foreground)) {
      runtime.dispatch(surface, event, const {});
    }
  }

  MetaversePluginRuntime? _runtime;
  Runtime? _widgets;
  final _surfaceContexts = <MetaversePluginSurface, BuildContext>{};
  final _surfaceData = <MetaversePluginSurface, DynamicContent>{};

  /// Flutter 上下文及 RFW 数据由界面适配层持有。
  DynamicContent attachSurface(MetaversePluginSurface surface, BuildContext context) {
    if (_runtime?.owns(surface) != true) throw StateError('插件界面已关闭');
    _surfaceContexts[surface] = context;
    return _surfaceData.putIfAbsent(surface, () {
      final content = DynamicContent();
      for (final entry in surface.data.entries) {
        content.update(entry.key, entry.value ?? '');
      }
      surface.onData = (key, value) => content.update(key, value ?? '');
      return content;
    });
  }
  Future<void>? _starting;
  final _runtimeId = LogPolicy.newTraceId();
  DateTime? _logWindow;
  int _logCount = 0;
  int _suppressedLogs = 0;
  Timer? _idleTimer;
  int _generation = 0;
  int? _accountAtStart;
  bool Function()? _taskActive;
  final _forumAvatars = <Uri>{};
  final _streamBudget = MetaverseStreamBudget();
  final _streams = <String, ({MetaversePluginSurface surface, MetaverseEventStream connection})>{};

  void _closeStreams([bool Function(MetaverseEventStream)? where]) {
    for (final key in _streams.keys.toList()) {
      final entry = _streams[key]!;
      if (where == null || where(entry.connection)) {
        _streams.remove(key);
        entry.connection.close();
      }
    }
  }

  bool _uiBusy = false;
  DateTime? _activatedAt;
  MetaversePluginSurface? _activatedSurface;
  ({int token, String page, MetaversePluginSurface surface, int? account, bool replace})?
  _preparedNavigation;
  int _navigationSequence = 0;
  DateTime? _lastToast;

  /// 渲染插件界面用的组件运行时；仅在 [open] 成功后可用。
  Runtime get widgets => _widgets!;

  bool get isRunning => _runtime != null;
  bool get hasActiveUi => _uiBusy;
  String get runtimeId => _runtimeId;
  final Future<MetaversePluginCode> Function()? codeLoader;

  /// 仅开发协调器使用；等本轮事件及宿主调用结束后再替换模块。
  bool get canApplyDevelopmentUpdate => !_uiBusy && (_runtime?.isIdle ?? false);

  void updateDevelopmentUi(String source) {
    if (codeLoader == null) throw StateError('当前不是开发实例');
    final checked = validatePluginUiContract(source, metaverseComponentContract);
    if ((checked['diagnostics'] as List).isNotEmpty) throw FormatException((checked['diagnostics'] as List).join('\n'));
    final library = MetaversePluginInstaller.validateUi(manifest, source);
    _widgets?.update(metaversePluginLibraryName, library);
  }

  /// 打开一块界面，必要时先启动脚本。
  Future<MetaversePluginSurface> open({
    required String kind,
    String? page,
    Map<String, Object?> params = const {},
    bool Function()? isVisible,
  }) async {
    if (_retired) throw const PluginOperationCancelled();
    _idleTimer?.cancel();
    _idleTimer = null;
    await (_starting ??= _start(_generation));
    final runtime = _runtime;
    if (runtime == null) throw StateError('插件已停止');
    if (isVisible != null && !isVisible()) {
      if (runtime.surfaces.isEmpty) _idleTimer = Timer(idleTimeout, shutdown);
      throw const MetaversePluginCallException('surface_not_visible');
    }
    // 并发打开时，另一个已隐藏的启动请求可能刚设置过空闲回收。
    _idleTimer?.cancel();
    _idleTimer = null;
    return runtime.openSurface(kind: kind, page: page, params: params);
  }

  /// 独立实例执行任务，结束即销毁；不能与可见页面共用脚本内存。
  Future<void> runTask(String id, {required bool background, required bool Function() isActive}) async {
    if (_retired) throw const PluginOperationCancelled();
    if (background) _requirePermission(MetaversePluginPermission.background);
    if (_runtime != null || _starting != null || !manifest.tasks.any((t) => t.id == id)) {
      throw const MetaversePluginCallException('task_not_declared');
    }
    _taskActive = isActive;
    try {
      if (!isActive()) throw const MetaversePluginCallException('task_cancelled');
      await (_starting ??= _start(_generation));
      if (!isActive()) throw const MetaversePluginCallException('task_cancelled');
      await _runtime!.runTask(id, background: background);
    } finally { shutdown(); }
  }

  void close(MetaversePluginSurface surface) {
    final runtime = _runtime;
    if (runtime == null) return;
    if (identical(surface, _activatedSurface)) _clearActivation();
    if (identical(surface, _preparedNavigation?.surface)) {
      _preparedNavigation = null;
    }
    for (final key in _streams.keys.where((key) => _streams[key]!.surface == surface).toList()) {
      _streams.remove(key)!.connection.close();
    }
    runtime.closeSurface(surface);
    _surfaceContexts.remove(surface);
    _surfaceData.remove(surface);
    if (runtime.surfaces.isEmpty) {
      _idleTimer?.cancel();
      _idleTimer = Timer(idleTimeout, shutdown);
    }
  }

  void setSurfaceForeground(
    MetaversePluginSurface surface,
    bool foreground, {
    bool appForeground = true,
  }) {
    if ((!appForeground || (!foreground && surface.foreground && !_uiBusy)) &&
        identical(surface, _preparedNavigation?.surface)) {
      _preparedNavigation = null;
    }
    if (!foreground && identical(surface, _activatedSurface)) {
      _clearActivation();
    }
    _runtime?.setForeground(surface, foreground, appForeground: appForeground);
    for (final entry in _streams.values.where((entry) => entry.surface == surface)) {
      entry.connection.setActive(foreground && appForeground);
    }
  }

  void _clearActivation() {
    _activatedAt = null;
    _activatedSurface = null;
  }

  /// 用户在界面上触发的事件。
  void dispatchUserEvent(
    MetaversePluginSurface surface,
    String name,
    Map<String, Object?> args,
  ) {
    final runtime = _runtime;
    if (runtime == null || !runtime.owns(surface) || !surface.foreground) {
      return;
    }
    _activatedAt = _clock();
    _activatedSurface = surface;
    _preparedNavigation = null;
    runtime.dispatch(surface, name, args);
  }

  /// 元宇宙入口由用户刷新时，只通知当前可见卡片，不启动隐藏界面。
  void refreshVisibleCards() {
    for (final surface in _runtime?.surfaces.toList() ?? <MetaversePluginSurface>[]) {
      if (surface.kind == 'card' && surface.foreground) {
        // 批量刷新不把一次底栏点击授权给多个插件弹出界面。
        _runtime!.dispatch(surface, 'card.refresh', const {});
      }
    }
  }

  void notifyTaskUpdated() {
    final runtime = _runtime;
    if (runtime == null) return;
    for (final surface in runtime.surfaces.where((surface) => surface.foreground)) {
      runtime.dispatch(surface, 'task.updated', const {});
    }
  }

  /// 停止脚本并释放引擎；之后 [open] 会重新启动。
  void shutdown() {
    _generation++;
    _closeStreams();
    _forumAvatars.clear();
    _delegate.onShutdown();
    _dohHost = null;
    dnsRetryHost.value = null;
    _idleTimer?.cancel();
    _idleTimer = null;
    _starting = null;
    _runtime?.dispose();
    _runtime = null;
    _surfaceContexts.clear();
    _surfaceData.clear();
    _widgets = null;
    _uiBusy = false;
    _preparedNavigation = null;
    _clearActivation();
  }

  /// 撤销实例持有的授权，旧页面即使再次可见也不能重启这个实例。
  void retire() {
    _retired = true;
    shutdown();
  }

  Future<void> _start(int generation) async {
    _accountAtStart = _delegate.currentAccountId();
    try {
      await _delegate.prepareStart();
      if (!manifest.runtimeSupported) {
        throw const MetaversePluginCallException('plugin_api_upgrade_required');
      }
      final code = await (codeLoader?.call() ?? _store.readCode(id));
      if (generation != _generation) throw const PluginOperationCancelled();
      final library = _taskActive == null ? MetaversePluginInstaller.validateUi(manifest, code.ui) : null;
      final runtime = await MetaversePluginRuntime.start(
        engineFactory: _engineFactory,
        script: code.script,
        bridge: this,
        executionContext: PluginExecutionContext(pluginId: id, pluginVersion: manifest.version, runtimeId: _runtimeId),
        onSurfaceReady: () {
          if (generation == _generation) _delegate.onHealthy();
        },
        onFatal: (reason) {
          if (generation != _generation) return;
          shutdown();
          _delegate.onSuspended(id, reason);
        },
      );
      // 启动期间被停用/卸载：丢弃刚起来的引擎。
      if (generation != _generation) {
        runtime.dispose();
        throw StateError('插件已停止');
      }
      _runtime = runtime;
      if (library == null) return;
      final account = _accountAtStart;
      Future<Uint8List> image(Uri uri, {bool reload = false}) {
        final forumAvatar = _forumAvatars.contains(uri);
        return PluginExecutionContext(pluginId: id, pluginVersion: manifest.version,
          runtimeId: _runtimeId, emitter: 'framework').run(() => _network.loadImage(manifest, uri,
            forumAvatar: forumAvatar,
            allowPublicImages: !blockedPermissions.contains(MetaversePluginPermission.publicImages),
            cache: _store.imageCache, cacheSource: imageCacheSource, account: account, runtime: runtime,
            reload: reload, checkActive: () {
              if (generation != _generation || account != _delegate.currentAccountId() ||
                  (forumAvatar && !_forumAvatars.contains(uri))) {
                throw const PluginOperationCancelled();
              }
            },
          ));
      }
      _widgets = Runtime()
        ..update(
          metaverseWidgetLibraryName,
          createMetaverseWidgetLibrary(
            loadImage: image, reloadImage: (uri) => image(uri, reload: true),
          ),
        )
        ..update(metaversePluginLibraryName, library);
    } catch (_) {
      if (generation == _generation) { _starting = null; _delegate.onStartFailed(); }
      rethrow;
    }
  }

  @override
  void log(String level, String message) {
    final now = _clock();
    if (_logWindow == null || now.difference(_logWindow!) >= const Duration(minutes: 1)) {
      if (_suppressedLogs > 0) {
        _writeLog('warning', 'plugin_log_throttled', '插件日志已合并', {
          'suppressed': _suppressedLogs,
        });
      }
      _logWindow = now;
      _logCount = 0;
      _suppressedLogs = 0;
    }
    if (++_logCount > 120) {
      _suppressedLogs++;
      return;
    }
    _writeLog(level, 'plugin_console', message);
  }

  void _writeLog(String level, String event, String message, [Map<String, Object?> fields = const {}]) {
    LogWriter.instance.write({
      ...fields,
      'pluginId': id,
      'pluginVersion': manifest.version,
      'runtimeId': _runtimeId,
      'emitter': 'plugin',
      'type': 'plugin',
      'event': event,
      'level': level,
      'message': message,
    });
  }

  @override
  Future<Object?> call(String method, Map<String, Object?> params) =>
      PluginExecutionContext(
        pluginId: id,
        pluginVersion: manifest.version,
        runtimeId: _runtimeId,
        surfaceId: PluginExecutionContext.current?.surfaceId,
        traceId: LogPolicy.newTraceId(),
      ).run(() async {
        final watch = Stopwatch()..start();
        try {
          return await _call(method, params);
        } catch (error) {
          LogWriter.instance.write({
            'type': 'plugin',
            'level': 'warning',
            'event': 'plugin_call_failed',
            'method': method,
            'duration': watch.elapsedMilliseconds,
            'message': error.toString(),
          });
          rethrow;
        }
      });

  /// 只允许类型化论坛响应返回的头像，不能由脚本任意指定站点地址。
  void _rememberForumAvatars(Object? value) {
    if (value is Map) {
      final avatar = value['avatarUrl'];
      final uri = avatar is String ? Uri.tryParse(avatar) : null;
      if (uri != null && uri.scheme == 'https' && uri.userInfo.isEmpty && uri.host.isNotEmpty) {
        if (_forumAvatars.length >= 512) _forumAvatars.remove(_forumAvatars.first);
        _forumAvatars.add(uri);
      }
      for (final child in value.values) { _rememberForumAvatars(child); }
    } else if (value is List) {
      for (final child in value) { _rememberForumAvatars(child); }
    }
  }

  String _accountStorageKey(String key) {
    if (!manifest.accountScoped) return key;
    final account = _delegate.currentAccountId();
    if (account == null) throw const MetaversePluginCallException('forum_auth_required');
    return '@forum-account:$_accountAtStart:$key';
  }

  Future<Object?> _streamCall(String method, Map<String, Object?> params) async {
    final runtime = _runtime;
    final surfaceId = PluginExecutionContext.current?.surfaceId;
    final source = runtime?.surfaces.where((s) => s.id == surfaceId).firstOrNull;
    final streamId = params['id'];
    if (source == null || source.kind == 'task' || runtime == null) {
      throw const MetaversePluginCallException('stream_requires_surface');
    }
    if (streamId is! String || !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(streamId)) {
      throw const MetaversePluginCallException('stream_invalid_id');
    }
    final key = '${source.id}:$streamId';
    if (method == 'streams.close') {
      _streams.remove(key)?.connection.close();
      return null;
    }
    if (!manifest.requiredFeatures.contains('eventStreams')) {
      throw const MetaversePluginCallException('stream_feature_not_declared');
    }
    if (!source.foreground || !source.appForeground) throw const MetaversePluginCallException('stream_not_visible');
    if (_streams.containsKey(key)) throw const MetaversePluginCallException('stream_already_open');
    if (_streams.length >= 8) throw const MetaversePluginCallException('stream_limit');
    final url = params['url'];
    final uri = url is String && url.length <= 8192 ? Uri.tryParse(url) : null;
    final lastId = params['lastEventId'] ?? '';
    if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.fragment.isNotEmpty ||
        lastId is! String || lastId.length > 4096 || lastId.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
        (params['headers'] != null && params['headers'] is! Map) ||
        params.keys.any((key) => !{'id', 'url', 'headers', 'credential', 'lastEventId'}.contains(key))) {
      throw const MetaversePluginCallException('stream_invalid_request');
    }
    final credentialName = params['credential'];
    if (credentialName != null) {
      _requirePermission(MetaversePluginPermission.serviceAccount);
      _credentials.spec(credentialName);
    }
    final generation = _generation, account = _delegate.currentAccountId();
    final revision = credentialName is String ? _store.credentialRevision(id, credentialName) : null;
    late final MetaverseEventStream connection;
    void checkActive() {
      if (generation != _generation || _retired || account != _delegate.currentAccountId() ||
          _streams[key]?.connection != connection || !runtime.owns(source) || !source.foreground ||
          !source.appForeground || (credentialName is String && revision != _store.credentialRevision(id, credentialName))) {
        throw const PluginOperationCancelled();
      }
      if (credentialName != null) _requirePermission(MetaversePluginPermission.serviceAccount);
    }
    connection = MetaverseEventStream(id: streamId, credential: credentialName as String?, budget: _streamBudget,
      lastEventId: lastId,
      connect: (cancel, lastEventId, onOpen, onEvent, onRetry) => PluginExecutionContext(
        pluginId: id, pluginVersion: manifest.version, runtimeId: _runtimeId,
        surfaceId: source.id, emitter: 'framework', traceId: LogPolicy.newTraceId(),
      ).run(() async {
        checkActive();
        final credential = credentialName == null ? null : await _credentials.read(credentialName, account);
        checkActive();
        if (credentialName != null && credential == null) throw const MetaverseStreamException('stream_credential_required');
        void checkCredential() {
          checkActive();
          if (credential != null && !credential.validFor(account)) throw const MetaverseStreamException('stream_credential_expired');
        }
        await _network.consumeEvents(manifest, request: params, authToken: credential?.secret,
          cancel: cancel, checkActive: checkCredential, onOpen: onOpen, onEvent: onEvent,
          onRetry: onRetry, lastEventId: lastEventId);
      }),
      emit: (name, args) async {
        checkActive();
        if (name == 'stream.state') {
          LogWriter.instance.write({'type': 'plugin', 'level': 'info', 'event': 'plugin_stream_state',
            'pluginId': id, 'pluginVersion': manifest.version, 'runtimeId': _runtimeId, 'surfaceId': source.id,
            'emitter': 'framework', 'streamId': streamId, 'host': uri.host,
            'state': args['state'], 'reason': args['reason'], 'status': args['status'],
            'message': '插件实时连接状态变更'});
        }
        await runtime.dispatchAndWait(source, name, args);
      });
    _streams[key] = (surface: source, connection: connection);
    connection.setActive(true);
    return streamId;
  }

  Future<Object?> _call(String method, Map<String, Object?> params) async {
    if (_retired) throw const PluginOperationCancelled();
    if (manifest.accountScoped && _accountAtStart != _delegate.currentAccountId()) {
      throw const MetaversePluginCallException('forum_account_changed');
    }
    if (_taskActive != null && !_taskActive!()) throw const MetaversePluginCallException('task_cancelled');
    if (_taskActive != null && !const {
      'forum.read', 'storage.get', 'storage.set', 'storage.setMany', 'storage.remove', 'storage.compareAndSet',
      'host.features', 'host.environment', 'preferences.get', 'user.get', 'tasks.list', 'navigation.setBadge',
      'notifications.show', 'notifications.cancel', 'notifications.isAllowed', 'notifications.status', 'crypto.uuid', 'crypto.sha256', 'fetch',
    }.contains(method)) {
      throw const MetaversePluginCallException('task_has_no_ui');
    }
    final callGeneration = _generation;
    final callAccount = _delegate.currentAccountId();
    void checkActive() {
      if (callGeneration != _generation || callAccount != _delegate.currentAccountId() ||
          (_taskActive != null && !_taskActive!())) {
        throw const MetaversePluginCallException('task_cancelled');
      }
    }
    switch (method) {
      case 'streams.open':
      case 'streams.close':
        return _streamCall(method, params);
      case 'navigation.dismiss':
        final id = PluginExecutionContext.current?.surfaceId;
        final source = _runtime?.surfaces.where((surface) => surface.id == id).firstOrNull;
        final page = source?.page;
        final context = _surfaceContexts[source];
        if (_uiBusy || source == null || !source.foreground || !source.appForeground || page == null ||
            manifest.page(page)?.modal != true || context == null || !context.mounted) {
          return false;
        }
        return _delegate.dismissModal(context, page);
      case 'permissions.status':
        return {for (final p in manifest.declaredPermissions) p.name: !blockedPermissions.contains(p)};
      case 'permissions.request':
        final names = params['names'];
        if (names is! List || names.isEmpty || names.length > MetaversePluginPermission.values.length) {
          throw const MetaversePluginCallException('permission_invalid_request');
        }
        final missing = <MetaversePluginPermission>{};
        for (final name in names) {
          final p = manifest.declaredPermissions.where((p) => p.name == name && p.manageable).firstOrNull;
          if (p == null) throw const MetaversePluginCallException('permission_not_requestable');
          if (blockedPermissions.contains(p)) missing.add(p);
        }
        if (missing.isEmpty) return true;
        return _askPermissions(missing, checkActive);
      case 'tasks.schedule':
        final request = MetaverseTaskSchedule.parse(params);
        if (request.background) _requirePermission(MetaversePluginPermission.background);
        if (!manifest.tasks.any((t) => t.id == request.id)) throw const MetaversePluginCallException('task_not_declared');
        if (request.background && !manifest.capabilities.background) throw const MetaversePluginCallException('task_permission_denied');
        return _userInitiatedUi((context) async {
          if (request.background && !await _delegate.confirmBackground(context, request.id)) return false;
          checkActive();
          return _delegate.taskOperation(method, params, checkActive: checkActive);
        });
      case 'tasks.cancel':
      case 'tasks.list':
        if (manifest.tasks.isEmpty) throw const MetaversePluginCallException('task_not_declared');
        return _delegate.taskOperation(method, params, checkActive: checkActive);
      case 'notifications.requestPermission':
        if (!manifest.capabilities.notifications) throw const MetaversePluginCallException('notification_permission_denied');
        final needsGrant = blockedPermissions.contains(MetaversePluginPermission.notifications);
        if (needsGrant && !await _askPermissions({MetaversePluginPermission.notifications}, checkActive)) return false;
        return _userInitiatedUi((context) async {
          if (!needsGrant && !await _delegate.confirmNotifications(context)) return false;
          checkActive();
          return _delegate.taskOperation(method, params, checkActive: checkActive);
        });
      case 'notifications.status':
        if (!manifest.capabilities.notifications) throw const MetaversePluginCallException('notification_permission_denied');
        final status = await _delegate.taskOperation(method, params, checkActive: checkActive);
        checkActive();
        return {...(status as Map<String, Object?>), if (blockedPermissions.contains(MetaversePluginPermission.notifications)) 'authorized': false};
      case 'notifications.openSettings':
        if (!manifest.capabilities.notifications) throw const MetaversePluginCallException('notification_permission_denied');
        return _userInitiatedUi((_) => _delegate.taskOperation(method, params, checkActive: checkActive));
      case 'notifications.show':
      case 'notifications.cancel':
      case 'notifications.isAllowed':
      case 'notifications.revoke':
        if (!manifest.capabilities.notifications) throw const MetaversePluginCallException('notification_permission_denied');
        if (method == 'notifications.isAllowed' && blockedPermissions.contains(MetaversePluginPermission.notifications)) return false;
        if (method == 'notifications.show') _requirePermission(MetaversePluginPermission.notifications);
        return _delegate.taskOperation(method, params, checkActive: checkActive);
      case 'navigation.setBadge':
        final page = params['page'], count = params['count'];
        if (page is! String || manifest.page(page)?.navigation == null || count is! int || count < 0 || count > 99999) {
          throw const MetaversePluginCallException('badge_invalid');
        }
        return _delegate.taskOperation(method, params, checkActive: checkActive);
      case 'forum.read':
        final request = MetaverseForumRequest.parse(params);
        if (!manifest.capabilities.forum.contains(request.resource.scope)) {
          throw const MetaversePluginCallException('forum_permission_denied');
        }
        _requirePermission(MetaversePluginPermission.forForum(request.resource.scope));
        final account = _delegate.currentAccountId();
        if (account == null) throw const MetaversePluginCallException('forum_auth_required');
        final generation = _generation;
        final sourceId = PluginExecutionContext.current?.surfaceId;
        final source = _runtime?.surfaces.where((s) => s.id == sourceId).firstOrNull;
        void checkActive() {
          if (generation != _generation || account != _delegate.currentAccountId()) {
            throw const MetaversePluginCallException('forum_account_changed');
          }
          if (_taskActive != null && !_taskActive!()) throw const MetaversePluginCallException('task_cancelled');
          if (_taskActive == null && (source == null || _runtime?.owns(source) != true || !source.foreground)) {
            throw const MetaversePluginCallException('forum_not_visible');
          }
        }
        checkActive();
        final result = await _delegate.readForum(request, checkActive: checkActive);
        checkActive();
        _rememberForumAvatars(result);
        return result;
      case 'forum.open':
        final destination = MetaverseForumDestination.parse(params);
        return _userInitiatedUi((context) => _delegate.openForum(context, destination));
      case 'fetch':
        if (_taskActive != null && !{'GET', 'HEAD'}.contains((params['method'] ?? 'GET').toString().toUpperCase())) {
          throw const MetaversePluginCallException('task_read_only');
        }
        final host = Uri.tryParse('${params['url']}')?.host;
        final publicRead =
            '${params['method'] ?? 'GET'}'.toUpperCase() == 'GET' &&
            params['auth'] != true &&
            params['credential'] == null &&
            params['body'] == null &&
            (params['headers'] == null ||
                (params['headers'] is Map &&
                    (params['headers'] as Map).isEmpty));
        final useDoh =
            publicRead &&
            host != null &&
            host == _dohHost &&
            dohNetwork != null;
        final generation = _generation;
        final accountId = _delegate.currentAccountId();
        final credentialName = params['credential'];
        if (credentialName != null || params['auth'] == true) _requirePermission(MetaversePluginPermission.serviceAccount);
        final credentialRevision = credentialName is String
            ? _store.credentialRevision(id, credentialName)
            : null;
        final credential = credentialName == null
            ? null
            : await _credentials.read(credentialName, accountId);
        void checkActive() {
          if (generation != _generation ||
              (_taskActive != null && !_taskActive!()) ||
              accountId != _delegate.currentAccountId() ||
              (credentialName is String &&
                  credentialRevision != _store.credentialRevision(id, credentialName))) {
            throw const PluginOperationCancelled();
          }
        }
        try {
          final response = await (useDoh ? dohNetwork! : _network).fetch(
            manifest,
            request: params,
            authToken: credentialName != null
                ? credential?.secret
                : params['auth'] == true
                ? await _store.readToken(id)
                : null,
            checkActive: checkActive,
          );
          if (params['auth'] == true &&
              (generation != _generation ||
                  accountId != _delegate.currentAccountId())) {
            throw const MetaversePluginCallException('auth_required');
          }
          return response;
        } on MetaverseIpv6ReadTimeout catch (e) {
          if (generation == _generation &&
              publicRead &&
              e.host != _dohHost &&
              dohNetwork != null &&
              canSuggestDoh?.call() == true) {
            dnsRetryHost.value = e.host;
          }
          rethrow;
        }

      case 'storage.get':
        final key = _accountStorageKey(_storageKey(params));
        final generation = _generation;
        final account = _delegate.currentAccountId();
        final data = await _store.readStorage(id);
        if (generation != _generation || (manifest.accountScoped && account != _delegate.currentAccountId())) {
          throw const MetaversePluginCallException('forum_account_changed');
        }
        checkActive();
        return data[key];
      case 'storage.set':
        return _writeStorage(_storageKey(params), params['value']);
      case 'storage.compareAndSet':
        if (!params.containsKey('expected') || !params.containsKey('value')) {
          throw const MetaversePluginCallException('storage_invalid_arguments');
        }
        return _store.compareAndSet(id, _accountStorageKey(_storageKey(params)), params['expected'], params['value'], checkActive: checkActive);
      case 'storage.remove':
        return _writeStorage(_storageKey(params), null);
      case 'storage.setMany':
        final entries = params['entries'];
        if (entries is! Map<String, dynamic> || entries.length > 128) {
          throw const MetaversePluginCallException('存储批次不合法');
        }
        for (final key in entries.keys) {
          _storageKey({'key': key});
        }
        try {
          await _store.updateStorageEntries(id, entries.map((key, value) => MapEntry(_accountStorageKey(key), value)), isActive: () { checkActive(); return true; });
        } on StateError {
          throw const MetaversePluginCallException('存储空间已满');
        }
        return null;

      case 'credentials.status':
        _credentials.spec(params['name']);
        if (blockedPermissions.contains(MetaversePluginPermission.serviceAccount)) {
          return {'authorized': false, 'expiresAt': null};
        }
        final status = await _credentials.status(params['name'], _delegate.currentAccountId(), includeClaims: params['jwt'] == true);
        checkActive();
        return status;
      case 'credentials.capture':
        _requirePermission(MetaversePluginPermission.serviceAccount);
        _credentials.spec(params['name']);
        _closeStreams((stream) => stream.credential == params['name']);
        if (_taskActive != null) throw const MetaversePluginCallException('task_read_only');
        final generation = _generation;
        final accountId = _delegate.currentAccountId();
        return _credentials.capture(
          params,
          accountId: accountId,
          isActive: () => generation == _generation &&
              accountId == _delegate.currentAccountId(),
        );
      case 'credentials.remove':
        final name = _credentials.spec(params['name']).name;
        _closeStreams((stream) => stream.credential == name);
        await _store.removeCredential(id, name);
        return null;
      case 'credentials.request':
        _requirePermission(MetaversePluginPermission.serviceAccount);
        final name = _credentials.spec(params['name']).name;
        return _userInitiatedUi(
          (context) => _delegate.requestCredential(context, name),
        );
      case 'crypto.pkce':
        final random = Random.secure();
        final verifier = base64Url
            .encode(List.generate(32, (_) => random.nextInt(256)))
            .replaceAll('=', '');
        return {
          'verifier': verifier,
          'challenge': base64Url
              .encode(sha256.convert(utf8.encode(verifier)).bytes)
              .replaceAll('=', ''),
          'method': 'S256',
        };
      case 'crypto.uuid':
        return const Uuid().v4();
      case 'crypto.sha256':
        final input = params['text'];
        if (input is! String || utf8.encode(input).length > 1024 * 1024) {
          throw const MetaversePluginCallException('hash_input_invalid');
        }
        return sha256.convert(utf8.encode(input)).toString();
      case 'host.features':
        return PluginFeatures.supported.toList();
      case 'host.environment': return _delegate.environment();
      case 'preferences.get': return _store.preferences(manifest);
      case 'dialogs.confirm':
        for (final key in ['title', 'message', 'confirmLabel']) {
          if (params[key] is! String || (params[key] as String).isEmpty || (params[key] as String).length > 4096) {
            throw const MetaversePluginCallException('confirmation_invalid');
          }
        }
        final agreement = params['agreement'];
        if (agreement != null) {
          final uri = agreement is Map && agreement['url'] is String ? Uri.tryParse(agreement['url']) : null;
          if (agreement is! Map || agreement['label'] is! String || (agreement['label'] as String).length > 256 ||
              uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.toString().length > 2048) {
            throw const MetaversePluginCallException('confirmation_invalid_agreement');
          }
        }
        return _userInitiatedUi((context) => _delegate.confirm(context, params), renewOnAcceptance: true);
      case 'connect.authorize':
        _requirePermission(MetaversePluginPermission.serviceAccount);
        final raw = params['url'];
        final uri = raw is String && raw.length <= 16384
            ? Uri.tryParse(raw)
            : null;
        if (uri == null || manifest.capabilities.connectCallbacks.isEmpty) {
          throw const MetaversePluginCallException('connect_not_declared');
        }
        return _userInitiatedUi(
          (context) => _delegate.authorizeConnect(context, uri),
        );
      case 'payments.request':
        _requirePermission(MetaversePluginPermission.payments);
        final provider = manifest.capabilities.payments
            .where((value) => value.name == params['provider'])
            .firstOrNull;
        final reference = params['reference'];
        final rawUrl = params['url'];
        final url = rawUrl is String && rawUrl.length <= 16384
            ? Uri.tryParse(rawUrl)
            : null;
        final amount = params['amount'];
        if (provider == null ||
            url == null ||
            reference is! String ||
            reference.isEmpty ||
            reference.length > 128 ||
            reference.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
            (amount is! String && amount is! num)) {
          throw const MetaversePluginCallException('payment_invalid_request');
        }
        return _userInitiatedUi(
          (context) => _delegate.requestPayment(
            context,
            provider: provider,
            url: url,
            reference: reference,
            amount: amount!,
          ),
        );

      case 'auth.status':
        final authorized = manifest.auth.required && !blockedPermissions.contains(MetaversePluginPermission.serviceAccount) &&
            ((await _store.readToken(id))?.isNotEmpty ?? false);
        checkActive();
        return {'required': manifest.auth.required, 'authorized': authorized};
      case 'auth.request':
        _requirePermission(MetaversePluginPermission.serviceAccount);
        if (!manifest.auth.required) {
          throw const MetaversePluginCallException('清单未声明授权方式');
        }
        return _userInitiatedUi(
          (context) => _delegate.requestAuth(context, manifest),
        );
      case 'auth.signOut':
        await _store.deleteToken(id);
        return null;

      case 'user.get':
        if (!manifest.identity) {
          throw const MetaversePluginCallException(
            '清单未声明 permissions.identity',
          );
        }
        if (blockedPermissions.contains(MetaversePluginPermission.identity)) return null;
        final username = _delegate.currentUsername();
        return username == null ? null : {
          'username': username,
          if (manifest.apiVersion >= 2) 'id': _delegate.currentAccountId(),
        };

      case 'navigation.prepare':
        final page = params['page'];
        final surface = _activatedSurface;
        final activated = _activatedAt;
        if (page is! String || manifest.page(page) == null) {
          throw MetaversePluginCallException('页面 $page 未在清单中声明');
        }
        if (_uiBusy ||
            surface == null ||
            !surface.foreground ||
            activated == null ||
            _clock().difference(activated) > activationWindow) {
          throw const MetaversePluginCallException('该操作须由用户点击触发');
        }
        final token = ++_navigationSequence;
        _preparedNavigation = (
          token: token,
          page: page,
          surface: surface,
          account: _delegate.currentAccountId(),
          replace: params['replace'] == true,
        );
        return token;

      case 'navigate':
        final page = params['page'];
        if (page is! String || manifest.page(page) == null) {
          throw MetaversePluginCallException('页面 $page 未在清单中声明');
        }
        final pageParams = params['params'];
        final continuation = params['continuation'];
        if (continuation != null) {
          final prepared = _preparedNavigation;
          if (prepared == null ||
              prepared.token != continuation ||
              prepared.page != page ||
              _uiBusy ||
              !prepared.surface.foreground ||
              prepared.account != _delegate.currentAccountId()) {
            throw const MetaversePluginCallException('导航预约已失效');
          }
          final context = _surfaceContexts[prepared.surface];
          _preparedNavigation = null;
          _clearActivation();
          if (context == null || !context.mounted) {
            throw const MetaversePluginCallException('没有可见的界面');
          }
          if ((params['replace'] == true) != prepared.replace) {
            throw const MetaversePluginCallException('导航预约方式不匹配');
          }
          (prepared.replace ? _delegate.replacePage : _delegate.openPage)(
            context,
            manifest,
            page,
            pageParams is Map ? pageParams.cast<String, Object?>() : const {},
          );
          return null;
        }
        await _userInitiatedUi((context) async {
          (params['replace'] == true ? _delegate.replacePage : _delegate.openPage)(
            context,
            manifest,
            page,
            pageParams is Map ? pageParams.cast<String, Object?>() : const {},
          );
        });
        return null;

      case 'session.login':
      case 'session.open':
        _requirePermission(MetaversePluginPermission.serviceAccount);
        final path = params['path'];
        final target = method == 'session.login'
            ? manifest.webLogin
            : path is String
            ? manifest.webSessionPage(path)
            : null;
        if (target == null) {
          throw const MetaversePluginCallException('须声明网页登录入口，且只能打开该站点的页面');
        }
        await _userInitiatedUi(
          (context) => _delegate.openWebSession(context, target),
        );
        return null;

      case 'openUrl':
      case 'browser.open':
        final rawUrl = params['url'];
        final url = rawUrl is String ? Uri.tryParse(rawUrl) : null;
        if (url == null ||
            url.host.isEmpty ||
            (url.scheme != 'https' && url.scheme != 'http')) {
          throw const MetaversePluginCallException('只能打开 http(s) 链接');
        }
        final mode = LinkOpenMode.values
            .where((value) => value.name == (params['mode'] ?? 'ask'))
            .firstOrNull;
        if (method == 'browser.open' && mode == null) {
          throw const MetaversePluginCallException('browser_invalid_mode');
        }
        await _userInitiatedUi(
          (context) => method == 'browser.open'
              ? _delegate.openBrowser(context, url, mode!)
              : _delegate.openUrl(context, url),
        );
        return null;

      case 'toast':
        // 需要有可见界面，且限速：后台插件不能刷提示。
        if (_runtime?.surfaces.any(
              (s) => s.foreground && _surfaceContexts[s]?.mounted == true,
            ) !=
            true) {
          throw const MetaversePluginCallException('没有可见的界面');
        }
        final now = _clock();
        final last = _lastToast;
        if (last != null && now.difference(last) < _toastInterval) return null;
        _lastToast = now;
        final message = '${params['message'] ?? ''}';
        _delegate.toast(
          message.length > _maxToast
              ? message.substring(0, _maxToast)
              : message,
          '${params['type'] ?? 'info'}',
        );
        return null;
    }
    throw MetaversePluginCallException('未知的调用 $method');
  }

  String _storageKey(Map<String, Object?> params) {
    final key = params['key'];
    if (key is! String || key.isEmpty || key.length > _maxStorageKey || key.startsWith('@forum-account:')) {
      throw const MetaversePluginCallException('存储键不合法');
    }
    return key;
  }

  Future<Object?> _writeStorage(String key, Object? value) async {
    try {
      final generation = _generation, account = _delegate.currentAccountId();
      await _store.updateStorage(id, _accountStorageKey(key), value, isActive: () => generation == _generation && account == _delegate.currentAccountId() && (_taskActive?.call() ?? true));
    } on StateError {
      throw const MetaversePluginCallException('存储空间已满');
    }
    return null;
  }

  /// 执行一个会改变用户所见界面的操作。
  ///
  /// 必须发生在用户操作之后的 [activationWindow] 内，一次操作只能换一次，
  /// 且同一时间只允许一个。提前预约的页面可在操作结束后打开一次。
  Future<T> _userInitiatedUi<T>(
    Future<T> Function(BuildContext context) run, {
    bool renewOnAcceptance = false,
  }) async {
    if (_taskActive != null) throw const MetaversePluginCallException('task_has_no_ui');
    if (_uiBusy) {
      throw const MetaversePluginCallException('已有进行中的界面操作');
    }
    final activatedAt = _activatedAt;
    final requestedSurface = PluginExecutionContext.current?.surfaceId;
    if (requestedSurface != null && requestedSurface != _activatedSurface?.id) {
      throw const MetaversePluginCallException('用户操作不属于当前界面');
    }
    if (activatedAt == null ||
        _clock().difference(activatedAt) > activationWindow) {
      throw const MetaversePluginCallException('该操作须由用户点击触发');
    }
    final source = _activatedSurface;
    final account = _delegate.currentAccountId();
    final context = _surfaceContexts[source];
    _clearActivation();
    if (context == null || !context.mounted) {
      throw const MetaversePluginCallException('没有可见的界面');
    }
    final generation = _generation;
    _uiBusy = true;
    try {
      final result = await run(context);
      if (renewOnAcceptance && result == true && generation == _generation &&
          account == _delegate.currentAccountId() && source != null &&
          _surfaceContexts.containsKey(source) && source.appForeground && context.mounted) {
        _activatedSurface = source;
        _activatedAt = _clock();
      }
      return result;
    } finally {
      if (generation == _generation) _uiBusy = false;
    }
  }
}
