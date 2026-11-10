// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';

import '../services/fonts/font_download_service.dart';

/// 字体下载服务（安装状态、下载源设置、测速结果变化时通知）。
final fontDownloadProvider = ChangeNotifierProvider<FontDownloadService>(
  (ref) => FontDownloadService.instance,
);
