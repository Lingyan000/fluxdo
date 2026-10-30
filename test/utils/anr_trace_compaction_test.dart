import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// ANR trace 压缩算法的交叉验证。
///
/// 线上实现在 `android/app/src/main/kotlin/.../AnrTraceReporter.kt`
/// 的 `compactTrace()`。这里是它的逐行等价 Dart 移植 —— Android 侧没有
/// 可用的 unit test 基建(sourceSet 收录不到测试类),而这套算法上一版
/// 正是因为没实测才错的,所以在能跑的测试基建里交叉验证一遍。
///
/// 要守住的两条:
/// 1. **一个线程都不能丢** —— Flutter 引擎线程(1.ui / 1.raster)排在几十个
///    线程之后,上一版"固定帧数 + 撞总量就 break"的写法会把后半段线程整个
///    丢掉,而凶手恰恰在那里;
/// 2. 结果必须落在 Crashlytics 的 64 KB log 区内(SDK 19.4.3
///    LogFileManager.MAX_LOG_SIZE = 65536,环形队列写满从最旧的丢)。
const int kTraceBudgetBytes = 48000;

/// [AnrTraceReporter.compactTrace] 的等价实现。
String compactTrace(String trace) {
  try {
    final lines = trace.split('\n');
    var threadCount = lines.where((l) => l.startsWith('"')).length;
    if (threadCount < 1) threadCount = 1;

    var headEnd = lines.indexWhere((l) => l.startsWith('"'));
    if (headEnd < 0) headEnd = lines.length;

    final out = StringBuffer();
    var headBytes = 0;
    for (var i = 0; i < headEnd; i++) {
      out.write(lines[i]);
      out.write('\n');
      headBytes += lines[i].length + 1;
    }

    var perThread = (kTraceBudgetBytes - headBytes) ~/ threadCount;
    if (perThread < 200) perThread = 200;

    var usedInThread = 0;
    var omitted = 0;
    void flushOmitted() {
      if (omitted > 0) {
        out.write('      ... +$omitted frames\n');
        omitted = 0;
      }
    }

    for (var i = headEnd; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trimLeft();
      final isThreadHeader = line.startsWith('"');
      final isFrame = trimmed.startsWith('at ') ||
          trimmed.startsWith('- ') ||
          trimmed.startsWith('native: ');

      if (isThreadHeader) {
        flushOmitted();
        usedInThread = line.length + 1;
        out.write(line);
        out.write('\n');
      } else if (isFrame) {
        if (usedInThread + line.length + 1 <= perThread) {
          out.write(line);
          out.write('\n');
          usedInThread += line.length + 1;
        } else {
          omitted++;
        }
      } else {
        flushOmitted();
        out.write(line);
        out.write('\n');
        usedInThread += line.length + 1;
      }
    }
    flushOmitted();
    return out.toString();
  } catch (_) {
    return trace.length > kTraceBudgetBytes
        ? trace.substring(0, kTraceBudgetBytes)
        : trace;
  }
}

int _threadCount(String s) =>
    const LineSplitter().convert(s).where((l) => l.startsWith('"')).length;

/// 上一版的做法,用于对照证明新算法确有必要。
String legacyTruncate(String trace, {int maxChars = 60000}) =>
    trace.length > maxChars ? trace.substring(0, maxChars) : trace;

void main() {
  group('ANR trace 压缩', () {
    test('真实 dump:线程一个不丢且落在 64KB 内', () {
      final f = File('test/fixtures/anr_sample.txt');
      if (!f.existsSync()) {
        markTestSkipped('样本缺失: ${f.path}');
        return;
      }
      final trace = f.readAsStringSync();
      final before = _threadCount(trace);
      expect(before, greaterThan(20), reason: '样本应含多个线程');

      final result = compactTrace(trace);
      final after = _threadCount(result);
      final bytes = utf8.encode(result).length;

      // ignore: avoid_print
      print('原始 ${trace.length} 字符 / $before 线程');
      // ignore: avoid_print
      print('压缩 ${result.length} 字符 / $after 线程 / $bytes 字节');

      expect(after, before, reason: '丢失了 ${before - after} 个线程');
      expect(bytes, lessThan(65536), reason: '超出 Crashlytics 64KB log 区');
    });

    test('对照:上一版截断会丢掉后半段线程', () {
      final f = File('test/fixtures/anr_sample.txt');
      if (!f.existsSync()) {
        markTestSkipped('样本缺失');
        return;
      }
      final trace = f.readAsStringSync();
      final legacy = legacyTruncate(trace);
      final legacyThreads = _threadCount(legacy);
      final allThreads = _threadCount(trace);

      // ignore: avoid_print
      print('上一版截断: $legacyThreads/$allThreads 线程');
      expect(
        legacyThreads,
        lessThan(allThreads),
        reason: '若这条不成立说明样本太小,不足以复现线上场景',
      );
    });

    test('引擎线程排在最后也能存活', () {
      // 复刻线上真实排布:大量噪声线程在前,1.ui / 1.raster 垫底
      final sb = StringBuffer('----- pid 999 -----\n');
      for (var i = 0; i < 80; i++) {
        sb.write('"noise-$i" prio=5 tid=$i Native\n');
        for (var j = 0; j < 40; j++) {
          sb.write('  at com.example.Noise.method$j(Noise.java:$j)\n');
        }
      }
      sb.write('"1.ui" prio=5 tid=900 Runnable\n');
      sb.write('  at io.flutter.MarkerUi.frame(Marker.java:1)\n');
      sb.write('"1.raster" prio=5 tid=901 Runnable\n');
      sb.write('  at io.flutter.MarkerRaster.draw(Marker.java:2)\n');
      final trace = sb.toString();

      final result = compactTrace(trace);

      expect(result.contains('"1.ui"'), isTrue, reason: '1.ui 线程丢失');
      expect(result.contains('"1.raster"'), isTrue, reason: '1.raster 线程丢失');
      expect(result.contains('MarkerUi.frame'), isTrue, reason: '引擎栈顶帧丢失');
      expect(result.contains('MarkerRaster.draw'), isTrue, reason: '引擎栈顶帧丢失');
      expect(utf8.encode(result).length, lessThan(65536));

      // 同一输入下,上一版会把这两个线程整个丢掉 —— 这正是线上取不到证据的原因
      final legacy = legacyTruncate(trace);
      expect(
        legacy.contains('"1.raster"'),
        isFalse,
        reason: '若上一版也能保住,说明这个对照样本没有说服力',
      );
    });

    test('短 trace 原样保留,不做无谓折叠', () {
      const trace = '----- pid 123 -----\n'
          '"main" prio=5 tid=1 Native\n'
          '  at java.lang.Object.wait(Native method)\n'
          '  at foo.Bar.baz(Bar.java:1)\n'
          '"1.ui" prio=5 tid=25 Runnable\n'
          '  at io.flutter.Engine.doFrame(Engine.java:2)\n';

      final result = compactTrace(trace);
      expect(_threadCount(result), _threadCount(trace));
      expect(result.contains('... +'), isFalse);
    });

    test('空输入与畸形输入不抛异常', () {
      expect(compactTrace(''), isNotNull);
      expect(compactTrace('no thread header at all\njust text'), isNotNull);
      expect(compactTrace('"only header"'), isNotNull);
    });
  });
}
