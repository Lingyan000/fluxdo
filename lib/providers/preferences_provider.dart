import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/services.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/topic_card_style.dart';
import '../navigation/nav_action_bus.dart';
import '../services/network/request_scheduler_config.dart';
import '../services/cf_challenge_service.dart';
import '../utils/blocked_user_filter.dart';
import '../widgets/topic/topic_card_layout.dart';
import 'theme_provider.dart';

/// 嵌套视图连接线样式
enum NestedLineStyle {
  auto, // 自适应（移动端竖线，桌面端 L 线）
  lLine, // 始终 L 形连接线
  straight; // 始终简化竖线

  static NestedLineStyle fromString(String? value) {
    return NestedLineStyle.values.firstWhere(
      (e) => e.name == value,
      orElse: () => NestedLineStyle.auto,
    );
  }
}

enum BookmarksOpenMode {
  defaultRoute,
  tabbedWorkspace;

  static BookmarksOpenMode fromString(String? value) {
    return BookmarksOpenMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => BookmarksOpenMode.defaultRoute,
    );
  }
}

/// 进度悬浮条手势可绑定的动作
enum ProgressGestureAction {
  none, // 仅用于滑动手势，表示该方向不触发任何动作
  openTimeline,
  scrollToTop,
  jumpToUnread,
  nextPost,
  previousPost,
  reply,
  share,
  shareImage,
  exportArticle,
  openInBrowser,
  bookmark,
  readLater,
  notification,
  filter,
  toggleNestedView,
  aiAssistant,
  readingSettings,
  search,
  refresh,
  goBack;

  static ProgressGestureAction fromString(String? value) {
    return ProgressGestureAction.values.firstWhere(
      (e) => e.name == value,
      orElse: () => ProgressGestureAction.openTimeline,
    );
  }
}

/// 长按菜单候选功能默认列表（6 项），覆盖常用操作
const List<ProgressGestureAction> _defaultProgressGestureMenu = [
  ProgressGestureAction.openTimeline,
  ProgressGestureAction.scrollToTop,
  ProgressGestureAction.reply,
  ProgressGestureAction.bookmark,
  ProgressGestureAction.share,
  ProgressGestureAction.aiAssistant,
];

const int kProgressGestureMenuMax = 8;

class AppPreferences {
  static const Object _unset = Object();

  final bool autoPanguSpacing;

  /// 阅读时自动优化中英文混排间距
  final bool displayPanguSpacing;
  final bool anonymousShare;
  final bool longPressPreview;
  final bool openExternalLinksInAppBrowser;

  /// 内容字体缩放比例，范围 0.8 ~ 1.4，默认 1.0
  final double contentFontScale;

  /// 分享图片主题索引
  final int shareImageThemeIndex;

  /// 自动填充登录凭证
  final bool autoFillLogin;

  /// 自动识别剪贴板中的 Linux.do 话题链接
  final bool clipboardTopicLinkDetection;

  /// 话题关键词过滤列表（原样存储，仅 trim 去重去空，保留用户输入大小写以便回显）
  final List<String> topicFilterKeywords;

  /// 话题关键词过滤：是否启用完整词匹配（仅影响英文/数字等 word-char 关键词）
  final bool topicFilterWholeWord;

  /// 本地内容屏蔽用户名列表。只影响本客户端的展示，不会同步到 Discourse。
  final List<String> blockedUsernames;

  /// 话题关键词过滤的归一化形式（lowercase），匹配时使用
  late final List<String> normalizedFilterKeywords = List.unmodifiable(
    topicFilterKeywords
        .map((keyword) => keyword.trim().toLowerCase())
        .where((keyword) => keyword.isNotEmpty),
  );

  /// 本地内容屏蔽用户名的归一化集合，匹配时使用。
  late final Set<String> normalizedBlockedUsernames =
      BlockedUserFilter.normalizedUsernames(blockedUsernames);

  /// 崩溃日志上报（仅 Android）
  final bool crashlytics;

  /// 竖屏锁定
  final bool portraitLock;

  /// 滚动时收起顶栏和底栏
  final bool hideBarOnScroll;

  /// 退出时清除图片缓存
  final bool clearCacheOnExit;

  /// 拦截到 CF 盾时自动弹出验证页面
  final bool autoCfChallenge;

  /// 相关链接默认展开
  final bool expandRelatedLinks;

  /// AI 助手左滑入口（PageView 模式）
  final bool aiSwipeEntry;

  /// 富文本编辑器(实验性,自研 WYSIWYG composer)
  final bool useRichComposer;

  /// 发帖前 AI 审核
  final bool aiPostReviewEnabled;

  /// 发帖前 AI 审核使用的模型 key（providerId:modelId）
  final String? aiPostReviewModelKey;

