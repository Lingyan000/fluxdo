import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

import 'local_ocr_service.dart';

/// 隐私区域类别。
enum PrivacyCategory {
  phone,
  email,
  idCard,
  bankCard,
  secret,
  ipAddress,
  account,
  qrCode,
  manual,
}

/// 单个可打码区域（原图像素坐标系）。
class PrivacyRegion {
  const PrivacyRegion({
    required this.id,
    required this.category,
    required this.bounds,
    this.preview = '',
    this.enabled = true,
  });

  final String id;
  final PrivacyCategory category;
  final Rect bounds;
  final String preview;
  final bool enabled;

  PrivacyRegion copyWith({bool? enabled, Rect? bounds}) => PrivacyRegion(
    id: id,
    category: category,
    bounds: bounds ?? this.bounds,
    preview: preview,
    enabled: enabled ?? this.enabled,
  );
}

/// 纯本地隐私检测引擎：基于 OCR 文本字符坐标匹配文字类隐私，并用 ZXing 检测二维码。
abstract final class PrivacyDetector {
  static final _phoneRegex = RegExp(
    r'(?<!\d)(?:\+?86[-\s]?)?1[3-9]\d(?:[-\s]?\d{4}){2}(?!\d)',
  );
  static final _emailRegex = RegExp(
    r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}',
  );
  static final _idCardRegex = RegExp(
    r'(?<![0-9A-Za-z])[1-9]\d{5}(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[\dXx](?![0-9A-Za-z])',
  );
  static final _bankCardRegex = RegExp(
    r'(?<!\d)(?:\d[ -]?){13,19}(?!\d)',
  );
  static final _ipv4Regex = RegExp(
    r'(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?![\d.])',
  );
  static final _tokenPatterns = <RegExp>[
    RegExp(r'\bsk-(?:proj-|ant-|live-|test-)?[A-Za-z0-9_-]{16,}\b'),
    RegExp(r'\bgh[pousr]_[A-Za-z0-9_]{20,}\b'),
    RegExp(r'\bgithub_pat_[A-Za-z0-9_]{20,}\b'),
    RegExp(r'\bAKIA[0-9A-Z]{16}\b'),
    RegExp(r'\bAIza[0-9A-Za-z_-]{35}\b'),
    RegExp(r'\bxox[baprs]-[0-9A-Za-z-]{10,}\b'),
    RegExp(r'\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b'),
  ];
  static final _bearerRegex = RegExp(
    r'\bBearer\s+([A-Za-z0-9._~+/=-]{16,})',
    caseSensitive: false,
  );
  static final _keyValueSecretRegex = RegExp(
    r'(?:api[_-]?key|access[_-]?token|refresh[_-]?token|secret[_-]?key|private[_-]?key|auth[_-]?token|session[_-]?id|cookie|token|secret)\s*[:=]\s*([^\s,;"' "'" r'`]{8,})',
    caseSensitive: false,
  );
  static final _contextLabelValueRegex = RegExp(
    r'(?:微信号|微信|WeChat|QQ号?|密码|口令|Password|Passwd|订单号|订单编号|运单号|快递单号|收货地址|收件地址|联系地址|家庭住址|详细地址|收货人|收件人|真实姓名|持卡人|身份证号|银行卡号|开户行|手机号|联系电话|电话)\s*[:：]\s*(.+)$',
    caseSensitive: false,
  );
  static final _standaloneLabelRegex = RegExp(
    r'^(?:微信号|微信|WeChat|QQ号?|密码|口令|Password|Passwd|订单号|订单编号|运单号|快递单号|收货地址|收件地址|联系地址|家庭住址|详细地址|收货人|收件人|真实姓名|持卡人|身份证号|银行卡号|手机号|联系电话|电话)\s*[:：]?$',
    caseSensitive: false,
  );

  /// 从 OCR 结构化结果中提取所有命中隐私的精确像素区域。
  static List<PrivacyRegion> detectText(OcrResult ocr) {
    if (ocr.isEmpty) return const [];
    final imageBounds = Rect.fromLTWH(
      0,
      0,
      ocr.imageWidth.toDouble(),
      ocr.imageHeight.toDouble(),
    );
    final candidates = <_RawHit>[];

    for (var i = 0; i < ocr.lines.length; i++) {
      final line = ocr.lines[i];
      final text = line.text;

      // 1. 密钥 / Token（最高优先级）
      for (final pattern in _tokenPatterns) {
        for (final m in pattern.allMatches(text)) {
          candidates.add(_hit(line, m.start, m.end, PrivacyCategory.secret));
        }
      }
      for (final m in _bearerRegex.allMatches(text)) {
        final value = m.group(1);
        if (value != null) {
          final start = text.indexOf(value, m.start);
          candidates.add(
            _hit(line, start, start + value.length, PrivacyCategory.secret),
          );
        }
      }
      for (final m in _keyValueSecretRegex.allMatches(text)) {
        final value = m.group(1);
        if (value != null) {
          final start = text.indexOf(value, m.start);
          candidates.add(
            _hit(line, start, start + value.length, PrivacyCategory.secret),
          );
        }
      }

      // 2. 身份证号（带校验位验证）
      for (final m in _idCardRegex.allMatches(text)) {
        final value = m.group(0)!;
        if (isValidChineseIdCard(value)) {
          candidates.add(_hit(line, m.start, m.end, PrivacyCategory.idCard));
        }
      }

      // 3. 手机号
      for (final m in _phoneRegex.allMatches(text)) {
        final digits = m.group(0)!.replaceAll(RegExp(r'\D'), '');
        final normalized = digits.length == 13 && digits.startsWith('86')
            ? digits.substring(2)
            : digits;
        if (normalized.length == 11) {
          candidates.add(_hit(line, m.start, m.end, PrivacyCategory.phone));
        }
      }

      // 4. 邮箱
      for (final m in _emailRegex.allMatches(text)) {
        candidates.add(_hit(line, m.start, m.end, PrivacyCategory.email));
      }

      // 5. 银行卡号（带 Luhn 算法校验）
      for (final m in _bankCardRegex.allMatches(text)) {
        final raw = m.group(0)!.trim();
        final digits = raw.replaceAll(RegExp(r'\D'), '');
        if (digits.length >= 13 &&
            digits.length <= 19 &&
            passesLuhn(digits)) {
          final start = text.indexOf(raw, m.start);
          candidates.add(
            _hit(line, start, start + raw.length, PrivacyCategory.bankCard),
          );
        }
      }

      // 6. IP 地址（排除常见本机占位地址与版本号前缀）
      for (final m in _ipv4Regex.allMatches(text)) {
        final ip = m.group(0)!;
        if (ip == '0.0.0.0' || ip == '127.0.0.1' || ip == '255.255.255.255') {
          continue;
        }
        if (m.start > 0 &&
            (text[m.start - 1] == 'v' || text[m.start - 1] == 'V')) {
          continue;
        }
        candidates.add(_hit(line, m.start, m.end, PrivacyCategory.ipAddress));
      }

      // 7. 同段上下文标签（例如「微信号：alice_123」「收货地址：...」）
      final labelMatch = _contextLabelValueRegex.firstMatch(text);
      if (labelMatch != null) {
        final value = labelMatch.group(1)?.trim();
        if (value != null && value.length >= 2) {
          final start = text.indexOf(value, labelMatch.start);
          candidates.add(
            _hit(line, start, start + value.length, PrivacyCategory.account),
          );
        }
      }

      // 8. 同一视觉行相邻两段（表格/表单左右两列：「收货人」 | 「张三」）
      if (_standaloneLabelRegex.hasMatch(text.trim()) &&
          i + 1 < ocr.lines.length &&
          ocr.lines[i + 1].rowIndex == line.rowIndex) {
        final next = ocr.lines[i + 1];
        if (next.text.trim().length >= 2) {
          candidates.add(
            _hit(next, 0, next.text.length, PrivacyCategory.account),
          );
        }
      }
    }

    // 按优先级去重，避免同一段文字被多个规则重复叠加。
    candidates.sort((a, b) => a.priority.compareTo(b.priority));
    final accepted = <_RawHit>[];
    for (final item in candidates) {
      final overlaps = accepted.any((existing) {
        final inter = item.bounds.intersect(existing.bounds);
        if (inter.isEmpty) return false;
        final interArea = inter.width * inter.height;
        final minArea = math.min(
          item.bounds.width * item.bounds.height,
          existing.bounds.width * existing.bounds.height,
        );
        return minArea > 0 && interArea / minArea > 0.55;
      });
      if (!overlaps) accepted.add(item);
    }

    // 恢复从上到下、从左到右的阅读顺序。
    accepted.sort((a, b) {
      final dy = a.bounds.top.compareTo(b.bounds.top);
      return dy != 0 ? dy : a.bounds.left.compareTo(b.bounds.left);
    });

    return [
      for (var i = 0; i < accepted.length; i++)
        PrivacyRegion(
          id: 'text_${accepted[i].category.name}_$i',
          category: accepted[i].category,
          bounds: _padRect(accepted[i].bounds, imageBounds),
          preview: accepted[i].preview,
        ),
    ];
  }

  /// 纯 CPU 二维码位置检测（支持多码、深色反色及长截图滑窗）。
  static Future<List<PrivacyRegion>> detectQrCodes(Uint8List imageBytes) async {
    final rawRects = await Isolate.run(() => _detectQrRects(imageBytes));
    return [
      for (var i = 0; i < rawRects.length; i++)
        PrivacyRegion(
          id: 'qr_$i',
          category: PrivacyCategory.qrCode,
          bounds: Rect.fromLTRB(
            rawRects[i][0],
            rawRects[i][1],
            rawRects[i][2],
            rawRects[i][3],
          ),
        ),
    ];
  }

  static List<List<double>> _detectQrRects(Uint8List imageBytes) {
    var decoded = img.decodeImage(imageBytes);
    if (decoded == null) return const [];
    if (decoded.format != img.Format.uint8 || decoded.hasPalette) {
      decoded = decoded.convert(format: img.Format.uint8, numChannels: 3);
    }
    final origW = decoded.width.toDouble();
    final origH = decoded.height.toDouble();
    final scale = decoded.width > 1280 ? 1280 / decoded.width : 1.0;
    final working = scale < 1.0
        ? img.copyResize(
            decoded,
            width: 1280,
            interpolation: img.Interpolation.linear,
          )
        : decoded.clone();

    final found = <Rect>[];
    final invScaleX = origW / working.width;
    final invScaleY = origH / working.height;

    void scanWindow(img.Image crop, int offsetX, int offsetY) {
      final canvas = crop.clone();
      for (var attempt = 0; attempt < 4; attempt++) {
        final result = _decodeSingleQr(canvas);
        if (result == null) break;
        final localRect = _qrBoundsFromPoints(
          result.resultPoints,
          canvas.width,
          canvas.height,
        );
        if (localRect == null) break;

        // 在工作副本上抹除已命中的二维码，继续扫描其余二维码。
        img.fillRect(
          canvas,
          x1: localRect.left.floor().clamp(0, canvas.width - 1),
          y1: localRect.top.floor().clamp(0, canvas.height - 1),
          x2: localRect.right.ceil().clamp(0, canvas.width - 1),
          y2: localRect.bottom.ceil().clamp(0, canvas.height - 1),
          color: img.ColorRgb8(128, 128, 128),
        );

        final fullRect = Rect.fromLTRB(
          ((offsetX + localRect.left) * invScaleX).clamp(0.0, origW),
          ((offsetY + localRect.top) * invScaleY).clamp(0.0, origH),
          ((offsetX + localRect.right) * invScaleX).clamp(0.0, origW),
          ((offsetY + localRect.bottom) * invScaleY).clamp(0.0, origH),
        );
        final duplicate = found.any((other) {
          final inter = fullRect.intersect(other);
          if (inter.isEmpty) return false;
          final area = inter.width * inter.height;
          final minArea = math.min(
            fullRect.width * fullRect.height,
            other.width * other.height,
          );
          return minArea > 0 && area / minArea > 0.4;
        });
        if (!duplicate) found.add(fullRect);
      }
    }

    // 长图按重叠窗口扫描；常规图整张扫描。
    if (working.height > working.width * 1.6) {
      final bandH = (working.width * 1.25).round();
      final stride = (bandH * 0.72).round();
      for (var top = 0; top < working.height; top += stride) {
        final h = math.min(bandH, working.height - top);
        final band = img.copyCrop(
          working,
          x: 0,
          y: top,
          width: working.width,
          height: h,
        );
        scanWindow(band, 0, top);
        if (top + h >= working.height) break;
      }
    } else {
      scanWindow(working, 0, 0);
    }

    return [
      for (final r in found) [r.left, r.top, r.right, r.bottom],
    ];
  }

  static Result? _decodeSingleQr(img.Image image) {
    final abgr = image
        .convert(format: img.Format.uint8, numChannels: 4)
        .getBytes(order: img.ChannelOrder.abgr)
        .buffer
        .asInt32List();
    final source = RGBLuminanceSource(image.width, image.height, abgr);
    final reader = QRCodeReader();
    try {
      return reader.decode(BinaryBitmap(HybridBinarizer(source)));
    } catch (_) {
      try {
        return reader.decode(
          BinaryBitmap(HybridBinarizer(InvertedLuminanceSource(source))),
        );
      } catch (_) {
        return null;
      }
    }
  }

  static Rect? _qrBoundsFromPoints(
    List<ResultPoint> points,
    int maxWidth,
    int maxHeight,
  ) {
    if (points.length < 3) return null;
    // ZXing QRCodeReader 返回 [bottomLeft, topLeft, topRight, (optional alignment)]。
    final bl = points[0];
    final tl = points[1];
    final tr = points[2];
    final brX = tr.x + (bl.x - tl.x);
    final brY = tr.y + (bl.y - tl.y);

    final xs = <double>[bl.x, tl.x, tr.x, brX];
    final ys = <double>[bl.y, tl.y, tr.y, brY];
    for (var i = 3; i < points.length; i++) {
      xs.add(points[i].x);
      ys.add(points[i].y);
    }
    final minX = xs.reduce(math.min);
    final maxX = xs.reduce(math.max);
    final minY = ys.reduce(math.min);
    final maxY = ys.reduce(math.max);
    final side = math.max(maxX - minX, maxY - minY);
    if (side < 8) return null;

    // 定位角中心距二维码外边缘 3.5 模块，向外扩展 0.28 * side 覆盖完整码面与留白。
    final expand = side * 0.28;
    return Rect.fromLTRB(
      (minX - expand).clamp(0.0, maxWidth.toDouble()),
      (minY - expand).clamp(0.0, maxHeight.toDouble()),
      (maxX + expand).clamp(0.0, maxWidth.toDouble()),
      (maxY + expand).clamp(0.0, maxHeight.toDouble()),
    );
  }

  static _RawHit _hit(
    OcrTextLine line,
    int start,
    int end,
    PrivacyCategory category,
  ) {
    return _RawHit(
      category: category,
      bounds: line.boundsForRange(start, end),
      preview: line.text.substring(
        start.clamp(0, line.text.length),
        end.clamp(0, line.text.length),
      ),
    );
  }

  static Rect _padRect(Rect rect, Rect limit) {
    final padX = math.max(2.0, rect.height * 0.14);
    final padY = math.max(2.0, rect.height * 0.1);
    return Rect.fromLTRB(
      (rect.left - padX).clamp(limit.left, limit.right),
      (rect.top - padY).clamp(limit.top, limit.bottom),
      (rect.right + padX).clamp(limit.left, limit.right),
      (rect.bottom + padY).clamp(limit.top, limit.bottom),
    );
  }

  /// 校验中国大陆 18 位居民身份证号码（含 ISO 7064 MOD 11-2 校验位）。
  static bool isValidChineseIdCard(String value) {
    if (value.length != 18) return false;
    final province = int.tryParse(value.substring(0, 2));
    if (province == null || province < 11 || province > 65) return false;
    const weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
    const checkChars = '10X98765432';
    var sum = 0;
    for (var i = 0; i < 17; i++) {
      final digit = value.codeUnitAt(i) - 48;
      if (digit < 0 || digit > 9) return false;
      sum += digit * weights[i];
    }
    return value[17].toUpperCase() == checkChars[sum % 11];
  }

  /// 校验银行卡号 Luhn 校验和。
  static bool passesLuhn(String digits) {
    if (digits.length < 13 || digits.length > 19) return false;
    // 排除全同数字等明显伪匹配（如 0000000000000000）。
    if (digits.split('').toSet().length <= 1) return false;
    var sum = 0;
    var doubleNext = false;
    for (var i = digits.length - 1; i >= 0; i--) {
      final d = digits.codeUnitAt(i) - 48;
      if (d < 0 || d > 9) return false;
      var value = d;
      if (doubleNext) {
        value *= 2;
        if (value > 9) value -= 9;
      }
      sum += value;
      doubleNext = !doubleNext;
    }
    return sum % 10 == 0;
  }
}

class _RawHit {
  const _RawHit({
    required this.category,
    required this.bounds,
    required this.preview,
  });

  final PrivacyCategory category;
  final Rect bounds;
  final String preview;

  int get priority => switch (category) {
    PrivacyCategory.secret => 0,
    PrivacyCategory.idCard => 1,
    PrivacyCategory.email => 2,
    PrivacyCategory.phone => 3,
    PrivacyCategory.bankCard => 4,
    PrivacyCategory.ipAddress => 5,
    PrivacyCategory.account => 6,
    PrivacyCategory.qrCode => 7,
    PrivacyCategory.manual => 8,
  };
}
