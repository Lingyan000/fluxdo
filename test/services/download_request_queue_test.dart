import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/download_request_queue.dart';

void main() {
  test('下层下载一直不完成时市场仍获得保留槽', () async {
    final q = DownloadRequestQueue(3, reservedHighSlots: 1);
    await q.acquire('lower1', DownloadPriority.normal);
    await q.acquire('lower2', DownloadPriority.normal);
    var lowerStarted = false;
    final lower = q
        .acquire('lower3', DownloadPriority.normal)
        .then((_) => lowerStarted = true);
    await q.acquire('market', DownloadPriority.high);
    expect(lowerStarted, isFalse);
    q.release();
    await Future<void>.delayed(Duration.zero);
    expect(lowerStarted, isFalse);
    q.release();
    await lower;
    expect(lowerStarted, isTrue);
    q.release();
    q.release();
    expect(q.release, throwsStateError);
  });
  test('提权已有后台排队URL无需等下层释放且保持FIFO', () async {
    final q = DownloadRequestQueue(3, reservedHighSlots: 1);
    await q.acquire('a', DownloadPriority.normal);
    await q.acquire('b', DownloadPriority.normal);
    final order = <String>[];
    final c = q
        .acquire('c', DownloadPriority.normal)
        .then((_) => order.add('c'));
    final d = q
        .acquire('d', DownloadPriority.normal)
        .then((_) => order.add('d'));
    q.bump('d');
    q.bump('d');
    await d;
    expect(order, ['d']);
    q.release();
    q.release();
    await c;
    expect(order, ['d', 'c']);
    q.release();
    q.release();
  });
  test('普通通道不预留槽，高优释放时先行', () async {
    final q = DownloadRequestQueue(1);
    await q.acquire('a', DownloadPriority.normal);
    final order = <String>[];
    final low = q
        .acquire('b', DownloadPriority.normal)
        .then((_) => order.add('b'));
    final high = q
        .acquire('c', DownloadPriority.high)
        .then((_) => order.add('c'));
    q.release();
    await high;
    q.release();
    await low;
    expect(order, ['c', 'b']);
    q.release();
  });
}
