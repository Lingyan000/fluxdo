/// hashtag 药丸图标解析器的接线回归。
///
/// `FaIconData` 是 `IconData` 的**包装**不是子类:写成 `as IconData?`
/// 编译期过得去、运行期每颗药丸抛一次(真机症状:整片正文变灰/红框)。
/// 这条测试钉住"名字 → 真 IconData"这一步。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/font_awesome_name_mapping.dart';

IconData? resolve(String name) => faIconNameMapping['solid $name']?.data;

void main() {
  test('站点默认图标名解析成 IconData(不是 FaIconData)', () {
    for (final name in ['folder', 'tag', 'droplet', 'code']) {
      final icon = resolve(name);
      expect(icon, isNotNull, reason: '$name 应当能解析');
      expect(icon, isA<IconData>());
    }
  });

  test('认不出来的名字返回 null,交给调用方兜底', () {
    expect(resolve('definitely-not-an-icon'), isNull);
  });

  test('unicode emoji 对照表是合法 JSON', () {
    // 曾经有一行 key 少了引号(`ℹ: "information_source"`),整表加载失败,
    // 裸 Unicode emoji 的站内图片替换全程哑掉。
    final raw = File('assets/emoji/unicode_replacements.json')
        .readAsStringSync();
    expect(() => jsonDecode(raw), returnsNormally);
  });
}
