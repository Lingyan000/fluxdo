/// 加解密算法选择器：对齐 ai_model_select_sheet 的统一风格。
///
/// - 外壳：AppBottomSheet（贴边列表式），与模型选择器同一容器
/// - 顶部搜索框：surfaceContainerHigh 填充、圆角 12（与模型选择器同款）
/// - 分组标题：labelSmall + onSurfaceVariant + letterSpacing 0.5（与模型
///   选择器 section header 一致）
/// - 算法行：Material 自绘选中背景（primaryContainer alpha 0.5、圆角 12），
///   滚动时随列表 clip 不溢出
/// - 「最近使用」横向 chips（历史图标），支持列表/网格展示切换
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../providers/preferences_provider.dart';
import '../../services/crypto/crypto_algorithm.dart';
import '../../services/crypto/crypto_toolbox.dart';
import '../common/app_bottom_sheet.dart';

/// 展示算法选择弹层；返回选中的算法 id（取消返回 null）。
Future<String?> showCryptoAlgorithmPicker(
  BuildContext context, {
  required String currentAlgorithmId,
}) {
  return AppBottomSheet.show<String>(
    context: context,
    style: AppSheetStyle.edge,
    title: context.l10n.crypto_algorithm,
    contentPadding: EdgeInsets.zero,
    maxHeightFactor: 0.85,
    builder: (ctx) => CryptoAlgorithmPickerSheet(
      currentAlgorithmId: currentAlgorithmId,
    ),
  );
}

/// 记录一次算法选择（弹层选中后调用，供最近使用列表置顶）。
Future<void> recordCryptoAlgorithmUsage(WidgetRef ref, String algorithmId) {
  return ref
      .read(preferencesProvider.notifier)
      .recordCryptoAlgorithmUsage(algorithmId);
}

class CryptoAlgorithmPickerSheet extends ConsumerStatefulWidget {
  const CryptoAlgorithmPickerSheet({
    super.key,
    required this.currentAlgorithmId,
  });

  final String currentAlgorithmId;

  @override
  ConsumerState<CryptoAlgorithmPickerSheet> createState() =>
      _CryptoAlgorithmPickerSheetState();
}

