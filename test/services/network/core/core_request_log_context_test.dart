import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/core/core_request_log_context.dart';

void main() {
  test('并发请求归属独立，完成后仍能关联晚到日志', () {
    final contexts = CoreRequestLogContext();
    contexts.register(1, {'pluginId': 'example.one'});
    contexts.register(2, {'pluginId': 'example.two'});
    contexts.complete(1);
    expect(contexts.fieldsFor(1)['pluginId'], 'example.one');
    expect(contexts.fieldsFor(2)['pluginId'], 'example.two');
    expect(contexts.fieldsFor(null), isEmpty);
    expect(contexts.fieldsFor(3), isEmpty);
  });

  test('结束缓存有界，在途归属保留，请求号复用覆盖旧记录', () {
    final contexts = CoreRequestLogContext(completedLimit: 2);
    contexts.register(100, {'pluginId': 'active'});
    for (var id = 1; id <= 3; id++) {
      contexts.register(id, {'traceId': 'trace-$id'});
      contexts.complete(id);
    }
    expect(contexts.fieldsFor(1), isEmpty);
    expect(contexts.fieldsFor(2)['traceId'], 'trace-2');
    expect(contexts.fieldsFor(100)['pluginId'], 'active');
    contexts.register(3, {'traceId': 'replacement'});
    expect(contexts.fieldsFor(3)['traceId'], 'replacement');
    contexts.complete(3);
    expect(contexts.fieldsFor(3)['traceId'], 'replacement');
  });

  test('归属快照不可变，核心未受理的零号请求不登记', () {
    final contexts = CoreRequestLogContext();
    final fields = <String, Object>{'pluginId': 'original'};
    contexts.register(1, fields);
    fields['pluginId'] = 'changed';
    expect(contexts.fieldsFor(1)['pluginId'], 'original');
    expect(() => contexts.fieldsFor(1).clear(), throwsUnsupportedError);
    contexts.register(0, fields);
    expect(contexts.fieldsFor(0), isEmpty);
  });
}
