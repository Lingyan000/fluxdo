import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../l10n/s.dart';
import '../models/category.dart';
import '../models/topic.dart';
import '../models/topic_card_style.dart';
import '../providers/preferences_provider.dart';
import '../utils/responsive.dart';
import '../widgets/topic/painted_topic_card.dart';
import '../widgets/topic/topic_card_layout.dart';

/// 话题卡片样式设置页
///
/// 布局:顶部 = 实时预览卡片(假数据 + 真实自绘渲染,所见即所得),
/// 下方 = 元信息字段开关 / 头像布局 / 动态头像配置。改动即存即预览。
class TopicCardStyleSettingsPage extends ConsumerStatefulWidget {
  const TopicCardStyleSettingsPage({super.key});

  @override
  ConsumerState<TopicCardStyleSettingsPage> createState() =>
      _TopicCardStyleSettingsPageState();
}

class _TopicCardStyleSettingsPageState
    extends ConsumerState<TopicCardStyleSettingsPage> {
  /// 预览假数据:存 State 字段保证 identityHashCode 稳定
  /// (进 TopicCardLayout 的 stamp,实例漂移会导致每帧重排)
  Topic? _previewTopic;
  Category? _previewCategory;

  void _ensurePreviewData(BuildContext context) {
    if (_previewTopic != null) return;
    final l10n = context.l10n;
    _previewTopic = Topic(
      id: 0,
      title: l10n.topicCardStyle_previewTopicTitle,
      slug: 'preview',
      postsCount: 25,
      replyCount: 24,
      views: 2048,
      likeCount: 128,
      excerpt: l10n.topicCardStyle_previewExcerpt,
      lastPostedAt: DateTime.now().subtract(const Duration(minutes: 5)),
      categoryId: '1',
      tags: [Tag(name: l10n.topicCardStyle_previewTag)],
      posters: [
        TopicPoster(
          userId: 0,
          description: '',
          extras: '',
          user: TopicUser(
            id: 0,
            username: 'fluxdo',
            name: l10n.topicCardStyle_previewUserName,
            avatarTemplate: '', // 空串 → 灰底占位,预览零网络依赖
          ),
        ),
      ],
    );
    _previewCategory = Category(
      id: 1,
      name: l10n.topicCardStyle_previewCategory,
      color: '25AAE2',
      textColor: 'FFFFFF',
      slug: 'preview',
    );
  }

  void _update(TopicCardStyle style) {
    ref.read(preferencesProvider.notifier).setTopicCardStyle(style);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final style = ref.watch(
      preferencesProvider.select((p) => p.topicCardStyle),
    );
    _ensurePreviewData(context);

    final listView = ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        _buildSectionHeader(
          theme,
          l10n.topicCardStyle_preview,
          Symbols.preview_rounded,
        ),
        const SizedBox(height: 12),
        _buildPreviewCard(context, style),
        const SizedBox(height: 24),

        _buildSectionHeader(
          theme,
          l10n.topicCardStyle_titleFontSize,
          Symbols.format_size_rounded,
        ),
        const SizedBox(height: 12),
        SegmentedCardGroup(
          children: [_buildTitleFontSizeSlider(theme, l10n, style)],
        ),
        const SizedBox(height: 24),

        _buildSectionHeader(
          theme,
          l10n.topicCardStyle_avatarGroup,
          Symbols.account_circle_rounded,
        ),
        const SizedBox(height: 12),
        SegmentedCardGroup(
          children: [
            RadioGroup<TopicCardAvatarLayout>(
              groupValue: style.avatarLayout,
              onChanged: (v) {
                if (v != null) _update(style.copyWith(avatarLayout: v));
              },
              child: Column(
                children: [
                  RadioListTile<TopicCardAvatarLayout>(
                    title: Text(l10n.topicCardStyle_avatarLayoutInline),
                    subtitle:
                        Text(l10n.topicCardStyle_avatarLayoutInlineDesc),
                    value: TopicCardAvatarLayout.inline,
                  ),
                  RadioListTile<TopicCardAvatarLayout>(
                    title: Text(l10n.topicCardStyle_avatarLayoutColumn),
                    subtitle:
                        Text(l10n.topicCardStyle_avatarLayoutColumnDesc),
                    value: TopicCardAvatarLayout.column,
                  ),
                ],
              ),
            ),
            SwitchListTile(
              title: Text(l10n.topicCardStyle_animatedAvatar),
              subtitle: Text(l10n.topicCardStyle_animatedAvatarDesc),
              secondary: Icon(
                Symbols.gif_box_rounded,
                color: style.animatedAvatar
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              value: style.animatedAvatar,
              onChanged: (v) => _update(style.copyWith(animatedAvatar: v)),
            ),
          ],
        ),
        const SizedBox(height: 24),

        _buildSectionHeader(
          theme,
          l10n.topicCardStyle_fieldsGroup,
          Symbols.checklist_rounded,
        ),
        const SizedBox(height: 4),
        // 骨架字段说明:分类/标题/时间/未读/头像恒定显示
        Padding(
          padding: const EdgeInsets.only(left: 26),
          child: Text(
            l10n.topicCardStyle_fieldsGroupDesc,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 12),
        SegmentedCardGroup(
          children: [
            _fieldSwitch(
              theme,
              icon: Symbols.person_rounded,
              title: l10n.topicCardStyle_showAuthor,
              value: style.showAuthor,
              onChanged: (v) => _update(style.copyWith(showAuthor: v)),
            ),
            _fieldSwitch(
              theme,
              icon: Symbols.tag_rounded,
              title: l10n.topicCardStyle_showTags,
              value: style.showTags,
              onChanged: (v) => _update(style.copyWith(showTags: v)),
            ),
            _fieldSwitch(
              theme,
              icon: Symbols.chat_bubble_rounded,
              title: l10n.topicCardStyle_showReplies,
              value: style.showReplies,
              onChanged: (v) => _update(style.copyWith(showReplies: v)),
            ),
            _fieldSwitch(
              theme,
              icon: Symbols.favorite_rounded,
              title: l10n.topicCardStyle_showLikes,
              value: style.showLikes,
              onChanged: (v) => _update(style.copyWith(showLikes: v)),
            ),
            _fieldSwitch(
              theme,
              icon: Symbols.visibility_rounded,
              title: l10n.topicCardStyle_showViews,
              subtitle: l10n.topicCardStyle_showViewsDesc,
              value: style.showViews,
              onChanged: (v) => _update(style.copyWith(showViews: v)),
            ),
          ],
        ),
        const SizedBox(height: 24),

        Center(
          child: TextButton.icon(
            onPressed: style.isDefault
                ? null
                : () => _update(TopicCardStyle.defaults),
            icon: const Icon(Symbols.restart_alt_rounded),
            label: Text(l10n.topicCardStyle_resetDefault),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );

    return Scaffold(
      appBar: AppBar(title: Text(l10n.topicCardStyle_title)),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: Breakpoints.maxContentWidth,
          ),
          child: listView,
        ),
      ),
    );
  }

  /// 实时预览:直接用自绘卡真实渲染(与列表逐像素一致)。
  /// identity 用保留前缀,不与真实列表 `topic:{id}` 冲突;
  /// 显式传 style,statsAvailableWidth 拉满让 likes/views 开关效果
  /// 在窄屏预览上也可见
  Widget _buildPreviewCard(BuildContext context, TopicCardStyle style) {
    final cardWidth =
        (MediaQuery.sizeOf(context).width - 32)
            .clamp(0.0, Breakpoints.maxContentWidth - 32)
            .toDouble();
    final layout = TopicCardLayout.obtain(
      identity: 'style-preview:0',
      topic: _previewTopic!,
      width: cardWidth,
      theme: Theme.of(context),
      category: _previewCategory,
      emojiUrlOf: topicCardEmojiUrlResolver,
      statsAvailableWidth: 9999,
      style: style,
    );
    return IgnorePointer(
      child: SizedBox(
        width: cardWidth,
        child: PaintedTopicCard(layout: layout),
      ),
    );
  }

  /// 标题字号滑块:13~18sp、0.5 步进,默认 15(与 SettingsRenderer
  /// 的 DoubleSlider 同视觉;拖动即写入,预览实时重排)
  Widget _buildTitleFontSizeSlider(
    ThemeData theme,
    AppLocalizations l10n,
    TopicCardStyle style,
  ) {
    final value = style.titleFontSize;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Symbols.format_size_rounded,
                  color: theme.colorScheme.primary),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.topicCardStyle_titleFontSize),
                    Text(
                      value == 15.0
                          ? '15 (${l10n.topicCardStyle_titleFontSizeDefault})'
                          : value.toStringAsFixed(
                              value == value.roundToDouble() ? 0 : 1),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: value != 15.0
                    ? () => _update(style.copyWith(titleFontSize: 15.0))
                    : null,
                child: Text(context.l10n.common_reset),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 滑块样式走全局主题(M3E 开 = year2023 新样式),不再本地覆盖
          Slider(
            value: value,
            min: 13,
            max: 18,
            divisions: 10,
            label: value.toStringAsFixed(
                value == value.roundToDouble() ? 0 : 1),
            onChanged: (v) => _update(style.copyWith(titleFontSize: v)),
          ),
        ],
      ),
    );
  }

  Widget _fieldSwitch(
    ThemeData theme, {
    required IconData icon,
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle) : null,
      secondary: Icon(
        icon,
        color: value
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      ),
      value: value,
      onChanged: onChanged,
    );
  }

  Widget _buildSectionHeader(ThemeData theme, String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
