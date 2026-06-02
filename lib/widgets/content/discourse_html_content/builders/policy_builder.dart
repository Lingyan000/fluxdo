import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../../models/topic.dart';
import '../../../../pages/user_profile_page.dart';
import '../../../../services/discourse/discourse_service.dart';
import '../../../../services/toast_service.dart';
import '../../../../widgets/common/smart_avatar.dart';
import '../current_post_scope.dart';

/// 构建 Policy 容器（discourse-policy 插件）
///
/// HTML 结构：
/// ```html
/// <div class="policy" data-groups="..." data-version="1" data-accept="..." ...>
///   <p>policy 正文 markdown</p>
/// </div>
/// ```
///
/// 样式对齐 Discourse `plugins/discourse-policy/assets/stylesheets/common/discourse-policy.scss`：
/// 容器带边框，无 header；body + footer 用 border-top 分隔；footer 横排（按钮 | 用户栏），
/// 窄屏降级为纵排。
///
/// 响应最新 post：通过 [CurrentPostScope] 订阅外层 Post 引用变化
/// （TopicDetailNotifier 的 refreshPost 会产出新 Post 对象）。不依赖
/// widget.post 传参——那条路径会被 HtmlWidget 的子树复用冻住。
Widget buildPolicy({
  required BuildContext context,
  required ThemeData theme,
  required dom.Element element,
  required Post post,
  required Widget Function(String html, TextStyle? textStyle) htmlBuilder,
}) {
  var bodyHtml = element.innerHtml;
  final bodyMatch = RegExp(
    r'^\s*<div[^>]*class="[^"]*policy-body[^"]*"[^>]*>([\s\S]*)</div>\s*$',
    caseSensitive: false,
  ).firstMatch(bodyHtml);
  if (bodyMatch != null) {
    bodyHtml = bodyMatch.group(1) ?? '';
  }

  final acceptLabel = element.attributes['data-accept'];
  final revokeLabel = element.attributes['data-revoke'];

  return _PolicyWidget(
    initialPost: post,
    bodyHtml: bodyHtml,
    acceptLabel:
        (acceptLabel == null || acceptLabel.isEmpty) ? '接受' : acceptLabel,
    revokeLabel:
        (revokeLabel == null || revokeLabel.isEmpty) ? '撤销' : revokeLabel,
    htmlBuilder: htmlBuilder,
  );
}

class _PolicyWidget extends StatefulWidget {
  /// 首次 mount 时的 Post；后续以 [CurrentPostScope.of] 为准
  final Post initialPost;
  final String bodyHtml;
  final String acceptLabel;
  final String revokeLabel;
  final Widget Function(String html, TextStyle? textStyle) htmlBuilder;

  const _PolicyWidget({
    required this.initialPost,
    required this.bodyHtml,
    required this.acceptLabel,
    required this.revokeLabel,
    required this.htmlBuilder,
  });

  @override
  State<_PolicyWidget> createState() => _PolicyWidgetState();
}

class _PolicyWidgetState extends State<_PolicyWidget> {
  // 本地乐观状态（初值跟随 post；操作后实时 flip）
  late bool _accepted;
  late bool _revoked;
  late bool _canAccept;
  late bool _canRevoke;
  late int _acceptedCount;
  late int _notAcceptedCount;
  late List<PolicyUser> _acceptedUsers;
  late List<PolicyUser> _notAcceptedUsers;

  /// 当前用户能否看到 policy 用户统计（群组成员可见权限）
  ///
  /// 服务端 PostSerializer 的 `include_policy_stats?` 决定是否下发
  /// accepted_by/not_accepted_by/两个 count 字段。无权限时四个字段全为 null。
  /// 没权限则：不显示头像栏、+N 按钮；Accept/Revoke 后也不伪造 count 自增。
  late bool _hasStats;

  bool _isLoading = false;
  bool _showNotAccepted = false;
  bool _loadingMoreAccepted = false;
  bool _loadingMoreNotAccepted = false;

  /// 当前跟踪的 Post（来自 CurrentPostScope 的最新引用）
  late Post _trackedPost;

  int get _postId => _trackedPost.id;

  @override
  void initState() {
    super.initState();
    _trackedPost = widget.initialPost;
    _syncFromPost(_trackedPost);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // CurrentPostScope 里的 Post 引用变化会触发（TopicDetailNotifier 的
    // refreshPost 每次都 copyWith 产出新 Post）。乐观更新期间不覆盖，避免
    // 与 in-flight API 请求竞争；请求完成后下一次 Scope 变化会追上来。
    if (_isLoading) return;
    final latest = CurrentPostScope.of(context);
    if (latest == null) return;
    if (identical(latest, _trackedPost)) return;
    _trackedPost = latest;
    setState(() => _syncFromPost(latest));
  }

