import 'package:rfw/formats.dart';

Map<String, Object?> validatePluginUiContract(String source, Map contract) {
  final diagnostics = <String>[];
  try {
    final library = parseLibraryFile(source, sourceIdentifier: 'ui.rfwtxt');
    final declared = library.widgets.map((w) => w.name).toSet();
    for (final imported in library.imports) {
      if (imported.name.parts.join('.') != 'fluxdo') {
        diagnostics.add('只能 import fluxdo');
      }
    }
    void walk(Object? node) {
      if (node is ConstructorCall) {
        if (!declared.contains(node.name)) {
          final spec = contract[node.name];
          final offset = node.source?.start.offset ?? 0;
          final line = '\n'.allMatches(source.substring(0, offset)).length + 1;
          final column =
              offset - source.lastIndexOf('\n', offset == 0 ? 0 : offset - 1);
          if (spec is! Map) {
            diagnostics.add('ui.rfwtxt:$line:$column 未知组件 ${node.name}');
          } else {
            final keys = (spec['parameters'] as List).cast<String>().toSet();
            for (final key in node.arguments.keys) {
              if (!keys.contains(key)) {
                diagnostics.add(
                  'ui.rfwtxt:$line:$column ${node.name} 不支持参数 $key；可用参数：${keys.join(', ')}',
                );
              }
            }
          }
        }
        walk(node.arguments);
      } else if (node is Map) {
        node.values.forEach(walk);
      } else if (node is Iterable) {
        node.forEach(walk);
      } else if (node is Switch) {
        walk(node.outputs);
      } else if (node is Loop) {
        walk(node.output);
      } else if (node is WidgetBuilderDeclaration) {
        walk(node.widget);
      } else if (node is EventHandler) {
        walk(node.eventArguments);
      } else if (node is SetStateHandler) {
        walk(node.value);
      }
    }

    for (final widget in library.widgets) {
      walk(widget.root);
    }
    return {'widgets': declared.toList(), 'diagnostics': diagnostics};
  } catch (error) {
    return {
      'widgets': <String>[],
      'diagnostics': ['$error'],
    };
  }
}
