import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;
import 'package:m3e_ui/m3e_ui.dart';

import '../models/user.dart';
import '../providers/core_providers.dart';
import '../widgets/common/error_view.dart';
import '../widgets/common/trust_level_skeleton.dart';
import '../services/network/discourse_dio.dart';
import '../l10n/s.dart';

class TrustLevelRequirementsPage extends ConsumerStatefulWidget {
  const TrustLevelRequirementsPage({super.key});

  @override
  ConsumerState<TrustLevelRequirementsPage> createState() =>
      _TrustLevelRequirementsPageState();
}

class _TrustLevelRequirementsPageState
    extends ConsumerState<TrustLevelRequirementsPage> {
  bool _isLoading = true;
  Object? _error;
  StackTrace? _errorStack;
  TrustLevelData? _data;

  @override
  void initState() {
    super.initState();
    _fetchData();
  }

  Future<void> _fetchData() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _errorStack = null;
    });

    try {
      final dio = DiscourseDio.create();
      final response = await dio.get('https://connect.linux.do/');

      if (response.statusCode == 200) {
        await _parseHtml(response.data);
      } else {
        if (!mounted) return;
        setState(() {
          _error = Exception(
            S.current.trustLevel_requestFailed(response.statusCode ?? 0),
          );
          _isLoading = false;
        });
      }
    } catch (e, s) {
      setState(() {
        _error = e;
        _errorStack = s;
        _isLoading = false;
      });
    }
  }

  Future<void> _parseHtml(String htmlContent) async {
    try {
      final document = html_parser.parse(htmlContent);

      final cardDiv = document.querySelector('div.card');
      if (cardDiv == null) {
        throw Exception(S.current.trustLevel_parseNotFound);
      }

      final emptyState = await _parseEmptyState(cardDiv);
      if (emptyState != null) {
        if (!mounted) return;
        setState(() {
          _data = emptyState;
          _isLoading = false;
        });
        return;
      }

      // 1. Title & Badge & Status Text
      final titleEl = cardDiv.querySelector('h2.card-title');
      final title = titleEl?.text.trim() ?? S.current.trustLevel_title;

      final badgeEl = cardDiv.querySelector('.badge');
      final badgeText = badgeEl?.text.trim() ?? '';
      // badge-success / badge-danger / badge-warning
      final Set<String> badgeClasses = badgeEl?.classes ?? <String>{};
      final badgeType = badgeClasses.contains('badge-success')
          ? TlBadgeType.success
          : badgeClasses.contains('badge-danger')
          ? TlBadgeType.danger
          : TlBadgeType.warning;

      // 2. Subtitle
      final subtitleEl = cardDiv.querySelector('.card-subtitle');
      final subtitle = subtitleEl?.text.trim() ?? '';

      // 3. Rings
      final ringEls = cardDiv.querySelectorAll('.tl3-ring');
      final rings = ringEls.map((el) {
        final label = el.querySelector('.tl3-ring-label')?.text.trim() ?? '';
        final circle = el.querySelector('.tl3-ring-circle');
        final isMet = circle?.classes.contains('met') ?? false;

        final style = circle?.attributes['style'] ?? '';
        final val = _parseCssVar(style, '--val');
        final max = _parseCssVar(style, '--max');

        return TlRingData(
          label: label,
          current: val.toInt(),
          max: max.toInt(),
          isMet: isMet,
        );
      }).toList();

      // 4. Bars
      final barEls = cardDiv.querySelectorAll('.tl3-bar-item');
      final bars = barEls.map((el) {
        final label = el.querySelector('.tl3-bar-label')?.text.trim() ?? '';
        final nums = el.querySelector('.tl3-bar-nums')?.text.trim() ?? '';
        final fill = el.querySelector('.tl3-bar-fill');
        final isMet = fill?.classes.contains('met') ?? false;

        final style = fill?.attributes['style'] ?? '';
        final val = _parseCssVar(style, '--val');
        final max = _parseCssVar(style, '--max');

        return TlBarData(
          label: label,
          current: nums,
          target: max.toStringAsFixed(0),
          progress: max > 0 ? (val / max).clamp(0.0, 1.0) : 0.0,
          isMet: isMet,
        );
      }).toList();

      // 5. Quotas
      final quotaEls = cardDiv.querySelectorAll('.tl3-quota-card');
      final quotas = quotaEls.map((el) {
        final label = el.querySelector('.tl3-quota-label')?.text.trim() ?? '';
        final nums = el.querySelector('.tl3-quota-nums')?.text.trim() ?? '';
        // "met" class on card normally, if it has "unmet", it is red
        final isMet = !el.classes.contains('unmet');

        // Count used slots
        final slots = el.querySelectorAll('.tl3-slot.used').length;

        return TlQuotaData(
          label: label,
          value: nums,
          isMet: isMet,
          usedSlots: slots,
          totalSlots: 5, // Default assumption from visual
        );
      }).toList();

      // 6. Vetos
      final vetoEls = cardDiv.querySelectorAll('.tl3-veto-item');
      final vetos = vetoEls.map((el) {
        final isMet = !el.classes.contains('unmet');

        // If unmet, we actually display the back face data which might be different or at least red.
        final front = el.querySelector('.tl3-veto-front');
        final back = el.querySelector('.tl3-veto-back');

        final targetFace = isMet ? front : back;

        final label =
            targetFace?.querySelector('.tl3-veto-label')?.text.trim() ?? '';
        final desc =
            targetFace?.querySelector('.tl3-veto-desc')?.text.trim() ?? '';
        final value =
            targetFace?.querySelector('.tl3-veto-value')?.text.trim() ?? '0';

        return TlVetoData(label: label, desc: desc, value: value, isMet: isMet);
      }).toList();

      // 7. Footer
      final hintEl = cardDiv.querySelector('.text-hint');
      final footerHint = hintEl?.text.trim() ?? '';

      final statusEl = cardDiv.querySelector('.status-met, .status-unmet');
      final statusText = statusEl?.text.trim() ?? '';
      final isStatusMet = statusEl?.classes.contains('status-met') ?? false;

      if (!mounted) return;
      setState(() {
        _data = TrustLevelData(
          title: title,
          badgeText: badgeText,
          badgeType: badgeType,
          subtitle: subtitle,
          rings: rings,
          bars: bars,
          quotas: quotas,
          vetos: vetos,
          footerHint: footerHint,
          statusText: statusText,
          isStatusMet: isStatusMet,
        );
        _isLoading = false;
      });
    } catch (e, s) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _errorStack = s;
        _isLoading = false;
      });
    }
  }

  Future<TrustLevelData?> _parseEmptyState(html_dom.Element cardDiv) async {
    if (!cardDiv.classes.contains('empty-state')) {
      return null;
    }

    final title = cardDiv.querySelector('h2.card-title')?.text.trim();
    final paragraphs = cardDiv
        .querySelectorAll('p')
        .map((el) => el.text.trim())
        .where((text) => text.isNotEmpty)
        .toList();

    if ((title == null || title.isEmpty) && paragraphs.isEmpty) {
      return null;
    }

    final allText = [title, ...paragraphs].whereType<String>().join(' ');
    final currentLevel = _parseCurrentTrustLevel(allText);
    final summary = await _loadUserSummaryOrNull();

    return TrustLevelData(
      title: title?.isNotEmpty == true ? title! : S.current.trustLevel_title,
      badgeText: '',
      badgeType: TlBadgeType.warning,
      subtitle: paragraphs.isNotEmpty ? paragraphs.first : '',
      rings: const [],
      bars: const [],
      quotas: const [],
      vetos: const [],
      footerHint: paragraphs.length > 1 ? paragraphs.sublist(1).join('\n') : '',
      statusText: '',
      isStatusMet: false,
      isEmptyState: true,
      currentLevel: currentLevel,
      fallbackRequirements: _buildFallbackRequirements(currentLevel, summary),
    );
  }

  Future<UserSummary?> _loadUserSummaryOrNull() async {
    try {
      return await ref.read(userSummaryProvider.future);
    } catch (_) {
      return ref.read(userSummaryProvider).value;
    }
  }

  int? _parseCurrentTrustLevel(String text) {
    final patterns = [
      RegExp(r'当前\s*(\d+)\s*级'),
      RegExp(r'当前信任等级[:：]?\s*(\d+)'),
      RegExp(r'(\d+)\s*级用户'),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(text);
      if (match == null) continue;
      return int.tryParse(match.group(1) ?? '');
    }

    return null;
  }

  List<TlFallbackRequirement> _buildFallbackRequirements(
    int? level,
    UserSummary? summary,
  ) {
    final readingMinutes = summary == null ? null : summary.timeRead ~/ 60;

    switch (level) {
      case 0:
        return [
          TlFallbackRequirement(
            label: '浏览话题',
            currentValue: summary?.topicsEntered,
            requiredValue: 5,
          ),
          TlFallbackRequirement(
            label: '已读帖子',
            currentValue: summary?.postsReadCount,
            requiredValue: 30,
          ),
          TlFallbackRequirement(
            label: '阅读时间',
            currentValue: readingMinutes,
            requiredValue: 10,
            unit: '分钟',
          ),
        ];
      case 1:
        return [
          TlFallbackRequirement(
            label: '访问天数',
            currentValue: summary?.daysVisited,
            requiredValue: 15,
            unit: '天',
          ),
          TlFallbackRequirement(
            label: '送出赞',
            currentValue: summary?.likesGiven,
            requiredValue: 1,
          ),
          TlFallbackRequirement(
            label: '获赞',
            currentValue: summary?.likesReceived,
            requiredValue: 1,
          ),
          TlFallbackRequirement(
            label: '回复',
            currentValue: summary?.postCount,
            requiredValue: 3,
          ),
          TlFallbackRequirement(
            label: '浏览话题',
            currentValue: summary?.topicsEntered,
            requiredValue: 20,
          ),
          TlFallbackRequirement(
            label: '已读帖子',
            currentValue: summary?.postsReadCount,
            requiredValue: 100,
          ),
          TlFallbackRequirement(
            label: '阅读时间',
            currentValue: readingMinutes,
            requiredValue: 60,
            unit: '分钟',
          ),
        ];
      case 2:
      case 3:
      case 4:
        return [
          TlFallbackRequirement(
            label: '访问次数',
            currentValue: summary?.daysVisited,
            requiredValue: 50,
          ),
          TlFallbackRequirement(
            label: '回复',
            currentValue: summary?.postCount,
            requiredValue: 10,
          ),
          TlFallbackRequirement(
            label: '浏览话题',
            currentValue: summary?.topicsEntered,
            requiredValue: 500,
          ),
          TlFallbackRequirement(
            label: '已读帖子',
            currentValue: summary?.postsReadCount,
            requiredValue: 20000,
          ),
          TlFallbackRequirement(
            label: '点赞',
            currentValue: summary?.likesGiven,
            requiredValue: 30,
          ),
          TlFallbackRequirement(
            label: '获赞',
            currentValue: summary?.likesReceived,
            requiredValue: 20,
          ),
          const TlFallbackRequirement(
            label: '被举报帖子',
            currentValue: 0,
            requiredValue: 5,
            isReverse: true,
          ),
          const TlFallbackRequirement(
            label: '发起举报用户',
            currentValue: 0,
            requiredValue: 5,
            isReverse: true,
          ),
          const TlFallbackRequirement(
            label: '被禁言',
            currentValue: 0,
            requiredValue: 0,
            isReverse: true,
          ),
          const TlFallbackRequirement(
            label: '被封禁',
            currentValue: 0,
            requiredValue: 0,
            isReverse: true,
          ),
        ];
      default:
        return const [];
    }
  }

  double _parseCssVar(String style, String varName) {
    final regex = RegExp('$varName:\\s*([0-9.]+)');
    final match = regex.firstMatch(style);
    if (match != null) {
      return double.tryParse(match.group(1) ?? '0') ?? 0;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Background color strictly following the theme surface
    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: _isLoading
          ? const TrustLevelSkeleton()
          : _error != null
          ? _buildError(theme)
          : _data == null
          ? _buildEmpty(theme)
          : _data!.isEmptyState
          ? _buildTrustLevelEmptyState(theme)
          : M3eRefreshIndicator(
              onRefresh: _fetchData,
              child: CustomScrollView(
                slivers: [
                  _buildAppBar(theme),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const SizedBox(height: 24),
                          _buildCard(
                            theme,
                            title: context.l10n.trustLevel_activity,
                            child: _buildRings(theme),
                          ),
                          const SizedBox(height: 16),
                          _buildCard(
                            theme,
                            title: context.l10n.trustLevel_interaction,
                            child: _buildBars(theme),
                          ),
                          const SizedBox(height: 16),
                          _buildCard(
                            theme,
                            title: context.l10n.trustLevel_compliance,
                            child: _buildCompliance(theme),
                          ),
                          const SizedBox(height: 24),
                          _buildFooter(theme),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildAppBar(ThemeData theme) {
    final colorScheme = theme.colorScheme;

    // Badge colors logic
    Color badgeBg;
    Color badgeText;
    switch (_data!.badgeType) {
      case TlBadgeType.success:
        badgeBg = const Color(0xFF22c55e).withValues(alpha: 0.1);
        badgeText = const Color(0xFF22c55e);
        break;
      case TlBadgeType.danger:
        badgeBg = const Color(0xFFef4444).withValues(alpha: 0.1);
        badgeText = const Color(0xFFef4444);
        break;
      default:
        badgeBg = const Color(0xFFf59e0b).withValues(alpha: 0.1);
        badgeText = const Color(0xFFf59e0b);
        break;
    }

    return SliverAppBar.large(
      title: Text(context.l10n.trustLevel_appBarTitle),
      centerTitle: false,
      expandedHeight: 200,
      flexibleSpace: FlexibleSpaceBar(
        background: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                colorScheme.surface,
                colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Stack(
            children: [
              Positioned(
                right: -20,
                top: -20,
                child: Icon(
                  Symbols.verified_user_rounded,
                  size: 200,
                  color: colorScheme.primary.withValues(alpha: 0.05),
                ),
              ),
              Positioned(
                left: 20 + MediaQuery.of(context).padding.left,
                bottom: 20,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _data!.subtitle,
                      style: TextStyle(
                        fontSize: 14,
                        color: colorScheme.secondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _data!.title,
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (_data!.badgeText.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: badgeBg,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: badgeText.withValues(alpha: 0.2),
                          ),
                        ),
                        child: Text(
                          _data!.badgeText,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: badgeText,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCard(
    ThemeData theme, {
    required String title,
    required Widget child,
  }) {
    final colorScheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
        boxShadow: [
          BoxShadow(
            color: colorScheme.shadow.withValues(alpha: 0.02),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.8,
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }

  Widget _buildRings(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Typically 3 rings in a row
        final width = constraints.maxWidth / 3;
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _data!.rings
              .map(
                (ring) =>
                    SizedBox(width: width, child: _buildRingItem(theme, ring)),
              )
              .toList(),
        );
      },
    );
  }

  Widget _buildRingItem(ThemeData theme, TlRingData ring) {
    final colorScheme = theme.colorScheme;
    final progress = ring.max > 0
        ? (ring.current / ring.max).clamp(0.0, 1.0)
        : 0.0;

    // met -> #22c55e, unmet -> #f59e0b
    // Increase size to match 88px ~ 80-90 logical pixels
    final color = ring.isMet
        ? const Color(0xFF22c55e)
        : const Color(0xFFf59e0b);

    return Column(
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            // M3eCircularProgress 自带 track,底轨+进度合一
            M3eCircularProgress(
              value: progress,
              size: 80,
              strokeWidth: 8,
              color: color,
              trackColor: colorScheme.secondaryContainer.withValues(alpha: 0.5),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${ring.current}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: colorScheme.onSurface,
                  ),
                ),
                Text(
                  '/${ring.max}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.outline,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          ring.label,
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w500,
            color: colorScheme.secondary,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildBars(ThemeData theme) {
    return Column(
      children: _data!.bars.map((bar) => _buildBarItem(theme, bar)).toList(),
    );
  }

  Widget _buildBarItem(ThemeData theme, TlBarData bar) {
    final colorScheme = theme.colorScheme;

    final labelColor = bar.isMet
        ? const Color(0xFF22c55e)
        : const Color(0xFFf59e0b);

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                bar.label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.secondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                bar.current,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: labelColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Container(
              height: 8,
              width: double.infinity,
              color: colorScheme.secondaryContainer.withValues(alpha: 0.5),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: bar.progress,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: bar.isMet
                          ? [const Color(0xFF22c55e), const Color(0xFF4ade80)]
                          : [const Color(0xFFf59e0b), const Color(0xFFfbbf24)],
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                    ),
                    borderRadius: BorderRadius.circular(4),
                    boxShadow: [
                      BoxShadow(
                        color: bar.isMet
                            ? const Color(0xFF22c55e).withValues(alpha: 0.4)
                            : const Color(0xFFf59e0b).withValues(alpha: 0.4),
                        blurRadius: 6,
                        spreadRadius: 0,
                        offset: const Offset(0, 0),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompliance(ThemeData theme) {
    return Column(
      children: [
        Row(
          children: _data!.quotas
              .map(
                (quota) => Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: _buildQuotaCard(theme, quota),
                  ),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 12),
        Row(
          children: _data!.vetos
              .map(
                (veto) => Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: _buildVetoCard(theme, veto),
                  ),
                ),
              )
              .toList(),
        ),
      ],
    );
  }

  Widget _buildQuotaCard(ThemeData theme, TlQuotaData quota) {
    final colorScheme = theme.colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Met: default card style
    // Unmet: red border, red bg tint

    final borderColor = quota.isMet
        ? colorScheme.outlineVariant.withValues(alpha: 0.4)
        : const Color(0xFFef4444).withValues(alpha: 0.3);

    final bgColor = quota.isMet
        ? colorScheme.surface
        : (isDark ? const Color(0xFF2e0a0a) : const Color(0xFFfef2f2));

    final textColor = quota.isMet
        ? colorScheme.onSurfaceVariant
        : const Color(0xFFef4444);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  quota.label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.secondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                quota.value,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(5, (index) {
              // Used slots are danger style, unused are success style
              final isUsed = index < quota.usedSlots;
              final color = isUsed
                  ? const Color(0xFFef4444)
                  : const Color(0xFF22c55e);

              return Expanded(
                child: Container(
                  height: 6,
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: isUsed ? 0.9 : 0.2),
                    borderRadius: BorderRadius.circular(3),
                    boxShadow: isUsed
                        ? [
                            BoxShadow(
                              color: color.withValues(alpha: 0.3),
                              blurRadius: 4,
                            ),
                          ]
                        : null,
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildVetoCard(ThemeData theme, TlVetoData veto) {
    // If Met -> Green style
    // If Unmet -> Red style

    final isDark = Theme.of(context).brightness == Brightness.dark;

    Color bgColor;
    Color borderColor;
    Color iconBg;
    Color iconColor;

    if (veto.isMet) {
      bgColor = isDark ? const Color(0xFF0a2e14) : const Color(0xFFf0fdf4);
      borderColor = const Color(0xFF22c55e).withValues(alpha: 0.2);
      iconBg = const Color(0xFF22c55e).withValues(alpha: 0.15);
      iconColor = const Color(0xFF22c55e);
    } else {
      bgColor = isDark ? const Color(0xFF2e0a0a) : const Color(0xFFfef2f2);
      borderColor = const Color(0xFFef4444).withValues(alpha: 0.2);
      iconBg = const Color(0xFFef4444).withValues(alpha: 0.15);
      iconColor = const Color(0xFFef4444);
    }

    return Container(
      height: 100,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: iconBg,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  veto.isMet ? Symbols.check_rounded : Symbols.close_rounded,
                  size: 16,
                  color: iconColor,
                ),
              ),
              Text(
                veto.value,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: iconColor,
                ),
              ),
            ],
          ),
          const Spacer(),
          Text(
            veto.label,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          Text(
            veto.desc,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 10,
              color: Theme.of(context).colorScheme.secondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(ThemeData theme) {
    final statusColor = _data!.isStatusMet
        ? const Color(0xFF22c55e)
        : const Color(0xFFef4444);

    return Column(
      children: [
        const Divider(height: 32, thickness: 0.5),
        if (_data!.footerHint.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _data!.footerHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        if (_data!.statusText.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: statusColor.withValues(alpha: 0.2)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _data!.isStatusMet
                      ? Symbols.check_circle_rounded
                      : Symbols.cancel_rounded,
                  color: statusColor,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    _data!.statusText,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: statusColor,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildEmpty(ThemeData theme) {
    return Center(child: Text(context.l10n.common_noData));
  }

  Widget _buildTrustLevelEmptyState(ThemeData theme) {
    final colorScheme = theme.colorScheme;

    return M3eRefreshIndicator(
      onRefresh: _fetchData,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverAppBar.large(
            title: Text(context.l10n.trustLevel_appBarTitle),
            centerTitle: false,
          ),
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 48, 24, 48),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: colorScheme.outlineVariant.withValues(
                          alpha: 0.3,
                        ),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: colorScheme.primaryContainer.withValues(
                              alpha: 0.45,
                            ),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Symbols.star_rounded,
                            color: colorScheme.primary,
                            size: 28,
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          _data!.title,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: colorScheme.onSurface,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        if (_data!.subtitle.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            _data!.subtitle,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                        if (_data!.footerHint.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            _data!.footerHint,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.outline,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                        if (_data!.fallbackRequirements.isNotEmpty) ...[
                          const SizedBox(height: 24),
                          _buildFallbackRequirementList(theme),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(ThemeData theme) {
    return ErrorView(
      error: _error!,
      stackTrace: _errorStack,
      onRetry: _fetchData,
    );
  }

  Widget _buildFallbackRequirementList(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final currentLevel = _data!.currentLevel;
    final targetLevel = currentLevel == null ? null : currentLevel + 1;
    final title = targetLevel == null ? '可参考要求' : '升至信任级别 $targetLevel 的参考要求';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Divider(color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
        const SizedBox(height: 16),
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurface,
          ),
          textAlign: TextAlign.left,
        ),
        const SizedBox(height: 6),
        Text(
          '当前页面未开放 connect 详情，以下进度来自个人统计数据。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.outline,
          ),
        ),
        const SizedBox(height: 14),
        Column(
          children: _data!.fallbackRequirements
              .map((item) => _buildFallbackRequirementItem(theme, item))
              .toList(),
        ),
      ],
    );
  }

  Widget _buildFallbackRequirementItem(
    ThemeData theme,
    TlFallbackRequirement item,
  ) {
    final colorScheme = theme.colorScheme;
    final isMet = item.isMet;
    final progress = item.progress;
    final color = isMet ? const Color(0xFF22c55e) : const Color(0xFFf59e0b);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Icon(
                  isMet
                      ? Symbols.check_circle_rounded
                      : Symbols.radio_button_unchecked_rounded,
                  color: color,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item.label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  item.valueText,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            M3eLinearProgress(
              value: progress,
              color: color,
              trackColor: colorScheme.secondaryContainer.withValues(
                alpha: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Models
enum TlBadgeType { success, warning, danger }

class TrustLevelData {
  final String title;
  final String badgeText;
  final TlBadgeType badgeType;
  final String subtitle;
  final List<TlRingData> rings;
  final List<TlBarData> bars;
  final List<TlQuotaData> quotas;
  final List<TlVetoData> vetos;
  final String footerHint;
  final String statusText;
  final bool isStatusMet;
  final bool isEmptyState;
  final int? currentLevel;
  final List<TlFallbackRequirement> fallbackRequirements;

  TrustLevelData({
    required this.title,
    required this.badgeText,
    required this.badgeType,
    required this.subtitle,
    required this.rings,
    required this.bars,
    required this.quotas,
    required this.vetos,
    required this.footerHint,
    required this.statusText,
    required this.isStatusMet,
    this.isEmptyState = false,
    this.currentLevel,
    this.fallbackRequirements = const [],
  });
}

class TlFallbackRequirement {
  final String label;
  final int? currentValue;
  final int requiredValue;
  final String unit;
  final bool isReverse;

  const TlFallbackRequirement({
    required this.label,
    required this.currentValue,
    required this.requiredValue,
    this.unit = '',
    this.isReverse = false,
  });

  bool get isMet {
    final current = currentValue;
    if (current == null) return false;
    return isReverse ? current <= requiredValue : current >= requiredValue;
  }

  double get progress {
    final current = currentValue;
    if (current == null) return 0;
    if (isReverse) {
      if (requiredValue == 0) return current <= 0 ? 1 : 0;
      return (1 - current / requiredValue).clamp(0.0, 1.0);
    }
    if (requiredValue <= 0) return isMet ? 1 : 0;
    return (current / requiredValue).clamp(0.0, 1.0);
  }

  String get valueText {
    final currentText = currentValue == null ? '-' : '$currentValue';
    final targetText = isReverse ? '≤ $requiredValue' : '$requiredValue';
    final suffix = unit.isEmpty ? '' : ' $unit';
    return '$currentText / $targetText$suffix';
  }
}

class TlRingData {
  final String label;
  final int current;
  final int max;
  final bool isMet;

  TlRingData({
    required this.label,
    required this.current,
    required this.max,
    required this.isMet,
  });
}

class TlBarData {
  final String label;
  final String current;
  final String target;
  final double progress;
  final bool isMet;

  TlBarData({
    required this.label,
    required this.current,
    required this.target,
    required this.progress,
    required this.isMet,
  });
}

class TlQuotaData {
  final String label;
  final String value;
  final bool isMet;
  final int usedSlots;
  final int totalSlots;

  TlQuotaData({
    required this.label,
    required this.value,
    required this.isMet,
    required this.usedSlots,
    required this.totalSlots,
  });
}

class TlVetoData {
  final String label;
  final String desc;
  final String value;
  final bool isMet;

  TlVetoData({
    required this.label,
    required this.desc,
    required this.value,
    required this.isMet,
  });
}
