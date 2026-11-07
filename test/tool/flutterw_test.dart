import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final projectRoot = Directory.current;
  final packageConfig = File('.dart_tool/package_config.json').absolute;
  final packages = jsonDecode(packageConfig.readAsStringSync()) as Map;
  final flutterPackage = (packages['packages'] as List).cast<Map>().firstWhere(
    (package) => package['name'] == 'flutter',
  );
  final dartExecutable = File.fromUri(
    packageConfig.uri
        .resolve('${flutterPackage['rootUri']}/')
        .resolve(
          '../../bin/cache/dart-sdk/bin/${Platform.isWindows ? 'dart.exe' : 'dart'}',
        ),
  ).path;

  const phone = {
    'id': 'phone-1234',
    'name': 'Pixel 9',
    'targetPlatform': 'android-arm64',
    'isSupported': true,
  };
  const windows = {
    'id': 'windows',
    'name': 'Windows',
    'targetPlatform': 'windows-x64',
    'isSupported': true,
  };
  const chrome = {
    'id': 'chrome',
    'name': 'Chrome',
    'targetPlatform': 'web-javascript',
    'isSupported': true,
  };
  const emulator = {
    'id': 'emulator-5554',
    'name': 'Android Emulator',
    'targetPlatform': 'android-x64',
    'isSupported': true,
  };

  late Directory workspace;
  late File callsFile;
  late Map<String, String> environment;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('fluxdo_flutterw_test_');
    for (final directory in ['tool', 'android', 'windows', 'web']) {
      Directory('${workspace.path}/$directory').createSync();
    }
    for (final name in [
      'flutterw.dart',
      '_workspace_cli.dart',
      '_cli_ui.dart',
    ]) {
      File('${projectRoot.path}/tool/$name')
          .copySync('${workspace.path}/tool/$name');
    }
    const recordCall = '''
import 'dart:convert';
import 'dart:io';
void main(List<String> args) {
  final script = Platform.script.pathSegments.last;
  if (script == 'fake_flutter.dart' && args.first == 'devices') {
    if (Platform.environment['FLUXDO_TEST_DISCOVERY_FAIL'] == 'true') {
      stderr.writeln('device discovery failed');
      exit(7);
    }
    stdout.write(Platform.environment['FLUXDO_TEST_DEVICES']);
    return;
  }
  File(Platform.environment['FLUXDO_TEST_CALLS']!).writeAsStringSync(
    jsonEncode([script, ...args]) + '\\n', mode: FileMode.append,
  );
  if (script == 'project_tasks.dart') {
    exit(int.parse(Platform.environment['FLUXDO_TEST_NATIVE_EXIT'] ?? '0'));
  }
}
''';
    for (final path in [
      'tool/project_prep.dart',
      'tool/project_tasks.dart',
      'fake_flutter.dart',
    ]) {
      File('${workspace.path}/$path').writeAsStringSync(recordCall);
    }
    final launcher = File(
      '${workspace.path}/${Platform.isWindows ? 'flutter.cmd' : 'flutter'}',
    );
    launcher.writeAsStringSync(
      Platform.isWindows
          ? '@"%FLUXDO_TEST_DART%" "%~dp0fake_flutter.dart" %*\r\n'
          : '#!/bin/sh\nexec "\$FLUXDO_TEST_DART" "\$(dirname "\$0")/fake_flutter.dart" "\$@"\n',
    );
    if (!Platform.isWindows) {
      final result = await Process.run('chmod', ['+x', launcher.path]);
      expect(result.exitCode, 0);
    }
    callsFile = File('${workspace.path}/calls.jsonl');
    environment = {
      'FLUTTER_BIN': launcher.path,
      'FLUXDO_TEST_DART': dartExecutable,
      'FLUXDO_TEST_CALLS': callsFile.path,
      'FLUXDO_TEST_DEVICES': jsonEncode([phone, windows, chrome]),
      'FLUXDO_CLI_FORCE_PLAIN': 'true',
      'FLUXDO_CLI_TEST_INPUTS': 'q',
      'DART_SUPPRESS_ANALYTICS': 'true',
    };
  });

  tearDown(() async {
    await workspace.delete(recursive: true);
  });

  Future<ProcessResult> run(List<String> args) => Process.run(
    dartExecutable,
    [
      '--packages=${packageConfig.path}',
      '${workspace.path}/tool/flutterw.dart',
      ...args,
    ],
    workingDirectory: workspace.path,
    environment: environment,
  );

  List<List<dynamic>> calls() => callsFile
      .readAsLinesSync()
      .map((line) => jsonDecode(line) as List<dynamic>)
      .toList();

  test(
    'run prepares the phone core before Flutter when desktops are also present',
    () async {
      final result = await run(['run', '--profile']);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(calls(), [
        ['project_prep.dart', 'app'],
        [
          'project_tasks.dart',
          'native:prepare',
          'android',
          '--profile',
          '--target-platform=android-arm64',
        ],
        ['fake_flutter.dart', 'run', '--profile', '-d', 'phone-1234'],
      ]);
    },
  );

  for (final selector in [
    ['-d', 'PHONE-'],
    ['--device-id=Pixel'],
    ['-d=phone-1234'],
  ]) {
    test(
      'run resolves device selector $selector before preparing the core',
      () async {
        final result = await run(['run', ...selector]);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(calls()[1], contains('--target-platform=android-arm64'));
        expect(calls().last.join(' '), contains('phone-1234'));
      },
    );
  }

  test(
    'multiple phones are selected before preparing the chosen architecture',
    () async {
      environment['FLUXDO_TEST_DEVICES'] = jsonEncode([
        phone,
        emulator,
        windows,
      ]);
      environment['FLUXDO_CLI_TEST_INPUTS'] = '2';
      final result = await run(['run']);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(calls()[1], contains('--target-platform=android-x64'));
      expect(calls().last, ['fake_flutter.dart', 'run', '-d', 'emulator-5554']);
    },
  );

  test(
    'all prepares each native architecture before starting Flutter',
    () async {
      environment['FLUXDO_TEST_DEVICES'] = jsonEncode([
        phone,
        emulator,
        windows,
        chrome,
      ]);
      final result = await run(['run', '-d', 'all']);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(calls().length, 5);
      expect(calls()[1], contains('--target-platform=android-arm64'));
      expect(calls()[2], contains('--target-platform=android-x64'));
      expect(calls()[3], [
        'project_tasks.dart',
        'native:prepare',
        'windows',
        '--debug',
      ]);
      expect(calls().last, ['fake_flutter.dart', 'run', '-d', 'all']);
    },
  );

  test('device discovery failure stops before running Flutter', () async {
    environment['FLUXDO_TEST_DISCOVERY_FAIL'] = 'true';
    final result = await run(['run']);
    expect(result.exitCode, 7);
    expect(calls(), [
      ['project_prep.dart', 'app'],
    ]);
  });

  test('native preparation failure stops before running Flutter', () async {
    environment['FLUXDO_TEST_NATIVE_EXIT'] = '9';
    final result = await run(['run']);
    expect(result.exitCode, 9);
    expect(calls().length, 2);
    expect(calls().last.first, 'project_tasks.dart');
  });

  test('explicit web target runs without native preparation', () async {
    final result = await run(['run', '-d', 'chrome']);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(calls(), [
      ['project_prep.dart', 'app'],
      ['fake_flutter.dart', 'run', '-d', 'chrome'],
    ]);
  });

  test(
    'apk builds keep preparing the requested Android architecture',
    () async {
      final result = await run([
        'build',
        'apk',
        '--release',
        '--target-platform',
        'android-arm64',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(calls()[1], [
        'project_tasks.dart',
        'native:prepare',
        'android',
        '--release',
        '--target-platform=android-arm64',
      ]);
    },
  );
}
