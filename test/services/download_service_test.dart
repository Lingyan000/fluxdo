import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/download_service.dart';
import 'package:path/path.dart' as p;

void main() {
  group('DownloadService.resolveFileName', () {
    test('保留安全的建议文件名', () {
      expect(
        DownloadService.resolveFileName(
          'https://example.com/files/fallback.pdf',
          suggestedFilename: '报告 2026.pdf',
        ),
        '报告 2026.pdf',
      );
    });

    test('拒绝跨平台路径和保留设备名并回退到安全 URL 文件名', () {
      const unsafeNames = <String>[
        '../escape.txt',
        r'..\escape.txt',
        '/tmp/escape.txt',
        r'C:\temp\escape.txt',
        r'\\server\share\escape.txt',
        '.',
        '..',
        'NUL.txt',
        'bad:name.txt',
        'trailing.',
        'control\u0000.txt',
      ];

      for (final unsafeName in unsafeNames) {
        expect(
          DownloadService.resolveFileName(
            'https://example.com/files/safe.pdf',
            suggestedFilename: unsafeName,
          ),
          'safe.pdf',
          reason: unsafeName,
        );
      }
    });

    test('拒绝 URL 中解码后出现的跨平台路径分隔符', () {
      const unsafeUrls = <String>[
        'https://example.com/files/%2E%2E%2Fescape.txt',
        'https://example.com/files/%2E%2E%5Cescape.txt',
      ];

      for (final url in unsafeUrls) {
        expect(
          DownloadService.resolveFileName(url),
          matches(RegExp(r'^download_\d+$')),
          reason: url,
        );
      }
    });

    test('Content-Disposition 文件名仍在写入前经过安全检查', () {
      const header = "attachment; filename*=UTF-8''..%2Fescape.txt";
      final parsed = DownloadService.parseContentDisposition(header);

      expect(parsed, '../escape.txt');
      expect(
        DownloadService.resolveFileName(
          'https://example.com/files/safe.pdf',
          suggestedFilename: parsed,
        ),
        'safe.pdf',
      );
    });
  });

  group('DownloadService.resolveAvailableSavePath', () {
    late Directory downloadDirectory;

    setUp(() {
      downloadDirectory = Directory.systemTemp.createTempSync(
        'fluxdo-download-test-',
      );
    });

    tearDown(() {
      downloadDirectory.deleteSync(recursive: true);
    });

    test('目标始终是规范化下载目录的直接子项', () {
      final reservation = DownloadService.reserveAvailableDownload(
        directory: downloadDirectory,
        fileName: 'report.pdf',
      );
      addTearDown(reservation.release);
      final canonicalDirectory = downloadDirectory.resolveSymbolicLinksSync();

      expect(reservation.requestedFileName, 'report.pdf');
      expect(p.dirname(reservation.savePath), canonicalDirectory);
      expect(p.basename(reservation.savePath), 'report.pdf');
      expect(p.dirname(reservation.temporaryPath), canonicalDirectory);
    });

    test('拒绝未经解析器处理的危险文件名', () {
      expect(
        () => DownloadService.reserveAvailableDownload(
          directory: downloadDirectory,
          fileName: '../escape.txt',
        ),
        throwsArgumentError,
      );
    });

    test('已有路径不会被覆盖', () {
      final occupiedPath = p.join(downloadDirectory.path, 'report.pdf');
      File(occupiedPath).writeAsStringSync('existing');

      final reservation = DownloadService.reserveAvailableDownload(
        directory: downloadDirectory,
        fileName: 'report.pdf',
      );
      addTearDown(reservation.release);

      expect(p.basename(reservation.savePath), 'report (1).pdf');
      expect(
        p.dirname(reservation.savePath),
        downloadDirectory.resolveSymbolicLinksSync(),
      );
    });

    test('并发预留同名文件时获得不同路径', () async {
      final reservations = await Future.wait([
        Future(
          () => DownloadService.reserveAvailableDownload(
            directory: downloadDirectory,
            fileName: 'report.pdf',
          ),
        ),
        Future(
          () => DownloadService.reserveAvailableDownload(
            directory: downloadDirectory,
            fileName: 'report.pdf',
          ),
        ),
      ]);
      addTearDown(() async {
        for (final reservation in reservations) {
          await reservation.release();
        }
      });

      expect(
        reservations.map((reservation) => p.basename(reservation.savePath)),
        unorderedEquals(['report.pdf', 'report (1).pdf']),
      );
    });

    test(
      '提交时不会跟随被替换的目标符号链接',
      () async {
        final outsideFile = File(
          p.join(downloadDirectory.parent.path, 'fluxdo-outside-target.txt'),
        )..writeAsStringSync('outside');
        addTearDown(() {
          if (outsideFile.existsSync()) outsideFile.deleteSync();
        });
        final reservation = DownloadService.reserveAvailableDownload(
          directory: downloadDirectory,
          fileName: 'report.pdf',
        );
        addTearDown(reservation.release);
        File(reservation.temporaryPath).writeAsStringSync('downloaded');

        File(reservation.savePath).deleteSync();
        Link(reservation.savePath).createSync(outsideFile.path);

        await reservation.commit();

        expect(outsideFile.readAsStringSync(), 'outside');
        expect(File(reservation.savePath).readAsStringSync(), 'downloaded');
        expect(
          FileSystemEntity.typeSync(reservation.savePath, followLinks: false),
          FileSystemEntityType.file,
        );
      },
      skip: Platform.isWindows ? 'Windows 创建符号链接通常需要额外权限' : false,
    );

    test('释放预留会清理占位文件和临时文件', () async {
      final reservation = DownloadService.reserveAvailableDownload(
        directory: downloadDirectory,
        fileName: 'report.pdf',
      );
      final savePath = reservation.savePath;
      final temporaryPath = reservation.temporaryPath;

      await reservation.release();

      expect(
        FileSystemEntity.typeSync(savePath),
        FileSystemEntityType.notFound,
      );
      expect(
        FileSystemEntity.typeSync(temporaryPath),
        FileSystemEntityType.notFound,
      );
    });

    test('释放预留不会删除后来写入目标路径的文件', () async {
      final reservation = DownloadService.reserveAvailableDownload(
        directory: downloadDirectory,
        fileName: 'report.pdf',
      );
      File(reservation.savePath).writeAsStringSync('other owner');

      await reservation.release();

      expect(File(reservation.savePath).readAsStringSync(), 'other owner');
      expect(
        FileSystemEntity.typeSync(reservation.temporaryPath),
        FileSystemEntityType.notFound,
      );
    });
  });
}
