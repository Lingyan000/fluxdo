import 'dart:typed_data';
import 'dart:ui' show Rect, TextAlign;

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

    test('双栏文档通过 XY-Cut 先读完左栏再读右栏，避免跨栏串行', () {
      final ocr = OcrResult(
        imageWidth: 900,
        imageHeight: 500,
        lines: [
          // 顶部通栏大标题
          _line('双栏技术文档标题', left: 260, top: 20, width: 380, height: 32),
          // 左栏（x: 30..360）
          _line('左栏第一行继续说明', left: 30, top: 100, width: 320, height: 22),
          _line('左栏第二行完整内容', left: 30, top: 130, width: 310, height: 22),
          _line('左栏第三行结束。', left: 30, top: 160, width: 200, height: 22),
          // 右栏（x: 470..800，间距 110px >> 22px）
          _line('右栏第一行独立段落', left: 470, top: 102, width: 320, height: 22),
          _line('右栏第二行接续正文', left: 470, top: 132, width: 310, height: 22),
        ],
      );
      final layout = PictureTextLayout.fromOcr(ocr);
      expect(
        layout.fullText,
        '双栏技术文档标题\n左栏第一行继续说明左栏第二行完整内容左栏第三行结束。\n右栏第一行独立段落右栏第二行接续正文',
      );
      expect(layout.paragraphs, hasLength(3));
    });

    test('识别中文首行缩进、列表独立换行与英文软连字符合并', () {
      final ocr = OcrResult(
        imageWidth: 600,
        imageHeight: 500,
        lines: [
          // 首行缩进 2 字（left: 68 vs 次行 left: 20）
          _line('这是首行缩进的中文段落', left: 68, top: 20, width: 332, height: 22),
          _line('第二行紧贴左边缘自然延续。', left: 20, top: 48, width: 380, height: 22),
          // 编号列表项应各自独立换行
          _line('1. 第一条列表说明', left: 20, top: 82, width: 220, height: 22),
          _line('2. 第二条列表说明', left: 20, top: 110, width: 220, height: 22),
          // 英文软换行连字符修复
          _line('High perfor-', left: 20, top: 170, width: 160, height: 22),
          _line('mance OCR engine', left: 20, top: 198, width: 220, height: 22),
        ],
      );
      final layout = PictureTextLayout.fromOcr(ocr);
      expect(
        layout.fullText,
        '这是首行缩进的中文段落第二行紧贴左边缘自然延续。\n'
        '1. 第一条列表说明\n'
        '2. 第二条列表说明\n'
        'High performance OCR engine',
      );
    });

    test('识别居中对齐多行段落与竖排文字从右到左阅读顺序', () {
      final centeredOcr = OcrResult(
        imageWidth: 600,
        imageHeight: 300,
        lines: [
          _line('欢迎使用智能排版系统', left: 150, top: 40, width: 300, height: 26),
          _line('支持自动对齐检测', left: 190, top: 72, width: 220, height: 26),
        ],
      );
      final centered = PictureTextLayout.fromOcr(centeredOcr);
      expect(centered.paragraphs, hasLength(1));
      expect(centered.paragraphs.single.alignment, TextAlign.center);
      expect(centered.fullText, '欢迎使用智能排版系统支持自动对齐检测');

      OcrTextLine verticalLine(String text, {required double left}) {
        const w = 28.0;
        const h = 120.0;
        final charH = h / text.length;
        return OcrTextLine(
          text: text,
          bounds: Rect.fromLTWH(left, 20, w, h),
          charBounds: [
            for (var i = 0; i < text.length; i++)
              Rect.fromLTWH(left, 20 + i * charH, w, charH),
          ],
          rowIndex: 0,
        );
      }

      final vertOcr = OcrResult(
        imageWidth: 300,
        imageHeight: 200,
        lines: [
          verticalLine('春眠不觉晓', left: 160),
          verticalLine('处处闻啼鸟', left: 110),
        ],
      );
      final vert = PictureTextLayout.fromOcr(vertOcr);
      expect(vert.lineDirections, everyElement(OcrTextDirection.vertical));
      // 竖排应从右到左先读右列「春眠不觉晓」，再读左列「处处闻啼鸟」
      expect(vert.fullText, '春眠不觉晓处处闻啼鸟');
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
      expect(blocks.last.sourceRows, hasLength(2));
      expect(blocks.last.sourceFontSize, closeTo(20 * 0.85, 0.01));
    });

    test('groupBlocks 识别居中段落对齐方式并保留各原行矩形', () {
      final ocr = OcrResult(
        imageWidth: 800,
        imageHeight: 300,
        lines: [
          _line(
            'Welcome to the next generation',
            left: 200,
            top: 40,
            width: 400,
            height: 24,
          ),
          _line(
            'image translation engine',
            left: 250,
            top: 72,
            width: 300,
            height: 24,
          ),
        ],
      );
      final blocks = ImageTranslationService.groupBlocks(ocr);
      expect(blocks, hasLength(1));
      expect(blocks.single.textAlign, TextAlign.center);
      expect(blocks.single.sourceRows, hasLength(2));
      expect(
        blocks.single.originalText,
        'Welcome to the next generation image translation engine',
      );
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
