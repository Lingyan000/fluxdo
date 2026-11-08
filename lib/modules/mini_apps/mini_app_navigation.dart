import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../navigation/nav_action_bus.dart';
import '../../utils/platform_utils.dart';
import 'mini_app_detail_page.dart';
import 'mini_app_gallery_page.dart';
import 'mini_app_url.dart';

/// 点击入口与深链共用；桌面根页切换工作区，其余路由保留原来的返回路径。
Future<void> openMiniAppGallery(BuildContext context) async {
  final route = ModalRoute.of(context);
  if (!PlatformUtils.isDesktop ||
      route?.isFirst != true ||
      route?.isCurrent != true) {
    await MiniAppGalleryPage.open(context);
    return;
  }
  final container = ProviderScope.containerOf(context, listen: false);
  final previous = container.read(navDestinationRequestProvider);
  container
      .read(navDestinationRequestProvider.notifier)
      .state = NavDestinationRequest(
    targetId: NavEntryIds.miniApps,
    nonce: (previous?.nonce ?? 0) + 1,
  );
}

/// Returns false for non-app routes so callers preserve their existing routing.
Future<bool> openMiniAppLink(BuildContext context, String value) async {
  final uri = MiniAppUrl.parse(value, AppConstants.baseUrl);
  if (uri == null) return false;
  final id = MiniAppUrl.appId(uri);
  if (id == null) {
    await openMiniAppGallery(context);
  } else {
    await MiniAppDetailPage.open(context, id, launchUri: uri);
  }
  return true;
}
