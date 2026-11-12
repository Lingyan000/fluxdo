import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/widgets.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';
import 'package:rfw/rfw.dart';

import '../../../services/log/log_policy.dart';
import '../../../services/log/log_writer.dart';

import 'metaverse_plugin_installer.dart';
import 'metaverse_checkout.dart';
import 'metaverse_checkout_types.dart';
import 'metaverse_plugin_manifest.dart';
import 'metaverse_plugin_network.dart';
import 'metaverse_plugin_store.dart';
import 'metaverse_service_session.dart';
import 'metaverse_credential_manager.dart';
import 'metaverse_plugin_capabilities.dart';
import 'ui/metaverse_widget_library.dart';

/// 宿主里需要界面或应用状态才能完成的操作，由上层（provider 层）实现。
abstract class MetaversePluginHostDelegate {
  void onShutdown() {}
  int? currentAccountId() => null;

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

  Future<Object?> payOrder(
    BuildContext context,
    String orderNo, {
    bool cancel = false,
  }) => Future.error(const MetaversePluginCallException('payment_unavailable'));
  Future<bool> confirmOrder(
    BuildContext context,
    MetaverseCheckoutGrant grant,
    MetaverseOrderIntent intent,
  );

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

  /// 打开外部链接；是否需要离站确认由应用的链接安全策略决定。
  Future<void> openUrl(BuildContext context, Uri url);

  /// 打开第一方网页会话，不将授权材料或页面内容返回给插件。
  Future<void> openWebSession(BuildContext context, Uri url);

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
  final MetaversePluginStore _store;
  final MetaversePluginNetwork _network;
  late final _checkout = MetaverseCheckout(manifest, _store, _network);
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
  bool _uiBusy = false;
  DateTime? _activatedAt;
  MetaversePluginSurface? _activatedSurface;
  ({int token, String page, MetaversePluginSurface surface, int? account})?
  _preparedNavigation;
  int _navigationSequence = 0;
  DateTime? _lastToast;

  /// 渲染插件界面用的组件运行时；仅在 [open] 成功后可用。
  Runtime get widgets => _widgets!;

  bool get isRunning => _runtime != null;

  /// 打开一块界面，必要时先启动脚本。
  Future<MetaversePluginSurface> open({
    required String kind,
    String? page,
    Map<String, Object?> params = const {},
  }) async {
    _idleTimer?.cancel();
    _idleTimer = null;
    await (_starting ??= _start(_generation));
    final runtime = _runtime;
    if (runtime == null) throw StateError('插件已停止');
    return runtime.openSurface(kind: kind, page: page, params: params);
  }