  /// hcaptcha 验证 POST endpoint 覆盖。null = 用内置 fallback 列表 (尝试
  /// `/captcha/hcaptcha/create.json` → `/hcaptcha/create.json`)。
  /// 站长改 mount path 时不发版即可改这里。
  final String? hcaptchaCreateEndpoint;

  /// 对话框背景高斯模糊
  final bool dialogBlur;

  /// 显示用户签名。默认关闭:签名在网页本就是 opt-in 功能
  /// (signatures_visible_by_default 默认 false,需用户主动开启),
  /// 且第三方签名图成本高、良莠不齐,默认关对齐网页更稳妥。
  final bool showSignatures;

  /// Boost 弹幕化（默认关闭）
  final bool boostDanmaku;

  /// 默认使用树形视图
  final bool defaultNestedView;

  /// 嵌套视图连接线样式
  final NestedLineStyle nestedLineStyle;

  /// 书签页默认打开方式（桌面端与手机端均生效）
  final BookmarksOpenMode bookmarksOpenMode;

  /// 最大并发请求数
  final int maxConcurrent;

  /// 滑动窗口内最大请求数
  final int maxPerWindow;

  /// 滑动窗口时长（秒）
  final int windowSeconds;

  /// 底栏：单击已选中 tab 执行的动作
  final NavTapAction bottomSingleTapAction;

  /// 底栏：双击已选中 tab 执行的动作
  final NavTapAction bottomDoubleTapAction;

  /// 底栏入口 id 列表（顺序即显示顺序）
  final List<String> bottomNavIds;

  /// Android 屏幕刷新率偏好（0 = auto/跟随系统，其它为目标刷新率，如 60 / 90 / 120）
  final int displayModeRefreshRate;

  /// 进度悬浮条手势总开关
  final bool progressGesturesEnabled;

  /// 左滑动作
  final ProgressGestureAction progressGestureSwipeLeft;

  /// 右滑动作
  final ProgressGestureAction progressGestureSwipeRight;

  /// 上滑动作
  final ProgressGestureAction progressGestureSwipeUp;

  /// 长按菜单总开关（关闭时长按不弹出菜单）
  final bool progressGestureLongPressEnabled;

  /// 长按菜单候选功能（按顺序展示在半圆菜单中）
  final List<ProgressGestureAction> progressGestureMenuActions;

  /// 编辑器工具栏外显工具 id 列表（空 = 全部收进「更多」面板）
  final List<String> editorToolbarTools;

  /// 话题卡片自定义样式（元信息字段开关 / 头像布局 / 动态头像）
  final TopicCardStyle topicCardStyle;

  AppPreferences({
    required this.autoPanguSpacing,
    required this.displayPanguSpacing,
    required this.anonymousShare,
    required this.longPressPreview,
    required this.openExternalLinksInAppBrowser,
    required this.contentFontScale,
    required this.shareImageThemeIndex,
    required this.autoFillLogin,
    required this.clipboardTopicLinkDetection,
    required this.topicFilterKeywords,
    this.topicFilterWholeWord = false,
    this.blockedUsernames = const [],
    required this.crashlytics,
    required this.portraitLock,
    required this.hideBarOnScroll,
    required this.clearCacheOnExit,
    required this.autoCfChallenge,
    required this.expandRelatedLinks,
    required this.aiSwipeEntry,
    this.useRichComposer = false,
    this.aiPostReviewEnabled = false,
    this.aiPostReviewModelKey,
    this.hcaptchaCreateEndpoint,
    required this.dialogBlur,
    this.showSignatures = false,
    this.boostDanmaku = false,
    this.defaultNestedView = false,
    this.nestedLineStyle = NestedLineStyle.auto,
    this.bookmarksOpenMode = BookmarksOpenMode.defaultRoute,
    required this.maxConcurrent,
    required this.maxPerWindow,
    required this.windowSeconds,
    required this.bottomSingleTapAction,
    required this.bottomDoubleTapAction,
    required this.bottomNavIds,
    this.displayModeRefreshRate = 0,
    this.progressGesturesEnabled = true,
    this.progressGestureSwipeLeft = ProgressGestureAction.nextPost,
    this.progressGestureSwipeRight = ProgressGestureAction.previousPost,
    this.progressGestureSwipeUp = ProgressGestureAction.jumpToUnread,
    this.progressGestureLongPressEnabled = true,
    this.progressGestureMenuActions = _defaultProgressGestureMenu,
    this.editorToolbarTools = const [],
    this.topicCardStyle = TopicCardStyle.defaults,
  });

