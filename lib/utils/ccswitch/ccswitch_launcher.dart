import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:win32_registry/win32_registry.dart';

import '../../services/app_link_service.dart';

/// Launch a `ccswitch://` deeplink as close as possible to browser behavior.
///
/// On Windows the protocol may be registered to a debug console build
/// (`target\debug\cc-switch.exe`, subsystem CUI), which pops a terminal.
/// Prefer launching the installed GUI executable directly when available.
Future<bool> launchCcswitchDeeplink(String url) async {
  if (url.trim().isEmpty) return false;

  if (!kIsWeb && Platform.isWindows) {
    final exe = resolveCcswitchExecutableWindows();
    if (exe != null) {
      try {
        await Process.start(
          exe,
          [url],
          mode: ProcessStartMode.detached,
          runInShell: false,
        );
        // Best-effort: keep protocol registration pointing at the GUI build so
        // browser imports behave the same way.
        maybeHealCcswitchProtocolRegistration(exe);
        return true;
      } catch (e) {
        debugPrint('[CCSwitch] direct launch failed: $e');
      }
    }
  }

  return AppLinkService.launchAppLink(url);
}

/// Resolve the preferred installed CC Switch executable on Windows.
///
/// Preference order:
/// 1. `%LOCALAPPDATA%\Programs\CC Switch\cc-switch.exe`
/// 2. Uninstall registry InstallLocation (HKCU/HKLM)
/// 3. Protocol handler command, if it is not a debug/console build
@visibleForTesting
String? resolveCcswitchExecutableWindows({
  Map<String, String>? environment,
  bool Function(String path)? fileExists,
  String? protocolCommand,
  String? uninstallInstallLocation,
}) {
  final env = environment ?? Platform.environment;
  final exists = fileExists ?? ((path) => File(path).existsSync());

  final candidates = <String>[];

  final localAppData = env['LOCALAPPDATA'];
  if (localAppData != null && localAppData.isNotEmpty) {
    candidates.add(
      _joinWindowsPath(localAppData, const [
        'Programs',
        'CC Switch',
        'cc-switch.exe',
      ]),
    );
  }

  final installLocation =
      uninstallInstallLocation ?? _readUninstallInstallLocation();
  if (installLocation != null && installLocation.isNotEmpty) {
    final trimmed = installLocation.replaceAll(RegExp(r'[\\/]+$'), '');
    candidates.add(_joinWindowsPath(trimmed, const ['cc-switch.exe']));
  }

  final command = protocolCommand ?? _readProtocolCommand();
  final protocolExe = parseProtocolCommandExecutable(command);
  if (protocolExe != null && !_isLikelyDebugConsoleBuild(protocolExe)) {
    candidates.add(protocolExe);
  }

  for (final candidate in candidates) {
    final normalized = candidate.trim();
    if (normalized.isEmpty) continue;
    if (exists(normalized)) return normalized;
  }

  // Last resort: protocol command even if it looks like a debug build.
  if (protocolExe != null && exists(protocolExe)) return protocolExe;
  return null;
}

@visibleForTesting
String? parseProtocolCommandExecutable(String? command) {
  if (command == null) return null;
  final trimmed = command.trim();
  if (trimmed.isEmpty) return null;

  // "C:\Path\cc-switch.exe" "%1"
  final quoted = RegExp(r'^"([^"]+\.exe)"', caseSensitive: false)
      .firstMatch(trimmed);
  if (quoted != null) return quoted.group(1);

  // C:\Path\cc-switch.exe "%1"
  final unquoted = RegExp(r'^([^\s"]+\.exe)\b', caseSensitive: false)
      .firstMatch(trimmed);
  return unquoted?.group(1);
}

@visibleForTesting
bool isLikelyDebugConsoleBuild(String path) => _isLikelyDebugConsoleBuild(path);

bool _isLikelyDebugConsoleBuild(String path) {
  final normalized = path.replaceAll('/', r'\').toLowerCase();
  return normalized.contains(r'\target\debug\') ||
      normalized.contains(r'\debug\cc-switch.exe');
}

void maybeHealCcswitchProtocolRegistration(String exePath) {
  if (kIsWeb || !Platform.isWindows) return;
  if (_isLikelyDebugConsoleBuild(exePath)) return;
  try {
    final current = parseProtocolCommandExecutable(_readProtocolCommand());
    if (current != null &&
        !_isLikelyDebugConsoleBuild(current) &&
        _samePath(current, exePath)) {
      return;
    }
    _writeProtocolCommand(exePath);
  } catch (e) {
    debugPrint('[CCSwitch] heal protocol registration failed: $e');
  }
}

String? _readProtocolCommand() {
  try {
    final key = Registry.openPath(
      RegistryHive.currentUser,
      path: r'Software\Classes\ccswitch\shell\open\command',
    );
    try {
      return key.getValueAsString('');
    } finally {
      key.close();
    }
  } catch (_) {
    return null;
  }
}

void _writeProtocolCommand(String exePath) {
  final key = Registry.currentUser.createKey(r'Software\Classes\ccswitch');
  try {
    key.createValue(
      const RegistryValue.string('', 'URL:com.ccswitch.desktop protocol'),
    );
    key.createValue(const RegistryValue.string('URL Protocol', ''));
    final cmdKey = key.createKey(r'shell\open\command');
    try {
      cmdKey.createValue(RegistryValue.string('', '"$exePath" "%1"'));
    } finally {
      cmdKey.close();
    }
  } finally {
    key.close();
  }
}

String? _readUninstallInstallLocation() {
  for (final hive in const [
    RegistryHive.currentUser,
    RegistryHive.localMachine,
  ]) {
    for (final root in const [
      r'Software\Microsoft\Windows\CurrentVersion\Uninstall',
      r'Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
    ]) {
      try {
        final parent = Registry.openPath(hive, path: root);
        try {
          for (final subName in parent.subkeyNames) {
            try {
              final sub = Registry.openPath(
                hive,
                path: '$root\\$subName',
              );
              try {
                final displayName = sub.getValueAsString('DisplayName') ?? '';
                if (!RegExp(r'cc\s*switch', caseSensitive: false)
                    .hasMatch(displayName)) {
                  continue;
                }
                final location = sub.getValueAsString('InstallLocation');
                if (location != null && location.isNotEmpty) return location;
                final icon = sub.getValueAsString('DisplayIcon');
                final fromIcon = parseProtocolCommandExecutable(icon);
                if (fromIcon != null) {
                  return File(fromIcon).parent.path;
                }
              } finally {
                sub.close();
              }
            } catch (_) {
              // keep scanning
            }
          }
        } finally {
          parent.close();
        }
      } catch (_) {
        // try next root/hive
      }
    }
  }
  return null;
}

String _joinWindowsPath(String root, List<String> parts) {
  final buf = StringBuffer(root.replaceAll('/', r'\'));
  for (final part in parts) {
    final current = buf.toString();
    if (!current.endsWith(r'\')) buf.write(r'\');
    buf.write(part);
  }
  return buf.toString();
}

bool _samePath(String a, String b) {
  return a.replaceAll('/', r'\').toLowerCase() ==
      b.replaceAll('/', r'\').toLowerCase();
}
