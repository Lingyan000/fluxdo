part of '../user_profile_page.dart';

/// SliverAppBar 构建相关方法
extension _SliverAppBarBuilder on _UserProfilePageState {
  Widget buildSliverAppBar(BuildContext context, ThemeData theme, User? currentUser) {
    final bgUrl = _user?.backgroundUrl;
    final hasBackground = bgUrl != null && bgUrl.isNotEmpty;
    // Standard toolbar height is usually 56.0 + status bar height
    final double pinnedHeight = kToolbarHeight + MediaQuery.of(context).padding.top;
    final double expandedHeight = 410.0;

    // Check if there is any info to show (for the "About" popup)
    final hasBio = _user?.bio != null && _user!.bio!.isNotEmpty;
    final hasLocation = _user?.location != null && _user!.location!.isNotEmpty;
    final hasWebsite = _user?.website != null && _user!.website!.isNotEmpty;
    final hasJoinedAt = _user?.createdAt != null;
    final hasInfo = hasBio || hasLocation || hasWebsite || hasJoinedAt;

    // 检查是否是自己
    final isOwnProfile = currentUser != null && _user != null && currentUser.username == _user!.username;

    return SliverAppBar(
      expandedHeight: expandedHeight,
      pinned: true,
      stretch: true,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: Colors.transparent, // Transparent to show FlexibleSpaceBar background
      surfaceTintColor: Colors.transparent, // Prevent M3 tint
      iconTheme: const IconThemeData(color: Colors.white),
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          onPressed: () => _openUserSearch(),
        ),
        if (_user != null && _user!.canSendPrivateMessageToUser != false)
          IconButton(
            onPressed: _openMessageDialog,
            icon: const Icon(Icons.mail_outline_rounded),
            tooltip: '私信',
          ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          onSelected: (value) {
            if (value == 'share') {
              _shareUser();
            }
          },
          itemBuilder: (context) {
            final theme = Theme.of(context);
            return [
              PopupMenuItem<String>(
                value: 'share',
                child: Row(
                  children: [
                    Icon(Icons.share_outlined, size: 20, color: theme.colorScheme.onSurface),
                    const SizedBox(width: 12),
                    const Text('分享用户'),
                  ],
                ),
              ),
            ];
          },
        ),
      ],
      // Bottom 参数承载 TabBar，并应用圆角背景，这样它会"浮"在 FlexibleSpace 背景图之上
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(36),
        child: Container(
          decoration: const BoxDecoration(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: TabBar(
            controller: _tabController,
            labelColor: theme.colorScheme.primary,
            unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
            indicatorColor: theme.colorScheme.primary,
            labelPadding: const EdgeInsets.symmetric(horizontal: 12),
            indicatorSize: TabBarIndicatorSize.label,
            dividerColor: Colors.transparent,
            tabs: const [
              Tab(height: 36, text: '总结'),
              Tab(height: 36, text: '动态'),
              Tab(height: 36, text: '话题'),
              Tab(height: 36, text: '回复'),
              Tab(height: 36, text: '赞'),
              Tab(height: 36, text: '回应'),
            ],
          ),
          ),
        ),
      ),
      // Use a Stack to ensure a solid black background exists BEHIND the FlexibleSpaceBar
      flexibleSpace: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final currentHeight = constraints.biggest.height;
          final t = ((currentHeight - pinnedHeight) / (expandedHeight - pinnedHeight)).clamp(0.0, 1.0);
          
          // 标题透明度：收起时显示（当 t < 0.3 时完全显示，避免半透明）
          final titleOpacity = t < 0.3 ? 1.0 : (1.0 - ((t - 0.3) / 0.7)).clamp(0.0, 1.0);
          // 内容透明度：展开时显示
          final contentOpacity = ((t - 0.4) / 0.6).clamp(0.0, 1.0);
          
          return Stack(
            fit: StackFit.expand,
            children: [
              // ===== 层 0: 背景 - 渐变动画打底 + 图片叠加 =====
              const AnimatedGradientBackground(),
              if (hasBackground)
                Image(
                  image: discourseImageProvider(
                    UrlHelper.resolveUrl(bgUrl),
                  ),
                  fit: BoxFit.cover,
                  alignment: Alignment.center,
                  frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                    if (wasSynchronouslyLoaded || frame != null) {
                      return AnimatedOpacity(
                        opacity: frame != null ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 300),
                        child: child,
                      );
                    }
                    return const SizedBox.shrink();
                  },
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),

              // ===== 层 1: 统一压暗遮罩 - 随向上滑动变得更暗 =====
              Container(
                color: Color.lerp(
                  Colors.black.withValues(alpha:0.6), // 展开状态：默认更暗 (0.6)
                  Colors.black.withValues(alpha:0.85), // 收起状态：稍微透一点 (0.85)
                  Curves.easeOut.transform(1.0 - t), // 使用 easeOut 曲线优化滑动体验
                ),
              ),

              // ===== 层 2: 用户信息内容 - 展开时显示，收起时淡出 =====
              Positioned(
                left: 20,
                right: 20,
                bottom: 36 + 24, // TabBar 高度 + 间距
                child: Opacity(
                  opacity: contentOpacity,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 头像、姓名、操作按钮一行
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // 1. 头像 radius=36，flair 大小 30，偏移 right=-7, bottom=-4
                          GestureDetector(
                            onTap: () {
                              if (_user?.getAvatarUrl() != null) {
                                final avatarUrl = _user!.getAvatarUrl(size: 360);
                                ImageViewerPage.open(
                                  context,
                                  avatarUrl,
                                  heroTag: 'user_avatar_${_user!.username}',
                                );
                              }
                            },
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 2),
                              ),
                              child: AvatarWithFlair(
                                flairSize: 30,
                                flairRight: -7,
                                flairBottom: -4,
                                flairUrl: _user?.flairUrl,
                                flairName: _user?.flairName,
                                flairBgColor: _user?.flairBgColor,
                                flairColor: _user?.flairColor,
                                avatar: Hero(
                                  tag: 'user_avatar_${_user?.username ?? ''}',
                                  child: SmartAvatar(
                                    imageUrl: _user?.getAvatarUrl() != null
                                        ? _user!.getAvatarUrl(size: 144)
                                        : null,
                                    radius: 36,
                                    fallbackText: _user?.username,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          
                          // 2. 姓名、身份信息
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Row 1: Name + Status
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        (_user?.name?.isNotEmpty == true) ? _user!.name! : (_user?.username ?? ''),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 22,
                                          fontWeight: FontWeight.bold,
                                          shadows: [Shadow(color: Colors.black45, offset: Offset(0, 1), blurRadius: 2)],
                                        ),
                                      ),
                                    ),
                                    if (_user?.status != null) ...[
                                      const SizedBox(width: 8),
                                      Padding(
                                        padding: const EdgeInsets.only(top: 4),
                                        child: buildStatusEmoji(_user!.status!, size: 18, fontSize: 16),
                                      ),
                                    ],
                                  ],
                                ),
                                
                                // Row 2: Username
                                if (_user?.username != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2, bottom: 6),
                                    child: Text(
                                       '@${_user?.username}',
                                       style: TextStyle(color: Colors.white.withValues(alpha:0.85), fontSize: 13),
                                    ),
                                  )
                                else
                                  const SizedBox(height: 6), // 占位

                                // Row 3: Level Badge
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha:0.2),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    getTrustLevelLabel(_user?.trustLevel ?? 0),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          // 3. 操作按钮 (关注)
                          if (_user != null && !isOwnProfile) ...[
                            const SizedBox(width: 12),
                            _buildFollowButton(isOwnProfile),
                          ],
                        ],
                      ),
                      const SizedBox(height: 16),
                      // Status / Signature (始终显示，保持布局一致)
                      const SizedBox(height: 12),
                      GestureDetector(
                        onTap: hasInfo ? _showUserInfo : null,
                        child: Container(
                          height: 54,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha:0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: hasBio
                                    ? CollapsedHtmlContent(
                                        html: _user!.bio!,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        textStyle: TextStyle(
                                          color: Colors.white.withValues(alpha:0.9),
                                          fontSize: 14,
                                          height: 1.3,
                                        ),
                                      )
                                    : Text(
                                        '这个人很懒，什么都没写',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: Colors.white.withValues(alpha:0.5),
                                          fontSize: 14,
                                          height: 1.3,
                                          fontStyle: FontStyle.italic,
                                        ),
                                      ),
                              ),
                              if (hasInfo) ...[
                                const SizedBox(width: 8),
                                Icon(
                                  Icons.chevron_right,
                                  size: 16,
                                  color: Colors.white.withValues(alpha:0.6),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),

                      // Stats
                      const SizedBox(height: 16),
                      if (_summary != null)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 第一行：关注、粉丝
                            if (_user?.totalFollowing != null || _user?.totalFollowers != null)
                              Wrap(
                                spacing: 16,
                                children: [
                                  if (_user?.totalFollowing != null)
                                    GestureDetector(
                                      onTap: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => FollowListPage(
                                            username: widget.username,
                                            isFollowing: true,
                                          ),
                                        ),
                                      ),
                                      child: _buildStatSlot(NumberUtils.formatCount(_user!.totalFollowing!), '关注', _user!.totalFollowing!),
                                    ),
                                  if (_user?.totalFollowers != null)
                                    GestureDetector(
                                      onTap: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => FollowListPage(
                                            username: widget.username,
                                            isFollowing: false,
                                          ),
                                        ),
                                      ),
                                      child: _buildStatSlot(NumberUtils.formatCount(_user!.totalFollowers!), '粉丝', _user!.totalFollowers!),
                                    ),
                                ],
                              ),
                            // 第二行：获赞、访问、话题、回复
                            if (_user?.totalFollowing != null || _user?.totalFollowers != null)
                              const SizedBox(height: 8),
                            Wrap(
                              spacing: 16,
                              children: [
                                _buildStatSlot(NumberUtils.formatCount(_summary!.likesReceived), '获赞', _summary!.likesReceived),
                                _buildStatSlot(NumberUtils.formatCount(_summary!.daysVisited), '访问', _summary!.daysVisited),
                                _buildStatSlot(NumberUtils.formatCount(_summary!.topicCount), '话题', _summary!.topicCount),
                                _buildStatSlot(NumberUtils.formatCount(_summary!.postCount), '回复', _summary!.postCount),
                              ],
                            ),
                          ],
                        ),
                      
                      // 最近活动时间
                      if (_user?.lastPostedAt != null || _user?.lastSeenAt != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha:0.15),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.flash_on_rounded, size: 12, color: Colors.white70),
                              const SizedBox(width: 4),
                              Text(
                                TimeUtils.formatRelativeTime(_user?.lastSeenAt ?? _user!.lastPostedAt!),
                                style: const TextStyle(color: Colors.white70, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              // ===== 层 3: 收起时的标题栏内容 - 收起时显示，点击展开 =====
              Positioned(
                left: 60, // 增加间距，避免靠近返回按钮
                right: 48,
                bottom: 14 + 36, // 调整位置适应 TabBar (36是TabBar高度)
                child: GestureDetector(
                  onTap: titleOpacity > 0.5 ? () {
                    _scrollController.animateTo(
                      0,
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOut,
                    );
                  } : null,
                  behavior: HitTestBehavior.opaque,
                  child: Opacity(
                    opacity: titleOpacity,
                    child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 头像 radius=16，flair 大小 14，偏移 right=-3, bottom=-1
                      AvatarWithFlair(
                        flairSize: 14,
                        flairRight: -3,
                        flairBottom: -1,
                        flairUrl: _user?.flairUrl,
                        flairName: _user?.flairName,
                        flairBgColor: _user?.flairBgColor,
                        flairColor: _user?.flairColor,
                        avatar: SmartAvatar(
                          imageUrl: _user?.getAvatarUrl() != null
                              ? _user!.getAvatarUrl(size: 64)
                              : null,
                          radius: 16,
                          fallbackText: _user?.username,
                          border: Border.all(color: Colors.white70, width: 1),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          (_user?.name?.isNotEmpty == true) ? _user!.name! : (_user?.username ?? ''),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                ),
              ),

              // 移除之前的所有伪装层
            ],
          );
        }
      ),
    );
  }

  Widget _buildStatSlot(String value, String label, int rawValue) {
    return Tooltip(
      message: '$rawValue',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha:0.7),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFollowButton(bool isOwnProfile) {
    if (_user == null || _user!.canFollow != true || isOwnProfile) {
      return const SizedBox.shrink();
    }

    return _isFollowLoading
        ? Container(
            width: 32,
            height: 32,
            padding: const EdgeInsets.all(8),
            child: const CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          )
        : TextButton.icon(
            onPressed: _toggleFollow,
            icon: Icon(
              _isFollowed ? Icons.check_rounded : Icons.add_rounded,
              size: 16,
            ),
            label: Text(_isFollowed ? '已关注' : '关注'),
            style: TextButton.styleFrom(
              backgroundColor: _isFollowed ? Colors.white.withValues(alpha:0.15) : Colors.white,
              foregroundColor: _isFollowed ? Colors.white : Colors.black87,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: _isFollowed ? const BorderSide(color: Colors.white38) : BorderSide.none,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            ),
          );
  }

}
