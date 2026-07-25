import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/ccswitch/ccswitch_launcher.dart';

void main() {
  group('parseProtocolCommandExecutable', () {
    test('parses quoted command', () {
      expect(
        parseProtocolCommandExecutable(
          r'"C:\Users\demo\AppData\Local\Programs\CC Switch\cc-switch.exe" "%1"',
        ),
        r'C:\Users\demo\AppData\Local\Programs\CC Switch\cc-switch.exe',
      );
    });

    test('parses unquoted command', () {
      expect(
        parseProtocolCommandExecutable(r'C:\Apps\cc-switch.exe %1'),
        r'C:\Apps\cc-switch.exe',
      );
    });

    test('returns null for empty', () {
      expect(parseProtocolCommandExecutable(null), isNull);
      expect(parseProtocolCommandExecutable(''), isNull);
    });
  });

  group('isLikelyDebugConsoleBuild', () {
    test('detects cargo debug target', () {
      expect(
        isLikelyDebugConsoleBuild(
          r'D:\CCSWITCH\src-tauri\target\debug\cc-switch.exe',
        ),
        isTrue,
      );
    });

    test('accepts installed GUI path', () {
      expect(
        isLikelyDebugConsoleBuild(
          r'C:\Users\demo\AppData\Local\Programs\CC Switch\cc-switch.exe',
        ),
        isFalse,
      );
    });
  });

  group('resolveCcswitchExecutableWindows', () {
    test('prefers installed LocalAppData path over debug protocol', () {
      final resolved = resolveCcswitchExecutableWindows(
        environment: {
          'LOCALAPPDATA': r'C:\Users\demo\AppData\Local',
        },
        fileExists: (path) =>
            path ==
            r'C:\Users\demo\AppData\Local\Programs\CC Switch\cc-switch.exe',
        protocolCommand:
            r'"D:\CCSWITCH\src-tauri\target\debug\cc-switch.exe" "%1"',
      );
      expect(
        resolved,
        r'C:\Users\demo\AppData\Local\Programs\CC Switch\cc-switch.exe',
      );
    });

    test('falls back to uninstall install location', () {
      final resolved = resolveCcswitchExecutableWindows(
        environment: const {},
        uninstallInstallLocation:
            r'C:\Users\demo\AppData\Local\Programs\CC Switch\',
        fileExists: (path) =>
            path ==
            r'C:\Users\demo\AppData\Local\Programs\CC Switch\cc-switch.exe',
        protocolCommand:
            r'"D:\CCSWITCH\src-tauri\target\debug\cc-switch.exe" "%1"',
      );
      expect(
        resolved,
        r'C:\Users\demo\AppData\Local\Programs\CC Switch\cc-switch.exe',
      );
    });

    test('uses non-debug protocol command when install missing', () {
      final resolved = resolveCcswitchExecutableWindows(
        environment: const {},
        fileExists: (path) =>
            path == r'C:\Program Files\CC Switch\cc-switch.exe',
        protocolCommand: r'"C:\Program Files\CC Switch\cc-switch.exe" "%1"',
      );
      expect(resolved, r'C:\Program Files\CC Switch\cc-switch.exe');
    });
  });
}
