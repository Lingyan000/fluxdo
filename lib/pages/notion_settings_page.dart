import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/s.dart';
import '../providers/notion_config_provider.dart';
import '../services/notion/notion_client.dart';
import '../services/notion/notion_config.dart';
import '../services/notion/notion_sync_service.dart';
import '../services/toast_service.dart';
import 'package:m3e_ui/m3e_ui.dart';

/// Notion 同步设置页：分步引导 + 配置编辑。
class NotionSettingsPage extends ConsumerStatefulWidget {
  const NotionSettingsPage({super.key});

  @override
  ConsumerState<NotionSettingsPage> createState() =>
      _NotionSettingsPageState();
}

class _NotionSettingsPageState extends ConsumerState<NotionSettingsPage> {
  final _tokenController = TextEditingController();
  final _databaseIdController = TextEditingController();
  bool _obscureToken = true;
  bool _testing = false;
  bool _initialized = false;
  bool _editing = false;
  bool? _needsUpgrade; // null = 未检测;true/false = 检测结果
  bool _upgrading = false;

  @override
  void dispose() {
    _tokenController.dispose();
    _databaseIdController.dispose();
    super.dispose();
  }

  void _ensureInitialFromConfig(NotionConfig cfg) {
    // 不再用一次性 _initialized 标记 —— 那会让 username 还在 loading 时
    // 同步进空 cfg 后再也不更新。改为:只要 controller 还是空 + cfg 有值
    // 就同步一次。这样首次 build 拿到的是空 cfg(controller 也空,不冲突),
    // notifier 异步加载完成后 cfg 变为有值,本方法被再次调用时把值灌入。
    // 用户主动清空 controller 想抹掉配置时不会被回填(因为对应 cfg 也会被 clear)。
    if (_tokenController.text.isEmpty &&
        (cfg.integrationToken ?? '').isNotEmpty) {
      _tokenController.text = cfg.integrationToken!;
    }
    if (_databaseIdController.text.isEmpty &&
        (cfg.databaseId ?? '').isNotEmpty) {
      _databaseIdController.text = cfg.databaseId!;
    }
    if (!_initialized && cfg.isComplete) {
      _initialized = true;
      _checkUpgrade(cfg);
    }
  }

  Future<void> _checkUpgrade(NotionConfig cfg) async {
    try {
      final svc = NotionSyncService(config: cfg);
      final ok = await svc.isDatabaseUpToDate();
      if (!mounted) return;
      setState(() => _needsUpgrade = !ok);
    } catch (_) {
      // 检测失败就当不需要升级,不打扰用户
      if (mounted) setState(() => _needsUpgrade = false);
    }
  }

  Future<void> _doUpgrade(NotionConfig cfg) async {
    setState(() => _upgrading = true);
    try {
      final svc = NotionSyncService(config: cfg);
      await svc.upgradeDatabase();
      if (!mounted) return;
      setState(() => _needsUpgrade = false);
      ToastService.showSuccess(S.current.notion_upgradeSucceed);
    } on NotionApiException catch (e) {
      ToastService.showError(S.current.notion_upgradeFailed(e.message));
    } catch (e) {
      ToastService.showError(S.current.notion_upgradeFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _upgrading = false);
    }
  }

