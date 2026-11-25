import 'dart:math' as math;
import 'dart:async';
import 'package:flutter/services.dart';

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:jovial_svg/jovial_svg.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:fluxdo_render/fluxdo_render.dart' as content;
import 'package:markdown/markdown.dart' as md;
import 'package:html/parser.dart' as html;
// rfw 的 Switch 是界面描述里的分支节点，与 Material 的开关组件重名。
import 'package:rfw/rfw.dart' hide Switch;

import '../../../../l10n/s.dart';
import '../../../../pages/image_viewer_page.dart';
import '../../../../utils/svg_utils.dart';
import '../../../../widgets/common/image_placeholder.dart';
import '../../../../widgets/common/paged_list_footer.dart';
import '../../../../widgets/common/skeleton.dart';
import '../../../../utils/time_utils.dart';
import '../../../../widgets/common/relative_time_text.dart';
import '../../../../widgets/layout/master_detail_layout.dart';
import '../../../../services/toast_service.dart';

part 'metaverse_page_components.dart';
part 'metaverse_form_component.dart';
part 'metaverse_tile_grid.dart';
part 'metaverse_grid_page.dart';
part 'metaverse_content_components.dart';
part 'metaverse_timeline_page.dart';

/// rfw 里宿主组件库的名字：插件界面描述用 `import fluxdo;` 引入。
const metaverseWidgetLibraryName = LibraryName(<String>['fluxdo']);

/// 插件自己的界面库。
const metaversePluginLibraryName = LibraryName(<String>['main']);

/// 从 rfw 自带组件里放行的部分：只有布局、文本和手势。
///
/// 刻意不放行的：`Image`（任意地址的网络图片，绕过网络白名单）、
/// `Container`（装饰里同样能挂网络图片）和整个 Material 组件库（样式不跟随
/// 应用主题，`DrawerHeader` 也带装饰图）。它们由下面的宿主组件替代。
const _allowedCoreWidgets = {
  'Align',
  'AspectRatio',
  'Center',
  'ClipRRect',
  'ColoredBox',
  'Column',
  'DefaultTextStyle',
  'Directionality',
  'Expanded',
  'Flexible',
  'FittedBox',
  'FractionallySizedBox',
  'GestureDetector',
  'GridView',
  'IntrinsicHeight',
  'IntrinsicWidth',
  'ListBody',
  'ListView',
  'Opacity',
  'Padding',
  'Positioned',
  'Rotation',
  'Row',
  'SafeArea',
  'Scale',
  'SingleChildScrollView',
  'SizedBox',
  'SizedBoxExpand',
  'SizedBoxShrink',
  'Spacer',
  'Stack',
  'Text',
  'Wrap',
};

/// 构建某个插件可用的宿主组件库。
///
/// 图片由宿主按清单权限获取，脚本不能读取图片响应。
LocalWidgetLibrary createMetaverseWidgetLibrary({
  required Future<Uint8List> Function(Uri) loadImage,
  Future<Uint8List> Function(Uri)? reloadImage,
}) {
  final core = createCoreWidgets().widgets;
  return LocalWidgetLibrary({
    for (final name in _allowedCoreWidgets) name: core[name]!,
    ..._hostWidgets(loadImage, reloadImage),
  });
}

/// 开发文档守卫由生产注册表推导组件集合。
Set<String> get metaverseHostWidgetNames =>
    _hostWidgets((_) async => Uint8List(0)).keys.toSet();

