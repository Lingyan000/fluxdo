import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../l10n/s.dart';
import '../../models/sticker.dart';
import '../../providers/sticker_favorites_provider.dart';
import '../../services/sticker_favorites_service.dart';
import '../../services/toast_service.dart';
import '../../utils/dialog_utils.dart';
import '../common/app_bottom_sheet.dart';

/// 分类的显示名:默认分类叫「收藏」。
String stickerFavoriteCategoryLabel(StickerFavoriteCategory category) =>
    category.isDefault || category.name.isEmpty
    ? S.current.sticker_favorites
    : category.name;

/// 收藏一张表情:还没有自定义分类时直接收进默认分类,否则让用户选。
Future<void> favoriteSticker(BuildContext context, StickerItem item) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final categories = container.read(stickerFavoritesProvider);
  if (categories.every((c) => c.isDefault)) {
    await container.read(stickerFavoritesProvider.notifier).add(item);
    ToastService.showSuccess(
      S.current.sticker_favoritedTo(S.current.sticker_favorites),
    );
    return;
  }
  if (!context.mounted) return;
  await showFavoriteCategoryPicker(context, item);
}

/// 「收藏到…」:选一个分类(当前所在分类打勾),或新建分类后收进去。
Future<void> showFavoriteCategoryPicker(
  BuildContext context,
  StickerItem item,
) {
  return AppBottomSheet.show(
    context: context,
    title: S.current.sticker_favoriteTo,
    contentPadding: const EdgeInsets.only(bottom: 8),
    builder: (sheetContext) => _CategoryPickerBody(item: item),
  );
}

class _CategoryPickerBody extends ConsumerWidget {
  const _CategoryPickerBody({required this.item});

  final StickerItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final categories = ref.watch(stickerFavoritesProvider);
    final notifier = ref.read(stickerFavoritesProvider.notifier);
    final current = notifier.categoryOf(item.url);
    // 默认分类即使还不存在也要能选
    final options = [
      if (!categories.any((c) => c.isDefault))
        const StickerFavoriteCategory(
          id: StickerFavoriteCategory.defaultId,
          name: '',
        ),
      ...categories,
    ];

    Future<void> saveTo(String categoryId, String label) async {
      Navigator.of(context).pop();
      await notifier.add(item, categoryId: categoryId);
      ToastService.showSuccess(S.current.sticker_favoritedTo(label));
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final category in options)
          ListTile(
            leading: Icon(
              category.isDefault
                  ? Symbols.star_rounded
                  : Symbols.folder_rounded,
              fill: category.isDefault ? 1 : 0,
            ),
            title: Text(stickerFavoriteCategoryLabel(category)),
            subtitle: Text(
              S.current.sticker_emojiCount(category.items.length),
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
            trailing: category.id == current
                ? Icon(Symbols.check_rounded, color: context.emphasis.selected)
                : null,
            onTap: () =>
                saveTo(category.id, stickerFavoriteCategoryLabel(category)),
          ),
        ListTile(
          leading: const Icon(Symbols.add_rounded),
          title: Text(S.current.sticker_newCategory),
          onTap: () async {
            final name = await showStickerCategoryNameDialog(
              context,
              title: S.current.sticker_newCategory,
            );
            if (name == null || !context.mounted) return;
            final id = await notifier.createCategory(name);
            if (!context.mounted) return;
            await saveTo(id, name);
          },
        ),
      ],
    );
  }
}

/// 输入分类名称;取消返回 null,空白名称不允许提交。
Future<String?> showStickerCategoryNameDialog(
  BuildContext context, {
  required String title,
  String initial = '',
}) {
  return showAppDialog<String>(
    context: context,
    builder: (_) => _CategoryNameDialog(title: title, initial: initial),
  );
}

/// controller 由对话框自己的 State 持有:调用方 await 返回后立即 dispose
/// 会在退场动画期间炸树。
class _CategoryNameDialog extends StatefulWidget {
  const _CategoryNameDialog({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_CategoryNameDialog> createState() => _CategoryNameDialogState();
}

class _CategoryNameDialogState extends State<_CategoryNameDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 30,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(hintText: S.current.sticker_categoryName),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(S.current.common_cancel),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _controller,
          builder: (context, value, _) => FilledButton(
            onPressed: value.text.trim().isEmpty ? null : _submit,
            child: Text(S.current.common_confirm),
          ),
        ),
      ],
    );
  }
}
