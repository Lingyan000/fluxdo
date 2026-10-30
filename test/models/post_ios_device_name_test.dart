import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic.dart';

void main() {
  group('Post ios_device_name', () {
    test('parses and trims the device model', () {
      final post = Post.fromJson({
        'id': 1,
        'username': 'tester',
        'ios_device_name': '  iPhone 17 Pro Max  ',
      });

      expect(post.iosDeviceName, 'iPhone 17 Pro Max');
    });

    test('ignores a blank device model', () {
      final post = Post.fromJson({
        'id': 2,
        'username': 'tester',
        'ios_device_name': '   ',
      });

      expect(post.iosDeviceName, isNull);
    });
  });
}
