import 'package:flutter/painting.dart';

import '../../../l10n/s.dart';
import '../plugin/ui/metaverse_widget_library.dart'
    show MetaverseTileGridLayout;

/// 参数直接绑定到生产组件库的数据树，预览与插件使用同一份实现。
class MetaverseComponentExample {
  const MetaverseComponentExample(
    this.name,
    this.source,
    this.parameters, {
    required this.description,
    this.previewHeight = 200,
    this.options = const {},
  });
  final String name;
  final String description;
  final String source;
  final Map<String, Object> parameters;
  final double previewHeight;
  final Map<String, List<String>> options;
}

List<MetaverseComponentExample> metaverseComponentExamples(AppLocalizations l) {
  final text = l.metaverse_developerExample;
  final label = {'label': text};
  final title = {'title': text, 'message': l.metaverse_developerPreview};
  return [
    MetaverseComponentExample(
      'PageLayout',
      description: l.metaverse_componentPageLayout,
      'PageLayout(loading: data.loading, hasMore: data.hasMore, loadingMore: data.loadingMore, loadMoreError: data.loadMoreError, onLoadMore: event "loadMore" {}, onRefresh: event "refresh" {}, children: [Label(text: data.title), Gap(), Button(label: data.message, onPressed: event "action" {})], footer: Button(label: data.title, onPressed: event "footer" {}))',
      {
        ...title,
        'loading': false,
        'hasMore': true,
        'loadingMore': false,
        'loadMoreError': '',
      },
      previewHeight: 360,
    ),
    MetaverseComponentExample(
      'ListPage',
      description: l.metaverse_componentListPage,
      'ListPage(loading: data.loading, loadingMore: data.loadingMore, error: data.error, emptyTitle: data.emptyTitle, moreLabel: data.moreLabel, onRetry: event "retry" {}, hasMore: data.hasMore, onRefresh: event "refresh" {}, onLoadMore: event "loadMore" {}, search: SearchInput(value: data.value, hint: data.title, onChanged: event "change" {}), items: [ListItem(title: data.title, subtitle: data.message, onTap: event "open" {id: "one"}), ListItem(title: data.message, onTap: event "open" {id: "two"})])',
      {
        ...title,
        'loading': false,
        'loadingMore': false,
        'error': '',
        'emptyTitle': l.common_noData,
        'moreLabel': l.common_more,
        'hasMore': true,
        'value': '',
      },
      previewHeight: 400,
    ),
    MetaverseComponentExample(
      'DetailPage',
      description: l.metaverse_componentDetailPage,
      'DetailPage(loading: data.loading, error: data.error, emptyTitle: data.emptyTitle, onRetry: event "retry" {}, onRefresh: event "refresh" {}, header: Label(text: data.title, style: "headlineSmall"), sections: [Surface(child: SelectableLabel(text: data.message))], actions: ActionBar(actions: [Button(label: data.title, onPressed: event "action" {})]))',
      {...title, 'loading': false, 'error': '', 'emptyTitle': l.common_noData},
      previewHeight: 360,
    ),
    MetaverseComponentExample(
      'FormPage',
      description: l.metaverse_componentFormPage,
      'FormPage(loading: data.loading, submitLabel: data.submitLabel, resetKey: data.resetKey, fields: [{name: "name", label: data.title, required: true, maxLength: 40}, {name: "notes", label: data.message, type: "multiline"}, {name: "enabled", label: data.title, type: "toggle", value: true}], onChanged: event "formChanged" {}, onSubmit: event "submit" {})',
      {
        ...title,
        'loading': false,
        'submitLabel': l.metaverse_formSubmit,
        'resetKey': '',
      },
      previewHeight: 440,
    ),
    MetaverseComponentExample(
      'ActionBar',
      description: l.metaverse_componentActionBar,
      'ActionBar(actions: [Button(label: data.secondary, variant: "text", onPressed: event "secondary" {}), Button(label: data.label, loading: data.loading, onPressed: event "primary" {})])',
      {...label, 'secondary': l.common_cancel, 'loading': false},
    ),
    MetaverseComponentExample(
      'TileGrid',
      description: l.metaverse_componentTileGrid,
      'SingleChildScrollView(child: TileGrid(layout: data.layout, columns: data.columns, minTileWidth: data.minTileWidth, spacing: data.spacing, runSpacing: data.runSpacing, children: [Surface(color: "secondaryContainer", child: SizedBox(height: 48.0, child: Label(text: data.label))), Surface(color: "secondaryContainer", child: SizedBox(height: 96.0, child: Label(text: data.label))), Surface(color: "secondaryContainer", child: SizedBox(height: 64.0, child: Label(text: data.label))), Surface(color: "secondaryContainer", child: SizedBox(height: 40.0, child: Label(text: data.label)))]))',
      {
        ...label,
        'layout': 'natural',
        'columns': 2,
        'minTileWidth': 0.0,
        'spacing': 12.0,
        'runSpacing': 12.0,
      },
      options: {
        'layout': MetaverseTileGridLayout.values
            .map((value) => value.name)
            .toList(),
      },
      previewHeight: 400,
    ),
    MetaverseComponentExample(
      'Choice',
      description: l.metaverse_componentChoice,
      'Choice(label: data.label, selected: data.selected, onSelected: event "select" {})',
      {...label, 'selected': false},
    ),
    MetaverseComponentExample(
      'EmptyState',
      description: l.metaverse_componentEmptyState,
      'EmptyState(title: data.title, message: data.message, icon: data.icon, action: Button(label: data.title, onPressed: event "retry" {}))',
      {...title, 'icon': 'cloud'},
    ),
    MetaverseComponentExample(
      'SelectableLabel',
      description: l.metaverse_componentSelectableLabel,
      'SelectableLabel(text: data.text)',
      {'text': text},
    ),
    MetaverseComponentExample(
      'Label',
      description: l.metaverse_componentLabel,
      'Label(text: data.text, style: data.style, color: data.color, bold: data.bold, maxLines: data.maxLines, align: data.align)',
      {
        'text': text,
        'style': 'titleMedium',
        'color': 'onSurface',
        'bold': false,
        'maxLines': 3,
        'align': 'start',
      },
      options: {'align': TextAlign.values.map((value) => value.name).toList()},
    ),
    MetaverseComponentExample(
      'Surface',
      description: l.metaverse_componentSurface,
      'Surface(radius: data.radius, color: data.color, padding: [data.start, data.top, data.end, data.bottom], child: Label(text: data.label), onTap: event "tap" {})',
      {
        ...label,
        'radius': 16.0,
        'color': 'surfaceContainerLow',
        'start': 16.0,
        'top': 16.0,
        'end': 16.0,
        'bottom': 16.0,
      },
    ),
    MetaverseComponentExample(
      'Button',
      description: l.metaverse_componentButton,
      'Button(label: data.label, icon: data.icon, variant: data.variant, enabled: data.enabled, loading: data.loading, onPressed: event "press" {})',
      {
        ...label,
        'icon': 'check',
        'variant': 'filled',
        'enabled': true,
        'loading': false,
      },
      options: {
        'variant': ['filled', 'tonal', 'outlined', 'text'],
      },
    ),
    MetaverseComponentExample(
      'IconButton',
      description: l.metaverse_componentIconButton,
      'IconButton(icon: data.icon, tooltip: data.label, onPressed: event "press" {})',
      {...label, 'icon': 'favorite'},
    ),
    MetaverseComponentExample(
      'Symbol',
      description: l.metaverse_componentSymbol,
      'Symbol(name: data.name, size: data.size, color: data.color)',
      {'name': 'extension', 'size': 48.0, 'color': 'primary'},
    ),
    MetaverseComponentExample(
      'Image',
      description: l.metaverse_componentImage,
      'Image(url: data.url, height: data.height, width: data.width, radius: data.radius, fit: data.fit)',
      {
        'url': 'https://example.org/preview.png',
        'height': 120.0,
        'width': 120.0,
        'radius': 16.0,
        'fit': 'contain',
      },
      options: {'fit': BoxFit.values.map((value) => value.name).toList()},
    ),
    MetaverseComponentExample(
      'ListItem',
      description: l.metaverse_componentListItem,
      'ListItem(title: data.title, subtitle: data.message, leading: Symbol(name: "bookmark"), trailing: Symbol(name: "chevron_right"), onTap: event "tap" {})',
      title,
    ),
    MetaverseComponentExample(
      'Divider',
      'Divider()',
      {},
      description: l.metaverse_componentDivider,
    ),
    MetaverseComponentExample('Spinner', 'Spinner(size: data.size)', {
      'size': 32.0,
    }, description: l.metaverse_componentSpinner),
    MetaverseComponentExample(
      'ProgressBar',
      description: l.metaverse_componentProgressBar,
      'ProgressBar(value: data.value)',
      {'value': 0.6},
    ),
    MetaverseComponentExample(
      'Chip',
      description: l.metaverse_componentChip,
      'Chip(label: data.label, color: data.color, textColor: data.textColor)',
      {
        ...label,
        'color': 'secondaryContainer',
        'textColor': 'onSecondaryContainer',
      },
    ),
    MetaverseComponentExample(
      'Gap',
      description: l.metaverse_componentGap,
      'Column(children: [Label(text: "A"), Gap(size: data.size), Label(text: "B")])',
      {'size': 24.0},
    ),
    MetaverseComponentExample(
      'Toggle',
      description: l.metaverse_componentToggle,
      'Toggle(value: data.value, onChanged: event "change" {})',
      {'value': true},
    ),
    MetaverseComponentExample(
      'SearchInput',
      description: l.metaverse_componentSearchInput,
      'SearchInput(value: data.value, hint: data.hint, onChanged: event "change" {}, onSubmitted: event "submit" {})',
      {'value': '', 'hint': l.metaverse_marketSearch},
    ),
    MetaverseComponentExample(
      'TextInput',
      description: l.metaverse_componentTextInput,
      'TextInput(value: data.value, label: data.label, hint: data.hint, obscure: data.obscure, maxLines: data.maxLines, onChanged: event "change" {}, onSubmitted: event "submit" {})',
      {...label, 'value': '', 'hint': '', 'obscure': false, 'maxLines': 1},
    ),
  ];
}
