import 'dart:math' as math;
import 'dart:async';

import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../l10n/app_localizations.dart';

enum ConnectionPhase { running, warming, applying, fallback }

/// 状态与配置共用一张图；仅消费快照，不发起探测或轮询。
class NetworkConnectionOverview extends StatefulWidget {
  const NetworkConnectionOverview({
    super.key,
    required this.phase,
    required this.engine,
    required this.dns,
    required this.outbound,
    required this.webViewOutbound,
    required this.compatibility,
    required this.webViewViaCore,
    required this.templateName,
    required this.templateDetail,
    required this.onTemplate,
    required this.onDns,
    required this.onProxy,
    required this.onCompatibility,
    required this.onRestart,
  });

  final ConnectionPhase phase;
  final String engine, dns, outbound, webViewOutbound;
  final String templateName, templateDetail;
  final bool compatibility, webViewViaCore;
  final VoidCallback onTemplate, onDns, onProxy, onCompatibility;
  final FutureOr<void> Function() onRestart;

  @override
  State<NetworkConnectionOverview> createState() =>
      _NetworkConnectionOverviewState();
}

class _NetworkConnectionOverviewState extends State<NetworkConnectionOverview>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  bool _started = false;
  bool _graph = true;
  bool _restarting = false;
  Future<void> _restart() async {
    if (_restarting || widget.phase == ConnectionPhase.applying) return;
    setState(() => _restarting = true);
    try {
      await widget.onRestart();
    } finally {
      if (mounted) setState(() => _restarting = false);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _motion.value = 1;
    } else if (!_started) {
      _started = true;
      _motion.forward();
    }
  }

  @override
  void didUpdateWidget(NetworkConnectionOverview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.phase != widget.phase ||
            oldWidget.compatibility != widget.compatibility ||
            oldWidget.webViewViaCore != widget.webViewViaCore ||
            oldWidget.dns != widget.dns ||
            oldWidget.outbound != widget.outbound) &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled) {
      _motion.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final l = Translations.of(context);
    final applying = _restarting || widget.phase == ConnectionPhase.applying;
    final fallback = widget.phase == ConnectionPhase.fallback;
    final title = switch (widget.phase) {
      ConnectionPhase.running => l.networkStatus_running,
      ConnectionPhase.warming => l.networkStatus_warming,
      ConnectionPhase.applying => l.networkStatus_applying,
      ConnectionPhase.fallback => l.networkStatus_backup,
    };
    final accent = fallback ? c.error : c.primary;
    final scale = math.max(
      1.0,
      MediaQuery.textScalerOf(context).scale(14) / 14,
    );
    final header = Row(
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Semantics(
            liveRegion: true,
            child: Text(
              _restarting ? l.networkMap_restarting : title,
              style: theme.textTheme.titleSmall,
            ),
          ),
        ),
        IconButton(
          tooltip: _graph ? l.networkMap_showList : l.networkMap_showGraph,
          onPressed: applying ? null : () => setState(() => _graph = !_graph),
          icon: Icon(
            _graph ? Symbols.view_agenda_rounded : Symbols.hub_rounded,
            size: 20,
          ),
        ),
        IconButton.filledTonal(
          tooltip: l.networkStatus_restart,
          onPressed: applying ? null : _restart,
          icon: applying && !MediaQuery.disableAnimationsOf(context)
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Symbols.refresh_rounded, size: 20),
        ),
      ],
    );
    if (!_graph) {
      return SegmentedCardGroup(
        children: [
          Padding(padding: const EdgeInsets.all(16), child: header),
          if (applying)
            SizedBox(
              height: 288 * scale,
              child: Center(child: Text(l.networkStatus_updatingRoutes)),
            )
          else ...[
            ListTile(
              leading: const Icon(Symbols.fingerprint_rounded),
              title: Text(l.networkStatus_template),
              subtitle: Text(widget.templateName),
              trailing: const Icon(Symbols.chevron_right_rounded, size: 20),
              onTap: widget.onTemplate,
            ),
            ListTile(
              leading: const Icon(Symbols.dns_rounded),
              title: const Text('DNS / ECH'),
              subtitle: Text(widget.dns),
              trailing: const Icon(Symbols.chevron_right_rounded, size: 20),
              onTap: widget.onDns,
            ),
            ListTile(
              leading: const Icon(Symbols.language_rounded),
              title: const Text('WebView'),
              subtitle: Text(
                widget.compatibility
                    ? (widget.webViewViaCore
                          ? l.networkStatus_webViewViaCore
                          : l.networkStatus_systemNetwork)
                    : l.networkMap_bypassed,
              ),
              trailing: const Icon(Symbols.chevron_right_rounded, size: 20),
              onTap: widget.onCompatibility,
            ),
            ListTile(
              leading: const Icon(Symbols.public_rounded),
              title: Text(l.networkMap_outbound),
              subtitle: Text(widget.outbound),
              trailing: const Icon(Symbols.chevron_right_rounded, size: 20),
              onTap: widget.onProxy,
            ),
          ],
        ],
      );
    }
    return SegmentedCardGroup(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              header,
              const SizedBox(height: 12),
              if (applying)
                SizedBox(
                  height: (_graph ? 340 : 288) * scale,
                  child: Center(child: Text(l.networkStatus_updatingRoutes)),
                )
              else
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: SizedBox(
                      height: 340 * scale,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final w = constraints.maxWidth;
                          final h = constraints.maxHeight;
                          Widget node(
                            double x,
                            double y,
                            double width,
                            double height,
                            Widget child,
                          ) => Positioned(
                            left: w * x - width / 2,
                            top: h * y - height / 2,
                            width: width,
                            height: height,
                            child: child,
                          );
                          return Stack(
                            children: [
                              Positioned.fill(
                                child: RepaintBoundary(
                                  child: CustomPaint(
                                    painter: _ConfigurationPainter(
                                      motion: _motion,
                                      color: accent,
                                      surface: c.surfaceContainerLow,
                                    ),
                                  ),
                                ),
                              ),
                              node(
                                .24,
                                .17,
                                w * .46,
                                108 * scale,
                                _Control(
                                  id: 'dns',
                                  icon: Symbols.dns_rounded,
                                  title: 'DNS / ECH',
                                  value: widget.dns,
                                  detail: l.networkStatus_dnsScope,
                                  color: c.secondary,
                                  onTap: widget.onDns,
                                ),
                              ),
                              node(
                                .76,
                                .17,
                                w * .46,
                                108 * scale,
                                _Control(
                                  id: 'webview',
                                  icon: Symbols.language_rounded,
                                  title: 'WebView',
                                  value: widget.compatibility
                                      ? (widget.webViewViaCore
                                            ? l.networkStatus_webViewViaCore
                                            : l.networkStatus_systemNetwork)
                                      : l.networkMap_bypassed,
                                  detail: l.networkStatus_splitNote,
                                  color: widget.compatibility
                                      ? c.tertiary
                                      : c.onSurfaceVariant,
                                  onTap: widget.onCompatibility,
                                ),
                              ),
                              node(
                                .5,
                                .56,
                                w * .70,
                                132 * scale,
                                Tooltip(
                                  message: widget.templateDetail,
                                  child: Semantics(
                                    button: true,
                                    label:
                                        '${l.network_adapterCore}，${widget.templateName}',
                                    onTap: widget.onTemplate,
                                    excludeSemantics: true,
                                    child: Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        key: const ValueKey('network-map-core'),
                                        onTap: widget.onTemplate,
                                        customBorder:
                                            const RoundedRectangleBorder(
                                              borderRadius: BorderRadius.all(
                                                Radius.circular(32),
                                              ),
                                            ),
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Container(
                                              width: 60,
                                              height: 60,
                                              decoration: ShapeDecoration(
                                                color: c.primaryContainer,
                                                shape:
                                                    const RoundedRectangleBorder(
                                                      borderRadius:
                                                          BorderRadius.all(
                                                            Radius.circular(22),
                                                          ),
                                                    ),
                                              ),
                                              child: Icon(
                                                Symbols.hub_rounded,
                                                size: 30,
                                                color: c.onPrimaryContainer,
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            Text(
                                              fallback
                                                  ? widget.engine
                                                  : l.network_adapterCore,
                                              maxLines: 2,
                                              textAlign: TextAlign.center,
                                              style: theme.textTheme.titleMedium
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                            ),
                                            const SizedBox(height: 4),
                                            Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: [
                                                Icon(
                                                  Symbols.fingerprint_rounded,
                                                  size: 14,
                                                  color: c.onSurfaceVariant,
                                                ),
                                                const SizedBox(width: 4),
                                                Flexible(
                                                  child: Text(
                                                    widget.templateName,
                                                    maxLines: 2,
                                                    textAlign: TextAlign.center,
                                                    style: theme
                                                        .textTheme
                                                        .labelMedium
                                                        ?.copyWith(
                                                          color: c
                                                              .onSurfaceVariant,
                                                        ),
                                                  ),
                                                ),
                                                Icon(
                                                  Symbols.chevron_right_rounded,
                                                  size: 14,
                                                  color: c.onSurfaceVariant,
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              node(
                                .5,
                                .90,
                                w * .82,
                                64 * scale,
                                _Control(
                                  id: 'outbound',
                                  icon: Symbols.public_rounded,
                                  title: l.networkMap_outbound,
                                  value: widget.outbound,
                                  detail: fallback
                                      ? '${l.networkStatus_fallbackScope}\nWebView: ${widget.webViewOutbound}'
                                      : l.networkStatus_routeNote,
                                  color: accent,
                                  onTap: widget.onProxy,
                                  horizontal: true,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              if (_graph)
                Text(
                  l.networkMap_tapToConfigure,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: c.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Control extends StatelessWidget {
  const _Control({
    required this.id,
    required this.icon,
    required this.title,
    required this.value,
    required this.detail,
    required this.color,
    required this.onTap,
    this.horizontal = false,
  });
  final String id, title, value, detail;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final bool horizontal;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final text = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelMedium?.copyWith(
            color: c.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
    return Tooltip(
      message: '$title · $value\n$detail',
      child: Semantics(
        button: true,
        label: '$title，$value',
        onTap: onTap,
        excludeSemantics: true,
        child: Material(
          color: Color.alphaBlend(
            color.withValues(alpha: .055),
            c.surfaceContainerLow,
          ),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(24)),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('network-map-$id'),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: horizontal
                  ? Row(
                      children: [
                        Icon(icon, size: 22, color: color),
                        const SizedBox(width: 12),
                        Expanded(child: text),
                        Icon(
                          Symbols.chevron_right_rounded,
                          size: 18,
                          color: c.onSurfaceVariant,
                        ),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          children: [
                            Icon(icon, size: 20, color: color),
                            const Spacer(),
                            Icon(
                              Symbols.chevron_right_rounded,
                              size: 16,
                              color: c.onSurfaceVariant,
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Flexible(child: text),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 只表达配置关联，不将装饰线冒充实时流量或完整请求拓扑。
class _ConfigurationPainter extends CustomPainter {
  _ConfigurationPainter({
    required this.motion,
    required this.color,
    required this.surface,
  }) : super(repaint: motion);
  final Animation<double> motion;
  final Color color, surface;
  @override
  void paint(Canvas canvas, Size size) {
    Offset p(double x, double y) => Offset(size.width * x, size.height * y);
    final center = p(.5, .49);
    final radius = math.min(size.width * .24, 78.0);
    final wash = Paint()
      ..shader = RadialGradient(
        colors: [color.withValues(alpha: .08), color.withValues(alpha: 0)],
      ).createShader(Rect.fromCircle(center: center, radius: radius * 1.5));
    canvas.drawCircle(center, radius * 1.5, wash);
    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color.withValues(alpha: .13);
    canvas.drawCircle(center, radius, pen);
    canvas.drawCircle(
      center,
      radius + 10,
      pen..color = color.withValues(alpha: .055),
    );
    final alpha = .15 + .12 * (1 - motion.value);
    pen
      ..color = color.withValues(alpha: alpha)
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    for (final x in [.24, .76]) {
      final path = Path()
        ..moveTo(p(x, .27).dx, p(x, .27).dy)
        ..cubicTo(
          p(x, .35).dx,
          p(x, .35).dy,
          p(.5, .34).dx,
          p(.5, .34).dy,
          p(.5, .40).dx,
          p(.5, .40).dy,
        );
      canvas.drawPath(path, pen);
    }
    canvas.drawLine(p(.5, .77), p(.5, .81), pen);
  }

  @override
  bool shouldRepaint(_ConfigurationPainter old) =>
      old.color != color || old.surface != surface;
}
