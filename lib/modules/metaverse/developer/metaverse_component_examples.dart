import '../../../l10n/s.dart';

/// 参数直接绑定到生产组件库的数据树，预览与插件使用同一份实现。
class MetaverseComponentExample {
  const MetaverseComponentExample(
    this.name,
    this.source,
    this.parameters, {
    this.previewHeight = 200,
  });
  final String name;
  final String source;
  final Map<String, Object> parameters;
  final double previewHeight;
}

List<MetaverseComponentExample> metaverseComponentExamples(AppLocalizations l) {
  final text = l.metaverse_developerExample;
  final label = {'label': text};
  final title = {'title': text, 'message': l.metaverse_developerPreview};
  return [
    MetaverseComponentExample(
      'PageLayout',
      'PageLayout(loading: data.loading, onRefresh: event "refresh" {}, children: [Label(text: data.title), Gap(), Button(label: data.message, onPressed: event "action" {})], footer: Button(label: data.title, onPressed: event "footer" {}))',
      {...title, 'loading': false},
      previewHeight: 360,
    ),
    MetaverseComponentExample(
      'ListPage',
      'ListPage(loading: data.loading, hasMore: data.hasMore, onRefresh: event "refresh" {}, onLoadMore: event "loadMore" {}, search: SearchInput(value: data.value, hint: data.title, onChanged: event "change" {}), items: [ListItem(title: data.title, subtitle: data.message, onTap: event "open" {id: "one"}), ListItem(title: data.message, onTap: event "open" {id: "two"})])',
      {...title, 'loading': false, 'hasMore': true, 'value': ''},
      previewHeight: 400,
    ),
    MetaverseComponentExample(
      'DetailPage',
      'DetailPage(loading: data.loading, onRefresh: event "refresh" {}, header: Label(text: data.title, style: "headlineSmall"), sections: [Surface(child: SelectableLabel(text: data.message))], actions: ActionBar(actions: [Button(label: data.title, onPressed: event "action" {})]))',
      {...title, 'loading': false},
      previewHeight: 360,
    ),
    MetaverseComponentExample(
      'FormPage',
      'FormPage(loading: data.loading, fields: [{name: "name", label: data.title, required: true, maxLength: 40}, {name: "notes", label: data.message, type: "multiline"}, {name: "enabled", label: data.title, type: "toggle", value: true}], onChanged: event "formChanged" {}, onSubmit: event "submit" {})',
      {...title, 'loading': false},
      previewHeight: 440,
    ),
    MetaverseComponentExample(
      'ActionBar',
      'ActionBar(actions: [Button(label: data.secondary, variant: "text", onPressed: event "secondary" {}), Button(label: data.label, loading: data.loading, onPressed: event "primary" {})])',
      {...label, 'secondary': l.common_cancel, 'loading': false},
    ),
    MetaverseComponentExample(
      'TileGrid',
      'TileGrid(children: [Surface(child: Label(text: data.label)), Surface(child: Label(text: data.label)), Surface(child: Label(text: data.label))])',
      label,
    ),
    MetaverseComponentExample(
      'Choice',
      'Choice(label: data.label, selected: data.selected, onSelected: event "select" {})',
      {...label, 'selected': false},
    ),
    MetaverseComponentExample(
      'EmptyState',
      'EmptyState(title: data.title, message: data.message, icon: "cloud", action: Button(label: data.title, onPressed: event "retry" {}))',
      title,
    ),
    MetaverseComponentExample(
      'SelectableLabel',
      'SelectableLabel(text: data.text)',
      {'text': text},
    ),
    MetaverseComponentExample(
      'Label',
      'Label(text: data.text, style: data.style, color: "onSurface", bold: data.bold, maxLines: 3)',
      {'text': text, 'style': 'titleMedium', 'bold': false},
    ),
    MetaverseComponentExample(
      'Surface',
      'Surface(radius: data.radius, padding: [16.0], child: Label(text: data.label), onTap: event "tap" {})',
      {...label, 'radius': 16.0},
    ),
    MetaverseComponentExample(
      'Button',
      'Button(label: data.label, icon: "check", variant: data.variant, enabled: data.enabled, loading: data.loading, onPressed: event "press" {})',
      {...label, 'variant': 'filled', 'enabled': true, 'loading': false},
    ),
    MetaverseComponentExample(
      'IconButton',
      'IconButton(icon: data.icon, tooltip: data.label, onPressed: event "press" {})',
      {...label, 'icon': 'favorite'},
    ),
    MetaverseComponentExample(
      'Symbol',
      'Symbol(name: data.name, size: data.size, color: "primary")',
      {'name': 'extension', 'size': 48.0},
    ),
    MetaverseComponentExample(
      'Image',
      'Image(url: "https://example.org/preview.png", height: data.height, width: data.width, radius: data.radius, fit: "contain")',
      {'height': 120.0, 'width': 120.0, 'radius': 16.0},
    ),
    MetaverseComponentExample(
      'ListItem',
      'ListItem(title: data.title, subtitle: data.message, leading: Symbol(name: "bookmark"), trailing: Symbol(name: "chevron_right"), onTap: event "tap" {})',
      title,
    ),
    const MetaverseComponentExample('Divider', 'Divider()', {}),
    const MetaverseComponentExample('Spinner', 'Spinner(size: data.size)', {
      'size': 32.0,
    }),
    const MetaverseComponentExample(
      'ProgressBar',
      'ProgressBar(value: data.value)',
      {'value': 0.6},
    ),
    MetaverseComponentExample(
      'Chip',
      'Chip(label: data.label, color: "secondaryContainer")',
      label,
    ),
    const MetaverseComponentExample(
      'Gap',
      'Column(children: [Label(text: "A"), Gap(size: data.size), Label(text: "B")])',
      {'size': 24.0},
    ),
    const MetaverseComponentExample(
      'Toggle',
      'Toggle(value: data.value, onChanged: event "change" {})',
      {'value': true},
    ),
    MetaverseComponentExample(
      'SearchInput',
      'SearchInput(value: data.value, hint: data.hint, onChanged: event "change" {}, onSubmitted: event "submit" {})',
      {'value': '', 'hint': l.metaverse_marketSearch},
    ),
    MetaverseComponentExample(
      'TextInput',
      'TextInput(value: data.value, label: data.label, obscure: data.obscure, maxLines: 1, onChanged: event "change" {}, onSubmitted: event "submit" {})',
      {...label, 'value': '', 'obscure': false},
    ),
  ];
}