class _CryptoAlgorithmPickerSheetState
    extends ConsumerState<CryptoAlgorithmPickerSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  bool _gridMode = false;

  static const List<CryptoAlgorithmCategory> _categoryOrder = [
    CryptoAlgorithmCategory.symmetric,
    CryptoAlgorithmCategory.encoding,
    CryptoAlgorithmCategory.hash,
    CryptoAlgorithmCategory.asymmetric,
    CryptoAlgorithmCategory.classic,
  ];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _categoryLabel(AppLocalizations s, CryptoAlgorithmCategory category) {
    switch (category) {
      case CryptoAlgorithmCategory.symmetric:
        return s.crypto_categorySymmetric;
      case CryptoAlgorithmCategory.encoding:
        return s.crypto_categoryEncoding;
      case CryptoAlgorithmCategory.hash:
        return s.crypto_categoryHash;
      case CryptoAlgorithmCategory.asymmetric:
        return s.crypto_categoryAsymmetric;
      case CryptoAlgorithmCategory.classic:
        return s.crypto_categoryClassic;
    }
  }

  void _select(String algorithmId) {
    ref
        .read(preferencesProvider.notifier)
        .recordCryptoAlgorithmUsage(algorithmId);
    Navigator.of(context).pop(algorithmId);
  }

  List<CryptoAlgorithm> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return CryptoToolbox.all
        .where((a) =>
            a.id.contains(q) || a.displayName.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = context.l10n;
    final recent = ref
        .watch(preferencesProvider)
        .cryptoRecentAlgorithms
        .where((id) => CryptoToolbox.byId(id) != null)
        .toList();
    final searching = _query.trim().isNotEmpty;
    final gridMode = _gridMode;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 搜索框（与模型选择器同款样式与内边距）+ 右侧布局切换
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: _buildSearchField(theme, s),
              ),
              const SizedBox(width: 4),
              IconButton(
                key: const ValueKey('crypto-picker-toggle-layout'),
                tooltip: s.crypto_toggleLayout,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  gridMode
                      ? Icons.view_list_rounded
                      : Icons.grid_view_rounded,
                  size: 20,
                ),
                onPressed: () => setState(() => _gridMode = !_gridMode),
              ),
            ],
          ),
        ),
        Flexible(
          child: searching
              ? _buildSearchResults(theme, s)
              : gridMode
                  ? _buildGridList(theme, s, recent)
                  : _buildGroupedList(theme, s, recent),
        ),
      ],
    );
  }

  Widget _buildSearchField(ThemeData theme, AppLocalizations s) {
    return TextField(
      key: const ValueKey('crypto-picker-search'),
      controller: _searchController,
      autofocus: false,
      onChanged: (value) => setState(() => _query = value),
      decoration: InputDecoration(
        hintText: s.crypto_searchHint,
        prefixIcon: Icon(
          Icons.search_rounded,
          size: 20,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  _searchController.clear();
                  setState(() => _query = '');
                },
              ),
        filled: true,
        fillColor: theme.colorScheme.surfaceContainerHigh,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  /// 搜索态：平铺过滤结果
  Widget _buildSearchResults(ThemeData theme, AppLocalizations s) {
    final results = _filtered;
    if (results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_off_rounded,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 8),
            Text(
              s.crypto_noAlgorithmFound,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
      itemCount: results.length,
      itemBuilder: (context, index) => _algorithmTile(theme, results[index]),
    );
  }

  /// 非搜索列表态：最近使用 chips + 分类分组
  Widget _buildGroupedList(
      ThemeData theme, AppLocalizations s, List<String> recent) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
      children: [
        if (recent.isNotEmpty) ...[
          _buildSectionLabel(theme, s.crypto_recentlyUsed),
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: recent.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final algo = CryptoToolbox.byId(recent[index])!;
                return ActionChip(
                  key: ValueKey('crypto-recent-${algo.id}'),
                  avatar: Icon(
                    Icons.history_rounded,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  label: Text(algo.displayName),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _select(algo.id),
                );
              },
            ),
          ),
        ],
        for (final category in _categoryOrder) ...[
          _buildSectionLabel(theme, _categoryLabel(s, category)),
          for (final algo in CryptoToolbox.algorithmsByCategory(category))
            _algorithmTile(theme, algo),
        ],
      ],
    );
  }

  /// 网格态：最近使用 + 分类网格（3 列紧凑卡片）
  Widget _buildGridList(
      ThemeData theme, AppLocalizations s, List<String> recent) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
      children: [
        if (recent.isNotEmpty) ...[
          _buildSectionLabel(theme, s.crypto_recentlyUsed),
          _buildCategoryGrid(
            theme,
            recent.map((id) => CryptoToolbox.byId(id)!).toList(growable: false),
          ),
        ],
        for (final category in _categoryOrder) ...[
          _buildSectionLabel(theme, _categoryLabel(s, category)),
          _buildCategoryGrid(
              theme, CryptoToolbox.algorithmsByCategory(category)),
        ],
      ],
    );
  }

  Widget _buildCategoryGrid(ThemeData theme, List<CryptoAlgorithm> algorithms) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 2.6,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
      ),
      itemCount: algorithms.length,
      itemBuilder: (context, index) {
        final algo = algorithms[index];
        final selected = algo.id == widget.currentAlgorithmId;
        return Material(
          key: ValueKey('crypto-grid-${algo.id}'),
          color: selected
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.7)
              : theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _select(algo.id),
            child: Center(
              child: Text(
                algo.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.onSurface,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 分组标题：与模型选择器 section header 同款
  /// （labelSmall + onSurfaceVariant + letterSpacing 0.5 + w500）
  Widget _buildSectionLabel(ThemeData theme, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  /// 算法行：Material 自绘选中背景（随列表 clip，不溢出到 sheet 外）。
  Widget _algorithmTile(ThemeData theme, CryptoAlgorithm algo) {
    final selected = algo.id == widget.currentAlgorithmId;
    return Padding(
      key: ValueKey('crypto-algo-${algo.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: Material(
        color: selected
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _select(algo.id),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    algo.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected
                          ? theme.colorScheme.onPrimaryContainer
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                if (selected)
                  Icon(
                    Icons.check_rounded,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 当前算法展示条（单行紧凑：图标 + 算法名 + 自动识别 chip + chevron）。
class CryptoAlgorithmTile extends StatelessWidget {
  const CryptoAlgorithmTile({
    super.key,
    required this.algorithmId,
    required this.onSelected,
    this.autoDetected = false,
  });

  final String algorithmId;

  /// 选择变化回调（弹层返回 null 表示取消，不会触发）
  final ValueChanged<String> onSelected;

  /// 是否显示「已自动识别」徽标
  final bool autoDetected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = context.l10n;
    final algo = CryptoToolbox.byId(algorithmId);
    final displayName = algo?.displayName ?? algorithmId;

    return Material(
      key: const ValueKey('crypto-algorithm-tile'),
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          final selected = await showCryptoAlgorithmPicker(
            context,
            currentAlgorithmId: algorithmId,
          );
          if (selected != null && selected != algorithmId) {
            onSelected(selected);
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(
                Icons.enhanced_encryption_rounded,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  displayName,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              if (autoDetected) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    s.crypto_autoDetected,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Icon(
                Icons.unfold_more_rounded,
                size: 18,
                color: theme.colorScheme.outline,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
