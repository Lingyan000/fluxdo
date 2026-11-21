import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/s.dart';
import '../../../../navigation/nav_entry.dart';
import '../../../../utils/link_launcher.dart';
import '../../../../utils/dialog_utils.dart';
import '../providers/metaverse_plugin_providers.dart';
import 'metaverse_plugin_surface_view.dart';

/// 插件声明的一个独立页面。
///
/// 返回、关闭及安全区由宿主提供，插件可向标题栏提供标题与操作组件。
class MetaversePluginPage extends ConsumerStatefulWidget {
  const MetaversePluginPage({
    super.key,
    required this.pluginId,
    required this.page,
    this.params = const {},
    this.modal = false,
    this.workspace = false,
  });

  final String pluginId;
  final String page;
  final bool modal;
  final bool workspace;
  final Map<String, Object?> params;

  /// 只关闭发起调用的插件弹层。确认对话框和普通导航页有独立的路由。
  static bool dismissModal(BuildContext source, String pluginId, String page) {
    final owner = source.findAncestorWidgetOfExactType<MetaversePluginPage>();
    final route = ModalRoute.of(source);
    if (owner == null || !owner.modal || owner.pluginId != pluginId || owner.page != page ||
        route is! PopupRoute || !route.isCurrent) {
      return false;
    }
    route.navigator!.pop();
    return true;
  }

  static Future<void> open(
    BuildContext context,
    String pluginId,
    String page, {
    Map<String, Object?> params = const {},
  }) async {
    final plugin = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(metaversePluginsProvider.notifier).byId(pluginId);
    if (plugin?.manifest.page(page)?.modal == true) {
      final content = MetaversePluginPage(
        pluginId: pluginId,
        page: page,
        params: params,
        modal: true,
      );
      if (MediaQuery.sizeOf(context).width >= 600) {
        await showAppDialog<void>(
          context: context,
          builder: (_) => Dialog(
            clipBehavior: Clip.antiAlias,
            child: SizedBox(width: 560, height: 640, child: content),
          ),
        );
      } else {
        await showAppBottomSheet<void>(
          context: context,
          useRootNavigator: true,
          useSafeArea: true,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (context) => Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: FractionallySizedBox(heightFactor: .88, child: content),
          ),
        );
      }
      return;
    }
    await Navigator.of(context).push<void>(
      InteractionPageRoute(
        builder: (_) =>
            MetaversePluginPage(pluginId: pluginId, page: page, params: params),
      ),
    );
  }

  /// 仅替换当前插件的普通页面；完成步骤后不再返回已经结束的表单。
  static void replace(BuildContext source, String pluginId, String page,
      {Map<String, Object?> params = const {}}) {
    final owner = source.findAncestorWidgetOfExactType<MetaversePluginPage>();
    final route = ModalRoute.of(source);
    if (owner == null || owner.pluginId != pluginId || owner.modal || owner.workspace ||
        route == null || route is PopupRoute || !route.isCurrent) {
      throw StateError('navigation_replace_unavailable');
    }
    Navigator.of(source).pushReplacement<void, void>(InteractionPageRoute(
      builder: (_) => MetaversePluginPage(pluginId: pluginId, page: page, params: params),
    ));
  }

  @override
  ConsumerState<MetaversePluginPage> createState() => _MetaversePluginPageState();
}

