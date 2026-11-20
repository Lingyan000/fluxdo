import 'dart:async';

import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';

import '../../../../../l10n/s.dart';
import '../../models/sticker.dart';
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
/// 桌面悬浮面板里内联显示(传 [onClose] 显示返回按钮),移动端放在底部
/// 弹层里(面板占着键盘的位置,不能在面板里弹键盘)。
class StickerSearchView extends StatefulWidget {
  const StickerSearchView({
    super.key,
    required this.search,
    required this.onSelected,
    this.onClose,
    this.scrollController,
    this.bottomPadding = 0,
  });

  final List<StickerSearchSection> Function(String query) search;
  final ValueChanged<StickerItem> onSelected;
  final VoidCallback? onClose;
  final ScrollController? scrollController;
  final double bottomPadding;

  /// 表情名去掉扩展名后参与匹配(`猫猫叹气.gif` 搜「叹气」能中)。
  static String plainName(String name) =>
      name.replaceFirst(RegExp(r'\.[A-Za-z0-9]{2,5}$'), '');

  @override
  State<StickerSearchView> createState() => _StickerSearchViewState();
}

class _StickerSearchViewState extends State<StickerSearchView> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _preview = StickerPreviewController();
  Timer? _debounce;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final next = _controller.text.trim();
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

    final Widget body;
    if (_query.isEmpty || sections.isEmpty) {
      body = Center(
        child: Text(
          _query.isEmpty
              ? S.current.sticker_searchHint
              : S.current.sticker_searchEmpty,
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    } else {
      body = CustomScrollView(
        controller: widget.scrollController,
        slivers: [
          for (final section in sections) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
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
              padding: const EdgeInsets.symmetric(horizontal: 12),
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
          SliverToBoxAdapter(child: SizedBox(height: 8 + widget.bottomPadding)),
        ],
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Row(
            children: [
              if (widget.onClose != null)
                IconButton(
                  icon: const Icon(Symbols.arrow_back_rounded, size: 20),
                  color: theme.colorScheme.onSurfaceVariant,
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onClose,
                  tooltip: S.current.common_cancel,
                ),
              Expanded(
                child: InputFieldShell(
                  height: 36,
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.5,
                  ),
                  radius: 10,
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    autofocus: true,
                    textAlignVertical: TextAlignVertical.center,
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      hintText: S.current.sticker_searchHint,
                      hintStyle: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      isDense: true,
                      contentPadding: const EdgeInsets.only(right: 12),
                      prefixIcon: Icon(
                        Symbols.search_rounded,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      suffixIcon: ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _controller,
                        builder: (_, value, _) => value.text.isEmpty
                            ? const SizedBox.shrink()
                            : IconButton(
                                icon: const Icon(
                                  Symbols.cancel_rounded,
                                  size: 16,
                                ),
                                color: theme.colorScheme.onSurfaceVariant,
                                onPressed: _controller.clear,
                              ),
                      ),
                    ).withoutBorder(),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(child: body),
      ],
    );
  }
}
