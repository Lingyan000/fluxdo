import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import '../../../../models/topic.dart';
import 'package:dio/dio.dart';
import '../../../../services/app_error_handler.dart';
import '../../../../services/discourse/discourse_service.dart';
import '../../../../utils/time_utils.dart';
import '../../../../l10n/s.dart';

/// 构建投票块
Widget buildPoll({
  required BuildContext context,
  required ThemeData theme,
  required dynamic element,
  required Post post,
}) {
  final pollTitle = _extractPollTitle(element);
  final pollName = element.attributes['data-poll-name'] ?? 'poll';
  final poll = post.polls?.firstWhere((p) => p.name == pollName, orElse: () => Poll(id: 0, name: pollName, type: 'regular', status: 'open', results: 'always', options: [], voters: 0));

  if (poll == null || poll.options.isEmpty) {
    return const SizedBox.shrink();
  }

  final userVotes = post.pollsVotes?[pollName] ?? [];

  return _PollWidget(
    poll: poll,
    title: pollTitle,
    post: post,
    userVotes: userVotes,
    // 图表类型来自 cooked 属性(API poll 数据不带 chart_type);
    // number 型没有该属性 → null → bar 现状
    chartType: element.attributes['data-poll-charttype'] as String?,
    // 落地到 post 实例:widget 滚出 cacheExtent 销毁后重建时从这里现读。
    // (首次投票时 post.pollsVotes 为 null,applyPollUpdate 内部 ??= 初始化。)
    onPollUpdated: (updatedPoll, updatedVotes) =>
        post.applyPollUpdate(pollName, updatedPoll, updatedVotes),
  );
}