/// 可在界面描述里按名字引用的图标（`Symbol(name: "wallet")`）。
const metaverseIcons = <String, IconData>{
  'add': Symbols.add_rounded,
  'arrow_forward': Symbols.arrow_forward_rounded,
  'bolt': Symbols.bolt_rounded,
  'bookmark': Symbols.bookmark_rounded,
  'calendar': Symbols.calendar_today_rounded,
  'chart': Symbols.bar_chart_rounded,
  'check': Symbols.check_rounded,
  'check_circle': Symbols.check_circle_rounded,
  'chevron_right': Symbols.chevron_right_rounded,
  'close': Symbols.close_rounded,
  'cloud': Symbols.cloud_rounded,
  'code': Symbols.code_rounded,
  'copy': Symbols.content_copy_rounded,
  'credit_card': Symbols.credit_card_rounded,
  'delete': Symbols.delete_rounded,
  'download': Symbols.download_rounded,
  'done_all': Symbols.done_all_rounded,
  'edit': Symbols.edit_rounded,
  'error': Symbols.error_rounded,
  'extension': Symbols.extension_rounded,
  'favorite': Symbols.favorite_rounded,
  'flag': Symbols.flag_rounded,
  'gift': Symbols.redeem_rounded,
  'group': Symbols.group_rounded,
  'history': Symbols.history_rounded,
  'home': Symbols.home_rounded,
  'hub': Symbols.hub_rounded,
  'image': Symbols.image_rounded,
  'info': Symbols.info_rounded,
  'key': Symbols.key_rounded,
  'link': Symbols.link_rounded,
  'lock': Symbols.lock_rounded,
  'mail': Symbols.mail_rounded,
  'notifications': Symbols.notifications_rounded,
  'open_in_new': Symbols.open_in_new_rounded,
  'payments': Symbols.payments_rounded,
  'person': Symbols.person_rounded,
  'public': Symbols.public_rounded,
  'refresh': Symbols.refresh_rounded,
  'schedule': Symbols.schedule_rounded,
  'search': Symbols.search_rounded,
  'settings': Symbols.settings_rounded,
  'share': Symbols.share_rounded,
  'shopping_cart': Symbols.shopping_cart_rounded,
  'star': Symbols.star_rounded,
  'storefront': Symbols.storefront_rounded,
  'sync': Symbols.sync_rounded,
  'tag': Symbols.tag_rounded,
  'thumb_up': Symbols.thumb_up_rounded,
  'thumb_down': Symbols.thumb_down_rounded,
  'token': Symbols.token_rounded,
  'trending_up': Symbols.trending_up_rounded,
  'verified': Symbols.verified_rounded,
  'visibility': Symbols.visibility_rounded,
  'wallet': Symbols.wallet_rounded,
  'warning': Symbols.warning_rounded,
};

/// 清单声明的图标名 → 图标；未知名字退回通用插件图标。
IconData metaversePluginIcon(String? name) =>
    metaverseIcons[name] ?? Symbols.extension_rounded;

/// 颜色参数：主题色名（`"primary"`）或 0xAARRGGBB 整数。
Color? _color(BuildContext context, DataSource source, List<Object> key) {
  final token = source.v<String>(key);
  if (token == null) return ArgumentDecoders.color(source, key);
  final scheme = Theme.of(context).colorScheme;
  return switch (token) {
    'primary' => scheme.primary,
    'onPrimary' => scheme.onPrimary,
    'primaryContainer' => scheme.primaryContainer,
    'onPrimaryContainer' => scheme.onPrimaryContainer,
    'secondary' => scheme.secondary,
    'onSecondary' => scheme.onSecondary,
    'secondaryContainer' => scheme.secondaryContainer,
    'onSecondaryContainer' => scheme.onSecondaryContainer,
    'tertiary' => scheme.tertiary,
    'onTertiary' => scheme.onTertiary,
    'tertiaryContainer' => scheme.tertiaryContainer,
    'onTertiaryContainer' => scheme.onTertiaryContainer,
    'error' => scheme.error,
    'onError' => scheme.onError,
    'errorContainer' => scheme.errorContainer,
    'onErrorContainer' => scheme.onErrorContainer,
    'surface' => scheme.surface,
    'onSurface' => scheme.onSurface,
    'onSurfaceVariant' => scheme.onSurfaceVariant,
    'surfaceContainerLowest' => scheme.surfaceContainerLowest,
    'surfaceContainerLow' => scheme.surfaceContainerLow,
    'surfaceContainer' => scheme.surfaceContainer,
    'surfaceContainerHigh' => scheme.surfaceContainerHigh,
    'surfaceContainerHighest' => scheme.surfaceContainerHighest,
    'outline' => scheme.outline,
    'outlineVariant' => scheme.outlineVariant,
    _ => null,
  };
}

/// 数值参数：rfw 严格区分 `16` 与 `16.0`，宿主组件两种写法都接受。
double? _number(DataSource source, List<Object> key) =>
    source.v<double>(key) ?? source.v<int>(key)?.toDouble();

double _gridDimension(DataSource source, String name, double fallback) {
  final value = _number(source, [name]);
  return value != null && value.isFinite && value >= 0 ? value : fallback;
}

/// 文本参数：字符串，或若干片段的列表（拼接，便于混排数据引用）。
String _text(DataSource source, List<Object> key) {
  final text = source.v<String>(key);
  if (text != null) return text;
  final buffer = StringBuffer();
  final count = source.length(key);
  for (var index = 0; index < count; index++) {
    final part =
        source.v<String>([...key, index]) ??
        source.v<int>([...key, index])?.toString() ??
        source.v<double>([...key, index])?.toString() ??
        '';
    buffer.write(part);
  }
  return buffer.toString();
}

