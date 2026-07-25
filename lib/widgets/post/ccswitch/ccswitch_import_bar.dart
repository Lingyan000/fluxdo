import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/s.dart';
import '../../../models/topic.dart';
import '../../../providers/preferences_provider.dart';
import '../../../services/toast_service.dart';
import '../../../utils/ccswitch/ccswitch_credentials.dart';
import '../../../utils/ccswitch/ccswitch_launcher.dart';

/// Main-post (#1) inline bar: detect BASE URL + API Key and open CC Switch.
///
/// Mirrors userscript `ensureMainPostCcswitchImport` placement near the
/// post date / floor meta area.
class CcswitchImportBar extends ConsumerStatefulWidget {
  final Post post;

  /// Optional compact mode for tight header slots.
  final bool compact;

  const CcswitchImportBar({
    super.key,
    required this.post,
    this.compact = false,
  });

  @override
  ConsumerState<CcswitchImportBar> createState() => _CcswitchImportBarState();
}

class _CcswitchImportBarState extends ConsumerState<CcswitchImportBar> {
  CcswitchCredentials? _credentials;
  bool _pickerOpen = false;
  bool _busy = false;
  late final TextEditingController _nameController;
  CcswitchImportApp _pickedApp = CcswitchImportApp.codex;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _scanFromPost(silent: true);
  }

  @override
  void didUpdateWidget(CcswitchImportBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.post.id != widget.post.id ||
        oldWidget.post.cooked != widget.post.cooked) {
      _scanFromPost(silent: true);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _scanFromPost({bool silent = false}) {
    final found = detectCredentialsFromCooked(widget.post.cooked);
    setState(() {
      _credentials = found;
      if (found?.name != null && found!.name!.isNotEmpty) {
        _nameController.text = found.name!;
      }
    });
    if (silent) return;
    if (found == null) {
      ToastService.showInfo(S.current.ccswitch_notFound);
      return;
    }
    if (found.isComplete) {
      ToastService.showSuccess(
        S.current.ccswitch_detected(
          found.baseUrl ?? '',
          maskApiKey(found.apiKey),
        ),
      );
    } else {
      ToastService.showInfo(S.current.ccswitch_partial);
    }
  }

  Future<void> _openCcSwitch() async {
    final creds = _credentials;
    if (creds == null || !creds.isComplete) {
      ToastService.showInfo(S.current.ccswitch_needUrlAndKey);
      return;
    }
    final appMode = _pickerOpen
        ? _pickedApp
        : ref.read(preferencesProvider).ccswitchImportApp;
    final name = _nameController.text.trim().isNotEmpty
        ? _nameController.text.trim()
        : creds.name;
    final withName = creds.copyWith(name: name);
    final links = buildCcswitchDeeplinks(appMode, withName, name: name);

    setState(() => _busy = true);
    try {
      var opened = 0;
      for (var i = 0; i < links.length; i++) {
        if (i > 0) await Future<void>.delayed(const Duration(milliseconds: 600));
        final ok = await launchCcswitchDeeplink(links[i]);
        if (ok) opened += 1;
      }
      if (opened == 0) {
        ToastService.showError(S.current.ccswitch_openFailed);
      } else {
        ToastService.showSuccess(S.current.ccswitch_opened(opened));
        if (mounted) setState(() => _pickerOpen = false);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyDeeplink() async {
    final creds = _credentials;
    if (creds == null || !creds.isComplete) {
      ToastService.showInfo(S.current.ccswitch_needUrlAndKey);
      return;
    }
    final appMode = ref.read(preferencesProvider).ccswitchImportApp;
    final name = _nameController.text.trim().isNotEmpty
        ? _nameController.text.trim()
        : creds.name;
    final links = buildCcswitchDeeplinks(
      appMode == CcswitchImportApp.all ? CcswitchImportApp.codex : appMode,
      creds.copyWith(name: name),
      name: name,
    );
    if (links.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: links.first));
    ToastService.showSuccess(S.current.ccswitch_linkCopied);
  }

  void _openPicker() {
    final preferred = ref.read(preferencesProvider).ccswitchImportApp;
    setState(() {
      _pickedApp = preferred == CcswitchImportApp.all
          ? CcswitchImportApp.codex
          : preferred;
      _pickerOpen = !_pickerOpen;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.post.postNumber != 1) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final l10n = context.l10n;
    final ready = _credentials?.isComplete == true;
    final partial = _credentials != null && !ready;

    final statusColor = ready
        ? theme.colorScheme.primary
        : partial
            ? theme.colorScheme.tertiary
            : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7);

    return Material(
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _ActionChip(
                label: l10n.ccswitch_fill,
                primary: true,
                enabled: !_busy,
                onTap: ready ? _openPicker : () {
                  _scanFromPost();
                  if (_credentials?.isComplete == true) {
                    _openPicker();
                  }
                },
              ),
              if (_credentials != null)
                Text(
                  ready
                      ? l10n.ccswitch_statusReady
                      : l10n.ccswitch_statusPartial,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: statusColor,
                    fontSize: 11,
                  ),
                ),
              _ActionChip(
                label: l10n.ccswitch_rescan,
                onTap: _busy ? null : () => _scanFromPost(),
              ),
              _ActionChip(
                label: l10n.ccswitch_copy,
                enabled: ready && !_busy,
                onTap: ready ? _copyDeeplink : null,
              ),
            ],
          ),
          if (_pickerOpen) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.ccswitch_fill,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.ccswitch_app,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final app in const [
                        CcswitchImportApp.claude,
                        CcswitchImportApp.codex,
                        CcswitchImportApp.gemini,
                      ])
                        ChoiceChip(
                          label: Text(_appLabel(l10n, app)),
                          selected: _pickedApp == app,
                          onSelected: (_) => setState(() => _pickedApp = app),
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    l10n.ccswitch_name,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: l10n.ccswitch_nameHint,
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                    ),
                  ),
                  if (ready) ...[
                    const SizedBox(height: 8),
                    Text(
                      '${_credentials!.baseUrl} / ${maskApiKey(_credentials!.apiKey)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() => _pickerOpen = false),
                        child: Text(l10n.common_cancel),
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: _busy ? null : _openCcSwitch,
                        icon: _busy
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Symbols.open_in_new_rounded, size: 16),
                        label: Text(l10n.ccswitch_open),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _appLabel(AppLocalizations l10n, CcswitchImportApp app) {
    return switch (app) {
      CcswitchImportApp.claude => l10n.ccswitch_appClaude,
      CcswitchImportApp.codex => l10n.ccswitch_appCodex,
      CcswitchImportApp.gemini => l10n.ccswitch_appGemini,
      CcswitchImportApp.all => l10n.ccswitch_appAll,
    };
  }
}

class _ActionChip extends StatelessWidget {
  final String label;
  final bool primary;
  final bool enabled;
  final VoidCallback? onTap;

  const _ActionChip({
    required this.label,
    this.primary = false,
    this.enabled = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveOnTap = enabled ? onTap : null;
    if (primary) {
      return FilledButton.tonal(
        onPressed: effectiveOnTap,
        style: FilledButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          minimumSize: const Size(0, 28),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: theme.textTheme.labelSmall?.copyWith(fontSize: 11),
        ),
        child: Text(label),
      );
    }
    return OutlinedButton(
      onPressed: effectiveOnTap,
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: theme.textTheme.labelSmall?.copyWith(fontSize: 11),
      ),
      child: Text(label),
    );
  }
}
