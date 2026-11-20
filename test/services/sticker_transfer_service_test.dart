import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/sticker.dart';
import 'package:fluxdo/services/sticker_transfer_service.dart';
import 'package:fluxdo/utils/url_helper.dart';
import 'package:shared_preferences/shared_preferences.dart';

StickerItem _item(String url) => StickerItem(
  id: 'id',
  name: '猫猫/叹气.gif',
  url: url,
  width: 10,
  height: 10,
  groupId: 'g',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late List<String> downloads;
  late List<String> uploads;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('sticker-transfer-');
    downloads = [];
    uploads = [];
    UrlHelper.debugSetOverrides(s3CdnUrl: 'https://cdn3.forum.example');
  });

  tearDown(() async {
    UrlHelper.debugSetOverrides();
    await temp.delete(recursive: true);
  });

  Future<StickerTransferService> newService({bool ready = true}) async {
    SharedPreferences.setMockInitialValues({});
    return StickerTransferService(
      await SharedPreferences.getInstance(),
      siteConfigReady: () => ready,
      tempDirectory: () async => temp,
      download: (url) async {
        downloads.add(url);
        return Uint8List.fromList([0x47, 0x49, 0x46, 0x38, 0, 0]);
      },
      upload: (path) async {
        uploads.add(path.split('/').last);
        expect(File(path).existsSync(), isTrue);
        return (
          url: 'https://cdn3.forum.example/original/x.gif',
          width: 64,
          height: 48,
        );
      },
    );
  }

  test('论坛自己的 CDN 不转存,外站转存;站点配置未就绪时一律不转存', () async {
    final service = await newService();
    expect(
      service.needsTransfer('https://cdn3.forum.example/original/a.png'),
      isFalse,
    );
    expect(service.needsTransfer('https://idcflare.com/uploads/a.png'), isTrue);
    expect(service.needsTransfer('upload://abc.png'), isFalse);

    final notReady = await newService(ready: false);
    expect(
      notReady.needsTransfer('https://idcflare.com/uploads/a.png'),
      isFalse,
    );
  });

  test('转存后换成论坛地址与尺寸,同一张图只传一次,临时文件清理', () async {
    final service = await newService();
    final item = _item('https://idcflare.com/uploads/a.png');

    final first = await service.transfer(item);
    final second = await service.transfer(item);

    expect(first.url, 'https://cdn3.forum.example/original/x.gif');
    expect((first.width, first.height), (64, 48));
    expect(second.url, first.url);
    expect(downloads, hasLength(1));
    expect(uploads, ['猫猫_叹气.gif'], reason: '文件名去掉路径分隔,扩展名按文件头');
    expect(service.cached(item)?.url, first.url);
    expect(Directory('${temp.path}/sticker_transfer').listSync(), isEmpty);
  });

  test('扩展名先按文件头判断,认不出再看地址', () {
    Uint8List bytes(List<int> b) => Uint8List.fromList([...b, 0, 0, 0, 0]);
    expect(
      StickerTransferService.extensionOf(
        'https://x/a',
        bytes([0x89, 0x50, 0x4E, 0x47]),
      ),
      'png',
    );
    expect(
      StickerTransferService.extensionOf(
        'https://x/a',
        Uint8List.fromList([
          ...'RIFF'.codeUnits,
          0,
          0,
          0,
          0,
          ...'WEBP'.codeUnits,
        ]),
      ),
      'webp',
    );
    expect(
      StickerTransferService.extensionOf('https://x/a.JPEG', bytes([1, 2])),
      'jpeg',
    );
    expect(
      StickerTransferService.extensionOf('https://x/media?f=1', bytes([1])),
      'png',
    );
  });
}
