import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cross_file/cross_file.dart';
import 'package:ai_model_manager/ai_model_manager.dart';

import '../l10n/s.dart';
import '../utils/share_utils.dart';
import '../providers/app_state_refresher.dart';
import '../providers/core_providers.dart';
import '../providers/theme_provider.dart';
import '../utils/dialog_utils.dart';
import '../services/data_management/cache_size_service.dart';
import '../services/data_management/data_backup_service.dart';
import '../services/toast_service.dart';
import '../settings/definitions/data_management_defs.dart';
import 'package:m3e_ui/m3e_ui.dart';
import '../widgets/settings/settings_group_page.dart';

/// 数据管理页面（数据驱动版）
class DataManagementPage extends StatelessWidget {
  final String? highlightId;

  const DataManagementPage({super.key, this.highlightId});

  @override
  Widget build(BuildContext context) {
    return SettingsGroupPage(
      title: context.l10n.dataManagement_title,
      groupsBuilder: buildDataManagementGroups,
      highlightId: highlightId,
    );
  }
}

// ─────────────────────────────────────────────
// 缓存管理区块（有状态，被 CustomModel 包装）
// ─────────────────────────────────────────────

/// 缓存管理区块 —— Telegram Storage Usage 式信息架构:
///
/// - 图片缓存(可再下载)细分六类,**多选勾选 + 单一「清理所选」按钮**,
///   顶部分段彩条总览(分类色 = 勾选框色,取消勾选实时从彩条移除);
/// - AI 聊天 / Cookie 是本地数据(清了就没/要重登),**不进多选**,
///   保持独立行 + 各自确认 —— 对齐 Telegram 把 Local Database 与
///   可再下载缓存分离的原则。
class CacheManagementSection extends ConsumerStatefulWidget {
  const CacheManagementSection({super.key});

  @override
  ConsumerState<CacheManagementSection> createState() =>
      _CacheManagementSectionState();
}