TextStyle? _textStyle(BuildContext context, String? name) {
  final theme = Theme.of(context).textTheme;
  return switch (name) {
    'displaySmall' => theme.displaySmall,
    'headlineLarge' => theme.headlineLarge,
    'headlineMedium' => theme.headlineMedium,
    'headlineSmall' => theme.headlineSmall,
    'titleLarge' => theme.titleLarge,
    'titleMedium' => theme.titleMedium,
    'titleSmall' => theme.titleSmall,
    'bodyLarge' => theme.bodyLarge,
    'bodySmall' => theme.bodySmall,
    'labelLarge' => theme.labelLarge,
    'labelMedium' => theme.labelMedium,
    'labelSmall' => theme.labelSmall,
    _ => theme.bodyMedium,
  };
}

Widget? _icon(BuildContext context, DataSource source, List<Object> key) {
  final icon = metaverseIcons[source.v<String>(key)];
  return icon == null ? null : Icon(icon);
}

Map<String, LocalWidgetBuilder> _hostWidgets(
  Future<Uint8List> Function(Uri) loadImage, [
  Future<Uint8List> Function(Uri)? reloadImage,
]) => {
  ..._pageWidgets(),
  'GridPage': _buildGridPage,
  'Statistics': _buildStatistics,
  'Amount': _buildAmount,
  'QuantityInput': _buildQuantityInput,
  'CopyButton': (context, source) {
    final text = _text(source, ['text']);
    return TextButton.icon(
      onPressed: text.isEmpty ? null : () async {
        await Clipboard.setData(ClipboardData(text: text));
        if (context.mounted) ToastService.showSuccess(context.l10n.common_copiedToClipboard);
      },
      icon: const Icon(Symbols.content_copy_rounded, size: 18),
      label: Text(source.v<String>(['label']) ?? context.l10n.common_copy),
    );
  },
  'Markdown': (context, source) => _PluginMarkdown(
    text: _text(source, ['text']),
    loadImage: loadImage,
    reloadImage: reloadImage,
    onLink: source.handler(['onLink'], (trigger) => (String url) => trigger({'url': url})),
  ),
  'AdaptivePane': (context, source) {
    final masterWidth = _gridDimension(source, 'masterWidth', 260).clamp(160.0, 500.0).toDouble();
    final detailWidth = _gridDimension(source, 'minDetailWidth', 440).clamp(240.0, 800.0).toDouble();
    final sidebar = source.child(['sidebar']);
    final compact = source.optionalChild(['compactHeader']);
    final body = source.child(['body']);
    return LayoutBuilder(builder: (context, constraints) {
    if (constraints.hasBoundedHeight && constraints.maxWidth >= masterWidth + detailWidth &&
        MasterDetailLayout.canShowBothPanesFor(context, masterWidth: masterWidth, minDetailWidth: detailWidth)) {
      return MasterDetailLayout(masterWidth: masterWidth, minDetailWidth: detailWidth,
        master: PrimaryScrollController.none(child: sidebar), detail: body);
    }
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [?compact, constraints.hasBoundedHeight ? Expanded(child: body) : body]);
    });
  },
  'ContentRow': (context, source) {
    final theme = Theme.of(context);
    final meta = _text(source, ['meta']);
    final summary = _text(source, ['summary']);
    final leading = source.optionalChild(['leading']);
    final detail = source.optionalChild(['detail']);
    return InkWell(onTap: source.voidHandler(['onTap']), child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (leading != null) ...[leading, const SizedBox(width: 12)],
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (meta.isNotEmpty || detail != null) Padding(padding: const EdgeInsets.only(bottom: 4),
            child: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              if (meta.isNotEmpty) Text(meta, style: theme.textTheme.labelMedium?.copyWith(color: context.emphasis.accent)), ?detail,
            ])),
          Text(_text(source, ['title']), maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
          if (summary.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(summary,
            maxLines: (source.v<int>(['summaryLines']) ?? 2).clamp(1, 6), overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
        ])),
      ]),
    ));
  },
  'Avatar': (context, source) {
    final name = _text(source, ['label']).trim();
    final size = _gridDimension(source, 'size', 36).clamp(16.0, 96.0).toDouble();
    final fallback = CircleAvatar(radius: size / 2, child: ExcludeSemantics(child: name.isEmpty
        ? Icon(Symbols.person_rounded, size: size * .6)
        : Text(name.characters.first.toUpperCase(), style: Theme.of(context).textTheme.labelLarge)));
    final count = source.v<int>(['count']) ?? 0;
    final avatar = Semantics(label: name, image: true, child: ClipOval(child: _PluginImage(
      url: source.v<String>(['url']) ?? '', width: size, height: size, fit: BoxFit.cover,
      radius: BorderRadius.zero, load: loadImage, reload: reloadImage, fallback: fallback)));
    return count > 0 ? Badge.count(count: count, maxCount: 99, child: avatar) : avatar;
  },
  'RelativeTime': (context, source) => RelativeTimeText(
    dateTime: TimeUtils.parseUtcTime(source.v<String>(['value'])),
    style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
  'PageLayout': (context, source) => _PluginPageLayout(
    toolbar: source.optionalChild(['toolbar']),
    loading: source.v<bool>(['loading']) == true,
    onRefresh: source.voidHandler(['onRefresh']),
    onLoadMore: source.voidHandler(['onLoadMore']),
    hasMore: source.v<bool>(['hasMore']) == true,
    loadingMore: source.v<bool>(['loadingMore']) == true,
    loadMoreError: source.v<String>(['loadMoreError']) ?? '',
    footer: source.optionalChild(['footer']),
    children: source.childList(['children']),
  ),
  'Skeleton': (context, source) => Semantics(
    label: context.l10n.common_loading,
    child: ExcludeSemantics(child: IgnorePointer(child: TickerMode(
      enabled: !MediaQuery.disableAnimationsOf(context),
      child: Skeleton(child: source.child(['child'])),
    ))),
  ),
  'SkeletonBox': (context, source) => SkeletonBox(
    width: _number(source, ['width'])?.clamp(0.0, 2048.0),
    height: (_number(source, ['height']) ?? 16).clamp(0.0, 2048.0),
    borderRadius: (_number(source, ['radius']) ?? 4).clamp(0.0, 1024.0),
  ),
  'TileGrid': (context, source) => _PluginTileGrid(
    settings: (
      layout: ArgumentDecoders.enumValue(
        MetaverseTileGridLayout.values, source, ['layout'],
      ) ?? MetaverseTileGridLayout.natural,
      columns: source.v<int>(['columns']) ?? 0,
      minTileWidth: _gridDimension(source, 'minTileWidth', 0),
      spacing: _gridDimension(source, 'spacing', 12),
      runSpacing: _gridDimension(source, 'runSpacing', 12),
      direction: Directionality.of(context),
    ),
    children: source.childList(['children']),
  ),
  'Choice': (context, source) {
    final label = _text(source, ['label']);
    final selected = source.v<bool>(['selected']) == true;
    final select = source.voidHandler(['onSelected']);
    final leading = source.optionalChild(['leading']);
    if (source.v<String>(['layout']) != 'stacked') {
      return ChoiceChip(avatar: leading, label: Text(label), selected: selected,
        onSelected: select == null ? null : (_) => select());
    }
    final theme = Theme.of(context);
    final radius = context.shapes.borderRadius(14);
    return Semantics(button: true, selected: selected, child: Tooltip(message: label, child: Material(
      color: selected ? theme.colorScheme.secondaryContainer : Colors.transparent,
      borderRadius: radius,
      child: InkWell(borderRadius: radius, onTap: select, child: Container(
        width: 76, constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Column(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
          if (leading != null) ...[leading, const SizedBox(height: 4)],
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelMedium?.copyWith(
            color: selected ? theme.colorScheme.onSecondaryContainer : theme.colorScheme.onSurfaceVariant)),
        ]),
      )),
    )));
  },
  'EmptyState': (context, source) => AppEmptyState(
    icon:
        _icon(context, source, ['icon']) ??
        const Icon(Symbols.shopping_bag_rounded),
    title: _text(source, ['title']),
    message: source.v<String>(['message']),
    action: source.optionalChild(['action']),
  ),
  'SelectableLabel': (context, source) => SelectableText(
    _text(source, ['text']),
    style: Theme.of(context).textTheme.bodyMedium,
  ),
  // 跟随主题的文本：style 取主题文字样式名，color 取主题色名。
  'Label': (context, source) {
    final maxLines = source.v<int>(['maxLines']);
    return Text(
      _text(source, ['text']),
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
      textAlign: ArgumentDecoders.enumValue<TextAlign>(
        TextAlign.values,
        source,
        ['align'],
      ),
      style: _textStyle(context, source.v<String>(['style']))?.copyWith(
        color: _color(context, source, ['color']),
        fontWeight: source.v<bool>(['bold']) == true ? FontWeight.w600 : null,
      ),
    );
  },

  // 跟随主题圆角的色块容器，可点击。
  'Surface': (context, source) {
    final shape = RoundedSuperellipseBorder(
      borderRadius: context.shapes.borderRadius(
        _number(source, ['radius']) ?? 16,
      ),
    );
    final onTap = source.voidHandler(['onTap']);
    final content = Padding(
      padding:
          ArgumentDecoders.edgeInsets(source, ['padding']) ??
          const EdgeInsets.all(16),
      child: source.optionalChild(['child']),
    );
    return Material(
      color:
          _color(context, source, ['color']) ??
          PageBackgroundScope.contentColor(
            context,
            Theme.of(context).colorScheme.surfaceContainerLow,
          ),
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: onTap == null
          ? content
          : InkWell(onTap: onTap, customBorder: shape, child: content),
    );
  },

  'Button': (context, source) {
    final loading = source.v<bool>(['loading']) == true;
    final onPressed = loading || source.v<bool>(['enabled']) == false
        ? null
        : source.voidHandler(['onPressed']);
    final label = Text(_text(source, ['label']));
    final icon = loading
        ? const LoadingSpinner(size: 16)
        : _icon(context, source, ['icon']);
    final button = switch (source.v<String>(['variant'])) {
      'tonal' => FilledButton.tonalIcon(
        onPressed: onPressed,
        icon: icon,
        label: label,
      ),
      'outlined' => OutlinedButton.icon(
        onPressed: onPressed,
        icon: icon,
        label: label,
      ),
      'text' => TextButton.icon(onPressed: onPressed, icon: icon, label: label),
      _ => FilledButton.icon(onPressed: onPressed, icon: icon, label: label),
    };
    return source.v<bool>(['fullWidth']) == true
        ? SizedBox(width: double.infinity, child: button)
        : button;
  },

  'IconButton': (context, source) {
    final loading = source.v<bool>(['loading']) == true;
    final icon = metaversePluginIcon(source.v<String>(['icon']));
    final child = source.optionalChild(['child']);
    return IconButton(
      onPressed: source.v<bool>(['enabled']) == false || loading
          ? null : source.voidHandler(['onPressed']),
      tooltip: source.v<String>(['tooltip']),
      isSelected: source.v<bool>(['selected']),
      selectedIcon: loading ? const LoadingSpinner(size: 20) : child ?? Icon(icon, fill: 1),
      icon: loading ? const LoadingSpinner(size: 20) : child ?? Icon(icon),
    );
  },

  'Symbol': (context, source) => Icon(
    metaverseIcons[source.v<String>(['name'])] ?? Symbols.extension_rounded,
    size: _number(source, ['size']),
    color: _color(context, source, ['color']),
  ),

  'Image': (context, source) => _PluginImage(
    preview: source.v<bool>(['preview']) == true,
    url: source.v<String>(['url']) ?? '',
    width: _number(source, ['width']),
    height: _number(source, ['height']),
    fit:
        ArgumentDecoders.enumValue<BoxFit>(BoxFit.values, source, ['fit']) ??
        BoxFit.cover,
    radius: context.shapes.borderRadius(_number(source, ['radius']) ?? 0),
    load: loadImage,
    reload: reloadImage,
  ),

  'ListItem': (context, source) {
    final subtitle = _text(source, ['subtitle']);
    return ListTile(
      title: Text(_text(source, ['title'])),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      leading: source.optionalChild(['leading']),
      trailing: source.optionalChild(['trailing']),
      onTap: source.voidHandler(['onTap']),
    );
  },

  'Divider': (context, source) => const Divider(height: 1),

  'Spinner': (context, source) =>
      LoadingSpinner(size: _number(source, ['size']) ?? 32),

  'ProgressBar': (context, source) => LinearProgressIndicator(
    value: _number(source, ['value'])?.clamp(0, 1).toDouble(),
    borderRadius: context.shapes.borderRadius(4),
  ),

  'Chip': (context, source) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: _color(context, source, ['color']) ?? scheme.secondaryContainer,
        shape: const StadiumBorder(),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(
          _text(source, ['label']),
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color:
                _color(context, source, ['textColor']) ??
                scheme.onSecondaryContainer,
          ),
        ),
      ),
    );
  },

  'Gap': (context, source) =>
      SizedBox.square(dimension: _number(source, ['size']) ?? 8),

  // 开关：onChanged 事件带 { value: bool }。
  'Toggle': (context, source) => M3eSwitch(
    value: source.v<bool>(['value']) ?? false,
    onChanged: source.handler(
      ['onChanged'],
      (HandlerTrigger trigger) =>
          (bool value) => trigger({'value': value}),
    ),
  ),

  // 输入框：onChanged / onSubmitted 事件带 { value: String }。
  'SearchInput': (context, source) => _PluginTextInput(
    search: true,
    value: source.v<String>(['value']) ?? '',
    label: null,
    hint: source.v<String>(['hint']),
    obscure: false,
    maxLines: 1,
    onChanged: source.handler(
      ['onChanged'],
      (HandlerTrigger trigger) =>
          (String value) => trigger({'value': value}),
    ),
    onSubmitted: source.handler(
      ['onSubmitted'],
      (HandlerTrigger trigger) =>
          (String value) => trigger({'value': value}),
    ),
  ),
  'TextInput': (context, source) => _PluginTextInput(
    value: source.v<String>(['value']) ?? '',
    label: source.v<String>(['label']),
    hint: source.v<String>(['hint']),
    obscure: source.v<bool>(['obscure']) == true,
    maxLines: source.v<int>(['maxLines']) ?? 1,
    minLines: source.v<int>(['minLines']),
    maxLength: source.v<int>(['maxLength']),
    filled: source.v<String>(['variant']) == 'filled',
    enabled: source.v<bool>(['enabled']) ?? true,
    readOnly: source.v<bool>(['readOnly']) ?? false,
    showCounter: source.v<bool>(['showCounter']) ?? true,
    onChanged: source.handler(
      ['onChanged'],
      (HandlerTrigger trigger) =>
          (String value) => trigger({'value': value}),
    ),
    onSubmitted: source.handler(
      ['onSubmitted'],
      (HandlerTrigger trigger) =>
          (String value) => trigger({'value': value}),
    ),
  ),
};

