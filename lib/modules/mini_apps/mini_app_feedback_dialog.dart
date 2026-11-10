import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:uuid/uuid.dart';

import '../../l10n/s.dart';
import '../../services/auth_session.dart';
import '../../utils/error_utils.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/platform_utils.dart';
import '../../utils/time_utils.dart';
import 'mini_app.dart';
import 'mini_app_identity.dart';
import 'mini_app_providers.dart';

enum MiniAppFeedback { rating, tip, report }

class MiniAppFeedbackDialog extends ConsumerStatefulWidget {
  const MiniAppFeedbackDialog({
    super.key,
    required this.details,
    required this.action,
    this.asSheet = false,
  });
  final MiniAppDetails details;
  final MiniAppFeedback action;
  final bool asSheet;

  static Future<bool?> show(
    BuildContext context, {
    required MiniAppDetails details,
    required MiniAppFeedback action,
    bool blur = true,
    ValueChanged<double>? onBlurSigmaChanged,
    ValueListenable<bool>? blurReady,
    bool filterBackdrop = true,
  }) {
    if (PlatformUtils.isDesktop) {
      return showAppDialog<bool>(
        context: context,
        blur: blur,
        onBlurSigmaChanged: onBlurSigmaChanged,
        blurReady: blurReady,
        filterBackdrop: filterBackdrop,
        barrierDismissible: false,
        builder: (_) => MiniAppFeedbackDialog(details: details, action: action),
      );
    }
    return showAppBottomSheet<bool>(
      context: context,
      blur: blur,
      onBlurSigmaChanged: onBlurSigmaChanged,
      blurReady: blurReady,
      filterBackdrop: filterBackdrop,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      isDismissible: false,
      enableDrag: false,
      builder: (_) => MiniAppFeedbackDialog(
        details: details,
        action: action,
        asSheet: true,
      ),
    );
  }

  @override
  ConsumerState<MiniAppFeedbackDialog> createState() =>
      _MiniAppFeedbackDialogState();
}

class _MiniAppFeedbackDialogState extends ConsumerState<MiniAppFeedbackDialog> {
  final _message = TextEditingController();
  bool _loading = true, _saving = false;
  Object? _error;
  Map<String, dynamic>? _tip;
  List<Map<String, dynamic>> _flags = [];
  int? _selected;
  String? _requestId;
  late final int _generation;
  bool get _sessionValid => AuthSession().isValid(_generation);
  bool get _cooling =>
      TimeUtils.parseUtcTime(_tip?['next_tip_at']?.toString())
          ?.isAfter(DateTime.now()) ??
      false;
  @override
  void initState() {
    super.initState();
    _generation = AuthSession().generation;
    if (widget.action == MiniAppFeedback.rating) {
      final previous = widget.details.feedback['my_rating'];
      if (previous is num && previous >= 1 && previous <= 5) {
        _selected = previous.toInt();
      }
    }
    AuthSession().generationChanges.addListener(_sessionChanged);
    _load();
  }

