import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/draft.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/draft_controller.dart';

class _DraftService implements DiscourseService {
  final pending = <Completer<int>>[];

  @override
  Future<Draft?> getDraft(String key) async => null;

  @override
  Future<int> saveDraft({
    required String draftKey,
    required DraftData data,
    int sequence = 0,
    bool forceSave = false,
  }) {
    final result = Completer<int>();
    pending.add(result);
    return result.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final next in [
    const DraftData(reply: '继续编辑的新内容', action: 'reply'),
    const DraftData(reply: '', action: 'reply'),
  ]) {
    test('旧草稿保存完成不能覆盖当前未保存状态 hasContent=${next.hasContent}', () async {
      final service = _DraftService();
      final controller = DraftController(
        draftKey: 'topic_1',
        service: service,
        accountIdResolver: () async => null,
      );
      addTearDown(controller.dispose);
      final save = controller.saveNow(
        const DraftData(reply: '旧内容', action: 'reply'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(service.pending, hasLength(1));
      controller.scheduleSave(next);
      service.pending.single.complete(1);
      await save;
      expect(
        controller.status,
        next.hasContent ? DraftSaveStatus.pending : DraftSaveStatus.idle,
      );
    });
  }

  test('提交期间迟到的草稿结果不能重新显示保存提示', () async {
    final service = _DraftService();
    final controller = DraftController(
      draftKey: 'topic_1',
      service: service,
      accountIdResolver: () async => null,
    );
    addTearDown(controller.dispose);
    final save = controller.saveNow(
      const DraftData(reply: '待提交', action: 'reply'),
    );
    await Future<void>.delayed(Duration.zero);
    controller.disable();
    service.pending.single.complete(1);
    await save;
    expect(controller.status, DraftSaveStatus.idle);
  });
}