  AppPreferences copyWith({
    bool? autoPanguSpacing,
    bool? displayPanguSpacing,
    bool? anonymousShare,
    bool? longPressPreview,
    bool? openExternalLinksInAppBrowser,
    double? contentFontScale,
    int? shareImageThemeIndex,
    bool? autoFillLogin,
    bool? clipboardTopicLinkDetection,
    List<String>? topicFilterKeywords,
    bool? topicFilterWholeWord,
    List<String>? blockedUsernames,
    bool? crashlytics,
    bool? portraitLock,
    bool? hideBarOnScroll,
    bool? clearCacheOnExit,
    bool? autoCfChallenge,
    bool? expandRelatedLinks,
    bool? aiSwipeEntry,
    bool? useRichComposer,
    bool? aiPostReviewEnabled,
    Object? aiPostReviewModelKey = _unset,
    Object? hcaptchaCreateEndpoint = _unset,
    bool? dialogBlur,
    bool? showSignatures,
    bool? boostDanmaku,
    bool? defaultNestedView,
    NestedLineStyle? nestedLineStyle,
    BookmarksOpenMode? bookmarksOpenMode,
    int? maxConcurrent,
    int? maxPerWindow,
    int? windowSeconds,
    NavTapAction? bottomSingleTapAction,
    NavTapAction? bottomDoubleTapAction,
    List<String>? bottomNavIds,
    int? displayModeRefreshRate,
    bool? progressGesturesEnabled,
    ProgressGestureAction? progressGestureSwipeLeft,
    ProgressGestureAction? progressGestureSwipeRight,
    ProgressGestureAction? progressGestureSwipeUp,
    bool? progressGestureLongPressEnabled,
    List<ProgressGestureAction>? progressGestureMenuActions,
    List<String>? editorToolbarTools,
    TopicCardStyle? topicCardStyle,
  }) {
    return AppPreferences(
      autoPanguSpacing: autoPanguSpacing ?? this.autoPanguSpacing,
      displayPanguSpacing: displayPanguSpacing ?? this.displayPanguSpacing,
      anonymousShare: anonymousShare ?? this.anonymousShare,
      longPressPreview: longPressPreview ?? this.longPressPreview,
      openExternalLinksInAppBrowser:
          openExternalLinksInAppBrowser ?? this.openExternalLinksInAppBrowser,
      contentFontScale: contentFontScale ?? this.contentFontScale,
      shareImageThemeIndex: shareImageThemeIndex ?? this.shareImageThemeIndex,
      autoFillLogin: autoFillLogin ?? this.autoFillLogin,
      clipboardTopicLinkDetection:
          clipboardTopicLinkDetection ?? this.clipboardTopicLinkDetection,
      topicFilterKeywords: topicFilterKeywords ?? this.topicFilterKeywords,
      topicFilterWholeWord: topicFilterWholeWord ?? this.topicFilterWholeWord,
      blockedUsernames: blockedUsernames ?? this.blockedUsernames,
      crashlytics: crashlytics ?? this.crashlytics,
      portraitLock: portraitLock ?? this.portraitLock,
      hideBarOnScroll: hideBarOnScroll ?? this.hideBarOnScroll,
      clearCacheOnExit: clearCacheOnExit ?? this.clearCacheOnExit,
      autoCfChallenge: autoCfChallenge ?? this.autoCfChallenge,
      expandRelatedLinks: expandRelatedLinks ?? this.expandRelatedLinks,
      aiSwipeEntry: aiSwipeEntry ?? this.aiSwipeEntry,
      useRichComposer: useRichComposer ?? this.useRichComposer,
      aiPostReviewEnabled: aiPostReviewEnabled ?? this.aiPostReviewEnabled,
      aiPostReviewModelKey: identical(aiPostReviewModelKey, _unset)
          ? this.aiPostReviewModelKey
          : aiPostReviewModelKey as String?,
      hcaptchaCreateEndpoint: identical(hcaptchaCreateEndpoint, _unset)
          ? this.hcaptchaCreateEndpoint
          : hcaptchaCreateEndpoint as String?,
      dialogBlur: dialogBlur ?? this.dialogBlur,
      showSignatures: showSignatures ?? this.showSignatures,
      boostDanmaku: boostDanmaku ?? this.boostDanmaku,
      defaultNestedView: defaultNestedView ?? this.defaultNestedView,
      nestedLineStyle: nestedLineStyle ?? this.nestedLineStyle,
      bookmarksOpenMode: bookmarksOpenMode ?? this.bookmarksOpenMode,
      maxConcurrent: maxConcurrent ?? this.maxConcurrent,
      maxPerWindow: maxPerWindow ?? this.maxPerWindow,
      windowSeconds: windowSeconds ?? this.windowSeconds,
      bottomSingleTapAction:
          bottomSingleTapAction ?? this.bottomSingleTapAction,
      bottomDoubleTapAction:
          bottomDoubleTapAction ?? this.bottomDoubleTapAction,
      bottomNavIds: bottomNavIds ?? this.bottomNavIds,
      displayModeRefreshRate:
          displayModeRefreshRate ?? this.displayModeRefreshRate,
      progressGesturesEnabled:
          progressGesturesEnabled ?? this.progressGesturesEnabled,
      progressGestureSwipeLeft:
          progressGestureSwipeLeft ?? this.progressGestureSwipeLeft,
      progressGestureSwipeRight:
          progressGestureSwipeRight ?? this.progressGestureSwipeRight,
      progressGestureSwipeUp:
          progressGestureSwipeUp ?? this.progressGestureSwipeUp,
      progressGestureLongPressEnabled:
          progressGestureLongPressEnabled ??
          this.progressGestureLongPressEnabled,
      progressGestureMenuActions:
          progressGestureMenuActions ?? this.progressGestureMenuActions,
      editorToolbarTools: editorToolbarTools ?? this.editorToolbarTools,
      topicCardStyle: topicCardStyle ?? this.topicCardStyle,
    );
  }
}

