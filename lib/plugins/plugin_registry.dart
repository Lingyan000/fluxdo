import 'package:flutter/widgets.dart';

import '../config/sites/linuxdo.dart';
import 'plugin_context.dart';
import 'site_plugin.dart';

/// 站点插件注册中心
///
/// 默认取当前站点（[linuxdoCustomization]）声明的插件列表。
/// 测试可通过 [overridePlugins] 注入，并用 [resetOverride] 还原。
///
/// 这里直接引用站点配置而不是 `AppConstants`，是为了避开 `constants.dart`
/// 携带的 WebView 等重量级依赖，让插件层能在纯 widget 测试里运行。
class PluginRegistry {
  PluginRegistry._();

  static List<SitePlugin>? _override;

  /// 当前生效的插件列表
  static List<SitePlugin> get plugins =>
      _override ?? linuxdoCustomization.plugins;

  /// 测试注入
  @visibleForTesting
  static void overridePlugins(List<SitePlugin> plugins) {
    _override = plugins;
  }

  /// 还原测试注入
  @visibleForTesting
  static void resetOverride() {
    _override = null;
  }

  /// 依次执行所有插件的回复提交前钩子
  ///
  /// 任一插件返回 `false` 即中止提交，后续插件不再执行
  /// （对齐 Discourse `composerBeforeSave` 里 Promise.reject 中断保存的语义）。
  static Future<bool> runBeforeReplySubmit(ReplySubmitContext context) async {
    for (final plugin in plugins) {
      final allowed = await plugin.beforeReplySubmit(context);
      if (!allowed) return false;
      // 插件可能弹过 UI，期间宿主页面可能已销毁
      if (!context.context.mounted) return false;
    }
    return true;
  }

  /// 依次让插件改写最小正文字数（后一个插件看到前一个的结果，
  /// 对齐 Discourse value transformer 的链式语义）
  static int resolveMinPostLength(
    int value,
    ComposerMinLengthContext context,
  ) {
    var result = value;
    for (final plugin in plugins) {
      result = plugin.composerMinPostLength(result, context);
    }
    return result;
  }

  /// 取第一个提供字数警告文案的插件（无则返回 null）
  static String? charCountWarning(BuildContext context) {
    for (final plugin in plugins) {
      final warning = plugin.composerCharCountWarning(context);
      if (warning != null && warning.isNotEmpty) return warning;
    }
    return null;
  }
}