  void _syncFromPost(Post post) {
    _accepted = post.policyAccepted;
    _revoked = post.policyRevoked;
    _canAccept = post.policyCanAccept;
    _canRevoke = post.policyCanRevoke;
    _hasStats = post.policyAcceptedByCount != null ||
        post.policyNotAcceptedByCount != null;
    _acceptedCount = post.policyAcceptedByCount ?? 0;
    _notAcceptedCount = post.policyNotAcceptedByCount ?? 0;
    _acceptedUsers = List.of(post.policyAcceptedBy ?? const []);
    _notAcceptedUsers = List.of(post.policyNotAcceptedBy ?? const []);
  }

  bool get _hasAnyUsers =>
      _hasStats && (_acceptedCount > 0 || _notAcceptedCount > 0);

  bool get _hasFooter =>
      _canAccept || _canRevoke || _hasAnyUsers;

  Future<void> _accept() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      await DiscourseService().acceptPolicy(postId: _postId);
      if (!mounted) return;
      setState(() {
        // 官方：canAccept != canRevoke 时 flip，避免 add-users-to-group 模式下状态错乱
        if (_canAccept != _canRevoke) {
          _canAccept = false;
          _canRevoke = true;
          _accepted = true;
          _revoked = false;
        }
        if (_hasStats) {
          _acceptedCount += 1;
          if (_notAcceptedCount > 0) _notAcceptedCount -= 1;
        }
      });
    } catch (e) {
      if (mounted) ToastService.showError('接受失败: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _revoke() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      await DiscourseService().revokePolicy(postId: _postId);
      if (!mounted) return;
      setState(() {
        if (_canAccept != _canRevoke) {
          _canAccept = true;
          _canRevoke = false;
          _accepted = false;
          _revoked = true;
        }
        if (_hasStats) {
          _notAcceptedCount += 1;
          if (_acceptedCount > 0) _acceptedCount -= 1;
        }
      });
    } catch (e) {
      if (mounted) ToastService.showError('撤销失败: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadMoreAccepted() async {
    if (_loadingMoreAccepted) return;
    setState(() => _loadingMoreAccepted = true);
    try {
      final users = await DiscourseService().loadPolicyAccepted(
        postId: _postId,
        offset: _acceptedUsers.length,
      );
      if (!mounted) return;
      setState(() => _acceptedUsers.addAll(users));
    } catch (e) {
      if (mounted) ToastService.showError('加载失败: $e');
    } finally {
      if (mounted) setState(() => _loadingMoreAccepted = false);
    }
  }

  Future<void> _loadMoreNotAccepted() async {
    if (_loadingMoreNotAccepted) return;
    setState(() => _loadingMoreNotAccepted = true);
    try {
      final users = await DiscourseService().loadPolicyNotAccepted(
        postId: _postId,
        offset: _notAcceptedUsers.length,
      );
      if (!mounted) return;
      setState(() => _notAcceptedUsers.addAll(users));
    } catch (e) {
      if (mounted) ToastService.showError('加载失败: $e');
    } finally {
      if (mounted) setState(() => _loadingMoreNotAccepted = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildBody(theme),
          if (_hasFooter) _buildFooter(theme),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: widget.htmlBuilder(widget.bodyHtml, null),
    );
  }

  Widget _buildFooter(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 官方 @container (max-width: 25rem) 纵排，这里用同一阈值
          final narrow = constraints.maxWidth < 400;
          final actions = (_canAccept || _canRevoke)
              ? _buildActions(theme)
              : null;
          final userLists = _hasAnyUsers ? _buildUserLists(theme) : null;

          if (actions == null && userLists == null) {
            return const SizedBox.shrink();
          }

          if (narrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ?actions,
                if (actions != null && userLists != null)
                  const SizedBox(height: 10),
                ?userLists,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ?actions,
              if (actions != null && userLists != null) const Spacer(),
              if (actions == null && userLists != null) const Spacer(),
              if (userLists != null)
                Flexible(child: userLists),
            ],
          );
        },
      ),
    );
  }

  Widget _buildActions(ThemeData theme) {
    final children = <Widget>[];
    if (_canAccept) {
      final isActive = !_accepted || _revoked;
      children.add(
        isActive
            ? FilledButton.icon(
                onPressed: _isLoading ? null : _accept,
                icon: _accepted && !_revoked
                    ? const Icon(Icons.check, size: 16)
                    : const SizedBox.shrink(),
                label: Text(widget.acceptLabel),
              )
            : OutlinedButton.icon(
                onPressed: _isLoading ? null : _accept,
                icon: const Icon(Icons.check, size: 16),
                label: Text(widget.acceptLabel),
              ),
      );
    }
    if (_canRevoke) {
      if (children.isNotEmpty) children.add(const SizedBox(width: 8));
      final isActive = !_revoked || _accepted;
      children.add(
        isActive
            ? FilledButton.tonalIcon(
                onPressed: _isLoading ? null : _revoke,
                icon: const SizedBox.shrink(),
                label: Text(widget.revokeLabel),
                style: FilledButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                  backgroundColor:
                      theme.colorScheme.errorContainer.withValues(alpha: 0.6),
                ),
              )
            : OutlinedButton.icon(
                onPressed: _isLoading ? null : _revoke,
                icon: const Icon(Icons.check, size: 16),
                label: Text(widget.revokeLabel),
              ),
      );
    }
    if (_isLoading) {
      children.add(const SizedBox(width: 12));
      children.add(const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2),
      ));
    }

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: children,
    );
  }

  Widget _buildUserLists(ThemeData theme) {
    // 已接受 / 未接受 两组，点击计数图标切换哪一组展开用户头像
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (_acceptedCount > 0)
          _buildCountToggle(
            theme,
            icon: PhosphorIconsRegular.userCircleCheck,
            count: _acceptedCount,
            active: !_showNotAccepted,
            onTap: () => setState(() => _showNotAccepted = false),
            color: theme.colorScheme.primary,
          ),
        if (_acceptedCount > 0 && _notAcceptedCount > 0)
          Container(
            width: 1,
            height: 16,
            margin: const EdgeInsets.symmetric(horizontal: 8),
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
          ),
        if (_notAcceptedCount > 0)
          _buildCountToggle(
            theme,
            icon: PhosphorIconsRegular.userCircleMinus,
            count: _notAcceptedCount,
            active: _showNotAccepted,
            onTap: () => setState(() => _showNotAccepted = true),
            color: theme.colorScheme.error,
          ),
        const SizedBox(width: 12),
        Expanded(
          child: _showNotAccepted
              ? _buildAvatarRow(
                  users: _notAcceptedUsers,
                  totalCount: _notAcceptedCount,
                  isLoadingMore: _loadingMoreNotAccepted,
                  onLoadMore: _loadMoreNotAccepted,
                )
              : _buildAvatarRow(
                  users: _acceptedUsers,
                  totalCount: _acceptedCount,
                  isLoadingMore: _loadingMoreAccepted,
                  onLoadMore: _loadMoreAccepted,
                ),
        ),
      ],
    );
  }

  Widget _buildCountToggle(
    ThemeData theme, {
    required IconData icon,
    required int count,
    required bool active,
    required VoidCallback onTap,
    required Color color,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: active ? color : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 3),
            Text(
              '$count',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w500,
                color: active ? color : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatarRow({
    required List<PolicyUser> users,
    required int totalCount,
    required bool isLoadingMore,
    required VoidCallback onLoadMore,
  }) {
    // 官方 template：{{#if this.acceptedUsers.length}} ... {{/if}}
    // users 为空时连 "+N" 也不渲染——没权限看 stats 时后端就不会下发 users，
    // 此时即便 totalCount 显示为某个值（乐观/缓存场景）也不该出现可点击的加载按钮。
    if (users.isEmpty) return const SizedBox.shrink();

    final remaining = totalCount - users.length;

    return SizedBox(
      height: 24,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: users.length + (remaining > 0 ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(width: 4),
        itemBuilder: (context, index) {
          if (index < users.length) {
            final u = users[index];
            return GestureDetector(
              onTap: () {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => UserProfilePage(username: u.username),
                ));
              },
              child: SmartAvatar(
                imageUrl: u.getAvatarUrl(size: 48),
                radius: 12,
                fallbackText: u.username.isNotEmpty ? u.username[0] : '?',
              ),
            );
          }
          return _buildLoadMoreChip(
            remaining: remaining,
            isLoading: isLoadingMore,
            onTap: onLoadMore,
          );
        },
      ),
    );
  }

  Widget _buildLoadMoreChip({
    required int remaining,
    required bool isLoading,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: isLoading ? null : onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        constraints: const BoxConstraints(minWidth: 32, minHeight: 24),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        child: isLoading
            ? const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              )
            : Text(
                '+$remaining',
                style: theme.textTheme.labelSmall,
              ),
      ),
    );
  }
}
