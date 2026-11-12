import 'dart:convert';

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:rfw/formats.dart';
import 'package:rfw/rfw.dart';

import '../../../l10n/s.dart';
import '../../../services/toast_service.dart';
import '../../../utils/link_launcher.dart';
import '../plugin/runtime/flutter_js_script_engine.dart';
import '../plugin/ui/metaverse_widget_library.dart';
import 'metaverse_api_examples.dart';
import 'metaverse_component_examples.dart';

class MetaverseDeveloperPage extends StatelessWidget {
  const MetaverseDeveloperPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l.metaverse_developerCenter),
          bottom: TabBar(
            tabs: [
              Tab(text: l.metaverse_developerComponents),
              Tab(text: l.metaverse_developerApis),
              Tab(text: l.metaverse_developerGuides),
            ],
          ),
        ),
        body: const TabBarView(
          children: [_ComponentGallery(), _ApiGallery(), _DeveloperGuides()],
        ),
      ),
    );
  }
}

class _ComponentGallery extends StatefulWidget {
  const _ComponentGallery();
  @override
  State<_ComponentGallery> createState() => _ComponentGalleryState();
}

class _ComponentGalleryState extends State<_ComponentGallery> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final examples = metaverseComponentExamples(context.l10n)
        .where((e) => e.name.toLowerCase().contains(_query.toLowerCase()))
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: InputFieldShell(
            child: TextField(
              decoration: InputDecoration(
                hintText: context.l10n.metaverse_developerSearch,
                prefixIcon: const Icon(Symbols.search_rounded),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: examples.length,
            itemBuilder: (context, index) => ListTile(
              leading: const Icon(Symbols.widgets_rounded),
              title: Text(examples[index].name),
              subtitle: Text(examples[index].parameters.keys.join(' · ')),
              trailing: const Icon(Symbols.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(
                InteractionPageRoute(
                  builder: (_) =>
                      MetaverseComponentPreviewPage(example: examples[index]),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class MetaverseComponentPreviewPage extends StatefulWidget {
  const MetaverseComponentPreviewPage({super.key, required this.example});
  final MetaverseComponentExample example;
  @override
  State<MetaverseComponentPreviewPage> createState() =>
      _ComponentPreviewState();
}

class _ComponentPreviewState extends State<MetaverseComponentPreviewPage> {
  late final Runtime _widgets;
  late final DynamicContent _data;
  late Map<String, Object> _values;
  final _events = <String>[];
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    _values = Map.of(widget.example.parameters);
    _data = DynamicContent(_values);
    _widgets = Runtime()
      ..update(
        metaverseWidgetLibraryName,
        createMetaverseWidgetLibrary(loadImage: _previewImage),
      )
      ..update(
        metaversePluginLibraryName,
        parseLibraryFile(
          'import fluxdo; widget Preview = ${widget.example.source};',
        ),
      );
  }

  Future<Uint8List> _previewImage(Uri _) async {
    // 展示应用自带资源，预览组件无需访问网络。
    final bytes = await rootBundle.load(
      'assets/images/icon_default_preview.png',
    );
    return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  }

  @override
  void dispose() {
    _widgets.dispose();
    super.dispose();
  }

  void _change(String key, Object value) {
    setState(() => _values[key] = value);
    _data.update(key, value);
  }

  void _event(String name, DynamicMap args) {
    setState(() {
      _events.insert(0, '$name ${jsonEncode(args)}');
      if (_events.length > 50) _events.removeLast();
    });
    if (name == 'change') {
      final value = args['value'];
      if (value != null) _change('value', value);
    }
    if (name == 'select') _change('selected', _values['selected'] != true);
    if (name == 'refresh') {
      _change('loading', true);
      Future<void>.delayed(const Duration(milliseconds: 600), () {
        if (mounted) _change('loading', false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.example.name),
        actions: [
          IconButton(
            tooltip: l.metaverse_developerReset,
            icon: const Icon(Symbols.restart_alt_rounded),
            onPressed: () {
              for (final entry in widget.example.parameters.entries) {
                _data.update(entry.key, entry.value);
              }
              setState(() {
                _values = Map.of(widget.example.parameters);
                _events.clear();
                _revision++;
              });
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            l.metaverse_developerPreview,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          Card(
            elevation: 0,
            color: PageBackgroundScope.contentColor(
              context,
              theme.colorScheme.surfaceContainerLow,
            ),
            child: SizedBox(
              height: widget.example.name == 'PageLayout' ? 360 : 200,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: RemoteWidget(
                    key: ValueKey(_revision),
                    runtime: _widgets,
                    widget: const FullyQualifiedWidgetName(
                      metaversePluginLibraryName,
                      'Preview',
                    ),
                    data: _data,
                    onEvent: _event,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          if (_values.isNotEmpty)
            Text(
              l.metaverse_developerParameters,
              style: theme.textTheme.titleMedium,
            ),
          for (final entry in _values.entries)
            _parameter(entry.key, entry.value),
          const SizedBox(height: 20),
          _CodeBlock(
            title: l.metaverse_developerCode,
            code:
                'import fluxdo;\nwidget Preview = ${widget.example.source};\n\n// ctx.setData\n${const JsonEncoder.withIndent('  ').convert(_values)}',
          ),
          const SizedBox(height: 20),
          Text(l.metaverse_developerEvents, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final event in _events) SelectableText(event),
        ],
      ),
    );
  }

  Widget _parameter(String key, Object value) {
    if (value is bool) {
      return M3eSwitchListTile(
        title: Text(key),
        value: value,
        onChanged: (next) => _change(key, next),
      );
    }
    if (value is num) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$key · ${value.toStringAsFixed(2)}'),
          Slider(
            value: value.toDouble(),
            min: 0,
            max: key == 'value' ? 1 : 160,
            onChanged: (next) => _change(key, next),
          ),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: TextFormField(
        key: ValueKey('$key-$_revision'),
        initialValue: value.toString(),
        decoration: InputDecoration(labelText: key),
        onChanged: (next) => _change(key, next),
      ),
    );
  }
}

class _ApiGallery extends StatefulWidget {
  const _ApiGallery();
  @override
  State<_ApiGallery> createState() => _ApiGalleryState();
}

class _ApiGalleryState extends State<_ApiGallery> {
  MetaverseApiExample _example = metaverseApiExamples.first;
  MetaversePluginRuntime? _runtime;
  bool _failure = false;
  bool _running = false;
  int _generation = 0;
  final _events = <String>[];

  @override
  void dispose() {
    _generation++;
    _runtime?.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    if (_running) return;
    final generation = ++_generation;
    _runtime?.dispose();
    setState(() {
      _events.clear();
      _running = true;
    });
    try {
      final runtime = await MetaversePluginRuntime.start(
        engineFactory: createMetaverseScriptEngine,
        script: _example.script,
        bridge: MetaverseDocumentationBridge(
          example: _example,
          failure: _failure,
          onLog: (level, message) {
            if (!mounted || generation != _generation) return;
            setState(() {
              _events.add('[$level] $message');
              if (_events.length > 50) _events.removeAt(0);
            });
          },
        ),
      );
      if (!mounted || generation != _generation) {
        runtime.dispose();
        return;
      }
      _runtime = runtime;
      final surface = runtime.openSurface(kind: 'card');
      if (_example.userAction) runtime.dispatch(surface, 'action', const {});
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _events.add('$error'));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _running = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(l.metaverse_developerSimulated),
        const SizedBox(height: 16),
        DropdownButtonFormField<MetaverseApiExample>(
          initialValue: _example,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'API'),
          items: [
            for (final example in metaverseApiExamples)
              DropdownMenuItem(value: example, child: Text(example.name)),
          ],
          onChanged: _running
              ? null
              : (value) {
                  if (value != null) setState(() => _example = value);
                },
        ),
        ListTile(
          title: Text(l.metaverse_marketCompatibility),
          subtitle: Text('API ${_example.apiVersion}'),
        ),
        if (_example.permission case final permission?)
          ListTile(
            title: Text(l.metaverse_marketPermissions),
            subtitle: Text(permission),
          ),
        M3eSwitchListTile(
          title: Text(l.metaverse_developerSimulateFailure),
          value: _failure,
          onChanged: (value) => setState(() => _failure = value),
        ),
        FilledButton.icon(
          onPressed: _running ? null : _run,
          icon: _running
              ? const LoadingSpinner(size: 18)
              : const Icon(Symbols.play_arrow_rounded),
          label: Text(l.metaverse_developerRun),
        ),
        const SizedBox(height: 16),
        _CodeBlock(title: l.metaverse_developerCode, code: _example.script),
        const SizedBox(height: 16),
        Text(
          l.metaverse_developerEvents,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        for (final event in _events) SelectableText(event),
      ],
    );
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.title, required this.code});
  final String title, code;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          IconButton(
            tooltip: context.l10n.common_copy,
            icon: const Icon(Symbols.content_copy_rounded),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: code));
              ToastService.showSuccess(S.current.common_copiedToClipboard);
            },
          ),
        ],
      ),
      SelectableText(
        code,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(fontFamily: 'monospace'),
      ),
    ],
  );
}

class _DeveloperGuides extends StatelessWidget {
  const _DeveloperGuides();
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final sections = [
      (Symbols.description_rounded, l.metaverse_developerManifestGuide),
      (Symbols.widgets_rounded, l.metaverse_developerUiGuide),
      (Symbols.code_rounded, l.metaverse_developerScriptGuide),
      (Symbols.security_rounded, l.metaverse_developerPermissionGuide),
      (Symbols.bug_report_rounded, l.metaverse_developerDiagnosticsGuide),
      (Symbols.publish_rounded, l.metaverse_developerPublishGuide),
    ];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final section in sections)
          Card(
            elevation: 0,
            child: ListTile(
              contentPadding: const EdgeInsets.all(16),
              leading: Icon(section.$1, color: context.emphasis.accent),
              title: Text(section.$2),
            ),
          ),
        ListTile(
          title: Text(l.metaverse_marketRepository),
          subtitle: const Text('Lingyan000/fluxdo-plugins'),
          trailing: const Icon(Symbols.open_in_new_rounded),
          onTap: () => launchExternalLink(
            context,
            'https://github.com/Lingyan000/fluxdo-plugins',
          ),
        ),
      ],
    );
  }
}
