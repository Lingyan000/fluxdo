import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../models/emoji.dart';
import '../services/discourse/discourse_service.dart';
import 'core_providers.dart';

/// 表情列表 Provider —— SWR(stale-while-revalidate)快照。
///
/// 旧形态(FutureProvider 直等网络)是表情面板"打开先转一整圈
/// LoadingSpinner"的来源:/emojis.json 两千多条、几百 KB,走主 API
/// dio(并发 3 + 限速)还要和话题请求抢队列。
///
/// 现形态:
/// 1. 有磁盘快照 → **立即 emit**(面板 0ms 出结构);
/// 2. 后台拉最新 → 与快照比对,**有变化才落盘 + 再 emit**(面板原地
///    刷新,当场生效;无变化零重建);
/// 3. 无快照(首装)→ 行为同旧:等网络,单次 emit;网络失败且无
///    快照才进 error 态。
final emojiGroupsProvider =
    StreamProvider<Map<String, List<Emoji>>>((ref) async* {
  final service = ref.watch(discourseServiceProvider);

  final snapshotJson = await _EmojiSnapshotStore.load();
  if (snapshotJson != null) {
    Map<String, List<Emoji>>? snapshotGroups;
    try {
      snapshotGroups = parseEmojiGroups(
        jsonDecode(snapshotJson) as Map<String, dynamic>,
      );
    } catch (e) {
      debugPrint('[EmojiProvider] 快照解析失败,回退网络: $e');
    }
    if (snapshotGroups != null && snapshotGroups.isNotEmpty) {
      yield snapshotGroups;
      // 后台刷新:失败静默(快照已在展示,不打扰)。
      try {
        final fresh = await service.getEmojisRaw();
        final freshJson = jsonEncode(fresh);
        if (freshJson != snapshotJson) {
          await _EmojiSnapshotStore.save(freshJson);
          yield parseEmojiGroups(fresh);
        }
      } catch (e) {
        debugPrint('[EmojiProvider] 后台刷新失败(快照兜底): $e');
      }
      return;
    }
  }

  // 无快照:等网络(首装唯一一次),成功即落盘。
  final fresh = await service.getEmojisRaw();
  unawaited(_EmojiSnapshotStore.save(jsonEncode(fresh)));
  yield parseEmojiGroups(fresh);
});

/// /emojis.json 的磁盘快照(ApplicationSupport 下单文件)。
class _EmojiSnapshotStore {
  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/emoji_groups_snapshot.json');
  }

  static Future<String?> load() async {
    try {
      final file = await _file();
      final content = await file.readAsString();
      return content.isEmpty ? null : content;
    } catch (_) {
      return null; // 不存在/读失败都视为无快照
    }
  }

  static Future<void> save(String json) async {
    try {
      final file = await _file();
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(json, flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('[EmojiProvider] 快照落盘失败: $e');
    }
  }
}
