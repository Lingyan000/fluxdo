import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android 上游不将随包代理 CA 加入应用全局信任', () {
    final xml = File('android/app/src/main/res/xml/network_security_config.xml').readAsStringSync();
    final anchors = RegExp(r'<certificates\s+src="([^"]+)"').allMatches(xml)
        .map((match) => match.group(1)).toList();
    expect(anchors, unorderedEquals(['system', 'user']));
  });
}
