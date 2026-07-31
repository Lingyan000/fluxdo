import 'package:m3e_ui/m3e_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/ai_l10n.dart';
import '../providers/ai_provider_providers.dart';

class AiAdvancedSettingsPage extends ConsumerWidget {
  const AiAdvancedSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final useAppNetwork = ref.watch(aiUseAppNetworkProvider);
    final hasAdapterFactory = ref.watch(aiDioAdapterFactoryProvider) != null;
    final partialEnabled = ref.watch(aiPartialImagesProvider);

    return Scaffold(
      appBar: AppBar(title: Text(AiL10n.current.advancedSettings)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedCardGroup(
            children: [
              SwitchListTile(
                title: Text(AiL10n.current.useAppNetwork),
                subtitle: Text(AiL10n.current.useAppNetworkSubtitle),
                value: useAppNetwork && hasAdapterFactory,
                onChanged: hasAdapterFactory
                    ? (value) async {
                        final prefs =
                            ref.read(aiSharedPreferencesProvider);
                        await prefs.setBool('ai_use_app_network', value);
                        ref
                            .read(aiUseAppNetworkProvider.notifier)
                            .state = value;
                      }
                    : null,
              ),
              SwitchListTile(
                title: Text(AiL10n.current.partialImagesTitle),
                subtitle: Text(AiL10n.current.partialImagesSubtitle),
                value: partialEnabled,
                onChanged: (value) async {
                  final prefs = ref.read(aiSharedPreferencesProvider);
                  await prefs.setBool('ai_partial_images', value);
                  ref.read(aiPartialImagesProvider.notifier).state =
                      value;
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