class PreferencesNotifier extends StateNotifier<AppPreferences> {
  static const String _autoPanguSpacingKey = 'pref_auto_pangu_spacing';
  static const String _displayPanguSpacingKey = 'pref_display_pangu_spacing';
  static const String _anonymousShareKey = 'pref_anonymous_share';
  static const String _longPressPreviewKey = 'pref_long_press_preview';
  static const String _openExternalLinksInAppBrowserKey =
      'pref_open_external_links_in_app_browser';
  static const String _contentFontScaleKey = 'pref_content_font_scale';
  static const String _shareImageThemeIndexKey = 'pref_share_image_theme_index';
  static const String _autoFillLoginKey = 'pref_auto_fill_login';
  static const String _clipboardTopicLinkDetectionKey =
      'pref_clipboard_topic_link_detection';
  static const String _topicFilterKeywordsKey = 'pref_topic_filter_keywords';
  static const String _topicFilterWholeWordKey = 'pref_topic_filter_whole_word';
  static const String _blockedUsernamesKey = 'pref_blocked_usernames';
  static const String _crashlyticsKey = 'pref_crashlytics';
  static const String _portraitLockKey = 'pref_portrait_lock';
  static const String _hideBarOnScrollKey = 'pref_hide_bar_on_scroll';
  static const String _clearCacheOnExitKey = 'pref_clear_cache_on_exit';
  static const String _autoCfChallengeKey = 'pref_auto_cf_challenge';
  static const String _expandRelatedLinksKey = 'pref_expand_related_links';
  static const String _aiSwipeEntryKey = 'pref_ai_swipe_entry';
  static const String _useRichComposerKey = 'pref_use_rich_composer';
  static const String _aiPostReviewEnabledKey = 'pref_ai_post_review_enabled';
  static const String _aiPostReviewModelPrefKey = 'pref_ai_post_review_model';
  static const String _hcaptchaCreateEndpointKey =
      'pref_hcaptcha_create_endpoint';
  static const String _dialogBlurKey = 'pref_dialog_blur';
  static const String _showSignaturesKey = 'pref_show_signatures';
  static const String _boostDanmakuKey = 'pref_boost_danmaku';
  static const String _defaultNestedViewKey = 'pref_default_nested_view';
  static const String _nestedLineStyleKey = 'pref_nested_line_style';
  static const String _bookmarksOpenModeKey = 'pref_bookmarks_open_mode';
  static const String _maxConcurrentKey = 'pref_max_concurrent';
  static const String _maxPerWindowKey = 'pref_max_per_window';
  static const String _windowSecondsKey = 'pref_window_seconds';
  static const String _bottomSingleTapActionKey =
      'pref_bottom_single_tap_action';
  static const String _bottomDoubleTapActionKey =
      'pref_bottom_double_tap_action';
  static const String _bottomNavIdsKey = 'pref_bottom_nav_ids';
  static const String _displayModeRefreshRateKey =
      'pref_display_mode_refresh_rate';
  static const String _progressGesturesEnabledKey =
      'pref_progress_gestures_enabled';
  static const String _progressGestureSwipeLeftKey =
      'pref_progress_gesture_swipe_left';
  static const String _progressGestureSwipeRightKey =
      'pref_progress_gesture_swipe_right';
  static const String _progressGestureSwipeUpKey =
      'pref_progress_gesture_swipe_up';
  static const String _progressGestureLongPressEnabledKey =
      'pref_progress_gesture_long_press_enabled';
  static const String _progressGestureMenuActionsKey =
      'pref_progress_gesture_menu_actions';
  static const String _editorToolbarToolsKey = 'pref_editor_toolbar_tools';
  static const String _topicCardStyleKey = 'pref_topic_card_style';

  static const _crashlyticsChannel = MethodChannel(
    'com.github.lingyan000.fluxdo/crashlytics',
  );

