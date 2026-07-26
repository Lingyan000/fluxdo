import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';
import '../models/user.dart';
import '../providers/discourse_providers.dart';
import '../widgets/common/error_view.dart';
import '../widgets/common/smart_avatar.dart';
import 'user_profile_page.dart';
import '../l10n/s.dart';

/// 关注/粉丝列表页面
class FollowListPage extends ConsumerStatefulWidget {
  final String username;
  final bool isFollowing; // true=关注列表, false=粉丝列表

  const FollowListPage({
    super.key,
    required this.username,
    required this.isFollowing,
  });

  @override
  ConsumerState<FollowListPage> createState() => _FollowListPageState();
}

class _FollowListPageState extends ConsumerState<FollowListPage> {
  List<FollowUser>? _users;
  bool _isLoading = true;
  Object? _error;
  StackTrace? _errorStack;

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _errorStack = null;
    });

    try {
      final service = ref.read(discourseServiceProvider);
      final users = widget.isFollowing
          ? await service.getFollowing(widget.username)
          : await service.getFollowers(widget.username);

      if (mounted) {
        setState(() {
          _users = users;
          _isLoading = false;
        });
      }
    } catch (e, s) {
      if (mounted) {
        setState(() {
          _error = e;
          _errorStack = s;
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isFollowing ? context.l10n.followList_following : context.l10n.followList_followers),
      ),
      body: _isLoading
          ? const Center(child: LoadingSpinner())
          : _error != null
              ? ErrorView(
                  error: _error!,
                  stackTrace: _errorStack,
                  onRetry: _loadUsers,
                )
              : _users == null || _users!.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Symbols.group_rounded, size: 48, color: Colors.grey[400]),
                          const SizedBox(height: 8),
                          Text(context.l10n.common_noData, style: TextStyle(color: Colors.grey[600])),
                        ],
                      ),
                    )
                  : M3eRefreshIndicator(
                      onRefresh: _loadUsers,
                      child: ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _users!.length,
                        itemBuilder: (context, index) {
                          final user = _users![index];
                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            clipBehavior: Clip.antiAlias,
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              leading: SmartAvatar(
                                imageUrl: user.avatarTemplate != null
                                    ? user.getAvatarUrl(size: 96)
                                    : null,
                                radius: 24,
                                fallbackText: user.username,
                              ),
                              title: Text(
                                user.name?.isNotEmpty == true ? user.name! : user.username,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              subtitle: Text(
                                '@${user.username}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => UserProfilePage(username: user.username),
                                  ),
                                );
                              },
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}