class _MetaversePluginPageState extends ConsumerState<MetaversePluginPage> {
  final _scroll = ScrollController();
  String get pluginId => widget.pluginId;
  String get page => widget.page;
  bool get modal => widget.modal;
  bool get workspace => widget.workspace;
  Map<String, Object?> get params => widget.params;
  @override
  void dispose() { _scroll.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final plugin = ref.watch(
      metaversePluginsProvider.select((plugins) {
        for (final item in plugins) {
          if (item.id == pluginId) return item;
        }
        return null;
      }),
    );
    final spec = plugin?.manifest.page(page);
    // 由帖内链接打开时带着原始地址，给用户留一条"用浏览器打开"的退路。
    final sourceUrl = params['url'];
    Widget frame(Widget body, [Widget Function(String name)? render]) {
      final content = spec?.scroll == false
          ? body
          : Builder(builder: (context) => SingleChildScrollView(controller: _scroll,
              padding: EdgeInsets.fromLTRB(16, 16, 16,
                  16 + MediaQuery.paddingOf(context).bottom), child: body));
      return MetaversePluginPageFrame(
          title: spec?.title ?? plugin?.manifest.name ?? pluginId,
          customTitle: render != null && spec?.appBarTitle != null ? render(spec!.appBarTitle!) : null,
          actions: render != null && spec?.appBarActions != null ? render(spec!.appBarActions!) : null,
          sourceUrl: sourceUrl is String ? sourceUrl : null,
          modal: modal,
          workspace: workspace,
          child: content,
      );
    }

    final Widget body;
    if (plugin == null || spec == null || !plugin.enabled) {
      body = MetaversePluginErrorView(pluginId: pluginId, message: '$pluginId/$page', onRetry: plugin == null ? null : () async {
        await ref.read(metaversePluginsProvider.notifier).resume(pluginId);
        await ref.read(metaversePluginsProvider.notifier).setEnabled(pluginId, enabled: true);
      });
    } else if (plugin.suspendedReason case final String reason) {
      body = MetaversePluginErrorView(pluginId: pluginId,
        message: reason == 'rollback_review_required' ? context.l10n.metaverse_rollbackReview : reason,
        onRetry: reason == 'rollback_review_required' ? null : () => ref.read(metaversePluginsProvider.notifier).resume(pluginId));
    } else {
      final host = ref.watch(metaversePluginHostsProvider).hostFor(plugin);
      return PrimaryScrollController(controller: _scroll, child: MetaversePluginSurfaceView(
        host: host,
        kind: MetaversePluginSurfaceKind.page,
        page: page,
        params: params,
        navigationId: workspace ? pluginNavigationId(pluginId, page) : null,
        builder: (context, content, render) => frame(Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [ValueListenableBuilder<String?>(
            valueListenable: host.dnsRetryHost,
            builder: (context, name, _) => name == null
                ? const SizedBox.shrink()
                : OutlinedButton(
                    onPressed: () => host.enableDohForFailedHost(name),
                    child: Text(context.l10n.metaverse_pluginUseDoh(name)),
                  ),
          ),
          if (!spec.scroll) Expanded(child: content) else content,
          ],
        ), render),
      ));
    }
    return PrimaryScrollController(controller: _scroll, child: frame(body));
  }
}

/// 普通页和弹层共用标题栏插槽；返回与关闭始终由宿主保留。
class MetaversePluginPageFrame extends StatelessWidget {
  const MetaversePluginPageFrame({super.key, required this.title, required this.child,
    this.customTitle, this.actions, this.sourceUrl, this.modal = false, this.workspace = false});
  final String title;
  final Widget child;
  final Widget? customTitle;
  final Widget? actions;
  final String? sourceUrl;
  final bool modal;
  final bool workspace;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => _build(context, constraints.maxWidth),
  );

  Widget _build(BuildContext context, double width) {
    final titleWidget = customTitle == null ? Text(
      title,
      style: Theme.of(context).textTheme.titleMedium,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ) : ClipRect(child: ConstrainedBox(constraints: const BoxConstraints(maxHeight: kToolbarHeight), child: customTitle));
    final buttons = <Widget>[
      if (actions != null)
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width * .5, maxHeight: kToolbarHeight),
          child: SingleChildScrollView(primary: false, scrollDirection: Axis.horizontal, child: actions),
        ),
      if (sourceUrl != null && actions == null)
        IconButton(
          tooltip: context.l10n.metaverse_pluginOpen,
          icon: const Icon(Symbols.open_in_new_rounded),
          onPressed: () => launchExternalLink(context, sourceUrl!),
        ),
    ];
    if (modal) {
      return AppSheetScaffold(
        titleWidget: titleWidget,
        actions: buttons,
        showDragHandle: MediaQuery.sizeOf(context).width < 600,
        expandToFill: true,
        contentPadding: EdgeInsets.zero,
        child: child,
      );
    }
    return Scaffold(
      appBar: AppBar(title: titleWidget, actions: buttons, automaticallyImplyLeading: !workspace),
      body: SafeArea(top: false, bottom: false, child: child),
    );
  }
}