  PreferencesNotifier(this._prefs)
    : super(
        AppPreferences(
          autoPanguSpacing: _prefs.getBool(_autoPanguSpacingKey) ?? false,
          displayPanguSpacing: _prefs.getBool(_displayPanguSpacingKey) ?? false,
          anonymousShare: _prefs.getBool(_anonymousShareKey) ?? false,
          longPressPreview: _prefs.getBool(_longPressPreviewKey) ?? true,
          openExternalLinksInAppBrowser:
              _prefs.getBool(_openExternalLinksInAppBrowserKey) ?? false,
          contentFontScale: _prefs.getDouble(_contentFontScaleKey) ?? 1.0,
          shareImageThemeIndex: _prefs.getInt(_shareImageThemeIndexKey) ?? 0,
          autoFillLogin: _prefs.getBool(_autoFillLoginKey) ?? true,
          clipboardTopicLinkDetection:
              _prefs.getBool(_clipboardTopicLinkDetectionKey) ?? false,
          topicFilterKeywords:
              _prefs.getStringList(_topicFilterKeywordsKey) ?? const [],
          topicFilterWholeWord:
              _prefs.getBool(_topicFilterWholeWordKey) ?? false,
          blockedUsernames:
              _prefs.getStringList(_blockedUsernamesKey) ?? const [],
          crashlytics: _prefs.getBool(_crashlyticsKey) ?? true,
          portraitLock: _prefs.getBool(_portraitLockKey) ?? false,
          hideBarOnScroll: _prefs.getBool(_hideBarOnScrollKey) ?? true,
          clearCacheOnExit: _prefs.getBool(_clearCacheOnExitKey) ?? false,
          autoCfChallenge: _prefs.getBool(_autoCfChallengeKey) ?? true,
          expandRelatedLinks: _prefs.getBool(_expandRelatedLinksKey) ?? false,
          aiSwipeEntry: _prefs.getBool(_aiSwipeEntryKey) ?? false,
          useRichComposer: _prefs.getBool(_useRichComposerKey) ?? false,
          aiPostReviewEnabled: _prefs.getBool(_aiPostReviewEnabledKey) ?? false,
          aiPostReviewModelKey: _prefs.getString(_aiPostReviewModelPrefKey),
          hcaptchaCreateEndpoint: _prefs.getString(_hcaptchaCreateEndpointKey),
          dialogBlur: _prefs.getBool(_dialogBlurKey) ?? true,
          showSignatures: _prefs.getBool(_showSignaturesKey) ?? false,
          boostDanmaku: _prefs.getBool(_boostDanmakuKey) ?? false,
          defaultNestedView: _prefs.getBool(_defaultNestedViewKey) ?? false,
          nestedLineStyle: NestedLineStyle.fromString(
            _prefs.getString(_nestedLineStyleKey),
          ),
          bookmarksOpenMode: BookmarksOpenMode.fromString(
            _prefs.getString(_bookmarksOpenModeKey),
          ),
          maxConcurrent: _prefs.getInt(_maxConcurrentKey) ?? 3,
          maxPerWindow: _prefs.getInt(_maxPerWindowKey) ?? 6,
          windowSeconds: _prefs.getInt(_windowSecondsKey) ?? 3,
          bottomSingleTapAction: NavTapActionX.fromStorageKey(
            _prefs.getString(_bottomSingleTapActionKey),
            fallback: NavTapAction.scrollToTop,
          ),
          bottomDoubleTapAction: NavTapActionX.fromStorageKey(
            _prefs.getString(_bottomDoubleTapActionKey),
            fallback: NavTapAction.refresh,
          ),
          bottomNavIds:
              _prefs.getStringList(_bottomNavIdsKey) ??
              const [NavEntryIds.home, NavEntryIds.profile],
          displayModeRefreshRate:
              _prefs.getInt(_displayModeRefreshRateKey) ?? 0,
          progressGesturesEnabled:
              _prefs.getBool(_progressGesturesEnabledKey) ?? true,
          progressGestureSwipeLeft: _readGestureAction(
            _prefs.getString(_progressGestureSwipeLeftKey),
            ProgressGestureAction.nextPost,
          ),
          progressGestureSwipeRight: _readGestureAction(
            _prefs.getString(_progressGestureSwipeRightKey),
            ProgressGestureAction.previousPost,
          ),
          progressGestureSwipeUp: _readGestureAction(
            _prefs.getString(_progressGestureSwipeUpKey),
            ProgressGestureAction.jumpToUnread,
          ),
          progressGestureLongPressEnabled:
              _prefs.getBool(_progressGestureLongPressEnabledKey) ?? true,
          progressGestureMenuActions: _readGestureMenuActions(
            _prefs.getStringList(_progressGestureMenuActionsKey),
          ),
          editorToolbarTools:
              _prefs.getStringList(_editorToolbarToolsKey) ?? const [],
          topicCardStyle: TopicCardStyle.fromJsonString(
            _prefs.getString(_topicCardStyleKey),
          ),
        ),
      ) {
    isPortraitLocked = state.portraitLock;
    TopicCardStyleScope.current = state.topicCardStyle;
    CfChallengeService().autoVerifyEnabled = state.autoCfChallenge;
    _syncSchedulerConfig();
  }

