import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html_parser;

import '../constants.dart';
import '../widgets/common/trust_level_skeleton.dart';
import '../services/network/discourse_dio.dart';


class TrustLevelRequirementsPage extends StatefulWidget {
  const TrustLevelRequirementsPage({super.key});

  @override
  State<TrustLevelRequirementsPage> createState() =>
      _TrustLevelRequirementsPageState();
}

class _TrustLevelRequirementsPageState
    extends State<TrustLevelRequirementsPage> {
  bool _isLoading = true;
  String? _error;
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
    });



    try {
      final dio = DiscourseDio.create();
      final response = await dio.get('${AppConstants.connectUrl}/');

      if (response.statusCode == 200) {
        _parseHtml(response.data);
      } else {
        setState(() {
          _error = '请求失败: ${response.statusCode}';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = '加载失败: $e';
        _isLoading = false;
      });
    }
  }

  void _parseHtml(String htmlContent) {
    try {
      final document = html_parser.parse(htmlContent);

      final cardDiv = document.querySelector('div.card');
      if (cardDiv == null) {
        throw Exception('未找到信任级别信息 (div.card)');
      }

      // 1. Title & Badge & Status Text
      final titleEl = cardDiv.querySelector('h2.card-title');
      final title = titleEl?.text.trim() ?? '信任级别要求';

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
            totalSlots: 5 // Default assumption from visual
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
        
        final label = targetFace?.querySelector('.tl3-veto-label')?.text.trim() ?? '';
        final desc = targetFace?.querySelector('.tl3-veto-desc')?.text.trim() ?? '';
        final value = targetFace?.querySelector('.tl3-veto-value')?.text.trim() ?? '0';
        
        return TlVetoData(
          label: label,
          desc: desc,
          value: value,
          isMet: isMet
        );
      }).toList();

      // 7. Footer
      final hintEl = cardDiv.querySelector('.text-hint');
      final footerHint = hintEl?.text.trim() ?? '';

      final statusEl = cardDiv.querySelector('.status-met, .status-unmet');
      final statusText = statusEl?.text.trim() ?? '';
      final isStatusMet = statusEl?.classes.contains('status-met') ?? false;

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
    } catch (e) {
      setState(() {
        _error = '解析失败: $e';
        _isLoading = false;
      });
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
                  : RefreshIndicator(
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
                                    title: '活跃程度',
                                    child: _buildRings(theme),
                                  ),
                                  const SizedBox(height: 16),
                                  _buildCard(
                                    theme,
                                    title: '互动参与',
                                    child: _buildBars(theme),
                                  ),
                                  const SizedBox(height: 16),
                                  _buildCard(
                                    theme,
                                    title: '合规记录',
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
      title: const Text('信任要求'),
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
                  Icons.verified_user_outlined,
                  size: 200,
                  color: colorScheme.primary.withValues(alpha: 0.05),
                ),
              ),
              Positioned(
                left: 20,
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
                         fontWeight: FontWeight.bold,
                         color: colorScheme.onSurface,
                         height: 1.2,
                       ),
                     ),
                     const SizedBox(height: 8),
                     if (_data!.badgeText.isNotEmpty)
                       Container(
                         padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                         decoration: BoxDecoration(
                           color: badgeBg,
                           borderRadius: BorderRadius.circular(20),
                           border: Border.all(color: badgeText.withValues(alpha: 0.2)),
                         ),
                         child: Text(
                           _data!.badgeText,
                           style: theme.textTheme.labelSmall?.copyWith(
                             color: badgeText,
                             fontWeight: FontWeight.bold,
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

  Widget _buildCard(ThemeData theme, {required String title, required Widget child}) {
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
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
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
          children: _data!.rings.map((ring) => SizedBox(
            width: width,
            child: _buildRingItem(theme, ring)
          )).toList(),
        );
      }
    );
  }

  Widget _buildRingItem(ThemeData theme, TlRingData ring) {
    final colorScheme = theme.colorScheme;
    final progress = ring.max > 0 ? (ring.current / ring.max).clamp(0.0, 1.0) : 0.0;
    
    // met -> #22c55e, unmet -> #f59e0b
    // Increase size to match 88px ~ 80-90 logical pixels
    final color = ring.isMet ? const Color(0xFF22c55e) : const Color(0xFFf59e0b);

    return Column(
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 80,
              height: 80,
              child: CircularProgressIndicator(
                value: 1.0,
                color: colorScheme.secondaryContainer.withValues(alpha: 0.5),
                strokeWidth: 8,
                strokeCap: StrokeCap.round,
              ),
            ),
             SizedBox(
              width: 80,
              height: 80,
              child: CircularProgressIndicator(
                value: progress,
                color: color,
                strokeWidth: 8,
                strokeCap: StrokeCap.round,
              ),
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
            )
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
    
    final labelColor = bar.isMet ? const Color(0xFF22c55e) : const Color(0xFFf59e0b);

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
                   fontWeight: FontWeight.w700,
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
                      )
                    ]
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
            children: _data!.quotas.map((quota) => Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: _buildQuotaCard(theme, quota),
              ),
            )).toList(),
          ),
          const SizedBox(height: 12),
          Row(
            children: _data!.vetos.map((veto) => Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: _buildVetoCard(theme, veto),
              ),
            )).toList(),
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

    final textColor = quota.isMet ? colorScheme.onSurfaceVariant : const Color(0xFFef4444);

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
                  fontWeight: FontWeight.w700,
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
               final color = isUsed ? const Color(0xFFef4444) : const Color(0xFF22c55e);
               
               return Expanded(
                 child: Container(
                   height: 6,
                   margin: const EdgeInsets.symmetric(horizontal: 2),
                   decoration: BoxDecoration(
                     color: color.withValues(alpha: isUsed ? 0.9 : 0.2),
                     borderRadius: BorderRadius.circular(3),
                     boxShadow: isUsed ? [
                       BoxShadow(
                         color: color.withValues(alpha: 0.3),
                         blurRadius: 4,
                       )
                     ] : null,
                   ),
                 ),
               );
            }),
          )
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
                   veto.isMet ? Icons.check : Icons.close, 
                   size: 16,
                   color: iconColor,
                 ),
               ),
               Text(
                 veto.value,
                 style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: iconColor,
                 ),
               ),
            ],
          ),
          const Spacer(),
          Text(
            veto.label,
             style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
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
     final statusColor = _data!.isStatusMet ? const Color(0xFF22c55e) : const Color(0xFFef4444);
     
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
                 color: statusColor.withValues(alpha:0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: statusColor.withValues(alpha:0.2),
                  )
               ),
               child: Row(
                 mainAxisAlignment: MainAxisAlignment.center,
                 children: [
                    Icon(
                      _data!.isStatusMet ? Icons.check_circle_outline : Icons.cancel_outlined,
                      color: statusColor,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        _data!.statusText,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: statusColor,
                          fontWeight: FontWeight.w600,
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
    return const Center(child: Text('没有数据'));
  }

  Widget _buildError(ThemeData theme) {
     return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(_error ?? '未知错误'),
            const SizedBox(height: 16),
            FilledButton(onPressed: _fetchData, child: const Text('重试')),
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
  });
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
