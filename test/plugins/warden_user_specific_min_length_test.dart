import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/plugins/plugins.dart';

ComposerMinLengthContext _context({
  bool hasUserSpecificMinPostLength = false,
}) => ComposerMinLengthContext(
  categoryExtras: const {'warden_min_post_length': 16},
  isFirstPost: false,
  isPrivateMessage: false,
  isPmWithNonHumanUser: false,
  hasUserSpecificMinPostLength: hasUserSpecificMinPostLength,
  maxPostLength: 32000,
);

void main() {
  group('WardenPlugin user-specific minimum precedence', () {
    const plugin = WardenPlugin();

    test('ordinary user still uses category minimum', () {
      expect(plugin.composerMinPostLength(8, _context()), 16);
    });

    test('premium/group-specific minimum wins over category minimum', () {
      expect(
        plugin.composerMinPostLength(
          4,
          _context(hasUserSpecificMinPostLength: true),
        ),
        4,
      );
    });
  });
}