  final SharedPreferences _prefs;

  Future<void> setAutoPanguSpacing(bool enabled) async {
    state = state.copyWith(autoPanguSpacing: enabled);
    await _prefs.setBool(_autoPanguSpacingKey, enabled);
  }

  Future<void> setDisplayPanguSpacing(bool enabled) async {
    state = state.copyWith(displayPanguSpacing: enabled);
    await _prefs.setBool(_displayPanguSpacingKey, enabled);
  }

  Future<void> setAnonymousShare(bool enabled) async {
    state = state.copyWith(anonymousShare: enabled);
    await _prefs.setBool(_anonymousShareKey, enabled);
  }

  Future<void> setLongPressPreview(bool enabled) async {
    state = state.copyWith(longPressPreview: enabled);
    await _prefs.setBool(_longPressPreviewKey, enabled);
  }

  Future<void> setOpenExternalLinksInAppBrowser(bool enabled) async {
    state = state.copyWith(openExternalLinksInAppBrowser: enabled);
    await _prefs.setBool(_openExternalLinksInAppBrowserKey, enabled);
  }

  Future<void> setContentFontScale(double scale) async {
    // 限制范围在 0.8 ~ 1.4
    final clampedScale = scale.clamp(0.8, 1.4);
    state = state.copyWith(contentFontScale: clampedScale);
    await _prefs.setDouble(_contentFontScaleKey, clampedScale);
  }

  Future<void> setShareImageThemeIndex(int index) async {
    state = state.copyWith(shareImageThemeIndex: index);
    await _prefs.setInt(_shareImageThemeIndexKey, index);
  }

  Future<void> setAutoFillLogin(bool enabled) async {
    state = state.copyWith(autoFillLogin: enabled);
    await _prefs.setBool(_autoFillLoginKey, enabled);
  }

  Future<void> setClipboardTopicLinkDetection(bool enabled) async {
    state = state.copyWith(clipboardTopicLinkDetection: enabled);
    await _prefs.setBool(_clipboardTopicLinkDetectionKey, enabled);
  }

  Future<void> setTopicFilterKeywords(List<String> keywords) async {
    final deduped = keywords
        .map((keyword) => keyword.trim())
        .where((keyword) => keyword.isNotEmpty)
        .toSet()
        .toList();
    final current = state.topicFilterKeywords;
    if (deduped.length == current.length &&
        const ListEquality<String>().equals(deduped, current)) {
      return;
    }
    state = state.copyWith(topicFilterKeywords: deduped);
    await _prefs.setStringList(_topicFilterKeywordsKey, deduped);
  }

  Future<void> setTopicFilterWholeWord(bool enabled) async {
    if (state.topicFilterWholeWord == enabled) return;
    state = state.copyWith(topicFilterWholeWord: enabled);
    await _prefs.setBool(_topicFilterWholeWordKey, enabled);
  }

  Future<void> setBlockedUsernames(List<String> usernames) async {
    final sanitized = BlockedUserFilter.sanitizeUsernames(usernames);
    final current = state.blockedUsernames;
    if (sanitized.length == current.length &&
        const ListEquality<String>().equals(sanitized, current)) {
      return;
    }
    state = state.copyWith(blockedUsernames: sanitized);
    await _prefs.setStringList(_blockedUsernamesKey, sanitized);
  }

  Future<void> setCrashlytics(bool enabled) async {
    state = state.copyWith(crashlytics: enabled);
    await _prefs.setBool(_crashlyticsKey, enabled);
    if (Platform.isAndroid) {
      await _crashlyticsChannel.invokeMethod('setCrashlyticsEnabled', {
        'enabled': enabled,
      });
    }
  }