class _PluginPageLayout extends StatefulWidget {
  const _PluginPageLayout({
    required this.children,
    this.toolbar,
    this.footer,
    this.onRefresh,
    required this.loading,
    this.lazy = false,
    this.slivers,
    this.itemCount,
    this.onLoadMore,
    this.hasMore = false,
    this.loadingMore = false,
    this.loadMoreError = '',
    this.body,
  });
  final List<Widget> children;
  final Widget? toolbar;
  final Widget? footer;
  final VoidCallback? onRefresh;
  final bool loading;
  final bool lazy;
  final List<Widget>? slivers;
  final int? itemCount;
  int get paginationCount => itemCount ?? children.length;
  final VoidCallback? onLoadMore;
  final bool hasMore;
  final bool loadingMore;
  final String loadMoreError;
  final Widget? body;
  @override
  State<_PluginPageLayout> createState() => _PluginPageLayoutState();
}

class _PluginPageLayoutState extends State<_PluginPageLayout> {
  Completer<void>? _refresh;
  bool _moreRequested = false;

  bool _onScroll(ScrollNotification notification) {
    final delta = switch (notification) {
      ScrollUpdateNotification() => notification.scrollDelta ?? 0,
      OverscrollNotification() => notification.overscroll,
      _ => 0.0,
    };
    if (notification.depth != 0 ||
        notification.metrics.axis != Axis.vertical ||
        delta <= 0) {
      return false;
    }
    if (notification.metrics.extentAfter < 240 &&
        widget.hasMore &&
        !widget.loading &&
        !widget.loadingMore &&
        widget.loadMoreError.isEmpty &&
        !_moreRequested &&
        widget.onLoadMore != null) {
      _moreRequested = true;
      widget.onLoadMore!();
    }
    return false;
  }
  @override
  void didUpdateWidget(_PluginPageLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 本地缓存分页可在一帧内追加结果，不一定经过可见的 loadingMore 状态。
    if (widget.paginationCount != oldWidget.paginationCount ||
        (oldWidget.loading && !widget.loading) ||
        (oldWidget.loadingMore && !widget.loadingMore) ||
        !widget.hasMore ||
        widget.loadMoreError.isNotEmpty) {
      _moreRequested = false;
    }
    if (!widget.loading) {
      _refresh?.complete();
      _refresh = null;
    }
  }

