import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fluxdo/modules/cdk/services/cdk_client.dart';

Map<String, dynamic> cdkProject({
  String id = 'project-1',
  bool paid = false,
  bool received = false,
  int stock = 3,
}) => {
  'id': id,
  'name': '社区工具体验码',
  'description': '领取后可使用体验额度。每个账号仅限领取一次。',
  'distribution_type': 0,
  'total_items': 10,
  'available_items_count': stock,
  'price': paid ? '12.50' : '0',
  'minimum_trust_level': 2,
  'risk_level': 20,
  'allow_same_ip': false,
  'creator_username': 'creator',
  'start_time': DateTime.now()
      .toUtc()
      .subtract(const Duration(days: 1))
      .toIso8601String(),
  'end_time': DateTime.now()
      .toUtc()
      .add(const Duration(days: 10))
      .toIso8601String(),
  'tags': ['工具', '体验'],
  'is_received': received,
  'received_content': received ? 'SAMPLE-ONLY-1234' : '',
};

Map<String, dynamic> cdkPending() => {
  'has_pending': true,
  'amount': '12.50',
  'pay_url': 'https://credit.linux.do/epay/pay/submit.php?out_trade_no=CDK20260101&money=12.50&sign=fixture',
};

class CdkFixture implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  bool paid = false, received = false, hasPending = false, timeout = false;
  bool active = true;
  int stock = 3, total = 21, status = 200, verificationCount = 0;
  String? errorMessage;
  Completer<void>? hold, entered;
  Completer<List<String>>? pendingTags;
  late final client = CdkClient(
    dio: Dio()..httpClientAdapter = this,
    checkSession: () async {
      if (!active) throw StateError('account changed');
    },
    verifyAccount: () async {
      verificationCount++;
    },
  );
  @override
  Future<ResponseBody> fetch(
    RequestOptions request,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    requests.add(request);
    entered?.complete();
    entered = null;
    await hold?.future;
    Object? data;
    final path = request.uri.path;
    if (request.method == 'POST') {
      if (timeout) {
        throw DioException.receiveTimeout(
          timeout: const Duration(seconds: 1),
          requestOptions: request,
        );
      }
      if (paid) {
        hasPending = true;
        data = {
          ...cdkPending(),
          'require_payment': true,
          'out_trade_no': 'CDK20260101',
        };
      } else {
        received = true;
        data = {'itemContent': 'SAMPLE-ONLY-1234'};
      }
    } else if (path.endsWith('/pending-payment')) {
      data = hasPending ? cdkPending() : {'has_pending': false};
    } else if (path.endsWith('/tags')) {
      data = await pendingTags?.future ?? ['工具', '体验'];
    } else if (path.endsWith('/projects')) {
      final page = int.parse('${request.queryParameters['current']}');
      data = {
        'total': total,
        'results': [
          for (var i = (page - 1) * 20; i < page * 20 && i < total; i++)
            {
              ...cdkProject(id: 'project-$i', paid: i.isEven),
              'name': '社区工具体验码 ${i + 1}',
            },
        ],
      };
    } else if (path.endsWith('/received')) {
      data = {
        'total': 1,
        'results': [
          {
            'project_id': 'project-1',
            'project_name': '社区工具体验码',
            'project_creator': 'creator',
            'content': 'SAMPLE-ONLY-1234',
            'received_at': '2026-11-01T02:30:00Z',
          },
        ],
      };
    } else if (path.endsWith('/chart')) {
      data = [
        for (var i = 1; i <= 7; i++) {'date': '2026-11-0$i', 'count': i % 4},
      ];
    } else if (path.endsWith('/stats/all')) {
      data = {
        'summary': jsonEncode({
          'totalUsers': 12340,
          'totalProjects': 250,
          'totalReceived': 5480,
          'recentReceived': 96,
        }),
        'activityData': [
          for (var i = 1; i <= 7; i++) {'date': '2026-11-0$i', 'value': i * 12},
        ],
        'projectTags': [
          {'name': '工具', 'value': 42},
        ],
      };
    } else {
      data = cdkProject(paid: paid, received: received, stock: stock);
    }
    return ResponseBody.fromString(
      jsonEncode({'error_msg': errorMessage ?? '', 'data': data}),
      status,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
