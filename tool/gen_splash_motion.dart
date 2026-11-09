import 'dart:convert';
import 'dart:io';

import '_workspace_cli.dart';

// 启动 logo 描线动画生成器。
//
// 单一真源是 tool/splash_motion/logo_motion.json：几何（SVG 路径）+ 时间线 +
// 曲线 + 颜色。本脚本把路径解析并统一成绝对坐标命令，再从同一份解析结果
// 产出各端代码，保证 Flutter 启动页与原生启动屏逐帧同源：
// - lib/widgets/preheat_logo_motion.g.dart（Flutter 启动页）
// - Android 13+ 原生启动屏：res/drawable(-night)/splash_logo_*.xml
//   （AnimatedVectorDrawable）、res/interpolator/splash_motion_*.xml、
//   res/values-v31/splash_motion.xml（时长）
// - 两端共用的启动底色：res/values(-night)/splash_colors.xml、
//   iOS LaunchBackground.colorset
//
// 用法：dart run tool/gen_splash_motion.dart [--check]
// --check 只比对生成结果是否最新，不写文件（供 CI / just splash-motion-check）。

const _specPath = 'tool/splash_motion/logo_motion.json';
const _dartOut = 'lib/widgets/preheat_logo_motion.g.dart';
const _res = 'android/app/src/main/res';
const _iosColorset =
    'ios/Runner/Assets.xcassets/LaunchBackground.colorset/Contents.json';
const _header =
    '// 由 tool/gen_splash_motion.dart 根据 $_specPath 生成，勿手改。\n'
    '// 修改动画请改规格文件后执行 `just splash-motion`。\n';
const _xmlHeader =
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<!-- 由 tool/gen_splash_motion.dart 根据 $_specPath 生成，勿手改。\n'
    '     修改动画请改规格文件后执行 just splash-motion。 -->\n';

Future<void> main(List<String> args) async {
  enterWorkspaceRoot();
  final checkOnly = args.contains('--check');

  final spec =
      jsonDecode(File(_specPath).readAsStringSync()) as Map<String, dynamic>;
  final outputs = <String, String>{
    _dartOut: await _formatDart(_emitDart(spec)),
    ..._emitAndroid(spec),
    _iosColorset: _emitIosColorset(spec),
  };

  var stale = false;
  for (final entry in outputs.entries) {
    final file = File(entry.key);
    final current = file.existsSync() ? file.readAsStringSync() : null;
    if (current == entry.value) continue;
    if (checkOnly) {
      stderr.writeln('过期: ${entry.key}');
      stale = true;
    } else {
      file
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(entry.value);
      stdout.writeln('已生成 ${entry.key}');
    }
  }
  if (checkOnly) {
    if (stale) {
      stderr.writeln('启动动画生成结果过期，请执行 just splash-motion');
      exit(1);
    }
    stdout.writeln('启动动画生成结果为最新');
  }
}

// ---------------------------------------------------------------- SVG 路径

/// 统一后的绝对坐标命令：M/L/C/A/Z
class _Cmd {
  _Cmd(this.op, this.args);
  final String op;
  final List<double> args;
}

final _token = RegExp(
  r'[MmLlHhVvCcAaZz]|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?',
);

List<_Cmd> _parsePath(String d) {
  final tokens = _token.allMatches(d).map((m) => m.group(0)!).toList();
  final out = <_Cmd>[];
  var i = 0;
  var cx = 0.0, cy = 0.0, sx = 0.0, sy = 0.0;
  String? op;

  bool isCmd(String t) => RegExp(r'^[A-Za-z]$').hasMatch(t);
  double next() {
    if (i >= tokens.length || isCmd(tokens[i])) {
      throw FormatException('路径参数不足: $d');
    }
    return double.parse(tokens[i++]);
  }

  while (i < tokens.length) {
    if (isCmd(tokens[i])) {
      op = tokens[i++];
    } else if (op == null) {
      throw FormatException('路径缺少起始命令: $d');
    }
    final rel = op == op.toLowerCase();
    switch (op.toUpperCase()) {
      case 'M':
        var x = next(), y = next();
        if (rel) {
          x += cx;
          y += cy;
        }
        out.add(_Cmd('M', [x, y]));
        cx = sx = x;
        cy = sy = y;
        // M 之后的隐式坐标对按 L 处理
        op = rel ? 'l' : 'L';
      case 'L':
        var x = next(), y = next();
        if (rel) {
          x += cx;
          y += cy;
        }
        out.add(_Cmd('L', [x, y]));
        cx = x;
        cy = y;
      case 'H':
        var x = next();
        if (rel) x += cx;
        out.add(_Cmd('L', [x, cy]));
        cx = x;
      case 'V':
        var y = next();
        if (rel) y += cy;
        out.add(_Cmd('L', [cx, y]));
        cy = y;
      case 'C':
        final a = [next(), next(), next(), next(), next(), next()];
        if (rel) {
          for (var k = 0; k < 6; k += 2) {
            a[k] += cx;
            a[k + 1] += cy;
          }
        }
        out.add(_Cmd('C', a));
        cx = a[4];
        cy = a[5];
      case 'A':
        final rx = next(), ry = next(), rot = next();
        final large = next(), sweep = next();
        var x = next(), y = next();
        if (rel) {
          x += cx;
          y += cy;
        }
        out.add(_Cmd('A', [rx, ry, rot, large, sweep, x, y]));
        cx = x;
        cy = y;
      case 'Z':
        out.add(_Cmd('Z', const []));
        cx = sx;
        cy = sy;
        op = null;
      default:
        throw FormatException('不支持的路径命令 $op: $d');
    }
  }
  return out;
}

