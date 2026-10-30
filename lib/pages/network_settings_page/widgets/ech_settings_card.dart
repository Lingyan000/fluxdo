import 'package:app_icons/app_icons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../l10n/s.dart';
import '../../../services/network/doh/ech_dns_policy.dart';
import '../../../utils/dialog_utils.dart';
import '../../../widgets/common/app_bottom_sheet.dart';

/// ECH 配置来源与公共入口策略分层展示，域名列表按需展开。
class EchSettingsCard extends StatelessWidget {
  const EchSettingsCard({
    super.key,
    required this.policy,
    required this.serverSelector,
    required this.onChanged,
  });

  final EchDnsPolicy policy;
  final Widget serverSelector;
  final ValueChanged<EchDnsPolicy> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SegmentedCardGroup(
      children: [
        serverSelector,
        SwitchListTile(
          secondary: const Icon(Symbols.encrypted_rounded),
          title: Text(l10n.dohDetail_publicEch),
          subtitle: Text(
            policy.enabled
                ? l10n.dohDetail_publicEchDesc
                : l10n.dohDetail_publicEchDisabledDesc,
          ),
          value: policy.enabled,
          onChanged: (enabled) => onChanged(policy.copyWith(enabled: enabled)),
        ),
        if (policy.enabled)
          ListTile(
            leading: const Icon(AppIcons.language),
            title: Text(l10n.dohDetail_echDomains),
            subtitle: Text(
              l10n.dohDetail_echDomainsCount(
                EchDnsPolicy.builtinDomains.length,
                policy.customDomains.length,
              ),
            ),
            trailing: const Icon(AppIcons.chevronRight),
            onTap: () async {
              final domains = await AppBottomSheet.showDraggable<List<String>>(
                context: context,
                title: l10n.dohDetail_echDomains,
                showCloseButton: true,
                initialSize: 0.75,
                minSize: 0.5,
                maxSize: 0.95,
                bodyBuilder: (context, controller) => EchDomainsEditor(
                  initialDomains: policy.customDomains,
                  scrollController: controller,
                  onSave: (domains) => Navigator.pop(context, domains),
                ),
              );
              if (domains != null && context.mounted) {
                onChanged(policy.copyWith(customDomains: domains));
              }
            },
          ),
      ],
    );
  }
}

/// 域名变更在弹层中暂存，保存时一次应用，避免逐条操作反复重启连接。
class EchDomainsEditor extends StatefulWidget {
  const EchDomainsEditor({
    super.key,
    required this.initialDomains,
    required this.onSave,
    this.scrollController,
  });

  final List<String> initialDomains;
  final ValueChanged<List<String>> onSave;
  final ScrollController? scrollController;

  @override
  State<EchDomainsEditor> createState() => _EchDomainsEditorState();
}

class _EchDomainsEditorState extends State<EchDomainsEditor> {
  late final List<String> _domains = [...widget.initialDomains];

  Future<void> _editDomain([int? index]) async {
    final result = await showAppDialog<String>(
      context: context,
      builder: (_) => EchDomainDialog(
        initialDomain: index == null ? null : _domains[index],
        existingDomains: [
          ...EchDnsPolicy.builtinDomains,
          for (var i = 0; i < _domains.length; i++)
            if (i != index) _domains[i],
        ],
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      if (index == null) {
        _domains.add(result);
      } else {
        _domains[index] = result;
      }
    });
    if (index == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final controller = widget.scrollController;
        if (controller == null || !controller.hasClients) return;
        controller.animateTo(
          controller.position.maxScrollExtent,
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final changed = !listEquals(widget.initialDomains, _domains);
    return Column(
      children: [
        Expanded(
          child: ListView(
            controller: widget.scrollController,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            children: [
              Text(
                l10n.dohDetail_echDomainsHint,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                l10n.dohDetail_builtinDomains,
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 12),
              SegmentedCardGroup(
                children: [
                  for (final domain in EchDnsPolicy.builtinDomains)
                    ListTile(
                      title: Text(domain),
                      subtitle: Text(l10n.dohDetail_includesSubdomains),
                      trailing: const Icon(
                        AppIcons.lock,
                        size: 20,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 24),
              // 标题和添加按钮分别占位，放大文字时仍可自然换行。
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.dohDetail_customDomains,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => _editDomain(),
                    icon: const Icon(AppIcons.add, size: 20),
                    label: Text(l10n.common_add),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_domains.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    l10n.dohDetail_noCustomDomains,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                SegmentedCardGroup(
                  children: [
                    for (var index = 0; index < _domains.length; index++)
                      ListTile(
                        title: Text(_domains[index]),
                        subtitle: Text(l10n.dohDetail_includesSubdomains),
                        onTap: () => _editDomain(index),
                        trailing: IconButton(
                          icon: const Icon(AppIcons.delete),
                          tooltip: l10n.common_delete,
                          onPressed: () =>
                              setState(() => _domains.removeAt(index)),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: changed
                    ? () => widget.onSave(List.unmodifiable(_domains))
                    : null,
                child: Text(l10n.common_save),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class EchDomainDialog extends StatefulWidget {
  const EchDomainDialog({
    super.key,
    this.initialDomain,
    required this.existingDomains,
  });

  final String? initialDomain;
  final List<String> existingDomains;

  @override
  State<EchDomainDialog> createState() => _EchDomainDialogState();
}

class _EchDomainDialogState extends State<EchDomainDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _controller = TextEditingController(text: widget.initialDomain);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    if (_formKey.currentState!.validate()) {
      Navigator.pop(context, EchDnsPolicy.normalizeDomain(_controller.text));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(
        widget.initialDomain == null
            ? l10n.dohDetail_addEchDomain
            : l10n.dohDetail_editEchDomain,
      ),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: TextFormField(
            controller: _controller,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            decoration: InputDecoration(
              labelText: l10n.dohDetail_domain,
              hintText: 'example.com',
              helperText: l10n.dohDetail_domainHelper,
              helperMaxLines: 3,
              errorMaxLines: 3,
            ),
            validator: (value) {
              if (!EchDnsPolicy.isValidDomain(value ?? '')) {
                return l10n.dohDetail_invalidDomain;
              }
              final domain = EchDnsPolicy.normalizeDomain(value!);
              if (widget.existingDomains.any(
                (existing) => EchDnsPolicy.covers(existing, domain),
              )) {
                return l10n.dohDetail_domainAlreadyCovered;
              }
              return null;
            },
            onFieldSubmitted: (_) => _save(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.common_cancel),
        ),
        FilledButton(onPressed: _save, child: Text(l10n.common_save)),
      ],
    );
  }
}
