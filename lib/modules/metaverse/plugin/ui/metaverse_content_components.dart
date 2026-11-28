part of 'metaverse_widget_library.dart';

/// 数据由插件提供；窄屏和大字下自动换行，不要求插件计算像素宽度。
Widget _buildStatistics(BuildContext context, DataSource source) {
  final loading = source.v<bool>(['loading']) == true;
  final itemCount = source.length(['items']).clamp(0, 12);
  final count = loading && itemCount == 0 ? 4 : itemCount;
  // RFW 数据订阅必须在组件构建时建立，不能延迟到布局阶段。
  final items = [
    for (var i = 0; i < count; i++)
      (
        value: _text(source, ['items', i, 'value']),
        label: _text(source, ['items', i, 'label']),
      ),
  ];
  return LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.hasBoundedWidth ? constraints.maxWidth : 320.0;
      final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final capacity = math.max(
        1,
        math.min(count, ((width + 12) / (90 * textScale + 12)).floor()),
      );
      final rows = math.max(1, (count / capacity).ceil());
      final columns = math.max(1, (count / rows).ceil());
      final itemWidth = math.max(0.0, (width - 12 * (columns - 1)) / columns);
      final theme = Theme.of(context);
      final valueStyle = theme.textTheme.headlineSmall
          ?.copyWith(fontWeight: FontWeight.w600);
      final labelStyle = theme.textTheme.labelMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      );
      Widget placeholder(String text, TextStyle? style, double preferredWidth) {
        // 用真实字体和文字缩放测量行高，加载完成时保持相同的行距与布局。
        final painter = TextPainter(
          text: TextSpan(
            text: text.isEmpty ? '0' : text,
            style: DefaultTextStyle.of(context).style.merge(style),
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          locale: Localizations.maybeLocaleOf(context),
          textHeightBehavior: DefaultTextStyle.of(context).textHeightBehavior,
        )..layout(maxWidth: itemWidth);
        final height = painter.height;
        painter.dispose();
        return SkeletonBox(
          width: math.min(itemWidth, preferredWidth * textScale),
          height: height,
        );
      }
      final content = Wrap(
        spacing: 12,
        runSpacing: 16,
        children: [
          for (final item in items)
            SizedBox(
              width: itemWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (loading)
                    placeholder(item.value, valueStyle, 56)
                  else
                    Text(item.value, style: valueStyle),
                  const SizedBox(height: 4),
                  if (loading && item.label.isEmpty)
                    placeholder('', labelStyle, 72)
                  else
                    Text(item.label, style: labelStyle),
                ],
              ),
            ),
        ],
      );
      return loading
          ? Semantics(label: context.l10n.common_loadingData, liveRegion: true,
              child: ExcludeSemantics(child: MediaQuery.disableAnimationsOf(context)
                ? content : Skeleton(child: content)))
          : content;
    },
  );
}

Widget _buildAmount(BuildContext context, DataSource source) {
  final original = _text(source, ['original']);
  final unit = _text(source, ['unit']);
  final theme = Theme.of(context);
  return Wrap(
    spacing: 6,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text(
        _text(source, ['value']),
        style: _textStyle(context, source.v<String>(['style']) ?? 'titleLarge')
            ?.copyWith(
              color:
                  _color(context, source, ['color']) ?? context.emphasis.accent,
              fontWeight: FontWeight.w600,
            ),
      ),
      if (unit.isNotEmpty)
        Text(
          unit,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      if (original.isNotEmpty)
        Text(
          original,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            decoration: TextDecoration.lineThrough,
          ),
        ),
    ],
  );
}

