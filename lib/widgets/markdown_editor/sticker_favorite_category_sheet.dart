import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../../../l10n/s.dart';
import '../../models/sticker.dart';
import '../../providers/sticker_favorites_provider.dart';
import '../../services/discourse/discourse_service.dart';
import '../../services/sticker_favorites_service.dart';
import '../../services/toast_service.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/url_helper.dart';
import '../common/app_bottom_sheet.dart';
import 'sticker_favorite_ui.dart';
import 'sticker_preview.dart';

/// 收藏分类详情:网格展示分类里的表情。
///
/// - 点按选中/取消,有选中时底部变成「移动到… / 删除」;
/// - 长按拖到别的表情上调整顺序;
/// - 没有选中时底部是「添加图片」:选本地图片上传到论坛后收进本分类
///   (直接传原文件,不走压缩,动图不会被破坏)。
class StickerFavoriteCategorySheet extends ConsumerStatefulWidget {
  const StickerFavoriteCategorySheet({
    super.key,
    required this.categoryId,
    required this.scrollController,
  });

  final String categoryId;
  final ScrollController scrollController;

  static Future<void> show(BuildContext context, String categoryId) {
    return AppBottomSheet.showDraggable(
      context: context,
      titleWidget: _Title(categoryId: categoryId),
      initialSize: 0.75,
      bodyBuilder: (context, scrollController) => StickerFavoriteCategorySheet(
        categoryId: categoryId,
        scrollController: scrollController,
      ),
    );
  }

  @override
  ConsumerState<StickerFavoriteCategorySheet> createState() =>
      _StickerFavoriteCategorySheetState();
}

class _Title extends ConsumerWidget {
  const _Title({required this.categoryId});

