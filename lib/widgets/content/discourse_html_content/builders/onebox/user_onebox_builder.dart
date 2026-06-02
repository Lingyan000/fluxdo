import 'package:flutter/material.dart';
import '../../../../../pages/user_profile_page.dart';
import 'onebox_base.dart';

/// 构建用户 onebox 卡片
Widget buildUserOnebox({
  required BuildContext context,
  required ThemeData theme,
  required dynamic element,
}) {
  // 提取头像
  final avatarImg = element.querySelector('img');
  final avatarUrl = avatarImg?.attributes['src'] ?? '';

  // 提取用户名
  final h3Element = element.querySelector('h3');
  final usernameLink = h3Element?.querySelector('a');
  final usernameText = usernameLink?.text ?? '';
  // 从 @username 提取 username
  final username =
      usernameText.startsWith('@') ? usernameText.substring(1) : usernameText;

  // 提取名称
  final nameElement = element.querySelector('.full-name');
  final name = nameElement?.text ?? '';

  // 提取位置
  final locationElement = element.querySelector('.location');
  final location = locationElement?.text?.trim() ?? '';

  // 提取简介
  final bioElement = element.querySelector('p');
  final bio = bioElement?.text ?? '';

  // 提取加入时间
  final joinedElement = element.querySelector('.user-onebox--joined');
  final joined = joinedElement?.text ?? '';

  return OneboxContainer(
    borderRadius: 12,
    onTap: username.isNotEmpty
        ? () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => UserProfilePage(username: username),
              ),
            );
          }
        : null,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 头像
        OneboxAvatar(
          imageUrl: avatarUrl,
          size: 48,
          borderRadius: 24,
        ),
        const SizedBox(width: 12),
        // 用户信息
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 用户名
              Text(
                '@$username',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.primary,
                ),
              ),
              // 名称
              if (name.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  name,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ],
              // 位置
              if (location.isNotEmpty) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(
                      Icons.location_on_outlined,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        location,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
              // 简介
              if (bio.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  bio,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              // 加入时间
              if (joined.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  joined,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color:
                        theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}
