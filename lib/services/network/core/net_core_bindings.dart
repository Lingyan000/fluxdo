import 'dart:ffi';
import 'dart:io';

import 'dart:convert';

import 'package:ffi/ffi.dart';

import '../../app_logger.dart';
import '../../network_logger.dart';

/// 网络核心的 FFI 绑定：加载动态库并暴露 C 接口。
///
/// 请求不经本地 socket，而是把请求交给核心、经事件回调拿回响应，
/// 因此每个平台都必须能加载到库；加载失败时宿主回退到 Dart IO 应急路径。
class NetCoreBindings {
  NetCoreBindings._();

  static final NetCoreBindings instance = NetCoreBindings._();

  bool _initialized = false;

  /// 只尝试一次：符号字段是 late final，重复赋值会抛错并盖掉首次失败的真实原因。
  bool _attempted = false;

  /// 最近一次加载失败的原因，供设置页与日志展示。
  String? lastInitError;

  bool get isAvailable => _initialized || initialize();

  int Function(Pointer<Utf8>)? _verifyWebViewCertificate;

  /// 使用运行中核心的 CA 验证，宿主不能自行指定信任根。
  bool verifyWebViewCertificate(List<int> der, String host) {
    if (der.isEmpty ||
        der.length > 65536 ||
        host.isEmpty ||
        host.length > 253 ||
        !isAvailable) {
      return false;
    }
    final verify = _verifyWebViewCertificate;
    if (verify == null) return false;
    final input = jsonEncode({"der": base64Encode(der), "host": host})
        .toNativeUtf8();
    try {
      return verify(input) == 1;
    } finally {
      calloc.free(input);
    }
  }

  late final void Function() _initLogging;
  late final void Function(Pointer<NativeFunction<NetCoreLogCallback>>)
  _setLogCallback;
  late final void Function(int) _setLogLevel;

  /// 持有引用：回调在进程生命周期内一直被核心调用
  // ignore: unused_field
  NativeCallable<NetCoreLogCallback>? _logCallback;
  late final void Function(Pointer<NativeFunction<NetCoreEventCallback>>)
  _setEventCallback;
  late final int Function(Pointer<Utf8>) _init;
  late final void Function() _shutdown;
  late final Pointer<Utf8> Function() _statusJson;
  late final void Function() _resetConnections;
  late final Pointer<Utf8> Function() _generateCa;
  late final void Function(Pointer<Utf8>) _freeString;
  late final void Function(Pointer<Uint8>, int) _bufferFree;
  late final Pointer<Utf8> Function() _dnsCacheJson;
  late final void Function() _clearDnsCache;
  late final int Function(Pointer<Utf8>) _setEchDnsPolicy;
  late final int Function(Pointer<Utf8>) _requestStart;
  late final int Function(int, Pointer<Uint8>, int) _requestWrite;
  late final void Function(int) _requestFinish;
  late final void Function(int) _requestCancel;
  late final void Function(int) _requestPause;
  late final void Function(int) _requestResume;