  final String categoryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final category = ref
        .watch(stickerFavoritesProvider)
        .where((c) => c.id == categoryId)
        .firstOrNull;
    return Text(
      category == null ? '' : stickerFavoriteCategoryLabel(category),
      style: Theme.of(context).textTheme.titleMedium,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _StickerFavoriteCategorySheetState
    extends ConsumerState<StickerFavoriteCategorySheet> {
  final _selected = <String>{};
  final _preview = StickerPreviewController();
  final _picker = ImagePicker();
  int _uploadDone = 0;
  int _uploadTotal = 0;

  bool get _uploading => _uploadTotal > 0;

  @override
  void dispose() {
    _preview.dispose();
    super.dispose();
  }

  StickerFavoritesNotifier get _notifier =>
      ref.read(stickerFavoritesProvider.notifier);

  void _toggle(StickerItem item) {
    setState(() {
      if (!_selected.remove(item.url)) _selected.add(item.url);
    });
  }

  Future<void> _moveSelected(List<StickerFavoriteCategory> categories) async {
    final targets = [
      if (!categories.any((c) => c.isDefault))
        const StickerFavoriteCategory(
          id: StickerFavoriteCategory.defaultId,
          name: '',
        ),
      for (final c in categories)
        if (c.id != widget.categoryId) c,
    ].where((c) => c.id != widget.categoryId).toList();
    final target = await AppBottomSheet.show<String>(
      context: context,
      title: S.current.sticker_moveTo,
      contentPadding: const EdgeInsets.only(bottom: 8),
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final c in targets)
            ListTile(
              leading: Icon(
                c.isDefault ? Symbols.star_rounded : Symbols.folder_rounded,
                fill: c.isDefault ? 1 : 0,
              ),
              title: Text(stickerFavoriteCategoryLabel(c)),
              onTap: () => Navigator.of(sheetContext).pop(c.id),
            ),
        ],
      ),
    );
    if (target == null || !mounted) return;
    if (target == StickerFavoriteCategory.defaultId &&
        !ref.read(stickerFavoritesProvider).any((c) => c.isDefault)) {
      // 默认分类还不存在:逐个收进去(add 会自动创建)
      final items = _itemsOf(widget.categoryId)
          .where((i) => _selected.contains(i.url))
          .toList();
      for (final item in items) {
        await _notifier.add(item);
      }
    } else {
      await _notifier.move({..._selected}, target);
    }
    if (mounted) setState(_selected.clear);
  }

  Future<void> _deleteSelected() async {
    final count = _selected.length;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(S.current.sticker_deleteSelectedConfirm(count)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(S.current.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(S.current.common_delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _notifier.remove({..._selected});
    if (mounted) setState(_selected.clear);
  }

  List<StickerItem> _itemsOf(String categoryId) =>
      ref
          .read(stickerFavoritesProvider)
          .where((c) => c.id == categoryId)
          .firstOrNull
          ?.items ??
      const [];

  Future<void> _addImages() async {
    final images = await _picker.pickMultiImage();
    if (images.isEmpty || !mounted) return;
    setState(() {
      _uploadDone = 0;
      _uploadTotal = images.length;
    });
    var failed = 0;
    for (final image in images) {
      try {
        final result = await DiscourseService().uploadImage(image.path);
        final url = result.url;
        if (url == null) throw StateError('upload without url');
        final name = image.name.contains('.')
            ? image.name.substring(0, image.name.lastIndexOf('.'))
            : image.name;
        await _notifier.add(
          StickerItem(
            id: 'upload:${result.shortUrl}',
            name: name,
            url: UrlHelper.resolveUrlWithCdn(url),
            width: result.width ?? 0,
            height: result.height ?? 0,
            groupId: '',
          ),
          categoryId: widget.categoryId,
        );
      } catch (e) {
        debugPrint('[StickerFavorites] 上传失败 ${image.name}: $e');
        failed++;
      }
      if (mounted) setState(() => _uploadDone++);
    }
    if (failed > 0) {
      ToastService.showError(S.current.sticker_uploadFailed(failed));
    }
    if (mounted) {
      setState(() {
        _uploadDone = 0;
        _uploadTotal = 0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(stickerFavoritesProvider);
    final category = categories
        .where((c) => c.id == widget.categoryId)
        .firstOrNull;
    final items = category?.items ?? const <StickerItem>[];
    // 已不在分类里的选中项(被移走/删除)不再计数
    _selected.retainWhere((url) => items.any((i) => i.url == url));

    return Column(
      children: [
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Text(
                    S.current.sticker_favoriteEmpty,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : GridView.builder(
                  controller: widget.scrollController,
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 88,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, index) => _buildCell(items, index),
                ),
        ),
        _buildFooter(categories),
      ],
    );
  }

  Widget _buildCell(List<StickerItem> items, int index) {
    final theme = Theme.of(context);
    final item = items[index];
    final selected = _selected.contains(item.url);
    final cell = DecoratedBox(
      decoration: ShapeDecoration(
        color: selected
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainer,
        shape: RoundedSuperellipseBorder(
          borderRadius: context.shapes.borderRadius(12),
          side: selected
              ? BorderSide(color: theme.colorScheme.primary, width: 2)
              : BorderSide.none,
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Padding(
            padding: const EdgeInsets.all(6),
            child: StickerThumbnail(sticker: item),
          ),
          if (selected)
            Positioned(
              top: 4,
              right: 4,
              child: Icon(
                Symbols.check_circle_rounded,
                size: 20,
                fill: 1,
                color: context.emphasis.selected,
              ),
            ),
        ],
      ),
    );

    return DragTarget<int>(
      onWillAcceptWithDetails: (details) => details.data != index,
      onAcceptWithDetails: (details) {
        _notifier.reorderItems(widget.categoryId, details.data, index);
        HapticFeedback.selectionClick();
      },
      builder: (context, candidates, _) => LongPressDraggable<int>(
        data: index,
        hapticFeedbackOnStart: true,
        feedback: SizedBox.square(
          dimension: 80,
          child: Material(
            type: MaterialType.transparency,
            child: Transform.scale(scale: 1.1, child: cell),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.3, child: cell),
        child: GestureDetector(
          onTap: () => _toggle(item),
          child: candidates.isEmpty
              ? cell
              : DecoratedBox(
                  position: DecorationPosition.foreground,
                  decoration: ShapeDecoration(
                    shape: RoundedSuperellipseBorder(
                      borderRadius: context.shapes.borderRadius(12),
                      side: BorderSide(color: theme.colorScheme.primary),
                    ),
                  ),
                  child: cell,
                ),
        ),
      ),
    );
  }

  Widget _buildFooter(List<StickerFavoriteCategory> categories) {
    final Widget child;
    if (_uploading) {
      child = FilledButton.icon(
        onPressed: null,
        icon: const LoadingSpinner(size: 18),
        label: Text(S.current.sticker_uploading(_uploadDone, _uploadTotal)),
      );
    } else if (_selected.isEmpty) {
      child = FilledButton.icon(
        onPressed: _addImages,
        icon: const Icon(Symbols.add_photo_alternate_rounded, size: 18),
        label: Text(S.current.sticker_addImages),
      );
    } else {
      child = Row(
        children: [
          Expanded(
            child: Text(
              S.current.sticker_selectedCount(_selected.length),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          OutlinedButton.icon(
            onPressed: () => _moveSelected(categories),
            icon: const Icon(Symbols.drive_file_move_rounded, size: 18),
            label: Text(S.current.sticker_moveTo),
          ),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: _deleteSelected,
            icon: const Icon(Symbols.delete_rounded, size: 18),
            label: Text(S.current.common_delete),
          ),
        ],
      );
    }
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: SizedBox(width: double.infinity, child: child),
      ),
    );
  }
}
