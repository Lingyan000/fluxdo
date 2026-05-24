/// 书签名规范化：去空白后，把 `?` / `？` / 空字符串归为 null。
///
/// 全项目共享同一份规范：
/// - 模型层 `Topic.fromJson` 反序列化时调用此函数清洗服务端脏数据；
/// - 筛选/汇总（如 `buildBookmarkNameSummaries`）用它判定"未设置"分组；
/// - 编辑入口（`BookmarkEditSheet`、`BookmarkNameAutocompleteField`）用它
///   决定文本框初值与候选过滤。
String? normalizeBookmarkName(String? rawName) {
  final trimmed = rawName?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  if (trimmed == '?' || trimmed == '？') {
    return null;
  }
  return trimmed;
}