  @override
  void dispose() {
    _refresh?.complete();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final bottomInset = MediaQuery.paddingOf(context).bottom;
      final scrollPadding = EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomInset);
      final content = Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Padding(
            padding: scrollPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: widget.children,
            ),
          ),
        ),
      );
      if (!constraints.hasBoundedHeight && widget.slivers == null) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [?widget.toolbar, content, ?widget.footer],
        );
      }
      Widget scroll = SingleChildScrollView(
        controller: PrimaryScrollController.maybeOf(context),
        physics: const AlwaysScrollableScrollPhysics(),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: content,
      );
      if (widget.lazy) {
        scroll = Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: ListView.builder(
              controller: PrimaryScrollController.maybeOf(context),
              padding: scrollPadding,
              physics: const AlwaysScrollableScrollPhysics(),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              itemCount: widget.children.length,
              itemBuilder: (_, index) => widget.children[index],
            ),
          ),
        );
      }
      if (widget.slivers != null) {
        scroll = Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: CustomScrollView(
              shrinkWrap: !constraints.hasBoundedHeight,
              primary: false,
              controller: constraints.hasBoundedHeight ? PrimaryScrollController.maybeOf(context) : null,
              physics: constraints.hasBoundedHeight
                  ? const AlwaysScrollableScrollPhysics()
                  : const NeverScrollableScrollPhysics(),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [SliverPadding(
                padding: scrollPadding,
                sliver: SliverMainAxisGroup(slivers: widget.slivers!),
              )],
            ),
          ),
        );
      }
      if (!constraints.hasBoundedHeight) {
        return Column(mainAxisSize: MainAxisSize.min, children: [?widget.toolbar, scroll, ?widget.footer]);
      }
      if (widget.body != null) scroll = widget.body!;
      if (widget.onRefresh != null) {
        scroll = M3eRefreshIndicator(
          onRefresh: () {
            if (_refresh != null) return _refresh!.future;
            final pending = _refresh = Completer<void>();
            widget.onRefresh!();
            return pending.future;
          },
          child: scroll,
        );
      }
      scroll = NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: scroll,
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.toolbar != null)
            PageBackdrop(child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: constraints.maxHeight * .45),
              child: SingleChildScrollView(primary: false, child: Center(child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 8), child: widget.toolbar),
              ))),
            )),
          Expanded(child: scroll),
          if (widget.footer != null)
            PageBackdrop(
              child: _PluginOptionalPadding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + bottomInset),
                child: Center(heightFactor: 1, child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 928),
                  child: SizedBox(width: double.infinity, child: widget.footer),
                )),
              ),
            ),
        ],
      );
    },
  );
}

