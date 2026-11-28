import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluxdo/modules/metaverse/plugin/runtime/flutter_js_script_engine.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

void emit(Object? value) => stdout.writeln(jsonEncode(value));
Future<void> main(List<String> args) async {
  final engine = await IsolateScriptEngine.spawn();
  engine.onMessage = (value) => emit({'type': 'message', 'message': value});
  engine.onFatal = (reason) => emit({'type': 'fatal', 'error': reason});
  await engine.evaluate(metaversePluginPrelude);
  emit({'type': 'ready'});
  try {
    if (args.contains('--check')) return;
    await for (final line
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      final command = jsonDecode(line) as Map;
      if (command['type'] == 'close') break;
      try {
        await engine.evaluate(
          command['code'] as String,
          name: command['name'] as String? ?? 'dev-probe.js',
        );
        emit({'type': 'result', 'id': command['id'], 'ok': true});
      } catch (error) {
        emit({
          'type': 'result',
          'id': command['id'],
          'ok': false,
          'error': error.toString(),
        });
      }
    }
  } finally {
    engine.dispose();
    await engine.terminated;
  }
}