  void _sessionChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    if (!_sessionValid) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(miniAppServiceProvider);
      if (widget.action == MiniAppFeedback.tip) {
        _tip = await api.tipStatus(widget.details);
      }
      if (widget.action == MiniAppFeedback.report) {
        _flags = await api.reportTypes();
      }
    } catch (e) {
      if (mounted) _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _submit() async {
    if (_saving || _selected == null || !_sessionValid) return;
    if (widget.action == MiniAppFeedback.tip && !_validTip) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final api = ref.read(miniAppServiceProvider);
      switch (widget.action) {
        case MiniAppFeedback.rating:
          await api.rate(widget.details, _selected!);
        case MiniAppFeedback.report:
          await api.report(widget.details, _selected!, _message.text);
        case MiniAppFeedback.tip:
          _requestId ??= const Uuid().v4();
          await api.tip(widget.details, _selected!, _requestId!);
      }
      if (mounted && _sessionValid) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      if (widget.action == MiniAppFeedback.tip && _sessionValid) {
        try {
          _tip = await ref
              .read(miniAppServiceProvider)
              .tipStatus(widget.details);
        } catch (_) {}
      }
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    AuthSession().generationChanges.removeListener(_sessionChanged);
    _message.dispose();
    super.dispose();
  }

  List<int> get _amounts =>
      (_tip?['amounts'] as List? ?? [])
          .whereType<num>()
          .where((v) => v > 0 && v == v.toInt())
          .map((v) => v.toInt())
          .toSet()
          .toList()
        ..sort();
  num get _balance => num.tryParse(_tip?['balance']?.toString() ?? '') ?? 0;
  bool get _validTip =>
      !_cooling &&
      _amounts.contains(_selected) &&
      _selected != null &&
      _selected! <= _balance;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final title = switch (widget.action) {
      MiniAppFeedback.rating => l.miniApp_rate,
      MiniAppFeedback.tip => l.miniApp_tip,
      MiniAppFeedback.report => l.miniApp_report,
    };
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final amounts = _amounts;
    final balance = _balance;
    final validTip = widget.action != MiniAppFeedback.tip || _validTip;
    final content = SizedBox(
      width: 400,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedCardItem(
              index: 0,
              count: 1,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: MiniAppIdentity(app: widget.details.app),
              ),
            ),
            const SizedBox(height: 24),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: LoadingSpinner(size: 32)),
              )
            else ...[
              if (widget.action == MiniAppFeedback.rating)
                _ratingPicker(context),
              if (widget.action == MiniAppFeedback.tip && _tip != null) ...[
                Text(
                  l.miniApp_tipEncouragement,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  l.miniApp_balance(balance.toString()),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                LayoutBuilder(
                  builder: (context, constraints) => Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final amount in amounts)
                        SizedBox(
                          width: (constraints.maxWidth - 10) / 2,
                          child: Semantics(
                            selected: _selected == amount,
                            child: SegmentedCardItem(
                              index: 0,
                              count: 1,
                              outerRadius: 20,
                              color: _selected == amount
                                  ? colors.primaryContainer
                                  : colors.surfaceContainerLow,
                              child: InkWell(
                                key: ValueKey('mini-app-tip-$amount'),
                                onTap:
                                    _saving ||
                                        !_sessionValid ||
                                        _cooling ||
                                        amount > balance
                                    ? null
                                    : () => setState(() {
                                        if (_selected != amount) {
                                          _requestId = null;
                                        }
                                        _selected = amount;
                                      }),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 18,
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        '$amount',
                                        style: theme.textTheme.headlineSmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                              color:
                                                  amount > balance || _cooling
                                                  ? colors.onSurface.withValues(
                                                      alpha: .38,
                                                    )
                                                  : _selected == amount
                                                  ? colors.onPrimaryContainer
                                                  : colors.onSurface,
                                            ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        l.miniApp_pointsUnit,
                                        style: theme.textTheme.labelMedium,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (amounts.isNotEmpty && amounts.every((v) => v > balance))
                  _notice(context, l.miniApp_insufficientBalance, error: true),
                _notice(
                  context,
                  _cooling ? l.miniApp_tipCooldown : l.miniApp_tipNotice,
                ),
              ],
              if (widget.action == MiniAppFeedback.report &&
                  _flags.isNotEmpty) ...[
                SwipeDismissiblePopupMenuButton<int>(
                  key: const ValueKey('mini-app-report-type'),
                  enabled: !_saving && _sessionValid,
                  initialValue: _selected,
                  position: PopupMenuPosition.under,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: context.shapes.borderRadius(12),
                  ),
                  itemBuilder: (_) => [
                    for (final flag in _flags)
                      CheckedPopupMenuItem(
                        value: (flag['id'] as num).toInt(),
                        checked: _selected == (flag['id'] as num).toInt(),
                        child: Text(
                          (flag['name'] ?? flag['name_key']).toString(),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onSelected: (v) => setState(() => _selected = v),
                  child: InputDecorator(
                    isEmpty: _selected == null,
                    decoration: InputDecoration(
                      labelText: l.miniApp_reportType,
                      enabled: !_saving && _sessionValid,
                      suffixIcon: const Icon(Symbols.arrow_drop_down_rounded),
                    ),
                    child: Text(
                      _flags
                              .where((flag) => flag['id'] == _selected)
                              .map(
                                (flag) => (flag['name'] ?? flag['name_key'])
                                    .toString(),
                              )
                              .firstOrNull ??
                          '',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _message,
                  maxLines: 4,
                  maxLength: 2000,
                  enabled: !_saving && _sessionValid,
                  decoration: InputDecoration(
                    labelText: l.miniApp_reportReason,
                  ),
                ),
              ],
              if (widget.action == MiniAppFeedback.report &&
                  _flags.isEmpty &&
                  _error == null)
                Text(l.miniApp_actionUnavailable),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              _notice(
                context,
                ErrorUtils.getErrorInfo(_error!).message,
                error: true,
              ),
              if (!_saving &&
                  (_tip == null && widget.action == MiniAppFeedback.tip ||
                      _flags.isEmpty &&
                          widget.action == MiniAppFeedback.report))
                TextButton(onPressed: _load, child: Text(l.miniApp_retry)),
            ],
            if (!_sessionValid)
              _notice(context, l.miniApp_sessionChanged, error: true),
          ],
        ),
      ),
    );
    final actions = [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: Text(l.miniApp_cancel),
      ),
      FilledButton(
        onPressed:
            _loading ||
                _saving ||
                _selected == null ||
                !validTip ||
                !_sessionValid
            ? null
            : _submit,
        child: _saving
            ? const SizedBox.square(
                dimension: 18,
                child: LoadingSpinner(size: 18),
              )
            : Text(
                widget.action == MiniAppFeedback.tip
                    ? (_selected == null
                          ? l.miniApp_tipConfirm
                          : l.miniApp_tipPay(_selected!))
                    : l.miniApp_submit,
              ),
      ),
    ];
    return PopScope(
      canPop: !_saving,
      child: widget.asSheet
          ? AppSheetScaffold(
              style: AppSheetStyle.card,
              title: title,
              showCloseButton: !_saving,
              contentPadding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              footer: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Row(
                  children: [
                    actions[0],
                    const SizedBox(width: 12),
                    Expanded(child: actions[1]),
                  ],
                ),
              ),
              child: content,
            )
          : AlertDialog(title: Text(title), content: content, actions: actions),
    );
  }

  Widget _ratingPicker(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final descriptions = [
      l.miniApp_rating1,
      l.miniApp_rating2,
      l.miniApp_rating3,
      l.miniApp_rating4,
      l.miniApp_rating5,
    ];
    return Column(
      children: [
        Text(
          _selected == null
              ? l.miniApp_ratingPrompt
              : descriptions[_selected! - 1],
          style: theme.textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            for (var score = 1; score <= 5; score++)
              Expanded(
                child: Semantics(
                  selected: _selected == score,
                  child: IconButton(
                    key: ValueKey('mini-app-rating-$score'),
                    tooltip: l.miniApp_ratingValue(score),
                    onPressed: _saving || !_sessionValid
                        ? null
                        : () => setState(() => _selected = score),
                    iconSize: 36,
                    icon: Icon(
                      Symbols.star_rounded,
                      fill: score <= (_selected ?? 0) ? 1 : 0,
                      color: score <= (_selected ?? 0)
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outline,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          l.miniApp_ratingHint,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _notice(BuildContext context, String text, {bool error = false}) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        liveRegion: true,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: ShapeDecoration(
            color: error ? colors.errorContainer : colors.surfaceContainerHigh,
            shape: RoundedSuperellipseBorder(
              borderRadius: context.shapes.borderRadius(16),
            ),
          ),
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: error ? colors.onErrorContainer : colors.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