/// 声明式插槽可能在运行时变成空组件，不能为它保留操作栏或标题间距。
class _PluginOptionalPadding extends SingleChildRenderObjectWidget {
  const _PluginOptionalPadding({required this.padding, super.child});
  final EdgeInsets padding;
  @override
  RenderObject createRenderObject(BuildContext context) => _OptionalPaddingRender(padding);
  @override
  void updateRenderObject(BuildContext context, _OptionalPaddingRender renderObject) {
    renderObject.padding = padding;
  }
}

class _OptionalPaddingRender extends RenderShiftedBox {
  _OptionalPaddingRender(this._padding) : super(null);
  EdgeInsets _padding;
  set padding(EdgeInsets value) {
    if (_padding == value) return;
    _padding = value;
    markNeedsLayout();
  }
  Size _size(BoxConstraints constraints, Size childSize) => constraints.constrain(
    Size(childSize.width + _padding.horizontal,
      childSize.height == 0 ? 0 : childSize.height + _padding.vertical),
  );
  @override
  Size computeDryLayout(BoxConstraints constraints) => _size(constraints,
    child?.getDryLayout(constraints.deflate(_padding)) ?? Size.zero);
  @override
  void performLayout() {
    child?.layout(constraints.deflate(_padding), parentUsesSize: true);
    size = _size(constraints, child?.size ?? Size.zero);
    if (child != null) {
      (child!.parentData! as BoxParentData).offset = Offset(_padding.left, _padding.top);
    }
  }
}

