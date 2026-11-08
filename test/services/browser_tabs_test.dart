import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/browser_tabs.dart';

void main() {
  test('恢复等待旧宿主卸载，连续点击只取出一次且保留同一实例', () async {
    final tabs = BrowserTabsController();
    final tab = BrowserTabSession(url: 'https://example.com');
    final token = tab.keepAlive;
    tab.attach();
    tabs.minimize(tab);
    tabs.minimize(tab);
    expect(tabs.tabs, [tab]);
    var restored = false;
    final first = tabs.take(tab).then((value) {
      restored = true;
      return value;
    });
    expect(await tabs.take(tab), isNull);
    expect(restored, isFalse);
    tab.detach();
    expect(await first, same(tab));
    expect(tab.keepAlive, same(token));
    expect(tabs.tabs, isEmpty);
    tab.attach();
    tab.detach();
    await tab.close();
    tabs.dispose();
  });

  test('退场时关闭不提前销毁原生实例，不恢复已关闭页面且只释放一次', () async {
    var releases = 0;
    final tabs = BrowserTabsController();
    final tab = BrowserTabSession(url: '', release: (_) async => releases++)
      ..hasWebView = true;
    tab.attach();
    tabs.minimize(tab);
    final pending = tabs.take(tab);
    tabs.close(tab);
    await Future<void>.delayed(Duration.zero);
    expect(releases, 0);
    tab.detach();
    expect(await pending, isNull);
    await tab.close();
    await tab.close();
    expect(releases, 1);
    expect(() => tab.attach(), throwsStateError);
    tabs.dispose();
  });

  test('全部关闭释放所有已创建实例，空白未创建页无需平台调用', () async {
    var releases = 0;
    final tabs = BrowserTabsController();
    final a = BrowserTabSession(url: 'a', release: (_) async => releases++)
      ..hasWebView = true;
    final b = BrowserTabSession(url: 'b', release: (_) async => releases++)
      ..hasWebView = true;
    final blank = BrowserTabSession(url: '', release: (_) async => releases++);
    for (final tab in [a, b, blank]) {
      tabs.minimize(tab);
    }
    tabs.closeAll();
    await Future.wait([a.close(), b.close(), blank.close()]);
    expect(tabs.tabs, isEmpty);
    expect(releases, 2);
    tabs.dispose();
  });
}