Widget _buildQuantityInput(BuildContext context, DataSource source) {
  final min = source.v<int>(['min']) ?? 1;
  final max = math.max(min, source.v<int>(['max']) ?? 9999);
  final value = (source.v<int>(['value']) ?? min).clamp(min, max);
  final enabled = source.v<bool>(['enabled']) != false;
  final onChanged = source.handler(
    ['onChanged'],
    (trigger) =>
        (int next) => trigger({'value': next}),
  );
  return Material(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    borderRadius: context.shapes.borderRadius(12),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: context.l10n.metaverse_quantityDecrease,
          onPressed: enabled && onChanged != null && value > min
              ? () => onChanged(value - 1)
              : null,
          icon: const Icon(Symbols.remove_rounded, size: 18),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 32),
          child: Text(
            '$value',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        IconButton(
          tooltip: context.l10n.metaverse_quantityIncrease,
          onPressed: enabled && onChanged != null && value < max
              ? () => onChanged(value + 1)
              : null,
          icon: const Icon(Symbols.add_rounded, size: 18),
        ),
      ],
    ),
  );
}

/// 只接受 Markdown 文本。图片始终走插件的网络出口，链接只产生用户点击事件。
class _PluginMarkdown extends StatefulWidget {
  const _PluginMarkdown({
    required this.text,
    required this.loadImage,
    this.reloadImage,
    this.onLink,
  });
  final String text;
  final Future<Uint8List> Function(Uri) loadImage;
  final Future<Uint8List> Function(Uri)? reloadImage;
  final ValueChanged<String>? onLink;
  @override
  State<_PluginMarkdown> createState() => _PluginMarkdownState();
}

class _PluginMarkdownState extends State<_PluginMarkdown> {
  late String markup = _parse();
  String _parse() {
    // 不让原始 HTML 生成媒体、脚本或带站点语义的特殊节点。
    final document = md.Document(
      extensionSet: md.ExtensionSet.none,
      encodeHtml: true,
      withDefaultBlockSyntaxes: false,
      blockSyntaxes: const [
        md.EmptyBlockSyntax(),
        md.FencedCodeBlockSyntax(),
        md.SetextHeaderSyntax(),
        md.HeaderSyntax(),
        md.CodeBlockSyntax(),
        md.BlockquoteSyntax(),
        md.HorizontalRuleSyntax(),
        md.TableSyntax(),
        md.UnorderedListSyntax(),
        md.OrderedListSyntax(),
        md.LinkReferenceDefinitionSyntax(),
        md.ParagraphSyntax(),
      ],
      inlineSyntaxes: [
        md.StrikethroughSyntax(),
        md.AutolinkExtensionSyntax(),
        _PluginUnderlineSyntax(),
        _PluginLineBreakSyntax(),
      ],
    );
    final fragment = html.parseFragment(
      md.renderToHtml(
        document.parse(
          widget.text.substring(0, math.min(widget.text.length, 131072)),
        ),
      ),
    );
    for (final element in fragment.querySelectorAll('[src], [href]')) {
      for (final name in ['src', 'href']) {
        final raw = element.attributes[name];
        if (raw == null) continue;
        final uri = Uri.tryParse(raw);
        if (uri == null ||
            !['https', 'http'].contains(uri.scheme) ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty) {
          element.attributes.remove(name);
        }
      }
    }
    return fragment.outerHtml;
  }

  @override
  void didUpdateWidget(_PluginMarkdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) markup = _parse();
  }

  @override
  Widget build(BuildContext context) => content.FluxdoRender(
    cookedHtml: markup,
    trimTopMargin: true,
    trimBottomMargin: true,
    baseTextStyle: Theme.of(context).textTheme.bodyMedium
        ?.copyWith(height: 1.6),
    linkHandler: (_, url) => widget.onLink?.call(url),
    imageContentBuilder: (_, image, _) => ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 360),
      child: _PluginImage(
        url: image.src,
        width: double.infinity,
        height: 240,
        fit: BoxFit.contain,
        radius: context.shapes.borderRadius(12),
        load: widget.loadImage,
        reload: widget.reloadImage,
        preview: true,
      ),
    ),
  );
}

class _PluginUnderlineSyntax extends md.InlineSyntax {
  _PluginUnderlineSyntax() : super(r'\+\+([^\n+]+)\+\+');
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('u', match[1]!));
    return true;
  }
}

class _PluginLineBreakSyntax extends md.InlineSyntax {
  _PluginLineBreakSyntax() : super(r'\n');
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.empty('br'));
    return true;
  }
}
