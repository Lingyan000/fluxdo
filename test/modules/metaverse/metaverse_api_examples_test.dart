import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/metaverse/developer/metaverse_api_examples.dart';
import 'package:fluxdo/modules/metaverse/plugin/runtime/flutter_js_script_engine.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

Future<void> main() async {
  String? skip;
  try {
    (await IsolateScriptEngine.spawn()).dispose();
  } on MetaverseScriptException catch (error) {
    skip = '脚本引擎原生库不可用: $error';
  }

  group('开发中心公开 API 示例使用真实脚本桥执行', skip: skip, () {
    for (final example in metaverseApiExamples) {
      for (final failure in [false, true]) {
        test('${example.name} failure=$failure', () async {
          final result = Completer<(String, String)>();
          final calls = <String>[];
          final runtime = await MetaversePluginRuntime.start(
            engineFactory: createMetaverseScriptEngine,
            script: example.script,
            bridge: MetaverseDocumentationBridge(
              example: example,
              failure: failure,
              onLog: (level, message) {
                if (level == 'call') {
                  calls.add(message);
                } else if (!result.isCompleted) {
                  result.complete((level, message));
                }
              },
            ),
          );
          addTearDown(runtime.dispose);
          final surface = runtime.openSurface(kind: 'card');
          if (example.userAction) runtime.dispatch(surface, 'action', const {});
          final (level, message) = await result.future.timeout(
            const Duration(seconds: 5),
          );
          expect(calls, isNotEmpty);
          expect(level, failure ? 'error' : 'info');
          if (failure) expect(message, 'demo_permission_denied');
          if (example.name == 'prepareNavigation' && !failure) {
            expect(calls.length, 2);
            expect(message, 'navigation opened');
          }
        });
      }
    }
  });
}
