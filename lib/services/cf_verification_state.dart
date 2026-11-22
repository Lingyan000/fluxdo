import '../l10n/app_localizations.dart';

/// 同一轮 /challenge 主页面的状态。到达入口后，业务请求可以重试。
enum CfVerificationStage {
  opening,
  checking,
  interactionRequired,
  interactionExpired,
  widgetError,
  timedOut,
  loadFailed,
  unconfirmed,
  noChallengeObserved,
  challengeCleared,
  cancelled;

  String label(AppLocalizations l10n) => switch (this) {
    opening => l10n.cf_verifyOpeningTitle,
    checking => l10n.cf_challengeDetectedTitle,
    interactionRequired => l10n.cf_manualVerifyBannerTitle,
    interactionExpired => l10n.cf_interactionExpiredTitle,
    widgetError => l10n.cf_widgetError,
    timedOut => l10n.cf_verifyTimedOutTitle,
    loadFailed => l10n.cf_cannotOpenVerifyPage,
    unconfirmed => l10n.cf_verifyUnconfirmedTitle,
    noChallengeObserved => l10n.cf_noChallengeTitle,
    challengeCleared => l10n.cfVerify_success,
    cancelled => l10n.cf_userCancelled,
  };
}

enum CfChallengeEvidence {
  responseHeader,
  pageContent,
  interactionSignal,
  widgetError,
}

enum CfOriginEvidence { response, document }

/// 每次变化产生一份快照，页面结束后仍保留本轮观察到的证据。
class CfVerificationState {
  const CfVerificationState.opening(int round, {int attempt = 1})
    : this._(round: round, attempt: attempt);
  const CfVerificationState._({
    required this.round,
    required this.attempt,
    this.stage = CfVerificationStage.opening,
    this.evidence = const {},
    this.lastHttpStatus,
    this.originEvidence,
    this.lastWidgetErrorCode,
    this.loadErrorDescription,
  });

  final int round;

  /// 用户主动重新加载才开始下一次。验证过程中的正常跳转保留同一份证据。
  final int attempt;
  final CfVerificationStage stage;
  final Set<CfChallengeEvidence> evidence;
  final int? lastHttpStatus;
  final CfOriginEvidence? originEvidence;

  /// 控件最近一次报告的公开错误码，仅在该错误仍是当前状态时显示。
  final String? lastWidgetErrorCode;
  final String? loadErrorDescription;

  bool get reachedOrigin => originEvidence != null;
  bool get challengeObserved => evidence.isNotEmpty;
  bool get interactionRequested =>
      evidence.contains(CfChallengeEvidence.interactionSignal);

  String label(AppLocalizations l10n) {
    if (stage == CfVerificationStage.widgetError &&
        lastWidgetErrorCode != null) {
      return l10n.cf_widgetErrorWithCode(lastWidgetErrorCode!);
    }
    if (stage == CfVerificationStage.loadFailed &&
        loadErrorDescription != null) {
      return l10n.cf_loadFailed(loadErrorDescription!);
    }
    return stage.label(l10n);
  }

  CfVerificationState withStage(
    CfVerificationStage next, {
    CfChallengeEvidence? observed,
    int? status,
    CfOriginEvidence? origin,
    String? widgetErrorCode,
    String? loadErrorDescription,
  }) {
    final sources = observed != null && !evidence.contains(observed)
        ? Set<CfChallengeEvidence>.unmodifiable({...evidence, observed})
        : evidence;
    final lastStatus = status ?? lastHttpStatus;
    final lastCode = observed == CfChallengeEvidence.widgetError
        ? widgetErrorCode
        : lastWidgetErrorCode;
    final loadError = next == CfVerificationStage.loadFailed
        ? loadErrorDescription ?? this.loadErrorDescription
        : null;
    if (stage == next &&
        identical(sources, evidence) &&
        lastStatus == lastHttpStatus &&
        lastCode == lastWidgetErrorCode &&
        loadError == this.loadErrorDescription &&
        origin == originEvidence) {
      return this;
    }
    return CfVerificationState._(
      round: round,
      attempt: attempt,
      stage: next,
      evidence: sources,
      lastHttpStatus: lastStatus,
      originEvidence: origin,
      lastWidgetErrorCode: lastCode,
      loadErrorDescription: loadError,
    );
  }
}