class _PluginImage extends StatefulWidget {
  const _PluginImage({
    required this.url,
    required this.width,
    required this.height,
    required this.fit,
    required this.radius,
    required this.load,
    this.reload,
    this.fallback,
    this.preview = false,
  });
  final Widget? fallback;
  final bool preview;
  final String url;
  final double? width, height;
  final BoxFit fit;
  final BorderRadius radius;
  final Future<Uint8List> Function(Uri) load;
  final Future<Uint8List> Function(Uri)? reload;
  @override
  State<_PluginImage> createState() => _PluginImageState();
}

class _PluginImageState extends State<_PluginImage> {
  Future<Uint8List>? _request;
  ScalableImage? _svg;
  bool _previewOpen = false;

  Future<void> _openPreview() async {
    if (_previewOpen) return;
    var request = _request;
    if (request == null) return;
    final uri = Uri.parse(widget.url);
    final reload = widget.reload ?? widget.load;
    _previewOpen = true;
    try {
      await ImageViewerPage.openWithLoader(
        context,
        loadImage: () {
          // 首次查看共享已经发出的请求，重试仍须经过原来的权限和网络出口。
          final initial = request;
          request = null;
          return initial ?? reload(uri);
        },
      );
    } finally {
      _previewOpen = false;
    }
  }

  void _update({bool retry = false}) {
    _svg = null;
    final uri = Uri.tryParse(widget.url);
    _request = uri != null && (uri.scheme == 'https' || uri.scheme == 'http')
        ? (retry ? widget.reload ?? widget.load : widget.load)(uri)
        : null;
  }

  @override
  void initState() {
    super.initState();
    _update();
  }

