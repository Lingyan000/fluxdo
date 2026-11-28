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
            // 只检查静态值；数据引用、分支及循环仍由 RFW 在渲染时解析。
            bool matches(Object value, String kind) => switch (kind) {
              'string' => value is String,
              'boolean' => value is bool,
              'integer' => value is int,
              'number' => value is num,
              'list' => value is List,
              'widget' => value is ConstructorCall || value is WidgetBuilderDeclaration,
              'event' => value is EventHandler || value is SetStateHandler,
              _ => true,
            };
            void check(Object? value, List<String> path, List<String> kinds, String field) {
              if (value == null) return;
              if (path.isNotEmpty) {
                if (path.first == '*' && value is List) {
                  for (var i = 0; i < value.length; i++) {
                    check(value[i], path.sublist(1), kinds, '$field[$i]');
                  }
                } else if (value is Map && path.first != '*') {
                  check(value[path.first], path.sublist(1), kinds, field.isEmpty ? path.first : '$field.${path.first}');
                }
                return;
              }
              if (value is! String && value is! bool && value is! num && value is! List && value is! Map &&
                  value is! ConstructorCall && value is! EventHandler && value is! SetStateHandler && value is! WidgetBuilderDeclaration) { return; }
              if (!kinds.any((kind) => matches(value, kind))) {
                diagnostics.add('ui.rfwtxt:$line:$column ${node.name}.$field 应为 ${kinds.join(" / ")}');
              }
            }
            for (final entry in (spec['types'] as Map? ?? const {}).entries) {
              check(node.arguments, (entry.key as String).split('.'), (entry.value as List).cast<String>(), '');
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
