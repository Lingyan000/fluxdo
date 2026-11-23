import 'dart:async';

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../l10n/s.dart';
import '../plugin/ui/metaverse_plugin_dialogs.dart';
import '../plugin/ui/metaverse_plugin_page.dart';
import '../plugin/ui/metaverse_plugin_surface_view.dart';
import 'session/development_session.dart';

class MetaverseDevelopmentPage extends ConsumerStatefulWidget {
  const MetaverseDevelopmentPage({super.key});
  @override
  ConsumerState<MetaverseDevelopmentPage> createState() =>
      _DevelopmentPageState();
}

class _DevelopmentPageState extends ConsumerState<MetaverseDevelopmentPage>
    with WidgetsBindingObserver {
  final _pairing = TextEditingController();
  DevelopmentSession? _session;
  bool _reviewing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.inactive) {
      _session?.foreground = state == AppLifecycleState.resumed;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pairing.dispose();
    super.dispose();
  }

  Future<void> _start(DevelopmentSession session) async {
    final next = session.pendingProject ?? session.project;
    if (next == null || _reviewing) {
      return;
    }
    setState(() => _reviewing = true);
    try {
      final choices = await showMetaversePluginInstallSheet(
        context,
        next.manifest,
        isUpdate: false,
        confirmLabel: context.l10n.metaverse_devStart,
        initialBlocked: session.reviewPermissions(next),
      );
      if (choices != null && mounted) {
        await session.start(next, choices: choices);
      }
    } catch (error) {
      session.diagnostic('$error');
    } finally {
      if (mounted) {
        setState(() => _reviewing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(metaverseDevelopmentSessionProvider);
    _session = session;
    session.replace = (source, page, params) {
      final owner = source.findAncestorWidgetOfExactType<_DevelopmentPreviewPage>();
      if (owner?.session != session || ModalRoute.of(source)?.isCurrent != true) {
        throw StateError('navigation_replace_unavailable');
      }
      Navigator.of(source).pushReplacement<void, void>(InteractionPageRoute(
        builder: (_) => _DevelopmentPreviewPage(session: session, page: page, params: params),
      ));
    };
    session.navigate = (context, page, params) {
      Navigator.of(context).push<void>(
        InteractionPageRoute(
          builder: (_) => _DevelopmentPreviewPage(
            session: session,
            page: page,
            params: params,
          ),
        ),
      );
    };
    final l = context.l10n;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final host = session.host;
        return PopScope(
          canPop: !session.busy,
          child: Scaffold(
            appBar: AppBar(
              title: Text(l.metaverse_devTitle),
              actions: [
                if (session.state != 'idle')
                  IconButton(
                    tooltip: l.metaverse_devDisconnect,
                    onPressed: session.busy ? null : session.stop,
                    icon: const Icon(Symbols.link_off_rounded),
                  ),
              ],
            ),
            body: SafeArea(
              child: ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (session.state == 'idle' ||
                            session.state == 'disconnected') ...[
                          Text(
                            l.metaverse_devIntro,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 12),
                          InputFieldShell(
                            child: TextField(
                              controller: _pairing,
                              autocorrect: false,
                              textAlignVertical: TextAlignVertical.center,
                              decoration: InputDecoration(
                                hintText: l.metaverse_devPairing,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                prefixIcon: const Icon(Symbols.link_rounded),
                              ),
                              onSubmitted: (_) => _connect(session),
                            ),
                          ),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: () => _connect(session),
                            icon: const Icon(Symbols.cable_rounded),
                            label: Text(l.metaverse_devConnect),
                          ),
                        ],
                        if (session.state != 'idle')
                          SegmentedCardGroup(
                            children: [
                              ListTile(
                                leading: session.state == 'connecting'
                                    ? const SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: LoadingSpinner(size: 24),
                                      )
                                    : Icon(
                                        Symbols.developer_mode_rounded,
                                        color: context.emphasis.accent,
                                      ),
                                title: Text(switch (session.state) {
                                  'connecting' => l.metaverse_devConnecting,
                                  'connected' =>
                                    session.project?.manifest.localizedName(context.l10n.localeName) ??
                                        session.pendingProject?.manifest.localizedName(context.l10n.localeName) ??
                                        l.metaverse_devConnected,
                                  _ => l.metaverse_devDisconnected,
                                }),
                                subtitle: Text(l.metaverse_devIsolated),
                              ),
                            ],
                          ),
                        if (session.waiting)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(l.metaverse_devWaiting),
                          ),
                        if (session.pendingProject != null ||
                            session.restartRequired)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: FilledButton.tonalIcon(
                              onPressed:
                                  session.state == 'connected' &&
                                      !session.busy &&
                                      !_reviewing
                                  ? () => _start(session)
                                  : null,
                              icon: const Icon(Symbols.play_arrow_rounded),
                              label: Text(
                                host == null
                                    ? l.metaverse_devStart
                                    : l.metaverse_devRestart,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (session.diagnostics.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: SegmentedCardGroup(
                        children: [
                          ExpansionTile(
                            title: Text(l.metaverse_devDiagnostics),
                            trailing: IconButton(
                              tooltip: l.common_clear,
                              onPressed: () {
                                session.diagnostics.clear();
                                setState(() {});
                              },
                              icon: const Icon(Symbols.delete_outline_rounded),
                            ),
                            children: [
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxHeight: 160,
                                ),
                                child: SingleChildScrollView(
                                  padding: const EdgeInsets.all(12),
                                  child: SelectableText(
                                    session.diagnostics.join('\n\n'),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  SizedBox(
                    child: host == null
                        ? ListView(
                            padding: const EdgeInsets.all(16),
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            children: [
                              SegmentedCardGroup(
                                children: [
                                  ListTile(
                                    title: Text(l.metaverse_devInstructions),
                                    subtitle: const SelectableText(
                                      'pnpm dev\nadb reverse tcp:5174 tcp:5174',
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          )
                        : AbsorbPointer(
                            absorbing:
                                session.state != 'connected' ||
                                session.updating ||
                                session.restartRequired,
                            child: _DevelopmentPreview(session: session),
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _connect(DevelopmentSession session) async {
    try {
      FocusScope.of(context).unfocus();
      await session.connect(_pairing.text);
    } catch (_) {
      if (mounted) {
        session.diagnostic(context.l10n.metaverse_devInvalidPairing);
      }
    }
  }
}

class _DevelopmentPreview extends StatelessWidget {
  const _DevelopmentPreview({required this.session});
  final DevelopmentSession session;
  @override
  Widget build(BuildContext context) {
    final host = session.host!;
    final manifest = host.manifest;
    return ListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [
        if (manifest.cardWidget != null)
          MetaversePluginSurfaceView(
            host: host,
            kind: MetaversePluginSurfaceKind.card,
          ),
        if (manifest.pages.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: SegmentedCardGroup(
              children: [
                for (final page in manifest.pages)
                  ListTile(
                    title: Text(manifest.pageTitle(page, context.l10n.localeName)),
                    trailing: const Icon(Symbols.chevron_right_rounded),
                    onTap: () =>
                        session.navigate?.call(context, page.id, const {}),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _DevelopmentPreviewPage extends StatelessWidget {
  const _DevelopmentPreviewPage({
    required this.session,
    required this.page,
    required this.params,
  });
  final DevelopmentSession session;
  final String page;
  final Map<String, Object?> params;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final host = session.host;
      final spec = host?.manifest.page(page);
      final blocked = session.state != 'connected' ||
          session.updating || session.restartRequired;
      Widget frame(Widget child, [Widget Function(String)? render]) => MetaversePluginPageFrame(
        title: spec?.title ?? context.l10n.metaverse_devTitle,
        customTitle: render != null && spec?.appBarTitle != null
            ? AbsorbPointer(absorbing: blocked, child: render(spec!.appBarTitle!)) : null,
        actions: render != null && spec?.appBarActions != null
            ? AbsorbPointer(absorbing: blocked, child: render(spec!.appBarActions!)) : null,
        child: AbsorbPointer(absorbing: blocked, child: spec?.scroll == false
            ? child
            : Builder(builder: (context) => SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(16, 16, 16,
                  16 + MediaQuery.paddingOf(context).bottom), child: child))),
      );
      if (host == null || spec == null) return frame(const SizedBox.shrink());
      return MetaversePluginSurfaceView(
        host: host,
        kind: MetaversePluginSurfaceKind.page,
        page: page,
        params: params,
        builder: (context, content, render) => frame(content, render),
      );
    },
  );
}
