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
      final savePath = DownloadService.resolveAvailableSavePath(
        directory: downloadDirectory,
        fileName: 'report.pdf',
      );
      final canonicalDirectory = downloadDirectory.resolveSymbolicLinksSync();

      expect(p.dirname(savePath), canonicalDirectory);
      expect(p.basename(savePath), 'report.pdf');
    });

    test('拒绝未经解析器处理的危险文件名', () {
      expect(
        () => DownloadService.resolveAvailableSavePath(
          directory: downloadDirectory,
          fileName: '../escape.txt',
        ),
        throwsArgumentError,
      );
    });

    test('已有路径不会被覆盖', () {
      final occupiedPath = p.join(downloadDirectory.path, 'report.pdf');
      File(occupiedPath).writeAsStringSync('existing');

      final savePath = DownloadService.resolveAvailableSavePath(
        directory: downloadDirectory,
        fileName: 'report.pdf',
      );

      expect(p.basename(savePath), 'report (1).pdf');
      expect(p.dirname(savePath), downloadDirectory.resolveSymbolicLinksSync());
    });
  });
}