  @override
  void didUpdateWidget(_PluginImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.load != widget.load) _update();
  }

  @override
  Widget build(BuildContext context) {
    final placeholder = widget.fallback ?? ImagePlaceholder(loading: _request != null);
    final retry = widget.fallback ?? ImagePlaceholder(onRetry: () => setState(() => _update(retry: true)));
    final image = ClipRRect(
      borderRadius: widget.radius,
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: FutureBuilder<Uint8List>(
          future: _request,
          builder: (_, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return placeholder;
            }
            if (snapshot.hasError) return retry;
            final bytes = snapshot.data;
            if (bytes == null) return placeholder;
            if (SvgUtils.isSvgBytes(bytes)) {
              try {
                // 复用应用的静态 SVG 渲染器，外链子资源不会自行发起网络请求。
                _svg ??= ScalableImage.fromSvgString(
                  SvgUtils.decodeSvgBytes(bytes),
                  warnF: (_) {},
                );
                return ScalableImageWidget(si: _svg!, fit: widget.fit);
              } catch (_) {
                return retry;
              }
            }
            return Image(
              image: ResizeImage(
                MemoryImage(bytes),
                width: 1024,
                height: 1024,
                policy: ResizeImagePolicy.fit,
              ),
              fit: widget.fit,
              frameBuilder: (_, child, frame, loaded) =>
                  loaded || frame != null ? child : placeholder,
              errorBuilder: (_, _, _) => retry,
            );
          },
        ),
      ),
    );
    if (!widget.preview || _request == null) return image;
    return Semantics(
      button: true,
      label: context.l10n.metaverse_imagePreview,
      child: GestureDetector(onTap: _openPreview, child: image),
    );
  }
}

class _PluginTextInput extends StatefulWidget {
  const _PluginTextInput({
    this.search = false,
    required this.value,
    required this.label,
    required this.hint,
    required this.obscure,
    required this.maxLines,
    required this.onChanged,
    required this.onSubmitted,
    this.minLines,
    this.maxLength,
    this.filled = false,
    this.enabled = true,
    this.readOnly = false,
    this.showCounter = true,
  });

  final String value;
  final bool search;
  final String? label;
  final String? hint;
  final bool obscure;
  final int maxLines;
  final int? minLines;
  final int? maxLength;
  final bool filled;
  final bool enabled;
  final bool readOnly;
  final bool showCounter;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<_PluginTextInput> createState() => _PluginTextInputState();
}

class _PluginTextInputState extends State<_PluginTextInput> {
  late final _controller = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(_PluginTextInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 只在脚本主动改了 value 时同步，避免把用户正在输入的内容和光标冲掉。
    if (widget.value != oldWidget.value && widget.value != _controller.text) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.search) {
      return InputFieldShell(child: TextField(
        controller: _controller,
        textInputAction: TextInputAction.search,
        textAlignVertical: TextAlignVertical.center,
        style: Theme.of(context).textTheme.bodyLarge,
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          hintText: widget.hint,
          prefixIcon: IconButton(
          icon: const Icon(Symbols.search_rounded),
          tooltip: widget.hint,
          onPressed: () => _submitSearch(_controller.text),
        ),
          suffixIcon: _controller.text.isEmpty ? null : IconButton(
            tooltip: context.l10n.common_clear,
            icon: const Icon(Symbols.close_rounded),
            onPressed: () {
              setState(_controller.clear);
              widget.onChanged?.call('');
              _submitSearch('');
            },
          ),
        ),
        onChanged: (value) {
          setState(() {});
          widget.onChanged?.call(value);
        },
        onSubmitted: _submitSearch,
      ));
    }
    final maxLines = widget.obscure ? 1 : widget.maxLines.clamp(1, 20);
    final field = TextField(
      controller: _controller,
      obscureText: widget.obscure,
      enabled: widget.enabled,
      readOnly: widget.readOnly,
      minLines: widget.minLines?.clamp(1, maxLines),
      maxLines: maxLines,
      maxLength: widget.maxLength?.clamp(1, 10000),
      textAlignVertical: TextAlignVertical.center,
      style: Theme.of(context).textTheme.bodyLarge,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        counterText: widget.showCounter ? null : '',
        isDense: widget.filled,
        contentPadding: widget.filled
            ? const EdgeInsets.symmetric(horizontal: 16, vertical: 12)
            : null,
        visualDensity: widget.filled ? VisualDensity.standard : null,
      ),
    );
    return widget.filled ? InputFieldShell(child: field) : field;
  }

  void _submitSearch(String value) {
    FocusScope.of(context).unfocus();
    widget.onSubmitted?.call(value);
  }
}
