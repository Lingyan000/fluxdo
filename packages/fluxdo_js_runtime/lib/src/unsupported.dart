import '../fluxdo_js_runtime.dart';

Future<JsWorker> spawn(
  String debugName,
  String? channel,
  Duration timeout,
  int memoryLimit,
  int stackLimit,
) => Future.error(UnsupportedError('当前平台不支持原生 JS 运行时'));