  void close(MetaversePluginSurface surface) {
    final runtime = _runtime;
    if (runtime == null) return;
    if (identical(surface, _activatedSurface)) _clearActivation();
    if (identical(surface, _preparedNavigation?.surface)) {
      _preparedNavigation = null;
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

  /// 停止脚本并释放引擎；之后 [open] 会重新启动。
  void shutdown() {
    _generation++;
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

  Future<void> _start(int generation) async {
    try {
      final code = await _store.readCode(id);
      final library = MetaversePluginInstaller.validateUi(manifest, code.ui);
      final runtime = await MetaversePluginRuntime.start(
        engineFactory: _engineFactory,
        script: code.script,
        bridge: this,
        executionContext: PluginExecutionContext(pluginId: id, pluginVersion: manifest.version, runtimeId: _runtimeId),
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
      _widgets = Runtime()
        ..update(
          metaverseWidgetLibraryName,
          createMetaverseWidgetLibrary(
            loadImage: (uri) => _network.loadImage(manifest, uri),
          ),
        )
        ..update(metaversePluginLibraryName, library);
    } catch (_) {
      if (generation == _generation) _starting = null;
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

  Future<MetaverseServiceSession?> _readSession() async {
    final session = await _store.readServiceSession(id);
    if (session?.accountId != null &&
        session!.accountId != _delegate.currentAccountId()) {
      return null;
    }
    return session;
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

  Future<Object?> _call(String method, Map<String, Object?> params) async {
    switch (method) {
      case 'fetch':
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
        final credentialRevision = credentialName is String
            ? _store.credentialRevision(id, credentialName)
            : null;
        final credential = credentialName == null
            ? null
            : await _credentials.read(credentialName, accountId);
        void checkActive() {
          if (generation != _generation ||
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
                ? manifest.auth.type == MetaversePluginAuthType.readSession
                      ? (await _readSession())?.token
                      : await _store.readToken(id)
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
        return (await _store.readStorage(id))[_storageKey(params)];
      case 'storage.set':
        return _writeStorage(_storageKey(params), params['value']);
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
          await _store.updateStorageEntries(id, entries);
        } on StateError {
          throw const MetaversePluginCallException('存储空间已满');
        }
        return null;

      case 'credentials.status':
        return _credentials.status(params['name'], _delegate.currentAccountId());
      case 'credentials.capture':
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
        await _store.removeCredential(id, name);
        return null;
      case 'credentials.request':
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
      case 'connect.authorize':
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
        final managed =
            manifest.auth.type == MetaversePluginAuthType.readSession;
        final session = managed ? await _readSession() : null;
        return {
          'required': manifest.auth.required,
          'nativeSupported': manifest.auth.connect != null,
          'paymentSupported': manifest.auth.payment != null,
          'authorized': managed
              ? session != null
              : (manifest.auth.required &&
                    ((await _store.readToken(id))?.isNotEmpty ?? false)),
          'queries': [
            for (final e in manifest.auth.queries.entries)
              if (session?.queryUrls.contains(e.value) == true) e.key,
          ],
          if (session?.checkout case final grant?
              when grant.endpoints == manifest.auth.checkout)
            'checkoutUnit': grant.unit,
        };
      case 'checkout.status':
      case 'checkout.recover':
      case 'checkout.finish':
      case 'checkout.submit':
      case 'checkout.retry':
        final generation = _generation;
        final accountId = _delegate.currentAccountId();
        if (await _readSession() == null) {
          throw const MetaversePluginCallException('checkout_not_granted');
        }
        bool active() =>
            generation == _generation &&
            _runtime != null &&
            accountId == _delegate.currentAccountId();
        if (method == 'checkout.status') return _checkout.status(active);
        if (method == 'checkout.recover') return _checkout.recover(active);
        if (method == 'checkout.finish') {
          // 已确认建单的本地记录可以归档，服务端订单仍由订单页管理。
          return _checkout.finish('${params['orderNo']}', active);
        }
        final retry = method == 'checkout.retry';
        final intent = retry ? null : MetaverseOrderIntent.parse(params);
        final origin = _activatedSurface;
        if (!retry && intent == null) {
          throw const MetaversePluginCallException('checkout_invalid_intent');
        }
        return _userInitiatedUi(
          (context) => _checkout.submit(
            intent,
            (grant, order) =>
                context.mounted && active() && origin?.foreground == true
                ? _delegate.confirmOrder(context, grant, order)
                : Future.value(false),
            () => active() && context.mounted,
            retry: retry,
          ),
        );
      case 'auth.query':
        final name = params['name'];
        final args = params['arguments'];
        if (name is! String ||
            args is! Map<String, dynamic> ||
            !manifest.auth.queries.containsKey(name)) {
          throw const MetaversePluginCallException('query_not_granted');
        }
        final generation = _generation;
        final accountId = _delegate.currentAccountId();
        final response = await _network.query(
          manifest,
          name,
          args,
          await _readSession(),
        );
        if (generation != _generation ||
            accountId != _delegate.currentAccountId()) {
          throw const MetaversePluginCallException('auth_required');
        }
        return response;
      case 'checkout.pay':
      case 'checkout.cancel':
        final no = params['orderNo'];
        if (manifest.auth.payment == null ||
            !MetaverseOrderIntent.validId(no)) {
          throw const MetaversePluginCallException('payment_not_granted');
        }
        return _userInitiatedUi(
          (context) => _delegate.payOrder(
            context,
            no as String,
            cancel: method == 'checkout.cancel',
          ),
        );
      case 'auth.request':
        if (manifest.auth.type == MetaversePluginAuthType.readSession &&
            manifest.auth.connect == null) {
          throw const MetaversePluginCallException('native_login_unavailable');
        }
        if (!manifest.auth.required && manifest.auth.connect == null) {
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
          _delegate.openPage(
            context,
            manifest,
            page,
            pageParams is Map ? pageParams.cast<String, Object?>() : const {},
          );
          return null;
        }
        await _userInitiatedUi((context) async {
          _delegate.openPage(
            context,
            manifest,
            page,
            pageParams is Map ? pageParams.cast<String, Object?>() : const {},
          );
        });
        return null;

      case 'session.login':
      case 'session.open':
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
        final rawUrl = params['url'];
        final url = rawUrl is String ? Uri.tryParse(rawUrl) : null;
        if (url == null ||
            url.host.isEmpty ||
            (url.scheme != 'https' && url.scheme != 'http')) {
          throw const MetaversePluginCallException('只能打开 http(s) 链接');
        }
        await _userInitiatedUi((context) => _delegate.openUrl(context, url));
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
    if (key is! String || key.isEmpty || key.length > _maxStorageKey) {
      throw const MetaversePluginCallException('存储键不合法');
    }
    return key;
  }

  Future<Object?> _writeStorage(String key, Object? value) async {
    try {
      await _store.updateStorage(id, key, value);
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
    Future<T> Function(BuildContext context) run,
  ) async {
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
    final context = _surfaceContexts[_activatedSurface];
    _clearActivation();
    if (context == null || !context.mounted) {
      throw const MetaversePluginCallException('没有可见的界面');
    }
    final generation = _generation;
    _uiBusy = true;
    try {
      return await run(context);
    } finally {
      if (generation == _generation) _uiBusy = false;
    }
  }
}
