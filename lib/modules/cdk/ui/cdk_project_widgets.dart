import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../l10n/s.dart';
import '../../../models/cdk_user_info.dart';
import '../models/cdk_models.dart';

String cdkDistribution(BuildContext context, int value) => switch (value) {
  0 => context.l10n.cdk_oneEach,
  1 => context.l10n.cdk_lottery,
  2 => context.l10n.cdk_invitation,
  _ => context.l10n.cdk_distribution,
};

/// 金额与动作分开展示，窄屏或大字时也不把价格塞进按钮。
class CdkPrice extends StatelessWidget {
  const CdkPrice({super.key, required this.project, this.prominent = false});
  final CdkProject project;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Text.rich(
      TextSpan(
        text: project.paid ? project.price : context.l10n.cdk_free,
        children: [
          if (project.paid) TextSpan(text: ' LDC', style: text.labelLarge),
        ],
      ),
      style: (prominent ? text.headlineMedium : text.titleLarge)?.copyWith(
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

/// 项目使用同一个领取凭证层级，列表保留总量，详情才展示真实剩余。
class CdkProjectTile extends StatelessWidget {
  const CdkProjectTile({super.key, required this.project, required this.onTap});
  final CdkProject project;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final p = project;
    return InkWell(
      onTap: onTap,
      borderRadius: SegmentedCardItem.borderRadiusOf(
        context,
        index: 0,
        count: 1,
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Symbols.key_rounded,
                  size: 20,
                  color: context.emphasis.accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    ['CDK', ...p.tags].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.textTheme.labelMedium?.copyWith(
                      color: t.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              p.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: t.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (p.description.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                p.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: t.textTheme.bodyMedium?.copyWith(
                  color: t.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 16),
            CdkPerforation(color: t.colorScheme.outlineVariant),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: CdkPrice(project: p)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${context.l10n.cdk_projectTotal(p.total)} · Lv.${p.trustLevel}',
                    textAlign: TextAlign.end,
                    style: t.textTheme.labelMedium?.copyWith(
                      color: t.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class CdkProjectHero extends StatelessWidget {
  const CdkProjectHero({super.key, required this.project});
  final CdkProject project;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final p = project;
    return Material(
      color: cs.primaryContainer,
      shape: RoundedSuperellipseBorder(
        borderRadius: context.shapes.borderRadius(28),
      ),
      clipBehavior: Clip.antiAlias,
      child: DefaultTextStyle.merge(
        style: TextStyle(color: cs.onPrimaryContainer),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Symbols.key_rounded,
                    color: cs.onPrimaryContainer,
                    size: 22,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'CDK',
                    style: t.textTheme.labelLarge?.copyWith(
                      color: cs.onPrimaryContainer,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      cdkDistribution(context, p.distribution),
                      textAlign: TextAlign.end,
                      style: t.textTheme.labelMedium?.copyWith(
                        color: cs.onPrimaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Text(
                p.name,
                style: t.textTheme.headlineSmall?.copyWith(
                  color: cs.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (p.creator.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  '@${p.creator}',
                  style: t.textTheme.bodyMedium?.copyWith(
                    color: cs.onPrimaryContainer,
                  ),
                ),
              ],
              const SizedBox(height: 24),
              CdkPerforation(
                color: cs.onPrimaryContainer.withValues(alpha: 0.3),
              ),
              const SizedBox(height: 20),
              LayoutBuilder(
                builder: (context, box) {
                  final stacked =
                      box.maxWidth <
                      MediaQuery.textScalerOf(context).scale(240);
                  final price = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.cdk_price,
                        style: t.textTheme.labelMedium?.copyWith(
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(height: 4),
                      // 显式继承凭证底色的文字色。
                      Theme(
                        data: t.copyWith(
                          textTheme: t.textTheme.apply(
                            bodyColor: cs.onPrimaryContainer,
                            displayColor: cs.onPrimaryContainer,
                          ),
                        ),
                        child: CdkPrice(project: p, prominent: true),
                      ),
                    ],
                  );
                  final stock = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.cdk_stock,
                        style: t.textTheme.labelMedium?.copyWith(
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${p.available ?? '—'} / ${p.total}',
                        style: t.textTheme.titleLarge?.copyWith(
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                    ],
                  );
                  return stacked
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [price, const SizedBox(height: 16), stock],
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(child: price),
                            const SizedBox(width: 12),
                            stock,
                          ],
                        );
                },
              ),
              if (p.available != null && p.total > 0) ...[
                const SizedBox(height: 14),
                LinearProgressIndicator(
                  value: (p.available! / p.total).clamp(0, 1),
                  color: cs.onPrimaryContainer,
                  backgroundColor: cs.onPrimaryContainer.withValues(
                    alpha: 0.12,
                  ),
                  semanticsLabel: context.l10n.cdk_stock,
                  borderRadius: context.shapes.borderRadius(4),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class CdkEligibility extends StatelessWidget {
  const CdkEligibility({super.key, required this.project, this.account});
  final CdkProject project;
  final CdkUserInfo? account;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return SegmentedCardGroup(
      children: [
        _requirement(
          context,
          l.cdk_requiredTrust,
          'Lv.${project.trustLevel}',
          account == null ? null : 'Lv.${account!.trustLevel}',
          account == null ? null : account!.trustLevel >= project.trustLevel,
        ),
        _requirement(
          context,
          l.cdk_requiredScore,
          '${project.minimumScore}',
          account == null ? null : '${account!.score}',
          account == null ? null : account!.score >= project.minimumScore,
        ),
      ],
    );
  }

  Widget _requirement(
    BuildContext context,
    String label,
    String target,
    String? current,
    bool? meets,
  ) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    child: Row(
      children: [
        Icon(
          switch (meets) {
            true => Symbols.check_circle_rounded,
            false => Symbols.lock_outline_rounded,
            null => Symbols.info_rounded,
          },
          size: 22,
          color: meets == true ? context.emphasis.accent : null,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$label · $target',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              if (current != null) ...[
                const SizedBox(height: 4),
                Text(
                  context.l10n.cdk_currentValue(current),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

class CdkSectionTitle extends StatelessWidget {
  const CdkSectionTitle(this.title, {super.key, this.action});
  final String title;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 12),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        ?action,
      ],
    ),
  );
}

class CdkPerforation extends StatelessWidget {
  const CdkPerforation({super.key, required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      width: double.infinity,
      height: 1,
      child: CustomPaint(painter: _PerforationPainter(color)),
    ),
  );
}

class _PerforationPainter extends CustomPainter {
  const _PerforationPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 8) {
      canvas.drawLine(
        Offset(x, 0.5),
        Offset((x + 4).clamp(0, size.width), 0.5),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_PerforationPainter oldDelegate) =>
      oldDelegate.color != color;
}