String _num(double v) {
  final r = (v * 10000).round() / 10000;
  if (r == r.roundToDouble()) return r.toInt().toString();
  return r.toString();
}

String _svgPath(String d) {
  final b = StringBuffer();
  for (final c in _parsePath(d)) {
    if (b.isNotEmpty) b.write(' ');
    b.write(c.op);
    b.write(c.args.map(_num).join(','));
  }
  return b.toString();
}

// ---------------------------------------------------------------- Android 输出

const _curveNames = {
  'stroke': 'splash_motion_stroke',
  'fill': 'splash_motion_fill',
  'strokeFade': 'splash_motion_stroke_fade',
};

String _hexUpper(String hex) => '#${hex.substring(1).toUpperCase()}';

Map<String, String> _emitAndroid(Map<String, dynamic> spec) {
  final out = <String, String>{};
  final curves = spec['curves'] as Map<String, dynamic>;
  for (final entry in _curveNames.entries) {
    final c = (curves[entry.key] as List).cast<num>();
    out['$_res/interpolator/${entry.value}.xml'] =
        '$_xmlHeader'
        '<pathInterpolator xmlns:android="http://schemas.android.com/apk/res/android"\n'
        '    android:controlX1="${_num(c[0].toDouble())}"\n'
        '    android:controlY1="${_num(c[1].toDouble())}"\n'
        '    android:controlX2="${_num(c[2].toDouble())}"\n'
        '    android:controlY2="${_num(c[3].toDouble())}" />\n';
  }

  out['$_res/values-v31/splash_motion.xml'] =
      '$_xmlHeader'
      '<resources>\n'
      '    <!-- 描线动画时长，启动屏主题的 windowSplashScreenAnimationDuration 引用 -->\n'
      '    <integer name="splash_motion_duration">${spec['durationMs']}</integer>\n'
      '</resources>\n';

  final colors = spec['colors'] as Map<String, dynamic>;
  final bg = colors['background'] as Map<String, dynamic>;
  for (final dark in [false, true]) {
    out['$_res/values${dark ? '-night' : ''}/splash_colors.xml'] =
        '$_xmlHeader'
        '<resources>\n'
        '    <!-- 启动屏底色，与 Flutter 启动页同值 -->\n'
        '    <color name="splash_background">'
        '${_hexUpper(bg[dark ? 'dark' : 'light'] as String)}</color>\n'
        '</resources>\n';
  }

  final logos = spec['logos'] as Map<String, dynamic>;
  for (final name in logos.keys) {
    for (final dark in [false, true]) {
      out['$_res/drawable${dark ? '-night' : ''}/splash_logo_$name.xml'] =
          _emitAvd(spec, logos[name] as Map<String, dynamic>, dark);
    }
  }
  return out;
}

