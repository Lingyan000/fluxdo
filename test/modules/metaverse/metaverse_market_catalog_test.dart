import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/metaverse/market/metaverse_market_catalog.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

void main() {
  const source = MetaverseMarketSource(MetaverseMarketSource.defaultUrl);
  Map<String, Object?> entry() => {
    'id': 'example.notes',
    'name': 'Notes',
    'version': '1.0.0',
    'author': 'Example',
    'summary': 'Notes',
    'apiVersion': 1,
    'repository': 'https://github.com/example/notes',
    'packageUrl': 'https://github.com/example/notes/releases/download/v1.0.0/notes.fluxplugin',
    'sha256': 'a' * 64,
  };

  test('仓库地址、分支目录和索引文件规范化到稳定来源', () {
    expect(
      MetaverseMarketSource.fromInput(
        'https://github.com/Lingyan000/fluxdo-plugins',
      ).url,
      source.url,
    );
    expect(
      MetaverseMarketSource.fromInput(
        'https://github.com/example/plugins/tree/dev/catalog',
      ).url,
      'https://raw.githubusercontent.com/example/plugins/dev/catalog/index.json',
    );
    expect(
      MetaverseMarketSource.fromInput(
        'https://github.com/example/plugins/blob/dev/catalog/index.json',
      ).url,
      'https://raw.githubusercontent.com/example/plugins/dev/catalog/index.json',
    );
    for (final url in [
      'http://example.org/index.json',
      'https://user@example.org/index.json',
      'https://example.org:8080/index.json',
      'https://github.com/example',
      'https://example.org/index.json?secret=1',
    ]) {
      expect(() => MetaverseMarketSource.fromInput(url), throwsFormatException);
    }
  });

  test('索引校验身份、版本、资源地址和摘要', () {
    final raw = entry();
    final parsed = MetaverseMarketEntry.parse(raw, source);
    expect(parsed.id, 'example.notes');
    expect(parsed.newerThan('1.0.0-rc.1'), isTrue);
    expect(parsed.newerThan('1.0.0+build.2'), isFalse);
    for (final invalid in [
      {...raw, 'id': '../notes'},
      {...raw, 'version': '01.0.0'},
      {...raw, 'sha256': 'abc'},
      {
        ...raw,
        'screenshots': ['http://example.org/a.png'],
      },
      {...raw, 'packageUrl': 'https://user:password@example.org/a.fluxplugin'},
    ]) {
      expect(
        () => MetaverseMarketEntry.parse(invalid, source),
        throwsFormatException,
      );
    }
    expect(
      () => MetaverseMarketCatalog.parse({
        'schemaVersion': 1,
        'name': 'Test',
        'plugins': [raw, raw],
      }, source),
      throwsFormatException,
    );
    expect(
      MetaverseMarketEntry.parse({
        ...raw,
        'apiVersion': 999,
      }, source).compatible,
      isFalse,
    );
  });

  test('SemVer 预发布比较正确区分数字、连字符与构建号', () {
    const versions = [
      '1.0.0-alpha',
      '1.0.0-alpha.1',
      '1.0.0-alpha.beta',
      '1.0.0-beta',
      '1.0.0-beta.2',
      '1.0.0-beta.11',
      '1.0.0-rc.1',
      '1.0.0',
    ];
    for (var i = 1; i < versions.length; i++) {
      expect(
        PluginVersion.parse(versions[i])
            .compareTo(PluginVersion.parse(versions[i - 1])),
        greaterThan(0),
      );
    }
    expect(
      PluginVersion.parse('1.0.0--1').compareTo(PluginVersion.parse('1.0.0-1')),
      greaterThan(0),
    );
    for (final version in ['1.0.0-01', '01.0.0', '1.0', '1.0.0-a..b']) {
      expect(() => PluginVersion.parse(version), throwsFormatException);
    }
  });
}
