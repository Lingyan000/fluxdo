import '../core/metaverse_link_rule.dart';
import 'metaverse_plugin_capabilities.dart';
import 'metaverse_plugin_manifest.dart';

/// 比较实际访问范围，缩小范围不要求重新授权；不能证明包含关系时须审阅。
extension MetaverseApprovalChange on MetaversePluginManifest {
  List<String> expandedApprovalFrom(MetaversePluginManifest old) {
    bool hosts(List<String> next, List<String> before) => next.every(
      (n) => before.any(
        (o) =>
            n == o ||
            (o.startsWith('*.') &&
                (n.startsWith('*.')
                    ? n.substring(2).endsWith(o.substring(1))
                    : MetaverseHostPattern.matches(o, n))),
      ),
    );
    final changes = <String>[];
    if (!hosts(networkHosts, old.networkHosts)) changes.add('network');
    if (identity && !old.identity) changes.add('identity');
    if (publicImages && !old.publicImages) changes.add('publicImages');
    if (webLogin != null && webLogin != old.webLogin) changes.add('webLogin');
    if (auth.canAttachCredential &&
        (auth.type != old.auth.type ||
            auth.header != old.auth.header ||
            auth.scheme != old.auth.scheme ||
            !hosts(auth.hosts, old.auth.hosts))) {
      changes.add('auth');
    }
    final next = capabilities, before = old.capabilities;
    for (final entry in next.credentials.entries) {
      final previous = before.credentials[entry.key];
      if (previous == null || !entry.value.isWithin(previous))
        changes.add('credentials.${entry.key}');
    }
    if (!before.connectCallbacks.toSet().containsAll(next.connectCallbacks))
      changes.add('connect');
    if (!before.payments.containsAll(next.payments)) changes.add('payments');
    for (final scope in next.forum.difference(before.forum)) {
      changes.add('forum.${scope.name}');
    }
    if (next.background && !before.background) changes.add('background');
    if (next.notifications && !before.notifications)
      changes.add('notifications');
    if (!old.tasks.map((t) => t.id).toSet().containsAll(tasks.map((t) => t.id)))
      changes.add('tasks');
    // 路由顺序影响匹配结果。只允许删除旧条目且不改变剩余条目的顺序。
    var position = 0;
    for (final rule in links) {
      while (position < old.links.length &&
          (old.links[position].host != rule.host ||
              old.links[position].path != rule.path ||
              old.links[position].page != rule.page)) {
        position++;
      }
      if (position == old.links.length) {
        changes.add('links');
        break;
      }
      position++;
    }
    return changes;
  }

  bool canUpdateWithoutApproval(MetaversePluginManifest old) =>
      apiVersion == old.apiVersion &&
      runtimeSupported &&
      expandedApprovalFrom(old).isEmpty;
}

extension MetaverseCredentialReduction on MetaverseCredentialSpec {
  bool isWithin(MetaverseCredentialSpec previous) =>
      header.toLowerCase() == previous.header.toLowerCase() &&
      scheme == previous.scheme &&
      scopes.every(
        (n) => previous.scopes.any(
          (o) =>
              o.origin.origin == n.origin.origin &&
              (o.pathPrefix == '/' ||
                  n.pathPrefix == o.pathPrefix ||
                  n.pathPrefix.startsWith('${o.pathPrefix}/')) &&
              o.methods.containsAll(n.methods),
        ),
      );
}
