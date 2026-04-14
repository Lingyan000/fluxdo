// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get about_appLogs => 'App logs';

  @override
  String get about_checkUpdate => 'Check for updates';

  @override
  String about_checkUpdateError(String error) {
    return 'Cannot check for updates.\nError: $error';
  }

  @override
  String get about_checkUpdateFailed => 'Update check failed';

  @override
  String get about_develop => 'Development';

  @override
  String get about_developerMode => 'Developer mode';

  @override
  String get about_developerModeAlreadyEnabled =>
      'Developer mode already enabled';

  @override
  String get about_developerModeClosed => 'Developer mode disabled';

  @override
  String get about_developerModeEnabled => 'Developer mode enabled';

  @override
  String get about_feedback => 'Report issue';

  @override
  String get about_info => 'Info';

  @override
  String get about_latestVersion => 'Up to date';

  @override
  String get about_legalese =>
      'Unofficial Linux.do client\nBuilt with Flutter & Material 3';

  @override
  String about_noUpdateContent(String version) {
    return 'Current version: $version\nYou are using the latest version of FluxDO.';
  }

  @override
  String get about_openSourceLicense => 'Open source licenses';

  @override
  String get about_sourceCode => 'Source code';

  @override
  String get about_tapToDisableDeveloperMode => 'Tap to disable developer mode';

  @override
  String get about_title => 'About';

  @override
  String get deviceInfo_dohOff => 'DOH: Off';

  @override
  String get deviceInfo_proxyOff => 'Proxy: Off';

  @override
  String get update_changelog => 'What\'s new';

  @override
  String get update_dontRemind => 'Don\'t remind';

  @override
  String get update_newVersionFound => 'New version available';

  @override
  String get update_now => 'Update now';

  @override
  String get update_rateLimited => 'GitHub API rate limited, try later';

  @override
  String get ai_askSubtitle => 'AI will answer based on topic content';

  @override
  String get ai_askTitle => 'Ask AI Assistant';

  @override
  String get ai_clearChat => 'Clear chat';

  @override
  String get ai_clearChatConfirm => 'Clear all chat history?';

  @override
  String get ai_clearChatTitle => 'Clear chat';

  @override
  String get ai_clearLabel => 'Clear';

  @override
  String get ai_copiedToClipboard => 'Copied to clipboard';

  @override
  String get ai_copyLabel => 'Copy';

  @override
  String get ai_exportImage => 'Export image';

  @override
  String get ai_generateFailed => 'Generation failed';

  @override
  String get ai_highlights => 'What\'s worth noting';

  @override
  String get ai_highlightsPrompt =>
      'What notable information or highlights are in this topic?';

  @override
  String get ai_inputHint => 'Enter message...';

  @override
  String get ai_likeInDev => 'Like feature in development...';

  @override
  String get ai_listViewpoints => 'List main viewpoints';

  @override
  String get ai_listViewpointsPrompt =>
      'Please list the main viewpoints and positions from each post.';

  @override
  String get ai_moreTooltip => 'More';

  @override
  String get ai_multiSelectExport => 'Multi-select export';

  @override
  String get ai_newSession => 'New session';

  @override
  String get ai_retryLabel => 'Retry';

  @override
  String get ai_selectContext => 'Select context range';

  @override
  String get ai_selectExportMessages => 'Select messages to export';

  @override
  String get ai_selectModel => 'Select model';

  @override
  String ai_selectedCount(int count) {
    return '$count selected';
  }

  @override
  String get ai_sendTooltip => 'Send';

  @override
  String ai_sessionCount(int count) {
    return '$count sessions';
  }

  @override
  String get ai_sessionHistory => 'Session history';

  @override
  String ai_sessionTitle(int index) {
    return 'Session $index';
  }

  @override
  String get ai_stopGenerate => 'Stop generating';

  @override
  String get ai_summarizePrompt =>
      'Please briefly summarize the main content and key discussion points.';

  @override
  String get ai_summarizeTopic => 'Summarize this topic';

  @override
  String get ai_swipeHint => 'Swipe left to open AI Assistant';

  @override
  String get ai_title => 'AI Assistant';

  @override
  String get ai_translatePost => 'Translate first post';

  @override
  String get ai_translatePrompt =>
      'Please translate the first post content into English.';

  @override
  String get ai_typingIndicator => 'Typing';

  @override
  String get appearance_appIcon => 'App icon';

  @override
  String get appearance_colorAmber => 'Amber';

  @override
  String get appearance_colorBlue => 'Blue';

  @override
  String get appearance_colorGreen => 'Green';

  @override
  String get appearance_colorIndigo => 'Indigo';

  @override
  String get appearance_colorOrange => 'Orange';

  @override
  String get appearance_colorPink => 'Pink';

  @override
  String get appearance_colorPurple => 'Purple';

  @override
  String get appearance_colorRed => 'Red';

  @override
  String get appearance_colorTeal => 'Teal';

  @override
  String get appearance_contentFontSize => 'Content font size';

  @override
  String get appearance_dialogBlur => 'Dialog Blur';

  @override
  String get appearance_dialogBlurDesc => 'Blur background when dialog appears';

  @override
  String get appearance_font => 'Font';

  @override
  String get appearance_fontSystem => 'System default';

  @override
  String get appearance_iconClassic => 'Classic';

  @override
  String get appearance_iconModern => 'Modern';

  @override
  String get appearance_language => 'Language';

  @override
  String get appearance_languageEn => 'English';

  @override
  String get appearance_languageSystem => 'System default';

  @override
  String get appearance_languageZhCN => '简体中文';

  @override
  String get appearance_languageZhHK => '繁體中文（香港）';

  @override
  String get appearance_languageZhTW => '繁體中文（台灣）';

  @override
  String get appearance_large => 'Large';

  @override
  String get appearance_modeAuto => 'Auto';

  @override
  String get appearance_modeDark => 'Dark';

  @override
  String get appearance_modeLight => 'Light';

  @override
  String get appearance_panguSpacing => 'CJK spacing';

  @override
  String get appearance_panguSpacingDesc =>
      'Auto-optimize CJK/Latin spacing in posts';

  @override
  String get appearance_reading => 'Reading';

  @override
  String get appearance_schemeVariant => 'Color Scheme';

  @override
  String get appearance_small => 'Small';

  @override
  String get appearance_switchIconFailed =>
      'Failed to switch icon, please retry';

  @override
  String get appearance_themeColor => 'Theme color';

  @override
  String get appearance_themeMode => 'Theme mode';

  @override
  String get appearance_title => 'Appearance';

  @override
  String get layout_selectTopicHint => 'Select a topic to view details';

  @override
  String get reading_aiSwipeEntry => 'AI Assistant swipe entry';

  @override
  String get reading_aiSwipeEntryDesc =>
      'Swipe left in topic detail to open AI Assistant';

  @override
  String get reading_expandRelatedLinks => 'Expand related links by default';

  @override
  String get reading_expandRelatedLinksDesc =>
      'Show related links expanded in posts';

  @override
  String get reading_title => 'Reading Settings';

  @override
  String get schemeVariant_content => 'Content';

  @override
  String get schemeVariant_expressive => 'Expressive';

  @override
  String get schemeVariant_fidelity => 'Fidelity';

  @override
  String get schemeVariant_fruitSalad => 'Fruit Salad';

  @override
  String get schemeVariant_monochrome => 'Mono';

  @override
  String get schemeVariant_neutral => 'Neutral';

  @override
  String get schemeVariant_rainbow => 'Rainbow';

  @override
  String get schemeVariant_tonalSpot => 'Tonal Spot';

  @override
  String get schemeVariant_vibrant => 'Vibrant';

  @override
  String get auth_cdkConfirmMessage =>
      'Linux.do CDK will access your basic info. Allow?';

  @override
  String get auth_cdkConfirmTitle => 'Authorization';

  @override
  String get auth_clearDataAction => 'Clear data';

  @override
  String get auth_cookieRepairLogoutHint =>
      'The app detected invalid legacy login cookies and automatically cleaned related stale data. This can immediately invalidate an old broken session. Please log in again.';

  @override
  String get auth_frequentLogoutClearDataHint =>
      'Session invalidation has occurred multiple times in the last 24 hours. If it still keeps happening after you log in again, go to Data Management and clear cookies or all app data before logging in again.';

  @override
  String get auth_ldcConfirmMessage =>
      'Linux.do Credit will access your basic info. Allow?';

  @override
  String get auth_ldcConfirmTitle => 'Authorization';

  @override
  String get auth_logSubject => 'Auth log';

  @override
  String get auth_loginExpiredRelogin => 'Session expired, please log in again';

  @override
  String get auth_loginExpiredTitle => 'Session expired';

  @override
  String auth_oauthExpired(String serviceName) {
    return '$serviceName authorization expired';
  }

  @override
  String get login_browserHint => 'Will open login page in browser';

  @override
  String get login_slogan => 'Sincere, Friendly, United, Professional';

  @override
  String get migration_cookieUpgrade => 'Upgrading cookie storage...';

  @override
  String get migration_reloginRequired =>
      'Cookie storage has been upgraded. Your login session was cleared. Please log in again.';

  @override
  String get migration_title => 'Data Upgrade';

  @override
  String get oauth_approvePageParseFailed =>
      'Failed to parse authorization page, please ensure you are logged in';

  @override
  String get oauth_callbackFailed => 'Authorization callback failed';

  @override
  String get oauth_getAuthUrlFailed => 'Failed to get authorization URL';

  @override
  String get oauth_missingParams =>
      'Authorization callback missing required parameters';

  @override
  String get oauth_networkError =>
      'Network request failed, please check your connection';

  @override
  String get oauth_noRedirectResponse =>
      'Authorization service did not return a redirect';

  @override
  String get onboarding_guestAccess => 'Guest access';

  @override
  String get onboarding_networkSettings => 'Network settings';

  @override
  String get onboarding_slogan => 'Sincere · Friendly · United · Professional';

  @override
  String get badge_bronze => 'Bronze';

  @override
  String get badge_bronzeBadge => 'Bronze badge';

  @override
  String get badge_defaultName => 'Badge';

  @override
  String get badge_gold => 'Gold';

  @override
  String get badge_goldBadge => 'Gold badge';

  @override
  String badge_grantedCount(int count) {
    return 'Granted $count times';
  }

  @override
  String get badge_grantedSuffix => ' earned';

  @override
  String badge_granteeCount(int count) {
    return '$count users';
  }

  @override
  String get badge_grantees => 'Grantees';

  @override
  String get badge_myBadges => 'My badges';

  @override
  String get badge_noGrantees => 'No users have earned this badge';

  @override
  String get badge_silver => 'Silver';

  @override
  String get badge_silverBadge => 'Silver badge';

  @override
  String get myBadges_badgeUnit => ' badges';

  @override
  String get myBadges_empty => 'No badges';

  @override
  String get myBadges_title => 'My Badges';

  @override
  String get myBadges_totalEarned => 'Total earned';

  @override
  String get bookmark_deleteConfirm => 'Delete this bookmark?';

  @override
  String get bookmark_editBookmark => 'Edit bookmark';

  @override
  String get bookmark_nameHint => 'Add a note...';

  @override
  String get bookmark_nameLabel => 'Bookmark name (optional)';

  @override
  String get bookmark_reminderCustom => 'Custom';

  @override
  String get bookmark_reminderExpired => 'Reminder expired';

  @override
  String get bookmark_reminderNextWeek => 'Next week';

  @override
  String get bookmark_reminderThreeDays => 'In 3 days';

  @override
  String bookmark_reminderTime(String time) {
    return 'Reminder: $time';
  }

  @override
  String get bookmark_reminderTomorrow => 'Tomorrow';

  @override
  String get bookmark_reminderTwoHours => 'In 2 hours';

  @override
  String get bookmark_removed => 'Bookmark removed';

  @override
  String get bookmark_setReminder => 'Set reminder';

  @override
  String get bookmarks_cancelReminder => 'Cancel reminder';

  @override
  String get bookmarks_deleted => 'Bookmark deleted';

  @override
  String get bookmarks_empty => 'No bookmarks';

  @override
  String get bookmarks_emptySearchHint => 'Enter keywords to search bookmarks';

  @override
  String get bookmarks_expired => ' expired';

  @override
  String get bookmarks_reminderCancelled => 'Reminder cancelled';

  @override
  String get bookmarks_searchHint => 'Search bookmarks...';

  @override
  String get bookmarks_title => 'My Bookmarks';

  @override
  String get readLater_title => 'Read later';

  @override
  String get categoryTopics_createPost => 'Create post';

  @override
  String get categoryTopics_empty => 'No topics in this category';

  @override
  String get category_addHint => 'Tap categories below to add to tab bar';

  @override
  String get category_allCategories => 'All categories';

  @override
  String get category_available => 'Available';

  @override
  String get category_browse => 'Browse categories';

  @override
  String get category_dragHint => 'Drag to reorder, tap to remove';

  @override
  String get category_editHint => 'Tap \"Edit\" to add categories to tab bar';

  @override
  String get category_editMyCategories => 'Edit my categories';

  @override
  String get category_levelMuted => 'Muted';

  @override
  String get category_levelMutedDesc => 'No notifications from this category';

  @override
  String get category_levelRegular => 'Normal';

  @override
  String get category_levelRegularDesc =>
      'Only notify when @mentioned or replied';

  @override
  String get category_levelTracking => 'Tracking';

  @override
  String get category_levelTrackingDesc => 'Show unread count';

  @override
  String get category_levelWatching => 'Watching';

  @override
  String get category_levelWatchingDesc => 'Notify for every new reply';

  @override
  String get category_levelWatchingFirstPost => 'Watching first post';

  @override
  String get category_levelWatchingFirstPostDesc =>
      'Notify when new topics are created';

  @override
  String category_loadFailed(String error) {
    return 'Failed to load categories: $error';
  }

  @override
  String get category_myCategories => 'My categories';

  @override
  String get category_noCategories => 'No categories';

  @override
  String get category_noCategoriesFound => 'No categories found';

  @override
  String category_parentAll(String name) {
    return '$name (All)';
  }

  @override
  String get category_searchHint => 'Search categories...';

  @override
  String get tagTopics_empty => 'No topics with this tag';

  @override
  String tag_maxTagsReached(int max) {
    return 'Maximum $max tags allowed';
  }

  @override
  String get tag_noTags => 'No tags available';

  @override
  String get tag_noTagsFound => 'No tags found';

  @override
  String tag_requiredGroupWarning(String name, int minCount) {
    return 'Select at least $minCount tags from \"$name\"';
  }

  @override
  String tag_requiredTagGroupHint(String name, int minCount) {
    return 'Select at least $minCount from \"$name\"';
  }

  @override
  String get tag_searchHint => 'Search tags...';

  @override
  String tag_searchWithCount(int count) {
    return 'Search tags ($count selected)...';
  }

  @override
  String tag_searchWithMax(int selected, int max) {
    return 'Search tags ($selected/$max)...';
  }

  @override
  String tag_searchWithMin(int selected, int min) {
    return 'Search tags ($selected selected, min $min)...';
  }

  @override
  String tag_topicCount(int count) {
    return '$count topics';
  }

  @override
  String get common_about => 'About';

  @override
  String get common_add => 'Add';

  @override
  String get common_addBookmark => 'Add bookmark';

  @override
  String get common_added => 'Added';

  @override
  String get common_all => 'All';

  @override
  String get common_allow => 'Allow';

  @override
  String get common_authExpired => 'Authorization expired';

  @override
  String get common_back => 'Back';

  @override
  String get common_bookmarkAdded => 'Bookmark added';

  @override
  String get common_bookmarkRemoved => 'Bookmark removed';

  @override
  String get common_bookmarkUpdated => 'Bookmark updated';

  @override
  String get common_cancel => 'Cancel';

  @override
  String get common_cannotOpenBrowser => 'Cannot open browser';

  @override
  String get common_checkInput => 'Please check input';

  @override
  String get common_checkNetworkRetry => 'Please check network and retry';

  @override
  String get common_clear => 'Clear';

  @override
  String common_clearFailed(String error) {
    return 'Clear failed: $error';
  }

  @override
  String get common_clipboardUnavailable => 'Clipboard unavailable';

  @override
  String get common_close => 'Close';

  @override
  String get common_closePreview => 'Close preview';

  @override
  String get common_codeCopied => 'Code copied';

  @override
  String get common_confirm => 'OK';

  @override
  String get common_continue => 'Continue';

  @override
  String get common_continueVisit => 'Continue';

  @override
  String get common_copiedToClipboard => 'Copied to clipboard';

  @override
  String get common_copy => 'Copy';

  @override
  String get common_copyLink => 'Copy link';

  @override
  String get common_copyQuote => 'Copy quote';

  @override
  String get common_custom => 'Custom';

  @override
  String get common_decodeAvif => 'Decoding AVIF';

  @override
  String get common_delete => 'Delete';

  @override
  String get common_deleteBookmark => 'Delete bookmark';

  @override
  String get common_deleted => 'Deleted';

  @override
  String get common_deny => 'Deny';

  @override
  String get common_details => 'Details';

  @override
  String get common_discard => 'Discard';

  @override
  String get common_done => 'Done';

  @override
  String get common_edit => 'Edit';

  @override
  String get common_editTopic => 'Edit topic';

  @override
  String get common_enable => 'Enable';

  @override
  String get common_error => 'Error';

  @override
  String get common_errorDetails => 'Error details';

  @override
  String get common_exit => 'Exit';

  @override
  String get common_exitPreview => 'Exit preview';

  @override
  String get common_export => 'Export';

  @override
  String get common_failed => 'Failed';

  @override
  String get common_fillComplete => 'Please fill in all fields';

  @override
  String get common_filter => 'Filter';

  @override
  String get common_gotIt => 'Got it';

  @override
  String get common_help => 'Help';

  @override
  String get common_hint => 'Hint';

  @override
  String get common_import => 'Import';

  @override
  String get common_later => 'Later';

  @override
  String get common_linkCopied => 'Link copied';

  @override
  String get common_loadFailed => 'Failed to load';

  @override
  String get common_loadFailedRetry => 'Failed to load, please retry';

  @override
  String get common_loadFailedTapRetry => 'Failed to load, tap to retry';

  @override
  String get common_loading => 'Loading...';

  @override
  String get common_loadingData => 'Loading data...';

  @override
  String get common_login => 'Log in';

  @override
  String get common_logout => 'Log out';

  @override
  String get common_more => 'More';

  @override
  String get common_name => 'Name';

  @override
  String get common_networkDisconnected => 'Network disconnected';

  @override
  String get common_noContent => 'No content';

  @override
  String get common_noData => 'No data';

  @override
  String get common_noMore => 'No more';

  @override
  String get common_notConfigured => 'Not configured';

  @override
  String get common_notSet => 'Not set';

  @override
  String get common_notification => 'Notifications';

  @override
  String get common_ok => 'OK';

  @override
  String common_operationFailed(String error) {
    return 'Operation failed: $error';
  }

  @override
  String get common_paste => 'Paste';

  @override
  String get common_pleaseLogin => 'Please log in first';

  @override
  String get common_pleaseWait => 'Please wait...';

  @override
  String get common_preview => 'Preview';

  @override
  String get common_publish => 'Publish';

  @override
  String get common_quote => 'Quote';

  @override
  String get common_quoteCopied => 'Quote copied';

  @override
  String get common_reAuth => 'Re-authorize';

  @override
  String get common_recentlyUsed => 'Recently used';

  @override
  String get common_redo => 'Redo';

  @override
  String get common_refresh => 'Refresh';

  @override
  String get common_remove => 'Remove';

  @override
  String get common_reply => 'Reply';

  @override
  String get common_report => 'Report';

  @override
  String get common_reset => 'Reset';

  @override
  String get common_restore => 'Restore';

  @override
  String get common_restoreDefault => 'Restore default';

  @override
  String get common_restored => 'Restored';

  @override
  String get common_retry => 'Retry';

  @override
  String get common_save => 'Save';

  @override
  String get common_search => 'Search';

  @override
  String get common_searchHint => 'Search...';

  @override
  String get common_searchMore => 'Search more';

  @override
  String get common_send => 'Send';

  @override
  String get common_share => 'Share';

  @override
  String get common_shareFailed => 'Failed to share, please retry';

  @override
  String get common_shareImage => 'Share image';

  @override
  String get common_shareLink => 'Share link';

  @override
  String common_sizeBytes(String size) {
    return '$size Bytes';
  }

  @override
  String common_sizeGB(String size) {
    return '$size GB';
  }

  @override
  String common_sizeKB(String size) {
    return '$size KB';
  }

  @override
  String common_sizeMB(String size) {
    return '$size MB';
  }

  @override
  String get common_skip => 'Skip';

  @override
  String get common_success => 'Success';

  @override
  String get common_test => 'Test';

  @override
  String get common_title => 'Title';

  @override
  String get common_trustRequirements => 'Trust requirements';

  @override
  String get common_understood => 'Understood';

  @override
  String get common_undo => 'Undo';

  @override
  String get common_unknown => 'Unknown';

  @override
  String get common_unknownError => 'Unknown error';

  @override
  String get common_upload => 'Upload';

  @override
  String get common_view => 'View';

  @override
  String get common_viewAll => 'View all';

  @override
  String get common_viewDetails => 'View details';

  @override
  String createTopic_charCount(int count) {
    return '$count characters';
  }

  @override
  String get createTopic_confirmPublish => 'Publish';

  @override
  String get createTopic_contentHint => 'Content (Markdown supported)...';

  @override
  String get createTopic_continueEditing => 'Continue editing';

  @override
  String get createTopic_discardPost => 'Discard post';

  @override
  String get createTopic_discardPostContent => 'Discard your post?';

  @override
  String get createTopic_enterContent => 'Please enter content';

  @override
  String get createTopic_enterTitle => 'Please enter a title';

  @override
  String createTopic_loadCategoryFailed(String error) {
    return 'Failed to load categories: $error';
  }

  @override
  String createTopic_minContentLength(int min) {
    return 'Content needs at least $min characters';
  }

  @override
  String createTopic_minTags(int min) {
    return 'This category requires at least $min tags';
  }

  @override
  String createTopic_minTitleLength(int min) {
    return 'Title needs at least $min characters';
  }

  @override
  String get createTopic_noContent => '(No content)';

  @override
  String get createTopic_noTitle => '(No title)';

  @override
  String get createTopic_pendingReview => 'Your post is pending review';

  @override
  String get createTopic_restoreDraft => 'Restore draft';

  @override
  String get createTopic_restoreDraftContent =>
      'An unsent draft was found. Restore it?';

  @override
  String get createTopic_selectCategory => 'Please select a category';

  @override
  String get createTopic_templateNotModified =>
      'You haven\'t modified the template. Publish anyway?';

  @override
  String get createTopic_title => 'Create Topic';

  @override
  String get createTopic_titleHint => 'Enter an engaging title...';

  @override
  String get editTopic_editPm => 'Edit PM';

  @override
  String get editTopic_editTopic => 'Edit Topic';

  @override
  String editTopic_loadContentFailed(String error) {
    return 'Failed to load content: $error';
  }

  @override
  String get backup_invalidFormat => 'Invalid backup format';

  @override
  String get backup_missingDataField => 'Invalid backup: missing data field';

  @override
  String get dataManagement_aiChatCleared => 'AI chat data cleared';

  @override
  String get dataManagement_aiChatData => 'AI chat data';

  @override
  String get dataManagement_allCleared =>
      'All cache cleared, please log in again';

  @override
  String dataManagement_apiKeysCount(int count) {
    return 'Contains $count API Keys';
  }

  @override
  String get dataManagement_autoManagement => 'Auto management';

  @override
  String dataManagement_backupSource(String version) {
    return 'Backup from: v$version';
  }

  @override
  String get dataManagement_backupSubject => 'FluxDO Data Backup';

  @override
  String get dataManagement_cacheManagement => 'Cache management';

  @override
  String get dataManagement_calculating => 'Calculating...';

  @override
  String get dataManagement_clearAiChatContent =>
      'This will delete all AI chat history. This cannot be undone.';

  @override
  String get dataManagement_clearAiChatTitle => 'Clear AI chat data';

  @override
  String get dataManagement_clearAll => 'Clear all';

  @override
  String get dataManagement_clearAllCache => 'Clear all cache';

  @override
  String get dataManagement_clearAllContent =>
      'This will clear all cached data including images, AI chat data, and cookies.\n\nYou will need to log in again after clearing cookies.';

  @override
  String get dataManagement_clearAllTitle => 'Clear all cache';

  @override
  String get dataManagement_clearAndLogout => 'Clear and log out';

  @override
  String get dataManagement_clearCookieContent =>
      'You will need to log in again after clearing cookies. Continue?';

  @override
  String get dataManagement_clearCookieTitle => 'Clear Cookie cache';

  @override
  String get dataManagement_clearOnExit => 'Clear image cache on exit';

  @override
  String get dataManagement_clearOnExitDesc =>
      'Auto-clear image cache on next launch';

  @override
  String get dataManagement_confirmImport => 'Confirm import';

  @override
  String get dataManagement_cookieCache => 'Cookie cache';

  @override
  String get dataManagement_cookieCleared =>
      'Cookie cache cleared, please log in again';

  @override
  String get dataManagement_dataBackup => 'Data backup';

  @override
  String get dataManagement_exportData => 'Export data';

  @override
  String get dataManagement_exportDesc => 'Export preferences to file';

  @override
  String dataManagement_exportFailed(String error) {
    return 'Export failed: $error';
  }

  @override
  String dataManagement_exportTime(String time) {
    return 'Export time: $time';
  }

  @override
  String get dataManagement_imageCache => 'Image cache';

  @override
  String get dataManagement_imageCacheCleared => 'Image cache cleared';

  @override
  String get dataManagement_importAndRestart => 'Import and restart';

  @override
  String get dataManagement_importData => 'Import data';

  @override
  String get dataManagement_importDesc => 'Restore preferences from backup';

  @override
  String dataManagement_importFailed(String error) {
    return 'Import failed: $error';
  }

  @override
  String get dataManagement_importSuccess =>
      'Data imported, please restart app';

  @override
  String get dataManagement_importWarning =>
      'Importing will overwrite current settings. Restart required.';

  @override
  String get dataManagement_noCache => 'No cache';

  @override
  String dataManagement_settingsCount(int count) {
    return 'Contains $count settings';
  }

  @override
  String get dataManagement_title => 'Data Management';

  @override
  String get appLogs_appStart => 'App start';

  @override
  String get appLogs_clearContent => 'Clear all logs? This cannot be undone.';

  @override
  String get appLogs_clearLogs => 'Clear logs';

  @override
  String get appLogs_clearTitle => 'Clear logs';

  @override
  String get appLogs_copyAll => 'Copy all';

  @override
  String get appLogs_copyDeviceInfo => 'Copy device info';

  @override
  String get appLogs_duration => 'Duration';

  @override
  String get appLogs_error => 'Error';

  @override
  String get appLogs_errorType => 'Error type';

  @override
  String get appLogs_event => 'Event';

  @override
  String get appLogs_feedbackSending => 'Sending feedback...';

  @override
  String get appLogs_feedbackSent => 'Feedback sent';

  @override
  String get appLogs_feedbackTitle => 'App Log Feedback';

  @override
  String get appLogs_level => 'Level';

  @override
  String get appLogs_lifecycle => 'Lifecycle';

  @override
  String get appLogs_lifecycleEvent => 'Lifecycle event';

  @override
  String get appLogs_logoutActive => 'Active logout';

  @override
  String get appLogs_logoutPassive => 'Passive logout';

  @override
  String get appLogs_logsCleared => 'Logs cleared';

  @override
  String get appLogs_message => 'Message';

  @override
  String get appLogs_method => 'Method';

  @override
  String get appLogs_noLogs => 'No logs';

  @override
  String get appLogs_noMatchingLogs => 'No matching logs';

  @override
  String get appLogs_reason => 'Reason';

  @override
  String get appLogs_request => 'Request';

  @override
  String get appLogs_sendFeedback => 'Send logs via PM';

  @override
  String get appLogs_shareLogs => 'Share logs';

  @override
  String get appLogs_shareSubject => 'App Logs';

  @override
  String get appLogs_stack => 'Stack';

  @override
  String get appLogs_stackTrace => 'Stack trace';

  @override
  String get appLogs_statusCode => 'Status code';

  @override
  String get appLogs_tag => 'Tag';

  @override
  String get appLogs_time => 'Time';

  @override
  String get appLogs_title => 'App Logs';

  @override
  String get appLogs_type => 'Type';

  @override
  String get appLogs_user => 'User';

  @override
  String get appLogs_userLogin => 'User login';

  @override
  String get appLogs_version => 'Version';

  @override
  String get debugTools_cfLogs => 'CF Verification Logs';

  @override
  String get debugTools_cfLogsCleared => 'CF logs cleared';

  @override
  String get debugTools_cfLogsDesc => 'View Cloudflare verification details';

  @override
  String get debugTools_cfLogsTitle => 'CF Verification Logs';

  @override
  String get debugTools_clearCfLogs => 'Clear CF logs';

  @override
  String get debugTools_clearCfLogsConfirm => 'Clear all CF verification logs?';

  @override
  String get debugTools_clearCfLogsTitle => 'Clear CF logs';

  @override
  String get debugTools_clearLogs => 'Clear logs';

  @override
  String get debugTools_clearLogsConfirm => 'Clear all logs?';

  @override
  String get debugTools_clearLogsTitle => 'Clear logs';

  @override
  String get debugTools_debugLogs => 'Debug logs';

  @override
  String get debugTools_exportCfLogs => 'Export CF logs';

  @override
  String get debugTools_logsCleared => 'Logs cleared';

  @override
  String get debugTools_noCfLogs => 'No CF verification logs';

  @override
  String get debugTools_noCfLogsHint =>
      'Logs appear after CF verification is triggered';

  @override
  String get debugTools_noCfLogsToShare => 'No CF logs to share';

  @override
  String get debugTools_noLogs => 'No logs';

  @override
  String get debugTools_noLogsHint =>
      'Logs appear after enabling DOH and making requests';

  @override
  String get debugTools_noLogsToShare => 'No logs to share';

  @override
  String get debugTools_shareLogs => 'Share logs';

  @override
  String get debugTools_viewLogs => 'View logs';

  @override
  String get dohDetail_addServer => 'Add Server';

  @override
  String get dohDetail_bootstrapIpHelper =>
      'Connect to DoH server directly via IP, bypassing DNS resolution';

  @override
  String get dohDetail_bootstrapIpHint =>
      'Comma separated, e.g. 1.1.1.1, 1.0.0.1';

  @override
  String get dohDetail_bootstrapIpOptional => 'Bootstrap IP (Optional)';

  @override
  String get dohDetail_clearCache => 'Clear Cache';

  @override
  String dohDetail_clearDnsCacheFailed(String error) {
    return 'Failed to clear DNS cache: $error';
  }

  @override
  String get dohDetail_copyAddress => 'Copy address';

  @override
  String get dohDetail_deleteServer => 'Delete Server';

  @override
  String dohDetail_deleteServerConfirm(String name) {
    return 'Are you sure you want to delete \"$name\"?';
  }

  @override
  String get dohDetail_dnsCacheCleared => 'DNS cache cleared';

  @override
  String dohDetail_dnsCacheDesc(int count) {
    return 'Currently cached $count domains. Proxy mode and query mode share cache, background refresh when TTL is near expiry.';
  }

  @override
  String dohDetail_dnsCacheRefreshed(int count) {
    return 'DNS cache force refreshed ($count domains)';
  }

  @override
  String get dohDetail_dnsCacheRefreshedSimple => 'DNS cache force refreshed';

  @override
  String get dohDetail_dnsCacheSection => 'DNS Cache';

  @override
  String get dohDetail_dohAddress => 'DoH Address';

  @override
  String get dohDetail_dohAddressCopied => 'DoH address copied';

  @override
  String get dohDetail_echSameAsDnsDesc =>
      'Use DNS resolver to query ECH configuration';

  @override
  String get dohDetail_echServer => 'ECH Server';

  @override
  String get dohDetail_editServer => 'Edit Server';

  @override
  String get dohDetail_exampleDns => 'e.g. My DNS';

  @override
  String get dohDetail_forceRefresh => 'Force Refresh';

  @override
  String get dohDetail_gatewayDisabledDesc => 'Disabled, using MITM dual TLS';

  @override
  String get dohDetail_gatewayEnabledDesc =>
      'Single TLS, forwarded via reverse proxy';

  @override
  String get dohDetail_gatewayMode => 'Gateway Mode';

  @override
  String get dohDetail_ipAddress => 'IP Address';

  @override
  String get dohDetail_ipv6Prefer => 'Prefer IPv6';

  @override
  String get dohDetail_ipv6PreferDesc =>
      'Try IPv6 first, fallback to IPv4 on failure';

  @override
  String get dohDetail_localDnsCache => 'Shared Local DNS Cache';

  @override
  String get dohDetail_noServers => 'No servers';

  @override
  String get dohDetail_processing => 'Processing';

  @override
  String dohDetail_refreshDnsCacheFailed(String error) {
    return 'Failed to force refresh DNS cache: $error';
  }

  @override
  String get dohDetail_sameAsDns => 'Same as DNS';

  @override
  String get dohDetail_selectEchServer => 'Select ECH Server';

  @override
  String get dohDetail_serverIp => 'Server IP';

  @override
  String get dohDetail_serverIpHint =>
      'Specify connection IP, skip DNS resolution';

  @override
  String get dohDetail_servers => 'Servers';

  @override
  String get dohDetail_testAllSpeed => 'Test All';

  @override
  String get dohDetail_testSpeed => 'Test speed';

  @override
  String get dohDetail_testingSpeed => 'Testing...';

  @override
  String get dohDetail_title => 'DOH Detail Settings';

  @override
  String get dohDetail_urlMustHttps => 'Address must start with https://';

  @override
  String get dohSettings_certAllDone => 'All Steps Completed';

  @override
  String get dohSettings_certDialogDesc =>
      'HTTPS interception requires installing and trusting a CA certificate, each device generates a unique certificate';

  @override
  String get dohSettings_certDialogTitle => 'CA Certificate Installation';

  @override
  String get dohSettings_certDownloadFailed => 'Profile download failed';

  @override
  String get dohSettings_certDownloadHint =>
      'Tap the button below, Safari will prompt to download. Tap \"Allow\".';

  @override
  String get dohSettings_certDownloadProfile => 'Download Profile';

  @override
  String get dohSettings_certInstall => 'Install';

  @override
  String get dohSettings_certInstallHint =>
      'Install and trust the certificate for HTTPS interception';

  @override
  String get dohSettings_certInstallProfileHint =>
      'Go to Settings → General → VPN & Device Management, find the DOH Proxy CA profile and install it.';

  @override
  String get dohSettings_certInstalled => 'CA Certificate Installed';

  @override
  String get dohSettings_certInstalledNext => 'Installed, Next';

  @override
  String get dohSettings_certOpenSettings => 'Open Settings';

  @override
  String get dohSettings_certPreparing => 'Preparing...';

  @override
  String get dohSettings_certRegenerate => 'Regenerate Certificate';

  @override
  String get dohSettings_certRegenerateFailed =>
      'Certificate regeneration failed';

  @override
  String get dohSettings_certRegenerated => 'New certificate generated';

  @override
  String get dohSettings_certReinstall => 'Reinstall';

  @override
  String get dohSettings_certReinstallHint =>
      'Tap to reinstall or replace certificate';

  @override
  String get dohSettings_certRequired => 'CA Certificate Required';

  @override
  String get dohSettings_certStepDownload => 'Download Profile';

  @override
  String get dohSettings_certStepInstall => 'Install Profile';

  @override
  String get dohSettings_certStepTrust => 'Trust Certificate';

  @override
  String get dohSettings_certTrustHint =>
      'Go to Settings → General → About → Certificate Trust Settings, enable the trust switch for DOH Proxy CA.';

  @override
  String get dohSettings_disabledDesc => 'Using system default DNS';

  @override
  String get dohSettings_enabledDesc => 'Encrypted DNS resolution enabled';

  @override
  String get dohSettings_errorCopied => 'Error message copied';

  @override
  String get dohSettings_moreSettings => 'More Settings';

  @override
  String get dohSettings_moreSettingsDesc => 'Servers, IPv6, ECH, etc.';

  @override
  String get dohSettings_perDeviceCert => 'Per-Device Certificate';

  @override
  String get dohSettings_perDeviceCertDisabledDesc =>
      'Enable to generate a unique CA certificate per device for better security';

  @override
  String get dohSettings_perDeviceCertEnabledDesc =>
      'Enabled, each device uses its own CA certificate';

  @override
  String dohSettings_port(int port) {
    return 'Port $port';
  }

  @override
  String get dohSettings_proxyNotStarted => 'Proxy Not Started';

  @override
  String get dohSettings_proxyRunning => 'Proxy Running';

  @override
  String get dohSettings_proxyStartFailed =>
      'Proxy start failed, DoH/ECH cannot take effect';

  @override
  String get dohSettings_restartProxy => 'Restart Proxy';

  @override
  String get dohSettings_restarting => 'Restarting...';

  @override
  String get dohSettings_starting => 'Starting...';

  @override
  String get dohSettings_suppressedByVpn =>
      'Auto-disabled by VPN, will restore when VPN disconnects';

  @override
  String get doh_cannotConnect => 'Cannot connect to DOH service';

  @override
  String get doh_executableNotFound => 'Proxy executable not found';

  @override
  String get doh_invalidHttpResponse => 'Invalid HTTP response';

  @override
  String get doh_queryFailed => 'DOH query failed';

  @override
  String get doh_serverAlibaba => 'Alibaba DNS';

  @override
  String doh_serverError(String statusLine) {
    return 'DOH server error: $statusLine';
  }

  @override
  String get doh_serverTencent => 'Tencent DNS';

  @override
  String get doh_startTimeout => 'Proxy start timeout (5s)';

  @override
  String get doh_unknownReason => 'Unknown reason';

  @override
  String get codeBlock_chart => 'Chart';

  @override
  String get codeBlock_chartLoadFailed => 'Chart load failed';

  @override
  String get codeBlock_code => 'Code';

  @override
  String codeBlock_renderFailed(String error) {
    return 'Code block render failed: $error';
  }

  @override
  String draft_topicTitle(String id) {
    return 'Topic #$id';
  }

  @override
  String get draft_untitled => 'Untitled';

  @override
  String get drafts_deleteContent => 'Delete this draft?';

  @override
  String get drafts_deleteDraft => 'Delete draft';

  @override
  String drafts_deleteFailed(String error) {
    return 'Delete failed: $error';
  }

  @override
  String get drafts_deleteTitle => 'Delete draft';

  @override
  String get drafts_deleted => 'Draft deleted';

  @override
  String get drafts_draft => 'Draft';

  @override
  String get drafts_empty => 'No drafts';

  @override
  String get drafts_newTopic => 'New topic';

  @override
  String get drafts_pmIncomplete => 'PM draft data incomplete';

  @override
  String get drafts_privateMessage => 'Private message';

  @override
  String drafts_replyToPost(int number) {
    return 'Reply to #$number';
  }

  @override
  String get drafts_title => 'My Drafts';

  @override
  String get editor_hintText => 'Say something... (Markdown supported)';

  @override
  String get editor_noContent => '(No content)';

  @override
  String get link_insertTitle => 'Insert link';

  @override
  String get link_textHint => 'Display text';

  @override
  String get link_textLabel => 'Link text';

  @override
  String get link_textRequired => 'Please enter link text';

  @override
  String get link_urlRequired => 'Please enter URL';

  @override
  String get mention_group => 'Group';

  @override
  String get mention_noUserFound => 'No matching user';

  @override
  String get mention_searchHint => 'Search username';

  @override
  String get template_empty => 'No templates available';

  @override
  String get template_insertTitle => 'Insert Template';

  @override
  String get template_loadError => 'Failed to load templates';

  @override
  String get template_searchHint => 'Search templates...';

  @override
  String get template_tooltip => 'Template';

  @override
  String get toolbar_attachFileTooltip => 'Upload attachment';

  @override
  String get toolbar_boldPlaceholder => 'Bold text';

  @override
  String get toolbar_codePlaceholder => 'Type or paste code here';

  @override
  String get toolbar_gridMinImages => 'Need at least 2 images to create grid';

  @override
  String get toolbar_gridNeedConsecutive =>
      'Need at least 2 consecutive images';

  @override
  String get toolbar_h1 => 'H1 - Heading 1';

  @override
  String get toolbar_h2 => 'H2 - Heading 2';

  @override
  String get toolbar_h3 => 'H3 - Heading 3';

  @override
  String get toolbar_h4 => 'H4 - Heading 4';

  @override
  String get toolbar_h5 => 'H5 - Heading 5';

  @override
  String get toolbar_imageGridTooltip => 'Image grid';

  @override
  String get toolbar_imagesAlreadyInGrid =>
      'These images are already in a grid';

  @override
  String get toolbar_italicPlaceholder => 'Italic text';

  @override
  String get toolbar_mixOptimize => 'CJK spacing';

  @override
  String get toolbar_quotePlaceholder => 'Quote text';

  @override
  String get toolbar_spoilerPlaceholder => 'Spoiler content';

  @override
  String get toolbar_spoilerTooltip => 'Spoiler';

  @override
  String get toolbar_strikethroughPlaceholder => 'Strikethrough text';

  @override
  String get emoji_activities => 'Activities';

  @override
  String get emoji_animals => 'Animals';

  @override
  String get emoji_flags => 'Flags';

  @override
  String get emoji_food => 'Food';

  @override
  String get emoji_loadFailed => 'Failed to load emoji';

  @override
  String get emoji_notFound => 'No emoji found';

  @override
  String get emoji_objects => 'Objects';

  @override
  String get emoji_people => 'People';

  @override
  String get emoji_searchHint => 'Search emoji...';

  @override
  String get emoji_searchNotFound => 'No matching emoji';

  @override
  String get emoji_searchPrompt => 'Enter keywords to search';

  @override
  String get emoji_searchTooltip => 'Search emoji';

  @override
  String get emoji_smileys => 'Smileys';

  @override
  String get emoji_symbols => 'Symbols';

  @override
  String get emoji_tab => 'Emoji';

  @override
  String get emoji_travel => 'Travel';

  @override
  String get sticker_addFromMarket => 'Add from market';

  @override
  String get sticker_addTooltip => 'Add stickers';

  @override
  String get sticker_added => 'Added';

  @override
  String sticker_emojiCount(int count) {
    return '$count emoji';
  }

  @override
  String get sticker_groupEmpty => 'No stickers in this group';

  @override
  String get sticker_loadFailed => 'Failed to load stickers';

  @override
  String get sticker_marketEmpty => 'No stickers available';

  @override
  String get sticker_marketLoadFailed => 'Failed to load market';

  @override
  String get sticker_marketTitle => 'Sticker market';

  @override
  String get sticker_noStickers => 'No stickers yet';

  @override
  String get sticker_tab => 'Stickers';

  @override
  String get error_addBookmarkFailed =>
      'Failed to add bookmark: unexpected response';

  @override
  String get error_avifDecodeNoFrames => 'AVIF decode failed: no frame data';

  @override
  String get error_badRequest => 'Bad request';

  @override
  String get error_badRequestParams => 'Invalid request parameters';

  @override
  String get error_cannotConnectCheckNetwork =>
      'Cannot connect to server, please check network';

  @override
  String get error_certificateError => 'Certificate error';

  @override
  String get error_certificateVerifyFailed =>
      'Certificate verification failed, please check network';

  @override
  String get error_connectionTimeout => 'Connection timeout';

  @override
  String get error_contentDeleted => 'Content has been deleted';

  @override
  String get error_createTopicFailed => 'Failed to create topic';

  @override
  String get error_dataException => 'Data error';

  @override
  String get error_forbidden => 'Access denied';

  @override
  String get error_forbiddenAccess => 'No permission to access';

  @override
  String get error_gone => 'Deleted';

  @override
  String get error_imageFormatUnsupported => 'Image format not supported';

  @override
  String get error_imageTooBig => 'Image too large, please compress and retry';

  @override
  String get error_internalServerError => 'Internal server error';

  @override
  String get error_loadFailed => 'Failed to load';

  @override
  String get error_networkCheckSettings =>
      'Network connection failed, please check settings';

  @override
  String get error_networkRequestFailed => 'Network request failed';

  @override
  String get error_networkUnavailable => 'Network unavailable';

  @override
  String get error_notFound => 'Not found';

  @override
  String get error_notFoundOrDeleted => 'Content not found or deleted';

  @override
  String get error_notLoggedInNoUsername =>
      'Not logged in or cannot get username';

  @override
  String get error_providerDisposed => 'Provider disposed';

  @override
  String get error_rateLimited => 'Too many requests';

  @override
  String get error_rateLimitedRetryLater =>
      'Too many requests, please try later';

  @override
  String get error_replyFailed => 'Reply failed';

  @override
  String get error_requestCancelled => 'Request cancelled';

  @override
  String get error_requestCancelledMsg => 'Request has been cancelled';

  @override
  String get error_requestFailed => 'Request failed';

  @override
  String error_requestFailedWithCode(int statusCode) {
    return 'Request failed ($statusCode)';
  }

  @override
  String get error_requestTimeoutRetry => 'Request timed out, please retry';

  @override
  String get error_requestUnprocessable => 'Request cannot be processed';

  @override
  String get error_responseTimeout => 'Response timeout';

  @override
  String get error_securityChallenge => 'Security challenge';

  @override
  String get error_sendPMFailed => 'Failed to send private message';

  @override
  String get error_serverError => 'Server error';

  @override
  String get error_serverResponseTooLong =>
      'Server response too slow, please retry';

  @override
  String get error_serverUnavailable => 'Server unavailable';

  @override
  String get error_serviceUnavailable => 'Server unavailable';

  @override
  String get error_serviceUnavailableRetry =>
      'Server temporarily unavailable, please retry';

  @override
  String get error_tooManyRequests => 'Too many requests';

  @override
  String get error_topicDetailEmpty => 'Topic detail is empty';

  @override
  String get error_unauthorized => 'Not logged in';

  @override
  String get error_unauthorizedExpired => 'Not logged in or session expired';

  @override
  String get error_unknown => 'Unknown error';

  @override
  String get error_unknownResponseFormat => 'Unknown response format';

  @override
  String get error_unprocessable => 'Unprocessable';

  @override
  String get error_unrecognizedDataFormat =>
      'Unrecognized data format from server';

  @override
  String get error_updatePostFailed =>
      'Failed to update post: unexpected response';

  @override
  String get error_uploadNoUrl => 'Upload response missing URL';

  @override
  String get browsingHistory_empty => 'No browsing history';

  @override
  String get browsingHistory_emptySearchHint =>
      'Enter keywords to search history';

  @override
  String get browsingHistory_searchHint => 'Search browsing history...';

  @override
  String get browsingHistory_title => 'Browsing History';

  @override
  String get myTopics_empty => 'No topics';

  @override
  String get myTopics_emptySearchHint => 'Enter keywords to search my topics';

  @override
  String get myTopics_searchHint => 'Search my topics...';

  @override
  String get myTopics_title => 'My Topics';

  @override
  String get imageEditor_adjust => 'Adjust';

  @override
  String get imageEditor_applyingChanges => 'Applying changes';

  @override
  String get imageEditor_arrow => 'Arrow';

  @override
  String get imageEditor_arrowBoth => 'Double arrow';

  @override
  String get imageEditor_arrowEnd => 'Arrow end';

  @override
  String get imageEditor_arrowStart => 'Arrow start';

  @override
  String get imageEditor_bgMode => 'Background mode';

  @override
  String get imageEditor_blur => 'Blur';

  @override
  String get imageEditor_brightness => 'Brightness';

  @override
  String get imageEditor_brush => 'Brush';

  @override
  String get imageEditor_changeOpacity => 'Change opacity';

  @override
  String get imageEditor_circle => 'Circle';

  @override
  String get imageEditor_closeWarningMessage =>
      'Close the image editor? Your changes will not be saved.';

  @override
  String get imageEditor_closeWarningTitle => 'Close image editor?';

  @override
  String get imageEditor_color => 'Color';

  @override
  String get imageEditor_contrast => 'Contrast';

  @override
  String get imageEditor_cropRotate => 'Crop/Rotate';

  @override
  String get imageEditor_dashDotLine => 'Dash dot line';

  @override
  String get imageEditor_dashLine => 'Dash line';

  @override
  String get imageEditor_emoji => 'Emoji';

  @override
  String get imageEditor_emojiActivities => 'Activities';

  @override
  String get imageEditor_emojiAnimals => 'Animals & Nature';

  @override
  String get imageEditor_emojiFlags => 'Flags';

  @override
  String get imageEditor_emojiFood => 'Food & Drink';

  @override
  String get imageEditor_emojiObjects => 'Objects';

  @override
  String get imageEditor_emojiSmileys => 'Smileys & People';

  @override
  String get imageEditor_emojiSymbols => 'Symbols';

  @override
  String get imageEditor_emojiTravel => 'Travel & Places';

  @override
  String get imageEditor_eraser => 'Eraser';

  @override
  String get imageEditor_exposure => 'Exposure';

  @override
  String get imageEditor_fade => 'Fade';

  @override
  String get imageEditor_fill => 'Fill';

  @override
  String get imageEditor_filter => 'Filter';

  @override
  String get imageEditor_flip => 'Flip';

  @override
  String get imageEditor_fontSize => 'Font size';

  @override
  String get imageEditor_freeStyle => 'Free draw';

  @override
  String get imageEditor_hexagon => 'Hexagon';

  @override
  String get imageEditor_hue => 'Hue';

  @override
  String get imageEditor_initializingEditor => 'Initializing editor';

  @override
  String get imageEditor_inputText => 'Enter text';

  @override
  String get imageEditor_line => 'Line';

  @override
  String get imageEditor_lineWidth => 'Line width';

  @override
  String get imageEditor_luminance => 'Luminance';

  @override
  String get imageEditor_noFilter => 'No filter';

  @override
  String get imageEditor_opacity => 'Opacity';

  @override
  String get imageEditor_pixelate => 'Pixelate';

  @override
  String get imageEditor_polygon => 'Polygon';

  @override
  String get imageEditor_ratio => 'Ratio';

  @override
  String get imageEditor_rectangle => 'Rectangle';

  @override
  String get imageEditor_rotate => 'Rotate';

  @override
  String get imageEditor_rotateScale => 'Rotate & Scale';

  @override
  String get imageEditor_saturation => 'Saturation';

  @override
  String get imageEditor_sharpness => 'Sharpness';

  @override
  String get imageEditor_sticker => 'Sticker';

  @override
  String get imageEditor_strokeWidth => 'Stroke width';

  @override
  String get imageEditor_temperature => 'Temperature';

  @override
  String get imageEditor_text => 'Text';

  @override
  String get imageEditor_textAlign => 'Text align';

  @override
  String get imageEditor_toggleFill => 'Toggle fill';

  @override
  String get imageEditor_zoom => 'Zoom';

  @override
  String get imageFormat_generic => 'Image';

  @override
  String get imageFormat_gif => 'GIF';

  @override
  String get imageFormat_jpeg => 'JPEG';

  @override
  String get imageFormat_png => 'PNG';

  @override
  String get imageFormat_webp => 'WebP';

  @override
  String get imageUpload_compressionQuality => 'Compression quality:';

  @override
  String get imageUpload_confirmTitle => 'Upload image';

  @override
  String get imageUpload_editImage => 'Edit image';

  @override
  String imageUpload_editNotSupported(String format) {
    return '$format does not support editing to preserve animation';
  }

  @override
  String get imageUpload_editNotSupportedLabel =>
      'Current format does not support editing';

  @override
  String imageUpload_estimatedSize(String size) {
    return '~$size';
  }

  @override
  String get imageUpload_gridLayoutHint =>
      'Will use [grid] layout after upload';

  @override
  String get imageUpload_keepAtLeastOne => 'Keep at least one image';

  @override
  String imageUpload_keepOriginal(String format) {
    return '$format will be uploaded as-is without compression.';
  }

  @override
  String imageUpload_multiTitle(int count) {
    return 'Upload $count images';
  }

  @override
  String imageUpload_originalSize(String size) {
    return 'Original size: $size';
  }

  @override
  String imageUpload_processFailed(String error) {
    return 'Failed to process image: $error';
  }

  @override
  String imageUpload_totalEstimatedSize(String size) {
    return '~$size';
  }

  @override
  String imageUpload_totalOriginalSize(String size) {
    return 'Total size: $size';
  }

  @override
  String imageUpload_uploadCount(int count) {
    return 'Upload $count';
  }

  @override
  String get imageViewer_grantPermission => 'Please grant gallery permission';

  @override
  String get imageViewer_imageSaved => 'Image saved to gallery';

  @override
  String imageViewer_saveFailed(String error) {
    return 'Save failed: $error';
  }

  @override
  String get imageViewer_saveFailedRetry => 'Save failed, please retry';

  @override
  String get image_copied => 'Image copied';

  @override
  String get image_copyFailed => 'Failed to copy image';

  @override
  String get image_copyImage => 'Copy image';

  @override
  String get image_copyLink => 'Copy link';

  @override
  String get image_fetchFailed => 'Failed to fetch image';

  @override
  String get image_viewFull => 'View full image';

  @override
  String get invite_collapseOptions => 'Collapse link options';

  @override
  String get invite_createFailed => 'Failed to create invite link';

  @override
  String get invite_createLink => 'Create invite link';

  @override
  String get invite_created => 'Invite created';

  @override
  String get invite_creating => 'Creating...';

  @override
  String get invite_description => 'Description (optional)';

  @override
  String get invite_expandOptions => 'Edit link options or send via email.';

  @override
  String invite_expiryDate(String date) {
    return 'Expires $date';
  }

  @override
  String get invite_expiryTime => 'Expiry time';

  @override
  String get invite_fixed => 'Fixed';

  @override
  String get invite_inviteMembers => 'Invite members';

  @override
  String get invite_latestResult => 'Latest result';

  @override
  String get invite_linkCopied => 'Invite link copied';

  @override
  String get invite_linkGenerated => 'Invite link generated';

  @override
  String get invite_maxRedemptions => 'Max redemptions';

  @override
  String get invite_never => 'Never';

  @override
  String get invite_noExpiry => 'No expiry';

  @override
  String get invite_noLinks => 'No invite links generated';

  @override
  String get invite_permissionDenied =>
      'Server denied invite permission for this account';

  @override
  String invite_rateLimited(String waitText) {
    return 'Too many attempts. Please wait $waitText before trying again.';
  }

  @override
  String get invite_restriction => 'Restrict to (optional)';

  @override
  String get invite_restrictionHelper => 'Enter email or domain';

  @override
  String get invite_restrictionHint => 'name@example.com or example.com';

  @override
  String get invite_shareSubject => 'Linux.do Invite Link';

  @override
  String get invite_summaryDay1 =>
      'Link can be used by 1 user and will expire in 1 day.';

  @override
  String invite_summaryExpiry(String expiry) {
    return 'Link can be used by 1 user and will expire in $expiry.';
  }

  @override
  String get invite_summaryNever =>
      'Link can be used by 1 user and will never expire.';

  @override
  String get invite_title => 'Invite Links';

  @override
  String get invite_trustLevelTooLow =>
      'Account has not reached L3, cannot create invite links';

  @override
  String invite_usableCount(int count) {
    return 'Usable $count times';
  }

  @override
  String get appLink_alipay => 'Alipay';

  @override
  String get appLink_amap => 'Amap';

  @override
  String get appLink_baidu => 'Baidu';

  @override
  String get appLink_baiduNetdisk => 'Baidu Netdisk';

  @override
  String appLink_continueVisitConfirm(String name) {
    return 'Continue to $name?';
  }

  @override
  String get appLink_ctrip => 'Ctrip';

  @override
  String get appLink_dianping => 'Dianping';

  @override
  String get appLink_dingtalk => 'DingTalk';

  @override
  String get appLink_douban => 'Douban';

  @override
  String get appLink_douyin => 'Douyin';

  @override
  String get appLink_eleme => 'Eleme';

  @override
  String get appLink_email => 'Email';

  @override
  String get appLink_externalApp => 'External app';

  @override
  String get appLink_fliggy => 'Fliggy';

  @override
  String get appLink_jd => 'JD.com';

  @override
  String get appLink_kuaishou => 'Kuaishou';

  @override
  String get appLink_map => 'Map';

  @override
  String get appLink_meituan => 'Meituan';

  @override
  String get appLink_meituanWaimai => 'Meituan Waimai';

  @override
  String appLink_openAppConfirm(String name) {
    return 'This site wants to open $name';
  }

  @override
  String get appLink_phone => 'Phone';

  @override
  String get appLink_pinduoduo => 'Pinduoduo';

  @override
  String get appLink_playStore => 'Play Store';

  @override
  String get appLink_qqMap => 'Tencent Maps';

  @override
  String get appLink_sms => 'SMS';

  @override
  String get appLink_suning => 'Suning';

  @override
  String get appLink_taobao => 'Taobao';

  @override
  String get appLink_toutiao => 'Toutiao';

  @override
  String get appLink_weibo => 'Weibo';

  @override
  String get appLink_weixin => 'WeChat';

  @override
  String get appLink_xiaohongshu => 'Xiaohongshu';

  @override
  String get appLink_zhihu => 'Zhihu';

  @override
  String get externalLink_blocked => 'Link blocked';

  @override
  String get externalLink_blockedMessage => 'This link has been blacklisted';

  @override
  String get externalLink_contactAdmin =>
      'Contact site admin if you have questions';

  @override
  String get externalLink_leavingMessage =>
      'You are about to visit an external website';

  @override
  String get externalLink_leavingTitle => 'Leaving';

  @override
  String get externalLink_securityWarningHint =>
      'May contain promotional content or security risks';

  @override
  String get externalLink_securityWarningMessage =>
      'This link has been flagged as potentially risky';

  @override
  String get externalLink_securityWarningTitle => 'Security warning';

  @override
  String get externalLink_shortLinkMessage =>
      'This is a short link, the real destination cannot be previewed';

  @override
  String get externalLink_shortLinkTitle => 'Short link notice';

  @override
  String get externalLink_shortLinkWarning =>
      'Short links may hide the real destination, verify the source';

  @override
  String get iframe_exitInteraction => 'Exit interaction';

  @override
  String get onebox_linkPreview => 'Link preview';

  @override
  String get chat_thread => 'Thread';

  @override
  String get github_commentedOn => ' commented on ';

  @override
  String github_moreFiles(int count) {
    return '... and $count more files';
  }

  @override
  String get github_viewFullCode => 'View full code';

  @override
  String metaverse_authFailed(String error) {
    return 'Authorization failed: $error';
  }

  @override
  String get metaverse_cdkAuthSuccess => 'CDK authorization successful';

  @override
  String get metaverse_cdkDesc => 'Connect account to access CDK';

  @override
  String get metaverse_cdkReauthSuccess => 'CDK re-authorization successful';

  @override
  String get metaverse_cdkService => 'CDK Service';

  @override
  String get metaverse_comingSoon => 'More services coming soon...';

  @override
  String get metaverse_ldcAuthSuccess => 'LDC authorization successful';

  @override
  String get metaverse_ldcDesc => 'Connect account to access points';

  @override
  String get metaverse_ldcReauthSuccess => 'LDC re-authorization successful';

  @override
  String get metaverse_ldcService => 'LDC Points Service';

  @override
  String get metaverse_myServices => 'My Services';

  @override
  String get metaverse_title => 'Metaverse';

  @override
  String get nav_home => 'Home';

  @override
  String get nav_mine => 'Me';

  @override
  String toast_authorizationFailed(String error) {
    return 'Authorization failed: $error';
  }

  @override
  String get toast_credentialCleared => 'Credentials cleared';

  @override
  String get toast_credentialIncomplete =>
      'Please fill in all credential fields';

  @override
  String get toast_credentialSaved => 'Credentials saved';

  @override
  String get toast_networkDisconnected => 'Network disconnected';

  @override
  String get toast_networkRestored => 'Network restored';

  @override
  String get toast_operationFailedRetry => 'Operation failed, please retry';

  @override
  String get toast_pressAgainToExit => 'Press back again to exit';

  @override
  String toast_rewardError(String error) {
    return 'Tip failed: $error';
  }

  @override
  String get toast_rewardFailed => 'Tip failed';

  @override
  String get toast_rewardNotConfigured =>
      'Please configure tip credentials first';

  @override
  String get toast_rewardSuccess => 'Tip sent successfully!';

  @override
  String get advancedSettings_networkAdapter => 'Network Adapter';

  @override
  String get advancedSettings_networkAdapterDesc =>
      'Manage Cronet and fallback adapter settings';

  @override
  String get networkAdapter_adapterType => 'Adapter type';

  @override
  String get networkAdapter_autoFallback => 'Auto fallback';

  @override
  String get networkAdapter_autoFallbackDesc =>
      'Cronet unavailable, switched to fallback adapter';

  @override
  String get networkAdapter_controlOptions => 'Control options';

  @override
  String get networkAdapter_currentStatus => 'Current status';

  @override
  String get networkAdapter_degradeReason => 'Cronet fallback reason';

  @override
  String get networkAdapter_devTest => 'Developer testing';

  @override
  String get networkAdapter_fallback => 'Fallback';

  @override
  String get networkAdapter_fallbackStatus => 'Fallback status';

  @override
  String get networkAdapter_forceFallback => 'Force fallback adapter';

  @override
  String get networkAdapter_forceFallbackDesc =>
      'Disable Cronet, use NetworkHttpAdapter';

  @override
  String get networkAdapter_native => 'Native';

  @override
  String get networkAdapter_resetFallback => 'Reset fallback';

  @override
  String get networkAdapter_resetFallbackDesc =>
      'Clear fallback record, retry Cronet on next launch';

  @override
  String get networkAdapter_resetSuccess => 'Reset done, restart to apply';

  @override
  String get networkAdapter_settingSaved => 'Setting saved, restart to apply';

  @override
  String get networkAdapter_simulateError => 'Simulate Cronet error';

  @override
  String get networkAdapter_simulateErrorDesc =>
      'Trigger fallback process for testing';

  @override
  String get networkAdapter_simulateSuccess =>
      'Simulated fallback triggered, check status';

  @override
  String get networkAdapter_title => 'Network Adapter';

  @override
  String get networkAdapter_viewReason => 'View reason';

  @override
  String get networkSettings_advanced => 'Advanced';

  @override
  String get networkSettings_auxiliary => 'Auxiliary';

  @override
  String get networkSettings_debug => 'Debug';

  @override
  String get networkSettings_engine => 'Network Engine';

  @override
  String get networkSettings_maxConcurrent => 'Max concurrent requests';

  @override
  String get networkSettings_maxPerWindow => 'Requests per window';

  @override
  String get networkSettings_proxy => 'Network Proxy';

  @override
  String get networkSettings_title => 'Network Settings';

  @override
  String get networkSettings_windowSeconds => 'Window duration';

  @override
  String get networkSettings_windowSecondsSuffix => 's';

  @override
  String get network_adapterNativeAndroid => 'Cronet adapter';

  @override
  String get network_adapterNativeIos => 'Cupertino adapter';

  @override
  String get network_adapterNetwork => 'Network adapter';

  @override
  String get network_adapterRhttp => 'rhttp engine';

  @override
  String get network_adapterWebView => 'WebView adapter';

  @override
  String get network_badRequest => 'Invalid request parameters';

  @override
  String get network_forbidden => 'No permission for this action';

  @override
  String get network_internalError => 'Internal server error';

  @override
  String get network_notFound => 'Resource not found';

  @override
  String get network_postPendingReview => 'Your post is pending review';

  @override
  String get network_rateLimited => 'Too many requests, please try later';

  @override
  String network_rateLimitedWait(String duration) {
    return 'Too many requests, please wait $duration';
  }

  @override
  String network_requestFailed(int statusCode) {
    return 'Request failed ($statusCode)';
  }

  @override
  String network_serverUnavailable(int statusCode) {
    return 'Server temporarily unavailable ($statusCode)';
  }

  @override
  String get network_serverUnavailableRetry =>
      'Server temporarily unavailable, please retry';

  @override
  String get network_unauthorized => 'Not logged in or session expired';

  @override
  String get network_unprocessable => 'Request cannot be processed';

  @override
  String get rhttpEngine_alwaysUse => 'Always';

  @override
  String rhttpEngine_currentAdapter(String adapter) {
    return 'Current: $adapter';
  }

  @override
  String get rhttpEngine_disabledDesc => 'Enable to use Rust network engine';

  @override
  String get rhttpEngine_echFallbackHint =>
      'When ECH is on, WebView still falls back to local proxy; rhttp direct connection tries its own ECH first';

  @override
  String get rhttpEngine_enabledDesc => 'HTTP/2 Multiplexing · Rust reqwest';

  @override
  String get rhttpEngine_proxyDohOnly => 'Proxy/DOH Only';

  @override
  String get rhttpEngine_title => 'rhttp Engine';

  @override
  String get rhttpEngine_useMode => 'Usage Mode';

  @override
  String get webviewAdapter_disabledDesc =>
      'Use browser engine for requests, may improve login stability';

  @override
  String get webviewAdapter_enabledDesc =>
      'Main site API requests sent via browser engine';

  @override
  String get webviewAdapter_hint =>
      'Only main site API requests go through WebView; images and push notifications are not affected';

  @override
  String get webviewAdapter_title => 'WebView Network Engine';

  @override
  String get notification_adminNewSuggestions =>
      'New suggestions in site dashboard';

  @override
  String get notification_assignedTopic => 'Topic assigned to you';

  @override
  String get notification_backgroundRunning =>
      'Running in background for notifications';

  @override
  String notification_boost(String username) {
    return '$username boosted your post';
  }

  @override
  String notification_boostWithContent(String username, String content) {
    return '$username: $content';
  }

  @override
  String notification_boostByMany(String username, int count) {
    return '$username and $count others boosted your post';
  }

  @override
  String get notification_bookmarkReminder => 'Bookmark reminder';

  @override
  String get notification_channelBackground => 'Background';

  @override
  String get notification_channelBackgroundDesc =>
      'Keep FluxDO receiving notifications in background';

  @override
  String get notification_channelDiscourse => 'Discourse Notifications';

  @override
  String get notification_channelDiscourseDesc =>
      'Notifications from Discourse forum';

  @override
  String get notification_chatGroupMention => 'Group mentioned in chat';

  @override
  String notification_chatInvitation(String username) {
    return '$username invited you to chat';
  }

  @override
  String notification_chatMention(String username) {
    return '$username mentioned you in chat';
  }

  @override
  String notification_chatMessage(String username) {
    return '$username sent a chat message';
  }

  @override
  String notification_chatQuotedPost(String username) {
    return '$username quoted you in chat';
  }

  @override
  String get notification_chatWatchedThread =>
      'New messages in watched chat thread';

  @override
  String get notification_circlesActivity => 'New activity in circles';

  @override
  String get notification_codeReviewApproved => 'Code review approved';

  @override
  String notification_createdNewTopic(String username) {
    return '$username created a new topic';
  }

  @override
  String get notification_custom => 'Custom notification';

  @override
  String notification_editedPost(String username) {
    return '$username edited the post';
  }

  @override
  String get notification_empty => 'No notifications';

  @override
  String notification_eventInvitation(String username) {
    return '$username invited you to an event';
  }

  @override
  String get notification_eventReminder => 'Event reminder';

  @override
  String notification_followingYou(String displayName) {
    return '$displayName started following you';
  }

  @override
  String notification_grantedBadge(String badgeName) {
    return 'Earned \'$badgeName\'';
  }

  @override
  String notification_groupMessageSummary(String groupName, int count) {
    return '$groupName inbox has $count messages';
  }

  @override
  String notification_invitedToPM(String username) {
    return '$username invited you to a PM';
  }

  @override
  String notification_invitedToTopic(String username) {
    return '$username invited you to a topic';
  }

  @override
  String notification_inviteeAccepted(String displayName) {
    return '$displayName accepted your invitation';
  }

  @override
  String notification_liked(String username) {
    return '$username liked your post';
  }

  @override
  String notification_likedByMany(String username, int count) {
    return '$username and $count others liked your post';
  }

  @override
  String notification_likedByTwo(String username, String username2) {
    return '$username and $username2 liked your post';
  }

  @override
  String notification_likedMultiplePosts(String displayName, int count) {
    return '$displayName liked $count of your posts';
  }

  @override
  String notification_linkedMultiplePosts(String displayName, int count) {
    return '$displayName linked $count of your posts';
  }

  @override
  String notification_linkedPost(String username) {
    return '$username linked your post';
  }

  @override
  String get notification_markAllRead => 'Mark all as read';

  @override
  String notification_membershipAccepted(String groupName) {
    return 'Your request to join \'$groupName\' was accepted';
  }

  @override
  String notification_membershipPending(int count, String groupName) {
    return '$count pending \'$groupName\' membership requests';
  }

  @override
  String notification_mentioned(String username) {
    return '$username mentioned you in a post';
  }

  @override
  String notification_movedPost(String username) {
    return '$username moved the post';
  }

  @override
  String get notification_newFeaturesAvailable => 'New features available!';

  @override
  String get notification_newNotification => 'New notification';

  @override
  String notification_newPostPublished(String username) {
    return '$username published a new post';
  }

  @override
  String get notification_newTopic => 'New topic';

  @override
  String notification_peopleLikedPost(int count) {
    return '$count people liked your post';
  }

  @override
  String notification_peopleLinkedPost(int count) {
    return '$count people linked your post';
  }

  @override
  String get notification_postApproved => 'Your post has been approved';

  @override
  String notification_privateMsgSent(String username) {
    return '$username sent a private message';
  }

  @override
  String notification_qaCommented(String username) {
    return '$username commented on Q&A';
  }

  @override
  String notification_quoted(String username) {
    return '$username quoted your post';
  }

  @override
  String notification_reaction(String username) {
    return '$username reacted to your post';
  }

  @override
  String notification_replied(String username) {
    return '$username replied to your post';
  }

  @override
  String notification_repliedTopic(String username) {
    return '$username replied to the topic';
  }

  @override
  String get notification_topicReminder => 'Topic reminder';

  @override
  String get notification_typeAdminProblems => 'Admin problems';

  @override
  String get notification_typeAssignedTopic => 'Topic assigned';

  @override
  String get notification_typeBoost => 'Boost';

  @override
  String get notification_typeBookmarkReminder => 'Bookmark reminder';

  @override
  String get notification_typeChatGroupMention => 'Group chat mention';

  @override
  String get notification_typeChatInvitation => 'Chat invitation';

  @override
  String get notification_typeChatMention => 'Chat mention';

  @override
  String get notification_typeChatMessage => 'Chat message';

  @override
  String get notification_typeChatQuotedPost => 'Chat quoted';

  @override
  String get notification_typeChatWatchedThread => 'Chat watched thread';

  @override
  String get notification_typeCirclesActivity => 'Circles activity';

  @override
  String get notification_typeCodeReviewApproved => 'Code review approved';

  @override
  String get notification_typeCustom => 'Custom';

  @override
  String get notification_typeEdited => 'Edited';

  @override
  String get notification_typeEventInvitation => 'Event invitation';

  @override
  String get notification_typeEventReminder => 'Event reminder';

  @override
  String get notification_typeFollowing => 'Following';

  @override
  String get notification_typeFollowingCreatedTopic =>
      'Following created topic';

  @override
  String get notification_typeFollowingReplied => 'Following replied';

  @override
  String get notification_typeGrantedBadge => 'Badge granted';

  @override
  String get notification_typeGroupMentioned => 'Group mentioned';

  @override
  String get notification_typeGroupMessageSummary => 'Group message summary';

  @override
  String get notification_typeInvitedToPM => 'PM invitation';

  @override
  String get notification_typeInvitedToTopic => 'Topic invitation';

  @override
  String get notification_typeInviteeAccepted => 'Invitation accepted';

  @override
  String get notification_typeLiked => 'Liked';

  @override
  String get notification_typeLikedConsolidated => 'Likes consolidated';

  @override
  String get notification_typeLinked => 'Linked';

  @override
  String get notification_typeLinkedConsolidated => 'Links consolidated';

  @override
  String get notification_typeMembershipAccepted => 'Membership accepted';

  @override
  String get notification_typeMembershipConsolidated =>
      'Membership consolidated';

  @override
  String get notification_typeMentioned => 'Mentioned';

  @override
  String get notification_typeMovedPost => 'Post moved';

  @override
  String get notification_typeNewFeatures => 'New features';

  @override
  String get notification_typePostApproved => 'Post approved';

  @override
  String get notification_typePosted => 'Posted';

  @override
  String get notification_typePrivateMessage => 'Private message';

  @override
  String get notification_typeQACommented => 'Q&A comment';

  @override
  String get notification_typeQuoted => 'Quoted';

  @override
  String get notification_typeReaction => 'Reaction';

  @override
  String get notification_typeReplied => 'Replied';

  @override
  String get notification_typeTopicReminder => 'Topic reminder';

  @override
  String get notification_typeUnknown => 'Unknown';

  @override
  String get notification_typeVotesReleased => 'Votes released';

  @override
  String get notification_typeWatchingCategoryOrTag => 'Watching category/tag';

  @override
  String get notification_typeWatchingFirstPost => 'Watching first post';

  @override
  String get notification_votesReleased => 'Votes released';

  @override
  String notification_watchingCategoryNewPost(String username) {
    return '$username published a new post';
  }

  @override
  String get notifications_empty => 'No notifications';

  @override
  String get notifications_markAllRead => 'Mark all as read';

  @override
  String get notifications_title => 'Notifications';

  @override
  String get boost_created => 'Boost sent';

  @override
  String get boost_deleteConfirm =>
      'Are you sure you want to delete this boost?';

  @override
  String get boost_deleteFailed => 'Failed to delete boost';

  @override
  String get boost_deleted => 'Boost deleted';

  @override
  String get boost_failed => 'Failed to send boost';

  @override
  String get boost_flagSubmitted => 'Flag submitted';

  @override
  String get boost_flagTitle => 'Flag Boost';

  @override
  String get boost_limitReached => 'Boost limit reached for this post';

  @override
  String get boost_placeholder => 'Say something...';

  @override
  String get boost_send => 'Send';

  @override
  String boost_tooLong(int count) {
    return 'Content too long, max $count characters';
  }

  @override
  String get nested_flatView => 'Switch to flat view';

  @override
  String get nested_loadMore => 'Load more';

  @override
  String get nested_loadMoreReplies => 'Load more replies';

  @override
  String nested_repliesCount(int count) {
    return '$count replies';
  }

  @override
  String get nested_sortNew => 'New';

  @override
  String get nested_sortOld => 'Old';

  @override
  String get nested_sortTop => 'Top';

  @override
  String get nested_title => 'Threaded View';

  @override
  String get poll_closed => 'Closed';

  @override
  String get poll_count => 'Count';

  @override
  String get poll_percentage => 'Percentage';

  @override
  String get poll_undo => 'Undo';

  @override
  String get poll_viewResults => 'View results';

  @override
  String get poll_vote => 'Vote';

  @override
  String poll_voters(int count) {
    return '$count voters';
  }

  @override
  String get post_acceptSolution => 'Accept as solution';

  @override
  String get post_collapseReplies => 'Collapse replies';

  @override
  String get post_contentRequired => 'Please enter content';

  @override
  String get post_deleteReplyConfirm =>
      'Delete this reply? This can be undone.';

  @override
  String get post_deleteReplyTitle => 'Delete reply';

  @override
  String get post_detail => 'Post Detail';

  @override
  String get post_discardConfirm => 'Discard your post?';

  @override
  String get post_discardTitle => 'Discard post';

  @override
  String post_editPostTitle(int postNumber) {
    return 'Edit post #$postNumber';
  }

  @override
  String post_firstPostNotice(String username) {
    return 'This is $username\'s first post — let\'s welcome them to the community!';
  }

  @override
  String get post_flagDescriptionHint => 'Describe the issue...';

  @override
  String get post_flagFailed => 'Report failed, please retry';

  @override
  String post_flagMessageUser(String username) {
    return 'Message @$username';
  }

  @override
  String get post_flagNotifyModerators => 'Notify moderators privately';

  @override
  String get post_flagSubmitted => 'Report submitted';

  @override
  String get post_flagTitle => 'Report post';

  @override
  String get post_generateShareImage => 'Generate share image';

  @override
  String get post_lastReadHere => 'Last read here';

  @override
  String post_loadContentFailed(String error) {
    return 'Failed to load content: $error';
  }

  @override
  String get post_loadMoreReplies => 'Load more replies';

  @override
  String get post_longTimeAgo => 'A long time ago';

  @override
  String get post_meBadge => 'Me';

  @override
  String post_moreLinks(int count) {
    return '$count more';
  }

  @override
  String get post_noReactions => 'No reactions';

  @override
  String get post_opBadge => 'OP';

  @override
  String get post_pendingReview => 'Your post is pending review';

  @override
  String get post_reactions => 'Reactions';

  @override
  String get post_relatedLinks => 'Related links';

  @override
  String post_relatedRepliesCount(int count) {
    return '$count related replies';
  }

  @override
  String post_replyCount(int count) {
    return '$count replies';
  }

  @override
  String get post_replySent => 'Reply sent';

  @override
  String get post_replySentAction => 'View';

  @override
  String get post_replyTo => 'Reply to';

  @override
  String get post_replyToTopic => 'Reply to topic';

  @override
  String post_replyToUser(String username) {
    return 'Reply to @$username';
  }

  @override
  String post_returningUserNotice(String username, String timeText) {
    return 'Welcome back $username — their last post was $timeText.';
  }

  @override
  String post_sendPmTitle(String username) {
    return 'Send PM to @$username';
  }

  @override
  String get post_solutionAccepted => 'Accepted as solution';

  @override
  String get post_solutionUnaccepted => 'Solution unaccepted';

  @override
  String get post_solved => 'Solved';

  @override
  String get post_submitFlag => 'Submit report';

  @override
  String get post_tipLdc => 'Tip LDC';

  @override
  String get post_titleRequired => 'Please enter a title';

  @override
  String get post_topicSolved => 'This topic is solved';

  @override
  String get post_unacceptSolution => 'Unaccept solution';

  @override
  String get post_unsolved => 'Unsolved';

  @override
  String get post_viewBestAnswer => 'View best answer';

  @override
  String get post_viewHiddenInfo => 'View hidden info';

  @override
  String get post_whisperIndicator => 'Staff only';

  @override
  String get smallAction_archivedDisabled => 'Unarchived the topic';

  @override
  String get smallAction_archivedEnabled => 'Archived the topic';

  @override
  String get smallAction_autobumped => 'Auto-bumped';

  @override
  String get smallAction_autoclosedDisabled => 'Topic auto-opened';

  @override
  String get smallAction_autoclosedEnabled => 'Topic auto-closed';

  @override
  String get smallAction_bannerDisabled => 'Removed banner';

  @override
  String get smallAction_bannerEnabled => 'Made banner topic';

  @override
  String get smallAction_categoryChanged => 'Category updated';

  @override
  String get smallAction_closedDisabled => 'Opened the topic';

  @override
  String get smallAction_closedEnabled => 'Closed the topic';

  @override
  String get smallAction_forwarded => 'Forwarded email';

  @override
  String get smallAction_invitedGroup => 'Invited';

  @override
  String get smallAction_invitedUser => 'Invited';

  @override
  String get smallAction_openTopic => 'Converted to topic';

  @override
  String get smallAction_pinnedDisabled => 'Unpinned the topic';

  @override
  String get smallAction_pinnedEnabled => 'Pinned the topic';

  @override
  String get smallAction_pinnedGloballyDisabled => 'Globally unpinned';

  @override
  String get smallAction_pinnedGloballyEnabled => 'Globally pinned';

  @override
  String get smallAction_privateTopic => 'Converted to PM';

  @override
  String get smallAction_publicTopic => 'Made public topic';

  @override
  String get smallAction_removedGroup => 'Removed';

  @override
  String get smallAction_removedUser => 'Removed';

  @override
  String get smallAction_splitTopic => 'Split the topic';

  @override
  String get smallAction_tagsChanged => 'Tags updated';

  @override
  String get smallAction_userLeft => 'Left the conversation';

  @override
  String get smallAction_visibleDisabled => 'Made private';

  @override
  String get smallAction_visibleEnabled => 'Made public';

  @override
  String get vote_cancelled => 'Vote cancelled';

  @override
  String get vote_closed => 'Closed';

  @override
  String get vote_label => 'Vote';

  @override
  String get vote_pleaseLogin => 'Please log in first';

  @override
  String get vote_success => 'Vote successful';

  @override
  String get vote_successNoRemaining => 'Vote successful, no votes remaining';

  @override
  String vote_successRemaining(int remaining) {
    return 'Vote successful, $remaining votes remaining';
  }

  @override
  String get vote_topicClosed => 'Topic closed, cannot vote';

  @override
  String get vote_voted => 'Voted';

  @override
  String get preheat_logoutConfirm =>
      'Log out? This will clear local login data.';

  @override
  String get preheat_logoutMessage => 'User logged out (preload failure page)';

  @override
  String get preheat_networkSettings => 'Network settings';

  @override
  String get preheat_retryConnection => 'Retry connection';

  @override
  String get preheat_userSkipped => 'User skipped preload';

  @override
  String table_rowCount(int count) {
    return '$count rows';
  }

  @override
  String get httpProxy_auth => 'Authentication';

  @override
  String get httpProxy_base64PskHint =>
      'Enter Base64-encoded 32-byte pre-shared key';

  @override
  String get httpProxy_cipher => 'Cipher';

  @override
  String get httpProxy_cipherNotSet => 'Cipher not set';

  @override
  String get httpProxy_configTitle => 'Configure Upstream Proxy';

  @override
  String get httpProxy_disabledDesc =>
      'Configure remote HTTP / SOCKS5 / Shadowsocks proxy for local gateway';

  @override
  String get httpProxy_disabledHint =>
      'When enabled, keeps proxy mode switch, local gateway takes over Dio, WebView and Shadowsocks egress';

  @override
  String get httpProxy_dohProxyHint =>
      'Currently forwarded to upstream proxy via local DoH gateway; switches to pure proxy forwarding when DoH is off';

  @override
  String httpProxy_enabledDesc(String protocol) {
    return 'Enabled $protocol upstream proxy, forwarded by local gateway';
  }

  @override
  String get httpProxy_fillServerAndPort =>
      'Please fill in server address and port';

  @override
  String get httpProxy_importSsLink => 'Import ss:// link';

  @override
  String httpProxy_importedNode(String remarks) {
    return 'Imported node: $remarks';
  }

  @override
  String get httpProxy_keyBase64Psk => 'Key (Base64 PSK)';

  @override
  String get httpProxy_password => 'Password';

  @override
  String get httpProxy_port => 'Port';

  @override
  String get httpProxy_portHint => 'e.g. 8080 or 1080';

  @override
  String get httpProxy_portInvalid => 'Invalid port';

  @override
  String get httpProxy_protocol => 'Protocol';

  @override
  String get httpProxy_proxyAutoTest =>
      'Will auto-test after save, or test manually';

  @override
  String get httpProxy_requireAuth => 'Require Authentication';

  @override
  String get httpProxy_selectSsCipher =>
      'Please select a supported Shadowsocks cipher';

  @override
  String get httpProxy_server => 'Upstream Proxy Server';

  @override
  String get httpProxy_serverAddress => 'Server Address';

  @override
  String get httpProxy_serverAddressHint =>
      'e.g. 192.168.1.1 or proxy.example.com';

  @override
  String get httpProxy_ssConfigSaved =>
      'Will verify Shadowsocks config after save, recommend testing from home page';

  @override
  String get httpProxy_ssImportSuccess =>
      'Shadowsocks link imported successfully';

  @override
  String get httpProxy_ssLink => 'Shadowsocks Link';

  @override
  String get httpProxy_suppressedByVpn =>
      'Auto-disabled by VPN, will restore when VPN disconnects';

  @override
  String get httpProxy_testAvailability => 'Test Proxy Availability';

  @override
  String get httpProxy_testingProxy =>
      'Verifying access to linux.do via current proxy';

  @override
  String get httpProxy_testingSsConfig =>
      'Verifying Shadowsocks config can be managed by local gateway';

  @override
  String get httpProxy_title => 'Upstream Proxy';

  @override
  String httpProxy_username(String username) {
    return 'Username: $username';
  }

  @override
  String get httpProxy_usernameLabel => 'Username';

  @override
  String get proxy_cannotConnect => 'Cannot connect to proxy server';

  @override
  String get proxy_connectionClosed => 'Connection closed by remote';

  @override
  String get proxy_fillAddressPort => 'Please fill in proxy address and port';

  @override
  String get proxy_httpAuthFailed => 'HTTP proxy auth failed (407)';

  @override
  String proxy_httpConnectFailed(String statusLine) {
    return 'HTTP proxy CONNECT failed: $statusLine';
  }

  @override
  String get proxy_notConfigured => 'Proxy not configured';

  @override
  String get proxy_responseTimeout => 'Proxy response timeout';

  @override
  String get proxy_socks5AddrTypeNotSupported => 'Address type not supported';

  @override
  String get proxy_socks5AuthFailed => 'SOCKS5 auth failed';

  @override
  String get proxy_socks5AuthRejected => 'SOCKS5 auth method rejected';

  @override
  String get proxy_socks5CommandNotSupported => 'Command not supported';

  @override
  String proxy_socks5ConnectFailed(String reply) {
    return 'SOCKS5 CONNECT failed: $reply';
  }

  @override
  String get proxy_socks5ConnectInvalidVersion =>
      'SOCKS5 CONNECT invalid version';

  @override
  String get proxy_socks5ConnectionRefused => 'Connection refused';

  @override
  String get proxy_socks5CredentialsTooLong => 'SOCKS5 credentials too long';

  @override
  String get proxy_socks5GeneralFailure => 'General failure';

  @override
  String get proxy_socks5HostUnreachable => 'Host unreachable';

  @override
  String get proxy_socks5HostnameTooLong => 'SOCKS5 hostname too long';

  @override
  String get proxy_socks5InvalidVersion => 'SOCKS5 invalid response version';

  @override
  String get proxy_socks5NetworkUnreachable => 'Network unreachable';

  @override
  String get proxy_socks5NotAllowed => 'Not allowed by ruleset';

  @override
  String get proxy_socks5TtlExpired => 'TTL expired';

  @override
  String proxy_socks5UnknownAddrType(String hex) {
    return 'SOCKS5 unknown address type: 0x$hex';
  }

  @override
  String proxy_socks5UnknownError(String hex) {
    return 'Unknown error (0x$hex)';
  }

  @override
  String proxy_socks5UnsupportedAuth(String hex) {
    return 'SOCKS5 unsupported auth: 0x$hex';
  }

  @override
  String get proxy_ss2022KeyHint => 'Enter Shadowsocks 2022 key (Base64 PSK)';

  @override
  String get proxy_ss2022KeyInvalidBase64 => 'SS 2022 key must be valid Base64';

  @override
  String proxy_ss2022KeyInvalidLength(int length) {
    return 'SS 2022 key length invalid: must be $length bytes';
  }

  @override
  String get proxy_ssBase64DecodeFailed => 'ss:// Base64 decode failed';

  @override
  String get proxy_ssCannotParseCipher => 'Cannot parse cipher and password';

  @override
  String get proxy_ssIncomplete => 'Shadowsocks config incomplete';

  @override
  String get proxy_ssInvalidIpv6 => 'Invalid IPv6 address format';

  @override
  String get proxy_ssInvalidPort => 'Invalid port';

  @override
  String get proxy_ssLinkContentEmpty => 'ss:// link content empty';

  @override
  String get proxy_ssLinkEmpty => 'Link cannot be empty';

  @override
  String get proxy_ssMissingAddress => 'Missing server address';

  @override
  String get proxy_ssMissingPort => 'Missing port';

  @override
  String get proxy_ssOnlySsProtocol => 'Only ss:// links supported';

  @override
  String get proxy_ssPasswordHint => 'Enter Shadowsocks password';

  @override
  String get proxy_ssSaved => 'Shadowsocks config saved';

  @override
  String get proxy_ssSavedDetail =>
      'Current version routes Shadowsocks through local gateway; enable proxy and verify on homepage';

  @override
  String get proxy_ssSelectCipher => 'Select a supported Shadowsocks cipher';

  @override
  String proxy_ssUnsupportedCipher(String ciphers) {
    return 'Only $ciphers supported';
  }

  @override
  String proxy_targetResponseError(String statusLine) {
    return 'Target site response error: $statusLine';
  }

  @override
  String get proxy_testFailed => 'Proxy test failed';

  @override
  String get proxy_testSuccess => 'Proxy available';

  @override
  String proxy_testSuccessDetail(String protocol, String host, int statusCode) {
    return 'Connected to $host via $protocol proxy, HTTP $statusCode';
  }

  @override
  String get proxy_testTimeout => 'Proxy test timeout';

  @override
  String proxy_testTimeoutDetail(int seconds, String host) {
    return 'Connection/handshake exceeded ${seconds}s for $host';
  }

  @override
  String get proxy_testTlsFailed => 'TLS handshake failed';

  @override
  String get vpnToggle_and => ' and ';

  @override
  String get vpnToggle_connected => 'VPN Connected';

  @override
  String get vpnToggle_disconnected => 'VPN Disconnected';

  @override
  String get vpnToggle_subtitle =>
      'Auto-disable DOH and proxy when VPN detected, restore on disconnect';

  @override
  String get vpnToggle_suppressedSuffix =>
      ' auto-disabled, will restore when VPN disconnects';

  @override
  String get vpnToggle_title => 'VPN Auto Toggle';

  @override
  String get vpnToggle_upstreamProxy => 'Upstream Proxy';

  @override
  String get cdk_balance => 'CDK Points';

  @override
  String get cdk_points => 'Points';

  @override
  String get cdk_reAuthHint => 'Re-authorize to view points';

  @override
  String get ldc_balance => 'LDC Balance';

  @override
  String ldc_dailyIncome(String amount) {
    return 'Today\'s income $amount';
  }

  @override
  String get ldc_reAuthHint => 'Re-authorize to view balance';

  @override
  String get reward_authFailed => 'Auth failed, check Client ID and Secret';

  @override
  String get reward_clearCredential => 'Clear credentials';

  @override
  String get reward_configDialogTitle => 'Configure LDC Tip Credentials';

  @override
  String get reward_configHint => 'Enter credentials from credit.linux.do';

  @override
  String get reward_configured => 'Configured, can tip in posts';

  @override
  String reward_confirmMessage(String target, int amount) {
    return 'Tip $amount LDC to $target?';
  }

  @override
  String get reward_confirmTitle => 'Confirm tip';

  @override
  String get reward_createApp => 'Create app';

  @override
  String get reward_customAmount => 'Custom amount';

  @override
  String get reward_defaultError => 'Tip failed';

  @override
  String reward_duplicateWarning(int remaining) {
    return 'Please wait ${remaining}s before tipping again';
  }

  @override
  String get reward_goToCreateApp => 'Go to create app →';

  @override
  String reward_httpError(int statusCode) {
    return 'Request failed: HTTP $statusCode';
  }

  @override
  String reward_networkError(String error) {
    return 'Network error: $error';
  }

  @override
  String get reward_notConfigured => 'Configure credentials to enable tipping';

  @override
  String get reward_noteHint => 'Thanks for sharing!';

  @override
  String get reward_noteLabel => 'Note (optional)';

  @override
  String get reward_selectAmount => 'Select amount';

  @override
  String get reward_selectOrInputAmount => 'Select or enter amount';

  @override
  String get reward_sheetTitle => 'Tip LDC';

  @override
  String reward_submitWithAmount(int amount) {
    return 'Tip $amount LDC';
  }

  @override
  String get reward_title => 'LDC Tip';

  @override
  String reward_unknownError(String error) {
    return 'Unknown error: $error';
  }

  @override
  String get search_advancedSearch => 'Advanced search';

  @override
  String search_afterDate(String date) {
    return 'After $date';
  }

  @override
  String get search_applyFilter => 'Apply filter';

  @override
  String search_beforeDate(String date) {
    return 'Before $date';
  }

  @override
  String get search_category => 'Category';

  @override
  String search_categoryLoadFailed(String error) {
    return 'Failed to load categories: $error';
  }

  @override
  String get search_clearAll => 'Clear all';

  @override
  String get search_currentFilter => 'Current filter';

  @override
  String get search_custom => 'Custom';

  @override
  String get search_dateRange => 'Date range';

  @override
  String get search_emptyHint => 'Enter keywords to search';

  @override
  String get search_error => 'Search error';

  @override
  String get search_filterBookmarks => 'Bookmarks';

  @override
  String get search_filterCreated => 'My topics';

  @override
  String get search_filterSeen => 'Browsing history';

  @override
  String get search_hintText => 'Search @user #category tags:tag';

  @override
  String get search_lastMonth => 'Last month';

  @override
  String get search_lastWeek => 'Last week';

  @override
  String get search_lastYear => 'Last year';

  @override
  String search_likeCount(String count) {
    return '$count likes';
  }

  @override
  String get search_noLimit => 'No limit';

  @override
  String get search_noPopularTags => 'No popular tags';

  @override
  String get search_noResults => 'No results found';

  @override
  String get search_popularTags => 'Popular tags';

  @override
  String get search_recentSearches => 'Recent searches';

  @override
  String search_replyCount(int count) {
    return '$count replies';
  }

  @override
  String search_resultCount(int count, String more) {
    return '$count$more results';
  }

  @override
  String get search_selectDateRange => 'Select date range';

  @override
  String get search_selectedTags => 'Selected tags';

  @override
  String get search_sortLabel => 'Sort:';

  @override
  String get search_sortLatest => 'Latest posts';

  @override
  String get search_sortLatestTopic => 'Latest topics';

  @override
  String get search_sortLikes => 'Most liked';

  @override
  String get search_sortRelevance => 'Relevance';

  @override
  String get search_sortViews => 'Most viewed';

  @override
  String get search_status => 'Status';

  @override
  String get search_statusArchived => 'Archived';

  @override
  String get search_statusClosed => 'Closed';

  @override
  String get search_statusOpen => 'Open';

  @override
  String get search_statusSolved => 'Solved';

  @override
  String get search_statusUnsolved => 'Unsolved';

  @override
  String get search_tags => 'Tags';

  @override
  String search_tagsLoadFailed(String error) {
    return 'Failed to load tags: $error';
  }

  @override
  String get search_topicSearchHint => 'Search this topic';

  @override
  String get search_tryOtherKeywords => 'Try other keywords';

  @override
  String get search_users => 'Users';

  @override
  String search_viewCount(String count) {
    return '$count views';
  }

  @override
  String get cfVerify_cooldown => 'Too frequent, please try later';

  @override
  String get cfVerify_desc => 'Manually trigger verification';

  @override
  String get cfVerify_failed => 'Verification failed';

  @override
  String get cfVerify_success => 'Verification successful';

  @override
  String get cfVerify_title => 'Cloudflare Verification';

  @override
  String get cf_abandonVerifyMessage =>
      'Exiting verification will prevent related features from working. Are you sure?';

  @override
  String get cf_abandonVerifyTitle => 'Abandon verification?';

  @override
  String get cf_autoVerifyTimeout =>
      'Auto-verification timed out, please complete manually';

  @override
  String get cf_backgroundVerifying =>
      'Verifying in background... (tap to open)';

  @override
  String get cf_cannotOpenVerifyPage =>
      'Cannot open verification page, please retry';

  @override
  String get cf_challengeFailedCooldown =>
      'Verification failed, in cooldown period';

  @override
  String get cf_challengeNotEffective =>
      'Verification not effective, please retry';

  @override
  String get cf_continueVerify => 'Continue';

  @override
  String get cf_cooldown => 'Please try later';

  @override
  String get cf_failedRetry => 'Security verification failed, please retry';

  @override
  String cf_failedWithCause(String cause) {
    return 'Security verification failed: $cause';
  }

  @override
  String get cf_helpContent =>
      'This is a Cloudflare security verification page.\n\nPlease complete the challenge (e.g., checkbox or slider).\n\nThe page will close automatically after verification.\n\nIf unable to complete:\n• Tap refresh to reload\n• Check network connection\n• Close and try later';

  @override
  String get cf_helpTitle => 'Verification Help';

  @override
  String cf_loadFailed(String description) {
    return 'Failed to load: $description';
  }

  @override
  String get cf_securityVerifyTitle => 'Security Verification';

  @override
  String get cf_userCancelled => 'Verification cancelled';

  @override
  String get cf_verifyIncomplete => 'Verification incomplete, please retry';

  @override
  String cf_verifyLonger(int seconds) {
    return 'Verification taking longer, ${seconds}s remaining';
  }

  @override
  String get cf_verifyTimeout => 'Verification timed out, please retry';

  @override
  String cf_verifying(int seconds) {
    return 'Verifying... ${seconds}s';
  }

  @override
  String get hcaptcha_clear => 'Clear';

  @override
  String get hcaptcha_clearConfirm =>
      'Are you sure you want to clear the hCaptcha accessibility cookie?';

  @override
  String get hcaptcha_cookieCleared => 'hCaptcha accessibility cookie cleared';

  @override
  String get hcaptcha_cookieNotFound =>
      'hCaptcha accessibility cookie not found, please complete registration first';

  @override
  String get hcaptcha_cookieNotSet => 'Cookie not set';

  @override
  String get hcaptcha_cookieSaved => 'hCaptcha accessibility cookie saved';

  @override
  String get hcaptcha_cookieSet => 'Cookie set ✓';

  @override
  String get hcaptcha_done => 'Done';

  @override
  String get hcaptcha_pasteCookie => 'Paste Cookie';

  @override
  String get hcaptcha_pasteDialogDesc =>
      'After registering on the hCaptcha accessibility page in your browser, copy the hc_accessibility cookie value from browser DevTools and paste it below.';

  @override
  String get hcaptcha_pasteDialogHint => 'Enter hc_accessibility cookie value';

  @override
  String get hcaptcha_pasteDialogTitle => 'Paste hCaptcha Cookie';

  @override
  String get hcaptcha_pasteLink => 'Paste login link';

  @override
  String get hcaptcha_pasteLinkInvalid =>
      'No valid hCaptcha link found in clipboard';

  @override
  String get hcaptcha_subtitle =>
      'Skip hCaptcha verification for visually impaired users';

  @override
  String get hcaptcha_title => 'hCaptcha Accessibility';

  @override
  String get hcaptcha_webviewGet => 'WebView';

  @override
  String get hcaptcha_webviewTitle => 'hCaptcha Accessibility';

  @override
  String get config_seedUserTitle => 'Seed user';

  @override
  String get preferences_advanced => 'Advanced';

  @override
  String get preferences_androidNativeCdp => 'WebView cookie sync';

  @override
  String get preferences_androidNativeCdpDesc =>
      'Uses native CDP first. Disable to fall back to compatibility mode.';

  @override
  String get preferences_anonymousShare => 'Anonymous share';

  @override
  String get preferences_anonymousShareDesc =>
      'Share links without personal user identifier';

  @override
  String get preferences_autoFillLogin => 'Auto-fill login';

  @override
  String get preferences_autoFillLoginDesc =>
      'Remember credentials and auto-fill on login';

  @override
  String get preferences_autoPanguSpacing => 'Auto CJK spacing';

  @override
  String get preferences_autoPanguSpacingDesc =>
      'Auto-insert spaces between CJK and Latin text';

  @override
  String get preferences_basic => 'Basic';

  @override
  String get preferences_cfClearanceRefresh => 'cf_clearance auto refresh';

  @override
  String get preferences_cfClearanceRefreshDesc =>
      'Refresh the cf_clearance cookie through a background WebView.';

  @override
  String get preferences_crashlytics => 'Crash reporting';

  @override
  String get preferences_crashlyticsDesc =>
      'Auto-report crash logs to help developers';

  @override
  String get preferences_editor => 'Editor';

  @override
  String get preferences_enableCrashlyticsContent =>
      'This app uses Firebase Crashlytics to collect crash information to improve stability.\n\nCollected data includes device info and crash details, no personal data. You can disable this in Settings.';

  @override
  String get preferences_enableCrashlyticsTitle => 'Data Collection Notice';

  @override
  String get preferences_enterUrl => 'Enter URL';

  @override
  String get preferences_hideBarOnScroll => 'Hide bar on scroll';

  @override
  String get preferences_hideBarOnScrollDesc =>
      'Auto-hide top and bottom bars when scrolling';

  @override
  String get preferences_longPressPreview => 'Long press preview';

  @override
  String get preferences_longPressPreviewDesc =>
      'Long press topic card to preview content';

  @override
  String get preferences_openLinksInApp => 'Open links in app browser';

  @override
  String get preferences_openLinksInAppDesc =>
      'Open external links in in-app browser';

  @override
  String get preferences_portraitLock => 'Portrait lock';

  @override
  String get preferences_portraitLockDesc =>
      'Lock screen orientation to portrait';

  @override
  String get preferences_stickerSource => 'Sticker source';

  @override
  String get preferences_title => 'Preferences';

  @override
  String get settings_about => 'About FluxDO';

  @override
  String get settings_appearance => 'Appearance';

  @override
  String get settings_dataManagement => 'Data Management';

  @override
  String get settings_network => 'Network';

  @override
  String get settings_preferences => 'Preferences';

  @override
  String get settings_reading => 'Reading';

  @override
  String get settings_searchEmpty => 'No matching settings found';

  @override
  String get settings_searchHint => 'Search settings...';

  @override
  String get settings_shortcuts => 'Keyboard Shortcuts';

  @override
  String get settings_title => 'App Settings';

  @override
  String get shortcuts_closeOverlay => 'Close Overlay';

  @override
  String shortcuts_conflict(String action) {
    return 'Conflicts with \"$action\"';
  }

  @override
  String get shortcuts_content => 'Content';

  @override
  String get shortcuts_createTopic => 'Create Topic';

  @override
  String get shortcuts_customizeHint =>
      'Customize in Settings > Keyboard Shortcuts';

  @override
  String get shortcuts_navigateBack => 'Go Back';

  @override
  String get shortcuts_navigateBackAlt => 'Go Back (Alt)';

  @override
  String get shortcuts_navigation => 'Navigation';

  @override
  String get shortcuts_nextItem => 'Next Item';

  @override
  String get shortcuts_nextTab => 'Next Category';

  @override
  String get shortcuts_openItem => 'Open Selected Item';

  @override
  String get shortcuts_openSearch => 'Search';

  @override
  String get shortcuts_openSettings => 'Open Settings';

  @override
  String get shortcuts_previousItem => 'Previous Item';

  @override
  String get shortcuts_previousTab => 'Previous Category';

  @override
  String get shortcuts_recordKey => 'Press a new key combination';

  @override
  String get shortcuts_refresh => 'Refresh';

  @override
  String get shortcuts_resetAll => 'Reset All to Default';

  @override
  String get shortcuts_resetOne => 'Reset to Default';

  @override
  String get shortcuts_showHelp => 'Shortcut Help';

  @override
  String get shortcuts_switchPane => 'Switch Pane Focus';

  @override
  String get shortcuts_switchToProfile => 'Switch to Profile';

  @override
  String get shortcuts_switchToTopics => 'Switch to Topics';

  @override
  String get shortcuts_toggleAiPanel => 'AI Assistant Panel';

  @override
  String get shortcuts_toggleNotifications => 'Notifications';

  @override
  String get download_alreadyInProgress => 'Download already in progress';

  @override
  String get download_checksumFailed =>
      'Checksum failed, file may be corrupted';

  @override
  String get download_connecting => 'Connecting...';

  @override
  String download_downloading(String name) {
    return 'Downloading $name';
  }

  @override
  String download_failed(String error) {
    return 'Download failed: $error';
  }

  @override
  String download_failedWithError(String error) {
    return 'Download failed: $error';
  }

  @override
  String download_installFailed(String error) {
    return 'Install failed: $error';
  }

  @override
  String get download_installStarted => 'Installation started';

  @override
  String get download_installing => 'Installing...';

  @override
  String get download_internalError => 'Internal error during download';

  @override
  String get download_noInstallPermission => 'Install permission not granted';

  @override
  String get download_verifying => 'Verifying file...';

  @override
  String export_exporting(int progress, int total) {
    return 'Exporting ($progress/$total)';
  }

  @override
  String get export_exportingNoProgress => 'Exporting...';

  @override
  String export_failed(String error) {
    return 'Export failed: $error';
  }

  @override
  String get export_fetchPostsFailed => 'Failed to fetch post data';

  @override
  String get export_firstPostOnly => 'First post only';

  @override
  String get export_format => 'Export format';

  @override
  String export_markdownLimit(int max) {
    return 'Markdown exports up to $max posts';
  }

  @override
  String get export_noPostsToExport => 'No posts to export';

  @override
  String get export_range => 'Export range';

  @override
  String get export_title => 'Export article';

  @override
  String get share_aiAssistant => 'AI Assistant';

  @override
  String get share_aiQuestion => 'Question';

  @override
  String get share_aiReply => 'AI Reply';

  @override
  String get share_aiReplyAlt => 'AI Assistant Reply';

  @override
  String get share_cannotGetPostId => 'Cannot get first post ID';

  @override
  String get share_copyFailed => 'Copy failed, please retry';

  @override
  String get share_exportChatImage => 'Export chat image';

  @override
  String get share_exportImage => 'Export image';

  @override
  String get share_generatedByAi => 'Generated by FluxDO AI Assistant';

  @override
  String get share_getPostFailed => 'Failed to get first post';

  @override
  String get share_imageCopied => 'Image copied';

  @override
  String get share_imageSaved => 'Image saved to gallery';

  @override
  String get share_loadingPost => 'Loading post...';

  @override
  String get share_replyToTopic => 'Reply to topic';

  @override
  String get share_saveFailed => 'Save failed, please retry';

  @override
  String get share_savePermissionDenied =>
      'Save failed, please grant gallery permission';

  @override
  String get share_saveToGallery => 'Save to gallery';

  @override
  String get share_fileSaved => 'File saved';

  @override
  String get share_selectSaveLocation => 'Select save location';

  @override
  String get share_screenshotFailed => 'Screenshot failed';

  @override
  String get share_shareImageTitle => 'Share image';

  @override
  String get share_themeBlack => 'Black';

  @override
  String get share_themeBlue => 'Blue';

  @override
  String get share_themeClassic => 'Classic';

  @override
  String get share_themeDark => 'Dark';

  @override
  String get share_themeGreen => 'Green';

  @override
  String get share_themeWhite => 'White';

  @override
  String get share_uploadFailed => 'Upload failed, please retry';

  @override
  String get share_uploading => 'Uploading...';

  @override
  String time_days(int count) {
    return '$count days';
  }

  @override
  String time_daysAgo(int count) {
    return '${count}d ago';
  }

  @override
  String time_fullDate(int year, int month, int day) {
    return '$month/$day/$year';
  }

  @override
  String time_hours(int count) {
    return '$count hours';
  }

  @override
  String time_hoursAgo(int count) {
    return '${count}h ago';
  }

  @override
  String get time_justNow => 'Just now';

  @override
  String time_minutes(int count) {
    return '$count minutes';
  }

  @override
  String time_minutesAgo(int count) {
    return '${count}m ago';
  }

  @override
  String time_monthsAgo(int count) {
    return '${count}mo ago';
  }

  @override
  String time_seconds(int count) {
    return '$count seconds';
  }

  @override
  String time_shortDate(int month, int day) {
    return '$month/$day';
  }

  @override
  String get time_today => 'Today';

  @override
  String time_tooltipTime(
    int year,
    int month,
    int day,
    String hour,
    String minute,
    String second,
  ) {
    return '$month/$day/$year $hour:$minute:$second';
  }

  @override
  String time_weeksAgo(int count) {
    return '${count}w ago';
  }

  @override
  String time_yearsAgo(int count) {
    return '${count}y ago';
  }

  @override
  String get time_yesterday => 'Yesterday';

  @override
  String get topicDetail_addToReadLater => 'Add to float';

  @override
  String get topicDetail_addToReadLaterSuccess => 'Added to float';

  @override
  String get topicDetail_aiAssistant => 'AI Assistant';

  @override
  String get topicDetail_authorOnly => 'OP only';

  @override
  String get topicDetail_cannotOpenBrowser => 'Cannot open browser';

  @override
  String get topicDetail_editBookmark => 'Edit bookmark';

  @override
  String get topicDetail_editTopic => 'Edit topic';

  @override
  String get topicDetail_exportArticle => 'Export article';

  @override
  String get topicDetail_filter => 'Filter';

  @override
  String get topicDetail_generateShareImage => 'Generate share image';

  @override
  String get topicDetail_hotOnly => 'Hot only';

  @override
  String get topicDetail_loadFailedTapRetry => 'Failed to load, tap to retry';

  @override
  String get topicDetail_loading => 'Loading...';

  @override
  String get topicDetail_moreOptions => 'More options';

  @override
  String get topicDetail_openInBrowser => 'Open in browser';

  @override
  String topicDetail_readLaterFull(int max) {
    return 'Float is full (max $max)';
  }

  @override
  String get topicDetail_removeFromReadLater => 'Remove from float';

  @override
  String get topicDetail_removeFromReadLaterSuccess => 'Removed from float';

  @override
  String get topicDetail_replyLabel => 'Replies';

  @override
  String get topicDetail_scrollToTop => 'Scroll to top';

  @override
  String get topicDetail_searchHint => 'Search this topic...';

  @override
  String get topicDetail_searchTopic => 'Search topic';

  @override
  String topicDetail_setToLevel(String level) {
    return 'Set to $level';
  }

  @override
  String get topicDetail_shareLink => 'Share link';

  @override
  String topicDetail_showHiddenReplies(int count) {
    return 'Show $count hidden replies';
  }

  @override
  String get topicDetail_topLevelOnly => 'Top-level only';

  @override
  String get topicDetail_viewAll => 'View all';

  @override
  String get topicDetail_viewsLabel => 'Views';

  @override
  String get topicSort_activity => 'Activity';

  @override
  String get topicSort_created => 'Created';

  @override
  String get topicSort_default => 'Default';

  @override
  String get topicSort_likes => 'Likes';

  @override
  String get topicSort_posters => 'Posters';

  @override
  String get topicSort_posts => 'Replies';

  @override
  String get topicSort_views => 'Views';

  @override
  String get topic_addTags => 'Add tags';

  @override
  String get topic_aiSummary => 'AI Summary';

  @override
  String get topic_atCurrentPosition => 'You are here';

  @override
  String get topic_createdAt => 'Created ';

  @override
  String get topic_currentFloor => 'Current post';

  @override
  String get topic_filterHot => 'Hot';

  @override
  String get topic_filterLatest => 'Latest';

  @override
  String get topic_filterNew => 'New';

  @override
  String topic_filterTooltip(String label) {
    return 'Filter: $label';
  }

  @override
  String get topic_filterTop => 'Top';

  @override
  String get topic_filterUnread => 'Unread';

  @override
  String get topic_filterUnseen => 'Unseen';

  @override
  String get topic_flagInappropriate => 'Inappropriate';

  @override
  String get topic_flagInappropriateDesc =>
      'This post contains inappropriate content';

  @override
  String get topic_flagOffTopic => 'Off-topic';

  @override
  String get topic_flagOffTopicDesc =>
      'This post is not relevant and should be moved';

  @override
  String get topic_flagOther => 'Something else';

  @override
  String get topic_flagOtherDesc =>
      'Other issues requiring moderator attention';

  @override
  String get topic_flagSpam => 'Spam';

  @override
  String get topic_flagSpamDesc => 'This post is spam or advertising';

  @override
  String get topic_generateAiSummary => 'Generate AI summary';

  @override
  String get topic_generatingSummary => 'Generating summary...';

  @override
  String get topic_jump => 'Jump';

  @override
  String get topic_lastReply => 'Last reply ';

  @override
  String get topic_levelMuted => 'Muted';

  @override
  String get topic_levelMutedDesc => 'No notifications';

  @override
  String get topic_levelRegular => 'Normal';

  @override
  String get topic_levelRegularDesc => 'Only when @mentioned or replied';

  @override
  String get topic_levelTracking => 'Tracking';

  @override
  String get topic_levelTrackingDesc => 'Show unread count';

  @override
  String get topic_levelWatching => 'Watching';

  @override
  String get topic_levelWatchingDesc => 'Notify for every reply';

  @override
  String topic_likeCount(String count) {
    return '$count likes';
  }

  @override
  String topic_minTagsRequired(int min) {
    return 'Select at least $min tags';
  }

  @override
  String topic_newRepliesSinceSummary(int count) {
    return '$count new replies';
  }

  @override
  String get topic_noSummary => 'No summary available';

  @override
  String get topic_notificationSettings => 'Notification settings';

  @override
  String get topic_participants => 'Participants';

  @override
  String get topic_readyToJump => 'Ready to jump';

  @override
  String topic_remainingTags(int remaining) {
    return '$remaining more tags needed';
  }

  @override
  String topic_replyCount(int count) {
    return '$count replies';
  }

  @override
  String get topic_selectCategory => 'Select category';

  @override
  String topic_sortTooltip(String label) {
    return 'Sort: $label';
  }

  @override
  String get topic_summaryLoadFailed => 'Failed to load summary';

  @override
  String topic_tagGroupRequirement(String name, int minCount) {
    return 'Select $minCount from $name';
  }

  @override
  String get topic_updatedAt => 'Updated ';

  @override
  String topic_viewCount(String count) {
    return '$count views';
  }

  @override
  String get topicsScreen_createTopic => 'Create Topic';

  @override
  String get topicsScreen_myDrafts => 'My Drafts';

  @override
  String get topics_browseCategories => 'Browse categories';

  @override
  String get topics_debugJump => 'Debug: Jump to topic';

  @override
  String get topics_dismiss => 'Dismiss';

  @override
  String topics_dismissConfirmContent(String label) {
    return 'Dismiss all $label?';
  }

  @override
  String get topics_dismissConfirmTitle => 'Dismiss confirmation';

  @override
  String get topics_jump => 'Jump';

  @override
  String get topics_jumpToTopic => 'Jump to topic';

  @override
  String get topics_newTopics => 'New topics';

  @override
  String get topics_noTopics => 'No topics found';

  @override
  String get topics_searchHint => 'Search topics...';

  @override
  String get topics_topicId => 'Topic ID';

  @override
  String get topics_topicIdHint => 'e.g., 1095754';

  @override
  String get topics_unreadTopics => 'Unread topics';

  @override
  String topics_viewNewTopics(int count) {
    return 'View $count new or updated topics';
  }

  @override
  String get followList_followers => 'Followers';

  @override
  String get followList_following => 'Following';

  @override
  String get privateMessages_title => 'Messages';

  @override
  String get privateMessages_inbox => 'Inbox';

  @override
  String get privateMessages_sent => 'Sent';

  @override
  String get privateMessages_archive => 'Archive';

  @override
  String get privateMessages_empty => 'No messages';

  @override
  String get profileStats_addItems => 'Tap to add stats';

  @override
  String get profileStats_allItemsAdded => 'All items added';

  @override
  String get profileStats_availableItems => 'Available Items';

  @override
  String get profileStats_bookmarkCount => 'Bookmarks';

  @override
  String get profileStats_columnsPerRow => 'Columns Per Row';

  @override
  String get profileStats_dataSource => 'Data Source';

  @override
  String get profileStats_daysVisited => 'Days Visited';

  @override
  String get profileStats_editTitle => 'Customize Stats Card';

  @override
  String get profileStats_enabledItems => 'Enabled Items';

  @override
  String get profileStats_guideMessage =>
      'Tap the stats card to customize items, layout, and data source';

  @override
  String get profileStats_incompatibleSource =>
      'Incompatible with current data source';

  @override
  String get profileStats_layoutGrid => 'Grid';

  @override
  String get profileStats_layoutMode => 'Layout Mode';

  @override
  String get profileStats_layoutScroll => 'Scroll';

  @override
  String get profileStats_layoutSettings => 'Layout Settings';

  @override
  String get profileStats_likesGiven => 'Likes Given';

  @override
  String get profileStats_likesReceived => 'Likes Received';

  @override
  String get profileStats_likesReceivedDays => 'Liked Days';

  @override
  String get profileStats_likesReceivedUsers => 'Liked Users';

  @override
  String get profileStats_loadError =>
      'Failed to load, fell back to all-time stats';

  @override
  String get profileStats_noItemsSelected => 'No items selected';

  @override
  String get profileStats_postCount => 'Posts';

  @override
  String get profileStats_postsRead => 'Posts Read';

  @override
  String get profileStats_recentTimeRead => 'Recent 60d Read';

  @override
  String get profileStats_selectItems => 'Stats Items';

  @override
  String get profileStats_sourceConnect => 'Trust Period';

  @override
  String get profileStats_sourceDaily => 'Daily';

  @override
  String get profileStats_sourceMonthly => 'Monthly';

  @override
  String get profileStats_sourceQuarterly => 'Quarterly';

  @override
  String get profileStats_sourceSummary => 'All Time';

  @override
  String get profileStats_sourceWeekly => 'Weekly';

  @override
  String get profileStats_sourceYearly => 'Yearly';

  @override
  String get profileStats_timeRead => 'Time Read';

  @override
  String get profileStats_topicCount => 'Topics';

  @override
  String get profileStats_topicsEntered => 'Topics Viewed';

  @override
  String get profileStats_topicsRepliedTo => 'Topics Replied';

  @override
  String get profile_aboutFluxDO => 'About FluxDO';

  @override
  String get profile_aiModelService => 'AI Model Service';

  @override
  String get profile_appearance => 'Appearance';

  @override
  String get profile_browsingHistory => 'Browsing history';

  @override
  String get profile_cdkReauthSuccess => 'CDK re-authorization successful';

  @override
  String get profile_confirmLogout => 'Confirm logout';

  @override
  String get profile_dataManagement => 'Data management';

  @override
  String get profile_daysVisited => 'Days visited';

  @override
  String get profile_editProfile => 'Edit profile';

  @override
  String get profile_inviteLinks => 'Invite links';

  @override
  String get profile_ldcReauthSuccess => 'LDC re-authorization successful';

  @override
  String get profile_likesReceived => 'Likes received';

  @override
  String get profile_loadingData => 'Loading data...';

  @override
  String get profile_loggingOut => 'Logging out...';

  @override
  String get profile_loginForMore => 'Log in for more features';

  @override
  String get profile_loginLinuxDo => 'Log in to Linux.do';

  @override
  String get profile_logoutContent => 'Are you sure you want to log out?';

  @override
  String get profile_logoutCurrentAccount => 'Log out current account';

  @override
  String get profile_metaverse => 'Metaverse';

  @override
  String get profile_privateMessages => 'Messages';

  @override
  String get profile_myBadges => 'My badges';

  @override
  String get profile_myBookmarks => 'My bookmarks';

  @override
  String get profile_myBrowser => 'Web Browse';

  @override
  String get profile_myDrafts => 'My drafts';

  @override
  String get profile_myTopics => 'My topics';

  @override
  String get profile_networkSettings => 'Network settings';

  @override
  String get profile_notLoggedIn => 'Not logged in';

  @override
  String get profile_postCount => 'Posts made';

  @override
  String get profile_postsRead => 'Posts read';

  @override
  String get profile_preferences => 'Preferences';

  @override
  String get profile_settings => 'App Settings';

  @override
  String get profile_trustRequirements => 'Trust requirements';

  @override
  String get trustLevel_activity => 'Activity';

  @override
  String get trustLevel_appBarTitle => 'Trust Requirements';

  @override
  String get trustLevel_compliance => 'Compliance';

  @override
  String get trustLevel_interaction => 'Interaction';

  @override
  String trustLevel_parseFailed(String error) {
    return 'Parse failed: $error';
  }

  @override
  String get trustLevel_parseNotFound =>
      'Trust level info not found (div.card)';

  @override
  String trustLevel_requestFailed(int statusCode) {
    return 'Request failed: $statusCode';
  }

  @override
  String get trustLevel_title => 'Trust Level Requirements';

  @override
  String get userProfile_actionCreatedTopic => 'Created topic';

  @override
  String get userProfile_actionDefault => 'Activity';

  @override
  String get userProfile_actionLike => 'Liked';

  @override
  String get userProfile_actionLiked => 'Was liked';

  @override
  String get userProfile_actionReplied => 'Replied';

  @override
  String get userProfile_bio => 'Bio';

  @override
  String userProfile_catPostCount(int count) {
    return '$count posts';
  }

  @override
  String userProfile_catTopicCount(int count) {
    return '$count topics';
  }

  @override
  String get userProfile_follow => 'Follow';

  @override
  String get userProfile_followed => 'Following';

  @override
  String get userProfile_followers => 'Followers';

  @override
  String get userProfile_following => 'Following';

  @override
  String get userProfile_fourMonths => 'Four months';

  @override
  String get userProfile_ignored => 'Ignored';

  @override
  String get userProfile_joinDate => 'Joined';

  @override
  String get userProfile_laterThisWeek => 'Later this week';

  @override
  String get userProfile_laterToday => 'Later today';

  @override
  String userProfile_linkClicks(int count) {
    return '$count clicks';
  }

  @override
  String get userProfile_location => 'Location';

  @override
  String get userProfile_message => 'Message';

  @override
  String get userProfile_moreInfo => 'More info';

  @override
  String get userProfile_mostLiked => 'Most liked';

  @override
  String get userProfile_mostLikedBy => 'Most liked by';

  @override
  String get userProfile_mostRepliedTo => 'Most replied to';

  @override
  String get userProfile_mute => 'Mute';

  @override
  String get userProfile_nextMonday => 'Next Monday';

  @override
  String get userProfile_nextMonth => 'Next month';

  @override
  String get userProfile_noBio => 'This person is too lazy to write anything';

  @override
  String get userProfile_noContent => 'No content';

  @override
  String get userProfile_noReactions => 'No reactions';

  @override
  String get userProfile_noSummary => 'No summary data';

  @override
  String get userProfile_normal => 'Normal';

  @override
  String get userProfile_oneYear => 'One year';

  @override
  String get userProfile_permanent => 'Permanent';

  @override
  String get userProfile_permanentlySilenced =>
      'This user has been permanently silenced';

  @override
  String get userProfile_permanentlySuspended =>
      'This user has been permanently suspended';

  @override
  String get userProfile_reacted => 'Reacted';

  @override
  String get userProfile_restored => 'Restored to normal notifications';

  @override
  String get userProfile_selectIgnoreDuration => 'Select ignore duration';

  @override
  String get userProfile_setToIgnore => 'Set to ignored';

  @override
  String get userProfile_setToMute => 'Set to muted';

  @override
  String get userProfile_shareUser => 'Share user';

  @override
  String get userProfile_silencedBannerForever =>
      'This user has been permanently silenced';

  @override
  String userProfile_silencedBannerUntil(String date) {
    return 'This user has been silenced until $date';
  }

  @override
  String get userProfile_silencedStatus => 'Silenced';

  @override
  String userProfile_silencedUntil(String date) {
    return 'Silenced until $date';
  }

  @override
  String get userProfile_sixMonths => 'Six months';

  @override
  String get userProfile_statsLikes => 'Likes';

  @override
  String get userProfile_statsReplies => 'Replies';

  @override
  String get userProfile_statsTopics => 'Topics';

  @override
  String get userProfile_statsVisits => 'Visits';

  @override
  String get userProfile_suspendedBannerForever =>
      'This user has been permanently suspended';

  @override
  String userProfile_suspendedBannerUntil(String date) {
    return 'This user has been suspended until $date';
  }

  @override
  String get userProfile_suspendedStatus => 'Suspended';

  @override
  String userProfile_suspendedUntil(String date) {
    return 'Suspended until $date';
  }

  @override
  String get userProfile_tabActivity => 'Activity';

  @override
  String get userProfile_tabLikes => 'Likes';

  @override
  String get userProfile_tabReactions => 'Reactions';

  @override
  String get userProfile_tabReplies => 'Replies';

  @override
  String get userProfile_tabSummary => 'Summary';

  @override
  String get userProfile_tabTopics => 'Topics';

  @override
  String get userProfile_threeMonths => 'Three months';

  @override
  String get userProfile_tomorrow => 'Tomorrow';

  @override
  String get userProfile_topBadges => 'Top badges';

  @override
  String get userProfile_topCategories => 'Top categories';

  @override
  String get userProfile_topLinks => 'Top links';

  @override
  String get userProfile_topReplies => 'Top replies';

  @override
  String get userProfile_topTopics => 'Top topics';

  @override
  String userProfile_topicHash(String id) {
    return 'Topic #$id';
  }

  @override
  String get userProfile_twoMonths => 'Two months';

  @override
  String get userProfile_twoWeeks => 'Two weeks';

  @override
  String get userProfile_website => 'Website';

  @override
  String get user_trustLevel0 => 'L0 New User';

  @override
  String get user_trustLevel1 => 'L1 Basic User';

  @override
  String get user_trustLevel2 => 'L2 Member';

  @override
  String get user_trustLevel3 => 'L3 Regular';

  @override
  String get user_trustLevel4 => 'L4 Leader';

  @override
  String user_trustLevelUnknown(int level) {
    return 'Level $level';
  }

  @override
  String get myBrowser_addManually => 'Add bookmark';

  @override
  String myBrowser_bookmarkCount(int count) {
    return '$count bookmarks';
  }

  @override
  String get myBrowser_bookmarks => 'Bookmarks';

  @override
  String get myBrowser_clearCompleted => 'Clear completed';

  @override
  String get myBrowser_clearCompletedConfirm =>
      'Are you sure you want to clear all completed downloads?';

  @override
  String get myBrowser_clearHistory => 'Clear history';

  @override
  String get myBrowser_clearHistoryConfirm =>
      'Are you sure you want to clear all browsing history?';

  @override
  String get myBrowser_confirmDelete =>
      'Are you sure you want to delete this bookmark?';

  @override
  String get myBrowser_delete => 'Delete';

  @override
  String get myBrowser_deleted => 'Bookmark deleted';

  @override
  String get myBrowser_downloadComplete => 'Download complete';

  @override
  String get myBrowser_downloadEmpty => 'No downloads yet';

  @override
  String get myBrowser_downloadFailed => 'Download failed';

  @override
  String myBrowser_downloadSize(String size) {
    return '$size MB';
  }

  @override
  String get myBrowser_downloadStarted => 'Download started';

  @override
  String get myBrowser_downloading => 'Downloading';

  @override
  String get myBrowser_downloads => 'Downloads';

  @override
  String get myBrowser_downloadsDesc => 'View downloaded files';

  @override
  String get myBrowser_edit => 'Edit';

  @override
  String get myBrowser_editTitle => 'Edit title';

  @override
  String get myBrowser_empty => 'No bookmarked pages yet';

  @override
  String get myBrowser_fileNotFound => 'File not found';

  @override
  String get myBrowser_history => 'Browsing History';

  @override
  String get myBrowser_historyCleared => 'Browsing history cleared';

  @override
  String get myBrowser_historyDesc => 'View browsed pages';

  @override
  String get myBrowser_historyEmpty => 'No browsing history yet';

  @override
  String get myBrowser_inputTitle => 'Title (optional)';

  @override
  String get myBrowser_inputUrl => 'Enter URL';

  @override
  String get myBrowser_open => 'Open';

  @override
  String get myBrowser_title => 'Web Browse';

  @override
  String get myBrowser_undo => 'Undo';

  @override
  String get myBrowser_viewDownload => 'View';

  @override
  String get webviewLogin_clearSaved => 'Clear saved password';

  @override
  String get webviewLogin_clearSavedContent =>
      'Clear saved login credentials? You will need to enter them manually next time.';

  @override
  String get webviewLogin_clearSavedTitle => 'Clear saved password';

  @override
  String get webviewLogin_emailLoginInvalidLink => 'Invalid login link';

  @override
  String get webviewLogin_emailLoginPaste => 'Paste login link';

  @override
  String webviewLogin_lastLogin(String username) {
    return 'Last login: @$username';
  }

  @override
  String get webviewLogin_loginSuccess => 'Login successful!';

  @override
  String get webviewLogin_savedPassword => 'Saved password';

  @override
  String get webviewLogin_title => 'Log in to Linux.do';

  @override
  String get webview_addBookmark => 'Bookmark this page';

  @override
  String get webview_bookmarkAdded => 'Bookmarked';

  @override
  String get webview_bookmarkRemoved => 'Bookmark removed';

  @override
  String get webview_browser => 'Browser';

  @override
  String get webview_cannotOpenBrowser => 'Cannot open external browser';

  @override
  String get webview_go => 'Go';

  @override
  String get webview_goBack => 'Back';

  @override
  String get webview_goForward => 'Forward';

  @override
  String get webview_inputUrl => 'Enter or edit URL';

  @override
  String get webview_noAppForLink => 'No app found for this link';

  @override
  String get webview_openExternal => 'Open in external browser';

  @override
  String webview_openFailed(String error) {
    return 'Open failed: $error';
  }

  @override
  String get webview_removeBookmark => 'Remove bookmark';
}