/// 原生启动屏 logo：系统启动屏无图标背景时图标框为 288dp，logo 居中占
/// logoSizeDp，与 Flutter 启动页等大同位
String _emitAvd(
  Map<String, dynamic> spec,
  Map<String, dynamic> logo,
  bool dark,
) {
  const canvas = 288.0;
  final logoSize = (spec['logoSizeDp'] as num).toDouble();
  final durationMs = (spec['durationMs'] as num).toDouble();
  final vb = (logo['viewBox'] as List)
      .cast<num>()
      .map((v) => v.toDouble())
      .toList();
  final scale = logoSize / vb[2];
  final inset = (canvas - logoSize) / 2;
  final strokeWidth =
      (spec['strokeWidthDp'] as num).toDouble() * vb[2] / logoSize;
  final colors = spec['colors'] as Map<String, dynamic>;
  final strokeColor = _hexUpper(
    (colors['stroke'] as Map<String, dynamic>)[dark ? 'dark' : 'light']
        as String,
  );
  final fade = (spec['strokeFade'] as List).cast<num>();
  final shapes = (logo['shapes'] as List).cast<Map<String, dynamic>>();

  String ms(num fraction) => (fraction * durationMs).round().toString();
  String animator(
    String property,
    num from,
    num to,
    List<num> span,
    String curve,
  ) =>
      '                <objectAnimator\n'
      '                    android:propertyName="$property"\n'
      '                    android:startOffset="${ms(span[0])}"\n'
      '                    android:duration="${(((span[1] - span[0]) * durationMs).round())}"\n'
      '                    android:valueFrom="$from"\n'
      '                    android:valueTo="$to"\n'
      '                    android:valueType="floatType"\n'
      '                    android:interpolator="@interpolator/$curve" />\n';

  final b = StringBuffer()
    ..write(_xmlHeader)
    ..write(
      '<animated-vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
      '    xmlns:aapt="http://schemas.android.com/aapt">\n'
      '    <aapt:attr name="android:drawable">\n'
      '        <vector\n'
      '            android:width="${_num(canvas)}dp"\n'
      '            android:height="${_num(canvas)}dp"\n'
      '            android:viewportWidth="${_num(canvas)}"\n'
      '            android:viewportHeight="${_num(canvas)}">\n'
      '            <group\n'
      '                android:translateX="${_num(inset - vb[0] * scale)}"\n'
      '                android:translateY="${_num(inset - vb[1] * scale)}"\n'
      '                android:scaleX="${scale.toStringAsFixed(8)}"\n'
      '                android:scaleY="${scale.toStringAsFixed(8)}">\n',
    );
  // 先画全部填色，再在上层画描线（与 Flutter 绘制顺序一致）
  for (final s in shapes) {
    if (s['fillPath'] == null) continue;
    final fill = s['fill'] as Map<String, dynamic>;
    b.write(
      '                <path\n'
      '                    android:name="${s['id']}_fill"\n'
      '                    android:fillColor="${_hexUpper(fill[dark ? 'dark' : 'light'] as String)}"\n'
      '                    android:fillAlpha="0"\n'
      '                    android:pathData="${_svgPath(s['fillPath'] as String)}" />\n',
    );
  }
  for (final s in shapes) {
    if (s['strokePath'] == null) continue;
    b.write(
      '                <path\n'
      '                    android:name="${s['id']}_stroke"\n'
      '                    android:strokeColor="$strokeColor"\n'
      '                    android:strokeWidth="${_num(strokeWidth)}"\n'
      '                    android:strokeLineCap="round"\n'
      '                    android:strokeLineJoin="round"\n'
      '                    android:trimPathEnd="0"\n'
      '                    android:pathData="${_svgPath(s['strokePath'] as String)}" />\n',
    );
  }
  b.write(
    '            </group>\n'
    '        </vector>\n'
    '    </aapt:attr>\n',
  );
  for (final s in shapes) {
    if (s['fillPath'] == null) continue;
    final span = (s['fillIn'] as List).cast<num>();
    b
      ..write('    <target android:name="${s['id']}_fill">\n')
      ..write('        <aapt:attr name="android:animation">\n')
      ..write(
        animator(
          'fillAlpha',
          0,
          1,
          span,
          _curveNames['fill']!,
        ).replaceAll(RegExp(r'^ {4}', multiLine: true), ''),
      )
      ..write('        </aapt:attr>\n')
      ..write('    </target>\n');
  }
  for (final s in shapes) {
    if (s['strokePath'] == null) continue;
    final span = (s['stroke'] as List).cast<num>();
    b
      ..write('    <target android:name="${s['id']}_stroke">\n')
      ..write('        <aapt:attr name="android:animation">\n')
      ..write('            <set>\n')
      ..write(animator('trimPathEnd', 0, 1, span, _curveNames['stroke']!))
      ..write(animator('strokeAlpha', 1, 0, fade, _curveNames['strokeFade']!))
      ..write('            </set>\n')
      ..write('        </aapt:attr>\n')
      ..write('    </target>\n');
  }
  b.write('</animated-vector>\n');
  return b.toString();
}