  bool initialize() {
    if (_initialized) return true;
    if (_attempted) return false;
    _attempted = true;
    final lib = _loadLibrary();
    if (lib == null) return false;
    try {
      try {
        _verifyWebViewCertificate = lib
            .lookupFunction<
              Int32 Function(Pointer<Utf8>),
              int Function(Pointer<Utf8>)
            >('fluxdo_net_verify_webview_certificate');
      } catch (_) {
        /* 旧核心无校验接口时不放行证书。 */
      }
      _initLogging = lib.lookupFunction<Void Function(), void Function()>(
        'fluxdo_net_init_logging',
      );
      _setLogCallback = lib
          .lookupFunction<
            Void Function(Pointer<NativeFunction<NetCoreLogCallback>>),
            void Function(Pointer<NativeFunction<NetCoreLogCallback>>)
          >('fluxdo_net_set_log_callback');
      _setLogLevel = lib
          .lookupFunction<Void Function(Uint8), void Function(int)>(
            'fluxdo_net_set_log_level',
          );
      _setEventCallback = lib
          .lookupFunction<
            Void Function(Pointer<NativeFunction<NetCoreEventCallback>>),
            void Function(Pointer<NativeFunction<NetCoreEventCallback>>)
          >('fluxdo_net_set_event_callback');
      _init = lib
          .lookupFunction<
            Int32 Function(Pointer<Utf8>),
            int Function(Pointer<Utf8>)
          >('fluxdo_net_init');
      _shutdown = lib.lookupFunction<Void Function(), void Function()>(
        'fluxdo_net_shutdown',
      );
      _statusJson = lib
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'fluxdo_net_status_json',
          );
      _resetConnections = lib.lookupFunction<Void Function(), void Function()>(
        'fluxdo_net_reset_connections',
      );
      _generateCa = lib
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'fluxdo_net_generate_ca',
          );
      _freeString = lib
          .lookupFunction<
            Void Function(Pointer<Utf8>),
            void Function(Pointer<Utf8>)
          >('fluxdo_net_free_string');
      _bufferFree = lib
          .lookupFunction<
            Void Function(Pointer<Uint8>, Size),
            void Function(Pointer<Uint8>, int)
          >('fluxdo_net_buffer_free');
      _dnsCacheJson = lib
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'fluxdo_net_dns_cache_json',
          );
      _clearDnsCache = lib.lookupFunction<Void Function(), void Function()>(
        'fluxdo_net_clear_dns_cache',
      );
      _setEchDnsPolicy = lib
          .lookupFunction<
            Int32 Function(Pointer<Utf8>),
            int Function(Pointer<Utf8>)
          >('fluxdo_net_set_ech_dns_policy');
      _requestStart = lib
          .lookupFunction<
            Uint64 Function(Pointer<Utf8>),
            int Function(Pointer<Utf8>)
          >('fluxdo_net_request_start');
      _requestWrite = lib
          .lookupFunction<
            Int32 Function(Uint64, Pointer<Uint8>, Size),
            int Function(int, Pointer<Uint8>, int)
          >('fluxdo_net_request_write');
      _requestFinish = lib
          .lookupFunction<Void Function(Uint64), void Function(int)>(
            'fluxdo_net_request_finish',
          );
      _requestCancel = lib
          .lookupFunction<Void Function(Uint64), void Function(int)>(
            'fluxdo_net_request_cancel',
          );
      _requestPause = lib
          .lookupFunction<Void Function(Uint64), void Function(int)>(
            'fluxdo_net_request_pause',
          );
      _requestResume = lib
          .lookupFunction<Void Function(Uint64), void Function(int)>(
            'fluxdo_net_request_resume',
          );
      // 先接好日志出口再初始化：启动阶段的日志也要进应用日志
      _bindLogging();
      _initLogging();
      if (Platform.isAndroid && !_initAndroidContext(lib)) {
        return false;
      }
      _initialized = true;
      return true;
    } catch (e) {
      _recordInitError('网络核心符号缺失: $e');
      return false;
    }
  }

  /// 核心日志转进应用日志（type: network），级别跟随详细日志开关：
  /// 平时只收 info 及以上，开发者模式下连 debug（逐请求耗时等）一起收。
  void _bindLogging() {
    final callback = NativeCallable<NetCoreLogCallback>.listener(_onLog);
    _setLogCallback(callback.nativeFunction);
    _logCallback = callback;
    void syncLevel() => _setLogLevel(AppLogger.verboseNotifier.value ? 4 : 3);
    syncLevel();
    AppLogger.verboseNotifier.addListener(syncLevel);
  }

  static void _onLog(int level, Pointer<Uint8> ptr, int length) {
    String target = '';
    Map<String, dynamic>? fields;
    String message;
    try {
      final payload = utf8.decode(
        ptr.asTypedList(length),
        allowMalformed: true,
      );
      try {
        final decoded = jsonDecode(payload) as Map<String, dynamic>;
        fields = (decoded['fields'] as Map?)?.cast<String, dynamic>();
        target = decoded['target'] as String? ?? '';
        message = decoded['message'] as String? ?? payload;
      } catch (_) {
        message = payload;
      }
    } finally {
      instance._bufferFree(ptr, length);
    }
    NetworkLogger.logCore(
      level: level,
      target: target,
      message: message,
      fields: fields,
    );
  }

  void _recordInitError(String error) {
    lastInitError = error;
    NetworkLogger.log('[Core] $error', level: 'error');
  }

  /// Application.onCreate 中的 Kotlin 桥必须先完成系统证书校验环境初始化。
  bool _initAndroidContext(DynamicLibrary lib) {
    try {
      final ready = lib.lookupFunction<Int32 Function(), int Function()>(
        'fluxdo_net_android_ready',
      );
      if (ready() != 1) {
        _recordInitError('网络核心安卓运行环境尚未就绪');
        return false;
      }
      return true;
    } catch (e) {
      _recordInitError('网络核心未能取得安卓运行环境: $e');
      return false;
    }
  }

  /// [requestWrite] 的返回值：核心的请求体缓冲已满，稍后重试。
  static const int writeWouldBlock = 1;

  void setEventCallback(
    Pointer<NativeFunction<NetCoreEventCallback>> callback,
  ) => _setEventCallback(callback);

  /// 启动核心，返回本地监听端口；-1 表示失败。
  int start(String configJson) => _withUtf8(configJson, _init);

  void shutdown() => _shutdown();

  void resetConnections() => _resetConnections();

  String? statusJson() => _takeString(_statusJson());

  String? generateCa() => _takeString(_generateCa());

  String? dnsCacheJson() => _takeString(_dnsCacheJson());

  void clearDnsCache() => _clearDnsCache();

  int setEchDnsPolicy(String policyJson) =>
      _withUtf8(policyJson, _setEchDnsPolicy);

  int requestStart(String metaJson) => _withUtf8(metaJson, _requestStart);

  int requestWrite(int id, Pointer<Uint8> data, int length) =>
      _requestWrite(id, data, length);

  void requestFinish(int id) => _requestFinish(id);

  void requestCancel(int id) => _requestCancel(id);

  void requestPause(int id) => _requestPause(id);

  void requestResume(int id) => _requestResume(id);

  void bufferFree(Pointer<Uint8> ptr, int length) => _bufferFree(ptr, length);

  T _withUtf8<T>(String value, T Function(Pointer<Utf8>) action) {
    final ptr = value.toNativeUtf8();
    try {
      return action(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  /// 读取核心返回的字符串并归还其内存。
  String? _takeString(Pointer<Utf8> ptr) {
    if (ptr == nullptr) return null;
    try {
      return ptr.toDartString();
    } finally {
      _freeString(ptr);
    }
  }

  DynamicLibrary? _loadLibrary() {
    try {
      if (Platform.isIOS) {
        // iOS 静态链接进主程序
        return DynamicLibrary.process();
      }
      if (Platform.isAndroid) {
        return DynamicLibrary.open('libfluxdo_net.so');
      }
      if (Platform.isMacOS) {
        return _loadBundled(
          'libfluxdo_net.dylib',
          bundleDirs: const ['../Frameworks', '../Resources/native'],
          sourceDirs: const ['macos/Runner/native'],
        );
      }
      if (Platform.isWindows) {
        return _loadBundled(
          'fluxdo_net.dll',
          bundleDirs: const ['native'],
          sourceDirs: const ['windows/runner/native'],
        );
      }
      if (Platform.isLinux) {
        return _loadBundled(
          'libfluxdo_net.so',
          // linux/CMakeLists.txt 把 runner/native/ 装到 bundle 的 native/ 下
          bundleDirs: const ['native'],
          sourceDirs: const ['linux/runner/native'],
        );
      }
    } catch (e) {
      _recordInitError('加载网络核心失败: $e');
    }
    return null;
  }

  /// 按候选目录找库。
  ///
  /// [bundleDirs] 相对可执行文件，是随包安装的位置；[sourceDirs] 与
  /// `core/net_core/target` 相对项目根，供 `flutter run` 的开发构建使用。
  DynamicLibrary _loadBundled(
    String libName, {
    required List<String> bundleDirs,
    required List<String> sourceDirs,
  }) {
    final execDir = File(Platform.resolvedExecutable).parent.path;
    final roots = <String>[
      ?_projectRootFromBuildPath(Platform.resolvedExecutable),
      Directory.current.path,
    ];
    final candidates = <String>[
      for (final dir in bundleDirs) '$execDir/$dir/$libName',
      for (final root in roots) ...[
        for (final dir in sourceDirs) '$root/$dir/$libName',
        '$root/core/net_core/target/release/$libName',
        '$root/core/net_core/target/debug/$libName',
      ],
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) {
        NetworkLogger.log('[Core] 加载网络核心: $path');
        return DynamicLibrary.open(path);
      }
    }
    // 交给系统搜索路径
    return DynamicLibrary.open(libName);
  }

  String? _projectRootFromBuildPath(String execPath) {
    final normalized = execPath.replaceAll('\\', '/');
    final buildIndex = normalized.indexOf('/build/');
    return buildIndex > 0 ? normalized.substring(0, buildIndex) : null;
  }
}

/// 日志回调的原生签名：`(级别, 载荷指针, 载荷长度)`。
/// 级别 1 error、2 warn、3 info、4 debug；载荷为 `{"target","message"}` JSON。
typedef NetCoreLogCallback = Void Function(Uint8, Pointer<Uint8>, Size);

/// 事件回调的原生签名：`(请求 id, 事件类型, 载荷指针, 载荷长度)`。
typedef NetCoreEventCallback = Void Function(
  Uint64,
  Uint8,
  Pointer<Uint8>,
  Size,
);

/// 核心回传的事件类型，取值与 Rust 侧一致。
enum NetCoreEventKind {
  head(0),
  data(1),
  done(2),
  error(3);

  const NetCoreEventKind(this.code);

  final int code;

  static NetCoreEventKind? fromCode(int code) {
    for (final kind in values) {
      if (kind.code == code) return kind;
    }
    return null;
  }
}
