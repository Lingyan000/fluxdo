import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'metaverse_link_rule.dart';

/// 服务卡片上由宿主提供的状态与操作。
@immutable
class MetaverseCardHost {
  const MetaverseCardHost({
    required this.isProcessing,
    required this.onDisable,
    required this.onReauthorize,
    this.onRemove,
    this.onUpdate,
    this.updateVersion,
  });

  /// 宿主正在执行开启/停用/授权，卡片应暂停交互。
  final bool isProcessing;
  final VoidCallback onDisable;
  final VoidCallback onReauthorize;

  /// 仅可卸载的服务（第三方插件）提供。
  final VoidCallback? onRemove;
  final VoidCallback? onUpdate;
  final String? updateVersion;
}

/// 元宇宙服务：元宇宙页里一项可开启的服务。
///
/// 官方服务（LDC/CDK）用原生代码实现，第三方服务由插件包驱动
/// （见 `plugin/metaverse_plugin_service.dart`），两者对元宇宙页、链接路由
/// 都是同一个接口。
///
/// 注意与 `lib/plugins` 的 `SitePlugin` 区分：那是 Discourse 站点插件在
/// 客户端的钩子，这里是用户可开关的外部服务。
///
/// 方法接收 [ProviderContainer] 而不是 `WidgetRef`：链接路由等入口不在
/// widget 里，拿不到 ref。
abstract class MetaverseService {
  const MetaverseService();

  /// 全局唯一标识。第三方服务为清单里的反向域名 id。
  String get id;

  /// 是否来自第三方插件。
  bool get isThirdParty => false;

  String title(BuildContext context);

  String description(BuildContext context);

  IconData get icon;

  /// 未开启卡片上图标底色用主色系还是第三色系，仅用于区分相邻服务。
  bool get useTertiaryTone => false;

  bool isEnabled(ProviderContainer container);

  /// 开启服务（含授权）。返回 false 表示用户取消，失败抛异常。
  Future<bool> enable(BuildContext context, ProviderContainer container);

  Future<void> disable(ProviderContainer container);

  /// 重新授权。返回 false 表示用户取消，失败抛异常。
  Future<bool> reauthorize(BuildContext context, ProviderContainer container);

  /// 进入元宇宙页时刷新已开启服务的数据。
  ///
  /// [isActive] 返回 false 表示页面已销毁，实现须在每次等待后检查并中止。
  Future<void> refresh(
    ProviderContainer container, {
    required bool Function() isActive,
  }) async {}

  /// 开启/重新授权成功后的提示文案。
  String enabledMessage();

  String reauthorizedMessage();

  /// 已开启状态的卡片。
  Widget buildCard(BuildContext context, MetaverseCardHost host);

  /// 已开启后追加在卡片下方的配置区（如 LDC 打赏）。
  Widget? buildExtras(BuildContext context) => null;

  /// 是否可卸载。
  bool get canRemove => false;

  Future<void> remove(ProviderContainer container) async {}

  /// 该服务接管的帖内链接。
  List<MetaverseLinkRule> get linkRules => const [];

  /// 打开服务内的页面；[params] 为链接捕获的参数或服务自身传入的参数。
  Future<void> openPage(
    BuildContext context,
    String page,
    Map<String, Object?> params,
  ) async {}
}