// ---------------------------------------------------------------- iOS 输出

String _emitIosColorset(Map<String, dynamic> spec) {
  final bg =
      (spec['colors'] as Map<String, dynamic>)['background']
          as Map<String, dynamic>;
  String components(String hex) {
    final v = hex.substring(1).toUpperCase();
    return '        "components" : {\n'
        '          "alpha" : "1.000",\n'
        '          "blue" : "0x${v.substring(4, 6)}",\n'
        '          "green" : "0x${v.substring(2, 4)}",\n'
        '          "red" : "0x${v.substring(0, 2)}"\n'
        '        }\n';
  }

  return '{\n'
      '  "colors" : [\n'
      '    {\n'
      '      "color" : {\n'
      '        "color-space" : "srgb",\n'
      '${components(bg['light'] as String)}'
      '      },\n'
      '      "idiom" : "universal"\n'
      '    },\n'
      '    {\n'
      '      "appearances" : [\n'
      '        {\n'
      '          "appearance" : "luminosity",\n'
      '          "value" : "dark"\n'
      '        }\n'
      '      ],\n'
      '      "color" : {\n'
      '        "color-space" : "srgb",\n'
      '${components(bg['dark'] as String)}'
      '      },\n'
      '      "idiom" : "universal"\n'
      '    }\n'
      '  ],\n'
      '  "info" : {\n'
      '    "author" : "xcode",\n'
      '    "version" : 1\n'
      '  }\n'
      '}\n';
}

// ---------------------------------------------------------------- Dart 输出

String _dartColor(String hex) => 'Color(0xFF${hex.substring(1).toUpperCase()})';

String _constColor(String hex) => 'const ${_dartColor(hex)}';

String _dartCubic(List<dynamic> c) =>
    'Cubic(${c.map((v) => _numDouble((v as num).toDouble())).join(', ')})';

String _numDouble(double v) {
  final s = _num(v);
  return s.contains('.') ? s : '$s.0';
}

String _dartPath(String d) {
  final b = StringBuffer('Path()');
  for (final c in _parsePath(d)) {
    final a = c.args;
    switch (c.op) {
      case 'M':
        b.write('..moveTo(${_num(a[0])}, ${_num(a[1])})');
      case 'L':
        b.write('..lineTo(${_num(a[0])}, ${_num(a[1])})');
      case 'C':
        b.write('..cubicTo(${a.map(_num).join(', ')})');
      case 'A':
        final radius = a[0] == a[1]
            ? 'const Radius.circular(${_num(a[0])})'
            : 'const Radius.elliptical(${_num(a[0])}, ${_num(a[1])})';
        b.write(
          '..arcToPoint(const Offset(${_num(a[5])}, ${_num(a[6])}), '
          'radius: $radius, '
          '${a[2] != 0 ? 'rotation: ${_num(a[2])}, ' : ''}'
          'largeArc: ${a[3] != 0}, clockwise: ${a[4] != 0})',
        );
      case 'Z':
        b.write('..close()');
    }
  }
  return b.toString();
}

