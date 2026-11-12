import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../pages/category_topics_page.dart';
import '../providers/category_provider.dart';
import '../providers/core_providers.dart';
import '../services/toast_service.dart';
import '../widgets/layout/home_workspace_scope.dart';
import 'error_utils.dart';

/// 解析完整分类信息，再进入首页分类视图或独立分类页。
Future<void> openCategoryPage(
  BuildContext context,
  int categoryId, {
  bool useWorkspace = true,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  try {
    final category =
        container.read(categoryMapProvider).value?[categoryId] ??
        await container.read(discourseServiceProvider).getCategory(categoryId);
    if (!context.mounted) return;
    final workspace = useWorkspace ? HomeWorkspaceScope.maybeOf(context) : null;
    if (workspace != null) {
      workspace.onShowCategory(category);
    } else {
      Navigator.of(context).push(
        InteractionPageRoute(
          builder: (_) => CategoryTopicsPage(category: category),
        ),
      );
    }
  } catch (error) {
    if (context.mounted) {
      ToastService.showError(ErrorUtils.getErrorInfo(error).message);
    }
  }
}
