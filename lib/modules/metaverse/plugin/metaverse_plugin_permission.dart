import 'metaverse_forum_request.dart';
import 'metaverse_plugin_manifest.dart';

/// 分类由宿主定义。清单决定上限，脚本不能将可管理权限声明为基础能力。
enum MetaversePluginPermission {
  sandbox(manageable: false),
  network(manageable: false),
  foregroundTasks(manageable: false),
  identity,
  serviceAccount,
  payments,
  forumProfiles,
  forumActivity,
  forumFollowing,
  background,
  notifications,
  links(initiallyAllowed: true),
  publicImages(initiallyAllowed: true);

  const MetaversePluginPermission({
    this.manageable = true,
    this.initiallyAllowed = false,
  });
  final bool manageable;
  final bool initiallyAllowed;

  static MetaversePluginPermission forForum(MetaverseForumScope scope) =>
      switch (scope) {
        MetaverseForumScope.profiles => forumProfiles,
        MetaverseForumScope.activity => forumActivity,
        MetaverseForumScope.following => forumFollowing,
      };

  bool declaredBy(MetaversePluginManifest manifest) => switch (this) {
    sandbox => true,
    network => manifest.networkHosts.isNotEmpty,
    foregroundTasks => manifest.tasks.isNotEmpty,
    identity => manifest.identity,
    serviceAccount =>
      manifest.auth.canAttachCredential ||
          manifest.webLogin != null ||
          manifest.capabilities.credentials.isNotEmpty ||
          manifest.capabilities.connectCallbacks.isNotEmpty,
    payments => manifest.capabilities.payments.isNotEmpty,
    forumProfiles || forumActivity || forumFollowing =>
      manifest.capabilities.forum.any((scope) => forForum(scope) == this),
    background => manifest.capabilities.background,
    notifications => manifest.capabilities.notifications,
    links => manifest.links.isNotEmpty,
    publicImages => manifest.publicImages,
  };
}

extension MetaversePermissionDeclarations on MetaversePluginManifest {
  Iterable<MetaversePluginPermission> get declaredPermissions =>
      MetaversePluginPermission.values.where(
        (permission) => permission.declaredBy(this),
      );

  /// 合并用户实际改过的开关，未出现在本次选择中的权限沿用当前值。
  Set<MetaversePluginPermission> applyPermissionChoices(
    Set<MetaversePluginPermission> initial,
    Map<MetaversePluginPermission, bool> choices,
  ) {
    final blocked = {...initial};
    for (final entry in choices.entries) {
      final permission = entry.key;
      if (!permission.manageable || !permission.declaredBy(this)) {
        throw ArgumentError.value(permission, 'permission');
      }
      if (entry.value) {
        blocked.remove(permission);
      } else {
        blocked.add(permission);
      }
    }
    return Set.unmodifiable(blocked);
  }
}