class _CacheManagementSectionState
    extends ConsumerState<CacheManagementSection> {
  /// null = 计算中
  Map<ImageCacheCategory, int>? _breakdown;
  int _aiChatDataSize = -1;
  int _cookieCacheSize = -1;
  bool _isClearing = false;

  /// 勾选状态。默认全选(Telegram 同款)。
  final Set<ImageCacheCategory> _selected = {...ImageCacheCategory.values};

  @override
  void initState() {
    super.initState();
    _loadCacheSizes();
  }

  Future<void> _loadCacheSizes() async {
    final prefs = ref.read(sharedPreferencesProvider);
    final results = await Future.wait([
      CacheSizeService.getImageCacheBreakdown(),
      CacheSizeService.getAiChatDataSize(prefs),
      CacheSizeService.getCookieCacheSize(),
    ]);
    if (mounted) {
      setState(() {
        _breakdown = results[0] as Map<ImageCacheCategory, int>;
        _aiChatDataSize = results[1] as int;
        _cookieCacheSize = results[2] as int;
      });
    }
  }

  int get _imageTotal =>
      _breakdown?.values.fold(0, (a, b) => a! + b) ?? -1;

  int get _selectedSize {
    final b = _breakdown;
    if (b == null) return 0;
    var total = 0;
    for (final c in _selected) {
      total += b[c] ?? 0;
    }
    return total;
  }

  String _formatCacheSize(int size) {
    if (size < 0) return S.current.dataManagement_calculating;
    if (size == 0) return S.current.dataManagement_noCache;
    return CacheSizeService.formatSize(size);
  }

  String _categoryName(ImageCacheCategory c) => switch (c) {
        ImageCacheCategory.content => S.current.dataManagement_categoryContent,
        ImageCacheCategory.emoji => S.current.dataManagement_categoryEmoji,
        ImageCacheCategory.avatar => S.current.dataManagement_categoryAvatar,
        ImageCacheCategory.sticker => S.current.dataManagement_categorySticker,
        ImageCacheCategory.external =>
          S.current.dataManagement_categoryExternal,
        ImageCacheCategory.other => S.current.dataManagement_categoryOther,
      };

  /// 分类色:固定统计色板 + harmonizeWith(primary) 向主题色调和。
  ///
  /// 不能从 colorScheme 派生(primary/secondary/tertiary 在单色主题下
  /// 几乎同色,六类无法区分);固定色板保证区分度,harmonize 保证与
  /// 任意主题色/深浅模式协调 —— Telegram 统计色板同款思路。
  Color _categoryColor(ImageCacheCategory c, ColorScheme scheme) {
    const palette = {
      ImageCacheCategory.content: Color(0xFF4C8DF6), // 蓝
      ImageCacheCategory.sticker: Color(0xFFF2A03F), // 橙
      ImageCacheCategory.emoji: Color(0xFF41BA6D), // 绿
      ImageCacheCategory.avatar: Color(0xFF45B7D2), // 青
      ImageCacheCategory.external: Color(0xFF9B7BF0), // 紫
      ImageCacheCategory.other: Color(0xFF95A1AC), // 灰
    };
    return palette[c]!.harmonizeWith(scheme.primary);
  }

  Future<void> _clearSelected() async {
    final size = _selectedSize;
    final confirmed = await _showConfirmDialog(
      title: S.current.dataManagement_clearSelectedTitle,
      content: S.current.dataManagement_clearSelectedContent,
      confirmText: S.current.common_clear,
    );
    if (confirmed != true) return;

    setState(() => _isClearing = true);
    try {
      for (final c in _selected) {
        await CacheSizeService.clearImageCacheCategory(c);
      }
      PaintingBinding.instance.imageCache.clear();
      ToastService.showSuccess(
        S.current.dataManagement_freedSpace(CacheSizeService.formatSize(size)),
      );
    } catch (e) {
      ToastService.showError(S.current.common_clearFailed(e.toString()));
    } finally {
      if (mounted) {
        setState(() => _isClearing = false);
        await _loadCacheSizes();
      }
    }
  }

  Future<void> _clearAiChatData() async {
    final confirmed = await _showConfirmDialog(
      title: S.current.dataManagement_clearAiChatTitle,
      content: S.current.dataManagement_clearAiChatContent,
    );
    if (confirmed != true) return;

    setState(() => _isClearing = true);
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      await AiChatStorageService(prefs).deleteAllSessions();
      setState(() => _aiChatDataSize = 0);
      ToastService.showSuccess(S.current.dataManagement_aiChatCleared);
    } catch (e) {
      ToastService.showError(S.current.common_clearFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _isClearing = false);
    }
  }

  Future<void> _clearCookieCache() async {
    final confirmed = await _showConfirmDialog(
      title: S.current.dataManagement_clearCookieTitle,
      content: S.current.dataManagement_clearCookieContent,
      confirmText: S.current.dataManagement_clearAndLogout,
      isDestructive: true,
    );
    if (confirmed != true) return;

    setState(() => _isClearing = true);
    try {
      await _doClearCookies();
      setState(() => _cookieCacheSize = 0);
      ToastService.showSuccess(S.current.dataManagement_cookieCleared);
    } catch (e) {
      ToastService.showError(S.current.common_clearFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _isClearing = false);
    }
  }

  /// 清除 Cookie，并同步执行退出登录链路的状态销毁。
  Future<void> _doClearCookies() async {
    final container = ProviderScope.containerOf(context, listen: false);
    await ref.read(discourseServiceProvider).logout(callApi: false);
    await AppStateRefresher.resetForLogout(container);
  }

  Future<bool?> _showConfirmDialog({
    required String title,
    required String content,
    String? confirmText,
    bool isDestructive = false,
  }) {
    return showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: isDestructive
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                  )
                : null,
            child: Text(confirmText ?? context.l10n.common_confirm),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final breakdown = _breakdown;

    // 按大小降序(Telegram 同款);计算中保持枚举顺序。
    final categories = [...ImageCacheCategory.values];
    if (breakdown != null) {
      categories.sort((a, b) => (breakdown[b] ?? 0) - (breakdown[a] ?? 0));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedCardGroup(
          children: [
            // 顶部总览:总量 + 分段彩条
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Expanded(
                        child: Text(
                          context.l10n.dataManagement_imageCache,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      Text(
                        _formatCacheSize(_imageTotal),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _SegmentedBar(
                    segments: breakdown == null
                        ? null
                        : [
                            for (final c in categories)
                              if (_selected.contains(c) &&
                                  (breakdown[c] ?? 0) > 0)
                                (
                                  color: _categoryColor(c, theme.colorScheme),
                                  size: breakdown[c]!,
                                ),
                          ],
                  ),
                ],
              ),
            ),
            // 六类勾选行
            for (final c in categories)
              _buildCategoryTile(theme, c, breakdown?[c]),
            // 清理所选按钮(通栏,高度对齐 M3 FilledButton 规格)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              child: SizedBox(
                width: double.infinity,
                height: 44,
                child: FilledButton(
                  onPressed: _isClearing ||
                          breakdown == null ||
                          _selectedSize <= 0
                      ? null
                      : _clearSelected,
                  child: _isClearing
                      ? const LoadingSpinner(size: 18)
                      : Text(
                          S.current.dataManagement_clearSelected(
                            CacheSizeService.formatSize(_selectedSize),
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // 本地数据(非"可再下载"):独立区块,不进多选
        SegmentedCardGroup(
          children: [
            _buildLocalDataTile(
              theme: theme,
              icon: Symbols.smart_toy_rounded,
              title: context.l10n.dataManagement_aiChatData,
              size: _aiChatDataSize,
              onClear: _isClearing ? null : _clearAiChatData,
            ),
            _buildLocalDataTile(
              theme: theme,
              icon: Symbols.cookie_rounded,
              title: context.l10n.dataManagement_cookieCache,
              size: _cookieCacheSize,
              onClear: _isClearing ? null : _clearCookieCache,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCategoryTile(
    ThemeData theme,
    ImageCacheCategory c,
    int? size,
  ) {
    final color = _categoryColor(c, theme.colorScheme);
    final empty = size != null && size <= 0;
    final checked = _selected.contains(c) && !empty;
    final total = _imageTotal;
    // 占比:Telegram 同款,名称后跟小号加粗百分比;<1% 显示 <1%。
    String? percent;
    if (size != null && size > 0 && total > 0) {
      final p = size * 100 / total;
      percent = p < 1 ? '<1%' : '${p.round()}%';
    }
    return ListTile(
      dense: true,
      enabled: !empty && !_isClearing,
      leading: Checkbox(
        value: checked,
        shape: const CircleBorder(),
        activeColor: color,
        side: BorderSide(
          color: empty ? theme.colorScheme.outlineVariant : color,
          width: 2,
        ),
        onChanged: empty || _isClearing
            ? null
            : (v) => setState(() {
                  if (v == true) {
                    _selected.add(c);
                  } else {
                    _selected.remove(c);
                  }
                }),
      ),
      title: Text.rich(
        TextSpan(
          text: _categoryName(c),
          children: [
            if (percent != null)
              TextSpan(
                text: '  $percent',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
      trailing: size == null
          ? _ShimmerBox(width: 48, height: 14, theme: theme)
          : Text(
              _formatCacheSize(size),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: empty
                    ? theme.colorScheme.outline
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
      onTap: empty || _isClearing
          ? null
          : () => setState(() {
                if (_selected.contains(c)) {
                  _selected.remove(c);
                } else {
                  _selected.add(c);
                }
              }),
    );
  }

  Widget _buildLocalDataTile({
    required ThemeData theme,
    required IconData icon,
    required String title,
    required int size,
    required VoidCallback? onClear,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(_formatCacheSize(size)),
      trailing: TextButton(
        onPressed: size <= 0 ? null : onClear,
        child: Text(S.current.common_clear),
      ),
    );
  }
}

/// 分段彩条:分类按占比着色的水平条(环形图的轻量等价物)。
/// segments 为 null = 计算中,画灰条。
class _SegmentedBar extends StatelessWidget {
  const _SegmentedBar({required this.segments});

  final List<({Color color, int size})>? segments;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 12,
      child: segments == null
          ? _ShimmerBox(width: double.infinity, height: 12, theme: theme)
          : CustomPaint(
              painter: _SegmentedBarPainter(
                segments: segments!,
                emptyColor: theme.colorScheme.surfaceContainerHighest,
              ),
              size: const Size(double.infinity, 12),
            ),
    );
  }
}

class _SegmentedBarPainter extends CustomPainter {
  _SegmentedBarPainter({required this.segments, required this.emptyColor});

  final List<({Color color, int size})> segments;
  final Color emptyColor;

  static const double _gap = 3;

  /// 单段保底宽度:极小分类(几 MB vs 几百 MB)也要有可见的一段,
  /// 否则彩条退化成单色条,分类色与列表的对应关系断掉。
  static const double _minSegWidth = 10;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    final radius = Radius.circular(size.height / 2);
    final total = segments.fold<int>(0, (a, s) => a + s.size);
    if (total <= 0 || segments.isEmpty) {
      paint.color = emptyColor;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Offset.zero & size, radius),
        paint,
      );
      return;
    }
    final gapTotal = _gap * (segments.length - 1);
    final usable = (size.width - gapTotal).clamp(0.0, double.infinity);

    // 先按占比分宽,再把不足保底的段抬到保底,超出部分从最大段扣回。
    final widths = [
      for (final s in segments) usable * s.size / total,
    ];
    var deficit = 0.0;
    for (var i = 0; i < widths.length; i++) {
      if (widths[i] < _minSegWidth) {
        deficit += _minSegWidth - widths[i];
        widths[i] = _minSegWidth;
      }
    }
    if (deficit > 0) {
      var maxIdx = 0;
      for (var i = 1; i < widths.length; i++) {
        if (widths[i] > widths[maxIdx]) maxIdx = i;
      }
      widths[maxIdx] =
          (widths[maxIdx] - deficit).clamp(_minSegWidth, double.infinity);
    }

    var x = 0.0;
    for (var i = 0; i < segments.length; i++) {
      paint.color = segments[i].color;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, 0, widths[i], size.height),
          radius,
        ),
        paint,
      );
      x += widths[i] + _gap;
    }
  }

  @override
  bool shouldRepaint(_SegmentedBarPainter old) =>
      old.segments != segments || old.emptyColor != emptyColor;
}

/// 计算中的静态灰底占位(不做动画,页面停留短)。
class _ShimmerBox extends StatelessWidget {
  const _ShimmerBox({
    required this.width,
    required this.height,
    required this.theme,
  });

  final double width;
  final double height;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 数据备份区块（被 CustomModel 包装）
// ─────────────────────────────────────────────

/// 数据备份区块，封装了导出和导入逻辑
class DataBackupSection extends ConsumerWidget {
  const DataBackupSection({super.key});

  Future<void> _exportData(BuildContext context, WidgetRef ref) async {
    // 导出前敏感信息提示(备份 v2 含 API Key / 代理密码 / Notion Token)
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.current.dataManagement_exportConfirmTitle),
        content: Text(S.current.dataManagement_exportSensitiveWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.l10n.common_confirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final prefs = ref.read(sharedPreferencesProvider);
      final filePath = await DataBackupService.exportToFile(prefs);
      await ShareUtils.shareOrSaveFile(
        XFile(filePath, mimeType: 'application/json'),
        subject: S.current.dataManagement_backupSubject,
      );
    } catch (e) {
      ToastService.showError(
          S.current.dataManagement_exportFailed(e.toString()));
    }
  }

  Future<void> _importData(BuildContext context, WidgetRef ref) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (result == null || result.files.isEmpty) return;

      final filePath = result.files.single.path;
      if (filePath == null) return;

      final backup = await DataBackupService.parseBackupFile(filePath);
      final data = backup['data'] as Map<String, dynamic>;
      final apiKeys = backup['apiKeys'] as Map<String, dynamic>?;
      final appVersion =
          backup['appVersion'] as String? ?? S.current.common_unknown;
      final exportTime =
          backup['exportTime'] as String? ?? S.current.common_unknown;

      if (!context.mounted) return;

      final details = StringBuffer()
        ..writeln(S.current.dataManagement_backupSource(appVersion))
        ..writeln(S.current.dataManagement_exportTime(exportTime))
        ..writeln(S.current.dataManagement_settingsCount(data.length));
      if (apiKeys != null && apiKeys.isNotEmpty) {
        details.writeln(S.current.dataManagement_apiKeysCount(apiKeys.length));
      }
      details.write('\n${S.current.dataManagement_importWarning}');

      final confirmed = await showAppDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(S.current.dataManagement_confirmImport),
          content: Text(details.toString()),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(ctx.l10n.common_cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(S.current.dataManagement_importAndRestart),
            ),
          ],
        ),
      );
      if (confirmed != true) return;

      final prefs = ref.read(sharedPreferencesProvider);
      await DataBackupService.importData(prefs, backup);
      ToastService.showSuccess(S.current.dataManagement_importSuccess);
    } on FormatException catch (e) {
      ToastService.showError(e.message);
    } catch (e) {
      ToastService.showError(
          S.current.dataManagement_importFailed(e.toString()));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return SegmentedCardGroup(
      children: [
        ListTile(
          leading: const Icon(Symbols.upload_rounded),
          title: Text(context.l10n.dataManagement_exportData),
          subtitle: Text(context.l10n.dataManagement_exportDesc),
          trailing: Icon(
            Symbols.chevron_right_rounded,
            color: theme.colorScheme.outline.withValues(alpha: 0.4),
            size: 20,
          ),
          onTap: () => _exportData(context, ref),
        ),
        ListTile(
          leading: const Icon(Symbols.download_rounded),
          title: Text(context.l10n.dataManagement_importData),
          subtitle: Text(context.l10n.dataManagement_importDesc),
          trailing: Icon(
            Symbols.chevron_right_rounded,
            color: theme.colorScheme.outline.withValues(alpha: 0.4),
            size: 20,
          ),
          onTap: () => _importData(context, ref),
        ),
      ],
    );
  }
}
