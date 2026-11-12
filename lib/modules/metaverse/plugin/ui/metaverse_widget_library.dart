import 'dart:typed_data';
import 'dart:async';

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';
// rfw 的 Switch 是界面描述里的分支节点，与 Material 的开关组件重名。
import 'package:rfw/rfw.dart' hide Switch;

import '../../../../l10n/s.dart';

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
}) {
  final core = createCoreWidgets().widgets;
  return LocalWidgetLibrary({
    for (final name in _allowedCoreWidgets) name: core[name]!,
    ..._hostWidgets(loadImage),
  });
}

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
  'edit': Symbols.edit_rounded,
  'error': Symbols.error_rounded,
  'extension': Symbols.extension_rounded,
  'favorite': Symbols.favorite_rounded,
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
  Future<Uint8List> Function(Uri) loadImage,
) => {
  'PageLayout': (context, source) => _PluginPageLayout(
    loading: source.v<bool>(['loading']) == true,
    onRefresh: source.voidHandler(['onRefresh']),
    footer: source.optionalChild(['footer']),
    children: source.childList(['children']),
  ),
  'TileGrid': (context, source) {
    final children = source.childList(['children']);
    return LayoutBuilder(
      builder: (context, constraints) {
        final count = constraints.maxWidth >= 720
            ? 3
            : constraints.maxWidth >= 320
            ? 2
            : 1;
        final width = (constraints.maxWidth - (count - 1) * 12) / count;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final child in children) SizedBox(width: width, child: child),
          ],
        );
      },
    );
  },
  'Choice': (context, source) => ChoiceChip(
    label: Text(_text(source, ['label'])),
    selected: source.v<bool>(['selected']) == true,
    onSelected: (_) => source.voidHandler(['onSelected'])?.call(),
  ),
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
    return switch (source.v<String>(['variant'])) {
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
  },

  'IconButton': (context, source) => IconButton(
    onPressed: source.voidHandler(['onPressed']),
    tooltip: source.v<String>(['tooltip']),
    icon:
        _icon(context, source, ['icon']) ??
        const Icon(Symbols.extension_rounded),
  ),

  'Symbol': (context, source) => Icon(
    metaverseIcons[source.v<String>(['name'])] ?? Symbols.extension_rounded,
    size: _number(source, ['size']),
    color: _color(context, source, ['color']),
  ),

  'Image': (context, source) => _PluginImage(
    url: source.v<String>(['url']) ?? '',
    width: _number(source, ['width']),
    height: _number(source, ['height']),
    fit:
        ArgumentDecoders.enumValue<BoxFit>(BoxFit.values, source, ['fit']) ??
        BoxFit.cover,
    radius: context.shapes.borderRadius(_number(source, ['radius']) ?? 0),
    load: loadImage,
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
    this.footer,
    this.onRefresh,
    required this.loading,
  });
  final List<Widget> children;
  final Widget? footer;
  final VoidCallback? onRefresh;
  final bool loading;
  @override
  State<_PluginPageLayout> createState() => _PluginPageLayoutState();
}

class _PluginPageLayoutState extends State<_PluginPageLayout> {
  Completer<void>? _refresh;
  @override
  void didUpdateWidget(_PluginPageLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
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
      final content = Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: widget.children,
            ),
          ),
        ),
      );
      if (!constraints.hasBoundedHeight) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [content, ?widget.footer],
        );
      }
      Widget scroll = SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: content,
      );
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
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: scroll),
          if (widget.footer != null)
            PageBackdrop(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: widget.footer,
              ),
            ),
        ],
      );
    },
  );
}

class _PluginImage extends StatefulWidget {
  const _PluginImage({
    required this.url,
    required this.width,
    required this.height,
    required this.fit,
    required this.radius,
    required this.load,
  });
  final String url;
  final double? width, height;
  final BoxFit fit;
  final BorderRadius radius;
  final Future<Uint8List> Function(Uri) load;
  @override
  State<_PluginImage> createState() => _PluginImageState();
}

class _PluginImageState extends State<_PluginImage> {
  Future<Uint8List>? _request;
  void _update() {
    final uri = Uri.tryParse(widget.url);
    _request = uri?.scheme == 'https' ? widget.load(uri!) : null;
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
    final placeholder = Icon(
      Symbols.image_rounded,
      color: Theme.of(context).colorScheme.outline,
    );
    final retry = Center(
      child: IconButton(
        tooltip: context.l10n.common_retry,
        icon: const Icon(Symbols.refresh_rounded),
        color: Theme.of(context).colorScheme.outline,
        onPressed: () => setState(_update),
      ),
    );
    return ClipRRect(
      borderRadius: widget.radius,
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: FutureBuilder<Uint8List>(
          future: _request,
          builder: (_, snapshot) {
            if (snapshot.hasError) return retry;
            final bytes = snapshot.data;
            if (snapshot.connectionState != ConnectionState.done ||
                bytes == null) {
              return placeholder;
            }
            return Image(
              image: ResizeImage(
                MemoryImage(bytes),
                width: 1024,
                height: 1024,
                policy: ResizeImagePolicy.fit,
              ),
              fit: widget.fit,
              errorBuilder: (_, _, _) => retry,
            );
          },
        ),
      ),
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
  });

  final String value;
  final bool search;
  final String? label;
  final String? hint;
  final bool obscure;
  final int maxLines;
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
        decoration: InputDecoration(
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
    return TextField(
      controller: _controller,
      obscureText: widget.obscure,
      maxLines: widget.obscure ? 1 : widget.maxLines,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
      ),
    );
  }

  void _submitSearch(String value) {
    FocusScope.of(context).unfocus();
    widget.onSubmitted?.call(value);
  }
}