  Future<void> _saveAndTest() async {
    final token = _tokenController.text.trim();
    final dbId = _databaseIdController.text.trim();
    if (token.isEmpty || dbId.isEmpty) {
      ToastService.showError(S.current.notion_fillTokenAndDb);
      return;
    }
    setState(() => _testing = true);
    try {
      final svc = NotionSyncService(
        config: NotionConfig(integrationToken: token, databaseId: dbId),
      );
      final title = await svc.testConnection();
      await ref
          .read(notionConfigProvider.notifier)
          .update(
            ref.read(notionConfigProvider).copyWith(
              integrationToken: token,
              databaseId: dbId,
            ),
          );
      if (!mounted) return;
      ToastService.showSuccess(S.current.notion_testOk(title));
    } on NotionApiException catch (e) {
      ToastService.showError(S.current.notion_testFailed(e.message));
    } catch (e) {
      ToastService.showError(S.current.notion_testFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _disconnect() async {
    await ref.read(notionConfigProvider.notifier).clear();
    if (!mounted) return;
    _tokenController.clear();
    _databaseIdController.clear();
    ToastService.show(S.current.notion_disconnected);
  }

  Future<void> _openIntegrationsPage() async {
    final uri = Uri.parse('https://www.notion.so/my-integrations');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _createTemplateDatabase() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty) {
      ToastService.showError(S.current.notion_tokenRequired);
      return;
    }
    final parentId = await _askParentPageId();
    if (parentId == null || parentId.isEmpty) return;
    setState(() => _testing = true);
    try {
      final client = NotionClient(token);
      final created = await client.createDatabaseForExport(
        parentPageId: parentId,
        title: 'FluxDO 导出',
      );
      final dbId = created['id'] as String?;
      if (dbId == null) throw NotionApiException('No id in response');
      _databaseIdController.text = dbId;
      if (!mounted) return;
      ToastService.showSuccess(S.current.notion_databaseCreated);
    } on NotionApiException catch (e) {
      ToastService.showError(S.current.notion_dbCreateFailed(e.message));
    } catch (e) {
      ToastService.showError(S.current.notion_dbCreateFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<String?> _askParentPageId() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.current.notion_pickParentPage),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              S.current.notion_pickParentPageHint,
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Parent Page ID',
                hintText: 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(S.current.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(S.current.common_confirm),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cfg = ref.watch(notionConfigProvider);
    _ensureInitialFromConfig(cfg);
    // 已完整配置且没有点"编辑"时,把步骤折叠成一行徽标。
    final showSteps = !cfg.isComplete || _editing;

    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.notion_title),
        actions: [
          if (cfg.isComplete)
            TextButton.icon(
              icon: const Icon(Symbols.link_off_rounded, size: 16),
              onPressed: _testing ? null : _disconnect,
              label: Text(context.l10n.notion_disconnect),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          // 顶部说明
          _Header(),
          const SizedBox(height: 20),

          if (cfg.isComplete && _needsUpgrade == true) ...[
            _UpgradeBanner(
              upgrading: _upgrading,
              onUpgrade: () => _doUpgrade(cfg),
            ),
            const SizedBox(height: 16),
          ],

          if (!showSteps) ...[
            _ConfiguredBanner(
              onEdit: () => setState(() => _editing = true),
            ),
          ] else ...[
            // Step 1: Token
            _StepCard(
              index: 1,
              title: context.l10n.notion_step1Title,
              body: context.l10n.notion_step1Body,
              done: cfg.integrationToken != null &&
                  cfg.integrationToken!.isNotEmpty,
              children: [
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Symbols.open_in_new_rounded, size: 16),
                  onPressed: _openIntegrationsPage,
                  label: Text(context.l10n.notion_openIntegrationsPage),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _tokenController,
                  obscureText: _obscureToken,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: context.l10n.notion_tokenSection,
                    hintText: 'secret_xxxxxxxxxxxxxxxx',
                    filled: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureToken
                            ? Symbols.visibility_off_rounded
                            : Symbols.visibility_rounded,
                        size: 18,
                      ),
                      onPressed: () =>
                          setState(() => _obscureToken = !_obscureToken),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Step 2: Database
            _StepCard(
              index: 2,
              title: context.l10n.notion_step2Title,
              body: context.l10n.notion_step2Body,
              done:
                  cfg.databaseId != null && cfg.databaseId!.isNotEmpty,
              children: [
                const SizedBox(height: 12),
                TextField(
                  controller: _databaseIdController,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: context.l10n.notion_databaseSection,
                    hintText: 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
                    filled: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    suffixIcon: IconButton(
                      tooltip: context.l10n.common_paste,
                      icon: const Icon(Symbols.content_paste_rounded, size: 18),
                      onPressed: () async {
                        final data = await Clipboard.getData('text/plain');
                        final text = data?.text?.trim();
                        if (text != null && text.isNotEmpty) {
                          _databaseIdController.text = text;
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Symbols.auto_awesome_rounded, size: 16),
                  onPressed: _testing ? null : _createTemplateDatabase,
                  label: Text(context.l10n.notion_createTemplateDb),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Step 3: Save + test
            _StepCard(
              index: 3,
              title: context.l10n.notion_step3Title,
              body: context.l10n.notion_step3Body,
              done: cfg.isComplete && !_editing,
              children: [
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: _testing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Symbols.check_circle_rounded, size: 18),
                    onPressed: _testing
                        ? null
                        : () async {
                            await _saveAndTest();
                            if (mounted &&
                                ref.read(notionConfigProvider).isComplete) {
                              setState(() => _editing = false);
                            }
                          },
                    label: Text(context.l10n.notion_saveAndTest),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ],
            ),
          ],

          // Sync options
          if (cfg.isComplete) ...[
            const SizedBox(height: 24),
            _SectionTitle(context.l10n.notion_syncOptions),
            const SizedBox(height: 8),
            SegmentedCardGroup(
              children: [
                SwitchListTile(
                  title: Text(
                    context.l10n.notion_autoSyncOnBookmark,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  subtitle: Text(
                    context.l10n.notion_autoSyncDesc,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  value: cfg.autoSyncOnBookmark,
                  onChanged: (v) {
                    ref
                        .read(notionConfigProvider.notifier)
                        .update(cfg.copyWith(autoSyncOnBookmark: v));
                  },
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.notion_syncScope,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 8),
                      M3eButtonGroup<NotionSyncScope>(
                        items: [
                          M3eButtonGroupItem(
                            value: NotionSyncScope.firstPostOnly,
                            label: Text(
                              context.l10n.export_firstPostOnly,
                            ),
                          ),
                          M3eButtonGroupItem(
                            value: NotionSyncScope.allPosts,
                            label: Text(context.l10n.common_all),
                          ),
                        ],
                        selected: cfg.syncScope,
                        onSelected: (scope) {
                          ref
                              .read(notionConfigProvider.notifier)
                              .update(cfg.copyWith(syncScope: scope));
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],

          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(
                  Symbols.lock_rounded,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.l10n.notion_tokenSecurityNote,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 11,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Database 缺少新版字段时显示的升级 banner。
class _UpgradeBanner extends StatelessWidget {
  const _UpgradeBanner({required this.upgrading, required this.onUpgrade});

  final bool upgrading;
  final VoidCallback onUpgrade;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = Colors.amber.shade700;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Symbols.upgrade_rounded, color: accent, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.l10n.notion_upgradeAvailable,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: accent,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.notion_upgradeMessage,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
              height: 1.5,
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              icon: upgrading
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Symbols.bolt_rounded, size: 16),
              onPressed: upgrading ? null : onUpgrade,
              label: Text(context.l10n.notion_upgradeAction),
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 已配置完成状态下显示的紧凑徽标,替代 3 张步骤卡。
/// 点"修改"可重新展开编辑。
class _ConfiguredBanner extends StatelessWidget {
  const _ConfiguredBanner({required this.onEdit});

  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(
              Symbols.check_rounded,
              size: 18,
              color: theme.colorScheme.onPrimary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              context.l10n.notion_configured,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton.icon(
            icon: const Icon(Symbols.edit_rounded, size: 16),
            onPressed: onEdit,
            label: Text(context.l10n.notion_editConfig),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            theme.colorScheme.primary.withValues(alpha: 0.12),
            theme.colorScheme.primary.withValues(alpha: 0.04),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Symbols.cloud_sync_rounded,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.notion_title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  context.l10n.notion_subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 步骤卡片。step done 时左上角圆圈显示 ✓。
class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.index,
    required this.title,
    required this.body,
    required this.done,
    required this.children,
  });

  final int index;
  final String title;
  final String body;
  final bool done;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: done
              ? theme.colorScheme.primary.withValues(alpha: 0.4)
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
          width: done ? 1.2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: done
                      ? theme.colorScheme.primary
                      : theme.colorScheme.surfaceContainerHighest,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: done
                    ? Icon(
                        Symbols.check_rounded,
                        size: 16,
                        color: theme.colorScheme.onPrimary,
                      )
                    : Text(
                        '$index',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            body,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.6,
            ),
          ),
          ...children,
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
