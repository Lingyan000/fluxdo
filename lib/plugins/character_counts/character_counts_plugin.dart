import 'package:flutter/widgets.dart';

import '../../l10n/s.dart';
import '../site_plugin.dart';

/// 字数计数器的站点补充文案（对齐 linux.do 的 character-counts 主题组件）
///
/// 主题组件 `299ba1d7...js` 在正文计数器里写死了一句社区自有的劝阻文案：
///
/// ```js
/// get charCount() {
///   const e = this.args.showWarning ? " 勿用各类字数补丁" : "";
///   return this.showRequired ? `${length} / ${minimumLength}${e}` : ...;
/// }
/// ```
///
/// `showWarning` 只在正文插槽（after-d-editor）传 true，标题插槽不传，
/// 因此该文案仅在**正文且字数不足**时出现。计数器本身是通用能力，放在
/// 通用组件里；这句社区特有措辞由本插件提供，其他社区不会看到。
class CharacterCountsPlugin extends SitePlugin {
  const CharacterCountsPlugin();

  @override
  String get id => 'linuxdo-character-counts';

  @override
  String? composerCharCountWarning(BuildContext context) =>
      context.l10n.charCount_noPaddingWarning;
}
