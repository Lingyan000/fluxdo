import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/ai_chat_providers.dart';
import '../providers/ai_provider_providers.dart';
import '../l10n/ai_l10n.dart';
import 'ai_advanced_settings_page.dart';
import 'ai_chat_history_page.dart';
import 'ai_model_config_page.dart';
import 'ai_provider_list_page.dart';
import 'prompt_presets_page.dart';

class AiProvidersPage extends ConsumerWidget {
  final OpenSessionCallback? onOpenSession;

  const AiProvidersPage({super.key, this.onOpenSession});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providerCount = ref.watch(aiProviderListProvider).length;
    final hasModels = ref.watch(hasAvailableAiModelProvider);

    return Scaffold(
      appBar: AppBar(title: Text(AiL10n.current.aiModelService)),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          SegmentedCardGroup(
            children: [
              // 供应商管理
              _SettingsEntry(
                icon: Symbols.dns_rounded,
                title: AiL10n.current.addProvider.replaceAll('添加', '').trim().isEmpty
                    ? 'Providers'
                    : AiL10n.current.addProvider.replaceAll('添加', '').trim(),
                subtitle: providerCount > 0
                    ? '$providerCount'
                    : AiL10n.current.noProviderConfigured,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AiProviderListPage()),
                ),
              ),
              // 模型配置
              if (hasModels)
                _SettingsEntry(
                  icon: Symbols.tune_rounded,
                  title: AiL10n.current.modelConfig,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const AiModelConfigPage()),
                  ),
                ),
              // 聊天记录
              _SettingsEntry(
                icon: Symbols.history_rounded,
                title: AiL10n.current.chatHistory,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        AiChatHistoryPage(onOpenSession: onOpenSession),
                  ),
                ),
              ),
              // 快捷词管理
              _SettingsEntry(
                icon: Symbols.flash_on_rounded,
                title: AiL10n.current.quickPromptsManageTitle,
                subtitle: AiL10n.current.quickPromptsManageHint,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const PromptPresetsPage()),
                ),
              ),
              // 高级设置
              _SettingsEntry(
                icon: Symbols.settings_rounded,
                title: AiL10n.current.advancedSettings,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const AiAdvancedSettingsPage()),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SettingsEntry extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  const _SettingsEntry({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(icon, color: theme.colorScheme.onSurfaceVariant),
      title: Text(title),
      subtitle: subtitle != null
          ? Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : null,
      trailing: Icon(
        Symbols.chevron_right_rounded,
        color: theme.colorScheme.outline.withValues(alpha: 0.4),
        size: 20,
      ),
      onTap: onTap,
    );
  }
}