/// 无 post 场景(富 composer 岛预览等)的静态投票预览卡。
///
/// 数据不走 API,全部从 cooked `div.poll` DOM 解出:标题(.poll-title)、
/// 选项(li[data-poll-option-id])、属性(data-poll-*)。无投票交互,
/// 展示「标题 + 类型徽标 + 选项列表 + 属性摘要」——编辑器里插入 [poll]
/// BBCode 后 cook 出来的就是这个形态,所见即所发。
///
/// number 型选项 li 是 min/max/step 派生的数字全集,逐项列出冗长,
/// 压缩为范围摘要行。
Widget buildPollStaticPreview({
  required BuildContext context,
  required ThemeData theme,
  required dynamic element,
}) {
  final attrs = element.attributes;
  String? attr(String key) {
    final v = (attrs[key] as String?)?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  final type = attr('data-poll-type') ?? 'regular';
  // 标题:.poll-title 富文本取纯文本(emoji 用 alt 补位),
  // 属性形态(data-poll-question)走 legacy 提取
  String? title = _extractPollTitle(element);
  final titleEls = element.getElementsByClassName('poll-title');
  if (titleEls.isNotEmpty) {
    final t = _textWithEmojiAlt(titleEls.first);
    if (t.isNotEmpty) title = t;
  }
  final isNumber = type == 'number';

  final options = <String>[
    if (!isNumber)
      for (final li in element.querySelectorAll('li[data-poll-option-id]'))
        _textWithEmojiAlt(li),
  ];

  // 类型徽标文案
  final typeLabel = switch (type) {
    'multiple' => '多选',
    'number' => '评分',
    'ranked_choice' => '排序',
    _ => '单选',
  };

  // 属性摘要:多选范围 / 评分范围 / 结果可见性 / 公开 / 自动关闭
  final summary = <String>[];
  final min = attr('data-poll-min');
  final max = attr('data-poll-max');
  if (type == 'multiple' && (min != null || max != null)) {
    summary.add('选 ${min ?? '1'}-${max ?? options.length} 项');
  }
  if (isNumber) {
    final step = attr('data-poll-step');
    summary.add(
      '范围 ${min ?? '1'}-${max ?? '10'}'
      '${step != null && step != '1' ? ' 步长 $step' : ''}',
    );
  }
  switch (attr('data-poll-results')) {
    case 'on_vote':
      summary.add('结果投票后可见');
    case 'on_close':
      summary.add('结果关闭后可见');
    case 'staff_only':
      summary.add('结果仅管理人员可见');
  }
  if (attr('data-poll-public') == 'true') summary.add('公开投票人');
  if (attr('data-poll-charttype') == 'pie') summary.add('饼图');
  final close = attr('data-poll-close');
  if (close != null) {
    final closeTime = TimeUtils.parseUtcTime(close);
    if (closeTime != null) {
      summary.add('${TimeUtils.formatShortDate(closeTime)} 自动关闭');
    }
  }
  if (attr('data-poll-status') == 'closed') summary.add('已关闭');

  final scheme = theme.colorScheme;
  return Container(
    margin: const EdgeInsets.symmetric(vertical: 12),
    decoration: BoxDecoration(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.2),
      border: Border.all(
        color: scheme.outline.withValues(alpha: 0.3),
        width: 1,
      ),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 头部:类型徽标 + 标题
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  typeLabel,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ),
              if (title != null && title.isNotEmpty) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ] else
                const Spacer(),
            ],
          ),
        ),
        // 选项列表(静态,无点击态);number 型无选项行,靠摘要
        if (options.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Column(
              children: [
                for (var i = 0; i < options.length; i++)
                  Padding(
                    padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: scheme.surface,
                        border: Border.all(
                          color: scheme.outline.withValues(alpha: 0.2),
                        ),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            type == 'multiple'
                                ? Symbols.check_box_outline_blank_rounded
                                : Symbols.radio_button_unchecked_rounded,
                            size: 20,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              options[i],
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        // 底部:属性摘要
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          margin: const EdgeInsets.only(top: 4),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: scheme.outline.withValues(alpha: 0.2)),
            ),
          ),
          child: Row(
            children: [
              Icon(
                Symbols.poll_rounded,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  summary.isEmpty ? '投票' : summary.join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// 元素纯文本,但 emoji `<img class="emoji" alt=":x:">` 用 alt 补位 ——
/// 直接 .text 会把选项里的 emoji 静默吞掉,长得像丢字。
String _textWithEmojiAlt(dynamic el) {
  final buf = StringBuffer();
  void walk(dynamic node) {
    // html 包:Element 有 localName;Text 节点走 nodeType==3
    if (node.nodeType == 3) {
      buf.write(node.text ?? '');
      return;
    }
    final attrs = node.attributes;
    if (attrs is Map && (attrs['class'] as String? ?? '').contains('emoji')) {
      buf.write(attrs['alt'] as String? ?? '');
      return;
    }
    for (final child in node.nodes) {
      walk(child);
    }
  }

  walk(el);
  return buf.toString().trim();
}

String? _extractPollTitle(dynamic element) {
  final attributeTitle = element.attributes['data-poll-question'] ?? element.attributes['data-poll-title'];
  if (attributeTitle is String && attributeTitle.trim().isNotEmpty) {
    return attributeTitle.trim();
  }

  final pollTitleElements = element.getElementsByClassName('poll-title');
  if (pollTitleElements.isNotEmpty) {
    final text = pollTitleElements.first.text.trim();
    if (text.isNotEmpty) {
      return text;
    }
  }

  final pollQuestionElements = element.getElementsByClassName('poll-question');
  if (pollQuestionElements.isNotEmpty) {
    final text = pollQuestionElements.first.text.trim();
    if (text.isNotEmpty) {
      return text;
    }
  }

  return null;
}

class _PollWidget extends StatefulWidget {
  final Poll poll;
  final String? title;
  final Post post;
  final List<String> userVotes;
  final String? chartType; // cooked data-poll-charttype:'bar' | 'pie' | null
  final Function(Poll, List<String>) onPollUpdated;

  const _PollWidget({
    required this.poll,
    this.title,
    required this.post,
    required this.userVotes,
    this.chartType,
    required this.onPollUpdated,
  });

  @override
  State<_PollWidget> createState() => _PollWidgetState();
}

class _PollWidgetState extends State<_PollWidget> {
  late Poll _poll;
  late List<String> _userVotes;
  late bool _showResults;
  bool _isVoting = false;
  bool _showPercentage = true; // true: 百分比, false: 计数

  /// 饼图图例点击隐藏的选项 index 集(chart.js toggleDataVisibility
  /// 同款,纯本地视图态,不影响投票数据)
  final Set<int> _pieHidden = {};

  @override
  void initState() {
    super.initState();
    _poll = widget.poll;
    _userVotes = List.from(widget.userVotes);
    _showResults = _shouldShowResults();
  }

  bool _shouldShowResults() {
    final hasVoted = _userVotes.isNotEmpty;
    final isClosed = _poll.status == 'closed';

    // 如果是 on_close 且未关闭，不显示结果
    if (_poll.results == 'on_close' && !isClosed) {
      return false;
    }

    // 如果是 staff_only，不显示结果（需要管理员权限）
    if (_poll.results == 'staff_only') {
      return false;
    }

    // 满足以下任一条件就显示结果
    return hasVoted || isClosed;
  }

  bool get _isMultiple => _poll.type == 'multiple';

  Future<void> _vote(String optionId) async {
    if (_poll.status == 'closed' || _isVoting) return;

    setState(() => _isVoting = true);

    try {
      // 多选：切换选项
      List<String> votesToSubmit;
      if (_isMultiple) {
        if (_userVotes.contains(optionId)) {
          _userVotes.remove(optionId);
        } else {
          _userVotes.add(optionId);
        }
        votesToSubmit = List.from(_userVotes);
        setState(() {});
        return; // 多选不立即提交
      } else {
        // 单选：直接提交
        votesToSubmit = [optionId];
      }

      final result = await DiscourseService().votePoll(
        postId: widget.post.id,
        pollName: _poll.name,
        options: votesToSubmit,
      );

      if (result != null && mounted) {
        setState(() {
          _poll = result;
          _userVotes = votesToSubmit;
          _showResults = _shouldShowResults();
        });
        widget.onPollUpdated(result, votesToSubmit);
      }
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      if (mounted) setState(() => _isVoting = false);
    }
  }

  Future<void> _submitMultipleVote() async {
    if (_userVotes.isEmpty || _isVoting) return;

    setState(() => _isVoting = true);

    try {
      final result = await DiscourseService().votePoll(
        postId: widget.post.id,
        pollName: _poll.name,
        options: _userVotes,
      );

      if (result != null && mounted) {
        setState(() {
          _poll = result;
          _showResults = _shouldShowResults();
        });
        widget.onPollUpdated(result, _userVotes);
      }
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      if (mounted) setState(() => _isVoting = false);
    }
  }

  Future<void> _removeVote() async {
    if (_isVoting) return;

    setState(() => _isVoting = true);

    try {
      final result = await DiscourseService().removeVote(
        postId: widget.post.id,
        pollName: _poll.name,
      );

      if (result != null && mounted) {
        setState(() {
          _poll = result;
          _userVotes = [];
          _showResults = _shouldShowResults();
        });
        widget.onPollUpdated(result, []);
      }
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      if (mounted) setState(() => _isVoting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isClosed = _poll.status == 'closed';
    final hasVoted = _userVotes.isNotEmpty;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.3),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.title != null && widget.title!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Text(
                widget.title!,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          if (_showResults)
            _buildResults(theme)
          else
            _buildOptions(theme),

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: theme.colorScheme.outline.withValues(alpha: 0.2),
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  isClosed ? Symbols.lock_rounded : Symbols.poll_rounded,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  S.current.poll_voters(_poll.voters),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (isClosed) ...[
                  const SizedBox(width: 8),
                  Text(
                    '• ${S.current.poll_closed}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const Spacer(),
                // 多选投票按钮
                if (_isMultiple && !_showResults && _userVotes.isNotEmpty)
                  TextButton(
                    onPressed: _submitMultipleVote,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32),
                      backgroundColor: theme.colorScheme.primary,
                      foregroundColor: theme.colorScheme.onPrimary,
                    ),
                    child: Text(
                      S.current.poll_vote,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onPrimary,
                      ),
                    ),
                  ),
                // 撤销投票按钮
                if (!isClosed && hasVoted && !_showResults && !_isMultiple)
                  TextButton(
                    onPressed: _removeVote,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32),
                    ),
                    child: Text(
                      S.current.poll_undo,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                // 切换显示模式按钮
                if (_showResults && _poll.voters > 0)
                  TextButton(
                    onPressed: () => setState(() => _showPercentage = !_showPercentage),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32),
                    ),
                    child: Text(
                      _showPercentage ? S.current.poll_count : S.current.poll_percentage,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                // 投票/查看结果切换按钮 - 当 results 为 always 或者用户已投票时显示
                if (!isClosed && (hasVoted || _poll.results == 'always'))
                  TextButton(
                    onPressed: () => setState(() => _showResults = !_showResults),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32),
                    ),
                    child: Text(
                      _showResults ? S.current.poll_vote : S.current.poll_viewResults,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOptions(ThemeData theme) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      itemCount: _poll.options.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final option = _poll.options[index];
        final isUserVoted = _userVotes.contains(option.id);

        return InkWell(
          onTap: _isVoting ? null : () => _vote(option.id),
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isUserVoted
                  ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
                  : theme.colorScheme.surface,
              border: Border.all(
                color: isUserVoted
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outline.withValues(alpha: 0.2),
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                // 单选/多选图标
                Icon(
                  _isMultiple
                      ? (isUserVoted ? Symbols.check_box_rounded : Symbols.check_box_outline_blank_rounded)
                      : (isUserVoted ? Symbols.radio_button_checked_rounded : Symbols.radio_button_unchecked_rounded),
                  size: 20,
                  color: isUserVoted ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    option.html.replaceAll(RegExp(r'<[^>]*>'), ''),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: isUserVoted ? FontWeight.w500 : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildResults(ThemeData theme) {
    // chartType=pie(官方 poll 插件的饼图形态):结果区换饼图 + 图例。
    // 判定主源是 API poll.chart_type(serializer 直接下发,可靠);
    // cooked 的 data-poll-charttype 只作兜底(旧缓存数据无此字段时)。
    // 无人投票时饼图无意义,回落条形列表(显示 0 票选项)。
    final chartType = _poll.chartType ?? widget.chartType;
    if (chartType == 'pie' && _poll.voters > 0) {
      return _buildPieResults(theme);
    }
    return _buildBarResults(theme);
  }

  /// 饼图结果:CustomPaint 饼 + 官方式图例(图下方横向流式小色块+标签)。
  ///
  /// 对齐官方 poll-results-pie:配色走 chart-colors.js 的 cool 渐变
  /// (白→浅绿→蓝→深藏青→黑按选项数取样);图例点击切换该选项
  /// 显隐(chart.js toggleDataVisibility 同款,隐藏项图例淡显 0.2、
  /// 扇区剔除后占比重算);桌面 hover / 触屏点按扇区出「标签+票数」
  /// 气泡。
  Widget _buildPieResults(ThemeData theme) {
    final colors = _pieColors(theme, _poll.options.length);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: _PieChartInteractive(
              options: _poll.options,
              colors: colors,
              // 扇区描边:chart.js 默认白描边,官方暗色主题同样是白
              gapColor: Colors.white,
              showPercentage: _showPercentage,
              totalVoters: _poll.voters,
              hiddenIndexes: _pieHidden,
            ),
          ),
          const SizedBox(height: 12),
          // 官方式图例:横向 Wrap,小色块 + 纯标签;点击切换显隐
          Wrap(
            spacing: 12,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            children: [
              for (var i = 0; i < _poll.options.length; i++)
                _buildPieLegendItem(theme, i, colors[i]),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPieLegendItem(ThemeData theme, int index, Color color) {
    final option = _poll.options[index];
    final isUserVoted = _userVotes.contains(option.id);
    final hidden = _pieHidden.contains(index);
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => setState(() {
        // chart.js toggleDataVisibility 同款:点图例切换该项参与绘制
        if (!_pieHidden.remove(index)) _pieHidden.add(index);
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Opacity(
          // 官方 htmlLegend:隐藏项整行淡显 0.2
          opacity: hidden ? 0.2 : 1.0,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(
                    color:
                        theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
                    width: 0.5,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              if (isUserVoted) ...[
                Icon(
                  Symbols.check_circle_rounded,
                  size: 14,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 2),
              ],
              Text(
                option.html.replaceAll(RegExp(r'<[^>]*>'), ''),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: isUserVoted ? FontWeight.w600 : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 官方 chart-colors.js 的 cool 渐变移植:5 个锚点
  /// (白 → 浅绿 → 蓝 → 深藏青 → 黑),第 i 项取样位置
  /// (i+1)*100/(count+1),两端留白避免纯白/纯黑。与网页版同图同色。
  static List<Color> _pieColors(ThemeData theme, int count) {
    if (count <= 0) return const [];
    const anchors = <(double, int, int, int)>[
      (0, 255, 255, 255),
      (25, 220, 237, 200),
      (50, 66, 179, 213),
      (75, 26, 39, 62),
      (100, 0, 0, 0),
    ];
    Color sample(double pos) {
      for (var k = 0; k < anchors.length - 1; k++) {
        final (p0, r0, g0, b0) = anchors[k];
        final (p1, r1, g1, b1) = anchors[k + 1];
        if (pos >= p0 && pos <= p1) {
          final t = (pos - p0) / (p1 - p0);
          return Color.fromARGB(
            255,
            (r0 + (r1 - r0) * t).round(),
            (g0 + (g1 - g0) * t).round(),
            (b0 + (b1 - b0) * t).round(),
          );
        }
      }
      return const Color(0xFF000000);
    }

    return [
      for (var i = 0; i < count; i++) sample((i + 1) * 100 / (count + 1)),
    ];
  }

  Widget _buildBarResults(ThemeData theme) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      itemCount: _poll.options.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final option = _poll.options[index];
        final percentage = _poll.voters > 0 ? (option.votes / _poll.voters * 100) : 0.0;
        final isUserVoted = _userVotes.contains(option.id);

        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isUserVoted
                ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
                : theme.colorScheme.surface,
            border: Border.all(
              color: isUserVoted
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline.withValues(alpha: 0.2),
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        if (isUserVoted) ...[
                          Icon(
                            Symbols.check_circle_rounded,
                            size: 16,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Text(
                            option.html.replaceAll(RegExp(r'<[^>]*>'), ''),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: isUserVoted ? FontWeight.w500 : null,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _showPercentage
                        ? '${percentage.toStringAsFixed(0)}%'
                        : '${option.votes}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: percentage / 100,
                  minHeight: 4,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation(
                    isUserVoted ? theme.colorScheme.primary : theme.colorScheme.primary.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 投票结果饼图 painter:按票数占比画扇区,扇区间用 [gapColor](表面色)
/// 描 2px 缝隙线,相邻同类色也可辨。0 票选项不画扇区(图例仍在)。
/// 可交互饼图:桌面 hover 扇区即时高亮+气泡(chart.js hover 同款),
/// 触屏点按切换;隐藏项(图例点掉)不参与绘制,占比按剩余项重算。
class _PieChartInteractive extends StatefulWidget {
  const _PieChartInteractive({
    required this.options,
    required this.colors,
    required this.gapColor,
    required this.showPercentage,
    required this.totalVoters,
    this.hiddenIndexes = const {},
  });

  final List<PollOption> options;
  final List<Color> colors;
  final Color gapColor;
  final bool showPercentage;
  final int totalVoters;

  /// 图例点击隐藏的选项 index(不画扇区,占比重算)
  final Set<int> hiddenIndexes;

  @override
  State<_PieChartInteractive> createState() => _PieChartInteractiveState();
}

class _PieChartInteractiveState extends State<_PieChartInteractive> {
  static const double _size = 220;
  int? _selected; // 触屏点按锁定的选项 index
  int? _hovered; // 桌面 hover 的选项 index(离开即清)
  Offset _pointer = Offset.zero; // 最近一次指针位置(气泡锚点,本地系)

  bool _visible(int i) => !widget.hiddenIndexes.contains(i);

  /// 参与绘制的总票数(隐藏项剔除)
  int get _visibleTotal {
    var total = 0;
    for (var i = 0; i < widget.options.length; i++) {
      if (_visible(i)) total += widget.options[i].votes;
    }
    return total;
  }

  /// 命中检测:点位 → 扇区 index(与 painter 同一角度算法,跳过隐藏项)
  int? _hitTest(Offset local) {
    final center = const Offset(_size / 2, _size / 2);
    final v = local - center;
    if (v.distance > _size / 2) return null;
    final total = _visibleTotal;
    if (total <= 0) return null;
    // 12 点起顺时针;atan2 角归一到 [0, 2π)
    var angle = math.atan2(v.dy, v.dx) + math.pi / 2;
    if (angle < 0) angle += 2 * math.pi;
    var start = 0.0;
    for (var i = 0; i < widget.options.length; i++) {
      if (!_visible(i)) continue;
      final votes = widget.options[i].votes;
      if (votes <= 0) continue;
      final sweep = 2 * math.pi * votes / total;
      if (angle >= start && angle < start + sweep) return i;
      start += sweep;
    }
    return null;
  }

  /// hover 事件坐标换算:PointerHoverEvent.localPosition 的参照系不保证
  /// 是本 widget(嵌套滚动/变换下失真,曾致「移出圆气泡不消失」),
  /// 一律用 global 位置经自身 RenderBox 反算。
  Offset _toLocal(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return Offset.zero;
    return box.globalToLocal(global);
  }

  @override
  void didUpdateWidget(_PieChartInteractive oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 选中/悬停的项被图例隐藏后清态,避免气泡指向不存在的扇区
    if (_selected != null && !_visible(_selected!)) _selected = null;
    if (_hovered != null && !_visible(_hovered!)) _hovered = null;
  }

  /// chart.js tooltip 形态:黑底圆角、标题行 + 色块+票数行,跟随指针
  /// (右下偏移,越界翻转/夹取)。
  Widget _tooltip(ThemeData theme, int index, int total) {
    final option = widget.options[index];
    final percentage = widget.showPercentage && total > 0
        ? ' (${(option.votes / total * 100).toStringAsFixed(0)}%)'
        : '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            option.html.replaceAll(RegExp(r'<[^>]*>'), ''),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 3),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: widget.colors[index % widget.colors.length],
                  border: Border.all(color: Colors.white, width: 1),
                ),
              ),
              const SizedBox(width: 5),
              Text(
                '${option.votes}$percentage',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // hover 优先于点按锁定(桌面移动即时反馈;触屏无 hover 走 selected)
    final active = _hovered ?? _selected;
    final total = _visibleTotal;
    // 气泡跟随指针:右下偏移 12;右/下越界翻到左/上侧,再整体夹取
    const tooltipW = 120.0, tooltipH = 52.0;
    var tipLeft = _pointer.dx + 12;
    var tipTop = _pointer.dy + 12;
    if (tipLeft + tooltipW > _size) tipLeft = _pointer.dx - tooltipW - 12;
    if (tipTop + tooltipH > _size) tipTop = _pointer.dy - tooltipH - 12;
    tipLeft = tipLeft.clamp(-20.0, _size - 60);
    tipTop = tipTop.clamp(-20.0, _size - 30);
    return MouseRegion(
      onHover: (e) {
        final local = _toLocal(e.position);
        final hit = _hitTest(local);
        if (hit != _hovered || (hit != null && local != _pointer)) {
          setState(() {
            _hovered = hit;
            _pointer = local;
          });
        }
      },
      onExit: (_) {
        // 离开图面清 hover 与点按锁定,气泡必消(网页 tooltip 同语义)
        if (_hovered != null || _selected != null) {
          setState(() {
            _hovered = null;
            _selected = null;
          });
        }
      },
      child: GestureDetector(
        onTapUp: (d) => setState(() {
          final local = _toLocal(d.globalPosition);
          final hit = _hitTest(local);
          _pointer = local;
          _selected = hit == _selected ? null : hit;
        }),
        child: SizedBox(
          width: _size,
          height: _size,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              CustomPaint(
                size: const Size(_size, _size),
                painter: _PiePainter(
                  votes: [
                    for (var i = 0; i < widget.options.length; i++)
                      _visible(i) ? widget.options[i].votes : 0,
                  ],
                  colors: widget.colors,
                  gapColor: widget.gapColor,
                  highlight: active,
                ),
              ),
              if (active != null)
                Positioned(
                  left: tipLeft,
                  top: tipTop,
                  child: IgnorePointer(
                    child: _tooltip(theme, active, total),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PiePainter extends CustomPainter {
  const _PiePainter({
    required this.votes,
    required this.colors,
    required this.gapColor,
    this.highlight,
  });

  final List<int> votes;
  final List<Color> colors;
  final Color gapColor;

  /// 选中扇区 index(点按气泡态):该扇区向外平移少许突出显示
  final int? highlight;

  @override
  void paint(Canvas canvas, Size size) {
    final total = votes.fold<int>(0, (a, b) => a + b);
    if (total <= 0) return;
    final center = Offset(size.width / 2, size.height / 2);
    // 留 4px 给选中扇区外扩,不被裁
    final radius = math.min(size.width, size.height) / 2 - 4;

    // 12 点方向起,顺时针(官方图表习惯)
    var start = -math.pi / 2;
    final fill = Paint()..style = PaintingStyle.fill;
    final segments = <(int, double, double, Color)>[];
    for (var i = 0; i < votes.length; i++) {
      if (votes[i] <= 0) continue;
      final sweep = 2 * math.pi * votes[i] / total;
      segments.add((i, start, sweep, colors[i % colors.length]));
      start += sweep;
    }
    for (final (index, s, sweep, color) in segments) {
      fill.color = color;
      // 选中扇区沿角平分线外移 4px 突出(官方 hover 放大等价)
      final offset = index == highlight
          ? Offset(math.cos(s + sweep / 2), math.sin(s + sweep / 2)) * 4
          : Offset.zero;
      final rect = Rect.fromCircle(center: center + offset, radius: radius);
      canvas.drawArc(rect, s, sweep, true, fill);
    }
    // 扇区间白描边(网页 chart.js 同款视觉);单扇区(100%)不画,
    // 画了会出现一道突兀的半径线
    if (segments.length > 1) {
      final gap = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = gapColor;
      for (final (index, s, _, _) in segments) {
        if (index == highlight) continue;
        canvas.drawLine(
          center,
          center + Offset(math.cos(s), math.sin(s)) * radius,
          gap,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_PiePainter oldDelegate) =>
      !listEquals(oldDelegate.votes, votes) ||
      !listEquals(oldDelegate.colors, colors) ||
      oldDelegate.gapColor != gapColor ||
      oldDelegate.highlight != highlight;
}
