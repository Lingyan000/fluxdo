import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

/// 从实际 DataSource 读取位置导出参数名，不维护第二份组件白名单。
Future<void> main(List<String> args) async {
  final config = jsonDecode(
    await File('.dart_tool/package_config.json').readAsString(),
  ) as Map;
  final rfw = (config['packages'] as List).cast<Map>().firstWhere(
    (p) => p['name'] == 'rfw',
  );
  final base = File('.dart_tool/package_config.json').absolute.uri
      .resolve('${rfw['rootUri']}/');
  final files = [
    ...Directory('lib/modules/metaverse/plugin/ui')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart')),
    File.fromUri(base.resolve('lib/src/flutter/core_widgets.dart')),
  ];
  final functions = <String, AstNode>{};
  final definitions = <String, Expression>{};
  final allowed = <String>{};
  for (final file in files) {
    final unit = parseString(
      content: file.readAsStringSync(),
      throwIfDiagnostics: false,
    ).unit;
    for (final declaration in unit.declarations) {
      if (declaration is FunctionDeclaration) {
        functions[declaration.name.lexeme] =
            declaration.functionExpression.body;
      }
    }
    unit.accept(
      _Visitor((node) {
        if (node is VariableDeclaration &&
            node.name.lexeme == '_allowedCoreWidgets') {
          node.initializer?.accept(
            _Visitor((value) {
              if (value is SimpleStringLiteral) allowed.add(value.value);
            }),
          );
        }
        if (node is MapLiteralEntry && node.key is SimpleStringLiteral) {
          final parent = node.thisOrAncestorOfType<FunctionDeclaration>();
          final body = parent?.functionExpression.body;
          if (body is ExpressionFunctionBody &&
              identical(node.parent, body.expression) &&
              [
                '_hostWidgets',
                '_pageWidgets',
                '_coreWidgetsDefinitions',
              ].contains(parent?.name.lexeme)) {
            final name = (node.key as SimpleStringLiteral).value;
            if (parent?.name.lexeme != '_coreWidgetsDefinitions' ||
                !definitions.containsKey(name)) {
              definitions[name] = node.value;
            }
          }
        }
      }),
    );
  }
  final result = <String, Object>{};
  for (final entry in definitions.entries) {
    // 宿主组件来自两个注册函数；核心组件按生产注册表筛选。
    final parent = entry.value.thisOrAncestorOfType<FunctionDeclaration>();
    if (!allowed.contains(entry.key) &&
        parent?.name.lexeme != '_hostWidgets' &&
        parent?.name.lexeme != '_pageWidgets') {
      continue;
    }
    final fields = <String>{};
    final visited = <String>{};
    void scan(AstNode node) {
      if (node is SimpleIdentifier &&
          functions.containsKey(node.name) &&
          visited.add(node.name)) {
        scan(functions[node.name]!);
      }
      node.accept(
        _Visitor((value) {
          if (value is! MethodInvocation) return;
          final args = value.argumentList.arguments
              .map((a) => a.argumentExpression)
              .toList();
          Expression? path;
          if (value.target?.toSource() == 'source' && args.isNotEmpty) {
            path = args.first;
          }
          for (var i = 0; i < args.length - 1; i++) {
            if (args[i].toSource() == 'source') path = args[i + 1];
          }
          if (path is ListLiteral &&
              path.elements.isNotEmpty &&
              path.elements.first is SimpleStringLiteral) {
            fields.add((path.elements.first as SimpleStringLiteral).value);
          } else if (path is SimpleStringLiteral) {
            fields.add(path.value);
          }
          final name = value.methodName.name;
          if (args.any((a) => a.toSource() == 'source') &&
              functions.containsKey(name) &&
              visited.add(name)) {
            scan(functions[name]!);
          }
        }),
      );
    }

    scan(entry.value);
    result[entry.key] = {'parameters': fields.toList()..sort()};
  }
  final sorted = {
    for (final name in result.keys.toList()..sort()) name: result[name],
  };
  final text = '${const JsonEncoder.withIndent('  ').convert(sorted)}\n';
  final output = File(
    args.isEmpty ? 'test/fixtures/metaverse/sdk/components.json' : args.first,
  );
  if (args.contains('--check')) {
    final generated = File(
      'lib/modules/metaverse/plugin/metaverse_component_contract.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    if (output.readAsStringSync().replaceAll('\r\n', '\n') != text ||
        !generated.contains('const metaverseComponentContract = $text;')) {
      stderr.writeln('组件契约已过期');
      exitCode = 1;
    }
  } else {
    await output.writeAsString(text);
    await File(
      'lib/modules/metaverse/plugin/metaverse_component_contract.dart',
    ).writeAsString(
      '// 由 tool/plugin_tools/export_components.dart 生成，参数来自生产组件。\nconst metaverseComponentContract = $text;\n',
    );
  }
}

class _Visitor extends GeneralizingAstVisitor<void> {
  _Visitor(this.visit);
  final void Function(AstNode) visit;
  @override
  void visitNode(AstNode node) {
    visit(node);
    super.visitNode(node);
  }
}
