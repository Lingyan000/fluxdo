import 'dart:convert';
import 'dart:io';

import '_cli_ui.dart';
import '_workspace_cli.dart';

const _commandsRequiringAppPrep = {'run', 'build', 'drive'};
const _commandsRequiringTestPrep = {'test'};

Future<void> main(List<String> args) async {
  enterWorkspaceRoot();
  args = List.of(args);

  if (args.isEmpty) {
    stderr.writeln('用法: dart tool/flutterw.dart <flutter args...>');
    exit(64);
  }

  final command = _firstFlutterCommand(args);
  if (command != null && _commandsRequiringAppPrep.contains(command)) {
    await runOrExit(
      title: '执行项目预处理',
      executable: Platform.resolvedExecutable,
      arguments: const ['tool/project_prep.dart', 'app'],
    );
    await _runNativePrepIfNeeded(command, args);
  } else if (command != null && _commandsRequiringTestPrep.contains(command)) {
    await runOrExit(
      title: '执行测试预处理',
      executable: Platform.resolvedExecutable,
      arguments: const ['tool/project_prep.dart', 'test'],
    );
  }

  await runFlutterOrExit(
    title: '执行 flutter ${args.join(' ')}',
    arguments: args,
  );
}

Future<void> _runNativePrepIfNeeded(String command, List<String> args) async {
  final targets = await _detectNativeTargets(command, args);
  final prepared = <String>{};
  for (final target in targets) {
    final key = '${target.platform}/${target.androidTargetPlatform}';
    if (prepared.add(key)) {
      await _prepareNativeTarget(target, command, args);
    }
  }
}

Future<void> _prepareNativeTarget(
  _NativeTarget target,
  String command,
  List<String> args,
) async {
  final buildMode = _detectBuildMode(command, args);
  final nativeArgs = <String>[
    'tool/project_tasks.dart',
    'native:prepare',
    target.platform,
    buildMode,
  ];
  if (target.platform == 'android') {
    final targetPlatform =
        _extractOptionValue(args, '--target-platform', '--target-platform') ??
        target.androidTargetPlatform;
    if (targetPlatform != null && targetPlatform.isNotEmpty) {
      nativeArgs.add('--target-platform=$targetPlatform');
    }
  } else if (target.platform == 'macos') {
    final macOsArch = target.macOsArch;
    if (macOsArch != null && macOsArch.isNotEmpty) {
      nativeArgs.add('--arch=$macOsArch');
    }
  }
  await runOrExit(
    title: '准备 ${target.platform} 原生产物',
    executable: Platform.resolvedExecutable,
    arguments: nativeArgs,
  );
}

String? _firstFlutterCommand(List<String> args) {
  for (final arg in args) {
    if (!arg.startsWith('-')) {
      return arg;
    }
  }
  return null;
}

String? _macOsArchFromEnv() {
  final value = Platform.environment['FLUXDO_MACOS_ARCH']?.trim();
  return (value == null || value.isEmpty) ? null : value;
}

Future<List<_NativeTarget>> _detectNativeTargets(
  String command,
  List<String> args,
) async {
  switch (command) {
    case 'build':
      final buildTarget = _firstPositionalAfter(args, 'build');
      final target = switch (buildTarget) {
        'windows' => const _NativeTarget('windows'),
        'macos' => _NativeTarget('macos', macOsArch: _macOsArchFromEnv()),
        'linux' => const _NativeTarget('linux'),
        'ios' || 'ipa' => const _NativeTarget('ios'),
        'apk' || 'appbundle' || 'aar' => const _NativeTarget('android'),
        _ => null,
      };
      return [?target];
    case 'run':
    case 'drive':
      final deviceId = _extractOptionValue(args, '-d', '--device-id');
      final directTarget = switch (deviceId) {
        'windows' => const _NativeTarget('windows'),
        'macos' => _NativeTarget('macos', macOsArch: _macOsArchFromEnv()),
        'linux' => const _NativeTarget('linux'),
        'android' => const _NativeTarget('android'),
        'ios' => const _NativeTarget('ios'),
        _ => null,
      };
      if (directTarget != null) {
        return [directTarget];
      }
      if (const ['chrome', 'edge', 'web-server'].contains(deviceId)) {
        return const [];
      }

      final devices = await _selectRunDevices(args, deviceId);
      return devices
          .map(_nativeTargetFromDevice)
          .whereType<_NativeTarget>()
          .toList();
    default:
      return const [];
  }
}

Future<List<_FlutterDevice>> _selectRunDevices(
  List<String> args,
  String? deviceId,
) async {
  var devices = await _loadFlutterDevices(args);
  if (deviceId == null || deviceId == 'all') {
    devices = devices.where((device) {
      final platform = _nativeTargetFromDevice(device)?.platform;
      if (platform != null) return Directory(platform).existsSync();
      return deviceId != 'all' &&
          device.targetPlatform.startsWith('web') &&
          Directory('web').existsSync();
    }).toList();
  } else {
    final query = deviceId.toLowerCase();
    final exact = devices.where(
      (device) =>
          device.id.toLowerCase() == query ||
          device.name.toLowerCase() == query,
    );
    devices = exact.isNotEmpty
        ? [exact.first]
        : devices.where((device) {
            return device.id.toLowerCase().startsWith(query) ||
                device.name.toLowerCase().startsWith(query);
          }).toList();
  }

  if (devices.isEmpty) {
    stderr.writeln('未找到匹配的运行设备，请检查连接或使用 -d 指定设备。');
    exit(1);
  }
  if (deviceId == 'all') return devices;

  // Flutter 在未指定设备时优先选择唯一的手机或模拟器。
  if (deviceId == null) {
    final mobileDevices = devices
        .where(
          (device) =>
              device.targetPlatform.startsWith('android') ||
              device.targetPlatform == 'ios',
        )
        .toList();
    if (mobileDevices.length == 1) devices = mobileDevices;
  }

  final selected = devices.length == 1
      ? devices.single
      : await CliUi().select<_FlutterDevice>(
          title: '选择运行设备',
          options: [
            for (final device in devices)
              CliOption(
                value: device,
                label: device.name,
                detail: '${device.id} (${device.targetPlatform})',
                aliases: [device.id],
              ),
          ],
        );
  if (selected == null) exit(0);

  // 把本次选择传给 Flutter，确保启动设备与预先编译的核心一致。
  _setRunDevice(args, selected.id);
  return [selected];
}

