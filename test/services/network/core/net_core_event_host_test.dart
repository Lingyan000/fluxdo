import 'dart:convert';
import 'dart:ffi';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/core/net_core_bindings.dart';
import 'package:fluxdo/services/network/core/net_core_http_adapter.dart';

class _FakeBindings implements NetCoreBindings {
  _FakeBindings({required this.supportsEventHosts});

  @override
  final bool supportsEventHosts;

  int registerCalls = 0;
  int setCallbackCalls = 0;
  final List<int> unregisteredHosts = [];
  final List<Map<String, dynamic>> startedMeta = [];
  final List<int> cancelledRequests = [];
  int _nextHostId = 10;
  int _nextRequestId = 100;

  @override
  bool get isAvailable => true;

  @override
  String? lastInitError;

  @override
  int registerEventHost(
    Pointer<NativeFunction<NetCoreEventCallback>> callback,
  ) {
    registerCalls++;
    return ++_nextHostId;
  }

  @override
  void unregisterEventHost(int hostId) {
    unregisteredHosts.add(hostId);
  }

  @override
  void setEventCallback(
    Pointer<NativeFunction<NetCoreEventCallback>> callback,
  ) {
    setCallbackCalls++;
  }

  @override
  int requestStart(String metaJson) {
    startedMeta.add(jsonDecode(metaJson) as Map<String, dynamic>);
    return ++_nextRequestId;
  }

  @override
  void requestCancel(int id) {
    cancelledRequests.add(id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('支持多宿主事件回调时为当前 isolate 注册独立 host_id 且释放后取消在途请求', () async {
    final bindings = _FakeBindings(supportsEventHosts: true);
    NetCoreHttpAdapter.releaseEventHost(bindings: bindings);

    final adapter = NetCoreHttpAdapter(bindings: bindings);
    final req1 = adapter.fetch(
      RequestOptions(path: 'https://linux.do/'),
      null,
      null,
    );
    final req2 = adapter.fetch(
      RequestOptions(path: 'https://linux.do/latest.json'),
      null,
      null,
    );

    expect(bindings.registerCalls, 1);
    expect(bindings.setCallbackCalls, 0);
    expect(bindings.startedMeta, hasLength(2));
    expect(bindings.startedMeta[0]['host_id'], 11);
    expect(bindings.startedMeta[1]['host_id'], 11);

    NetCoreHttpAdapter.releaseEventHost(bindings: bindings);
    expect(bindings.unregisteredHosts, [11]);

    await expectLater(
      req1,
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    await expectLater(
      req2,
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );

    // 释放后再次发起请求会重新注册新 host_id，不复用已注销宿主。
    final req3 = adapter.fetch(
      RequestOptions(path: 'https://linux.do/categories.json'),
      null,
      null,
    );
    expect(bindings.registerCalls, 2);
    expect(bindings.startedMeta[2]['host_id'], 12);

    NetCoreHttpAdapter.releaseEventHost(bindings: bindings);
    await expectLater(req3, throwsA(isA<DioException>()));
  });

  test('旧核心不支持多宿主事件回调时自动回退到单槽注册且不下发 host_id', () async {
    final bindings = _FakeBindings(supportsEventHosts: false);
    NetCoreHttpAdapter.releaseEventHost(bindings: bindings);

    final adapter = NetCoreHttpAdapter(bindings: bindings);
    final req = adapter.fetch(
      RequestOptions(path: 'https://linux.do/'),
      null,
      null,
    );

    expect(bindings.registerCalls, 0);
    expect(bindings.setCallbackCalls, 1);
    expect(bindings.startedMeta.single.containsKey('host_id'), isFalse);

    NetCoreHttpAdapter.releaseEventHost(bindings: bindings);
    expect(bindings.unregisteredHosts, isEmpty);
    await expectLater(req, throwsA(isA<DioException>()));
  });
}