  Future<void> setPortraitLock(bool enabled) async {
    state = state.copyWith(portraitLock: enabled);
    await _prefs.setBool(_portraitLockKey, enabled);
    isPortraitLocked = enabled;
    if (enabled) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    } else {
      await SystemChrome.setPreferredOrientations([]);
    }
  }

  Future<void> setHideBarOnScroll(bool enabled) async {
    state = state.copyWith(hideBarOnScroll: enabled);
    await _prefs.setBool(_hideBarOnScrollKey, enabled);
  }

  Future<void> setClearCacheOnExit(bool enabled) async {
    state = state.copyWith(clearCacheOnExit: enabled);
    await _prefs.setBool(_clearCacheOnExitKey, enabled);
  }

  Future<void> setAutoCfChallenge(bool enabled) async {
    state = state.copyWith(autoCfChallenge: enabled);
    await _prefs.setBool(_autoCfChallengeKey, enabled);
    CfChallengeService().autoVerifyEnabled = enabled;
  }

  Future<void> setExpandRelatedLinks(bool enabled) async {
    state = state.copyWith(expandRelatedLinks: enabled);
    await _prefs.setBool(_expandRelatedLinksKey, enabled);
  }

  Future<void> setAiSwipeEntry(bool enabled) async {
    state = state.copyWith(aiSwipeEntry: enabled);
    await _prefs.setBool(_aiSwipeEntryKey, enabled);
  }

  Future<void> setUseRichComposer(bool enabled) async {
    state = state.copyWith(useRichComposer: enabled);
    await _prefs.setBool(_useRichComposerKey, enabled);
  }

  Future<void> setAiPostReviewEnabled(bool enabled) async {
    state = state.copyWith(aiPostReviewEnabled: enabled);
    await _prefs.setBool(_aiPostReviewEnabledKey, enabled);
  }

  Future<void> setAiPostReviewModelKey(String? key) async {
    state = state.copyWith(aiPostReviewModelKey: key);
    if (key == null || key.isEmpty) {
      await _prefs.remove(_aiPostReviewModelPrefKey);
    } else {
      await _prefs.setString(_aiPostReviewModelPrefKey, key);
    }
  }

  Future<void> setDialogBlur(bool enabled) async {
    state = state.copyWith(dialogBlur: enabled);
    await _prefs.setBool(_dialogBlurKey, enabled);
  }

  Future<void> setTopicCardStyle(TopicCardStyle style) async {
    if (state.topicCardStyle == style) return;
    state = state.copyWith(topicCardStyle: style);
    // 排版层直读全局快照(免逐调用点透传);stamp 含 style 保证重排,
    // evictAll 兜底清掉 LRU 里的旧排版
    TopicCardStyleScope.current = style;
    TopicCardLayout.evictAll();
    await _prefs.setString(_topicCardStyleKey, style.toJsonString());
  }

  Future<void> setShowSignatures(bool enabled) async {
    state = state.copyWith(showSignatures: enabled);
    await _prefs.setBool(_showSignaturesKey, enabled);
  }

  Future<void> setBoostDanmaku(bool enabled) async {
    if (state.boostDanmaku == enabled) return;
    state = state.copyWith(boostDanmaku: enabled);
    await _prefs.setBool(_boostDanmakuKey, enabled);
  }

  Future<void> setDefaultNestedView(bool enabled) async {
    state = state.copyWith(defaultNestedView: enabled);
    await _prefs.setBool(_defaultNestedViewKey, enabled);
  }

  Future<void> setNestedLineStyle(NestedLineStyle style) async {
    state = state.copyWith(nestedLineStyle: style);
    await _prefs.setString(_nestedLineStyleKey, style.name);
  }

  Future<void> setBookmarksOpenMode(BookmarksOpenMode mode) async {
    state = state.copyWith(bookmarksOpenMode: mode);
    await _prefs.setString(_bookmarksOpenModeKey, mode.name);
  }

  Future<void> setMaxConcurrent(int value) async {
    final clamped = value.clamp(1, 10);
    state = state.copyWith(maxConcurrent: clamped);
    await _prefs.setInt(_maxConcurrentKey, clamped);
    RequestSchedulerConfig.maxConcurrent = clamped;
  }

  Future<void> setMaxPerWindow(int value) async {
    final clamped = value.clamp(2, 30);
    state = state.copyWith(maxPerWindow: clamped);
    await _prefs.setInt(_maxPerWindowKey, clamped);
    RequestSchedulerConfig.maxPerWindow = clamped;
  }

  Future<void> setWindowSeconds(int value) async {
    final clamped = value.clamp(1, 10);
    state = state.copyWith(windowSeconds: clamped);
    await _prefs.setInt(_windowSecondsKey, clamped);
    RequestSchedulerConfig.windowSeconds = clamped;
  }

  Future<void> setBottomSingleTapAction(NavTapAction action) async {
    state = state.copyWith(bottomSingleTapAction: action);
    await _prefs.setString(_bottomSingleTapActionKey, action.toStorageKey());
  }

  Future<void> setBottomDoubleTapAction(NavTapAction action) async {
    state = state.copyWith(bottomDoubleTapAction: action);
    await _prefs.setString(_bottomDoubleTapActionKey, action.toStorageKey());
  }

  /// 写入底栏 id 列表（顺序即显示顺序）。调用方负责校验。
  Future<void> setBottomNavIds(List<String> ids) async {
    state = state.copyWith(bottomNavIds: ids);
    await _prefs.setStringList(_bottomNavIdsKey, ids);
  }

  /// 设置 Android 屏幕刷新率偏好（0 = auto，其它为目标刷新率整数）。
  /// 实际生效由调用方在写入后调用 FlutterDisplayMode.setPreferredMode 完成。
  Future<void> setDisplayModeRefreshRate(int rate) async {
    if (state.displayModeRefreshRate == rate) return;
    state = state.copyWith(displayModeRefreshRate: rate);
    await _prefs.setInt(_displayModeRefreshRateKey, rate);
  }

  Future<void> setProgressGesturesEnabled(bool enabled) async {
    if (state.progressGesturesEnabled == enabled) return;
    state = state.copyWith(progressGesturesEnabled: enabled);
    await _prefs.setBool(_progressGesturesEnabledKey, enabled);
  }

  Future<void> setProgressGestureSwipeLeft(ProgressGestureAction action) async {
    if (state.progressGestureSwipeLeft == action) return;
    state = state.copyWith(progressGestureSwipeLeft: action);
    await _prefs.setString(_progressGestureSwipeLeftKey, action.name);
  }

  Future<void> setProgressGestureSwipeRight(
    ProgressGestureAction action,
  ) async {
    if (state.progressGestureSwipeRight == action) return;
    state = state.copyWith(progressGestureSwipeRight: action);
    await _prefs.setString(_progressGestureSwipeRightKey, action.name);
  }

  Future<void> setProgressGestureSwipeUp(ProgressGestureAction action) async {
    if (state.progressGestureSwipeUp == action) return;
    state = state.copyWith(progressGestureSwipeUp: action);
    await _prefs.setString(_progressGestureSwipeUpKey, action.name);
  }

  Future<void> setProgressGestureLongPressEnabled(bool enabled) async {
    if (state.progressGestureLongPressEnabled == enabled) return;
    state = state.copyWith(progressGestureLongPressEnabled: enabled);
    await _prefs.setBool(_progressGestureLongPressEnabledKey, enabled);
  }

  Future<void> setProgressGestureMenuActions(
    List<ProgressGestureAction> actions,
  ) async {
    final deduped = <ProgressGestureAction>[];
    for (final a in actions) {
      if (!deduped.contains(a)) deduped.add(a);
      if (deduped.length >= kProgressGestureMenuMax) break;
    }
    if (const ListEquality<ProgressGestureAction>().equals(
      state.progressGestureMenuActions,
      deduped,
    )) {
      return;
    }
    state = state.copyWith(progressGestureMenuActions: deduped);
    await _prefs.setStringList(
      _progressGestureMenuActionsKey,
      deduped.map((e) => e.name).toList(),
    );
  }

  Future<void> resetProgressGestureMenuActions() async {
    await setProgressGestureMenuActions(_defaultProgressGestureMenu);
  }

  /// 写入编辑器工具栏外显工具 id 列表（顺序无关，渲染按工具注册表顺序）
  Future<void> setEditorToolbarTools(List<String> ids) async {
    final deduped = ids.toSet().toList();
    if (const ListEquality<String>().equals(
      state.editorToolbarTools,
      deduped,
    )) {
      return;
    }
    state = state.copyWith(editorToolbarTools: deduped);
    await _prefs.setStringList(_editorToolbarToolsKey, deduped);
  }

  void _syncSchedulerConfig() {
    RequestSchedulerConfig.maxConcurrent = state.maxConcurrent;
    RequestSchedulerConfig.maxPerWindow = state.maxPerWindow;
    RequestSchedulerConfig.windowSeconds = state.windowSeconds;
  }

  /// 当前竖屏锁定状态（供视频播放器等无法访问 ref 的组件使用）
  static bool isPortraitLocked = false;

  /// 恢复方向锁定设置
  /// 视频退出全屏后调用，重新应用竖屏锁定
  static Future<void> restoreOrientationLock() async {
    if (isPortraitLocked) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
  }
}

final preferencesProvider =
    StateNotifierProvider<PreferencesNotifier, AppPreferences>((ref) {
      final prefs = ref.watch(sharedPreferencesProvider);
      return PreferencesNotifier(prefs);
    });

ProgressGestureAction _readGestureAction(
  String? raw,
  ProgressGestureAction fallback,
) {
  if (raw == null) return fallback;
  for (final a in ProgressGestureAction.values) {
    if (a.name == raw) return a;
  }
  return fallback;
}

List<ProgressGestureAction> _readGestureMenuActions(List<String>? raw) {
  if (raw == null) return _defaultProgressGestureMenu;
  final out = <ProgressGestureAction>[];
  for (final name in raw) {
    for (final a in ProgressGestureAction.values) {
      if (a.name == name && !out.contains(a)) {
        out.add(a);
        break;
      }
    }
    if (out.length >= kProgressGestureMenuMax) break;
  }
  return out;
}
