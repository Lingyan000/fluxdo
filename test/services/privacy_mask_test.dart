import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/ocr/image_mask_renderer.dart';
import 'package:fluxdo/services/ocr/local_ocr_service.dart';
import 'package:fluxdo/services/ocr/privacy_detector.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

OcrTextLine _makeLine(
  String text, {
  required double left,
  required double top,
  required double charWidth,
  double height = 24,
  int rowIndex = 0,
}) {
  final charBounds = <Rect>[
    for (var i = 0; i < text.length; i++)
      Rect.fromLTWH(left + i * charWidth, top, charWidth, height),
  ];
  return OcrTextLine(
    text: text,
    bounds: Rect.fromLTWH(left, top, text.length * charWidth, height),
    charBounds: charBounds,
    rowIndex: rowIndex,
  );
}

void main() {
  group('OcrResult 行拼合与字符定位', () {
    test('同一视觉行用空格连接，跨行换行', () {
      final result = OcrResult(
        imageWidth: 800,
        imageHeight: 400,
        lines: [
          _makeLine('手机号', left: 20, top: 20, charWidth: 20, rowIndex: 0),
          _makeLine('13800138000', left: 200, top: 20, charWidth: 12, rowIndex: 0),
          _makeLine('第二行内容', left: 20, top: 70, charWidth: 20, rowIndex: 1),
        ],
      );
      expect(result.plainText, '手机号 13800138000\n第二行内容');
    });

    test('boundsForRange 精确返回子串像素框', () {
      final line = _makeLine('电话:13800138000', left: 10, top: 40, charWidth: 10);
      final phoneRect = line.boundsForRange(3, 14);
      expect(phoneRect.left, closeTo(40, 0.01));
      expect(phoneRect.right, closeTo(150, 0.01));
      expect(phoneRect.top, 40);
      expect(phoneRect.bottom, 64);
    });
  });

  group('PrivacyDetector 文本隐私规则', () {
    test('准确识别手机号、邮箱、密钥、IP 与有效身份证号并精确定位子串', () {
      final line1 = _makeLine(
        '联系 138-0013-8000 或 alice@example.com',
        left: 20,
        top: 20,
        charWidth: 10,
        rowIndex: 0,
      );
      final line2 = _makeLine(
        'Authorization: Bearer sk-proj-AbCdEf1234567890XyZ',
        left: 20,
        top: 60,
        charWidth: 10,
        rowIndex: 1,
      );
      // 合法 18 位校验位身份证（11010519491231002X）
      final line3 = _makeLine(
        '证件 11010519491231002X 无效 110105194912310021',
        left: 20,
        top: 100,
        charWidth: 10,
        rowIndex: 2,
      );
      final line4 = _makeLine(
        '节点 198.51.100.42 本地 127.0.0.1 版本 v1.2.3.4',
        left: 20,
        top: 140,
        charWidth: 10,
        rowIndex: 3,
      );
      final ocr = OcrResult(
        imageWidth: 900,
        imageHeight: 300,
        lines: [line1, line2, line3, line4],
      );

      final regions = PrivacyDetector.detectText(ocr);
      final byCategory = {
        for (final r in regions) r.category: r.preview,
      };
      expect(byCategory[PrivacyCategory.phone], '138-0013-8000');
      expect(byCategory[PrivacyCategory.email], 'alice@example.com');
      expect(byCategory[PrivacyCategory.secret], 'sk-proj-AbCdEf1234567890XyZ');
      expect(byCategory[PrivacyCategory.idCard], '11010519491231002X');
      expect(byCategory[PrivacyCategory.ipAddress], '198.51.100.42');
      // 无效校验位身份证、127.0.0.1 和 v1.2.3.4 不应误报
      expect(regions.where((r) => r.category == PrivacyCategory.idCard), hasLength(1));
      expect(regions.where((r) => r.category == PrivacyCategory.ipAddress), hasLength(1));

      // 手机号打码框只覆盖手机号子串，不会吞掉左侧的「联系 」
      final phoneRegion = regions.firstWhere((r) => r.category == PrivacyCategory.phone);
      expect(phoneRegion.bounds.left, greaterThan(40));
    });

    test('支持表格同行相邻两段的上下文标签识别', () {
      final ocr = OcrResult(
        imageWidth: 800,
        imageHeight: 200,
        lines: [
          _makeLine('收货地址', left: 20, top: 30, charWidth: 16, rowIndex: 0),
          _makeLine('北京市朝阳区测试路88号', left: 200, top: 30, charWidth: 14, rowIndex: 0),
        ],
      );
      final regions = PrivacyDetector.detectText(ocr);
      expect(regions, hasLength(1));
      expect(regions.first.category, PrivacyCategory.account);
      expect(regions.first.preview, '北京市朝阳区测试路88号');
      expect(regions.first.bounds.left, greaterThan(180));
    });

    test('Luhn 与身份证校验工具函数准确判别真假号段', () {
      expect(PrivacyDetector.isValidChineseIdCard('11010519491231002X'), isTrue);
      expect(PrivacyDetector.isValidChineseIdCard('110105194912310020'), isFalse);
      expect(PrivacyDetector.passesLuhn('4111111111111111'), isTrue);
      expect(PrivacyDetector.passesLuhn('4111111111111112'), isFalse);
      expect(PrivacyDetector.passesLuhn('0000000000000000'), isFalse);
    });
  });

  group('PrivacyDetector 二维码检测与 ImageMaskRenderer 渲染', () {
    test('能定位图片中的二维码并覆盖完整范围', () async {
      final qr = Encoder.encode(
        'https://linux.do/t/topic/12345',
        ErrorCorrectionLevel.m,
      );
      final matrix = qr.matrix!;
      const scale = 6;
      const offsetX = 60;
      const offsetY = 50;
      final canvas = img.Image(width: 360, height: 360);
      img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
      for (var y = 0; y < matrix.height; y++) {
        for (var x = 0; x < matrix.width; x++) {
          if (matrix.get(x, y) == 1) {
            img.fillRect(
              canvas,
              x1: offsetX + x * scale,
              y1: offsetY + y * scale,
              x2: offsetX + (x + 1) * scale - 1,
              y2: offsetY + (y + 1) * scale - 1,
              color: img.ColorRgb8(0, 0, 0),
            );
          }
        }
      }
      final png = Uint8List.fromList(img.encodePng(canvas));
      final regions = await PrivacyDetector.detectQrCodes(png);
      expect(regions, hasLength(1));
      final rect = regions.first.bounds;
      expect(rect.left, lessThanOrEqualTo(offsetX + 10));
      expect(rect.top, lessThanOrEqualTo(offsetY + 10));
      expect(rect.right, greaterThanOrEqualTo(offsetX + matrix.width * scale - 10));
      expect(rect.bottom, greaterThanOrEqualTo(offsetY + matrix.height * scale - 10));
    });

    test('三种打码样式均只修改目标区域，区域外像素保持不变', () async {
      final base = img.Image(width: 120, height: 120);
      for (var y = 0; y < 120; y++) {
        for (var x = 0; x < 120; x++) {
          base.setPixelRgb(x, y, (x * 2) % 256, (y * 2) % 256, ((x + y) * 3) % 256);
        }
      }
      final sourcePng = Uint8List.fromList(img.encodePng(base));
      const maskRect = Rect.fromLTWH(30, 30, 50, 40);

      for (final style in PrivacyMaskStyle.values) {
        final out = await ImageMaskRenderer.render(
          imageBytes: sourcePng,
          rects: const [maskRect],
          style: style,
        );
        final decoded = img.decodeImage(out)!;
        // 区域外像素完全不变
        final outsideBefore = base.getPixel(5, 5);
        final outsideAfter = decoded.getPixel(5, 5);
        expect(outsideAfter.r, outsideBefore.r);
        expect(outsideAfter.g, outsideBefore.g);
        expect(outsideAfter.b, outsideBefore.b);

        // 区域内至少存在像素被修改
        var changed = 0;
        for (var y = 32; y < 68; y++) {
          for (var x = 32; x < 78; x++) {
            final a = base.getPixel(x, y);
            final b = decoded.getPixel(x, y);
            if (a.r != b.r || a.g != b.g || a.b != b.b) changed++;
          }
        }
        expect(changed, greaterThan(100), reason: '样式 $style 应实际遮挡目标区域');
      }
    });

    test('16-bit PNG（Format.uint16）马赛克预览不变纯白、导出不变纯黑', () async {
      final u16 = img.Image(
        width: 120,
        height: 80,
        format: img.Format.uint16,
        numChannels: 4,
      );
      // 暗底 (~24) + 亮字笔画 (~210)
      for (var y = 0; y < 80; y++) {
        for (var x = 0; x < 120; x++) {
          final isStroke = y >= 25 && y <= 55 && (x % 12 < 3);
          final v = isStroke ? 210 * 257 : 24 * 257;
          u16.setPixelRgba(x, y, v, v, v, 65535);
        }
      }
      final png16 = Uint8List.fromList(img.encodePng(u16));

      final grid = await ImageMaskRenderer.buildMosaicPreviewGrid(png16);
      expect(grid, isNotNull);
      var hasDarkTile = false;
      var hasBrightTile = false;
      for (var i = 0; i < grid!.rgba.length; i += 4) {
        final r = grid.rgba[i];
        if (r < 60) hasDarkTile = true;
        if (r > 70 && r < 250) hasBrightTile = true;
      }
      expect(hasDarkTile, isTrue, reason: '预览网格不应全被截断成纯白');
      expect(hasBrightTile, isTrue, reason: '预览网格应保留文字像素颗粒反差');

      final out = await ImageMaskRenderer.render(
        imageBytes: png16,
        rects: const [Rect.fromLTWH(10, 15, 100, 50)],
        style: PrivacyMaskStyle.mosaic,
        encodePng: false,
      );
      final decoded = img.decodeImage(out)!;
      var minR = 255;
      var maxR = 0;
      for (var y = 20; y < 60; y++) {
        for (var x = 15; x < 105; x++) {
          final r = decoded.getPixel(x, y).r.toInt();
          if (r < minR) minR = r;
          if (r > maxR) maxR = r;
        }
      }
      expect(minR, greaterThan(10), reason: '导出马赛克不应坍缩成纯黑 0');
      expect(maxR, greaterThan(70), reason: '导出马赛克应保留清晰亮暗像素颗粒');
    });
  });
}
