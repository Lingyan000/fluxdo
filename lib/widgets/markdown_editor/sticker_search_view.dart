import 'dart:async';

import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';

import '../../../../../l10n/s.dart';
import '../../models/sticker.dart';
import '../../utils/dialog_utils.dart';
import 'picker_search_header.dart';
import 'sticker_preview.dart';

/// 搜索结果的一个分区(最近使用 / 收藏分类 / 表情包)。
class StickerSearchSection {
  const StickerSearchSection(this.title, this.items);

  final String title;
  final List<StickerItem> items;
}

/// 表情搜索:按表情名或所在分区名过滤面板内容。
///
/// 市场里多数表情名是文件名,所以分区名(表情包名、收藏分类名)命中时
/// 整个分区都算命中;只靠表情名几乎搜不到东西。
///
/// 两种形态与表情面板的搜索一致(头部共用 [PickerSearchSheetHeader] /
/// [PickerSearchInlineHeader]):
/// - 底部弹层:用 [showSheet] 打开,移动端用(面板占着键盘的位置,不能在
///   面板里弹键盘);
/// - 内联:传 [onClose],桌面悬浮面板里直接替换面板内容。
class StickerSearchView extends StatefulWidget {
  const StickerSearchView({
    super.key,
    required this.search,
    required this.onSelected,
    this.onClose,
    this.bottomPadding = 0,
  });

  final List<StickerSearchSection> Function(String query) search;
  final ValueChanged<StickerItem> onSelected;

  /// 内联形态的返回回调;为 null 时是底部弹层形态。
  final VoidCallback? onClose;
  final double bottomPadding;

  /// 表情名去掉扩展名后参与匹配(`猫猫叹气.gif` 搜「叹气」能中)。
  static String plainName(String name) =>
      name.replaceFirst(RegExp(r'\.[A-Za-z0-9]{2,5}$'), '');

  /// 底部弹层形态,选中的表情作为结果返回。
  static Future<StickerItem?> showSheet(
    BuildContext context, {
    required List<StickerSearchSection> Function(String query) search,
  }) {
    return showAppBottomSheet<StickerItem>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => AppSheetScaffold(
        showCloseButton: false,
        contentPadding: EdgeInsets.zero,
        maxHeightFactor: 0.8,
        child: StickerSearchView(
          search: search,
          onSelected: (sticker) {
            FocusScope.of(sheetContext).unfocus();
            Navigator.pop(sheetContext, sticker);
          },
        ),
      ),
    );
  }

  @override
  State<StickerSearchView> createState() => _StickerSearchViewState();
}

class _StickerSearchViewState extends State<StickerSearchView> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _preview = StickerPreviewController();
  Timer? _debounce;
  String _query = '';
  bool _hasText = false;

  bool get _inline => widget.onClose != null;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final text = _controller.text;
      if (text.isNotEmpty != _hasText) {
        setState(() => _hasText = text.isNotEmpty);
      }
      final next = text.trim();
      _debounce?.cancel();
      // 订阅多的时候一次过滤上万条,打字时稍微攒一下
      _debounce = Timer(const Duration(milliseconds: 150), () {
        if (mounted && next != _query) setState(() => _query = next);
      });
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    _preview.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sections = _query.isEmpty
        ? const <StickerSearchSection>[]
        : widget.search(_query);
    final horizontal = _inline ? 12.0 : 16.0;
    final bottom = _inline
        ? 12 + widget.bottomPadding
        : 16 + MediaQuery.viewInsetsOf(context).bottom;

    final Widget body;
    if (_query.isEmpty) {
      body = PickerSearchMessage(
        S.current.emoji_searchPrompt,
        icon: _inline ? null : Symbols.sticky_note_2_rounded,
      );
    } else if (sections.isEmpty) {
      body = PickerSearchMessage(S.current.sticker_searchEmpty);
    } else {
      body = CustomScrollView(
        slivers: [
          for (final section in sections) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(horizontal + 4, 12, 16, 4),
                child: Text(
                  section.title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: horizontal),
              sliver: SliverGrid(
                delegate: SliverChildBuilderDelegate(
                  (_, index) => StickerGridCell(
                    sticker: section.items[index],
                    preview: _preview,
                    onTap: () => widget.onSelected(section.items[index]),
                  ),
                  childCount: section.items.length,
                ),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 80,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                ),
              ),
            ),
          ],
          SliverToBoxAdapter(child: SizedBox(height: bottom)),
        ],
      );
    }

    return Column(
      children: [
        if (_inline)
          PickerSearchInlineHeader(
            controller: _controller,
            focusNode: _focusNode,
            hintText: S.current.sticker_searchHint,
            showClear: _hasText,
            onClose: widget.onClose!,
          )
        else
          PickerSearchSheetHeader(
            controller: _controller,
            focusNode: _focusNode,
            hintText: S.current.sticker_searchHint,
            showClear: _hasText,
          ),
        Expanded(child: body),
      ],
    );
  }
}
