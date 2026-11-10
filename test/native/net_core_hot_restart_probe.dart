// 设置 FLUXDO_PROBE_URL 为进程外流式 HTTP 服务，再运行：
// flutter run -d macos -t test/native/net_core_hot_restart_probe.dart
// 可设置 FLUXDO_PROBE_DUPLICATE 为临时 dylib 路径，强制制造第二份同 UUID 映像。
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/widgets.dart';
import 'package:fluxdo/services/network/core/net_core_http_adapter.dart';
import 'package:fluxdo/services/network/core/net_core_service.dart';

int _coreImageCount(DynamicLibrary process) {
  final count = process.lookupFunction<Uint32 Function(), int Function()>(
    '_dyld_image_count',
  );
  final name = process
      .lookupFunction<
        Pointer<Utf8> Function(Uint32),
        Pointer<Utf8> Function(int)
      >('_dyld_get_image_name');
  var result = 0;
  for (var i = 0; i < count(); i++) {
    final path = name(i);
    if (path != nullptr &&
        path.toDartString().endsWith('libfluxdo_net.dylib')) {
      result++;
    }
  }
  return result;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: Text('Network hot restart regression probe')),
    ),
  );
  final duplicate = Platform.environment['FLUXDO_PROBE_DUPLICATE'];
  if (duplicate != null && !File(duplicate).existsSync()) {
    final executable = File(Platform.resolvedExecutable).parent;
    final library = File(
      '${executable.path}/../Frameworks/libfluxdo_net.dylib',
    );
    File(duplicate).parent.createSync(recursive: true);
    await library.copy(duplicate);
    DynamicLibrary.open(duplicate);
  }
  final process = DynamicLibrary.process();
  final coreAddress = process.lookup<Void>('fluxdo_net_init').address;
  final images = _coreImageCount(process);
  // 服务不能运行在待重启的 isolate 中，否则 HttpResponse.flush 的 socket
  // 写入可能干扰 VM 服务事件调度，使探针自身无法响应热重启。
  final url = Platform.environment['FLUXDO_PROBE_URL'];
  if (url == null) {
    throw StateError('Set FLUXDO_PROBE_URL to an external stream');
  }
  final core = NetCoreService.instance;
  if (!await core.start(const NetCoreConfig())) {
    throw StateError('Probe network core failed: ${core.lastError}');
  }
  final dio = Dio()..httpClientAdapter = NetCoreHttpAdapter();
  final response = await dio.get<ResponseBody>(
    url,
    options: Options(responseType: ResponseType.stream),
  );
  var ready = false;
  var bytes = 0;
  await for (final chunk in response.data!.stream) {
    bytes += chunk.length;
    if (!ready && bytes >= 65536) {
      ready = true;
      // 测试驱动读取此标记；不能使用会节流的 debugPrint。
      // ignore: avoid_print
      print(
        'HOT_RESTART_PROBE_READY core=$coreAddress images=$images bytes=$bytes',
      );
    }
  }
}
