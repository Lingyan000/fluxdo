import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/ocr/image_translation_service.dart';
import 'package:fluxdo/services/ocr/local_ocr_service.dart';
import 'package:fluxdo/services/ocr/picture_text_layout.dart';
import 'package:image/image.dart' as img;

OcrTextLine _line(
  String text, {
  required double left,
  required double top,
  required double width,
  double height = 24,
  int rowIndex = 0,
}) {
  final charW = text.isEmpty ? width : width / text.length;
  return OcrTextLine(
    text: text,
    bounds: Rect.fromLTWH(left, top, width, height),
    charBounds: [
      for (var i = 0; i < text.length; i++)
        Rect.fromLTWH(left + i * charW, top, charW, height),
    ],
    rowIndex: rowIndex,
  );
}

void main() {
  group('PictureTextLayout 排版与选区', () {
    test('同段落自动合并、分段换行且中英数字间自动补空格', () {
      final ocr = OcrResult(
        imageWidth: 600,
        imageHeight: 400,
        lines: [
          _line('使用FluxDO版本2', left: 20, top: 20, width: 220, height: 24),
          _line('继续同一段落', left: 22, top: 50, width: 160, height: 24),
          _line('下一段落标题', left: 20, top: 140, width: 160, height: 24),
        ],
      );
      final layout = PictureTextLayout.fromOcr(ocr);
      expect(layout.fullText, '使用 FluxDO 版本 2 继续同一段落\n下一段落标题');
    });

    test('相邻字符格无缝拼接且支持坐标命中与整行选取', () {
      final ocr = OcrResult(
        imageWidth: 400,
        imageHeight: 200,
        lines: [
          _line('Hello', left: 40, top: 30, width: 100, height: 24),
          _line('World', left: 40, top: 100, width: 100, height: 24),
        ],
      );
      final layout = PictureTextLayout.fromOcr(ocr);
      // 同一行内相邻字符格左右严丝合缝
      for (var i = 0; i < 4; i++) {
        expect(
          layout.glyphs[i].bounds.right,
          closeTo(layout.glyphs[i + 1].bounds.left, 0.001),
        );
      }
      final hit = layout.glyphAt(90, 42, reach: 10);
      expect(hit, isNotNull);
      final range = layout.lineRangeOf(hit!);
      expect(layout.extractText(range.start, range.end), 'Hello');
      // 跨行选区返回两段高亮矩形
      expect(layout.selectionRects(2, 7), hasLength(2));
    });
  });

  group('ImageTranslationService 区块聚合、解析与配色采样', () {
    test('表格多列和带徽章的下拉列表保持逐行独立，真段落合并，纯程序名和 IP 自动跳过', () {
      final ocr = OcrResult(
        imageWidth: 800,
        imageHeight: 500,
        lines: [
          // 菜单栏同一行两项：不合并
          _line('File', left: 20, top: 10, width: 40, height: 20),
          _line('Profile', left: 90, top: 10, width: 60, height: 20),
          // 带右侧徽章的下拉菜单项：每行独立，绝不合并成一大坨
          _line('Model Alpha', left: 20, top: 60, width: 130, height: 20),
          _line('New', left: 170, top: 60, width: 32, height: 20),
          _line('Model Beta', left: 20, top: 86, width: 120, height: 20),
          _line('Deprecated', left: 170, top: 86, width: 80, height: 20),
          // 真实宽行多行段落：合并为一块
          _line(
            'This is a long wrapped paragraph line',
            left: 360,
            top: 150,
            width: 300,
            height: 20,
          ),
          _line(
            'continuing onto the second line',
            left: 362,
            top: 175,
            width: 260,
            height: 20,
          ),
          // 技术标识：跳过
          _line('codex.exe', left: 40, top: 240, width: 90, height: 20),
          _line('127.0.0.1', left: 200, top: 240, width: 90, height: 20),
        ],
      );
      final blocks = ImageTranslationService.groupBlocks(ocr);
      expect(blocks.map((b) => b.originalText), [
        'File',
        'Profile',
        'Model Alpha',
        'New',
        'Model Beta',
        'Deprecated',
        'This is a long wrapped paragraph line continuing onto the second line',
      ]);
      expect(blocks.last.lineCount, 2);
    });

    test('parseIndexedTranslations 正确解析带编号与全角括号译文', () {
      final parsed = ImageTranslationService.parseIndexedTranslations(
        '[0] 文件\n【1】 配置\n[2] 代理服务',
        [0, 1, 2],
      );
      expect(parsed, {0: '文件', 1: '配置', 2: '代理服务'});
    });

    test('sampleBlockColors 从彩色底块与 16-bit PNG 准确提取背景与高对比文字色', () async {
      // 构造 16-bit PNG：左块白底黑字，右块蓝底白字
      final canvas = img.Image(
        width: 240,
        height: 80,
        format: img.Format.uint16,
        numChannels: 4,
      );
      for (var y = 0; y < 80; y++) {
        for (var x = 0; x < 240; x++) {
          if (x < 120) {
            final isText = y >= 25 && y <= 55 && x >= 20 && x <= 100 && (x % 8 < 2);
            final v = isText ? 20 * 257 : 248 * 257;
            canvas.setPixelRgba(x, y, v, v, v, 65535);
          } else {
            final isText = y >= 25 && y <= 55 && x >= 140 && x <= 220 && (x % 8 < 2);
            if (isText) {
              canvas.setPixelRgba(x, y, 250 * 257, 250 * 257, 250 * 257, 65535);
            } else {
              canvas.setPixelRgba(x, y, 0, 120 * 257, 215 * 257, 65535);
            }
          }
        }
      }
      final png16 = Uint8List.fromList(img.encodePng(canvas));
      final colors = await ImageTranslationService.sampleBlockColors(
        png16,
        const [
          Rect.fromLTWH(15, 20, 90, 40),
          Rect.fromLTWH(135, 20, 90, 40),
        ],
      );
      expect(colors, hasLength(2));
      // 左块：浅白背景 + 深色前景
      expect(colors[0].bg.r, greaterThan(0.85));
      expect(colors[0].fg.r, lessThan(0.3));
      // 右块：蓝色背景 + 浅白前景
      expect(colors[1].bg.b, greaterThan(0.7));
      expect(colors[1].bg.r, lessThan(0.2));
      expect(colors[1].fg.r, greaterThan(0.8));
    });
  });
}