void _setRunDevice(List<String> args, String deviceId) {
  for (var index = 0; index < args.length; index++) {
    final arg = args[index];
    if (arg == '-d' || arg == '--device-id') {
      args[index + 1] = deviceId;
      return;
    }
    if (arg.startsWith('--device-id=') || arg.startsWith('-d=')) {
      args[index] = '--device-id=$deviceId';
      return;
    }
  }
  final separator = args.indexOf('--');
  args.insertAll(separator == -1 ? args.length : separator, ['-d', deviceId]);
}

String _detectBuildMode(String command, List<String> args) {
  if (args.contains('--debug')) {
    return '--debug';
  }
  if (args.contains('--profile')) {
    return '--profile';
  }
  if (args.contains('--release')) {
    return '--release';
  }
  return command == 'run' ? '--debug' : '--release';
}

String? _firstPositionalAfter(List<String> args, String command) {
  final commandIndex = args.indexOf(command);
  if (commandIndex == -1) {
    return null;
  }

  for (var index = commandIndex + 1; index < args.length; index++) {
    final value = args[index];
    if (!value.startsWith('-')) {
      return value;
    }
  }
  return null;
}

String? _extractOptionValue(
  List<String> args,
  String shortOption,
  String longOption,
) {
  for (var index = 0; index < args.length; index++) {
    final value = args[index];
    if (value == shortOption || value == longOption) {
      if (index + 1 < args.length) {
        return args[index + 1];
      }
      return null;
    }
    if (value.startsWith('$longOption=') || value.startsWith('$shortOption=')) {
      return value.substring(value.indexOf('=') + 1);
    }
  }
  return null;
}

Future<List<_FlutterDevice>> _loadFlutterDevices(List<String> args) async {
  try {
    final discoveryArgs = ['devices', '--machine'];
    for (final option in ['--device-timeout', '--device-connection']) {
      final value = _extractOptionValue(args, option, option);
      if (value != null) discoveryArgs.add('$option=$value');
    }
    final result = await Process.run(
      flutterExecutable,
      discoveryArgs,
      runInShell: Platform.isWindows,
      environment: await androidBuildEnvironment(),
      workingDirectory: workspaceRootPath,
    );
    if (result.exitCode != 0) {
      stderr.write(result.stderr);
      stderr.writeln('读取 Flutter 设备列表失败，无法准备网络核心。');
      exit(result.exitCode);
    }

    final decoded = jsonDecode(result.stdout.toString());
    if (decoded is! List) {
      throw const FormatException('设备列表不是 JSON 数组');
    }

    return decoded
        .whereType<Map>()
        .map((item) => _FlutterDevice.fromJson(item.cast<String, dynamic>()))
        .whereType<_FlutterDevice>()
        .toList();
  } catch (error) {
    stderr.writeln('读取 Flutter 设备列表失败，无法准备网络核心。$error');
    exit(1);
  }
}

_NativeTarget? _nativeTargetFromDevice(_FlutterDevice device) {
  final targetPlatform = device.targetPlatform;
  if (targetPlatform.startsWith('android')) {
    return _NativeTarget('android', androidTargetPlatform: targetPlatform);
  }
  if (targetPlatform == 'ios') {
    return const _NativeTarget('ios');
  }
  if (targetPlatform.startsWith('darwin')) {
    return _NativeTarget('macos', macOsArch: _macOsArchFromEnv());
  }
  if (targetPlatform.startsWith('windows')) {
    return const _NativeTarget('windows');
  }
  if (targetPlatform.startsWith('linux')) {
    return const _NativeTarget('linux');
  }
  return null;
}

class _NativeTarget {
  const _NativeTarget(
    this.platform, {
    this.androidTargetPlatform,
    this.macOsArch,
  });

  final String platform;
  final String? androidTargetPlatform;
  final String? macOsArch;
}

class _FlutterDevice {
  const _FlutterDevice({
    required this.id,
    required this.name,
    required this.targetPlatform,
  });

  final String id;
  final String name;
  final String targetPlatform;

  static _FlutterDevice? fromJson(Map<String, dynamic> json) {
    if (json['isSupported'] == false) return null;
    final id = json['id']?.toString().trim();
    final targetPlatform = json['targetPlatform']?.toString().trim();
    if (id == null ||
        id.isEmpty ||
        targetPlatform == null ||
        targetPlatform.isEmpty) {
      return null;
    }
    return _FlutterDevice(
      id: id,
      name: json['name']?.toString() ?? id,
      targetPlatform: targetPlatform,
    );
  }
}
