import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/update_service.dart';
import 'package:fluxdo/services/windows_update_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Adapter implements HttpClientAdapter {
  final FutureOr<ResponseBody> Function(RequestOptions) respond;
  final urls = <String>[];
  _Adapter(this.respond);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    urls.add(options.uri.toString());
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const name = 'fluxdo-windows-x86_64-setup.exe';
  const url = 'https://github.com/Lingyan000/fluxdo/releases/download/v2/$name';
  final bytes = utf8.encode('MZ test installer');
  final hash = sha256.convert(bytes).toString();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'FluxDO',
      packageName: 'fluxdo',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  group('release assets', () {
    Map<String, Object?> release({bool digest = true}) => {
      'tag_name': 'v2.0.0',
      'html_url': 'https://github.com/Lingyan000/fluxdo/releases/tag/v2.0.0',
      'body': 'Notes',
      'assets': [
        {'name': 'fluxdo-windows-x86_64.zip', 'browser_download_url': 'zip'},
        {'name': 'unrelated-setup.exe', 'browser_download_url': 'other'},
        {
          'name': name,
          'browser_download_url': url,
          'size': bytes.length,
          if (digest) 'digest': 'sha256:$hash',
        },
        {'name': '$name.sha256', 'browser_download_url': '$url.sha256'},
        {
          'name': 'fluxdo-arm64-v8a.apk',
          'browser_download_url': 'apk',
          'size': 10,
        },
      ],
    };

    test(
      'selects installer, preserves APKs and caches Windows metadata',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final adapter = _Adapter(
          (_) => ResponseBody.fromString(
            jsonEncode(release()),
            200,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
              'etag': ['test'],
            },
          ),
        );
        final service = UpdateService(
          dio: Dio()..httpClientAdapter = adapter,
          prefs: prefs,
        );
        final info = await service.checkForUpdate();
        expect(info.hasUpdate, isTrue);
        expect(info.windowsAsset!.sha256, hash);
        expect(info.windowsAsset!.sha256Url, '$url.sha256');
        expect(info.windowsAsset!.size, bytes.length);
        expect(info.apkAssets.single.architecture, 'arm64-v8a');
        expect(
          UpdateInfo.fromJson(info.toJson()).windowsAsset!.downloadUrl,
          url,
        );
        expect(
          (await service.checkForUpdate(useCache: true)).windowsAsset!.sha256,
          hash,
        );
        expect(adapter.urls, hasLength(1));

        final notModified = _Adapter((_) => ResponseBody.fromString('', 304));
        final cached = await UpdateService(
          dio: Dio()..httpClientAdapter = notModified,
          prefs: prefs,
        ).checkForUpdate();
        expect(cached.windowsAsset!.name, name);
      },
    );

    test(
      'older releases use checksum files and old caches remain readable',
      () async {
        final service = UpdateService(
          dio: Dio()
            ..httpClientAdapter = _Adapter(
              (_) => ResponseBody.fromString(
                jsonEncode(release(digest: false)),
                200,
                headers: {
                  Headers.contentTypeHeader: ['application/json'],
                },
              ),
            ),
        );
        final info = await service.checkForUpdate();
        expect(info.windowsAsset!.sha256, isNull);
        expect(info.windowsAsset!.canVerify, isTrue);
        final oldCache = info.toJson()..remove('windowsAsset');
        expect(UpdateInfo.fromJson(oldCache).windowsAsset, isNull);
      },
    );
  });

  group('verified downloads', () {
    late Directory temporary;
    late _Adapter adapter;
    late WindowsUpdateService service;

    WindowsUpdateAsset asset({
      String? checksum,
      bool includeDigest = true,
      bool includeChecksumUrl = true,
      int? size,
    }) => WindowsUpdateAsset(
      name: name,
      downloadUrl: url,
      size: size ?? bytes.length,
      sha256: includeDigest ? (checksum ?? hash) : null,
      sha256Url: includeChecksumUrl ? '$url.sha256' : null,
    );

    Future<WindowsUpdateDownload> download(
      WindowsUpdateAsset asset, {
      CancelToken? token,
      void Function(WindowsUpdateStage, double?)? progress,
    }) => service.download(
      asset,
      cancelToken: token ?? CancelToken(),
      onProgress: progress ?? (_, _) {},
    );

    setUp(() async {
      temporary = await Directory.systemTemp.createTemp('fluxdo-update-test-');
      adapter = _Adapter(
        (options) => options.uri.path.endsWith('.sha256')
            ? ResponseBody.fromString('$hash  ./$name\n', 200)
            : ResponseBody.fromBytes(
                bytes,
                200,
                headers: {
                  Headers.contentLengthHeader: ['${bytes.length}'],
                },
              ),
      );
      service = WindowsUpdateService(
        dio: Dio()..httpClientAdapter = adapter,
        temporaryDirectory: () async => temporary,
        githubProxy: () async => 'https://proxy.example/',
      );
    });

    tearDown(() async => temporary.delete(recursive: true));

    test('streams verification, prefers API digest, applies proxy and cleans files', () async {
      final stages = <WindowsUpdateStage>[];
      final result = await download(
        asset(),
        progress: (stage, _) => stages.add(stage),
      );
      expect(await result.installer.readAsBytes(), bytes);
      expect(adapter.urls, ['https://proxy.example/$url']);
      expect(
        stages,
        containsAllInOrder([
          WindowsUpdateStage.downloading,
          WindowsUpdateStage.verifying,
        ]),
      );
      await result.delete();
      expect(await temporary.list().toList(), isEmpty);
    });

    test(
      'fetches and enforces sha256sum file when API digest is absent',
      () async {
        final result = await download(asset(includeDigest: false));
        expect(adapter.urls, [
          'https://proxy.example/$url.sha256',
          'https://proxy.example/$url',
        ]);
        await result.delete();
      },
    );

    test('rejects digest mismatch and deletes installer', () async {
      await expectLater(
        download(asset(checksum: '0' * 64)),
        throwsA(
          isA<WindowsUpdateException>().having(
            (e) => e.reason,
            'reason',
            WindowsUpdateFailure.invalidChecksum,
          ),
        ),
      );
      expect(await temporary.list().toList(), isEmpty);
    });

    test('rejects truncated payload', () async {
      await expectLater(
        download(asset(size: bytes.length + 1)),
        throwsA(
          isA<WindowsUpdateException>().having(
            (e) => e.reason,
            'reason',
            WindowsUpdateFailure.sizeMismatch,
          ),
        ),
      );
      expect(await temporary.list().toList(), isEmpty);
    });

    test('never downloads an executable without checksum metadata', () async {
      await expectLater(
        download(asset(includeDigest: false, includeChecksumUrl: false)),
        throwsA(isA<WindowsUpdateException>()),
      );
      expect(adapter.urls, isEmpty);
    });

    test('checksum network failures cannot bypass verification', () async {
      adapter = _Adapter((_) => ResponseBody.fromString('Unavailable', 503));
      service = WindowsUpdateService(
        dio: Dio()..httpClientAdapter = adapter,
        temporaryDirectory: () async => temporary,
        githubProxy: () async => '',
      );
      await expectLater(
        download(asset(includeDigest: false)),
        throwsA(isA<DioException>()),
      );
      expect(adapter.urls, ['$url.sha256']);
      expect(await temporary.list().toList(), isEmpty);
    });

    test('malformed checksum is rejected before download', () async {
      await expectLater(
        download(asset(checksum: '<html>proxy error</html>')),
        throwsA(isA<WindowsUpdateException>()),
      );
      expect(adapter.urls, isEmpty);
    });

    test('cancellation before download sends no request', () async {
      final token = CancelToken()..cancel();
      await expectLater(
        download(asset(), token: token),
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      expect(adapter.urls, isEmpty);
    });

    test('cancellation during verification cleans downloaded files', () async {
      final token = CancelToken();
      await expectLater(
        download(
          asset(),
          token: token,
          progress: (stage, _) {
            if (stage == WindowsUpdateStage.verifying) token.cancel();
          },
        ),
        throwsA(isA<DioException>()),
      );
      expect(await temporary.list().toList(), isEmpty);
    });

    test('each attempt uses an isolated directory', () async {
      final first = await download(asset());
      final second = await download(asset());
      expect(first.installer.path, isNot(second.installer.path));
      await first.delete();
      expect(await second.installer.exists(), isTrue);
      await second.delete();
    });

    test(
      'installer cancellation remains an error and leaves file for retry',
      () async {
        final result = await download(asset());
        const channel = MethodChannel('com.fluxdo/windows_update');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final calls = <String>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'startUpdate') {
            expect(call.arguments, result.installer.path);
            return null;
          }
          return 2;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        await expectLater(
          WindowsUpdateService.install(result),
          throwsA(isA<PlatformException>()),
        );
        expect(calls, ['startUpdate', 'getUpdateExitCode']);
        expect(await result.installer.exists(), isTrue);
        await result.delete();
      },
    );
  });
}