String _emitDart(Map<String, dynamic> spec) {
  final curves = spec['curves'] as Map<String, dynamic>;
  final colors = spec['colors'] as Map<String, dynamic>;
  final fade = (spec['strokeFade'] as List).cast<num>();
  final b = StringBuffer()
    ..write(_header)
    ..writeln()
    ..writeln("import 'package:flutter/animation.dart';")
    ..writeln("import 'package:flutter/painting.dart';")
    ..writeln()
    ..writeln("import 'preheat_logo_motion.dart';")
    ..writeln()
    ..writeln('/// 描线动画总时长')
    ..writeln(
      'const Duration logoMotionDuration = '
      'Duration(milliseconds: ${spec['durationMs']});',
    )
    ..writeln()
    ..writeln('/// 规格基准 logo 边长（逻辑像素），与原生启动屏 logo 等大')
    ..writeln(
      'const double logoMotionLogoSize = '
      '${_numDouble((spec['logoSizeDp'] as num).toDouble())};',
    )
    ..writeln()
    ..writeln('/// 基准 logo 边长下的描线宽度（逻辑像素），随 logo 尺寸等比缩放')
    ..writeln(
      'const double logoMotionStrokeWidth = '
      '${_numDouble((spec['strokeWidthDp'] as num).toDouble())};',
    )
    ..writeln()
    ..writeln(
      'const Cubic logoMotionStrokeCurve = ${_dartCubic(curves['stroke'] as List)};',
    )
    ..writeln(
      'const Cubic logoMotionFillCurve = ${_dartCubic(curves['fill'] as List)};',
    )
    ..writeln(
      'const Cubic logoMotionStrokeFadeCurve = '
      '${_dartCubic(curves['strokeFade'] as List)};',
    )
    ..writeln()
    ..writeln('/// 描线整体淡出区间（占总时长比例）')
    ..writeln(
      'const double logoMotionStrokeFadeStart = ${_numDouble(fade[0].toDouble())};',
    )
    ..writeln(
      'const double logoMotionStrokeFadeEnd = ${_numDouble(fade[1].toDouble())};',
    )
    ..writeln()
    ..writeln('/// 启动页底色，与原生启动屏同值')
    ..writeln(
      'const Color logoMotionBackgroundLight = '
      '${_dartColor((colors['background'] as Map)['light'] as String)};',
    )
    ..writeln(
      'const Color logoMotionBackgroundDark = '
      '${_dartColor((colors['background'] as Map)['dark'] as String)};',
    )
    ..writeln()
    ..writeln('/// 描线颜色（品牌色，不随主题变化）')
    ..writeln(
      'const Color logoMotionStrokeLight = '
      '${_dartColor((colors['stroke'] as Map)['light'] as String)};',
    )
    ..writeln(
      'const Color logoMotionStrokeDark = '
      '${_dartColor((colors['stroke'] as Map)['dark'] as String)};',
    );

  final logos = spec['logos'] as Map<String, dynamic>;
  for (final name in logos.keys) {
    final logo = logos[name] as Map<String, dynamic>;
    final vb = (logo['viewBox'] as List).cast<num>();
    final body = logo['body'] as Map<String, dynamic>;
    b
      ..writeln()
      ..writeln('final LogoMotionSpec ${name}LogoMotion = LogoMotionSpec(')
      ..writeln(
        '  viewBox: const Rect.fromLTWH(${vb.map((v) => _num(v.toDouble())).join(', ')}),',
      )
      ..writeln(
        '  bodyCenter: const Offset(${_num((body['cx'] as num).toDouble())}, '
        '${_num((body['cy'] as num).toDouble())}),',
      )
      ..writeln('  bodyRadius: ${_numDouble((body['r'] as num).toDouble())},')
      ..writeln('  shapes: [');
    for (final raw in logo['shapes'] as List) {
      final s = raw as Map<String, dynamic>;
      final fill = s['fill'] as Map<String, dynamic>?;
      final stroke = (s['stroke'] as List?)?.cast<num>();
      final fillIn = (s['fillIn'] as List?)?.cast<num>();
      b.writeln('    LogoMotionShape(');
      b.writeln("      id: '${s['id']}',");
      if (s['body'] == true) b.writeln('      isBody: true,');
      if (s['fillPath'] != null) {
        b
          ..writeln('      fillPath: ${_dartPath(s['fillPath'] as String)},')
          ..writeln(
            '      fillLight: ${_constColor(fill!['light'] as String)},',
          )
          ..writeln('      fillDark: ${_constColor(fill['dark'] as String)},')
          ..writeln('      fillStart: ${_numDouble(fillIn![0].toDouble())},')
          ..writeln('      fillEnd: ${_numDouble(fillIn[1].toDouble())},');
      }
      if (s['strokePath'] != null) {
        b
          ..writeln(
            '      strokePath: ${_dartPath(s['strokePath'] as String)},',
          )
          ..writeln('      strokeStart: ${_numDouble(stroke![0].toDouble())},')
          ..writeln('      strokeEnd: ${_numDouble(stroke[1].toDouble())},');
      }
      b.writeln('    ),');
    }
    b
      ..writeln('  ],')
      ..writeln(');');
  }
  return b.toString();
}

/// 经 dart format 规整后的文本，--check 比对时与已提交文件格式一致
Future<String> _formatDart(String source) async {
  final dir = Directory('.dart_tool/gen_splash_motion')
    ..createSync(recursive: true);
  final tmp = File('${dir.path}/out.dart')..writeAsStringSync(source);
  final result = await Process.run(Platform.resolvedExecutable, [
    'format',
    tmp.path,
  ]);
  if (result.exitCode != 0) {
    throw ProcessException(
      'dart',
      ['format'],
      '${result.stderr}',
      result.exitCode,
    );
  }
  return tmp.readAsStringSync();
}
