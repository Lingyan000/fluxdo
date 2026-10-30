import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_submission_snapshot.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('快照比较前同步，并读取同步后的最后字符', () {
    var raw = '旧正文';
    final snapshot = ComposerSubmissionSnapshot(['最后字符']);
    expect(
      snapshot.verify(
        synchronize: () {
          raw = '最后字符';
          return true;
        },
        read: () => [raw],
      ),
      isTrue,
    );
  });

  test('同步失败不得继续读取或发送', () {
    final snapshot = ComposerSubmissionSnapshot(['正文']);
    expect(
      snapshot.verify(
        synchronize: () => false,
        read: () => throw StateError('不得读取旧镜像'),
      ),
      isFalse,
    );
  });

  test('异步确认期间正文或元数据变化都要求重试', () async {
    for (final latest in <List<Object?>>[
      ['新正文', '标题', 1, '标签'],
      ['正文', '新标题', 1, '标签'],
      ['正文', '标题', 2, '标签'],
      ['正文', '标题', 1, '新标签'],
    ]) {
      final snapshot = ComposerSubmissionSnapshot(['正文', '标题', 1, '标签']);
      await Future<void>.value();
      expect(
        snapshot.verify(synchronize: () => true, read: () => latest),
        isFalse,
      );
    }
  });
}
