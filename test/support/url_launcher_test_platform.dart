import 'package:flutter/services.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/link.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// 模拟“查询不可见但能够启动”，以及系统启动失败，不打开真实浏览器。
class TestUrlLauncher extends UrlLauncherPlatform {
  @override
  LinkDelegate? get linkDelegate => null;
  int queries = 0;
  bool succeeds = true;
  bool throwsOnLaunch = false;
  final opened = <String>[];

  @override
  Future<bool> canLaunch(String url) async {
    queries++;
    return false;
  }

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    opened.add(url);
    if (throwsOnLaunch) throw PlatformException(code: 'ACTIVITY_NOT_FOUND');
    return succeeds;
  }
}
