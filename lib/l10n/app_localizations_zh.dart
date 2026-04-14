// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get about_appLogs => '应用日志';

  @override
  String get about_checkUpdate => '检查更新';

  @override
  String about_checkUpdateError(String error) {
    return '无法检查更新，请稍后重试。\n错误信息: $error';
  }

  @override
  String get about_checkUpdateFailed => '检查更新失败';

  @override
  String get about_develop => '开发';

  @override
  String get about_developerMode => '开发者模式';

  @override
  String get about_developerModeAlreadyEnabled => '开发者模式已启用';

  @override
  String get about_developerModeClosed => '已关闭开发者模式';

  @override
  String get about_developerModeEnabled => '已启用开发者模式';

  @override
  String get about_feedback => '反馈问题';

  @override
  String get about_info => '信息';

  @override
  String get about_latestVersion => '已是最新版本';

  @override
  String get about_legalese => '非官方 Linux.do 客户端\n基于 Flutter & Material 3';

  @override
  String about_noUpdateContent(String version) {
    return '当前版本: $version\n您正在使用最新版本的 FluxDO，无需更新。';
  }

  @override
  String get about_openSourceLicense => '开源许可';

  @override
  String get about_sourceCode => '项目源码';

  @override
  String get about_tapToDisableDeveloperMode => '点击关闭开发者模式';

  @override
  String get about_title => '关于';

  @override
  String get deviceInfo_dohOff => 'DOH: 关闭';

  @override
  String get deviceInfo_proxyOff => '代理: 关闭';

  @override
  String get update_changelog => '更新内容';

  @override
  String get update_dontRemind => '不再提醒';

  @override
  String get update_newVersionFound => '发现新版本';

  @override
  String get update_now => '立即更新';

  @override
  String get update_rateLimited => 'GitHub API 请求过于频繁，请稍后再试';

  @override
  String get ai_askSubtitle => 'AI 会基于话题内容为你解答';

  @override
  String get ai_askTitle => '向 AI 助手提问';

  @override
  String get ai_clearChat => '清空聊天';

  @override
  String get ai_clearChatConfirm => '确定要清空所有聊天记录吗？';

  @override
  String get ai_clearChatTitle => '清空聊天';

  @override
  String get ai_clearLabel => '清空';

  @override
  String get ai_copiedToClipboard => '已复制到剪贴板';

  @override
  String get ai_copyLabel => '复制';

  @override
  String get ai_exportImage => '导出图片';

  @override
  String get ai_generateFailed => '生成失败';

  @override
  String get ai_highlights => '有什么值得关注的';

  @override
  String get ai_highlightsPrompt => '这个话题中有哪些值得关注的信息或亮点？';

  @override
  String get ai_inputHint => '输入消息...';

  @override
  String get ai_likeInDev => '点赞功能开发中...';

  @override
  String get ai_listViewpoints => '列出主要观点';

  @override
  String get ai_listViewpointsPrompt => '请列出这个话题中各楼层的主要观点和立场。';

  @override
  String get ai_moreTooltip => '更多';

  @override
  String get ai_multiSelectExport => '多选导出';

  @override
  String get ai_newSession => '新建会话';

  @override
  String get ai_retryLabel => '重试';

  @override
  String get ai_selectContext => '选择上下文范围';

  @override
  String get ai_selectExportMessages => '请选择要导出的消息';

  @override
  String get ai_selectModel => '选择模型';

  @override
  String ai_selectedCount(int count) {
    return '已选 $count 条';
  }

  @override
  String get ai_sendTooltip => '发送';

  @override
  String ai_sessionCount(int count) {
    return '$count 条';
  }

  @override
  String get ai_sessionHistory => '会话记录';

  @override
  String ai_sessionTitle(int index) {
    return '会话 $index';
  }

  @override
  String get ai_stopGenerate => '停止生成';

  @override
  String get ai_summarizePrompt => '请简要总结这个话题的主要内容和讨论要点。';

  @override
  String get ai_summarizeTopic => '总结这个话题';

  @override
  String get ai_swipeHint => '向左滑动可打开 AI 助手';

  @override
  String get ai_title => 'AI 助手';

  @override
  String get ai_translatePost => '翻译主帖';

  @override
  String get ai_translatePrompt => '请将主帖内容翻译成英文。';

  @override
  String get ai_typingIndicator => '正在输入';

  @override
  String get appearance_appIcon => '应用图标';

  @override
  String get appearance_colorAmber => '琥珀';

  @override
  String get appearance_colorBlue => '蓝色';

  @override
  String get appearance_colorGreen => '绿色';

  @override
  String get appearance_colorIndigo => '靛蓝';

  @override
  String get appearance_colorOrange => '橙色';

  @override
  String get appearance_colorPink => '粉色';

  @override
  String get appearance_colorPurple => '紫色';

  @override
  String get appearance_colorRed => '红色';

  @override
  String get appearance_colorTeal => '青色';

  @override
  String get appearance_contentFontSize => '内容字体大小';

  @override
  String get appearance_dialogBlur => '对话框模糊';

  @override
  String get appearance_dialogBlurDesc => '对话框弹出时模糊背景';

  @override
  String get appearance_font => '字体';

  @override
  String get appearance_fontSystem => '系统默认';

  @override
  String get appearance_iconClassic => '经典';

  @override
  String get appearance_iconModern => '现代';

  @override
  String get appearance_language => '语言';

  @override
  String get appearance_languageEn => 'English';

  @override
  String get appearance_languageSystem => '跟随系统';

  @override
  String get appearance_languageZhCN => '简体中文';

  @override
  String get appearance_languageZhHK => '繁體中文（香港）';

  @override
  String get appearance_languageZhTW => '繁體中文（台灣）';

  @override
  String get appearance_large => '大';

  @override
  String get appearance_modeAuto => '自动';

  @override
  String get appearance_modeDark => '深色';

  @override
  String get appearance_modeLight => '浅色';

  @override
  String get appearance_panguSpacing => '阅读混排优化';

  @override
  String get appearance_panguSpacingDesc => '浏览帖子时自动优化中英文间距';

  @override
  String get appearance_reading => '阅读';

  @override
  String get appearance_schemeVariant => '配色风格';

  @override
  String get appearance_small => '小';

  @override
  String get appearance_switchIconFailed => '切换图标失败，请稍后重试';

  @override
  String get appearance_themeColor => '主题色彩';

  @override
  String get appearance_themeMode => '主题模式';

  @override
  String get appearance_title => '外观';

  @override
  String get layout_selectTopicHint => '选择一个话题查看详情';

  @override
  String get reading_aiSwipeEntry => 'AI 助手滑动入口';

  @override
  String get reading_aiSwipeEntryDesc => '在话题详情页向左滑动打开 AI 助手';

  @override
  String get reading_expandRelatedLinks => '默认展开相关链接';

  @override
  String get reading_expandRelatedLinksDesc => '帖子中的相关链接区域默认展开显示';

  @override
  String get reading_title => '阅读设置';

  @override
  String get schemeVariant_content => '内容';

  @override
  String get schemeVariant_expressive => '表现力';

  @override
  String get schemeVariant_fidelity => '高保真';

  @override
  String get schemeVariant_fruitSalad => '缤纷';

  @override
  String get schemeVariant_monochrome => '单色';

  @override
  String get schemeVariant_neutral => '中性';

  @override
  String get schemeVariant_rainbow => '彩虹';

  @override
  String get schemeVariant_tonalSpot => '柔和色调';

  @override
  String get schemeVariant_vibrant => '鲜明';

  @override
  String get auth_cdkConfirmMessage => 'Linux.do CDK 将获取你的基本信息，是否允许？';

  @override
  String get auth_cdkConfirmTitle => '授权确认';

  @override
  String get auth_clearDataAction => '清理数据';

  @override
  String get auth_cookieRepairLogoutHint =>
      '检测到历史登录 Cookie 异常，应用已自动清理相关脏数据。这可能会让旧的无效登录态立即失效，请重新登录。';

  @override
  String get auth_frequentLogoutClearDataHint =>
      '最近 24 小时内多次触发登录失效。如果重新登录后仍反复发生，建议前往“数据管理”清除 Cookie 或全部数据后再登录。';

  @override
  String get auth_ldcConfirmMessage => 'Linux.do Credit 将获取你的基本信息，是否允许？';

  @override
  String get auth_ldcConfirmTitle => '授权确认';

  @override
  String get auth_logSubject => '认证日志';

  @override
  String get auth_loginExpiredRelogin => '登录已失效，请重新登录';

  @override
  String get auth_loginExpiredTitle => '登录失效';

  @override
  String auth_oauthExpired(String serviceName) {
    return '$serviceName 授权已过期';
  }

  @override
  String get login_browserHint => '将在浏览器中打开登录页面';

  @override
  String get login_slogan => '真诚、友善、团结、专业';

  @override
  String get migration_cookieUpgrade => '正在升级 Cookie 存储...';

  @override
  String get migration_reloginRequired =>
      '本次版本升级优化了 Cookie 存储机制，已清除旧的登录状态。请重新登录。';

  @override
  String get migration_title => '数据升级';

  @override
  String get oauth_approvePageParseFailed => '授权页面解析失败，请确认已登录论坛';

  @override
  String get oauth_callbackFailed => '授权回调失败';

  @override
  String get oauth_getAuthUrlFailed => '获取授权链接失败';

  @override
  String get oauth_missingParams => '授权回调缺少必要参数';

  @override
  String get oauth_networkError => '网络请求失败，请检查网络连接';

  @override
  String get oauth_noRedirectResponse => '授权服务未返回重定向';

  @override
  String get onboarding_guestAccess => '游客访问';

  @override
  String get onboarding_networkSettings => '网络设置';

  @override
  String get onboarding_slogan => '真诚 · 友善 · 团结 · 专业';

  @override
  String get badge_bronze => '铜牌';

  @override
  String get badge_bronzeBadge => '铜牌徽章';

  @override
  String get badge_defaultName => '徽章';

  @override
  String get badge_gold => '金牌';

  @override
  String get badge_goldBadge => '金牌徽章';

  @override
  String badge_grantedCount(int count) {
    return '已授予 $count 次';
  }

  @override
  String get badge_grantedSuffix => ' 获得';

  @override
  String badge_granteeCount(int count) {
    return '$count 位';
  }

  @override
  String get badge_grantees => '获得者';

  @override
  String get badge_myBadges => '我的徽章';

  @override
  String get badge_noGrantees => '暂无用户获得该徽章';

  @override
  String get badge_silver => '银牌';

  @override
  String get badge_silverBadge => '银牌徽章';

  @override
  String get myBadges_badgeUnit => '枚徽章';

  @override
  String get myBadges_empty => '暂无徽章';

  @override
  String get myBadges_title => '我的徽章';

  @override
  String get myBadges_totalEarned => '累计获得';

  @override
  String get bookmark_deleteConfirm => '确定要删除这个书签吗？';

  @override
  String get bookmark_editBookmark => '编辑书签';

  @override
  String get bookmark_nameHint => '为书签添加备注...';

  @override
  String get bookmark_nameLabel => '书签名称（可选）';

  @override
  String get bookmark_reminderCustom => '自定义';

  @override
  String get bookmark_reminderExpired => '提醒已过期';

  @override
  String get bookmark_reminderNextWeek => '下周';

  @override
  String get bookmark_reminderThreeDays => '3天后';

  @override
  String bookmark_reminderTime(String time) {
    return '提醒时间：$time';
  }

  @override
  String get bookmark_reminderTomorrow => '明天';

  @override
  String get bookmark_reminderTwoHours => '2小时后';

  @override
  String get bookmark_removed => '已取消书签';

  @override
  String get bookmark_setReminder => '设置提醒';

  @override
  String get bookmarks_cancelReminder => '取消提醒';

  @override
  String get bookmarks_deleted => '已删除书签';

  @override
  String get bookmarks_empty => '暂无书签';

  @override
  String get bookmarks_emptySearchHint => '输入关键词搜索书签';

  @override
  String get bookmarks_expired => ' 已过期';

  @override
  String get bookmarks_reminderCancelled => '已取消提醒';

  @override
  String get bookmarks_searchHint => '在书签中搜索...';

  @override
  String get bookmarks_title => '我的书签';

  @override
  String get readLater_title => '稍后阅读';

  @override
  String get categoryTopics_createPost => '发帖';

  @override
  String get categoryTopics_empty => '该分类下暂无话题';

  @override
  String get category_addHint => '点击下方分类添加到标签栏';

  @override
  String get category_allCategories => '全部分类';

  @override
  String get category_available => '可添加';

  @override
  String get category_browse => '浏览分类';

  @override
  String get category_dragHint => '拖拽排序，点击移除';

  @override
  String get category_editHint => '点击\"编辑\"添加常用分类到标签栏';

  @override
  String get category_editMyCategories => '编辑我的分类';

  @override
  String get category_levelMuted => '静音';

  @override
  String get category_levelMutedDesc => '不接收此分类的任何通知';

  @override
  String get category_levelRegular => '常规';

  @override
  String get category_levelRegularDesc => '只在被 @ 提及或回复时通知';

  @override
  String get category_levelTracking => '跟踪';

  @override
  String get category_levelTrackingDesc => '显示新帖未读计数';

  @override
  String get category_levelWatching => '关注';

  @override
  String get category_levelWatchingDesc => '每个新回复都通知';

  @override
  String get category_levelWatchingFirstPost => '关注新话题';

  @override
  String get category_levelWatchingFirstPostDesc => '此分类有新话题时通知';

  @override
  String category_loadFailed(String error) {
    return '加载分类失败: $error';
  }

  @override
  String get category_myCategories => '我的分类';

  @override
  String get category_noCategories => '暂无分类';

  @override
  String get category_noCategoriesFound => '未找到相关分类';

  @override
  String category_parentAll(String name) {
    return '$name（全部）';
  }

  @override
  String get category_searchHint => '搜索分类...';

  @override
  String get tagTopics_empty => '该标签下暂无话题';

  @override
  String tag_maxTagsReached(int max) {
    return '最多只能选择 $max 个标签';
  }

  @override
  String get tag_noTags => '暂无可用标签';

  @override
  String get tag_noTagsFound => '未找到相关标签';

  @override
  String tag_requiredGroupWarning(String name, int minCount) {
    return '需从 \"$name\" 标签组选择至少 $minCount 个标签';
  }

  @override
  String tag_requiredTagGroupHint(String name, int minCount) {
    return '需从 \"$name\" 选择至少 $minCount 个';
  }

  @override
  String get tag_searchHint => '搜索标签...';

  @override
  String tag_searchWithCount(int count) {
    return '搜索标签 (已选 $count)...';
  }

  @override
  String tag_searchWithMax(int selected, int max) {
    return '搜索标签 (已选 $selected/$max)...';
  }

  @override
  String tag_searchWithMin(int selected, int min) {
    return '搜索标签 (已选 $selected, 至少 $min)...';
  }

  @override
  String tag_topicCount(int count) {
    return '$count 个话题';
  }

  @override
  String get common_about => '关于';

  @override
  String get common_add => '添加';

  @override
  String get common_addBookmark => '添加书签';

  @override
  String get common_added => '已添加';

  @override
  String get common_all => '全部';

  @override
  String get common_allow => '允许';

  @override
  String get common_authExpired => '授权已过期';

  @override
  String get common_back => '返回';

  @override
  String get common_bookmarkAdded => '已添加书签';

  @override
  String get common_bookmarkRemoved => '已取消书签';

  @override
  String get common_bookmarkUpdated => '书签已更新';

  @override
  String get common_cancel => '取消';

  @override
  String get common_cannotOpenBrowser => '无法打开浏览器';

  @override
  String get common_checkInput => '请检查输入';

  @override
  String get common_checkNetworkRetry => '请检查网络后重试';

  @override
  String get common_clear => '清除';

  @override
  String common_clearFailed(String error) {
    return '清除失败: $error';
  }

  @override
  String get common_clipboardUnavailable => '剪贴板不可用';

  @override
  String get common_close => '关闭';

  @override
  String get common_closePreview => '关闭预览';

  @override
  String get common_codeCopied => '已复制代码';

  @override
  String get common_confirm => '确定';

  @override
  String get common_continue => '继续';

  @override
  String get common_continueVisit => '继续访问';

  @override
  String get common_copiedToClipboard => '已复制到剪贴板';

  @override
  String get common_copy => '复制';

  @override
  String get common_copyLink => '复制链接';

  @override
  String get common_copyQuote => '复制引用';

  @override
  String get common_custom => '自定义';

  @override
  String get common_decodeAvif => '解码 AVIF';

  @override
  String get common_delete => '删除';

  @override
  String get common_deleteBookmark => '删除书签';

  @override
  String get common_deleted => '已删除';

  @override
  String get common_deny => '拒绝';

  @override
  String get common_details => '详情';

  @override
  String get common_discard => '舍弃';

  @override
  String get common_done => '完成';

  @override
  String get common_edit => '编辑';

  @override
  String get common_editTopic => '编辑话题';

  @override
  String get common_enable => '开启';

  @override
  String get common_error => '发生错误';

  @override
  String get common_errorDetails => '错误详情';

  @override
  String get common_exit => '退出';

  @override
  String get common_exitPreview => '退出预览';

  @override
  String get common_export => '导出';

  @override
  String get common_failed => '失败';

  @override
  String get common_fillComplete => '请填写完整信息';

  @override
  String get common_filter => '筛选';

  @override
  String get common_gotIt => '知道了';

  @override
  String get common_help => '帮助';

  @override
  String get common_hint => '提示';

  @override
  String get common_import => '导入';

  @override
  String get common_later => '稍后';

  @override
  String get common_linkCopied => '链接已复制';

  @override
  String get common_loadFailed => '加载失败';

  @override
  String get common_loadFailedRetry => '加载失败，请重试';

  @override
  String get common_loadFailedTapRetry => '加载失败，点击重试';

  @override
  String get common_loading => '加载中...';

  @override
  String get common_loadingData => '加载数据...';

  @override
  String get common_login => '登录';

  @override
  String get common_logout => '退出登录';

  @override
  String get common_more => '更多';

  @override
  String get common_name => '名称';

  @override
  String get common_networkDisconnected => '网络连接已断开';

  @override
  String get common_noContent => '暂无内容';

  @override
  String get common_noData => '暂无数据';

  @override
  String get common_noMore => '没有更多了';

  @override
  String get common_notConfigured => '未配置';

  @override
  String get common_notSet => '未设置';

  @override
  String get common_notification => '通知';

  @override
  String get common_ok => '好';

  @override
  String common_operationFailed(String error) {
    return '操作失败：$error';
  }

  @override
  String get common_paste => '粘贴';

  @override
  String get common_pleaseLogin => '请先登录';

  @override
  String get common_pleaseWait => '请稍候...';

  @override
  String get common_preview => '预览';

  @override
  String get common_publish => '发布';

  @override
  String get common_quote => '引用';

  @override
  String get common_quoteCopied => '已复制引用';

  @override
  String get common_reAuth => '重新授权';

  @override
  String get common_recentlyUsed => '最近使用';

  @override
  String get common_redo => '重做';

  @override
  String get common_refresh => '刷新';

  @override
  String get common_remove => '移除';

  @override
  String get common_reply => '回复';

  @override
  String get common_report => '举报';

  @override
  String get common_reset => '重置';

  @override
  String get common_restore => '恢复';

  @override
  String get common_restoreDefault => '恢复默认';

  @override
  String get common_restored => '已恢复';

  @override
  String get common_retry => '重试';

  @override
  String get common_save => '保存';

  @override
  String get common_search => '搜索';

  @override
  String get common_searchHint => '搜索...';

  @override
  String get common_searchMore => '搜索更多';

  @override
  String get common_send => '发送';

  @override
  String get common_share => '分享';

  @override
  String get common_shareFailed => '分享失败，请重试';

  @override
  String get common_shareImage => '分享图片';

  @override
  String get common_shareLink => '分享链接';

  @override
  String common_sizeBytes(String size) {
    return '$size 字节';
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
  String get common_skip => '跳过';

  @override
  String get common_success => '成功';

  @override
  String get common_test => '测试';

  @override
  String get common_title => '标题';

  @override
  String get common_trustRequirements => '信任要求';

  @override
  String get common_understood => '我知道了';

  @override
  String get common_undo => '撤销';

  @override
  String get common_unknown => '未知';

  @override
  String get common_unknownError => '未知错误';

  @override
  String get common_upload => '上传';

  @override
  String get common_view => '查看';

  @override
  String get common_viewAll => '查看全部';

  @override
  String get common_viewDetails => '查看详情';

  @override
  String createTopic_charCount(int count) {
    return '$count 字符';
  }

  @override
  String get createTopic_confirmPublish => '确定发布';

  @override
  String get createTopic_contentHint => '正文内容 (支持 Markdown)...';

  @override
  String get createTopic_continueEditing => '继续编辑';

  @override
  String get createTopic_discardPost => '放弃帖子';

  @override
  String get createTopic_discardPostContent => '你想放弃你的帖子吗？';

  @override
  String get createTopic_enterContent => '请输入内容';

  @override
  String get createTopic_enterTitle => '请输入标题';

  @override
  String createTopic_loadCategoryFailed(String error) {
    return '加载分类失败: $error';
  }

  @override
  String createTopic_minContentLength(int min) {
    return '内容至少需要 $min 个字符';
  }

  @override
  String createTopic_minTags(int min) {
    return '此分类至少需要 $min 个标签';
  }

  @override
  String createTopic_minTitleLength(int min) {
    return '标题至少需要 $min 个字符';
  }

  @override
  String get createTopic_noContent => '（无内容）';

  @override
  String get createTopic_noTitle => '（无标题）';

  @override
  String get createTopic_pendingReview => '你的帖子已提交，正在等待审核';

  @override
  String get createTopic_restoreDraft => '恢复草稿';

  @override
  String get createTopic_restoreDraftContent => '检测到未发送的草稿，是否恢复？';

  @override
  String get createTopic_selectCategory => '请选择分类';

  @override
  String get createTopic_templateNotModified => '您尚未修改分类模板内容，确定要发布吗？';

  @override
  String get createTopic_title => '创建话题';

  @override
  String get createTopic_titleHint => '键入一个吸引人的标题...';

  @override
  String get editTopic_editPm => '编辑私信';

  @override
  String get editTopic_editTopic => '编辑话题';

  @override
  String editTopic_loadContentFailed(String error) {
    return '加载内容失败: $error';
  }

  @override
  String get backup_invalidFormat => '无效的备份文件格式';

  @override
  String get backup_missingDataField => '备份文件格式错误：缺少 data 字段';

  @override
  String get dataManagement_aiChatCleared => 'AI 聊天数据已清除';

  @override
  String get dataManagement_aiChatData => 'AI 聊天数据';

  @override
  String get dataManagement_allCleared => '所有缓存已清除，请重新登录';

  @override
  String dataManagement_apiKeysCount(int count) {
    return '包含 $count 个 API Key';
  }

  @override
  String get dataManagement_autoManagement => '自动管理';

  @override
  String dataManagement_backupSource(String version) {
    return '备份来源: v$version';
  }

  @override
  String get dataManagement_backupSubject => 'FluxDO 数据备份';

  @override
  String get dataManagement_cacheManagement => '缓存管理';

  @override
  String get dataManagement_calculating => '计算中...';

  @override
  String get dataManagement_clearAiChatContent => '将删除所有 AI 聊天记录，此操作不可恢复。';

  @override
  String get dataManagement_clearAiChatTitle => '清除 AI 聊天数据';

  @override
  String get dataManagement_clearAll => '全部清除';

  @override
  String get dataManagement_clearAllCache => '清除所有缓存';

  @override
  String get dataManagement_clearAllContent =>
      '将清除所有缓存数据，包括图片缓存、AI 聊天数据和 Cookie。\n\n清除 Cookie 后需要重新登录。';

  @override
  String get dataManagement_clearAllTitle => '清除所有缓存';

  @override
  String get dataManagement_clearAndLogout => '清除并退出登录';

  @override
  String get dataManagement_clearCookieContent => '清除 Cookie 后需要重新登录，确定要继续吗？';

  @override
  String get dataManagement_clearCookieTitle => '清除 Cookie 缓存';

  @override
  String get dataManagement_clearOnExit => '退出时清除图片缓存';

  @override
  String get dataManagement_clearOnExitDesc => '下次启动时自动清除图片缓存';

  @override
  String get dataManagement_confirmImport => '确认导入';

  @override
  String get dataManagement_cookieCache => 'Cookie 缓存';

  @override
  String get dataManagement_cookieCleared => 'Cookie 缓存已清除，请重新登录';

  @override
  String get dataManagement_dataBackup => '数据备份';

  @override
  String get dataManagement_exportData => '导出数据';

  @override
  String get dataManagement_exportDesc => '将偏好设置导出为文件';

  @override
  String dataManagement_exportFailed(String error) {
    return '导出失败: $error';
  }

  @override
  String dataManagement_exportTime(String time) {
    return '导出时间: $time';
  }

  @override
  String get dataManagement_imageCache => '图片缓存';

  @override
  String get dataManagement_imageCacheCleared => '图片缓存已清除';

  @override
  String get dataManagement_importAndRestart => '导入并重启';

  @override
  String get dataManagement_importData => '导入数据';

  @override
  String get dataManagement_importDesc => '从备份文件恢复偏好设置';

  @override
  String dataManagement_importFailed(String error) {
    return '导入失败: $error';
  }

  @override
  String get dataManagement_importSuccess => '数据已导入，请重启应用';

  @override
  String get dataManagement_importWarning => '导入后将覆盖当前对应的设置项，需要重启应用生效。';

  @override
  String get dataManagement_noCache => '无缓存';

  @override
  String dataManagement_settingsCount(int count) {
    return '包含 $count 项设置';
  }

  @override
  String get dataManagement_title => '数据管理';

  @override
  String get appLogs_appStart => '应用启动';

  @override
  String get appLogs_clearContent => '确定要清除所有日志吗？此操作不可撤销。';

  @override
  String get appLogs_clearLogs => '清除日志';

  @override
  String get appLogs_clearTitle => '清除日志';

  @override
  String get appLogs_copyAll => '复制全部';

  @override
  String get appLogs_copyDeviceInfo => '复制设备信息';

  @override
  String get appLogs_duration => '耗时';

  @override
  String get appLogs_error => '错误';

  @override
  String get appLogs_errorType => '错误类型';

  @override
  String get appLogs_event => '事件';

  @override
  String get appLogs_feedbackSending => '正在发送反馈…';

  @override
  String get appLogs_feedbackSent => '反馈已发送';

  @override
  String get appLogs_feedbackTitle => '应用日志反馈';

  @override
  String get appLogs_level => '级别';

  @override
  String get appLogs_lifecycle => '生命周期';

  @override
  String get appLogs_lifecycleEvent => '生命周期事件';

  @override
  String get appLogs_logoutActive => '主动退出';

  @override
  String get appLogs_logoutPassive => '被动退出';

  @override
  String get appLogs_logsCleared => '日志已清除';

  @override
  String get appLogs_message => '消息';

  @override
  String get appLogs_method => '方法';

  @override
  String get appLogs_noLogs => '暂无日志';

  @override
  String get appLogs_noMatchingLogs => '无匹配日志';

  @override
  String get appLogs_reason => '原因';

  @override
  String get appLogs_request => '请求';

  @override
  String get appLogs_sendFeedback => '私信反馈日志';

  @override
  String get appLogs_shareLogs => '分享日志';

  @override
  String get appLogs_shareSubject => '应用日志';

  @override
  String get appLogs_stack => '堆栈';

  @override
  String get appLogs_stackTrace => '堆栈跟踪';

  @override
  String get appLogs_statusCode => '状态码';

  @override
  String get appLogs_tag => '标签';

  @override
  String get appLogs_time => '时间';

  @override
  String get appLogs_title => '应用日志';

  @override
  String get appLogs_type => '类型';

  @override
  String get appLogs_user => '用户';

  @override
  String get appLogs_userLogin => '用户登录';

  @override
  String get appLogs_version => '版本';

  @override
  String get debugTools_cfLogs => 'CF 验证日志';

  @override
  String get debugTools_cfLogsCleared => 'CF 日志已清除';

  @override
  String get debugTools_cfLogsDesc => '查看 Cloudflare 验证详情';

  @override
  String get debugTools_cfLogsTitle => 'CF 验证日志';

  @override
  String get debugTools_clearCfLogs => '清除 CF 日志';

  @override
  String get debugTools_clearCfLogsConfirm => '确定要清除所有 CF 验证日志吗？';

  @override
  String get debugTools_clearCfLogsTitle => '清除 CF 日志';

  @override
  String get debugTools_clearLogs => '清除日志';

  @override
  String get debugTools_clearLogsConfirm => '确定要清除所有日志吗？';

  @override
  String get debugTools_clearLogsTitle => '清除日志';

  @override
  String get debugTools_debugLogs => '调试日志';

  @override
  String get debugTools_exportCfLogs => '导出 CF 日志';

  @override
  String get debugTools_logsCleared => '日志已清除';

  @override
  String get debugTools_noCfLogs => '暂无 CF 验证日志';

  @override
  String get debugTools_noCfLogsHint => '触发 CF 验证后会产生日志';

  @override
  String get debugTools_noCfLogsToShare => '暂无 CF 日志可分享';

  @override
  String get debugTools_noLogs => '暂无日志';

  @override
  String get debugTools_noLogsHint => '启用 DOH 并发起请求后会产生日志';

  @override
  String get debugTools_noLogsToShare => '暂无日志可分享';

  @override
  String get debugTools_shareLogs => '分享日志';

  @override
  String get debugTools_viewLogs => '查看日志';

  @override
  String get dohDetail_addServer => '添加服务器';

  @override
  String get dohDetail_bootstrapIpHelper => '直接用 IP 连接 DoH 服务器，绕过 DNS 解析';

  @override
  String get dohDetail_bootstrapIpHint => '用逗号分隔，如 1.1.1.1, 1.0.0.1';

  @override
  String get dohDetail_bootstrapIpOptional => 'Bootstrap IP（可选）';

  @override
  String get dohDetail_clearCache => '清空缓存';

  @override
  String dohDetail_clearDnsCacheFailed(String error) {
    return '清空 DNS 缓存失败: $error';
  }

  @override
  String get dohDetail_copyAddress => '复制地址';

  @override
  String get dohDetail_deleteServer => '删除服务器';

  @override
  String dohDetail_deleteServerConfirm(String name) {
    return '确定要删除 \"$name\" 吗？';
  }

  @override
  String get dohDetail_dnsCacheCleared => 'DNS 缓存已清空';

  @override
  String dohDetail_dnsCacheDesc(int count) {
    return '当前已缓存 $count 个域名。代理模式和查询模式共用缓存，TTL 临近到期会后台刷新。';
  }

  @override
  String dohDetail_dnsCacheRefreshed(int count) {
    return 'DNS 缓存已强制刷新（$count 个域名）';
  }

  @override
  String get dohDetail_dnsCacheRefreshedSimple => 'DNS 缓存已强制刷新';

  @override
  String get dohDetail_dnsCacheSection => 'DNS 缓存';

  @override
  String get dohDetail_dohAddress => 'DoH 地址';

  @override
  String get dohDetail_dohAddressCopied => '已复制 DoH 地址';

  @override
  String get dohDetail_echSameAsDnsDesc => '使用 DNS 解析服务器查询 ECH 配置';

  @override
  String get dohDetail_echServer => 'ECH 服务器';

  @override
  String get dohDetail_editServer => '编辑服务器';

  @override
  String get dohDetail_exampleDns => '例如：My DNS';

  @override
  String get dohDetail_forceRefresh => '强制刷新';

  @override
  String get dohDetail_gatewayDisabledDesc => '已关闭，使用 MITM 双重 TLS';

  @override
  String get dohDetail_gatewayEnabledDesc => '单次 TLS，通过反向代理转发';

  @override
  String get dohDetail_gatewayMode => 'Gateway 模式';

  @override
  String get dohDetail_ipAddress => 'IP 地址';

  @override
  String get dohDetail_ipv6Prefer => 'IPv6 优先';

  @override
  String get dohDetail_ipv6PreferDesc => '优先尝试 IPv6，失败自动回落 IPv4';

  @override
  String get dohDetail_localDnsCache => '共享本地 DNS 缓存';

  @override
  String get dohDetail_noServers => '暂无服务器';

  @override
  String get dohDetail_processing => '处理中';

  @override
  String dohDetail_refreshDnsCacheFailed(String error) {
    return '强制刷新 DNS 缓存失败: $error';
  }

  @override
  String get dohDetail_sameAsDns => '与 DNS 相同';

  @override
  String get dohDetail_selectEchServer => '选择 ECH 服务器';

  @override
  String get dohDetail_serverIp => '服务端 IP';

  @override
  String get dohDetail_serverIpHint => '指定连接 IP，跳过 DNS 解析';

  @override
  String get dohDetail_servers => '服务器';

  @override
  String get dohDetail_testAllSpeed => '全部测速';

  @override
  String get dohDetail_testSpeed => '测速';

  @override
  String get dohDetail_testingSpeed => '测速中';

  @override
  String get dohDetail_title => 'DOH 详细设置';

  @override
  String get dohDetail_urlMustHttps => '地址必须以 https:// 开头';

  @override
  String get dohSettings_certAllDone => '已完成所有步骤';

  @override
  String get dohSettings_certDialogDesc => 'HTTPS 拦截需要安装并信任 CA 证书，每台设备生成唯一证书';

  @override
  String get dohSettings_certDialogTitle => 'CA 证书安装';

  @override
  String get dohSettings_certDownloadFailed => '描述文件下载失败';

  @override
  String get dohSettings_certDownloadHint => '点击下方按钮，Safari 会弹出下载提示，请点击\"允许\"。';

  @override
  String get dohSettings_certDownloadProfile => '下载描述文件';

  @override
  String get dohSettings_certInstall => '安装';

  @override
  String get dohSettings_certInstallHint => 'HTTPS 拦截需要安装并信任证书';

  @override
  String get dohSettings_certInstallProfileHint =>
      '前往 设置 → 通用 → VPN与设备管理，找到 DOH Proxy CA 描述文件并安装。';

  @override
  String get dohSettings_certInstalled => 'CA 证书已安装';

  @override
  String get dohSettings_certInstalledNext => '已安装，下一步';

  @override
  String get dohSettings_certOpenSettings => '打开设置';

  @override
  String get dohSettings_certPreparing => '正在准备...';

  @override
  String get dohSettings_certRegenerate => '重新生成证书';

  @override
  String get dohSettings_certRegenerateFailed => '证书重新生成失败';

  @override
  String get dohSettings_certRegenerated => '新证书已生成';

  @override
  String get dohSettings_certReinstall => '重新安装';

  @override
  String get dohSettings_certReinstallHint => '点击可重新安装或更换证书';

  @override
  String get dohSettings_certRequired => '需要安装 CA 证书';

  @override
  String get dohSettings_certStepDownload => '下载描述文件';

  @override
  String get dohSettings_certStepInstall => '安装描述文件';

  @override
  String get dohSettings_certStepTrust => '信任证书';

  @override
  String get dohSettings_certTrustHint =>
      '前往 设置 → 通用 → 关于本机 → 证书信任设置，开启 DOH Proxy CA 的信任开关。';

  @override
  String get dohSettings_disabledDesc => '使用系统默认 DNS';

  @override
  String get dohSettings_enabledDesc => '已启用加密 DNS 解析';

  @override
  String get dohSettings_errorCopied => '已复制错误信息';

  @override
  String get dohSettings_moreSettings => '更多设置';

  @override
  String get dohSettings_moreSettingsDesc => '服务器、IPv6、ECH 等';

  @override
  String get dohSettings_perDeviceCert => '设备独有证书';

  @override
  String get dohSettings_perDeviceCertDisabledDesc => '启用后每台设备生成独立的 CA 证书，更安全';

  @override
  String get dohSettings_perDeviceCertEnabledDesc => '已启用，每台设备使用独立 CA 证书';

  @override
  String dohSettings_port(int port) {
    return '端口 $port';
  }

  @override
  String get dohSettings_proxyNotStarted => '代理未启动';

  @override
  String get dohSettings_proxyRunning => '代理运行中';

  @override
  String get dohSettings_proxyStartFailed => '代理启动失败，DoH/ECH 无法生效';

  @override
  String get dohSettings_restartProxy => '重启代理';

  @override
  String get dohSettings_restarting => '正在重启...';

  @override
  String get dohSettings_starting => '正在启动...';

  @override
  String get dohSettings_suppressedByVpn => '已被 VPN 自动关闭，VPN 断开后将自动恢复';

  @override
  String get doh_cannotConnect => '无法连接到 DOH 服务';

  @override
  String get doh_executableNotFound => '找不到代理可执行文件';

  @override
  String get doh_invalidHttpResponse => '无效的 HTTP 响应';

  @override
  String get doh_queryFailed => 'DOH 查询失败';

  @override
  String get doh_serverAlibaba => '阿里 DNS';

  @override
  String doh_serverError(String statusLine) {
    return 'DOH 服务器返回错误: $statusLine';
  }

  @override
  String get doh_serverTencent => '腾讯 DNS';

  @override
  String get doh_startTimeout => '代理启动超时（5秒内未响应）';

  @override
  String get doh_unknownReason => '未知原因';

  @override
  String get codeBlock_chart => '图表';

  @override
  String get codeBlock_chartLoadFailed => '图表加载失败';

  @override
  String get codeBlock_code => '代码';

  @override
  String codeBlock_renderFailed(String error) {
    return '代码块渲染失败: $error';
  }

  @override
  String draft_topicTitle(String id) {
    return '话题 #$id';
  }

  @override
  String get draft_untitled => '无标题';

  @override
  String get drafts_deleteContent => '确定要删除这个草稿吗？';

  @override
  String get drafts_deleteDraft => '删除草稿';

  @override
  String drafts_deleteFailed(String error) {
    return '删除失败: $error';
  }

  @override
  String get drafts_deleteTitle => '删除草稿';

  @override
  String get drafts_deleted => '草稿已删除';

  @override
  String get drafts_draft => '草稿';

  @override
  String get drafts_empty => '暂无草稿';

  @override
  String get drafts_newTopic => '新话题';

  @override
  String get drafts_pmIncomplete => '私信草稿数据不完整';

  @override
  String get drafts_privateMessage => '私信';

  @override
  String drafts_replyToPost(int number) {
    return '回复 #$number';
  }

  @override
  String get drafts_title => '我的草稿';

  @override
  String get editor_hintText => '说点什么吧... (支持 Markdown)';

  @override
  String get editor_noContent => '（无内容）';

  @override
  String get link_insertTitle => '插入链接';

  @override
  String get link_textHint => '显示的文字';

  @override
  String get link_textLabel => '链接文本';

  @override
  String get link_textRequired => '请输入链接文本';

  @override
  String get link_urlRequired => '请输入 URL';

  @override
  String get mention_group => '群组';

  @override
  String get mention_noUserFound => '未找到匹配用户';

  @override
  String get mention_searchHint => '输入用户名搜索';

  @override
  String get template_empty => '暂无可用模板';

  @override
  String get template_insertTitle => '插入模板';

  @override
  String get template_loadError => '加载模板失败';

  @override
  String get template_searchHint => '搜索模板…';

  @override
  String get template_tooltip => '模板';

  @override
  String get toolbar_attachFileTooltip => '上传附件';

  @override
  String get toolbar_boldPlaceholder => '粗体文本';

  @override
  String get toolbar_codePlaceholder => '在此处键入或粘贴代码';

  @override
  String get toolbar_gridMinImages => '需要至少 2 张图片才能创建网格';

  @override
  String get toolbar_gridNeedConsecutive => '需要至少 2 张连续的图片才能创建网格';

  @override
  String get toolbar_h1 => 'H1 - 一级标题';

  @override
  String get toolbar_h2 => 'H2 - 二级标题';

  @override
  String get toolbar_h3 => 'H3 - 三级标题';

  @override
  String get toolbar_h4 => 'H4 - 四级标题';

  @override
  String get toolbar_h5 => 'H5 - 五级标题';

  @override
  String get toolbar_imageGridTooltip => '图片网格';

  @override
  String get toolbar_imagesAlreadyInGrid => '这些图片已经在网格中了';

  @override
  String get toolbar_italicPlaceholder => '斜体文本';

  @override
  String get toolbar_mixOptimize => '混排优化';

  @override
  String get toolbar_quotePlaceholder => '引用文本';

  @override
  String get toolbar_spoilerPlaceholder => '剧透内容';

  @override
  String get toolbar_spoilerTooltip => '剧透';

  @override
  String get toolbar_strikethroughPlaceholder => '删除线文本';

  @override
  String get emoji_activities => '活动';

  @override
  String get emoji_animals => '动物';

  @override
  String get emoji_flags => '旗帜';

  @override
  String get emoji_food => '食物';

  @override
  String get emoji_loadFailed => '加载表情失败';

  @override
  String get emoji_notFound => '没有找到表情';

  @override
  String get emoji_objects => '物体';

  @override
  String get emoji_people => '人物';

  @override
  String get emoji_searchHint => '搜索表情...';

  @override
  String get emoji_searchNotFound => '未找到相关表情';

  @override
  String get emoji_searchPrompt => '输入关键词搜索表情';

  @override
  String get emoji_searchTooltip => '搜索表情';

  @override
  String get emoji_smileys => '表情';

  @override
  String get emoji_symbols => '符号';

  @override
  String get emoji_tab => '表情';

  @override
  String get emoji_travel => '旅行';

  @override
  String get sticker_addFromMarket => '从市场添加';

  @override
  String get sticker_addTooltip => '添加表情包';

  @override
  String get sticker_added => '已添加';

  @override
  String sticker_emojiCount(int count) {
    return '$count 个表情';
  }

  @override
  String get sticker_groupEmpty => '该分组暂无表情包';

  @override
  String get sticker_loadFailed => '加载表情包失败';

  @override
  String get sticker_marketEmpty => '暂无可用的表情包';

  @override
  String get sticker_marketLoadFailed => '加载市场失败';

  @override
  String get sticker_marketTitle => '表情包市场';

  @override
  String get sticker_noStickers => '还没有表情包';

  @override
  String get sticker_tab => '表情包';

  @override
  String get error_addBookmarkFailed => '添加书签失败：响应格式异常';

  @override
  String get error_avifDecodeNoFrames => 'AVIF 解码失败：无帧数据';

  @override
  String get error_badRequest => '请求错误';

  @override
  String get error_badRequestParams => '请求参数错误';

  @override
  String get error_cannotConnectCheckNetwork => '无法在规定时间内连接到服务器，请检查网络';

  @override
  String get error_certificateError => '证书异常';

  @override
  String get error_certificateVerifyFailed => '服务器证书验证失败，请检查网络环境';

  @override
  String get error_connectionTimeout => '连接超时';

  @override
  String get error_contentDeleted => '内容已被删除';

  @override
  String get error_createTopicFailed => '创建话题失败';

  @override
  String get error_dataException => '数据异常';

  @override
  String get error_forbidden => '没有权限';

  @override
  String get error_forbiddenAccess => '没有权限访问';

  @override
  String get error_gone => '已删除';

  @override
  String get error_imageFormatUnsupported => '图片格式不支持或不符合要求';

  @override
  String get error_imageTooBig => '图片文件过大，请压缩后重试';

  @override
  String get error_internalServerError => '服务器内部错误';

  @override
  String get error_loadFailed => '加载失败';

  @override
  String get error_networkCheckSettings => '网络连接失败，请检查网络设置';

  @override
  String get error_networkRequestFailed => '网络请求失败';

  @override
  String get error_networkUnavailable => '网络不可用';

  @override
  String get error_notFound => '内容不存在';

  @override
  String get error_notFoundOrDeleted => '内容不存在或已被删除';

  @override
  String get error_notLoggedInNoUsername => '未登录或无法获取用户名';

  @override
  String get error_providerDisposed => 'Provider 已销毁';

  @override
  String get error_rateLimited => '请求过于频繁';

  @override
  String get error_rateLimitedRetryLater => '请求过于频繁，请稍后再试';

  @override
  String get error_replyFailed => '回复失败';

  @override
  String get error_requestCancelled => '请求取消';

  @override
  String get error_requestCancelledMsg => '请求已取消';

  @override
  String get error_requestFailed => '请求失败';

  @override
  String error_requestFailedWithCode(int statusCode) {
    return '请求失败 ($statusCode)';
  }

  @override
  String get error_requestTimeoutRetry => '请求超时，请稍后重试';

  @override
  String get error_requestUnprocessable => '请求无法处理';

  @override
  String get error_responseTimeout => '响应超时';

  @override
  String get error_securityChallenge => '安全验证';

  @override
  String get error_sendPMFailed => '发送私信失败';

  @override
  String get error_serverError => '服务器错误';

  @override
  String get error_serverResponseTooLong => '服务器响应时间过长，请稍后重试';

  @override
  String get error_serverUnavailable => '服务器不可用';

  @override
  String get error_serviceUnavailable => '服务器不可用';

  @override
  String get error_serviceUnavailableRetry => '服务器暂时不可用，请稍后重试';

  @override
  String get error_tooManyRequests => '请求过于频繁';

  @override
  String get error_topicDetailEmpty => '话题详情为空';

  @override
  String get error_unauthorized => '未登录';

  @override
  String get error_unauthorizedExpired => '未登录或登录已过期';

  @override
  String get error_unknown => '未知错误';

  @override
  String get error_unknownResponseFormat => '未知响应格式';

  @override
  String get error_unprocessable => '无法处理';

  @override
  String get error_unrecognizedDataFormat => '服务器返回了无法识别的数据格式';

  @override
  String get error_updatePostFailed => '更新帖子失败：响应格式异常';

  @override
  String get error_uploadNoUrl => '上传响应中未包含 URL';

  @override
  String get browsingHistory_empty => '暂无浏览历史';

  @override
  String get browsingHistory_emptySearchHint => '输入关键词搜索浏览历史';

  @override
  String get browsingHistory_searchHint => '在浏览历史中搜索...';

  @override
  String get browsingHistory_title => '浏览历史';

  @override
  String get myTopics_empty => '暂无话题';

  @override
  String get myTopics_emptySearchHint => '输入关键词搜索我的话题';

  @override
  String get myTopics_searchHint => '在我的话题中搜索...';

  @override
  String get myTopics_title => '我的话题';

  @override
  String get imageEditor_adjust => '调整';

  @override
  String get imageEditor_applyingChanges => '正在应用更改';

  @override
  String get imageEditor_arrow => '箭头';

  @override
  String get imageEditor_arrowBoth => '双端箭头';

  @override
  String get imageEditor_arrowEnd => '终点箭头';

  @override
  String get imageEditor_arrowStart => '起点箭头';

  @override
  String get imageEditor_bgMode => '背景模式';

  @override
  String get imageEditor_blur => '模糊';

  @override
  String get imageEditor_brightness => '亮度';

  @override
  String get imageEditor_brush => '画笔';

  @override
  String get imageEditor_changeOpacity => '调整透明度';

  @override
  String get imageEditor_circle => '圆形';

  @override
  String get imageEditor_closeWarningMessage => '确定要关闭图片编辑器吗？你的更改将不会被保存。';

  @override
  String get imageEditor_closeWarningTitle => '关闭图片编辑器？';

  @override
  String get imageEditor_color => '颜色';

  @override
  String get imageEditor_contrast => '对比度';

  @override
  String get imageEditor_cropRotate => '裁剪/旋转';

  @override
  String get imageEditor_dashDotLine => '点划线';

  @override
  String get imageEditor_dashLine => '虚线';

  @override
  String get imageEditor_emoji => '表情';

  @override
  String get imageEditor_emojiActivities => '活动';

  @override
  String get imageEditor_emojiAnimals => '动物与自然';

  @override
  String get imageEditor_emojiFlags => '旗帜';

  @override
  String get imageEditor_emojiFood => '食物与饮品';

  @override
  String get imageEditor_emojiObjects => '物品';

  @override
  String get imageEditor_emojiSmileys => '笑脸与人物';

  @override
  String get imageEditor_emojiSymbols => '符号';

  @override
  String get imageEditor_emojiTravel => '旅行与地点';

  @override
  String get imageEditor_eraser => '橡皮擦';

  @override
  String get imageEditor_exposure => '曝光';

  @override
  String get imageEditor_fade => '褪色';

  @override
  String get imageEditor_fill => '填充';

  @override
  String get imageEditor_filter => '滤镜';

  @override
  String get imageEditor_flip => '翻转';

  @override
  String get imageEditor_fontSize => '字体大小';

  @override
  String get imageEditor_freeStyle => '自由绘制';

  @override
  String get imageEditor_hexagon => '六边形';

  @override
  String get imageEditor_hue => '色调';

  @override
  String get imageEditor_initializingEditor => '正在初始化编辑器';

  @override
  String get imageEditor_inputText => '输入文字';

  @override
  String get imageEditor_line => '直线';

  @override
  String get imageEditor_lineWidth => '线条宽度';

  @override
  String get imageEditor_luminance => '明度';

  @override
  String get imageEditor_noFilter => '无滤镜';

  @override
  String get imageEditor_opacity => '透明度';

  @override
  String get imageEditor_pixelate => '像素化';

  @override
  String get imageEditor_polygon => '多边形';

  @override
  String get imageEditor_ratio => '比例';

  @override
  String get imageEditor_rectangle => '矩形';

  @override
  String get imageEditor_rotate => '旋转';

  @override
  String get imageEditor_rotateScale => '旋转和缩放';

  @override
  String get imageEditor_saturation => '饱和度';

  @override
  String get imageEditor_sharpness => '锐度';

  @override
  String get imageEditor_sticker => '贴纸';

  @override
  String get imageEditor_strokeWidth => '线条粗细';

  @override
  String get imageEditor_temperature => '色温';

  @override
  String get imageEditor_text => '文字';

  @override
  String get imageEditor_textAlign => '文字对齐';

  @override
  String get imageEditor_toggleFill => '切换填充';

  @override
  String get imageEditor_zoom => '缩放';

  @override
  String get imageFormat_generic => '图片';

  @override
  String get imageFormat_gif => 'GIF 动图';

  @override
  String get imageFormat_jpeg => 'JPEG 图片';

  @override
  String get imageFormat_png => 'PNG 图片';

  @override
  String get imageFormat_webp => 'WebP 图片';

  @override
  String get imageUpload_compressionQuality => '压缩质量：';

  @override
  String get imageUpload_confirmTitle => '上传图片确认';

  @override
  String get imageUpload_editImage => '编辑图片';

  @override
  String imageUpload_editNotSupported(String format) {
    return '$format 暂不支持编辑，否则会丢失动画';
  }

  @override
  String get imageUpload_editNotSupportedLabel => '当前格式不支持编辑';

  @override
  String imageUpload_estimatedSize(String size) {
    return '约 $size';
  }

  @override
  String get imageUpload_gridLayoutHint => '上传后将自动使用 [grid] 网格布局';

  @override
  String get imageUpload_keepAtLeastOne => '至少需要保留一张图片';

  @override
  String imageUpload_keepOriginal(String format) {
    return '$format 将保留原图上传，不执行客户端压缩。';
  }

  @override
  String imageUpload_multiTitle(int count) {
    return '上传 $count 张图片';
  }

  @override
  String imageUpload_originalSize(String size) {
    return '原始大小：$size';
  }

  @override
  String imageUpload_processFailed(String error) {
    return '处理图片失败: $error';
  }

  @override
  String imageUpload_totalEstimatedSize(String size) {
    return '约 $size';
  }

  @override
  String imageUpload_totalOriginalSize(String size) {
    return '总大小：$size';
  }

  @override
  String imageUpload_uploadCount(int count) {
    return '上传 $count 张';
  }

  @override
  String get imageViewer_grantPermission => '请授予相册访问权限';

  @override
  String get imageViewer_imageSaved => '图片已保存到相册';

  @override
  String imageViewer_saveFailed(String error) {
    return '保存失败: $error';
  }

  @override
  String get imageViewer_saveFailedRetry => '保存失败，请重试';

  @override
  String get image_copied => '图片已复制';

  @override
  String get image_copyFailed => '复制图片失败';

  @override
  String get image_copyImage => '复制图片';

  @override
  String get image_copyLink => '复制链接';

  @override
  String get image_fetchFailed => '获取图片失败';

  @override
  String get image_viewFull => '查看大图';

  @override
  String get invite_collapseOptions => '收起链接选项';

  @override
  String get invite_createFailed => '生成邀请链接失败';

  @override
  String get invite_createLink => '创建邀请链接';

  @override
  String get invite_created => '邀请已创建';

  @override
  String get invite_creating => '创建中...';

  @override
  String get invite_description => '描述 (可选)';

  @override
  String get invite_expandOptions => '编辑链接选项或通过电子邮件发送。';

  @override
  String invite_expiryDate(String date) {
    return '截止 $date';
  }

  @override
  String get invite_expiryTime => '有效截止时间';

  @override
  String get invite_fixed => '固定';

  @override
  String get invite_inviteMembers => '邀请成员';

  @override
  String get invite_latestResult => '最新生成结果';

  @override
  String get invite_linkCopied => '邀请链接已复制';

  @override
  String get invite_linkGenerated => '邀请链接已生成';

  @override
  String get invite_maxRedemptions => '最大使用次数';

  @override
  String get invite_never => '从不';

  @override
  String get invite_noExpiry => '无过期时间';

  @override
  String get invite_noLinks => '暂无生成邀请链接';

  @override
  String get invite_permissionDenied => '服务端拒绝了当前账号的邀请权限';

  @override
  String invite_rateLimited(String waitText) {
    return '出错了：您执行此操作的次数过多。请等待 $waitText 后再试。';
  }

  @override
  String get invite_restriction => '限制为 (可选)';

  @override
  String get invite_restrictionHelper => '填写邮箱或域名';

  @override
  String get invite_restrictionHint => 'name@example.com 或者 example.com';

  @override
  String get invite_shareSubject => 'Linux.do 邀请链接';

  @override
  String get invite_summaryDay1 => '链接最多可用于 1 个用户，并且将在 1 天后到期。';

  @override
  String invite_summaryExpiry(String expiry) {
    return '链接最多可用于 1 个用户，并且将在 $expiry 后到期。';
  }

  @override
  String get invite_summaryNever => '链接最多可用于 1 个用户，并且永不过期。';

  @override
  String get invite_title => '邀请链接';

  @override
  String get invite_trustLevelTooLow => '当前账号尚未达到 L3，无法创建邀请链接';

  @override
  String invite_usableCount(int count) {
    return '可用 $count 次';
  }

  @override
  String get appLink_alipay => '支付宝';

  @override
  String get appLink_amap => '高德地图';

  @override
  String get appLink_baidu => '百度';

  @override
  String get appLink_baiduNetdisk => '百度网盘';

  @override
  String appLink_continueVisitConfirm(String name) {
    return '继续访问$name？';
  }

  @override
  String get appLink_ctrip => '携程';

  @override
  String get appLink_dianping => '大众点评';

  @override
  String get appLink_dingtalk => '钉钉';

  @override
  String get appLink_douban => '豆瓣';

  @override
  String get appLink_douyin => '抖音';

  @override
  String get appLink_eleme => '饿了么';

  @override
  String get appLink_email => '邮件';

  @override
  String get appLink_externalApp => '外部应用';

  @override
  String get appLink_fliggy => '飞猪';

  @override
  String get appLink_jd => '京东';

  @override
  String get appLink_kuaishou => '快手';

  @override
  String get appLink_map => '地图';

  @override
  String get appLink_meituan => '美团';

  @override
  String get appLink_meituanWaimai => '美团外卖';

  @override
  String appLink_openAppConfirm(String name) {
    return '此网站想打开$name应用';
  }

  @override
  String get appLink_phone => '电话';

  @override
  String get appLink_pinduoduo => '拼多多';

  @override
  String get appLink_playStore => 'Play 商店';

  @override
  String get appLink_qqMap => '腾讯地图';

  @override
  String get appLink_sms => '短信';

  @override
  String get appLink_suning => '苏宁';

  @override
  String get appLink_taobao => '淘宝';

  @override
  String get appLink_toutiao => '今日头条';

  @override
  String get appLink_weibo => '微博';

  @override
  String get appLink_weixin => '微信';

  @override
  String get appLink_xiaohongshu => '小红书';

  @override
  String get appLink_zhihu => '知乎';

  @override
  String get externalLink_blocked => '链接已被阻止';

  @override
  String get externalLink_blockedMessage => '此链接已被列入黑名单，无法访问';

  @override
  String get externalLink_contactAdmin => '如有疑问，请联系站点管理员';

  @override
  String get externalLink_leavingMessage => '您即将访问外部网站';

  @override
  String get externalLink_leavingTitle => '即将离开';

  @override
  String get externalLink_securityWarningHint => '可能包含推广内容或存在安全隐患，请谨慎访问';

  @override
  String get externalLink_securityWarningMessage => '此链接被标记为潜在风险链接';

  @override
  String get externalLink_securityWarningTitle => '安全警告';

  @override
  String get externalLink_shortLinkMessage => '此链接为短链接服务，无法预览真实目标';

  @override
  String get externalLink_shortLinkTitle => '短链接提醒';

  @override
  String get externalLink_shortLinkWarning => '短链接可能隐藏真实目的地，请确认来源可信';

  @override
  String get iframe_exitInteraction => '退出交互';

  @override
  String get onebox_linkPreview => '链接预览';

  @override
  String get chat_thread => '线程';

  @override
  String get github_commentedOn => ' 评论于 ';

  @override
  String github_moreFiles(int count) {
    return '... 还有 $count 个文件';
  }

  @override
  String get github_viewFullCode => '点击查看完整代码';

  @override
  String metaverse_authFailed(String error) {
    return '授权失败: $error';
  }

  @override
  String get metaverse_cdkAuthSuccess => 'CDK 授权成功';

  @override
  String get metaverse_cdkDesc => '连接账户，开启 CDK 权益';

  @override
  String get metaverse_cdkReauthSuccess => 'CDK 重新授权成功';

  @override
  String get metaverse_cdkService => 'CDK 服务';

  @override
  String get metaverse_comingSoon => '更多服务接入中...';

  @override
  String get metaverse_ldcAuthSuccess => 'LDC 授权成功';

  @override
  String get metaverse_ldcDesc => '连接账户，开启积分权益';

  @override
  String get metaverse_ldcReauthSuccess => 'LDC 重新授权成功';

  @override
  String get metaverse_ldcService => 'LDC 积分服务';

  @override
  String get metaverse_myServices => '我的服务';

  @override
  String get metaverse_title => '元宇宙';

  @override
  String get nav_home => '首页';

  @override
  String get nav_mine => '我的';

  @override
  String toast_authorizationFailed(String error) {
    return '授权失败: $error';
  }

  @override
  String get toast_credentialCleared => '凭证已清除';

  @override
  String get toast_credentialIncomplete => '请填写完整的凭证信息';

  @override
  String get toast_credentialSaved => '凭证保存成功';

  @override
  String get toast_networkDisconnected => '网络连接已断开';

  @override
  String get toast_networkRestored => '网络已恢复';

  @override
  String get toast_operationFailedRetry => '操作失败，请重试';

  @override
  String get toast_pressAgainToExit => '再按一次返回键退出';

  @override
  String toast_rewardError(String error) {
    return '打赏失败: $error';
  }

  @override
  String get toast_rewardFailed => '打赏失败';

  @override
  String get toast_rewardNotConfigured => '请先配置打赏凭证';

  @override
  String get toast_rewardSuccess => '打赏成功！';

  @override
  String get advancedSettings_networkAdapter => '网络适配器';

  @override
  String get advancedSettings_networkAdapterDesc => '管理 Cronet 和备用适配器设置';

  @override
  String get networkAdapter_adapterType => '适配器类型';

  @override
  String get networkAdapter_autoFallback => '已自动降级';

  @override
  String get networkAdapter_autoFallbackDesc => '检测到 Cronet 不可用，已切换到备用适配器';

  @override
  String get networkAdapter_controlOptions => '控制选项';

  @override
  String get networkAdapter_currentStatus => '当前状态';

  @override
  String get networkAdapter_degradeReason => 'Cronet 降级原因';

  @override
  String get networkAdapter_devTest => '开发者测试';

  @override
  String get networkAdapter_fallback => '备用';

  @override
  String get networkAdapter_fallbackStatus => '降级状态';

  @override
  String get networkAdapter_forceFallback => '强制使用备用适配器';

  @override
  String get networkAdapter_forceFallbackDesc =>
      '禁用 Cronet，使用 NetworkHttpAdapter';

  @override
  String get networkAdapter_native => '原生';

  @override
  String get networkAdapter_resetFallback => '重置降级状态';

  @override
  String get networkAdapter_resetFallbackDesc => '清除降级记录，下次启动重新尝试 Cronet';

  @override
  String get networkAdapter_resetSuccess => '已重置，重启应用后生效';

  @override
  String get networkAdapter_settingSaved => '设置已保存，重启应用后生效';

  @override
  String get networkAdapter_simulateError => '模拟 Cronet 错误';

  @override
  String get networkAdapter_simulateErrorDesc => '触发降级流程，测试自动降级功能';

  @override
  String get networkAdapter_simulateSuccess => '已触发模拟降级，请查看降级状态';

  @override
  String get networkAdapter_title => '网络适配器';

  @override
  String get networkAdapter_viewReason => '查看降级原因';

  @override
  String get networkSettings_advanced => '高级';

  @override
  String get networkSettings_auxiliary => '辅助功能';

  @override
  String get networkSettings_debug => '调试';

  @override
  String get networkSettings_engine => '网络引擎';

  @override
  String get networkSettings_maxConcurrent => '最大并发数';

  @override
  String get networkSettings_maxPerWindow => '窗口请求上限';

  @override
  String get networkSettings_proxy => '网络代理';

  @override
  String get networkSettings_title => '网络设置';

  @override
  String get networkSettings_windowSeconds => '窗口时长';

  @override
  String get networkSettings_windowSecondsSuffix => '秒';

  @override
  String get network_adapterNativeAndroid => 'Cronet 适配器';

  @override
  String get network_adapterNativeIos => 'Cupertino 适配器';

  @override
  String get network_adapterNetwork => 'Network 适配器';

  @override
  String get network_adapterRhttp => 'rhttp 引擎';

  @override
  String get network_adapterWebView => 'WebView 适配器';

  @override
  String get network_badRequest => '请求参数错误';

  @override
  String get network_forbidden => '没有权限执行此操作';

  @override
  String get network_internalError => '服务器内部错误';

  @override
  String get network_notFound => '请求的资源不存在';

  @override
  String get network_postPendingReview => '你的帖子已提交，正在等待审核';

  @override
  String get network_rateLimited => '请求过于频繁，请稍后再试';

  @override
  String network_rateLimitedWait(String duration) {
    return '请求过于频繁，请等待 $duration 后再试';
  }

  @override
  String network_requestFailed(int statusCode) {
    return '请求失败 ($statusCode)';
  }

  @override
  String network_serverUnavailable(int statusCode) {
    return '服务器暂时不可用 ($statusCode)';
  }

  @override
  String get network_serverUnavailableRetry => '服务器暂时不可用，请稍后再试';

  @override
  String get network_unauthorized => '未登录或登录已过期';

  @override
  String get network_unprocessable => '请求无法处理';

  @override
  String get rhttpEngine_alwaysUse => '始终使用';

  @override
  String rhttpEngine_currentAdapter(String adapter) {
    return '当前: $adapter';
  }

  @override
  String get rhttpEngine_disabledDesc => '启用后使用 Rust 网络引擎';

  @override
  String get rhttpEngine_echFallbackHint =>
      'ECH 启用时 WebView 仍通过本地代理兜底；rhttp 直连会优先尝试自身的 ECH';

  @override
  String get rhttpEngine_enabledDesc => 'HTTP/2 多路复用 · Rust reqwest';

  @override
  String get rhttpEngine_proxyDohOnly => '仅代理/DOH';

  @override
  String get rhttpEngine_title => 'rhttp 引擎';

  @override
  String get rhttpEngine_useMode => '使用模式';

  @override
  String get webviewAdapter_disabledDesc => '使用浏览器内核发送请求，可改善登录稳定性';

  @override
  String get webviewAdapter_enabledDesc => '主站 API 请求通过浏览器内核发送';

  @override
  String get webviewAdapter_hint => '仅主站 API 请求通过 WebView 发送，图片加载和消息推送不受影响';

  @override
  String get webviewAdapter_title => 'WebView 网络引擎';

  @override
  String get notification_adminNewSuggestions => '网站信息中心有新建议';

  @override
  String get notification_assignedTopic => '话题已分配给你';

  @override
  String get notification_backgroundRunning => '正在后台运行，保持通知接收';

  @override
  String notification_boost(String username) {
    return '$username Boost 了你的帖子';
  }

  @override
  String notification_boostWithContent(String username, String content) {
    return '$username: $content';
  }

  @override
  String notification_boostByMany(String username, int count) {
    return '$username 等 $count 人 Boost 了你的帖子';
  }

  @override
  String get notification_bookmarkReminder => '书签提醒';

  @override
  String get notification_channelBackground => '后台运行';

  @override
  String get notification_channelBackgroundDesc => '保持 FluxDO 在后台接收通知';

  @override
  String get notification_channelDiscourse => 'Discourse 通知';

  @override
  String get notification_channelDiscourseDesc => '来自 Discourse 论坛的通知';

  @override
  String get notification_chatGroupMention => '群组在聊天中被提及';

  @override
  String notification_chatInvitation(String username) {
    return '$username 邀请你参与聊天';
  }

  @override
  String notification_chatMention(String username) {
    return '$username 在聊天中提及了你';
  }

  @override
  String notification_chatMessage(String username) {
    return '$username 发送了聊天消息';
  }

  @override
  String notification_chatQuotedPost(String username) {
    return '$username 在聊天中引用了你';
  }

  @override
  String get notification_chatWatchedThread => '你关注的聊天话题有新消息';

  @override
  String get notification_circlesActivity => '圈子有新动态';

  @override
  String get notification_codeReviewApproved => '代码审核已通过';

  @override
  String notification_createdNewTopic(String username) {
    return '$username 创建了新话题';
  }

  @override
  String get notification_custom => '自定义通知';

  @override
  String notification_editedPost(String username) {
    return '$username 编辑了帖子';
  }

  @override
  String get notification_empty => '暂无通知';

  @override
  String notification_eventInvitation(String username) {
    return '$username 邀请你参加活动';
  }

  @override
  String get notification_eventReminder => '活动提醒';

  @override
  String notification_followingYou(String displayName) {
    return '$displayName 开始关注你';
  }

  @override
  String notification_grantedBadge(String badgeName) {
    return '获得了 \'$badgeName\'';
  }

  @override
  String notification_groupMessageSummary(String groupName, int count) {
    return '$groupName 收件箱有 $count 条消息';
  }

  @override
  String notification_invitedToPM(String username) {
    return '$username 邀请你参与私信';
  }

  @override
  String notification_invitedToTopic(String username) {
    return '$username 邀请你参与话题';
  }

  @override
  String notification_inviteeAccepted(String displayName) {
    return '$displayName 接受了你的邀请';
  }

  @override
  String notification_liked(String username) {
    return '$username 赞了你的帖子';
  }

  @override
  String notification_likedByMany(String username, int count) {
    return '$username 和其他 $count 人赞了你的帖子';
  }

  @override
  String notification_likedByTwo(String username, String username2) {
    return '$username、$username2 赞了你的帖子';
  }

  @override
  String notification_likedMultiplePosts(String displayName, int count) {
    return '$displayName 点赞了你的 $count 个帖子';
  }

  @override
  String notification_linkedMultiplePosts(String displayName, int count) {
    return '$displayName 链接了你的 $count 个帖子';
  }

  @override
  String notification_linkedPost(String username) {
    return '$username 链接了你的帖子';
  }

  @override
  String get notification_markAllRead => '全部标为已读';

  @override
  String notification_membershipAccepted(String groupName) {
    return '加入 \'$groupName\' 的申请已被接受';
  }

  @override
  String notification_membershipPending(int count, String groupName) {
    return '$count 个未处理的 \'$groupName\' 成员申请';
  }

  @override
  String notification_mentioned(String username) {
    return '$username 在帖子中提及了你';
  }

  @override
  String notification_movedPost(String username) {
    return '$username 移动了帖子';
  }

  @override
  String get notification_newFeaturesAvailable => '有新功能可用！';

  @override
  String get notification_newNotification => '新通知';

  @override
  String notification_newPostPublished(String username) {
    return '$username 发布了新帖子';
  }

  @override
  String get notification_newTopic => '新建话题';

  @override
  String notification_peopleLikedPost(int count) {
    return '$count 人赞了你的帖子';
  }

  @override
  String notification_peopleLinkedPost(int count) {
    return '$count 人链接了你的帖子';
  }

  @override
  String get notification_postApproved => '你的帖子已被批准';

  @override
  String notification_privateMsgSent(String username) {
    return '$username 发送了私信';
  }

  @override
  String notification_qaCommented(String username) {
    return '$username 评论了问答';
  }

  @override
  String notification_quoted(String username) {
    return '$username 引用了你的帖子';
  }

  @override
  String notification_reaction(String username) {
    return '$username 对你的帖子做出了反应';
  }

  @override
  String notification_replied(String username) {
    return '$username 回复了你的帖子';
  }

  @override
  String notification_repliedTopic(String username) {
    return '$username 回复了话题';
  }

  @override
  String get notification_topicReminder => '话题提醒';

  @override
  String get notification_typeAdminProblems => '管理员问题';

  @override
  String get notification_typeAssignedTopic => '话题指派';

  @override
  String get notification_typeBoost => 'Boost';

  @override
  String get notification_typeBookmarkReminder => '书签提醒';

  @override
  String get notification_typeChatGroupMention => '群聊提及';

  @override
  String get notification_typeChatInvitation => '聊天邀请';

  @override
  String get notification_typeChatMention => '聊天提及';

  @override
  String get notification_typeChatMessage => '聊天消息';

  @override
  String get notification_typeChatQuotedPost => '聊天引用';

  @override
  String get notification_typeChatWatchedThread => '聊天关注话题';

  @override
  String get notification_typeCirclesActivity => '圈子活动';

  @override
  String get notification_typeCodeReviewApproved => '代码审核通过';

  @override
  String get notification_typeCustom => '自定义';

  @override
  String get notification_typeEdited => '编辑';

  @override
  String get notification_typeEventInvitation => '活动邀请';

  @override
  String get notification_typeEventReminder => '活动提醒';

  @override
  String get notification_typeFollowing => '关注';

  @override
  String get notification_typeFollowingCreatedTopic => '关注的用户创建了话题';

  @override
  String get notification_typeFollowingReplied => '关注的用户回复了';

  @override
  String get notification_typeGrantedBadge => '获得徽章';

  @override
  String get notification_typeGroupMentioned => '群组提及';

  @override
  String get notification_typeGroupMessageSummary => '群组消息摘要';

  @override
  String get notification_typeInvitedToPM => '私信邀请';

  @override
  String get notification_typeInvitedToTopic => '话题邀请';

  @override
  String get notification_typeInviteeAccepted => '邀请已接受';

  @override
  String get notification_typeLiked => '点赞';

  @override
  String get notification_typeLikedConsolidated => '点赞汇总';

  @override
  String get notification_typeLinked => '链接';

  @override
  String get notification_typeLinkedConsolidated => '链接汇总';

  @override
  String get notification_typeMembershipAccepted => '成员申请已接受';

  @override
  String get notification_typeMembershipConsolidated => '成员申请汇总';

  @override
  String get notification_typeMentioned => '提及';

  @override
  String get notification_typeMovedPost => '帖子移动';

  @override
  String get notification_typeNewFeatures => '新功能';

  @override
  String get notification_typePostApproved => '帖子已批准';

  @override
  String get notification_typePosted => '发帖';

  @override
  String get notification_typePrivateMessage => '私信';

  @override
  String get notification_typeQACommented => '问答评论';

  @override
  String get notification_typeQuoted => '引用';

  @override
  String get notification_typeReaction => '反应';

  @override
  String get notification_typeReplied => '回复';

  @override
  String get notification_typeTopicReminder => '话题提醒';

  @override
  String get notification_typeUnknown => '未知';

  @override
  String get notification_typeVotesReleased => '投票发布';

  @override
  String get notification_typeWatchingCategoryOrTag => '关注分类或标签';

  @override
  String get notification_typeWatchingFirstPost => '关注首帖';

  @override
  String get notification_votesReleased => '投票已发布';

  @override
  String notification_watchingCategoryNewPost(String username) {
    return '$username 发布了新帖子';
  }

  @override
  String get notifications_empty => '暂无通知';

  @override
  String get notifications_markAllRead => '全部标为已读';

  @override
  String get notifications_title => '通知';

  @override
  String get boost_created => 'Boost 已发送';

  @override
  String get boost_deleteConfirm => '确定要删除这条 Boost 吗？';

  @override
  String get boost_deleteFailed => 'Boost 删除失败';

  @override
  String get boost_deleted => 'Boost 已删除';

  @override
  String get boost_failed => 'Boost 发送失败';

  @override
  String get boost_flagSubmitted => '举报已提交';

  @override
  String get boost_flagTitle => '举报 Boost';

  @override
  String get boost_limitReached => '此帖子的 Boost 数量已达上限';

  @override
  String get boost_placeholder => '说点什么...';

  @override
  String get boost_send => '发送';

  @override
  String boost_tooLong(int count) {
    return '内容过长，最多 $count 个字符';
  }

  @override
  String get nested_flatView => '切换平铺视图';

  @override
  String get nested_loadMore => '加载更多';

  @override
  String get nested_loadMoreReplies => '加载更多回复';

  @override
  String nested_repliesCount(int count) {
    return '$count 条回复';
  }

  @override
  String get nested_sortNew => '最新';

  @override
  String get nested_sortOld => '最旧';

  @override
  String get nested_sortTop => '热门';

  @override
  String get nested_title => '树形视图';

  @override
  String get poll_closed => '已关闭';

  @override
  String get poll_count => '计数';

  @override
  String get poll_percentage => '百分比';

  @override
  String get poll_undo => '撤销';

  @override
  String get poll_viewResults => '查看结果';

  @override
  String get poll_vote => '投票';

  @override
  String poll_voters(int count) {
    return '$count 投票人';
  }

  @override
  String get post_acceptSolution => '采纳为解决方案';

  @override
  String get post_collapseReplies => '收起回复';

  @override
  String get post_contentRequired => '请输入内容';

  @override
  String get post_deleteReplyConfirm => '确定要删除这条回复吗？此操作可以撤销。';

  @override
  String get post_deleteReplyTitle => '删除回复';

  @override
  String get post_detail => '帖子详情';

  @override
  String get post_discardConfirm => '你想放弃你的帖子吗？';

  @override
  String get post_discardTitle => '放弃帖子';

  @override
  String post_editPostTitle(int postNumber) {
    return '编辑帖子 #$postNumber';
  }

  @override
  String post_firstPostNotice(String username) {
    return '这是 $username 的首次发帖——让我们欢迎 TA 加入社区！';
  }

  @override
  String get post_flagDescriptionHint => '请描述具体问题...';

  @override
  String get post_flagFailed => '举报失败，请稍后重试';

  @override
  String post_flagMessageUser(String username) {
    return '向 @$username 发送消息';
  }

  @override
  String get post_flagNotifyModerators => '私下通知管理人员';

  @override
  String get post_flagSubmitted => '举报已提交';

  @override
  String get post_flagTitle => '举报帖子';

  @override
  String get post_generateShareImage => '生成分享图片';

  @override
  String get post_lastReadHere => '上次看到这里';

  @override
  String post_loadContentFailed(String error) {
    return '加载内容失败: $error';
  }

  @override
  String get post_loadMoreReplies => '加载更多回复';

  @override
  String get post_longTimeAgo => '很久以前';

  @override
  String get post_meBadge => '我';

  @override
  String post_moreLinks(int count) {
    return '还有 $count 条';
  }

  @override
  String get post_noReactions => '暂无回应';

  @override
  String get post_opBadge => '主';

  @override
  String get post_pendingReview => '你的帖子已提交，正在等待审核';

  @override
  String get post_reactions => '回应';

  @override
  String get post_relatedLinks => '相关链接';

  @override
  String post_relatedRepliesCount(int count) {
    return '相关回复共 $count 条';
  }

  @override
  String post_replyCount(int count) {
    return '$count 条回复';
  }

  @override
  String get post_replySent => '回复已发送';

  @override
  String get post_replySentAction => '查看';

  @override
  String get post_replyTo => '回复给';

  @override
  String get post_replyToTopic => '回复话题';

  @override
  String post_replyToUser(String username) {
    return '回复 @$username';
  }

  @override
  String post_returningUserNotice(String username, String timeText) {
    return '好久不见 $username——TA 的上一条帖子是 $timeText。';
  }

  @override
  String post_sendPmTitle(String username) {
    return '发送私信给 @$username';
  }

  @override
  String get post_solutionAccepted => '已采纳为解决方案';

  @override
  String get post_solutionUnaccepted => '已取消采纳';

  @override
  String get post_solved => '已解决';

  @override
  String get post_submitFlag => '提交举报';

  @override
  String get post_tipLdc => '打赏 LDC';

  @override
  String get post_titleRequired => '请输入标题';

  @override
  String get post_topicSolved => '此话题已解决';

  @override
  String get post_unacceptSolution => '取消采纳';

  @override
  String get post_unsolved => '待解决';

  @override
  String get post_viewBestAnswer => '查看最佳答案';

  @override
  String get post_viewHiddenInfo => '查看隐藏的信息';

  @override
  String get post_whisperIndicator => '仅管理员可见';

  @override
  String get smallAction_archivedDisabled => '取消归档了话题';

  @override
  String get smallAction_archivedEnabled => '归档了话题';

  @override
  String get smallAction_autobumped => '自动顶帖';

  @override
  String get smallAction_autoclosedDisabled => '话题被自动打开';

  @override
  String get smallAction_autoclosedEnabled => '话题被自动关闭';

  @override
  String get smallAction_bannerDisabled => '移除了横幅';

  @override
  String get smallAction_bannerEnabled => '将话题设为横幅';

  @override
  String get smallAction_categoryChanged => '更新了类别';

  @override
  String get smallAction_closedDisabled => '打开了话题';

  @override
  String get smallAction_closedEnabled => '关闭了话题';

  @override
  String get smallAction_forwarded => '转发了邮件';

  @override
  String get smallAction_invitedGroup => '邀请了';

  @override
  String get smallAction_invitedUser => '邀请了';

  @override
  String get smallAction_openTopic => '转换为话题';

  @override
  String get smallAction_pinnedDisabled => '取消置顶了话题';

  @override
  String get smallAction_pinnedEnabled => '置顶了话题';

  @override
  String get smallAction_pinnedGloballyDisabled => '取消全站置顶';

  @override
  String get smallAction_pinnedGloballyEnabled => '全站置顶了话题';

  @override
  String get smallAction_privateTopic => '转换为私信';

  @override
  String get smallAction_publicTopic => '转换为公开话题';

  @override
  String get smallAction_removedGroup => '移除了';

  @override
  String get smallAction_removedUser => '移除了';

  @override
  String get smallAction_splitTopic => '拆分了话题';

  @override
  String get smallAction_tagsChanged => '更新了标签';

  @override
  String get smallAction_userLeft => '离开了对话';

  @override
  String get smallAction_visibleDisabled => '取消公开了话题';

  @override
  String get smallAction_visibleEnabled => '公开了话题';

  @override
  String get vote_cancelled => '已取消投票';

  @override
  String get vote_closed => '已关闭';

  @override
  String get vote_label => '投票';

  @override
  String get vote_pleaseLogin => '请先登录';

  @override
  String get vote_success => '投票成功';

  @override
  String get vote_successNoRemaining => '投票成功，您的投票已用完';

  @override
  String vote_successRemaining(int remaining) {
    return '投票成功，剩余 $remaining 票';
  }

  @override
  String get vote_topicClosed => '话题已关闭，无法投票';

  @override
  String get vote_voted => '已投票';

  @override
  String get preheat_logoutConfirm => '确定要退出当前账号吗？退出后将清除本地登录信息。';

  @override
  String get preheat_logoutMessage => '用户主动退出登录（预热失败页面）';

  @override
  String get preheat_networkSettings => '网络设置';

  @override
  String get preheat_retryConnection => '重试连接';

  @override
  String get preheat_userSkipped => '用户跳过预加载';

  @override
  String table_rowCount(int count) {
    return '共 $count 行';
  }

  @override
  String get httpProxy_auth => '认证';

  @override
  String get httpProxy_base64PskHint => '请输入 Base64 编码后的 32 字节预共享密钥';

  @override
  String get httpProxy_cipher => '加密算法';

  @override
  String get httpProxy_cipherNotSet => '未设置算法';

  @override
  String get httpProxy_configTitle => '配置上游代理';

  @override
  String get httpProxy_disabledDesc =>
      '为本地网关配置远端 HTTP / SOCKS5 / Shadowsocks 代理';

  @override
  String get httpProxy_disabledHint =>
      '开启后会保留代理模式开关，由本地网关统一接管 Dio、WebView 和 Shadowsocks 出口';

  @override
  String get httpProxy_dohProxyHint =>
      '当前会通过本地 DoH 网关转发到上游代理；关闭 DoH 时会切换为纯代理转发';

  @override
  String httpProxy_enabledDesc(String protocol) {
    return '已启用 $protocol 上游代理，由本地网关统一转发';
  }

  @override
  String get httpProxy_fillServerAndPort => '请填写服务器地址和端口';

  @override
  String get httpProxy_importSsLink => '导入 ss:// 链接';

  @override
  String httpProxy_importedNode(String remarks) {
    return '已导入节点：$remarks';
  }

  @override
  String get httpProxy_keyBase64Psk => '密钥（Base64 PSK）';

  @override
  String get httpProxy_password => '密码';

  @override
  String get httpProxy_port => '端口';

  @override
  String get httpProxy_portHint => '例如：8080 或 1080';

  @override
  String get httpProxy_portInvalid => '端口无效';

  @override
  String get httpProxy_protocol => '协议';

  @override
  String get httpProxy_proxyAutoTest => '保存后会自动测试，也可以手动重新测试';

  @override
  String get httpProxy_requireAuth => '需要认证';

  @override
  String get httpProxy_selectSsCipher => '请选择受支持的 Shadowsocks 加密算法';

  @override
  String get httpProxy_server => '上游代理服务器';

  @override
  String get httpProxy_serverAddress => '服务器地址';

  @override
  String get httpProxy_serverAddressHint =>
      '例如：192.168.1.1 或 proxy.example.com';

  @override
  String get httpProxy_ssConfigSaved => '保存后会校验 Shadowsocks 配置，并建议返回首页做实际访问验证';

  @override
  String get httpProxy_ssImportSuccess => 'Shadowsocks 链接导入成功';

  @override
  String get httpProxy_ssLink => 'Shadowsocks 链接';

  @override
  String get httpProxy_suppressedByVpn => '已被 VPN 自动关闭，VPN 断开后将自动恢复';

  @override
  String get httpProxy_testAvailability => '测试代理可用性';

  @override
  String get httpProxy_testingProxy => '正在验证是否能通过当前代理访问 linux.do';

  @override
  String get httpProxy_testingSsConfig => '正在校验 Shadowsocks 配置是否可由本地网关接管';

  @override
  String get httpProxy_title => '上游代理';

  @override
  String httpProxy_username(String username) {
    return '用户名: $username';
  }

  @override
  String get httpProxy_usernameLabel => '用户名';

  @override
  String get proxy_cannotConnect => '无法连接代理服务器';

  @override
  String get proxy_connectionClosed => '连接已被远端关闭';

  @override
  String get proxy_fillAddressPort => '请先填写代理地址和端口';

  @override
  String get proxy_httpAuthFailed => 'HTTP 代理认证失败（407）';

  @override
  String proxy_httpConnectFailed(String statusLine) {
    return 'HTTP 代理 CONNECT 失败：$statusLine';
  }

  @override
  String get proxy_notConfigured => '未配置代理服务器';

  @override
  String get proxy_responseTimeout => '等待代理响应超时';

  @override
  String get proxy_socks5AddrTypeNotSupported => '地址类型不支持';

  @override
  String get proxy_socks5AuthFailed => 'SOCKS5 认证失败';

  @override
  String get proxy_socks5AuthRejected => 'SOCKS5 不接受当前认证方式';

  @override
  String get proxy_socks5CommandNotSupported => '命令不支持';

  @override
  String proxy_socks5ConnectFailed(String reply) {
    return 'SOCKS5 CONNECT 失败：$reply';
  }

  @override
  String get proxy_socks5ConnectInvalidVersion => 'SOCKS5 CONNECT 响应版本无效';

  @override
  String get proxy_socks5ConnectionRefused => '目标拒绝连接';

  @override
  String get proxy_socks5CredentialsTooLong => 'SOCKS5 用户名或密码过长';

  @override
  String get proxy_socks5GeneralFailure => '普通失败';

  @override
  String get proxy_socks5HostUnreachable => '主机不可达';

  @override
  String get proxy_socks5HostnameTooLong => 'SOCKS5 目标主机名过长';

  @override
  String get proxy_socks5InvalidVersion => 'SOCKS5 响应版本无效';

  @override
  String get proxy_socks5NetworkUnreachable => '网络不可达';

  @override
  String get proxy_socks5NotAllowed => '规则不允许';

  @override
  String get proxy_socks5TtlExpired => 'TTL 已过期';

  @override
  String proxy_socks5UnknownAddrType(String hex) {
    return 'SOCKS5 返回了未知地址类型：0x$hex';
  }

  @override
  String proxy_socks5UnknownError(String hex) {
    return '未知错误（0x$hex）';
  }

  @override
  String proxy_socks5UnsupportedAuth(String hex) {
    return 'SOCKS5 返回了不支持的认证方式：0x$hex';
  }

  @override
  String get proxy_ss2022KeyHint => '请填写 Shadowsocks 2022 的密钥（Base64 PSK）';

  @override
  String get proxy_ss2022KeyInvalidBase64 =>
      'Shadowsocks 2022 密钥必须是有效的 Base64 字符串';

  @override
  String proxy_ss2022KeyInvalidLength(int length) {
    return 'Shadowsocks 2022 密钥长度无效：解码后必须为 $length 字节';
  }

  @override
  String get proxy_ssBase64DecodeFailed => 'ss:// 链接 Base64 解码失败';

  @override
  String get proxy_ssCannotParseCipher => '无法解析加密算法和密码';

  @override
  String get proxy_ssIncomplete => 'Shadowsocks 配置不完整';

  @override
  String get proxy_ssInvalidIpv6 => 'IPv6 地址格式无效';

  @override
  String get proxy_ssInvalidPort => '端口无效';

  @override
  String get proxy_ssLinkContentEmpty => 'ss:// 链接内容为空';

  @override
  String get proxy_ssLinkEmpty => '链接不能为空';

  @override
  String get proxy_ssMissingAddress => '缺少服务器地址';

  @override
  String get proxy_ssMissingPort => '缺少端口';

  @override
  String get proxy_ssOnlySsProtocol => '仅支持 ss:// 链接';

  @override
  String get proxy_ssPasswordHint => '请填写 Shadowsocks 密码';

  @override
  String get proxy_ssSaved => 'Shadowsocks 配置已保存';

  @override
  String get proxy_ssSavedDetail =>
      '当前版本会通过本地网关接管 Shadowsocks 出站；请启用代理后返回首页进行实际访问验证';

  @override
  String get proxy_ssSelectCipher => '请选择受支持的 Shadowsocks 加密算法';

  @override
  String proxy_ssUnsupportedCipher(String ciphers) {
    return '当前版本仅支持 $ciphers';
  }

  @override
  String proxy_targetResponseError(String statusLine) {
    return '目标站点响应异常：$statusLine';
  }

  @override
  String get proxy_testFailed => '代理测试失败';

  @override
  String get proxy_testSuccess => '代理可用';

  @override
  String proxy_testSuccessDetail(String protocol, String host, int statusCode) {
    return '已通过 $protocol 代理访问 $host，HTTP $statusCode';
  }

  @override
  String get proxy_testTimeout => '代理测试超时';

  @override
  String proxy_testTimeoutDetail(int seconds, String host) {
    return '连接或握手超过 $seconds 秒，未能完成 $host 可用性验证';
  }

  @override
  String get proxy_testTlsFailed => 'TLS 握手失败';

  @override
  String get vpnToggle_and => ' 和 ';

  @override
  String get vpnToggle_connected => 'VPN 已连接';

  @override
  String get vpnToggle_disconnected => 'VPN 未连接';

  @override
  String get vpnToggle_subtitle => '检测到 VPN 时自动关闭 DOH 和代理，断开后恢复';

  @override
  String get vpnToggle_suppressedSuffix => '已被自动关闭，VPN 断开后将自动恢复';

  @override
  String get vpnToggle_title => 'VPN 自动切换';

  @override
  String get vpnToggle_upstreamProxy => '上游代理';

  @override
  String get cdk_balance => 'CDK 积分';

  @override
  String get cdk_points => '积分';

  @override
  String get cdk_reAuthHint => '请重新授权以查看积分';

  @override
  String get ldc_balance => 'LDC 余额';

  @override
  String ldc_dailyIncome(String amount) {
    return '今日收入 $amount';
  }

  @override
  String get ldc_reAuthHint => '请重新授权以查看余额';

  @override
  String get reward_authFailed => '认证失败，请检查 Client ID 和 Client Secret';

  @override
  String get reward_clearCredential => '清除凭证';

  @override
  String get reward_configDialogTitle => '配置 LDC 打赏凭证';

  @override
  String get reward_configHint => '请输入在 credit.linux.do 申请的凭证';

  @override
  String get reward_configured => '已配置，可在帖子中打赏';

  @override
  String reward_confirmMessage(String target, int amount) {
    return '确定向 $target 打赏 $amount LDC 吗？';
  }

  @override
  String get reward_confirmTitle => '确认打赏';

  @override
  String get reward_createApp => '创建应用';

  @override
  String get reward_customAmount => '自定义金额';

  @override
  String get reward_defaultError => '打赏失败';

  @override
  String reward_duplicateWarning(int remaining) {
    return '请勿重复打赏，$remaining秒后可再次操作';
  }

  @override
  String get reward_goToCreateApp => '前往创建应用 →';

  @override
  String reward_httpError(int statusCode) {
    return '请求失败: HTTP $statusCode';
  }

  @override
  String reward_networkError(String error) {
    return '网络错误: $error';
  }

  @override
  String get reward_notConfigured => '配置凭证以启用打赏功能';

  @override
  String get reward_noteHint => '感谢分享！';

  @override
  String get reward_noteLabel => '备注（可选）';

  @override
  String get reward_selectAmount => '选择金额';

  @override
  String get reward_selectOrInputAmount => '请选择或输入金额';

  @override
  String get reward_sheetTitle => '打赏 LDC';

  @override
  String reward_submitWithAmount(int amount) {
    return '打赏 $amount LDC';
  }

  @override
  String get reward_title => 'LDC 打赏';

  @override
  String reward_unknownError(String error) {
    return '未知错误: $error';
  }

  @override
  String get search_advancedSearch => '高级搜索';

  @override
  String search_afterDate(String date) {
    return '$date 之后';
  }

  @override
  String get search_applyFilter => '应用筛选';

  @override
  String search_beforeDate(String date) {
    return '$date 之前';
  }

  @override
  String get search_category => '分类';

  @override
  String search_categoryLoadFailed(String error) {
    return '加载分类失败: $error';
  }

  @override
  String get search_clearAll => '清除全部';

  @override
  String get search_currentFilter => '当前筛选';

  @override
  String get search_custom => '自定义';

  @override
  String get search_dateRange => '时间范围';

  @override
  String get search_emptyHint => '输入关键词搜索';

  @override
  String get search_error => '搜索出错';

  @override
  String get search_filterBookmarks => '书签';

  @override
  String get search_filterCreated => '我的话题';

  @override
  String get search_filterSeen => '浏览历史';

  @override
  String get search_hintText => '搜索 @用户 #分类 tags:标签';

  @override
  String get search_lastMonth => '最近一月';

  @override
  String get search_lastWeek => '最近一周';

  @override
  String get search_lastYear => '最近一年';

  @override
  String search_likeCount(String count) {
    return '$count 点赞';
  }

  @override
  String get search_noLimit => '不限';

  @override
  String get search_noPopularTags => '暂无热门标签';

  @override
  String get search_noResults => '没有找到相关结果';

  @override
  String get search_popularTags => '热门标签';

  @override
  String get search_recentSearches => '最近搜索';

  @override
  String search_replyCount(int count) {
    return '$count 条回复';
  }

  @override
  String search_resultCount(int count, String more) {
    return '$count$more 条结果';
  }

  @override
  String get search_selectDateRange => '选择时间范围';

  @override
  String get search_selectedTags => '已选标签';

  @override
  String get search_sortLabel => '排序：';

  @override
  String get search_sortLatest => '最新帖子';

  @override
  String get search_sortLatestTopic => '最新话题';

  @override
  String get search_sortLikes => '最受欢迎';

  @override
  String get search_sortRelevance => '相关性';

  @override
  String get search_sortViews => '最多浏览';

  @override
  String get search_status => '状态';

  @override
  String get search_statusArchived => '已归档';

  @override
  String get search_statusClosed => '已关闭';

  @override
  String get search_statusOpen => '进行中';

  @override
  String get search_statusSolved => '已解决';

  @override
  String get search_statusUnsolved => '未解决';

  @override
  String get search_tags => '标签';

  @override
  String search_tagsLoadFailed(String error) {
    return '加载标签失败: $error';
  }

  @override
  String get search_topicSearchHint => '输入关键词搜索本话题';

  @override
  String get search_tryOtherKeywords => '请尝试其他关键词';

  @override
  String get search_users => '用户';

  @override
  String search_viewCount(String count) {
    return '$count 浏览';
  }

  @override
  String get cfVerify_cooldown => '验证太频繁，请稍后再试';

  @override
  String get cfVerify_desc => '手动触发过盾验证';

  @override
  String get cfVerify_failed => '验证未通过';

  @override
  String get cfVerify_success => '验证成功';

  @override
  String get cfVerify_title => 'Cloudflare 验证';

  @override
  String get cf_abandonVerifyMessage => '退出验证将导致相关功能无法使用，确定要退出吗？';

  @override
  String get cf_abandonVerifyTitle => '放弃验证？';

  @override
  String get cf_autoVerifyTimeout => '自动验证超时，请手动完成验证';

  @override
  String get cf_backgroundVerifying => '后台验证中... (点击打开)';

  @override
  String get cf_cannotOpenVerifyPage => '无法打开验证页面，请稍后重试';

  @override
  String get cf_challengeFailedCooldown => '安全验证失败，已进入冷却期，请稍后再试';

  @override
  String get cf_challengeNotEffective => '验证未生效，请稍后重试';

  @override
  String get cf_continueVerify => '继续验证';

  @override
  String get cf_cooldown => '请稍后再试';

  @override
  String get cf_failedRetry => '安全验证失败，请重试';

  @override
  String cf_failedWithCause(String cause) {
    return '安全验证失败: $cause';
  }

  @override
  String get cf_helpContent =>
      '这是 Cloudflare 安全验证页面。\n\n请完成页面上的验证挑战（如勾选框或滑块）。\n\n验证成功后会自动关闭此页面。\n\n如果长时间无法完成，可以尝试：\n• 点击刷新按钮重新加载\n• 检查网络连接\n• 关闭后稍后再试';

  @override
  String get cf_helpTitle => '验证帮助';

  @override
  String cf_loadFailed(String description) {
    return '加载失败: $description';
  }

  @override
  String get cf_securityVerifyTitle => '安全验证';

  @override
  String get cf_userCancelled => '验证已取消';

  @override
  String get cf_verifyIncomplete => '验证未完成，请重试';

  @override
  String cf_verifyLonger(int seconds) {
    return '验证时间较长，还剩 $seconds 秒';
  }

  @override
  String get cf_verifyTimeout => '验证超时，请重试';

  @override
  String cf_verifying(int seconds) {
    return '验证中... ${seconds}s';
  }

  @override
  String get hcaptcha_clear => '清除';

  @override
  String get hcaptcha_clearConfirm => '确定要清除 hCaptcha 无障碍 Cookie 吗？';

  @override
  String get hcaptcha_cookieCleared => 'hCaptcha 无障碍 Cookie 已清除';

  @override
  String get hcaptcha_cookieNotFound => '未找到 hCaptcha 无障碍 Cookie，请先完成注册';

  @override
  String get hcaptcha_cookieNotSet => 'Cookie 未设置';

  @override
  String get hcaptcha_cookieSaved => 'hCaptcha 无障碍 Cookie 已保存';

  @override
  String get hcaptcha_cookieSet => 'Cookie 已设置 ✓';

  @override
  String get hcaptcha_done => '完成';

  @override
  String get hcaptcha_pasteCookie => '粘贴 Cookie';

  @override
  String get hcaptcha_pasteDialogDesc =>
      '在浏览器中访问 hCaptcha 无障碍页面注册后，从浏览器开发者工具中复制名为 hc_accessibility 的 Cookie 值粘贴到下方。';

  @override
  String get hcaptcha_pasteDialogHint => '请输入 hc_accessibility Cookie 值';

  @override
  String get hcaptcha_pasteDialogTitle => '粘贴 hCaptcha Cookie';

  @override
  String get hcaptcha_pasteLink => '粘贴登录链接';

  @override
  String get hcaptcha_pasteLinkInvalid => '剪贴板中没有有效的 hCaptcha 链接';

  @override
  String get hcaptcha_subtitle => '视障用户可跳过 hCaptcha 验证';

  @override
  String get hcaptcha_title => 'hCaptcha 无障碍';

  @override
  String get hcaptcha_webviewGet => 'WebView 获取';

  @override
  String get hcaptcha_webviewTitle => 'hCaptcha 无障碍';

  @override
  String get config_seedUserTitle => '种子用户';

  @override
  String get preferences_advanced => '高级';

  @override
  String get preferences_androidNativeCdp => 'WebView Cookie 同步';

  @override
  String get preferences_androidNativeCdpDesc => '优先使用原生 CDP；异常时可关闭并回退兼容模式。';

  @override
  String get preferences_anonymousShare => '匿名分享';

  @override
  String get preferences_anonymousShareDesc => '分享链接时不附带个人用户标识';

  @override
  String get preferences_autoFillLogin => '自动填充登录';

  @override
  String get preferences_autoFillLoginDesc => '记住账号密码，登录时自动填充';

  @override
  String get preferences_autoPanguSpacing => '自动混排优化';

  @override
  String get preferences_autoPanguSpacingDesc => '输入时自动插入中英文混排空格';

  @override
  String get preferences_basic => '基础';

  @override
  String get preferences_cfClearanceRefresh => 'cf_clearance 自动续期';

  @override
  String get preferences_cfClearanceRefreshDesc =>
      '通过后台 WebView 自动续期 cf_clearance Cookie';

  @override
  String get preferences_crashlytics => '崩溃日志上报';

  @override
  String get preferences_crashlyticsDesc => '发生崩溃时自动上报日志，帮助开发者定位问题';

  @override
  String get preferences_editor => '编辑器';

  @override
  String get preferences_enableCrashlyticsContent =>
      '本应用使用 Firebase Crashlytics 收集崩溃信息以改进应用稳定性。\n\n收集的数据包括设备信息和崩溃详情，不包含个人隐私数据。您可以在设置中关闭此功能。';

  @override
  String get preferences_enableCrashlyticsTitle => '数据收集说明';

  @override
  String get preferences_enterUrl => '输入 URL';

  @override
  String get preferences_hideBarOnScroll => '滚动收起导航栏';

  @override
  String get preferences_hideBarOnScrollDesc => '首页滚动时自动收起顶栏和底栏';

  @override
  String get preferences_longPressPreview => '长按预览';

  @override
  String get preferences_longPressPreviewDesc => '长按话题卡片快速预览内容';

  @override
  String get preferences_openLinksInApp => '外部链接使用内置浏览器';

  @override
  String get preferences_openLinksInAppDesc => '贴内外部链接优先在应用内打开';

  @override
  String get preferences_portraitLock => '竖屏锁定';

  @override
  String get preferences_portraitLockDesc => '锁定屏幕方向为竖屏';

  @override
  String get preferences_stickerSource => '表情包数据源';

  @override
  String get preferences_title => '功能设置';

  @override
  String get settings_about => '关于 FluxDO';

  @override
  String get settings_appearance => '外观设置';

  @override
  String get settings_dataManagement => '数据管理';

  @override
  String get settings_network => '网络设置';

  @override
  String get settings_preferences => '功能设置';

  @override
  String get settings_reading => '阅读设置';

  @override
  String get settings_searchEmpty => '未找到匹配的设置项';

  @override
  String get settings_searchHint => '搜索设置项...';

  @override
  String get settings_shortcuts => '快捷键';

  @override
  String get settings_title => '应用设置';

  @override
  String get shortcuts_closeOverlay => '关闭浮层';

  @override
  String shortcuts_conflict(String action) {
    return '与「$action」冲突';
  }

  @override
  String get shortcuts_content => '内容';

  @override
  String get shortcuts_createTopic => '创建话题';

  @override
  String get shortcuts_customizeHint => '在 设置 > 快捷键 中自定义';

  @override
  String get shortcuts_navigateBack => '返回';

  @override
  String get shortcuts_navigateBackAlt => '返回（备用）';

  @override
  String get shortcuts_navigation => '导航';

  @override
  String get shortcuts_nextItem => '下一个条目';

  @override
  String get shortcuts_nextTab => '下一个分类';

  @override
  String get shortcuts_openItem => '打开选中条目';

  @override
  String get shortcuts_openSearch => '搜索';

  @override
  String get shortcuts_openSettings => '打开设置';

  @override
  String get shortcuts_previousItem => '上一个条目';

  @override
  String get shortcuts_previousTab => '上一个分类';

  @override
  String get shortcuts_recordKey => '请按下新的快捷键组合';

  @override
  String get shortcuts_refresh => '刷新';

  @override
  String get shortcuts_resetAll => '恢复所有默认';

  @override
  String get shortcuts_resetOne => '恢复默认';

  @override
  String get shortcuts_showHelp => '快捷键帮助';

  @override
  String get shortcuts_switchPane => '切换面板焦点';

  @override
  String get shortcuts_switchToProfile => '切换到个人';

  @override
  String get shortcuts_switchToTopics => '切换到话题';

  @override
  String get shortcuts_toggleAiPanel => 'AI 助手面板';

  @override
  String get shortcuts_toggleNotifications => '通知面板';

  @override
  String get download_alreadyInProgress => '已有下载任务正在进行';

  @override
  String get download_checksumFailed => '文件校验失败，下载的文件可能已损坏';

  @override
  String get download_connecting => '正在连接...';

  @override
  String download_downloading(String name) {
    return '正在下载 $name';
  }

  @override
  String download_failed(String error) {
    return '下载失败: $error';
  }

  @override
  String download_failedWithError(String error) {
    return '下载失败: $error';
  }

  @override
  String download_installFailed(String error) {
    return '安装失败: $error';
  }

  @override
  String get download_installStarted => '已开始安装';

  @override
  String get download_installing => '正在安装...';

  @override
  String get download_internalError => '下载安装过程中发生内部错误';

  @override
  String get download_noInstallPermission => '未授予安装权限，请在设置中允许安装未知应用';

  @override
  String get download_verifying => '正在校验文件...';

  @override
  String export_exporting(int progress, int total) {
    return '导出中 ($progress/$total)';
  }

  @override
  String get export_exportingNoProgress => '导出中...';

  @override
  String export_failed(String error) {
    return '导出失败: $error';
  }

  @override
  String get export_fetchPostsFailed => '获取帖子数据失败';

  @override
  String get export_firstPostOnly => '仅主帖';

  @override
  String get export_format => '导出格式';

  @override
  String export_markdownLimit(int max) {
    return 'Markdown 格式最多导出前 $max 条帖子';
  }

  @override
  String get export_noPostsToExport => '没有可导出的帖子';

  @override
  String get export_range => '导出范围';

  @override
  String get export_title => '导出文章';

  @override
  String get share_aiAssistant => 'AI 助手';

  @override
  String get share_aiQuestion => '提问';

  @override
  String get share_aiReply => 'AI 回复';

  @override
  String get share_aiReplyAlt => 'AI 助手回复';

  @override
  String get share_cannotGetPostId => '无法获取主帖 ID';

  @override
  String get share_copyFailed => '复制失败，请重试';

  @override
  String get share_exportChatImage => '导出对话图片';

  @override
  String get share_exportImage => '导出图片';

  @override
  String get share_generatedByAi => '由 FluxDO AI 助手生成';

  @override
  String get share_getPostFailed => '获取主帖失败';

  @override
  String get share_imageCopied => '图片已复制';

  @override
  String get share_imageSaved => '图片已保存到相册';

  @override
  String get share_loadingPost => '正在加载帖子...';

  @override
  String get share_replyToTopic => '回复话题';

  @override
  String get share_saveFailed => '保存失败，请重试';

  @override
  String get share_savePermissionDenied => '保存失败，请授予相册权限';

  @override
  String get share_saveToGallery => '保存到相册';

  @override
  String get share_fileSaved => '文件已保存';

  @override
  String get share_selectSaveLocation => '选择保存位置';

  @override
  String get share_screenshotFailed => '截图失败';

  @override
  String get share_shareImageTitle => '分享图片';

  @override
  String get share_themeBlack => '纯黑';

  @override
  String get share_themeBlue => '蓝调';

  @override
  String get share_themeClassic => '经典';

  @override
  String get share_themeDark => '深色';

  @override
  String get share_themeGreen => '绿野';

  @override
  String get share_themeWhite => '纯白';

  @override
  String get share_uploadFailed => '上传失败，请重试';

  @override
  String get share_uploading => '正在上传...';

  @override
  String time_days(int count) {
    return '$count 天';
  }

  @override
  String time_daysAgo(int count) {
    return '$count天前';
  }

  @override
  String time_fullDate(int year, int month, int day) {
    return '$year年$month月$day日';
  }

  @override
  String time_hours(int count) {
    return '$count 小时';
  }

  @override
  String time_hoursAgo(int count) {
    return '$count小时前';
  }

  @override
  String get time_justNow => '刚刚';

  @override
  String time_minutes(int count) {
    return '$count 分钟';
  }

  @override
  String time_minutesAgo(int count) {
    return '$count分钟前';
  }

  @override
  String time_monthsAgo(int count) {
    return '$count个月前';
  }

  @override
  String time_seconds(int count) {
    return '$count 秒';
  }

  @override
  String time_shortDate(int month, int day) {
    return '$month月$day日';
  }

  @override
  String get time_today => '今天';

  @override
  String time_tooltipTime(
    int year,
    int month,
    int day,
    String hour,
    String minute,
    String second,
  ) {
    return '$year年$month月$day日 $hour:$minute:$second';
  }

  @override
  String time_weeksAgo(int count) {
    return '$count周前';
  }

  @override
  String time_yearsAgo(int count) {
    return '$count年前';
  }

  @override
  String get time_yesterday => '昨天';

  @override
  String get topicDetail_addToReadLater => '加入浮窗';

  @override
  String get topicDetail_addToReadLaterSuccess => '已加入浮窗';

  @override
  String get topicDetail_aiAssistant => 'AI 助手';

  @override
  String get topicDetail_authorOnly => '只看题主';

  @override
  String get topicDetail_cannotOpenBrowser => '无法打开浏览器';

  @override
  String get topicDetail_editBookmark => '编辑书签';

  @override
  String get topicDetail_editTopic => '编辑话题';

  @override
  String get topicDetail_exportArticle => '导出文章';

  @override
  String get topicDetail_filter => '筛选';

  @override
  String get topicDetail_generateShareImage => '生成分享图片';

  @override
  String get topicDetail_hotOnly => '只看热门';

  @override
  String get topicDetail_loadFailedTapRetry => '加载失败，点击重试';

  @override
  String get topicDetail_loading => '加载中...';

  @override
  String get topicDetail_moreOptions => '更多选项';

  @override
  String get topicDetail_openInBrowser => '在浏览器打开';

  @override
  String topicDetail_readLaterFull(int max) {
    return '浮窗已满（最多 $max 个）';
  }

  @override
  String get topicDetail_removeFromReadLater => '移出浮窗';

  @override
  String get topicDetail_removeFromReadLaterSuccess => '已从浮窗移除';

  @override
  String get topicDetail_replyLabel => '回复';

  @override
  String get topicDetail_scrollToTop => '回到顶部';

  @override
  String get topicDetail_searchHint => '在本话题中搜索...';

  @override
  String get topicDetail_searchTopic => '搜索本话题';

  @override
  String topicDetail_setToLevel(String level) {
    return '已设置为$level';
  }

  @override
  String get topicDetail_shareLink => '分享链接';

  @override
  String topicDetail_showHiddenReplies(int count) {
    return '显示 $count 条隐藏回复';
  }

  @override
  String get topicDetail_topLevelOnly => '只看顶层';

  @override
  String get topicDetail_viewAll => '查看全部';

  @override
  String get topicDetail_viewsLabel => '浏览';

  @override
  String get topicSort_activity => '活跃度';

  @override
  String get topicSort_created => '创建时间';

  @override
  String get topicSort_default => '默认';

  @override
  String get topicSort_likes => '点赞数';

  @override
  String get topicSort_posters => '参与者';

  @override
  String get topicSort_posts => '回复数';

  @override
  String get topicSort_views => '浏览量';

  @override
  String get topic_addTags => '添加标签';

  @override
  String get topic_aiSummary => 'AI 摘要';

  @override
  String get topic_atCurrentPosition => '正位于此';

  @override
  String get topic_createdAt => '创建于 ';

  @override
  String get topic_currentFloor => '当前楼层';

  @override
  String get topic_filterHot => '热门';

  @override
  String get topic_filterLatest => '最新';

  @override
  String get topic_filterNew => '新话题';

  @override
  String topic_filterTooltip(String label) {
    return '筛选: $label';
  }

  @override
  String get topic_filterTop => '排行榜';

  @override
  String get topic_filterUnread => '未读完';

  @override
  String get topic_filterUnseen => '未浏览';

  @override
  String get topic_flagInappropriate => '不当内容';

  @override
  String get topic_flagInappropriateDesc => '此帖子包含不适当的内容';

  @override
  String get topic_flagOffTopic => '离题';

  @override
  String get topic_flagOffTopicDesc => '此帖子与当前讨论无关，应该移动到其他话题';

  @override
  String get topic_flagOther => '其他问题';

  @override
  String get topic_flagOtherDesc => '需要版主关注的其他问题';

  @override
  String get topic_flagSpam => '垃圾信息';

  @override
  String get topic_flagSpamDesc => '此帖子是广告或垃圾信息';

  @override
  String get topic_generateAiSummary => '生成 AI 摘要';

  @override
  String get topic_generatingSummary => '正在生成摘要...';

  @override
  String get topic_jump => '跳转';

  @override
  String get topic_lastReply => '最后回复 ';

  @override
  String get topic_levelMuted => '静音';

  @override
  String get topic_levelMutedDesc => '不接收任何通知';

  @override
  String get topic_levelRegular => '常规';

  @override
  String get topic_levelRegularDesc => '只在被 @ 提及或回复时通知';

  @override
  String get topic_levelTracking => '跟踪';

  @override
  String get topic_levelTrackingDesc => '显示未读计数';

  @override
  String get topic_levelWatching => '关注';

  @override
  String get topic_levelWatchingDesc => '每个新回复都通知';

  @override
  String topic_likeCount(String count) {
    return '$count 点赞';
  }

  @override
  String topic_minTagsRequired(int min) {
    return '至少选择 $min 个标签';
  }

  @override
  String topic_newRepliesSinceSummary(int count) {
    return '有 $count 条新回复';
  }

  @override
  String get topic_noSummary => '暂无摘要';

  @override
  String get topic_notificationSettings => '订阅设置';

  @override
  String get topic_participants => '参与者';

  @override
  String get topic_readyToJump => '准备跳转';

  @override
  String topic_remainingTags(int remaining) {
    return '还需 $remaining 个标签';
  }

  @override
  String topic_replyCount(int count) {
    return '$count 条回复';
  }

  @override
  String get topic_selectCategory => '选择分类';

  @override
  String topic_sortTooltip(String label) {
    return '排序: $label';
  }

  @override
  String get topic_summaryLoadFailed => '加载摘要失败';

  @override
  String topic_tagGroupRequirement(String name, int minCount) {
    return '从 $name 选择 $minCount 个';
  }

  @override
  String get topic_updatedAt => '更新于 ';

  @override
  String topic_viewCount(String count) {
    return '$count 浏览';
  }

  @override
  String get topicsScreen_createTopic => '创建话题';

  @override
  String get topicsScreen_myDrafts => '我的草稿';

  @override
  String get topics_browseCategories => '浏览分类';

  @override
  String get topics_debugJump => '调试：跳转话题';

  @override
  String get topics_dismiss => '忽略';

  @override
  String topics_dismissConfirmContent(String label) {
    return '确定要忽略全部$label吗？';
  }

  @override
  String get topics_dismissConfirmTitle => '忽略确认';

  @override
  String get topics_jump => '跳转';

  @override
  String get topics_jumpToTopic => '跳转到话题';

  @override
  String get topics_newTopics => '新话题';

  @override
  String get topics_noTopics => '没有相关话题';

  @override
  String get topics_searchHint => '搜索话题...';

  @override
  String get topics_topicId => '话题 ID';

  @override
  String get topics_topicIdHint => '例如: 1095754';

  @override
  String get topics_unreadTopics => '未读话题';

  @override
  String topics_viewNewTopics(int count) {
    return '查看 $count 个新的或更新的话题';
  }

  @override
  String get followList_followers => '粉丝';

  @override
  String get followList_following => '关注';

  @override
  String get privateMessages_title => '私信';

  @override
  String get privateMessages_inbox => '最新';

  @override
  String get privateMessages_sent => '已发送';

  @override
  String get privateMessages_archive => '归档';

  @override
  String get privateMessages_empty => '暂无私信';

  @override
  String get profileStats_addItems => '点击添加统计项';

  @override
  String get profileStats_allItemsAdded => '所有统计项已添加';

  @override
  String get profileStats_availableItems => '可添加项目';

  @override
  String get profileStats_bookmarkCount => '书签数';

  @override
  String get profileStats_columnsPerRow => '每行数量';

  @override
  String get profileStats_dataSource => '数据源';

  @override
  String get profileStats_daysVisited => '访问天数';

  @override
  String get profileStats_editTitle => '统计卡片自定义';

  @override
  String get profileStats_enabledItems => '已添加项目';

  @override
  String get profileStats_guideMessage => '点击统计卡片可自定义展示项目、布局和数据源';

  @override
  String get profileStats_incompatibleSource => '不兼容当前数据源';

  @override
  String get profileStats_layoutGrid => '网格';

  @override
  String get profileStats_layoutMode => '布局模式';

  @override
  String get profileStats_layoutScroll => '滚动';

  @override
  String get profileStats_layoutSettings => '布局设置';

  @override
  String get profileStats_likesGiven => '送赞';

  @override
  String get profileStats_likesReceived => '获赞';

  @override
  String get profileStats_likesReceivedDays => '获赞天数';

  @override
  String get profileStats_likesReceivedUsers => '获赞人数';

  @override
  String get profileStats_loadError => '数据加载失败，已回退到全量统计';

  @override
  String get profileStats_noItemsSelected => '未选择任何统计项';

  @override
  String get profileStats_postCount => '发帖数';

  @override
  String get profileStats_postsRead => '已读帖子';

  @override
  String get profileStats_recentTimeRead => '近60天阅读';

  @override
  String get profileStats_selectItems => '统计项目';

  @override
  String get profileStats_sourceConnect => '信任等级周期';

  @override
  String get profileStats_sourceDaily => '本日';

  @override
  String get profileStats_sourceMonthly => '本月';

  @override
  String get profileStats_sourceQuarterly => '本季';

  @override
  String get profileStats_sourceSummary => '全量统计';

  @override
  String get profileStats_sourceWeekly => '本周';

  @override
  String get profileStats_sourceYearly => '本年';

  @override
  String get profileStats_timeRead => '阅读时间';

  @override
  String get profileStats_topicCount => '主题数';

  @override
  String get profileStats_topicsEntered => '浏览主题';

  @override
  String get profileStats_topicsRepliedTo => '回复主题';

  @override
  String get profile_aboutFluxDO => '关于 FluxDO';

  @override
  String get profile_aiModelService => 'AI 模型服务';

  @override
  String get profile_appearance => '外观设置';

  @override
  String get profile_browsingHistory => '浏览历史';

  @override
  String get profile_cdkReauthSuccess => 'CDK 重新授权成功';

  @override
  String get profile_confirmLogout => '确认退出';

  @override
  String get profile_dataManagement => '数据管理';

  @override
  String get profile_daysVisited => '访问天数';

  @override
  String get profile_editProfile => '编辑资料';

  @override
  String get profile_inviteLinks => '邀请链接';

  @override
  String get profile_ldcReauthSuccess => 'LDC 重新授权成功';

  @override
  String get profile_likesReceived => '获得点赞';

  @override
  String get profile_loadingData => '加载数据...';

  @override
  String get profile_loggingOut => '正在退出...';

  @override
  String get profile_loginForMore => '登录后体验更多功能';

  @override
  String get profile_loginLinuxDo => '登录 Linux.do';

  @override
  String get profile_logoutContent => '确定要退出登录吗？';

  @override
  String get profile_logoutCurrentAccount => '退出当前账号';

  @override
  String get profile_metaverse => '元宇宙';

  @override
  String get profile_privateMessages => '私信';

  @override
  String get profile_myBadges => '我的徽章';

  @override
  String get profile_myBookmarks => '我的书签';

  @override
  String get profile_myBrowser => '网页浏览';

  @override
  String get profile_myDrafts => '我的草稿';

  @override
  String get profile_myTopics => '我的话题';

  @override
  String get profile_networkSettings => '网络设置';

  @override
  String get profile_notLoggedIn => '未登录';

  @override
  String get profile_postCount => '发表回复';

  @override
  String get profile_postsRead => '阅读帖子';

  @override
  String get profile_preferences => '功能设置';

  @override
  String get profile_settings => '应用设置';

  @override
  String get profile_trustRequirements => '信任要求';

  @override
  String get trustLevel_activity => '活跃程度';

  @override
  String get trustLevel_appBarTitle => '信任要求';

  @override
  String get trustLevel_compliance => '合规记录';

  @override
  String get trustLevel_interaction => '互动参与';

  @override
  String trustLevel_parseFailed(String error) {
    return '解析失败: $error';
  }

  @override
  String get trustLevel_parseNotFound => '未找到信任级别信息 (div.card)';

  @override
  String trustLevel_requestFailed(int statusCode) {
    return '请求失败: $statusCode';
  }

  @override
  String get trustLevel_title => '信任级别要求';

  @override
  String get userProfile_actionCreatedTopic => '发布了话题';

  @override
  String get userProfile_actionDefault => '动态';

  @override
  String get userProfile_actionLike => '点赞';

  @override
  String get userProfile_actionLiked => '被赞';

  @override
  String get userProfile_actionReplied => '回复了';

  @override
  String get userProfile_bio => '个人简介';

  @override
  String userProfile_catPostCount(int count) {
    return '$count 回复';
  }

  @override
  String userProfile_catTopicCount(int count) {
    return '$count 话题';
  }

  @override
  String get userProfile_follow => '关注';

  @override
  String get userProfile_followed => '已关注';

  @override
  String get userProfile_followers => '粉丝';

  @override
  String get userProfile_following => '关注';

  @override
  String get userProfile_fourMonths => '四个月';

  @override
  String get userProfile_ignored => '已忽略';

  @override
  String get userProfile_joinDate => '加入时间';

  @override
  String get userProfile_laterThisWeek => '本周稍后';

  @override
  String get userProfile_laterToday => '今天稍后';

  @override
  String userProfile_linkClicks(int count) {
    return '$count 次点击';
  }

  @override
  String get userProfile_location => '位置';

  @override
  String get userProfile_message => '私信';

  @override
  String get userProfile_moreInfo => '更多信息';

  @override
  String get userProfile_mostLiked => '赞最多';

  @override
  String get userProfile_mostLikedBy => '被谁赞的最多';

  @override
  String get userProfile_mostRepliedTo => '最多回复至';

  @override
  String get userProfile_mute => '免打扰';

  @override
  String get userProfile_nextMonday => '下周一';

  @override
  String get userProfile_nextMonth => '下个月';

  @override
  String get userProfile_noBio => '这个人很懒，什么都没写';

  @override
  String get userProfile_noContent => '暂无内容';

  @override
  String get userProfile_noReactions => '暂无回应';

  @override
  String get userProfile_noSummary => '暂无总结数据';

  @override
  String get userProfile_normal => '常规';

  @override
  String get userProfile_oneYear => '一年';

  @override
  String get userProfile_permanent => '永久';

  @override
  String get userProfile_permanentlySilenced => '该用户已被永久禁言';

  @override
  String get userProfile_permanentlySuspended => '该用户已被永久封禁';

  @override
  String get userProfile_reacted => '回应了';

  @override
  String get userProfile_restored => '已恢复常规通知';

  @override
  String get userProfile_selectIgnoreDuration => '选择忽略时长';

  @override
  String get userProfile_setToIgnore => '已设置为忽略';

  @override
  String get userProfile_setToMute => '已设置为免打扰';

  @override
  String get userProfile_shareUser => '分享用户';

  @override
  String get userProfile_silencedBannerForever => '该用户已被永久禁言';

  @override
  String userProfile_silencedBannerUntil(String date) {
    return '该用户已被禁言至 $date';
  }

  @override
  String get userProfile_silencedStatus => '禁言状态';

  @override
  String userProfile_silencedUntil(String date) {
    return '禁言至 $date';
  }

  @override
  String get userProfile_sixMonths => '六个月';

  @override
  String get userProfile_statsLikes => '获赞';

  @override
  String get userProfile_statsReplies => '回复';

  @override
  String get userProfile_statsTopics => '话题';

  @override
  String get userProfile_statsVisits => '访问';

  @override
  String get userProfile_suspendedBannerForever => '该用户已被永久封禁';

  @override
  String userProfile_suspendedBannerUntil(String date) {
    return '该用户已被封禁至 $date';
  }

  @override
  String get userProfile_suspendedStatus => '封禁状态';

  @override
  String userProfile_suspendedUntil(String date) {
    return '封禁至 $date';
  }

  @override
  String get userProfile_tabActivity => '动态';

  @override
  String get userProfile_tabLikes => '赞';

  @override
  String get userProfile_tabReactions => '回应';

  @override
  String get userProfile_tabReplies => '回复';

  @override
  String get userProfile_tabSummary => '总结';

  @override
  String get userProfile_tabTopics => '话题';

  @override
  String get userProfile_threeMonths => '三个月';

  @override
  String get userProfile_tomorrow => '明天';

  @override
  String get userProfile_topBadges => '热门徽章';

  @override
  String get userProfile_topCategories => '热门类别';

  @override
  String get userProfile_topLinks => '热门链接';

  @override
  String get userProfile_topReplies => '热门回复';

  @override
  String get userProfile_topTopics => '热门话题';

  @override
  String userProfile_topicHash(String id) {
    return '话题 #$id';
  }

  @override
  String get userProfile_twoMonths => '两个月';

  @override
  String get userProfile_twoWeeks => '两周';

  @override
  String get userProfile_website => '网站';

  @override
  String get user_trustLevel0 => 'L0 新用户';

  @override
  String get user_trustLevel1 => 'L1 基本用户';

  @override
  String get user_trustLevel2 => 'L2 成员';

  @override
  String get user_trustLevel3 => 'L3 活跃用户';

  @override
  String get user_trustLevel4 => 'L4 领袖';

  @override
  String user_trustLevelUnknown(int level) {
    return '等级 $level';
  }

  @override
  String get myBrowser_addManually => '添加收藏';

  @override
  String myBrowser_bookmarkCount(int count) {
    return '$count 个收藏';
  }

  @override
  String get myBrowser_bookmarks => '收藏';

  @override
  String get myBrowser_clearCompleted => '清除已完成';

  @override
  String get myBrowser_clearCompletedConfirm => '确定要清除所有已完成的下载记录吗？';

  @override
  String get myBrowser_clearHistory => '清空历史';

  @override
  String get myBrowser_clearHistoryConfirm => '确定要清空所有浏览历史吗？';

  @override
  String get myBrowser_confirmDelete => '确定要删除这条收藏吗？';

  @override
  String get myBrowser_delete => '删除';

  @override
  String get myBrowser_deleted => '已删除收藏';

  @override
  String get myBrowser_downloadComplete => '下载完成';

  @override
  String get myBrowser_downloadEmpty => '还没有下载记录';

  @override
  String get myBrowser_downloadFailed => '下载失败';

  @override
  String myBrowser_downloadSize(String size) {
    return '$size MB';
  }

  @override
  String get myBrowser_downloadStarted => '开始下载';

  @override
  String get myBrowser_downloading => '下载中';

  @override
  String get myBrowser_downloads => '下载管理';

  @override
  String get myBrowser_downloadsDesc => '查看下载的文件';

  @override
  String get myBrowser_edit => '编辑';

  @override
  String get myBrowser_editTitle => '编辑标题';

  @override
  String get myBrowser_empty => '还没有收藏的网页';

  @override
  String get myBrowser_fileNotFound => '文件不存在';

  @override
  String get myBrowser_history => '浏览历史';

  @override
  String get myBrowser_historyCleared => '浏览历史已清空';

  @override
  String get myBrowser_historyDesc => '查看浏览过的网页';

  @override
  String get myBrowser_historyEmpty => '还没有浏览记录';

  @override
  String get myBrowser_inputTitle => '标题（选填）';

  @override
  String get myBrowser_inputUrl => '输入网址';

  @override
  String get myBrowser_open => '打开';

  @override
  String get myBrowser_title => '网页浏览';

  @override
  String get myBrowser_undo => '撤销';

  @override
  String get myBrowser_viewDownload => '查看';

  @override
  String get webviewLogin_clearSaved => '清除已保存的密码';

  @override
  String get webviewLogin_clearSavedContent => '确定要清除已保存的登录凭证吗？下次登录时需要手动输入。';

  @override
  String get webviewLogin_clearSavedTitle => '清除已保存的密码';

  @override
  String get webviewLogin_emailLoginInvalidLink => '无效的登录链接';

  @override
  String get webviewLogin_emailLoginPaste => '粘贴登录链接';

  @override
  String webviewLogin_lastLogin(String username) {
    return '上次登录: @$username';
  }

  @override
  String get webviewLogin_loginSuccess => '登录成功！';

  @override
  String get webviewLogin_savedPassword => '已保存的密码';

  @override
  String get webviewLogin_title => '登录 Linux.do';

  @override
  String get webview_addBookmark => '收藏此页';

  @override
  String get webview_bookmarkAdded => '已收藏';

  @override
  String get webview_bookmarkRemoved => '已取消收藏';

  @override
  String get webview_browser => '浏览器';

  @override
  String get webview_cannotOpenBrowser => '无法打开外部浏览器';

  @override
  String get webview_go => '前往';

  @override
  String get webview_goBack => '后退';

  @override
  String get webview_goForward => '前进';

  @override
  String get webview_inputUrl => '输入或编辑网址';

  @override
  String get webview_noAppForLink => '未找到可处理此链接的应用';

  @override
  String get webview_openExternal => '在外部浏览器打开';

  @override
  String webview_openFailed(String error) {
    return '打开失败: $error';
  }

  @override
  String get webview_removeBookmark => '取消收藏';
}

/// The translations for Chinese, as used in Hong Kong (`zh_HK`).
class AppLocalizationsZhHk extends AppLocalizationsZh {
  AppLocalizationsZhHk() : super('zh_HK');

  @override
  String get about_appLogs => '應用日誌';

  @override
  String get about_checkUpdate => '檢查更新';

  @override
  String about_checkUpdateError(String error) {
    return '無法檢查更新，請稍後重試。\n錯誤信息: $error';
  }

  @override
  String get about_checkUpdateFailed => '檢查更新失敗';

  @override
  String get about_develop => '開發';

  @override
  String get about_developerMode => '開發者模式';

  @override
  String get about_developerModeAlreadyEnabled => '開發者模式已啓用';

  @override
  String get about_developerModeClosed => '已關閉開發者模式';

  @override
  String get about_developerModeEnabled => '已啓用開發者模式';

  @override
  String get about_feedback => '反饋問題';

  @override
  String get about_info => '信息';

  @override
  String get about_latestVersion => '已是最新版本';

  @override
  String get about_legalese => '非官方 Linux.do 客户端\n基於 Flutter & Material 3';

  @override
  String about_noUpdateContent(String version) {
    return '當前版本: $version\n您正在使用最新版本的 FluxDO，無需更新。';
  }

  @override
  String get about_openSourceLicense => '開源許可';

  @override
  String get about_sourceCode => '項目源碼';

  @override
  String get about_tapToDisableDeveloperMode => '點擊關閉開發者模式';

  @override
  String get about_title => '關於';

  @override
  String get deviceInfo_dohOff => 'DOH: 關閉';

  @override
  String get deviceInfo_proxyOff => '代理: 關閉';

  @override
  String get update_changelog => '更新內容';

  @override
  String get update_dontRemind => '不再提醒';

  @override
  String get update_newVersionFound => '發現新版本';

  @override
  String get update_now => '立即更新';

  @override
  String get update_rateLimited => 'GitHub API 請求過於頻繁，請稍後再試';

  @override
  String get ai_askSubtitle => 'AI 會基於話題內容為你解答';

  @override
  String get ai_askTitle => '向 AI 助手提問';

  @override
  String get ai_clearChat => '清空聊天';

  @override
  String get ai_clearChatConfirm => '確定要清空所有聊天記錄嗎？';

  @override
  String get ai_clearChatTitle => '清空聊天';

  @override
  String get ai_clearLabel => '清空';

  @override
  String get ai_copiedToClipboard => '已複製到剪貼板';

  @override
  String get ai_copyLabel => '複製';

  @override
  String get ai_exportImage => '導出圖片';

  @override
  String get ai_generateFailed => '生成失敗';

  @override
  String get ai_highlights => '有什麼值得關注的';

  @override
  String get ai_highlightsPrompt => '這個話題中有哪些值得關注的信息或亮點？';

  @override
  String get ai_inputHint => '輸入消息...';

  @override
  String get ai_likeInDev => '點贊功能開發中...';

  @override
  String get ai_listViewpoints => '列出主要觀點';

  @override
  String get ai_listViewpointsPrompt => '請列出這個話題中各樓層的主要觀點和立場。';

  @override
  String get ai_moreTooltip => '更多';

  @override
  String get ai_multiSelectExport => '多選導出';

  @override
  String get ai_newSession => '新建會話';

  @override
  String get ai_retryLabel => '重試';

  @override
  String get ai_selectContext => '選擇上下文範圍';

  @override
  String get ai_selectExportMessages => '請選擇要導出的消息';

  @override
  String get ai_selectModel => '選擇模型';

  @override
  String ai_selectedCount(int count) {
    return '已選 $count 條';
  }

  @override
  String get ai_sendTooltip => '發送';

  @override
  String ai_sessionCount(int count) {
    return '$count 條';
  }

  @override
  String get ai_sessionHistory => '會話記錄';

  @override
  String ai_sessionTitle(int index) {
    return '會話 $index';
  }

  @override
  String get ai_stopGenerate => '停止生成';

  @override
  String get ai_summarizePrompt => '請簡要總結這個話題的主要內容和討論要點。';

  @override
  String get ai_summarizeTopic => '總結這個話題';

  @override
  String get ai_swipeHint => '向左滑動可打開 AI 助手';

  @override
  String get ai_title => 'AI 助手';

  @override
  String get ai_translatePost => '翻譯主帖';

  @override
  String get ai_translatePrompt => '請將主帖內容翻譯成英文。';

  @override
  String get ai_typingIndicator => '正在輸入';

  @override
  String get appearance_appIcon => '應用圖標';

  @override
  String get appearance_colorAmber => '琥珀';

  @override
  String get appearance_colorBlue => '藍色';

  @override
  String get appearance_colorGreen => '綠色';

  @override
  String get appearance_colorIndigo => '靛藍';

  @override
  String get appearance_colorOrange => '橙色';

  @override
  String get appearance_colorPink => '粉色';

  @override
  String get appearance_colorPurple => '紫色';

  @override
  String get appearance_colorRed => '紅色';

  @override
  String get appearance_colorTeal => '青色';

  @override
  String get appearance_contentFontSize => '內容字體大小';

  @override
  String get appearance_dialogBlur => '對話框模糊';

  @override
  String get appearance_dialogBlurDesc => '對話框彈出時模糊背景';

  @override
  String get appearance_font => '字體';

  @override
  String get appearance_fontSystem => '系統預設';

  @override
  String get appearance_iconClassic => '經典';

  @override
  String get appearance_iconModern => '現代';

  @override
  String get appearance_language => '語言';

  @override
  String get appearance_languageEn => 'English';

  @override
  String get appearance_languageSystem => '跟隨系統';

  @override
  String get appearance_languageZhCN => '简体中文';

  @override
  String get appearance_languageZhHK => '繁體中文（香港）';

  @override
  String get appearance_languageZhTW => '繁體中文（台灣）';

  @override
  String get appearance_large => '大';

  @override
  String get appearance_modeAuto => '自動';

  @override
  String get appearance_modeDark => '深色';

  @override
  String get appearance_modeLight => '淺色';

  @override
  String get appearance_panguSpacing => '閲讀混排優化';

  @override
  String get appearance_panguSpacingDesc => '瀏覽帖子時自動優化中英文間距';

  @override
  String get appearance_reading => '閲讀';

  @override
  String get appearance_schemeVariant => '配色風格';

  @override
  String get appearance_small => '小';

  @override
  String get appearance_switchIconFailed => '切換圖標失敗，請稍後重試';

  @override
  String get appearance_themeColor => '主題色彩';

  @override
  String get appearance_themeMode => '主題模式';

  @override
  String get appearance_title => '外觀';

  @override
  String get layout_selectTopicHint => '選擇一個話題查看詳情';

  @override
  String get reading_aiSwipeEntry => 'AI 助手滑動入口';

  @override
  String get reading_aiSwipeEntryDesc => '在話題詳情頁向左滑動打開 AI 助手';

  @override
  String get reading_expandRelatedLinks => '預設展開相關鏈接';

  @override
  String get reading_expandRelatedLinksDesc => '帖子中的相關鏈接區域預設展開顯示';

  @override
  String get reading_title => '閱讀設定';

  @override
  String get schemeVariant_content => '內容';

  @override
  String get schemeVariant_expressive => '表現力';

  @override
  String get schemeVariant_fidelity => '高保真';

  @override
  String get schemeVariant_fruitSalad => '繽紛';

  @override
  String get schemeVariant_monochrome => '單色';

  @override
  String get schemeVariant_neutral => '中性';

  @override
  String get schemeVariant_rainbow => '彩虹';

  @override
  String get schemeVariant_tonalSpot => '柔和色調';

  @override
  String get schemeVariant_vibrant => '鮮明';

  @override
  String get auth_cdkConfirmMessage => 'Linux.do CDK 將獲取你的基本信息，是否允許？';

  @override
  String get auth_cdkConfirmTitle => '授權確認';

  @override
  String get auth_clearDataAction => '清理數據';

  @override
  String get auth_cookieRepairLogoutHint =>
      '檢測到歷史登錄 Cookie 異常，應用已自動清理相關髒數據。這可能會讓舊的無效登錄態立即失效，請重新登錄。';

  @override
  String get auth_frequentLogoutClearDataHint =>
      '最近 24 小時內多次觸發登錄失效。如果重新登錄後仍反覆發生，建議前往「數據管理」清除 Cookie 或全部數據後再登錄。';

  @override
  String get auth_ldcConfirmMessage => 'Linux.do Credit 將獲取你的基本信息，是否允許？';

  @override
  String get auth_ldcConfirmTitle => '授權確認';

  @override
  String get auth_logSubject => '認證日誌';

  @override
  String get auth_loginExpiredRelogin => '登錄已失效，請重新登錄';

  @override
  String get auth_loginExpiredTitle => '登錄失效';

  @override
  String auth_oauthExpired(String serviceName) {
    return '$serviceName 授權已過期';
  }

  @override
  String get login_browserHint => '將在瀏覽器中打開登錄頁面';

  @override
  String get login_slogan => '真誠、友善、團結、專業';

  @override
  String get migration_cookieUpgrade => '正在升級 Cookie 儲存...';

  @override
  String get migration_reloginRequired =>
      '本次版本升級優化了 Cookie 儲存機制，已清除舊的登入狀態。請重新登入。';

  @override
  String get migration_title => '資料升級';

  @override
  String get oauth_approvePageParseFailed => '授權頁面解析失敗，請確認已登入論壇';

  @override
  String get oauth_callbackFailed => '授權回調失敗';

  @override
  String get oauth_getAuthUrlFailed => '獲取授權連結失敗';

  @override
  String get oauth_missingParams => '授權回調缺少必要參數';

  @override
  String get oauth_networkError => '網絡請求失敗，請檢查網絡連接';

  @override
  String get oauth_noRedirectResponse => '授權服務未返回重定向';

  @override
  String get onboarding_guestAccess => '遊客訪問';

  @override
  String get onboarding_networkSettings => '網絡設置';

  @override
  String get onboarding_slogan => '真誠 · 友善 · 團結 · 專業';

  @override
  String get badge_bronze => '銅牌';

  @override
  String get badge_bronzeBadge => '銅牌徽章';

  @override
  String get badge_defaultName => '徽章';

  @override
  String get badge_gold => '金牌';

  @override
  String get badge_goldBadge => '金牌徽章';

  @override
  String badge_grantedCount(int count) {
    return '已授予 $count 次';
  }

  @override
  String get badge_grantedSuffix => ' 獲得';

  @override
  String badge_granteeCount(int count) {
    return '$count 位';
  }

  @override
  String get badge_grantees => '獲得者';

  @override
  String get badge_myBadges => '我的徽章';

  @override
  String get badge_noGrantees => '暫無用户獲得該徽章';

  @override
  String get badge_silver => '銀牌';

  @override
  String get badge_silverBadge => '銀牌徽章';

  @override
  String get myBadges_badgeUnit => '枚徽章';

  @override
  String get myBadges_empty => '暫無徽章';

  @override
  String get myBadges_title => '我的徽章';

  @override
  String get myBadges_totalEarned => '累計獲得';

  @override
  String get bookmark_deleteConfirm => '確定要刪除這個書籤嗎？';

  @override
  String get bookmark_editBookmark => '編輯書籤';

  @override
  String get bookmark_nameHint => '為書籤添加備註...';

  @override
  String get bookmark_nameLabel => '書籤名稱（可選）';

  @override
  String get bookmark_reminderCustom => '自定義';

  @override
  String get bookmark_reminderExpired => '提醒已過期';

  @override
  String get bookmark_reminderNextWeek => '下週';

  @override
  String get bookmark_reminderThreeDays => '3天后';

  @override
  String bookmark_reminderTime(String time) {
    return '提醒時間：$time';
  }

  @override
  String get bookmark_reminderTomorrow => '明天';

  @override
  String get bookmark_reminderTwoHours => '2小時後';

  @override
  String get bookmark_removed => '已取消書籤';

  @override
  String get bookmark_setReminder => '設置提醒';

  @override
  String get bookmarks_cancelReminder => '取消提醒';

  @override
  String get bookmarks_deleted => '已刪除書籤';

  @override
  String get bookmarks_empty => '暫無書籤';

  @override
  String get bookmarks_emptySearchHint => '輸入關鍵詞搜索書籤';

  @override
  String get bookmarks_expired => ' 已過期';

  @override
  String get bookmarks_reminderCancelled => '已取消提醒';

  @override
  String get bookmarks_searchHint => '在書籤中搜索...';

  @override
  String get bookmarks_title => '我的書籤';

  @override
  String get readLater_title => '稍後閲讀';

  @override
  String get categoryTopics_createPost => '發帖';

  @override
  String get categoryTopics_empty => '該分類下暫無話題';

  @override
  String get category_addHint => '點擊下方分類添加到標籤欄';

  @override
  String get category_allCategories => '全部分類';

  @override
  String get category_available => '可添加';

  @override
  String get category_browse => '瀏覽分類';

  @override
  String get category_dragHint => '拖拽排序，點擊移除';

  @override
  String get category_editHint => '點擊\"編輯\"添加常用分類到標籤欄';

  @override
  String get category_editMyCategories => '編輯我的分類';

  @override
  String get category_levelMuted => '靜音';

  @override
  String get category_levelMutedDesc => '不接收此分類的任何通知';

  @override
  String get category_levelRegular => '常規';

  @override
  String get category_levelRegularDesc => '只在被 @ 提及或回覆時通知';

  @override
  String get category_levelTracking => '跟蹤';

  @override
  String get category_levelTrackingDesc => '顯示新帖未讀計數';

  @override
  String get category_levelWatching => '關注';

  @override
  String get category_levelWatchingDesc => '每個新回覆都通知';

  @override
  String get category_levelWatchingFirstPost => '關注新話題';

  @override
  String get category_levelWatchingFirstPostDesc => '此分類有新話題時通知';

  @override
  String category_loadFailed(String error) {
    return '加載分類失敗: $error';
  }

  @override
  String get category_myCategories => '我的分類';

  @override
  String get category_noCategories => '暫無分類';

  @override
  String get category_noCategoriesFound => '未找到相關分類';

  @override
  String category_parentAll(String name) {
    return '$name（全部）';
  }

  @override
  String get category_searchHint => '搜索分類...';

  @override
  String get tagTopics_empty => '該標籤下暫無話題';

  @override
  String tag_maxTagsReached(int max) {
    return '最多隻能選擇 $max 個標籤';
  }

  @override
  String get tag_noTags => '暫無可用標籤';

  @override
  String get tag_noTagsFound => '未找到相關標籤';

  @override
  String tag_requiredGroupWarning(String name, int minCount) {
    return '需從 \"$name\" 標籤組選擇至少 $minCount 個標籤';
  }

  @override
  String tag_requiredTagGroupHint(String name, int minCount) {
    return '需從 \"$name\" 選擇至少 $minCount 個';
  }

  @override
  String get tag_searchHint => '搜索標籤...';

  @override
  String tag_searchWithCount(int count) {
    return '搜索標籤 (已選 $count)...';
  }

  @override
  String tag_searchWithMax(int selected, int max) {
    return '搜索標籤 (已選 $selected/$max)...';
  }

  @override
  String tag_searchWithMin(int selected, int min) {
    return '搜索標籤 (已選 $selected, 至少 $min)...';
  }

  @override
  String tag_topicCount(int count) {
    return '$count 個話題';
  }

  @override
  String get common_about => '關於';

  @override
  String get common_add => '添加';

  @override
  String get common_addBookmark => '添加書籤';

  @override
  String get common_added => '已添加';

  @override
  String get common_all => '全部';

  @override
  String get common_allow => '允許';

  @override
  String get common_authExpired => '授權已過期';

  @override
  String get common_back => '返回';

  @override
  String get common_bookmarkAdded => '已添加書籤';

  @override
  String get common_bookmarkRemoved => '已取消書籤';

  @override
  String get common_bookmarkUpdated => '書籤已更新';

  @override
  String get common_cancel => '取消';

  @override
  String get common_cannotOpenBrowser => '無法打開瀏覽器';

  @override
  String get common_checkInput => '請檢查輸入';

  @override
  String get common_checkNetworkRetry => '請檢查網絡後重試';

  @override
  String get common_clear => '清除';

  @override
  String common_clearFailed(String error) {
    return '清除失敗: $error';
  }

  @override
  String get common_clipboardUnavailable => '剪貼板不可用';

  @override
  String get common_close => '關閉';

  @override
  String get common_closePreview => '關閉預覽';

  @override
  String get common_codeCopied => '已複製代碼';

  @override
  String get common_confirm => '確定';

  @override
  String get common_continue => '繼續';

  @override
  String get common_continueVisit => '繼續訪問';

  @override
  String get common_copiedToClipboard => '已複製到剪貼板';

  @override
  String get common_copy => '複製';

  @override
  String get common_copyLink => '複製鏈接';

  @override
  String get common_copyQuote => '複製引用';

  @override
  String get common_custom => '自定義';

  @override
  String get common_decodeAvif => '解碼 AVIF';

  @override
  String get common_delete => '刪除';

  @override
  String get common_deleteBookmark => '刪除書籤';

  @override
  String get common_deleted => '已刪除';

  @override
  String get common_deny => '拒絕';

  @override
  String get common_details => '詳情';

  @override
  String get common_discard => '捨棄';

  @override
  String get common_done => '完成';

  @override
  String get common_edit => '編輯';

  @override
  String get common_editTopic => '編輯話題';

  @override
  String get common_enable => '開啓';

  @override
  String get common_error => '發生錯誤';

  @override
  String get common_errorDetails => '錯誤詳情';

  @override
  String get common_exit => '退出';

  @override
  String get common_exitPreview => '退出預覽';

  @override
  String get common_export => '導出';

  @override
  String get common_failed => '失敗';

  @override
  String get common_fillComplete => '請填寫完整信息';

  @override
  String get common_filter => '篩選';

  @override
  String get common_gotIt => '知道了';

  @override
  String get common_help => '幫助';

  @override
  String get common_hint => '提示';

  @override
  String get common_import => '導入';

  @override
  String get common_later => '稍後';

  @override
  String get common_linkCopied => '鏈接已複製';

  @override
  String get common_loadFailed => '加載失敗';

  @override
  String get common_loadFailedRetry => '加載失敗，請重試';

  @override
  String get common_loadFailedTapRetry => '加載失敗，點擊重試';

  @override
  String get common_loading => '加載中...';

  @override
  String get common_loadingData => '加載數據...';

  @override
  String get common_login => '登錄';

  @override
  String get common_logout => '退出登錄';

  @override
  String get common_more => '更多';

  @override
  String get common_name => '名稱';

  @override
  String get common_networkDisconnected => '網絡連接已斷開';

  @override
  String get common_noContent => '暫無內容';

  @override
  String get common_noData => '暫無數據';

  @override
  String get common_noMore => '沒有更多了';

  @override
  String get common_notConfigured => '未配置';

  @override
  String get common_notSet => '未設置';

  @override
  String get common_notification => '通知';

  @override
  String get common_ok => '好';

  @override
  String common_operationFailed(String error) {
    return '操作失敗：$error';
  }

  @override
  String get common_paste => '粘貼';

  @override
  String get common_pleaseLogin => '請先登錄';

  @override
  String get common_pleaseWait => '請稍候...';

  @override
  String get common_preview => '預覽';

  @override
  String get common_publish => '發佈';

  @override
  String get common_quote => '引用';

  @override
  String get common_quoteCopied => '已複製引用';

  @override
  String get common_reAuth => '重新授權';

  @override
  String get common_recentlyUsed => '最近使用';

  @override
  String get common_redo => '重做';

  @override
  String get common_refresh => '刷新';

  @override
  String get common_remove => '移除';

  @override
  String get common_reply => '回覆';

  @override
  String get common_report => '舉報';

  @override
  String get common_reset => '重置';

  @override
  String get common_restore => '恢復';

  @override
  String get common_restoreDefault => '恢復默認';

  @override
  String get common_restored => '已恢復';

  @override
  String get common_retry => '重試';

  @override
  String get common_save => '保存';

  @override
  String get common_search => '搜索';

  @override
  String get common_searchHint => '搜索...';

  @override
  String get common_searchMore => '搜索更多';

  @override
  String get common_send => '發送';

  @override
  String get common_share => '分享';

  @override
  String get common_shareFailed => '分享失敗，請重試';

  @override
  String get common_shareImage => '分享圖片';

  @override
  String get common_shareLink => '分享鏈接';

  @override
  String common_sizeBytes(String size) {
    return '$size 字節';
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
  String get common_skip => '跳過';

  @override
  String get common_success => '成功';

  @override
  String get common_test => '測試';

  @override
  String get common_title => '標題';

  @override
  String get common_trustRequirements => '信任要求';

  @override
  String get common_understood => '我知道了';

  @override
  String get common_undo => '撤銷';

  @override
  String get common_unknown => '未知';

  @override
  String get common_unknownError => '未知錯誤';

  @override
  String get common_upload => '上傳';

  @override
  String get common_view => '查看';

  @override
  String get common_viewAll => '查看全部';

  @override
  String get common_viewDetails => '查看詳情';

  @override
  String createTopic_charCount(int count) {
    return '$count 字符';
  }

  @override
  String get createTopic_confirmPublish => '確定發佈';

  @override
  String get createTopic_contentHint => '正文內容 (支持 Markdown)...';

  @override
  String get createTopic_continueEditing => '繼續編輯';

  @override
  String get createTopic_discardPost => '放棄帖子';

  @override
  String get createTopic_discardPostContent => '你想放棄你的帖子嗎？';

  @override
  String get createTopic_enterContent => '請輸入內容';

  @override
  String get createTopic_enterTitle => '請輸入標題';

  @override
  String createTopic_loadCategoryFailed(String error) {
    return '加載分類失敗: $error';
  }

  @override
  String createTopic_minContentLength(int min) {
    return '內容至少需要 $min 個字符';
  }

  @override
  String createTopic_minTags(int min) {
    return '此分類至少需要 $min 個標籤';
  }

  @override
  String createTopic_minTitleLength(int min) {
    return '標題至少需要 $min 個字符';
  }

  @override
  String get createTopic_noContent => '（無內容）';

  @override
  String get createTopic_noTitle => '（無標題）';

  @override
  String get createTopic_pendingReview => '你的帖子已提交，正在等待審核';

  @override
  String get createTopic_restoreDraft => '恢復草稿';

  @override
  String get createTopic_restoreDraftContent => '檢測到未發送的草稿，是否恢復？';

  @override
  String get createTopic_selectCategory => '請選擇分類';

  @override
  String get createTopic_templateNotModified => '您尚未修改分類模板內容，確定要發佈嗎？';

  @override
  String get createTopic_title => '創建話題';

  @override
  String get createTopic_titleHint => '鍵入一個吸引人的標題...';

  @override
  String get editTopic_editPm => '編輯私信';

  @override
  String get editTopic_editTopic => '編輯話題';

  @override
  String editTopic_loadContentFailed(String error) {
    return '加載內容失敗: $error';
  }

  @override
  String get backup_invalidFormat => '無效的備份文件格式';

  @override
  String get backup_missingDataField => '備份文件格式錯誤：缺少 data 字段';

  @override
  String get dataManagement_aiChatCleared => 'AI 聊天數據已清除';

  @override
  String get dataManagement_aiChatData => 'AI 聊天數據';

  @override
  String get dataManagement_allCleared => '所有緩存已清除，請重新登錄';

  @override
  String dataManagement_apiKeysCount(int count) {
    return '包含 $count 個 API Key';
  }

  @override
  String get dataManagement_autoManagement => '自動管理';

  @override
  String dataManagement_backupSource(String version) {
    return '備份來源: v$version';
  }

  @override
  String get dataManagement_backupSubject => 'FluxDO 數據備份';

  @override
  String get dataManagement_cacheManagement => '緩存管理';

  @override
  String get dataManagement_calculating => '計算中...';

  @override
  String get dataManagement_clearAiChatContent => '將刪除所有 AI 聊天記錄，此操作不可恢復。';

  @override
  String get dataManagement_clearAiChatTitle => '清除 AI 聊天數據';

  @override
  String get dataManagement_clearAll => '全部清除';

  @override
  String get dataManagement_clearAllCache => '清除所有緩存';

  @override
  String get dataManagement_clearAllContent =>
      '將清除所有緩存數據，包括圖片緩存、AI 聊天數據和 Cookie。\n\n清除 Cookie 後需要重新登錄。';

  @override
  String get dataManagement_clearAllTitle => '清除所有緩存';

  @override
  String get dataManagement_clearAndLogout => '清除並退出登錄';

  @override
  String get dataManagement_clearCookieContent => '清除 Cookie 後需要重新登錄，確定要繼續嗎？';

  @override
  String get dataManagement_clearCookieTitle => '清除 Cookie 緩存';

  @override
  String get dataManagement_clearOnExit => '退出時清除圖片緩存';

  @override
  String get dataManagement_clearOnExitDesc => '下次啓動時自動清除圖片緩存';

  @override
  String get dataManagement_confirmImport => '確認導入';

  @override
  String get dataManagement_cookieCache => 'Cookie 緩存';

  @override
  String get dataManagement_cookieCleared => 'Cookie 緩存已清除，請重新登錄';

  @override
  String get dataManagement_dataBackup => '數據備份';

  @override
  String get dataManagement_exportData => '導出數據';

  @override
  String get dataManagement_exportDesc => '將偏好設置導出為文件';

  @override
  String dataManagement_exportFailed(String error) {
    return '導出失敗: $error';
  }

  @override
  String dataManagement_exportTime(String time) {
    return '導出時間: $time';
  }

  @override
  String get dataManagement_imageCache => '圖片緩存';

  @override
  String get dataManagement_imageCacheCleared => '圖片緩存已清除';

  @override
  String get dataManagement_importAndRestart => '導入並重啓';

  @override
  String get dataManagement_importData => '導入數據';

  @override
  String get dataManagement_importDesc => '從備份文件恢復偏好設置';

  @override
  String dataManagement_importFailed(String error) {
    return '導入失敗: $error';
  }

  @override
  String get dataManagement_importSuccess => '數據已導入，請重啓應用';

  @override
  String get dataManagement_importWarning => '導入後將覆蓋當前對應的設置項，需要重啓應用生效。';

  @override
  String get dataManagement_noCache => '無緩存';

  @override
  String dataManagement_settingsCount(int count) {
    return '包含 $count 項設置';
  }

  @override
  String get dataManagement_title => '數據管理';

  @override
  String get appLogs_appStart => '應用啓動';

  @override
  String get appLogs_clearContent => '確定要清除所有日誌嗎？此操作不可撤銷。';

  @override
  String get appLogs_clearLogs => '清除日誌';

  @override
  String get appLogs_clearTitle => '清除日誌';

  @override
  String get appLogs_copyAll => '複製全部';

  @override
  String get appLogs_copyDeviceInfo => '複製設備信息';

  @override
  String get appLogs_duration => '耗時';

  @override
  String get appLogs_error => '錯誤';

  @override
  String get appLogs_errorType => '錯誤類型';

  @override
  String get appLogs_event => '事件';

  @override
  String get appLogs_feedbackSending => '正在發送反饋…';

  @override
  String get appLogs_feedbackSent => '反饋已發送';

  @override
  String get appLogs_feedbackTitle => '應用日誌反饋';

  @override
  String get appLogs_level => '級別';

  @override
  String get appLogs_lifecycle => '生命週期';

  @override
  String get appLogs_lifecycleEvent => '生命週期事件';

  @override
  String get appLogs_logoutActive => '主動退出';

  @override
  String get appLogs_logoutPassive => '被動退出';

  @override
  String get appLogs_logsCleared => '日誌已清除';

  @override
  String get appLogs_message => '消息';

  @override
  String get appLogs_method => '方法';

  @override
  String get appLogs_noLogs => '暫無日誌';

  @override
  String get appLogs_noMatchingLogs => '無匹配日誌';

  @override
  String get appLogs_reason => '原因';

  @override
  String get appLogs_request => '請求';

  @override
  String get appLogs_sendFeedback => '私信反饋日誌';

  @override
  String get appLogs_shareLogs => '分享日誌';

  @override
  String get appLogs_shareSubject => '應用日誌';

  @override
  String get appLogs_stack => '堆棧';

  @override
  String get appLogs_stackTrace => '堆棧跟蹤';

  @override
  String get appLogs_statusCode => '狀態碼';

  @override
  String get appLogs_tag => '標籤';

  @override
  String get appLogs_time => '時間';

  @override
  String get appLogs_title => '應用日誌';

  @override
  String get appLogs_type => '類型';

  @override
  String get appLogs_user => '用户';

  @override
  String get appLogs_userLogin => '用户登錄';

  @override
  String get appLogs_version => '版本';

  @override
  String get debugTools_cfLogs => 'CF 驗證日誌';

  @override
  String get debugTools_cfLogsCleared => 'CF 日誌已清除';

  @override
  String get debugTools_cfLogsDesc => '查看 Cloudflare 驗證詳情';

  @override
  String get debugTools_cfLogsTitle => 'CF 驗證日誌';

  @override
  String get debugTools_clearCfLogs => '清除 CF 日誌';

  @override
  String get debugTools_clearCfLogsConfirm => '確定要清除所有 CF 驗證日誌嗎？';

  @override
  String get debugTools_clearCfLogsTitle => '清除 CF 日誌';

  @override
  String get debugTools_clearLogs => '清除日誌';

  @override
  String get debugTools_clearLogsConfirm => '確定要清除所有日誌嗎？';

  @override
  String get debugTools_clearLogsTitle => '清除日誌';

  @override
  String get debugTools_debugLogs => '調試日誌';

  @override
  String get debugTools_exportCfLogs => '導出 CF 日誌';

  @override
  String get debugTools_logsCleared => '日誌已清除';

  @override
  String get debugTools_noCfLogs => '暫無 CF 驗證日誌';

  @override
  String get debugTools_noCfLogsHint => '觸發 CF 驗證後會產生日誌';

  @override
  String get debugTools_noCfLogsToShare => '暫無 CF 日誌可分享';

  @override
  String get debugTools_noLogs => '暫無日誌';

  @override
  String get debugTools_noLogsHint => '啓用 DOH 併發起請求後會產生日誌';

  @override
  String get debugTools_noLogsToShare => '暫無日誌可分享';

  @override
  String get debugTools_shareLogs => '分享日誌';

  @override
  String get debugTools_viewLogs => '查看日誌';

  @override
  String get dohDetail_addServer => '添加服務器';

  @override
  String get dohDetail_bootstrapIpHelper => '直接用 IP 連接 DoH 服務器，繞過 DNS 解析';

  @override
  String get dohDetail_bootstrapIpHint => '用逗號分隔，如 1.1.1.1, 1.0.0.1';

  @override
  String get dohDetail_bootstrapIpOptional => 'Bootstrap IP（可選）';

  @override
  String get dohDetail_clearCache => '清空緩存';

  @override
  String dohDetail_clearDnsCacheFailed(String error) {
    return '清空 DNS 緩存失敗: $error';
  }

  @override
  String get dohDetail_copyAddress => '複製地址';

  @override
  String get dohDetail_deleteServer => '刪除服務器';

  @override
  String dohDetail_deleteServerConfirm(String name) {
    return '確定要刪除 \"$name\" 嗎？';
  }

  @override
  String get dohDetail_dnsCacheCleared => 'DNS 緩存已清空';

  @override
  String dohDetail_dnsCacheDesc(int count) {
    return '當前已緩存 $count 個域名。代理模式和查詢模式共用緩存，TTL 臨近到期會後台刷新。';
  }

  @override
  String dohDetail_dnsCacheRefreshed(int count) {
    return 'DNS 緩存已強制刷新（$count 個域名）';
  }

  @override
  String get dohDetail_dnsCacheRefreshedSimple => 'DNS 緩存已強制刷新';

  @override
  String get dohDetail_dnsCacheSection => 'DNS 緩存';

  @override
  String get dohDetail_dohAddress => 'DoH 地址';

  @override
  String get dohDetail_dohAddressCopied => '已複製 DoH 地址';

  @override
  String get dohDetail_echSameAsDnsDesc => '使用 DNS 解析服務器查詢 ECH 配置';

  @override
  String get dohDetail_echServer => 'ECH 服務器';

  @override
  String get dohDetail_editServer => '編輯服務器';

  @override
  String get dohDetail_exampleDns => '例如：My DNS';

  @override
  String get dohDetail_forceRefresh => '強制刷新';

  @override
  String get dohDetail_gatewayDisabledDesc => '已關閉，使用 MITM 雙重 TLS';

  @override
  String get dohDetail_gatewayEnabledDesc => '單次 TLS，通過反向代理轉發';

  @override
  String get dohDetail_gatewayMode => 'Gateway 模式';

  @override
  String get dohDetail_ipAddress => 'IP 地址';

  @override
  String get dohDetail_ipv6Prefer => 'IPv6 優先';

  @override
  String get dohDetail_ipv6PreferDesc => '優先嚐試 IPv6，失敗自動回落 IPv4';

  @override
  String get dohDetail_localDnsCache => '共享本地 DNS 緩存';

  @override
  String get dohDetail_noServers => '暫無服務器';

  @override
  String get dohDetail_processing => '處理中';

  @override
  String dohDetail_refreshDnsCacheFailed(String error) {
    return '強制刷新 DNS 緩存失敗: $error';
  }

  @override
  String get dohDetail_sameAsDns => '與 DNS 相同';

  @override
  String get dohDetail_selectEchServer => '選擇 ECH 服務器';

  @override
  String get dohDetail_serverIp => '服務端 IP';

  @override
  String get dohDetail_serverIpHint => '指定連接 IP，跳過 DNS 解析';

  @override
  String get dohDetail_servers => '服務器';

  @override
  String get dohDetail_testAllSpeed => '全部測速';

  @override
  String get dohDetail_testSpeed => '測速';

  @override
  String get dohDetail_testingSpeed => '測速中';

  @override
  String get dohDetail_title => 'DOH 詳細設置';

  @override
  String get dohDetail_urlMustHttps => '地址必須以 https:// 開頭';

  @override
  String get dohSettings_certAllDone => '已完成所有步驟';

  @override
  String get dohSettings_certDialogDesc => 'HTTPS 攔截需要安裝並信任 CA 證書，每台裝置生成唯一證書';

  @override
  String get dohSettings_certDialogTitle => 'CA 證書安裝';

  @override
  String get dohSettings_certDownloadFailed => '描述檔下載失敗';

  @override
  String get dohSettings_certDownloadHint => '點擊下方按鈕，Safari 會彈出下載提示，請點擊「允許」。';

  @override
  String get dohSettings_certDownloadProfile => '下載描述檔';

  @override
  String get dohSettings_certInstall => '安裝';

  @override
  String get dohSettings_certInstallHint => 'HTTPS 攔截需要安裝並信任證書';

  @override
  String get dohSettings_certInstallProfileHint =>
      '前往 設定 → 一般 → VPN與裝置管理，找到 DOH Proxy CA 描述檔並安裝。';

  @override
  String get dohSettings_certInstalled => 'CA 證書已安裝';

  @override
  String get dohSettings_certInstalledNext => '已安裝，下一步';

  @override
  String get dohSettings_certOpenSettings => '打開設定';

  @override
  String get dohSettings_certPreparing => '正在準備...';

  @override
  String get dohSettings_certRegenerate => '重新生成證書';

  @override
  String get dohSettings_certRegenerateFailed => '證書重新生成失敗';

  @override
  String get dohSettings_certRegenerated => '新證書已生成';

  @override
  String get dohSettings_certReinstall => '重新安裝';

  @override
  String get dohSettings_certReinstallHint => '點擊可重新安裝或更換證書';

  @override
  String get dohSettings_certRequired => '需要安裝 CA 證書';

  @override
  String get dohSettings_certStepDownload => '下載描述檔';

  @override
  String get dohSettings_certStepInstall => '安裝描述檔';

  @override
  String get dohSettings_certStepTrust => '信任證書';

  @override
  String get dohSettings_certTrustHint =>
      '前往 設定 → 一般 → 關於本機 → 證書信任設定，開啟 DOH Proxy CA 的信任開關。';

  @override
  String get dohSettings_disabledDesc => '使用系統默認 DNS';

  @override
  String get dohSettings_enabledDesc => '已啓用加密 DNS 解析';

  @override
  String get dohSettings_errorCopied => '已複製錯誤信息';

  @override
  String get dohSettings_moreSettings => '更多設置';

  @override
  String get dohSettings_moreSettingsDesc => '服務器、IPv6、ECH 等';

  @override
  String get dohSettings_perDeviceCert => '裝置獨有證書';

  @override
  String get dohSettings_perDeviceCertDisabledDesc => '啟用後每台裝置生成獨立的 CA 證書，更安全';

  @override
  String get dohSettings_perDeviceCertEnabledDesc => '已啟用，每台裝置使用獨立 CA 證書';

  @override
  String dohSettings_port(int port) {
    return '端口 $port';
  }

  @override
  String get dohSettings_proxyNotStarted => '代理未啓動';

  @override
  String get dohSettings_proxyRunning => '代理運行中';

  @override
  String get dohSettings_proxyStartFailed => '代理啓動失敗，DoH/ECH 無法生效';

  @override
  String get dohSettings_restartProxy => '重啓代理';

  @override
  String get dohSettings_restarting => '正在重啓...';

  @override
  String get dohSettings_starting => '正在啓動...';

  @override
  String get dohSettings_suppressedByVpn => '已被 VPN 自動關閉，VPN 斷開後將自動恢復';

  @override
  String get doh_cannotConnect => '無法連接到 DOH 服務';

  @override
  String get doh_executableNotFound => '找不到代理可執行文件';

  @override
  String get doh_invalidHttpResponse => '無效的 HTTP 響應';

  @override
  String get doh_queryFailed => 'DOH 查詢失敗';

  @override
  String get doh_serverAlibaba => '阿里 DNS';

  @override
  String doh_serverError(String statusLine) {
    return 'DOH 服務器返回錯誤: $statusLine';
  }

  @override
  String get doh_serverTencent => '騰訊 DNS';

  @override
  String get doh_startTimeout => '代理啓動超時（5秒內未響應）';

  @override
  String get doh_unknownReason => '未知原因';

  @override
  String get codeBlock_chart => '圖表';

  @override
  String get codeBlock_chartLoadFailed => '圖表加載失敗';

  @override
  String get codeBlock_code => '代碼';

  @override
  String codeBlock_renderFailed(String error) {
    return '代碼塊渲染失敗: $error';
  }

  @override
  String draft_topicTitle(String id) {
    return '話題 #$id';
  }

  @override
  String get draft_untitled => '無標題';

  @override
  String get drafts_deleteContent => '確定要刪除這個草稿嗎？';

  @override
  String get drafts_deleteDraft => '刪除草稿';

  @override
  String drafts_deleteFailed(String error) {
    return '刪除失敗: $error';
  }

  @override
  String get drafts_deleteTitle => '刪除草稿';

  @override
  String get drafts_deleted => '草稿已刪除';

  @override
  String get drafts_draft => '草稿';

  @override
  String get drafts_empty => '暫無草稿';

  @override
  String get drafts_newTopic => '新話題';

  @override
  String get drafts_pmIncomplete => '私信草稿數據不完整';

  @override
  String get drafts_privateMessage => '私信';

  @override
  String drafts_replyToPost(int number) {
    return '回覆 #$number';
  }

  @override
  String get drafts_title => '我的草稿';

  @override
  String get editor_hintText => '説點什麼吧... (支持 Markdown)';

  @override
  String get editor_noContent => '（無內容）';

  @override
  String get link_insertTitle => '插入鏈接';

  @override
  String get link_textHint => '顯示的文字';

  @override
  String get link_textLabel => '鏈接文本';

  @override
  String get link_textRequired => '請輸入鏈接文本';

  @override
  String get link_urlRequired => '請輸入 URL';

  @override
  String get mention_group => '羣組';

  @override
  String get mention_noUserFound => '未找到匹配用户';

  @override
  String get mention_searchHint => '輸入用户名搜索';

  @override
  String get template_empty => '暫無可用模板';

  @override
  String get template_insertTitle => '插入模板';

  @override
  String get template_loadError => '加載模板失敗';

  @override
  String get template_searchHint => '搜索模板…';

  @override
  String get template_tooltip => '模板';

  @override
  String get toolbar_attachFileTooltip => '上傳附件';

  @override
  String get toolbar_boldPlaceholder => '粗體文本';

  @override
  String get toolbar_codePlaceholder => '在此處鍵入或粘貼代碼';

  @override
  String get toolbar_gridMinImages => '需要至少 2 張圖片才能創建網格';

  @override
  String get toolbar_gridNeedConsecutive => '需要至少 2 張連續的圖片才能創建網格';

  @override
  String get toolbar_h1 => 'H1 - 一級標題';

  @override
  String get toolbar_h2 => 'H2 - 二級標題';

  @override
  String get toolbar_h3 => 'H3 - 三級標題';

  @override
  String get toolbar_h4 => 'H4 - 四級標題';

  @override
  String get toolbar_h5 => 'H5 - 五級標題';

  @override
  String get toolbar_imageGridTooltip => '圖片網格';

  @override
  String get toolbar_imagesAlreadyInGrid => '這些圖片已經在網格中了';

  @override
  String get toolbar_italicPlaceholder => '斜體文本';

  @override
  String get toolbar_mixOptimize => '混排優化';

  @override
  String get toolbar_quotePlaceholder => '引用文本';

  @override
  String get toolbar_spoilerPlaceholder => '劇透內容';

  @override
  String get toolbar_spoilerTooltip => '劇透';

  @override
  String get toolbar_strikethroughPlaceholder => '刪除線文本';

  @override
  String get emoji_activities => '活動';

  @override
  String get emoji_animals => '動物';

  @override
  String get emoji_flags => '旗幟';

  @override
  String get emoji_food => '食物';

  @override
  String get emoji_loadFailed => '加載表情失敗';

  @override
  String get emoji_notFound => '沒有找到表情';

  @override
  String get emoji_objects => '物體';

  @override
  String get emoji_people => '人物';

  @override
  String get emoji_searchHint => '搜索表情...';

  @override
  String get emoji_searchNotFound => '未找到相關表情';

  @override
  String get emoji_searchPrompt => '輸入關鍵詞搜索表情';

  @override
  String get emoji_searchTooltip => '搜索表情';

  @override
  String get emoji_smileys => '表情';

  @override
  String get emoji_symbols => '符號';

  @override
  String get emoji_tab => '表情';

  @override
  String get emoji_travel => '旅行';

  @override
  String get sticker_addFromMarket => '從市場添加';

  @override
  String get sticker_addTooltip => '添加表情包';

  @override
  String get sticker_added => '已添加';

  @override
  String sticker_emojiCount(int count) {
    return '$count 個表情';
  }

  @override
  String get sticker_groupEmpty => '該分組暫無表情包';

  @override
  String get sticker_loadFailed => '加載表情包失敗';

  @override
  String get sticker_marketEmpty => '暫無可用的表情包';

  @override
  String get sticker_marketLoadFailed => '加載市場失敗';

  @override
  String get sticker_marketTitle => '表情包市場';

  @override
  String get sticker_noStickers => '還沒有表情包';

  @override
  String get sticker_tab => '表情包';

  @override
  String get error_addBookmarkFailed => '添加書籤失敗：響應格式異常';

  @override
  String get error_avifDecodeNoFrames => 'AVIF 解碼失敗：無幀數據';

  @override
  String get error_badRequest => '請求錯誤';

  @override
  String get error_badRequestParams => '請求參數錯誤';

  @override
  String get error_cannotConnectCheckNetwork => '無法在規定時間內連接到服務器，請檢查網絡';

  @override
  String get error_certificateError => '證書異常';

  @override
  String get error_certificateVerifyFailed => '服務器證書驗證失敗，請檢查網絡環境';

  @override
  String get error_connectionTimeout => '連接超時';

  @override
  String get error_contentDeleted => '內容已被刪除';

  @override
  String get error_createTopicFailed => '創建話題失敗';

  @override
  String get error_dataException => '數據異常';

  @override
  String get error_forbidden => '沒有權限';

  @override
  String get error_forbiddenAccess => '沒有權限訪問';

  @override
  String get error_gone => '已刪除';

  @override
  String get error_imageFormatUnsupported => '圖片格式不支持或不符合要求';

  @override
  String get error_imageTooBig => '圖片文件過大，請壓縮後重試';

  @override
  String get error_internalServerError => '服務器內部錯誤';

  @override
  String get error_loadFailed => '加載失敗';

  @override
  String get error_networkCheckSettings => '網絡連接失敗，請檢查網絡設置';

  @override
  String get error_networkRequestFailed => '網絡請求失敗';

  @override
  String get error_networkUnavailable => '網絡不可用';

  @override
  String get error_notFound => '內容不存在';

  @override
  String get error_notFoundOrDeleted => '內容不存在或已被刪除';

  @override
  String get error_notLoggedInNoUsername => '未登錄或無法獲取用户名';

  @override
  String get error_providerDisposed => 'Provider 已銷燬';

  @override
  String get error_rateLimited => '請求過於頻繁';

  @override
  String get error_rateLimitedRetryLater => '請求過於頻繁，請稍後再試';

  @override
  String get error_replyFailed => '回覆失敗';

  @override
  String get error_requestCancelled => '請求取消';

  @override
  String get error_requestCancelledMsg => '請求已取消';

  @override
  String get error_requestFailed => '請求失敗';

  @override
  String error_requestFailedWithCode(int statusCode) {
    return '請求失敗 ($statusCode)';
  }

  @override
  String get error_requestTimeoutRetry => '請求超時，請稍後重試';

  @override
  String get error_requestUnprocessable => '請求無法處理';

  @override
  String get error_responseTimeout => '響應超時';

  @override
  String get error_securityChallenge => '安全驗證';

  @override
  String get error_sendPMFailed => '發送私信失敗';

  @override
  String get error_serverError => '服務器錯誤';

  @override
  String get error_serverResponseTooLong => '服務器響應時間過長，請稍後重試';

  @override
  String get error_serverUnavailable => '服務器不可用';

  @override
  String get error_serviceUnavailable => '服務器不可用';

  @override
  String get error_serviceUnavailableRetry => '服務器暫時不可用，請稍後重試';

  @override
  String get error_tooManyRequests => '請求過於頻繁';

  @override
  String get error_topicDetailEmpty => '話題詳情為空';

  @override
  String get error_unauthorized => '未登錄';

  @override
  String get error_unauthorizedExpired => '未登錄或登錄已過期';

  @override
  String get error_unknown => '未知錯誤';

  @override
  String get error_unknownResponseFormat => '未知響應格式';

  @override
  String get error_unprocessable => '無法處理';

  @override
  String get error_unrecognizedDataFormat => '服務器返回了無法識別的數據格式';

  @override
  String get error_updatePostFailed => '更新帖子失敗：響應格式異常';

  @override
  String get error_uploadNoUrl => '上傳響應中未包含 URL';

  @override
  String get browsingHistory_empty => '暫無瀏覽歷史';

  @override
  String get browsingHistory_emptySearchHint => '輸入關鍵詞搜索瀏覽歷史';

  @override
  String get browsingHistory_searchHint => '在瀏覽歷史中搜索...';

  @override
  String get browsingHistory_title => '瀏覽歷史';

  @override
  String get myTopics_empty => '暫無話題';

  @override
  String get myTopics_emptySearchHint => '輸入關鍵詞搜索我的話題';

  @override
  String get myTopics_searchHint => '在我的話題中搜索...';

  @override
  String get myTopics_title => '我的話題';

  @override
  String get imageEditor_adjust => '調整';

  @override
  String get imageEditor_applyingChanges => '正在應用更改';

  @override
  String get imageEditor_arrow => '箭頭';

  @override
  String get imageEditor_arrowBoth => '雙端箭頭';

  @override
  String get imageEditor_arrowEnd => '終點箭頭';

  @override
  String get imageEditor_arrowStart => '起點箭頭';

  @override
  String get imageEditor_bgMode => '背景模式';

  @override
  String get imageEditor_blur => '模糊';

  @override
  String get imageEditor_brightness => '亮度';

  @override
  String get imageEditor_brush => '畫筆';

  @override
  String get imageEditor_changeOpacity => '調整透明度';

  @override
  String get imageEditor_circle => '圓形';

  @override
  String get imageEditor_closeWarningMessage => '確定要關閉圖片編輯器嗎？你的更改將不會被保存。';

  @override
  String get imageEditor_closeWarningTitle => '關閉圖片編輯器？';

  @override
  String get imageEditor_color => '顏色';

  @override
  String get imageEditor_contrast => '對比度';

  @override
  String get imageEditor_cropRotate => '裁剪/旋轉';

  @override
  String get imageEditor_dashDotLine => '點劃線';

  @override
  String get imageEditor_dashLine => '虛線';

  @override
  String get imageEditor_emoji => '表情';

  @override
  String get imageEditor_emojiActivities => '活動';

  @override
  String get imageEditor_emojiAnimals => '動物與自然';

  @override
  String get imageEditor_emojiFlags => '旗幟';

  @override
  String get imageEditor_emojiFood => '食物與飲品';

  @override
  String get imageEditor_emojiObjects => '物品';

  @override
  String get imageEditor_emojiSmileys => '笑臉與人物';

  @override
  String get imageEditor_emojiSymbols => '符號';

  @override
  String get imageEditor_emojiTravel => '旅行與地點';

  @override
  String get imageEditor_eraser => '橡皮擦';

  @override
  String get imageEditor_exposure => '曝光';

  @override
  String get imageEditor_fade => '褪色';

  @override
  String get imageEditor_fill => '填充';

  @override
  String get imageEditor_filter => '濾鏡';

  @override
  String get imageEditor_flip => '翻轉';

  @override
  String get imageEditor_fontSize => '字體大小';

  @override
  String get imageEditor_freeStyle => '自由繪製';

  @override
  String get imageEditor_hexagon => '六邊形';

  @override
  String get imageEditor_hue => '色調';

  @override
  String get imageEditor_initializingEditor => '正在初始化編輯器';

  @override
  String get imageEditor_inputText => '輸入文字';

  @override
  String get imageEditor_line => '直線';

  @override
  String get imageEditor_lineWidth => '線條寬度';

  @override
  String get imageEditor_luminance => '明度';

  @override
  String get imageEditor_noFilter => '無濾鏡';

  @override
  String get imageEditor_opacity => '透明度';

  @override
  String get imageEditor_pixelate => '像素化';

  @override
  String get imageEditor_polygon => '多邊形';

  @override
  String get imageEditor_ratio => '比例';

  @override
  String get imageEditor_rectangle => '矩形';

  @override
  String get imageEditor_rotate => '旋轉';

  @override
  String get imageEditor_rotateScale => '旋轉和縮放';

  @override
  String get imageEditor_saturation => '飽和度';

  @override
  String get imageEditor_sharpness => '鋭度';

  @override
  String get imageEditor_sticker => '貼紙';

  @override
  String get imageEditor_strokeWidth => '線條粗細';

  @override
  String get imageEditor_temperature => '色温';

  @override
  String get imageEditor_text => '文字';

  @override
  String get imageEditor_textAlign => '文字對齊';

  @override
  String get imageEditor_toggleFill => '切換填充';

  @override
  String get imageEditor_zoom => '縮放';

  @override
  String get imageFormat_generic => '圖片';

  @override
  String get imageFormat_gif => 'GIF 動圖';

  @override
  String get imageFormat_jpeg => 'JPEG 圖片';

  @override
  String get imageFormat_png => 'PNG 圖片';

  @override
  String get imageFormat_webp => 'WebP 圖片';

  @override
  String get imageUpload_compressionQuality => '壓縮質量：';

  @override
  String get imageUpload_confirmTitle => '上傳圖片確認';

  @override
  String get imageUpload_editImage => '編輯圖片';

  @override
  String imageUpload_editNotSupported(String format) {
    return '$format 暫不支持編輯，否則會丟失動畫';
  }

  @override
  String get imageUpload_editNotSupportedLabel => '當前格式不支持編輯';

  @override
  String imageUpload_estimatedSize(String size) {
    return '約 $size';
  }

  @override
  String get imageUpload_gridLayoutHint => '上傳後將自動使用 [grid] 網格佈局';

  @override
  String get imageUpload_keepAtLeastOne => '至少需要保留一張圖片';

  @override
  String imageUpload_keepOriginal(String format) {
    return '$format 將保留原圖上傳，不執行客户端壓縮。';
  }

  @override
  String imageUpload_multiTitle(int count) {
    return '上傳 $count 張圖片';
  }

  @override
  String imageUpload_originalSize(String size) {
    return '原始大小：$size';
  }

  @override
  String imageUpload_processFailed(String error) {
    return '處理圖片失敗: $error';
  }

  @override
  String imageUpload_totalEstimatedSize(String size) {
    return '約 $size';
  }

  @override
  String imageUpload_totalOriginalSize(String size) {
    return '總大小：$size';
  }

  @override
  String imageUpload_uploadCount(int count) {
    return '上傳 $count 張';
  }

  @override
  String get imageViewer_grantPermission => '請授予相冊訪問權限';

  @override
  String get imageViewer_imageSaved => '圖片已保存到相冊';

  @override
  String imageViewer_saveFailed(String error) {
    return '保存失敗: $error';
  }

  @override
  String get imageViewer_saveFailedRetry => '保存失敗，請重試';

  @override
  String get image_copied => '圖片已複製';

  @override
  String get image_copyFailed => '複製圖片失敗';

  @override
  String get image_copyImage => '複製圖片';

  @override
  String get image_copyLink => '複製鏈接';

  @override
  String get image_fetchFailed => '獲取圖片失敗';

  @override
  String get image_viewFull => '查看大圖';

  @override
  String get invite_collapseOptions => '收起鏈接選項';

  @override
  String get invite_createFailed => '生成邀請鏈接失敗';

  @override
  String get invite_createLink => '創建邀請鏈接';

  @override
  String get invite_created => '邀請已創建';

  @override
  String get invite_creating => '創建中...';

  @override
  String get invite_description => '描述 (可選)';

  @override
  String get invite_expandOptions => '編輯鏈接選項或通過電子郵件發送。';

  @override
  String invite_expiryDate(String date) {
    return '截止 $date';
  }

  @override
  String get invite_expiryTime => '有效截止時間';

  @override
  String get invite_fixed => '固定';

  @override
  String get invite_inviteMembers => '邀請成員';

  @override
  String get invite_latestResult => '最新生成結果';

  @override
  String get invite_linkCopied => '邀請鏈接已複製';

  @override
  String get invite_linkGenerated => '邀請鏈接已生成';

  @override
  String get invite_maxRedemptions => '最大使用次數';

  @override
  String get invite_never => '從不';

  @override
  String get invite_noExpiry => '無過期時間';

  @override
  String get invite_noLinks => '暫無生成邀請鏈接';

  @override
  String get invite_permissionDenied => '服務端拒絕了當前賬號的邀請權限';

  @override
  String invite_rateLimited(String waitText) {
    return '出錯了：您執行此操作的次數過多。請等待 $waitText 後再試。';
  }

  @override
  String get invite_restriction => '限制為 (可選)';

  @override
  String get invite_restrictionHelper => '填寫郵箱或域名';

  @override
  String get invite_restrictionHint => 'name@example.com 或者 example.com';

  @override
  String get invite_shareSubject => 'Linux.do 邀請鏈接';

  @override
  String get invite_summaryDay1 => '鏈接最多可用於 1 個用户，並且將在 1 天后到期。';

  @override
  String invite_summaryExpiry(String expiry) {
    return '鏈接最多可用於 1 個用户，並且將在 $expiry 後到期。';
  }

  @override
  String get invite_summaryNever => '鏈接最多可用於 1 個用户，並且永不過期。';

  @override
  String get invite_title => '邀請鏈接';

  @override
  String get invite_trustLevelTooLow => '當前賬號尚未達到 L3，無法創建邀請鏈接';

  @override
  String invite_usableCount(int count) {
    return '可用 $count 次';
  }

  @override
  String get appLink_alipay => '支付寶';

  @override
  String get appLink_amap => '高德地圖';

  @override
  String get appLink_baidu => '百度';

  @override
  String get appLink_baiduNetdisk => '百度網盤';

  @override
  String appLink_continueVisitConfirm(String name) {
    return '繼續訪問$name？';
  }

  @override
  String get appLink_ctrip => '攜程';

  @override
  String get appLink_dianping => '大眾點評';

  @override
  String get appLink_dingtalk => '釘釘';

  @override
  String get appLink_douban => '豆瓣';

  @override
  String get appLink_douyin => '抖音';

  @override
  String get appLink_eleme => '餓了麼';

  @override
  String get appLink_email => '郵件';

  @override
  String get appLink_externalApp => '外部應用';

  @override
  String get appLink_fliggy => '飛豬';

  @override
  String get appLink_jd => '京東';

  @override
  String get appLink_kuaishou => '快手';

  @override
  String get appLink_map => '地圖';

  @override
  String get appLink_meituan => '美團';

  @override
  String get appLink_meituanWaimai => '美團外賣';

  @override
  String appLink_openAppConfirm(String name) {
    return '此網站想打開$name應用';
  }

  @override
  String get appLink_phone => '電話';

  @override
  String get appLink_pinduoduo => '拼多多';

  @override
  String get appLink_playStore => 'Play 商店';

  @override
  String get appLink_qqMap => '騰訊地圖';

  @override
  String get appLink_sms => '短信';

  @override
  String get appLink_suning => '蘇寧';

  @override
  String get appLink_taobao => '淘寶';

  @override
  String get appLink_toutiao => '今日頭條';

  @override
  String get appLink_weibo => '微博';

  @override
  String get appLink_weixin => '微信';

  @override
  String get appLink_xiaohongshu => '小紅書';

  @override
  String get appLink_zhihu => '知乎';

  @override
  String get externalLink_blocked => '鏈接已被阻止';

  @override
  String get externalLink_blockedMessage => '此鏈接已被列入黑名單，無法訪問';

  @override
  String get externalLink_contactAdmin => '如有疑問，請聯繫站點管理員';

  @override
  String get externalLink_leavingMessage => '您即將訪問外部網站';

  @override
  String get externalLink_leavingTitle => '即將離開';

  @override
  String get externalLink_securityWarningHint => '可能包含推廣內容或存在安全隱患，請謹慎訪問';

  @override
  String get externalLink_securityWarningMessage => '此鏈接被標記為潛在風險鏈接';

  @override
  String get externalLink_securityWarningTitle => '安全警告';

  @override
  String get externalLink_shortLinkMessage => '此鏈接為短鏈接服務，無法預覽真實目標';

  @override
  String get externalLink_shortLinkTitle => '短鏈接提醒';

  @override
  String get externalLink_shortLinkWarning => '短鏈接可能隱藏真實目的地，請確認來源可信';

  @override
  String get iframe_exitInteraction => '退出交互';

  @override
  String get onebox_linkPreview => '鏈接預覽';

  @override
  String get chat_thread => '線程';

  @override
  String get github_commentedOn => ' 評論於 ';

  @override
  String github_moreFiles(int count) {
    return '... 還有 $count 個文件';
  }

  @override
  String get github_viewFullCode => '點擊查看完整代碼';

  @override
  String metaverse_authFailed(String error) {
    return '授權失敗: $error';
  }

  @override
  String get metaverse_cdkAuthSuccess => 'CDK 授權成功';

  @override
  String get metaverse_cdkDesc => '連接賬户，開啓 CDK 權益';

  @override
  String get metaverse_cdkReauthSuccess => 'CDK 重新授權成功';

  @override
  String get metaverse_cdkService => 'CDK 服務';

  @override
  String get metaverse_comingSoon => '更多服務接入中...';

  @override
  String get metaverse_ldcAuthSuccess => 'LDC 授權成功';

  @override
  String get metaverse_ldcDesc => '連接賬户，開啓積分權益';

  @override
  String get metaverse_ldcReauthSuccess => 'LDC 重新授權成功';

  @override
  String get metaverse_ldcService => 'LDC 積分服務';

  @override
  String get metaverse_myServices => '我的服務';

  @override
  String get metaverse_title => '元宇宙';

  @override
  String get nav_home => '首頁';

  @override
  String get nav_mine => '我的';

  @override
  String toast_authorizationFailed(String error) {
    return '授權失敗: $error';
  }

  @override
  String get toast_credentialCleared => '憑證已清除';

  @override
  String get toast_credentialIncomplete => '請填寫完整的憑證信息';

  @override
  String get toast_credentialSaved => '憑證保存成功';

  @override
  String get toast_networkDisconnected => '網絡連接已斷開';

  @override
  String get toast_networkRestored => '網絡已恢復';

  @override
  String get toast_operationFailedRetry => '操作失敗，請重試';

  @override
  String get toast_pressAgainToExit => '再按一次返回鍵退出';

  @override
  String toast_rewardError(String error) {
    return '打賞失敗: $error';
  }

  @override
  String get toast_rewardFailed => '打賞失敗';

  @override
  String get toast_rewardNotConfigured => '請先配置打賞憑證';

  @override
  String get toast_rewardSuccess => '打賞成功！';

  @override
  String get advancedSettings_networkAdapter => '網絡適配器';

  @override
  String get advancedSettings_networkAdapterDesc => '管理 Cronet 和備用適配器設置';

  @override
  String get networkAdapter_adapterType => '適配器類型';

  @override
  String get networkAdapter_autoFallback => '已自動降級';

  @override
  String get networkAdapter_autoFallbackDesc => '檢測到 Cronet 不可用，已切換到備用適配器';

  @override
  String get networkAdapter_controlOptions => '控制選項';

  @override
  String get networkAdapter_currentStatus => '當前狀態';

  @override
  String get networkAdapter_degradeReason => 'Cronet 降級原因';

  @override
  String get networkAdapter_devTest => '開發者測試';

  @override
  String get networkAdapter_fallback => '備用';

  @override
  String get networkAdapter_fallbackStatus => '降級狀態';

  @override
  String get networkAdapter_forceFallback => '強制使用備用適配器';

  @override
  String get networkAdapter_forceFallbackDesc =>
      '禁用 Cronet，使用 NetworkHttpAdapter';

  @override
  String get networkAdapter_native => '原生';

  @override
  String get networkAdapter_resetFallback => '重置降級狀態';

  @override
  String get networkAdapter_resetFallbackDesc => '清除降級記錄，下次啓動重新嘗試 Cronet';

  @override
  String get networkAdapter_resetSuccess => '已重置，重啓應用後生效';

  @override
  String get networkAdapter_settingSaved => '設置已保存，重啓應用後生效';

  @override
  String get networkAdapter_simulateError => '模擬 Cronet 錯誤';

  @override
  String get networkAdapter_simulateErrorDesc => '觸發降級流程，測試自動降級功能';

  @override
  String get networkAdapter_simulateSuccess => '已觸發模擬降級，請查看降級狀態';

  @override
  String get networkAdapter_title => '網絡適配器';

  @override
  String get networkAdapter_viewReason => '查看降級原因';

  @override
  String get networkSettings_advanced => '高級';

  @override
  String get networkSettings_auxiliary => '輔助功能';

  @override
  String get networkSettings_debug => '調試';

  @override
  String get networkSettings_engine => '網絡引擎';

  @override
  String get networkSettings_maxConcurrent => '最大並發數';

  @override
  String get networkSettings_maxPerWindow => '窗口請求上限';

  @override
  String get networkSettings_proxy => '網絡代理';

  @override
  String get networkSettings_title => '網絡設置';

  @override
  String get networkSettings_windowSeconds => '窗口時長';

  @override
  String get networkSettings_windowSecondsSuffix => '秒';

  @override
  String get network_adapterNativeAndroid => 'Cronet 適配器';

  @override
  String get network_adapterNativeIos => 'Cupertino 適配器';

  @override
  String get network_adapterNetwork => 'Network 適配器';

  @override
  String get network_adapterRhttp => 'rhttp 引擎';

  @override
  String get network_adapterWebView => 'WebView 適配器';

  @override
  String get network_badRequest => '請求參數錯誤';

  @override
  String get network_forbidden => '沒有權限執行此操作';

  @override
  String get network_internalError => '服務器內部錯誤';

  @override
  String get network_notFound => '請求的資源不存在';

  @override
  String get network_postPendingReview => '你的帖子已提交，正在等待審核';

  @override
  String get network_rateLimited => '請求過於頻繁，請稍後再試';

  @override
  String network_rateLimitedWait(String duration) {
    return '請求過於頻繁，請等待 $duration 後再試';
  }

  @override
  String network_requestFailed(int statusCode) {
    return '請求失敗 ($statusCode)';
  }

  @override
  String network_serverUnavailable(int statusCode) {
    return '服務器暫時不可用 ($statusCode)';
  }

  @override
  String get network_serverUnavailableRetry => '服務器暫時不可用，請稍後再試';

  @override
  String get network_unauthorized => '未登錄或登錄已過期';

  @override
  String get network_unprocessable => '請求無法處理';

  @override
  String get rhttpEngine_alwaysUse => '始終使用';

  @override
  String rhttpEngine_currentAdapter(String adapter) {
    return '當前: $adapter';
  }

  @override
  String get rhttpEngine_disabledDesc => '啓用後使用 Rust 網絡引擎';

  @override
  String get rhttpEngine_echFallbackHint =>
      'ECH 啓用時 WebView 仍通過本地代理兜底；rhttp 直連會優先嚐試自身的 ECH';

  @override
  String get rhttpEngine_enabledDesc => 'HTTP/2 多路複用 · Rust reqwest';

  @override
  String get rhttpEngine_proxyDohOnly => '僅代理/DOH';

  @override
  String get rhttpEngine_title => 'rhttp 引擎';

  @override
  String get rhttpEngine_useMode => '使用模式';

  @override
  String get notification_adminNewSuggestions => '網站信息中心有新建議';

  @override
  String get notification_assignedTopic => '話題已分配給你';

  @override
  String get notification_backgroundRunning => '正在後台運行，保持通知接收';

  @override
  String notification_boost(String username) {
    return '$username Boost 了你的帖子';
  }

  @override
  String notification_boostWithContent(String username, String content) {
    return '$username: $content';
  }

  @override
  String notification_boostByMany(String username, int count) {
    return '$username 等 $count 人 Boost 了你的帖子';
  }

  @override
  String get notification_bookmarkReminder => '書籤提醒';

  @override
  String get notification_channelBackground => '後台運行';

  @override
  String get notification_channelBackgroundDesc => '保持 FluxDO 在後台接收通知';

  @override
  String get notification_channelDiscourse => 'Discourse 通知';

  @override
  String get notification_channelDiscourseDesc => '來自 Discourse 論壇的通知';

  @override
  String get notification_chatGroupMention => '羣組在聊天中被提及';

  @override
  String notification_chatInvitation(String username) {
    return '$username 邀請你參與聊天';
  }

  @override
  String notification_chatMention(String username) {
    return '$username 在聊天中提及了你';
  }

  @override
  String notification_chatMessage(String username) {
    return '$username 發送了聊天消息';
  }

  @override
  String notification_chatQuotedPost(String username) {
    return '$username 在聊天中引用了你';
  }

  @override
  String get notification_chatWatchedThread => '你關注的聊天話題有新消息';

  @override
  String get notification_circlesActivity => '圈子有新動態';

  @override
  String get notification_codeReviewApproved => '代碼審核已通過';

  @override
  String notification_createdNewTopic(String username) {
    return '$username 創建了新話題';
  }

  @override
  String get notification_custom => '自定義通知';

  @override
  String notification_editedPost(String username) {
    return '$username 編輯了帖子';
  }

  @override
  String get notification_empty => '暫無通知';

  @override
  String notification_eventInvitation(String username) {
    return '$username 邀請你參加活動';
  }

  @override
  String get notification_eventReminder => '活動提醒';

  @override
  String notification_followingYou(String displayName) {
    return '$displayName 開始關注你';
  }

  @override
  String notification_grantedBadge(String badgeName) {
    return '獲得了 \'$badgeName\'';
  }

  @override
  String notification_groupMessageSummary(String groupName, int count) {
    return '$groupName 收件箱有 $count 條消息';
  }

  @override
  String notification_invitedToPM(String username) {
    return '$username 邀請你參與私信';
  }

  @override
  String notification_invitedToTopic(String username) {
    return '$username 邀請你參與話題';
  }

  @override
  String notification_inviteeAccepted(String displayName) {
    return '$displayName 接受了你的邀請';
  }

  @override
  String notification_liked(String username) {
    return '$username 讚了你的帖子';
  }

  @override
  String notification_likedByMany(String username, int count) {
    return '$username 和其他 $count 人讚了你的帖子';
  }

  @override
  String notification_likedByTwo(String username, String username2) {
    return '$username、$username2 讚了你的帖子';
  }

  @override
  String notification_likedMultiplePosts(String displayName, int count) {
    return '$displayName 點讚了你的 $count 個帖子';
  }

  @override
  String notification_linkedMultiplePosts(String displayName, int count) {
    return '$displayName 鏈接了你的 $count 個帖子';
  }

  @override
  String notification_linkedPost(String username) {
    return '$username 鏈接了你的帖子';
  }

  @override
  String get notification_markAllRead => '全部標為已讀';

  @override
  String notification_membershipAccepted(String groupName) {
    return '加入 \'$groupName\' 的申請已被接受';
  }

  @override
  String notification_membershipPending(int count, String groupName) {
    return '$count 個未處理的 \'$groupName\' 成員申請';
  }

  @override
  String notification_mentioned(String username) {
    return '$username 在帖子中提及了你';
  }

  @override
  String notification_movedPost(String username) {
    return '$username 移動了帖子';
  }

  @override
  String get notification_newFeaturesAvailable => '有新功能可用！';

  @override
  String get notification_newNotification => '新通知';

  @override
  String notification_newPostPublished(String username) {
    return '$username 發佈了新帖子';
  }

  @override
  String get notification_newTopic => '新建話題';

  @override
  String notification_peopleLikedPost(int count) {
    return '$count 人讚了你的帖子';
  }

  @override
  String notification_peopleLinkedPost(int count) {
    return '$count 人鏈接了你的帖子';
  }

  @override
  String get notification_postApproved => '你的帖子已被批准';

  @override
  String notification_privateMsgSent(String username) {
    return '$username 發送了私信';
  }

  @override
  String notification_qaCommented(String username) {
    return '$username 評論了問答';
  }

  @override
  String notification_quoted(String username) {
    return '$username 引用了你的帖子';
  }

  @override
  String notification_reaction(String username) {
    return '$username 對你的帖子做出了反應';
  }

  @override
  String notification_replied(String username) {
    return '$username 回覆了你的帖子';
  }

  @override
  String notification_repliedTopic(String username) {
    return '$username 回覆了話題';
  }

  @override
  String get notification_topicReminder => '話題提醒';

  @override
  String get notification_typeAdminProblems => '管理員問題';

  @override
  String get notification_typeAssignedTopic => '話題指派';

  @override
  String get notification_typeBoost => 'Boost';

  @override
  String get notification_typeBookmarkReminder => '書籤提醒';

  @override
  String get notification_typeChatGroupMention => '羣聊提及';

  @override
  String get notification_typeChatInvitation => '聊天邀請';

  @override
  String get notification_typeChatMention => '聊天提及';

  @override
  String get notification_typeChatMessage => '聊天消息';

  @override
  String get notification_typeChatQuotedPost => '聊天引用';

  @override
  String get notification_typeChatWatchedThread => '聊天關注話題';

  @override
  String get notification_typeCirclesActivity => '圈子活動';

  @override
  String get notification_typeCodeReviewApproved => '代碼審核通過';

  @override
  String get notification_typeCustom => '自定義';

  @override
  String get notification_typeEdited => '編輯';

  @override
  String get notification_typeEventInvitation => '活動邀請';

  @override
  String get notification_typeEventReminder => '活動提醒';

  @override
  String get notification_typeFollowing => '關注';

  @override
  String get notification_typeFollowingCreatedTopic => '關注的用户創建了話題';

  @override
  String get notification_typeFollowingReplied => '關注的用户回覆了';

  @override
  String get notification_typeGrantedBadge => '獲得徽章';

  @override
  String get notification_typeGroupMentioned => '羣組提及';

  @override
  String get notification_typeGroupMessageSummary => '羣組消息摘要';

  @override
  String get notification_typeInvitedToPM => '私信邀請';

  @override
  String get notification_typeInvitedToTopic => '話題邀請';

  @override
  String get notification_typeInviteeAccepted => '邀請已接受';

  @override
  String get notification_typeLiked => '點贊';

  @override
  String get notification_typeLikedConsolidated => '點贊彙總';

  @override
  String get notification_typeLinked => '鏈接';

  @override
  String get notification_typeLinkedConsolidated => '鏈接彙總';

  @override
  String get notification_typeMembershipAccepted => '成員申請已接受';

  @override
  String get notification_typeMembershipConsolidated => '成員申請彙總';

  @override
  String get notification_typeMentioned => '提及';

  @override
  String get notification_typeMovedPost => '帖子移動';

  @override
  String get notification_typeNewFeatures => '新功能';

  @override
  String get notification_typePostApproved => '帖子已批准';

  @override
  String get notification_typePosted => '發帖';

  @override
  String get notification_typePrivateMessage => '私信';

  @override
  String get notification_typeQACommented => '問答評論';

  @override
  String get notification_typeQuoted => '引用';

  @override
  String get notification_typeReaction => '反應';

  @override
  String get notification_typeReplied => '回覆';

  @override
  String get notification_typeTopicReminder => '話題提醒';

  @override
  String get notification_typeUnknown => '未知';

  @override
  String get notification_typeVotesReleased => '投票發佈';

  @override
  String get notification_typeWatchingCategoryOrTag => '關注分類或標籤';

  @override
  String get notification_typeWatchingFirstPost => '關注首帖';

  @override
  String get notification_votesReleased => '投票已發佈';

  @override
  String notification_watchingCategoryNewPost(String username) {
    return '$username 發佈了新帖子';
  }

  @override
  String get notifications_empty => '暫無通知';

  @override
  String get notifications_markAllRead => '全部標為已讀';

  @override
  String get notifications_title => '通知';

  @override
  String get poll_closed => '已關閉';

  @override
  String get poll_count => '計數';

  @override
  String get poll_percentage => '百分比';

  @override
  String get poll_undo => '撤銷';

  @override
  String get poll_viewResults => '查看結果';

  @override
  String get poll_vote => '投票';

  @override
  String poll_voters(int count) {
    return '$count 投票人';
  }

  @override
  String get post_acceptSolution => '採納為解決方案';

  @override
  String get post_collapseReplies => '收起回覆';

  @override
  String get post_contentRequired => '請輸入內容';

  @override
  String get post_deleteReplyConfirm => '確定要刪除這條回覆嗎？此操作可以撤銷。';

  @override
  String get post_deleteReplyTitle => '刪除回覆';

  @override
  String get post_detail => '帖子詳情';

  @override
  String get post_discardConfirm => '你想放棄你的帖子嗎？';

  @override
  String get post_discardTitle => '放棄帖子';

  @override
  String post_editPostTitle(int postNumber) {
    return '編輯帖子 #$postNumber';
  }

  @override
  String post_firstPostNotice(String username) {
    return '這是 $username 的首次發帖——讓我們歡迎 TA 加入社區！';
  }

  @override
  String get post_flagDescriptionHint => '請描述具體問題...';

  @override
  String get post_flagFailed => '舉報失敗，請稍後重試';

  @override
  String post_flagMessageUser(String username) {
    return '向 @$username 發送消息';
  }

  @override
  String get post_flagNotifyModerators => '私下通知管理人員';

  @override
  String get post_flagSubmitted => '舉報已提交';

  @override
  String get post_flagTitle => '舉報帖子';

  @override
  String get post_generateShareImage => '生成分享圖片';

  @override
  String get post_lastReadHere => '上次看到這裏';

  @override
  String post_loadContentFailed(String error) {
    return '加載內容失敗: $error';
  }

  @override
  String get post_loadMoreReplies => '加載更多回復';

  @override
  String get post_longTimeAgo => '很久以前';

  @override
  String get post_meBadge => '我';

  @override
  String post_moreLinks(int count) {
    return '還有 $count 條';
  }

  @override
  String get post_noReactions => '暫無回應';

  @override
  String get post_opBadge => '主';

  @override
  String get post_pendingReview => '你的帖子已提交，正在等待審核';

  @override
  String get post_reactions => '回應';

  @override
  String get post_relatedLinks => '相關鏈接';

  @override
  String post_relatedRepliesCount(int count) {
    return '相關回覆共 $count 條';
  }

  @override
  String post_replyCount(int count) {
    return '$count 條回覆';
  }

  @override
  String get post_replySent => '回覆已發送';

  @override
  String get post_replySentAction => '查看';

  @override
  String get post_replyTo => '回覆給';

  @override
  String get post_replyToTopic => '回覆話題';

  @override
  String post_replyToUser(String username) {
    return '回覆 @$username';
  }

  @override
  String post_returningUserNotice(String username, String timeText) {
    return '好久不見 $username——TA 的上一條帖子是 $timeText。';
  }

  @override
  String post_sendPmTitle(String username) {
    return '發送私信給 @$username';
  }

  @override
  String get post_solutionAccepted => '已採納為解決方案';

  @override
  String get post_solutionUnaccepted => '已取消採納';

  @override
  String get post_solved => '已解決';

  @override
  String get post_submitFlag => '提交舉報';

  @override
  String get post_tipLdc => '打賞 LDC';

  @override
  String get post_titleRequired => '請輸入標題';

  @override
  String get post_topicSolved => '此話題已解決';

  @override
  String get post_unacceptSolution => '取消採納';

  @override
  String get post_unsolved => '待解決';

  @override
  String get post_viewBestAnswer => '查看最佳答案';

  @override
  String get post_viewHiddenInfo => '查看隱藏的信息';

  @override
  String get post_whisperIndicator => '僅管理員可見';

  @override
  String get smallAction_archivedDisabled => '取消歸檔了話題';

  @override
  String get smallAction_archivedEnabled => '歸檔了話題';

  @override
  String get smallAction_autobumped => '自動頂帖';

  @override
  String get smallAction_autoclosedDisabled => '話題被自動打開';

  @override
  String get smallAction_autoclosedEnabled => '話題被自動關閉';

  @override
  String get smallAction_bannerDisabled => '移除了橫幅';

  @override
  String get smallAction_bannerEnabled => '將話題設為橫幅';

  @override
  String get smallAction_categoryChanged => '更新了類別';

  @override
  String get smallAction_closedDisabled => '打開了話題';

  @override
  String get smallAction_closedEnabled => '關閉了話題';

  @override
  String get smallAction_forwarded => '轉發了郵件';

  @override
  String get smallAction_invitedGroup => '邀請了';

  @override
  String get smallAction_invitedUser => '邀請了';

  @override
  String get smallAction_openTopic => '轉換為話題';

  @override
  String get smallAction_pinnedDisabled => '取消置頂了話題';

  @override
  String get smallAction_pinnedEnabled => '置頂了話題';

  @override
  String get smallAction_pinnedGloballyDisabled => '取消全站置頂';

  @override
  String get smallAction_pinnedGloballyEnabled => '全站置頂了話題';

  @override
  String get smallAction_privateTopic => '轉換為私信';

  @override
  String get smallAction_publicTopic => '轉換為公開話題';

  @override
  String get smallAction_removedGroup => '移除了';

  @override
  String get smallAction_removedUser => '移除了';

  @override
  String get smallAction_splitTopic => '拆分了話題';

  @override
  String get smallAction_tagsChanged => '更新了標籤';

  @override
  String get smallAction_userLeft => '離開了對話';

  @override
  String get smallAction_visibleDisabled => '取消公開了話題';

  @override
  String get smallAction_visibleEnabled => '公開了話題';

  @override
  String get vote_cancelled => '已取消投票';

  @override
  String get vote_closed => '已關閉';

  @override
  String get vote_label => '投票';

  @override
  String get vote_pleaseLogin => '請先登錄';

  @override
  String get vote_success => '投票成功';

  @override
  String get vote_successNoRemaining => '投票成功，您的投票已用完';

  @override
  String vote_successRemaining(int remaining) {
    return '投票成功，剩餘 $remaining 票';
  }

  @override
  String get vote_topicClosed => '話題已關閉，無法投票';

  @override
  String get vote_voted => '已投票';

  @override
  String get preheat_logoutConfirm => '確定要退出當前賬號嗎？退出後將清除本地登錄信息。';

  @override
  String get preheat_logoutMessage => '用户主動退出登錄（預熱失敗頁面）';

  @override
  String get preheat_networkSettings => '網絡設置';

  @override
  String get preheat_retryConnection => '重試連接';

  @override
  String get preheat_userSkipped => '用户跳過預加載';

  @override
  String table_rowCount(int count) {
    return '共 $count 行';
  }

  @override
  String get httpProxy_auth => '認證';

  @override
  String get httpProxy_base64PskHint => '請輸入 Base64 編碼後的 32 字節預共享密鑰';

  @override
  String get httpProxy_cipher => '加密算法';

  @override
  String get httpProxy_cipherNotSet => '未設置算法';

  @override
  String get httpProxy_configTitle => '配置上游代理';

  @override
  String get httpProxy_disabledDesc =>
      '為本地網關配置遠端 HTTP / SOCKS5 / Shadowsocks 代理';

  @override
  String get httpProxy_disabledHint =>
      '開啓後會保留代理模式開關，由本地網關統一接管 Dio、WebView 和 Shadowsocks 出口';

  @override
  String get httpProxy_dohProxyHint =>
      '當前會通過本地 DoH 網關轉發到上游代理；關閉 DoH 時會切換為純代理轉發';

  @override
  String httpProxy_enabledDesc(String protocol) {
    return '已啓用 $protocol 上游代理，由本地網關統一轉發';
  }

  @override
  String get httpProxy_fillServerAndPort => '請填寫服務器地址和端口';

  @override
  String get httpProxy_importSsLink => '導入 ss:// 鏈接';

  @override
  String httpProxy_importedNode(String remarks) {
    return '已導入節點：$remarks';
  }

  @override
  String get httpProxy_keyBase64Psk => '密鑰（Base64 PSK）';

  @override
  String get httpProxy_password => '密碼';

  @override
  String get httpProxy_port => '端口';

  @override
  String get httpProxy_portHint => '例如：8080 或 1080';

  @override
  String get httpProxy_portInvalid => '端口無效';

  @override
  String get httpProxy_protocol => '協議';

  @override
  String get httpProxy_proxyAutoTest => '保存後會自動測試，也可以手動重新測試';

  @override
  String get httpProxy_requireAuth => '需要認證';

  @override
  String get httpProxy_selectSsCipher => '請選擇受支持的 Shadowsocks 加密算法';

  @override
  String get httpProxy_server => '上游代理服務器';

  @override
  String get httpProxy_serverAddress => '服務器地址';

  @override
  String get httpProxy_serverAddressHint =>
      '例如：192.168.1.1 或 proxy.example.com';

  @override
  String get httpProxy_ssConfigSaved => '保存後會校驗 Shadowsocks 配置，並建議返回首頁做實際訪問驗證';

  @override
  String get httpProxy_ssImportSuccess => 'Shadowsocks 鏈接導入成功';

  @override
  String get httpProxy_ssLink => 'Shadowsocks 鏈接';

  @override
  String get httpProxy_suppressedByVpn => '已被 VPN 自動關閉，VPN 斷開後將自動恢復';

  @override
  String get httpProxy_testAvailability => '測試代理可用性';

  @override
  String get httpProxy_testingProxy => '正在驗證是否能通過當前代理訪問 linux.do';

  @override
  String get httpProxy_testingSsConfig => '正在校驗 Shadowsocks 配置是否可由本地網關接管';

  @override
  String get httpProxy_title => '上游代理';

  @override
  String httpProxy_username(String username) {
    return '用户名: $username';
  }

  @override
  String get httpProxy_usernameLabel => '用户名';

  @override
  String get proxy_cannotConnect => '無法連接代理服務器';

  @override
  String get proxy_connectionClosed => '連接已被遠端關閉';

  @override
  String get proxy_fillAddressPort => '請先填寫代理地址和端口';

  @override
  String get proxy_httpAuthFailed => 'HTTP 代理認證失敗（407）';

  @override
  String proxy_httpConnectFailed(String statusLine) {
    return 'HTTP 代理 CONNECT 失敗：$statusLine';
  }

  @override
  String get proxy_notConfigured => '未配置代理服務器';

  @override
  String get proxy_responseTimeout => '等待代理響應超時';

  @override
  String get proxy_socks5AddrTypeNotSupported => '地址類型不支持';

  @override
  String get proxy_socks5AuthFailed => 'SOCKS5 認證失敗';

  @override
  String get proxy_socks5AuthRejected => 'SOCKS5 不接受當前認證方式';

  @override
  String get proxy_socks5CommandNotSupported => '命令不支持';

  @override
  String proxy_socks5ConnectFailed(String reply) {
    return 'SOCKS5 CONNECT 失敗：$reply';
  }

  @override
  String get proxy_socks5ConnectInvalidVersion => 'SOCKS5 CONNECT 響應版本無效';

  @override
  String get proxy_socks5ConnectionRefused => '目標拒絕連接';

  @override
  String get proxy_socks5CredentialsTooLong => 'SOCKS5 用户名或密碼過長';

  @override
  String get proxy_socks5GeneralFailure => '普通失敗';

  @override
  String get proxy_socks5HostUnreachable => '主機不可達';

  @override
  String get proxy_socks5HostnameTooLong => 'SOCKS5 目標主機名過長';

  @override
  String get proxy_socks5InvalidVersion => 'SOCKS5 響應版本無效';

  @override
  String get proxy_socks5NetworkUnreachable => '網絡不可達';

  @override
  String get proxy_socks5NotAllowed => '規則不允許';

  @override
  String get proxy_socks5TtlExpired => 'TTL 已過期';

  @override
  String proxy_socks5UnknownAddrType(String hex) {
    return 'SOCKS5 返回了未知地址類型：0x$hex';
  }

  @override
  String proxy_socks5UnknownError(String hex) {
    return '未知錯誤（0x$hex）';
  }

  @override
  String proxy_socks5UnsupportedAuth(String hex) {
    return 'SOCKS5 返回了不支持的認證方式：0x$hex';
  }

  @override
  String get proxy_ss2022KeyHint => '請填寫 Shadowsocks 2022 的密鑰（Base64 PSK）';

  @override
  String get proxy_ss2022KeyInvalidBase64 =>
      'Shadowsocks 2022 密鑰必須是有效的 Base64 字符串';

  @override
  String proxy_ss2022KeyInvalidLength(int length) {
    return 'Shadowsocks 2022 密鑰長度無效：解碼後必須為 $length 字節';
  }

  @override
  String get proxy_ssBase64DecodeFailed => 'ss:// 鏈接 Base64 解碼失敗';

  @override
  String get proxy_ssCannotParseCipher => '無法解析加密算法和密碼';

  @override
  String get proxy_ssIncomplete => 'Shadowsocks 配置不完整';

  @override
  String get proxy_ssInvalidIpv6 => 'IPv6 地址格式無效';

  @override
  String get proxy_ssInvalidPort => '端口無效';

  @override
  String get proxy_ssLinkContentEmpty => 'ss:// 鏈接內容為空';

  @override
  String get proxy_ssLinkEmpty => '鏈接不能為空';

  @override
  String get proxy_ssMissingAddress => '缺少服務器地址';

  @override
  String get proxy_ssMissingPort => '缺少端口';

  @override
  String get proxy_ssOnlySsProtocol => '僅支持 ss:// 鏈接';

  @override
  String get proxy_ssPasswordHint => '請填寫 Shadowsocks 密碼';

  @override
  String get proxy_ssSaved => 'Shadowsocks 配置已保存';

  @override
  String get proxy_ssSavedDetail =>
      '當前版本會通過本地網關接管 Shadowsocks 出站；請啓用代理後返回首頁進行實際訪問驗證';

  @override
  String get proxy_ssSelectCipher => '請選擇受支持的 Shadowsocks 加密算法';

  @override
  String proxy_ssUnsupportedCipher(String ciphers) {
    return '當前版本僅支持 $ciphers';
  }

  @override
  String proxy_targetResponseError(String statusLine) {
    return '目標站點響應異常：$statusLine';
  }

  @override
  String get proxy_testFailed => '代理測試失敗';

  @override
  String get proxy_testSuccess => '代理可用';

  @override
  String proxy_testSuccessDetail(String protocol, String host, int statusCode) {
    return '已通過 $protocol 代理訪問 $host，HTTP $statusCode';
  }

  @override
  String get proxy_testTimeout => '代理測試超時';

  @override
  String proxy_testTimeoutDetail(int seconds, String host) {
    return '連接或握手超過 $seconds 秒，未能完成 $host 可用性驗證';
  }

  @override
  String get proxy_testTlsFailed => 'TLS 握手失敗';

  @override
  String get vpnToggle_and => ' 和 ';

  @override
  String get vpnToggle_connected => 'VPN 已連接';

  @override
  String get vpnToggle_disconnected => 'VPN 未連接';

  @override
  String get vpnToggle_subtitle => '檢測到 VPN 時自動關閉 DOH 和代理，斷開後恢復';

  @override
  String get vpnToggle_suppressedSuffix => '已被自動關閉，VPN 斷開後將自動恢復';

  @override
  String get vpnToggle_title => 'VPN 自動切換';

  @override
  String get vpnToggle_upstreamProxy => '上游代理';

  @override
  String get cdk_balance => 'CDK 積分';

  @override
  String get cdk_points => '積分';

  @override
  String get cdk_reAuthHint => '請重新授權以查看積分';

  @override
  String get ldc_balance => 'LDC 餘額';

  @override
  String ldc_dailyIncome(String amount) {
    return '今日收入 $amount';
  }

  @override
  String get ldc_reAuthHint => '請重新授權以查看餘額';

  @override
  String get reward_authFailed => '認證失敗，請檢查 Client ID 和 Client Secret';

  @override
  String get reward_clearCredential => '清除憑證';

  @override
  String get reward_configDialogTitle => '配置 LDC 打賞憑證';

  @override
  String get reward_configHint => '請輸入在 credit.linux.do 申請的憑證';

  @override
  String get reward_configured => '已配置，可在帖子中打賞';

  @override
  String reward_confirmMessage(String target, int amount) {
    return '確定向 $target 打賞 $amount LDC 嗎？';
  }

  @override
  String get reward_confirmTitle => '確認打賞';

  @override
  String get reward_createApp => '創建應用';

  @override
  String get reward_customAmount => '自定義金額';

  @override
  String get reward_defaultError => '打賞失敗';

  @override
  String reward_duplicateWarning(int remaining) {
    return '請勿重複打賞，$remaining秒後可再次操作';
  }

  @override
  String get reward_goToCreateApp => '前往創建應用 →';

  @override
  String reward_httpError(int statusCode) {
    return '請求失敗: HTTP $statusCode';
  }

  @override
  String reward_networkError(String error) {
    return '網絡錯誤: $error';
  }

  @override
  String get reward_notConfigured => '配置憑證以啓用打賞功能';

  @override
  String get reward_noteHint => '感謝分享！';

  @override
  String get reward_noteLabel => '備註（可選）';

  @override
  String get reward_selectAmount => '選擇金額';

  @override
  String get reward_selectOrInputAmount => '請選擇或輸入金額';

  @override
  String get reward_sheetTitle => '打賞 LDC';

  @override
  String reward_submitWithAmount(int amount) {
    return '打賞 $amount LDC';
  }

  @override
  String get reward_title => 'LDC 打賞';

  @override
  String reward_unknownError(String error) {
    return '未知錯誤: $error';
  }

  @override
  String get search_advancedSearch => '高級搜索';

  @override
  String search_afterDate(String date) {
    return '$date 之後';
  }

  @override
  String get search_applyFilter => '應用篩選';

  @override
  String search_beforeDate(String date) {
    return '$date 之前';
  }

  @override
  String get search_category => '分類';

  @override
  String search_categoryLoadFailed(String error) {
    return '加載分類失敗: $error';
  }

  @override
  String get search_clearAll => '清除全部';

  @override
  String get search_currentFilter => '當前篩選';

  @override
  String get search_custom => '自定義';

  @override
  String get search_dateRange => '時間範圍';

  @override
  String get search_emptyHint => '輸入關鍵詞搜索';

  @override
  String get search_error => '搜索出錯';

  @override
  String get search_filterBookmarks => '書籤';

  @override
  String get search_filterCreated => '我的話題';

  @override
  String get search_filterSeen => '瀏覽歷史';

  @override
  String get search_hintText => '搜索 @用户 #分類 tags:標籤';

  @override
  String get search_lastMonth => '最近一月';

  @override
  String get search_lastWeek => '最近一週';

  @override
  String get search_lastYear => '最近一年';

  @override
  String search_likeCount(String count) {
    return '$count 點贊';
  }

  @override
  String get search_noLimit => '不限';

  @override
  String get search_noPopularTags => '暫無熱門標籤';

  @override
  String get search_noResults => '沒有找到相關結果';

  @override
  String get search_popularTags => '熱門標籤';

  @override
  String get search_recentSearches => '最近搜索';

  @override
  String search_replyCount(int count) {
    return '$count 條回覆';
  }

  @override
  String search_resultCount(int count, String more) {
    return '$count$more 條結果';
  }

  @override
  String get search_selectDateRange => '選擇時間範圍';

  @override
  String get search_selectedTags => '已選標籤';

  @override
  String get search_sortLabel => '排序：';

  @override
  String get search_sortLatest => '最新帖子';

  @override
  String get search_sortLatestTopic => '最新話題';

  @override
  String get search_sortLikes => '最受歡迎';

  @override
  String get search_sortRelevance => '相關性';

  @override
  String get search_sortViews => '最多瀏覽';

  @override
  String get search_status => '狀態';

  @override
  String get search_statusArchived => '已歸檔';

  @override
  String get search_statusClosed => '已關閉';

  @override
  String get search_statusOpen => '進行中';

  @override
  String get search_statusSolved => '已解決';

  @override
  String get search_statusUnsolved => '未解決';

  @override
  String get search_tags => '標籤';

  @override
  String search_tagsLoadFailed(String error) {
    return '加載標籤失敗: $error';
  }

  @override
  String get search_topicSearchHint => '輸入關鍵詞搜索本話題';

  @override
  String get search_tryOtherKeywords => '請嘗試其他關鍵詞';

  @override
  String get search_users => '用户';

  @override
  String search_viewCount(String count) {
    return '$count 瀏覽';
  }

  @override
  String get cfVerify_cooldown => '驗證太頻繁，請稍後再試';

  @override
  String get cfVerify_desc => '手動觸發過盾驗證';

  @override
  String get cfVerify_failed => '驗證未通過';

  @override
  String get cfVerify_success => '驗證成功';

  @override
  String get cfVerify_title => 'Cloudflare 驗證';

  @override
  String get cf_abandonVerifyMessage => '退出驗證將導致相關功能無法使用，確定要退出嗎？';

  @override
  String get cf_abandonVerifyTitle => '放棄驗證？';

  @override
  String get cf_autoVerifyTimeout => '自動驗證超時，請手動完成驗證';

  @override
  String get cf_backgroundVerifying => '後台驗證中... (點擊打開)';

  @override
  String get cf_cannotOpenVerifyPage => '無法打開驗證頁面，請稍後重試';

  @override
  String get cf_challengeFailedCooldown => '安全驗證失敗，已進入冷卻期，請稍後再試';

  @override
  String get cf_challengeNotEffective => '驗證未生效，請稍後重試';

  @override
  String get cf_continueVerify => '繼續驗證';

  @override
  String get cf_cooldown => '請稍後再試';

  @override
  String get cf_failedRetry => '安全驗證失敗，請重試';

  @override
  String cf_failedWithCause(String cause) {
    return '安全驗證失敗: $cause';
  }

  @override
  String get cf_helpContent =>
      '這是 Cloudflare 安全驗證頁面。\n\n請完成頁面上的驗證挑戰（如勾選框或滑塊）。\n\n驗證成功後會自動關閉此頁面。\n\n如果長時間無法完成，可以嘗試：\n• 點擊刷新按鈕重新加載\n• 檢查網絡連接\n• 關閉後稍後再試';

  @override
  String get cf_helpTitle => '驗證幫助';

  @override
  String cf_loadFailed(String description) {
    return '加載失敗: $description';
  }

  @override
  String get cf_securityVerifyTitle => '安全驗證';

  @override
  String get cf_userCancelled => '驗證已取消';

  @override
  String get cf_verifyIncomplete => '驗證未完成，請重試';

  @override
  String cf_verifyLonger(int seconds) {
    return '驗證時間較長，還剩 $seconds 秒';
  }

  @override
  String get cf_verifyTimeout => '驗證超時，請重試';

  @override
  String cf_verifying(int seconds) {
    return '驗證中... ${seconds}s';
  }

  @override
  String get hcaptcha_clear => '清除';

  @override
  String get hcaptcha_clearConfirm => '確定要清除 hCaptcha 無障礙 Cookie 嗎？';

  @override
  String get hcaptcha_cookieCleared => 'hCaptcha 無障礙 Cookie 已清除';

  @override
  String get hcaptcha_cookieNotFound => '未找到 hCaptcha 無障礙 Cookie，請先完成註冊';

  @override
  String get hcaptcha_cookieNotSet => 'Cookie 未設置';

  @override
  String get hcaptcha_cookieSaved => 'hCaptcha 無障礙 Cookie 已保存';

  @override
  String get hcaptcha_cookieSet => 'Cookie 已設置 ✓';

  @override
  String get hcaptcha_done => '完成';

  @override
  String get hcaptcha_pasteCookie => '貼上 Cookie';

  @override
  String get hcaptcha_pasteDialogDesc =>
      '在瀏覽器中訪問 hCaptcha 無障礙頁面註冊後，從瀏覽器開發者工具中複製名為 hc_accessibility 的 Cookie 值貼上到下方。';

  @override
  String get hcaptcha_pasteDialogHint => '請輸入 hc_accessibility Cookie 值';

  @override
  String get hcaptcha_pasteDialogTitle => '貼上 hCaptcha Cookie';

  @override
  String get hcaptcha_pasteLink => '貼上登錄鏈接';

  @override
  String get hcaptcha_pasteLinkInvalid => '剪貼板中沒有有效的 hCaptcha 鏈接';

  @override
  String get hcaptcha_subtitle => '視障用戶可跳過 hCaptcha 驗證';

  @override
  String get hcaptcha_title => 'hCaptcha 無障礙';

  @override
  String get hcaptcha_webviewGet => 'WebView 獲取';

  @override
  String get hcaptcha_webviewTitle => 'hCaptcha 無障礙';

  @override
  String get config_seedUserTitle => '種子用户';

  @override
  String get preferences_advanced => '高級';

  @override
  String get preferences_androidNativeCdp => 'WebView Cookie 同步';

  @override
  String get preferences_androidNativeCdpDesc => '優先使用原生 CDP；異常時可關閉並回退相容模式。';

  @override
  String get preferences_anonymousShare => '匿名分享';

  @override
  String get preferences_anonymousShareDesc => '分享鏈接時不附帶個人用户標識';

  @override
  String get preferences_autoFillLogin => '自動填充登錄';

  @override
  String get preferences_autoFillLoginDesc => '記住賬號密碼，登錄時自動填充';

  @override
  String get preferences_autoPanguSpacing => '自動混排優化';

  @override
  String get preferences_autoPanguSpacingDesc => '輸入時自動插入中英文混排空格';

  @override
  String get preferences_basic => '基礎';

  @override
  String get preferences_cfClearanceRefresh => 'cf_clearance 自動續期';

  @override
  String get preferences_cfClearanceRefreshDesc =>
      '透過後台 WebView 自動續期 cf_clearance Cookie';

  @override
  String get preferences_crashlytics => '崩潰日誌上報';

  @override
  String get preferences_crashlyticsDesc => '發生崩潰時自動上報日誌，幫助開發者定位問題';

  @override
  String get preferences_editor => '編輯器';

  @override
  String get preferences_enableCrashlyticsContent =>
      '本應用使用 Firebase Crashlytics 收集崩潰信息以改進應用穩定性。\n\n收集嘅數據包括設備信息同崩潰詳情，唔包含個人隱私數據。您可以喺設置中關閉此功能。';

  @override
  String get preferences_enableCrashlyticsTitle => '數據收集說明';

  @override
  String get preferences_enterUrl => '輸入 URL';

  @override
  String get preferences_hideBarOnScroll => '滾動收起導航欄';

  @override
  String get preferences_hideBarOnScrollDesc => '首頁滾動時自動收起頂欄和底欄';

  @override
  String get preferences_longPressPreview => '長按預覽';

  @override
  String get preferences_longPressPreviewDesc => '長按話題卡片快速預覽內容';

  @override
  String get preferences_openLinksInApp => '外部鏈接使用內置瀏覽器';

  @override
  String get preferences_openLinksInAppDesc => '貼內外部鏈接優先在應用內打開';

  @override
  String get preferences_portraitLock => '豎屏鎖定';

  @override
  String get preferences_portraitLockDesc => '鎖定屏幕方向為豎屏';

  @override
  String get preferences_stickerSource => '表情包數據源';

  @override
  String get preferences_title => '功能設置';

  @override
  String get settings_about => '關於 FluxDO';

  @override
  String get settings_appearance => '外觀設定';

  @override
  String get settings_dataManagement => '資料管理';

  @override
  String get settings_network => '網絡設定';

  @override
  String get settings_preferences => '功能設定';

  @override
  String get settings_reading => '閱讀設定';

  @override
  String get settings_searchEmpty => '未找到匹配的設定項';

  @override
  String get settings_searchHint => '搜尋設定項...';

  @override
  String get settings_shortcuts => '快捷鍵';

  @override
  String get settings_title => '應用設定';

  @override
  String get shortcuts_closeOverlay => '關閉浮層';

  @override
  String shortcuts_conflict(String action) {
    return '與「$action」衝突';
  }

  @override
  String get shortcuts_content => '內容';

  @override
  String get shortcuts_createTopic => '建立話題';

  @override
  String get shortcuts_customizeHint => '在 設定 > 快捷鍵 中自訂';

  @override
  String get shortcuts_navigateBack => '返回';

  @override
  String get shortcuts_navigateBackAlt => '返回（備用）';

  @override
  String get shortcuts_navigation => '導覽';

  @override
  String get shortcuts_nextItem => '下一個條目';

  @override
  String get shortcuts_nextTab => '下一個分類';

  @override
  String get shortcuts_openItem => '開啟選中條目';

  @override
  String get shortcuts_openSearch => '搜尋';

  @override
  String get shortcuts_openSettings => '開啟設定';

  @override
  String get shortcuts_previousItem => '上一個條目';

  @override
  String get shortcuts_previousTab => '上一個分類';

  @override
  String get shortcuts_recordKey => '請按下新的快捷鍵組合';

  @override
  String get shortcuts_refresh => '重新整理';

  @override
  String get shortcuts_resetAll => '恢復所有預設';

  @override
  String get shortcuts_resetOne => '恢復預設';

  @override
  String get shortcuts_showHelp => '快捷鍵說明';

  @override
  String get shortcuts_switchPane => '切換面板焦點';

  @override
  String get shortcuts_switchToProfile => '切換到個人';

  @override
  String get shortcuts_switchToTopics => '切換到話題';

  @override
  String get shortcuts_toggleAiPanel => 'AI 助手面板';

  @override
  String get shortcuts_toggleNotifications => '通知面板';

  @override
  String get download_alreadyInProgress => '已有下載任務正在進行';

  @override
  String get download_checksumFailed => '文件校驗失敗，下載的文件可能已損壞';

  @override
  String get download_connecting => '正在連接...';

  @override
  String download_downloading(String name) {
    return '正在下載 $name';
  }

  @override
  String download_failed(String error) {
    return '下載失敗: $error';
  }

  @override
  String download_failedWithError(String error) {
    return '下載失敗: $error';
  }

  @override
  String download_installFailed(String error) {
    return '安裝失敗: $error';
  }

  @override
  String get download_installStarted => '已開始安裝';

  @override
  String get download_installing => '正在安裝...';

  @override
  String get download_internalError => '下載安裝過程中發生內部錯誤';

  @override
  String get download_noInstallPermission => '未授予安裝權限，請在設置中允許安裝未知應用';

  @override
  String get download_verifying => '正在校驗文件...';

  @override
  String export_exporting(int progress, int total) {
    return '導出中 ($progress/$total)';
  }

  @override
  String get export_exportingNoProgress => '導出中...';

  @override
  String export_failed(String error) {
    return '導出失敗: $error';
  }

  @override
  String get export_fetchPostsFailed => '獲取帖子數據失敗';

  @override
  String get export_firstPostOnly => '僅主帖';

  @override
  String get export_format => '導出格式';

  @override
  String export_markdownLimit(int max) {
    return 'Markdown 格式最多導出前 $max 條帖子';
  }

  @override
  String get export_noPostsToExport => '沒有可導出的帖子';

  @override
  String get export_range => '導出範圍';

  @override
  String get export_title => '導出文章';

  @override
  String get share_aiAssistant => 'AI 助手';

  @override
  String get share_aiQuestion => '提問';

  @override
  String get share_aiReply => 'AI 回覆';

  @override
  String get share_aiReplyAlt => 'AI 助手回覆';

  @override
  String get share_cannotGetPostId => '無法獲取主帖 ID';

  @override
  String get share_copyFailed => '複製失敗，請重試';

  @override
  String get share_exportChatImage => '導出對話圖片';

  @override
  String get share_exportImage => '導出圖片';

  @override
  String get share_generatedByAi => '由 FluxDO AI 助手生成';

  @override
  String get share_getPostFailed => '獲取主帖失敗';

  @override
  String get share_imageCopied => '圖片已複製';

  @override
  String get share_imageSaved => '圖片已保存到相冊';

  @override
  String get share_loadingPost => '正在加載帖子...';

  @override
  String get share_replyToTopic => '回覆話題';

  @override
  String get share_saveFailed => '保存失敗，請重試';

  @override
  String get share_savePermissionDenied => '保存失敗，請授予相冊權限';

  @override
  String get share_saveToGallery => '保存到相冊';

  @override
  String get share_fileSaved => '文件已保存';

  @override
  String get share_selectSaveLocation => '選擇保存位置';

  @override
  String get share_screenshotFailed => '截圖失敗';

  @override
  String get share_shareImageTitle => '分享圖片';

  @override
  String get share_themeBlack => '純黑';

  @override
  String get share_themeBlue => '藍調';

  @override
  String get share_themeClassic => '經典';

  @override
  String get share_themeDark => '深色';

  @override
  String get share_themeGreen => '綠野';

  @override
  String get share_themeWhite => '純白';

  @override
  String get share_uploadFailed => '上傳失敗，請重試';

  @override
  String get share_uploading => '正在上傳...';

  @override
  String time_days(int count) {
    return '$count 天';
  }

  @override
  String time_daysAgo(int count) {
    return '$count天前';
  }

  @override
  String time_fullDate(int year, int month, int day) {
    return '$year年$month月$day日';
  }

  @override
  String time_hours(int count) {
    return '$count 小時';
  }

  @override
  String time_hoursAgo(int count) {
    return '$count小時前';
  }

  @override
  String get time_justNow => '剛剛';

  @override
  String time_minutes(int count) {
    return '$count 分鐘';
  }

  @override
  String time_minutesAgo(int count) {
    return '$count分鐘前';
  }

  @override
  String time_monthsAgo(int count) {
    return '$count個月前';
  }

  @override
  String time_seconds(int count) {
    return '$count 秒';
  }

  @override
  String time_shortDate(int month, int day) {
    return '$month月$day日';
  }

  @override
  String get time_today => '今天';

  @override
  String time_tooltipTime(
    int year,
    int month,
    int day,
    String hour,
    String minute,
    String second,
  ) {
    return '$year年$month月$day日 $hour:$minute:$second';
  }

  @override
  String time_weeksAgo(int count) {
    return '$count周前';
  }

  @override
  String time_yearsAgo(int count) {
    return '$count年前';
  }

  @override
  String get time_yesterday => '昨天';

  @override
  String get topicDetail_addToReadLater => '加入浮窗';

  @override
  String get topicDetail_addToReadLaterSuccess => '已加入浮窗';

  @override
  String get topicDetail_aiAssistant => 'AI 助手';

  @override
  String get topicDetail_authorOnly => '只看題主';

  @override
  String get topicDetail_cannotOpenBrowser => '無法打開瀏覽器';

  @override
  String get topicDetail_editBookmark => '編輯書籤';

  @override
  String get topicDetail_editTopic => '編輯話題';

  @override
  String get topicDetail_exportArticle => '導出文章';

  @override
  String get topicDetail_generateShareImage => '生成分享圖片';

  @override
  String get topicDetail_hotOnly => '只看熱門';

  @override
  String get topicDetail_loadFailedTapRetry => '加載失敗，點擊重試';

  @override
  String get topicDetail_loading => '加載中...';

  @override
  String get topicDetail_moreOptions => '更多選項';

  @override
  String get topicDetail_openInBrowser => '在瀏覽器打開';

  @override
  String topicDetail_readLaterFull(int max) {
    return '浮窗已滿（最多 $max 個）';
  }

  @override
  String get topicDetail_removeFromReadLater => '移出浮窗';

  @override
  String get topicDetail_removeFromReadLaterSuccess => '已從浮窗移除';

  @override
  String get topicDetail_replyLabel => '回覆';

  @override
  String get topicDetail_scrollToTop => '回到頂部';

  @override
  String get topicDetail_searchHint => '在本話題中搜索...';

  @override
  String get topicDetail_searchTopic => '搜索本話題';

  @override
  String topicDetail_setToLevel(String level) {
    return '已設置為$level';
  }

  @override
  String get topicDetail_shareLink => '分享鏈接';

  @override
  String topicDetail_showHiddenReplies(int count) {
    return '顯示 $count 條隱藏回覆';
  }

  @override
  String get topicDetail_topLevelOnly => '只看頂層';

  @override
  String get topicDetail_viewAll => '查看全部';

  @override
  String get topicDetail_viewsLabel => '瀏覽';

  @override
  String get topicSort_activity => '活躍度';

  @override
  String get topicSort_created => '創建時間';

  @override
  String get topicSort_default => '默認';

  @override
  String get topicSort_likes => '點贊數';

  @override
  String get topicSort_posters => '參與者';

  @override
  String get topicSort_posts => '回覆數';

  @override
  String get topicSort_views => '瀏覽量';

  @override
  String get topic_addTags => '添加標籤';

  @override
  String get topic_aiSummary => 'AI 摘要';

  @override
  String get topic_atCurrentPosition => '正位於此';

  @override
  String get topic_createdAt => '創建於 ';

  @override
  String get topic_currentFloor => '當前樓層';

  @override
  String get topic_filterHot => '熱門';

  @override
  String get topic_filterLatest => '最新';

  @override
  String get topic_filterNew => '新話題';

  @override
  String topic_filterTooltip(String label) {
    return '篩選: $label';
  }

  @override
  String get topic_filterTop => '排行榜';

  @override
  String get topic_filterUnread => '未讀完';

  @override
  String get topic_filterUnseen => '未瀏覽';

  @override
  String get topic_flagInappropriate => '不當內容';

  @override
  String get topic_flagInappropriateDesc => '此帖子包含不適當的內容';

  @override
  String get topic_flagOffTopic => '離題';

  @override
  String get topic_flagOffTopicDesc => '此帖子與當前討論無關，應該移動到其他話題';

  @override
  String get topic_flagOther => '其他問題';

  @override
  String get topic_flagOtherDesc => '需要版主關注的其他問題';

  @override
  String get topic_flagSpam => '垃圾信息';

  @override
  String get topic_flagSpamDesc => '此帖子是廣告或垃圾信息';

  @override
  String get topic_generateAiSummary => '生成 AI 摘要';

  @override
  String get topic_generatingSummary => '正在生成摘要...';

  @override
  String get topic_jump => '跳轉';

  @override
  String get topic_lastReply => '最後回覆 ';

  @override
  String get topic_levelMuted => '靜音';

  @override
  String get topic_levelMutedDesc => '不接收任何通知';

  @override
  String get topic_levelRegular => '常規';

  @override
  String get topic_levelRegularDesc => '只在被 @ 提及或回覆時通知';

  @override
  String get topic_levelTracking => '跟蹤';

  @override
  String get topic_levelTrackingDesc => '顯示未讀計數';

  @override
  String get topic_levelWatching => '關注';

  @override
  String get topic_levelWatchingDesc => '每個新回覆都通知';

  @override
  String topic_likeCount(String count) {
    return '$count 點贊';
  }

  @override
  String topic_minTagsRequired(int min) {
    return '至少選擇 $min 個標籤';
  }

  @override
  String topic_newRepliesSinceSummary(int count) {
    return '有 $count 條新回覆';
  }

  @override
  String get topic_noSummary => '暫無摘要';

  @override
  String get topic_notificationSettings => '訂閲設置';

  @override
  String get topic_participants => '參與者';

  @override
  String get topic_readyToJump => '準備跳轉';

  @override
  String topic_remainingTags(int remaining) {
    return '還需 $remaining 個標籤';
  }

  @override
  String topic_replyCount(int count) {
    return '$count 條回覆';
  }

  @override
  String get topic_selectCategory => '選擇分類';

  @override
  String topic_sortTooltip(String label) {
    return '排序: $label';
  }

  @override
  String get topic_summaryLoadFailed => '加載摘要失敗';

  @override
  String topic_tagGroupRequirement(String name, int minCount) {
    return '從 $name 選擇 $minCount 個';
  }

  @override
  String get topic_updatedAt => '更新於 ';

  @override
  String topic_viewCount(String count) {
    return '$count 瀏覽';
  }

  @override
  String get topicsScreen_createTopic => '創建話題';

  @override
  String get topicsScreen_myDrafts => '我的草稿';

  @override
  String get topics_browseCategories => '瀏覽分類';

  @override
  String get topics_debugJump => '調試：跳轉話題';

  @override
  String get topics_dismiss => '忽略';

  @override
  String topics_dismissConfirmContent(String label) {
    return '確定要忽略全部$label嗎？';
  }

  @override
  String get topics_dismissConfirmTitle => '忽略確認';

  @override
  String get topics_jump => '跳轉';

  @override
  String get topics_jumpToTopic => '跳轉到話題';

  @override
  String get topics_newTopics => '新話題';

  @override
  String get topics_noTopics => '沒有相關話題';

  @override
  String get topics_searchHint => '搜索話題...';

  @override
  String get topics_topicId => '話題 ID';

  @override
  String get topics_topicIdHint => '例如: 1095754';

  @override
  String get topics_unreadTopics => '未讀話題';

  @override
  String topics_viewNewTopics(int count) {
    return '查看 $count 個新的或更新的話題';
  }

  @override
  String get followList_followers => '粉絲';

  @override
  String get followList_following => '關注';

  @override
  String get privateMessages_title => '私訊';

  @override
  String get privateMessages_inbox => '最新';

  @override
  String get privateMessages_sent => '已發送';

  @override
  String get privateMessages_archive => '歸檔';

  @override
  String get privateMessages_empty => '暫無私訊';

  @override
  String get profileStats_addItems => '點擊添加統計項';

  @override
  String get profileStats_allItemsAdded => '所有統計項已添加';

  @override
  String get profileStats_availableItems => '可添加項目';

  @override
  String get profileStats_bookmarkCount => '書簽數';

  @override
  String get profileStats_columnsPerRow => '每行數量';

  @override
  String get profileStats_dataSource => '數據來源';

  @override
  String get profileStats_daysVisited => '訪問天數';

  @override
  String get profileStats_editTitle => '統計卡片自訂';

  @override
  String get profileStats_enabledItems => '已添加項目';

  @override
  String get profileStats_guideMessage => '點擊統計卡片可自訂展示項目、佈局和數據來源';

  @override
  String get profileStats_incompatibleSource => '不兼容當前數據來源';

  @override
  String get profileStats_layoutGrid => '網格';

  @override
  String get profileStats_layoutMode => '佈局模式';

  @override
  String get profileStats_layoutScroll => '滾動';

  @override
  String get profileStats_layoutSettings => '佈局設定';

  @override
  String get profileStats_likesGiven => '送贊';

  @override
  String get profileStats_likesReceived => '獲贊';

  @override
  String get profileStats_likesReceivedDays => '獲贊天數';

  @override
  String get profileStats_likesReceivedUsers => '獲贊人數';

  @override
  String get profileStats_loadError => '數據加載失敗，已回退到全量統計';

  @override
  String get profileStats_noItemsSelected => '未選擇任何統計項';

  @override
  String get profileStats_postCount => '發帖數';

  @override
  String get profileStats_postsRead => '已讀帖子';

  @override
  String get profileStats_recentTimeRead => '近60天閱讀';

  @override
  String get profileStats_selectItems => '統計項目';

  @override
  String get profileStats_sourceConnect => '信任等級週期';

  @override
  String get profileStats_sourceDaily => '本日';

  @override
  String get profileStats_sourceMonthly => '本月';

  @override
  String get profileStats_sourceQuarterly => '本季';

  @override
  String get profileStats_sourceSummary => '全量統計';

  @override
  String get profileStats_sourceWeekly => '本週';

  @override
  String get profileStats_sourceYearly => '本年';

  @override
  String get profileStats_timeRead => '閱讀時間';

  @override
  String get profileStats_topicCount => '主題數';

  @override
  String get profileStats_topicsEntered => '瀏覽主題';

  @override
  String get profileStats_topicsRepliedTo => '回覆主題';

  @override
  String get profile_aboutFluxDO => '關於 FluxDO';

  @override
  String get profile_aiModelService => 'AI 模型服務';

  @override
  String get profile_appearance => '外觀設置';

  @override
  String get profile_browsingHistory => '瀏覽歷史';

  @override
  String get profile_cdkReauthSuccess => 'CDK 重新授權成功';

  @override
  String get profile_confirmLogout => '確認退出';

  @override
  String get profile_dataManagement => '數據管理';

  @override
  String get profile_daysVisited => '訪問天數';

  @override
  String get profile_editProfile => '編輯資料';

  @override
  String get profile_inviteLinks => '邀請鏈接';

  @override
  String get profile_ldcReauthSuccess => 'LDC 重新授權成功';

  @override
  String get profile_likesReceived => '獲得點贊';

  @override
  String get profile_loadingData => '加載數據...';

  @override
  String get profile_loggingOut => '正在退出...';

  @override
  String get profile_loginForMore => '登錄後體驗更多功能';

  @override
  String get profile_loginLinuxDo => '登錄 Linux.do';

  @override
  String get profile_logoutContent => '確定要退出登錄嗎？';

  @override
  String get profile_logoutCurrentAccount => '退出當前賬號';

  @override
  String get profile_metaverse => '元宇宙';

  @override
  String get profile_privateMessages => '私訊';

  @override
  String get profile_myBadges => '我的徽章';

  @override
  String get profile_myBookmarks => '我的書籤';

  @override
  String get profile_myDrafts => '我的草稿';

  @override
  String get profile_myTopics => '我的話題';

  @override
  String get profile_networkSettings => '網絡設置';

  @override
  String get profile_notLoggedIn => '未登錄';

  @override
  String get profile_postCount => '發表回覆';

  @override
  String get profile_postsRead => '閲讀帖子';

  @override
  String get profile_preferences => '功能設置';

  @override
  String get profile_settings => '應用設定';

  @override
  String get profile_trustRequirements => '信任要求';

  @override
  String get trustLevel_activity => '活躍程度';

  @override
  String get trustLevel_appBarTitle => '信任要求';

  @override
  String get trustLevel_compliance => '合規記錄';

  @override
  String get trustLevel_interaction => '互動參與';

  @override
  String trustLevel_parseFailed(String error) {
    return '解析失敗: $error';
  }

  @override
  String get trustLevel_parseNotFound => '未找到信任級別信息 (div.card)';

  @override
  String trustLevel_requestFailed(int statusCode) {
    return '請求失敗: $statusCode';
  }

  @override
  String get trustLevel_title => '信任級別要求';

  @override
  String get userProfile_actionCreatedTopic => '發佈了話題';

  @override
  String get userProfile_actionDefault => '動態';

  @override
  String get userProfile_actionLike => '點贊';

  @override
  String get userProfile_actionLiked => '被贊';

  @override
  String get userProfile_actionReplied => '回覆了';

  @override
  String get userProfile_bio => '個人簡介';

  @override
  String userProfile_catPostCount(int count) {
    return '$count 回覆';
  }

  @override
  String userProfile_catTopicCount(int count) {
    return '$count 話題';
  }

  @override
  String get userProfile_follow => '關注';

  @override
  String get userProfile_followed => '已關注';

  @override
  String get userProfile_followers => '粉絲';

  @override
  String get userProfile_following => '關注';

  @override
  String get userProfile_fourMonths => '四個月';

  @override
  String get userProfile_ignored => '已忽略';

  @override
  String get userProfile_joinDate => '加入時間';

  @override
  String get userProfile_laterThisWeek => '本週稍後';

  @override
  String get userProfile_laterToday => '今天稍後';

  @override
  String userProfile_linkClicks(int count) {
    return '$count 次點擊';
  }

  @override
  String get userProfile_location => '位置';

  @override
  String get userProfile_message => '私信';

  @override
  String get userProfile_moreInfo => '更多信息';

  @override
  String get userProfile_mostLiked => '贊最多';

  @override
  String get userProfile_mostLikedBy => '被誰讚的最多';

  @override
  String get userProfile_mostRepliedTo => '最多回復至';

  @override
  String get userProfile_mute => '免打擾';

  @override
  String get userProfile_nextMonday => '下週一';

  @override
  String get userProfile_nextMonth => '下個月';

  @override
  String get userProfile_noBio => '這個人很懶，什麼都沒寫';

  @override
  String get userProfile_noContent => '暫無內容';

  @override
  String get userProfile_noReactions => '暫無回應';

  @override
  String get userProfile_noSummary => '暫無總結數據';

  @override
  String get userProfile_normal => '常規';

  @override
  String get userProfile_oneYear => '一年';

  @override
  String get userProfile_permanent => '永久';

  @override
  String get userProfile_permanentlySilenced => '該用户已被永久禁言';

  @override
  String get userProfile_permanentlySuspended => '該用户已被永久封禁';

  @override
  String get userProfile_reacted => '回應了';

  @override
  String get userProfile_restored => '已恢復常規通知';

  @override
  String get userProfile_selectIgnoreDuration => '選擇忽略時長';

  @override
  String get userProfile_setToIgnore => '已設置為忽略';

  @override
  String get userProfile_setToMute => '已設置為免打擾';

  @override
  String get userProfile_shareUser => '分享用户';

  @override
  String get userProfile_silencedBannerForever => '該用户已被永久禁言';

  @override
  String userProfile_silencedBannerUntil(String date) {
    return '該用户已被禁言至 $date';
  }

  @override
  String get userProfile_silencedStatus => '禁言狀態';

  @override
  String userProfile_silencedUntil(String date) {
    return '禁言至 $date';
  }

  @override
  String get userProfile_sixMonths => '六個月';

  @override
  String get userProfile_statsLikes => '獲贊';

  @override
  String get userProfile_statsReplies => '回覆';

  @override
  String get userProfile_statsTopics => '話題';

  @override
  String get userProfile_statsVisits => '訪問';

  @override
  String get userProfile_suspendedBannerForever => '該用户已被永久封禁';

  @override
  String userProfile_suspendedBannerUntil(String date) {
    return '該用户已被封禁至 $date';
  }

  @override
  String get userProfile_suspendedStatus => '封禁狀態';

  @override
  String userProfile_suspendedUntil(String date) {
    return '封禁至 $date';
  }

  @override
  String get userProfile_tabActivity => '動態';

  @override
  String get userProfile_tabLikes => '贊';

  @override
  String get userProfile_tabReactions => '回應';

  @override
  String get userProfile_tabReplies => '回覆';

  @override
  String get userProfile_tabSummary => '總結';

  @override
  String get userProfile_tabTopics => '話題';

  @override
  String get userProfile_threeMonths => '三個月';

  @override
  String get userProfile_tomorrow => '明天';

  @override
  String get userProfile_topBadges => '熱門徽章';

  @override
  String get userProfile_topCategories => '熱門類別';

  @override
  String get userProfile_topLinks => '熱門鏈接';

  @override
  String get userProfile_topReplies => '熱門回覆';

  @override
  String get userProfile_topTopics => '熱門話題';

  @override
  String userProfile_topicHash(String id) {
    return '話題 #$id';
  }

  @override
  String get userProfile_twoMonths => '兩個月';

  @override
  String get userProfile_twoWeeks => '兩週';

  @override
  String get userProfile_website => '網站';

  @override
  String get user_trustLevel0 => 'L0 新用户';

  @override
  String get user_trustLevel1 => 'L1 基本用户';

  @override
  String get user_trustLevel2 => 'L2 成員';

  @override
  String get user_trustLevel3 => 'L3 活躍用户';

  @override
  String get user_trustLevel4 => 'L4 領袖';

  @override
  String user_trustLevelUnknown(int level) {
    return '等級 $level';
  }

  @override
  String get webviewLogin_clearSaved => '清除已保存的密碼';

  @override
  String get webviewLogin_clearSavedContent => '確定要清除已保存的登錄憑證嗎？下次登錄時需要手動輸入。';

  @override
  String get webviewLogin_clearSavedTitle => '清除已保存的密碼';

  @override
  String get webviewLogin_emailLoginInvalidLink => '無效的登錄鏈接';

  @override
  String get webviewLogin_emailLoginPaste => '粘貼登錄鏈接';

  @override
  String webviewLogin_lastLogin(String username) {
    return '上次登錄: @$username';
  }

  @override
  String get webviewLogin_loginSuccess => '登錄成功！';

  @override
  String get webviewLogin_savedPassword => '已保存的密碼';

  @override
  String get webviewLogin_title => '登錄 Linux.do';

  @override
  String get webview_browser => '瀏覽器';

  @override
  String get webview_cannotOpenBrowser => '無法打開外部瀏覽器';

  @override
  String get webview_goBack => '後退';

  @override
  String get webview_goForward => '前進';

  @override
  String get webview_noAppForLink => '未找到可處理此鏈接的應用';

  @override
  String get webview_openExternal => '在外部瀏覽器打開';

  @override
  String webview_openFailed(String error) {
    return '打開失敗: $error';
  }
}

/// The translations for Chinese, as used in Taiwan (`zh_TW`).
class AppLocalizationsZhTw extends AppLocalizationsZh {
  AppLocalizationsZhTw() : super('zh_TW');

  @override
  String get about_appLogs => '應用日誌';

  @override
  String get about_checkUpdate => '檢查更新';

  @override
  String about_checkUpdateError(String error) {
    return '無法檢查更新，請稍後重試。\n錯誤資訊: $error';
  }

  @override
  String get about_checkUpdateFailed => '檢查更新失敗';

  @override
  String get about_develop => '開發';

  @override
  String get about_developerMode => '開發者模式';

  @override
  String get about_developerModeAlreadyEnabled => '開發者模式已啟用';

  @override
  String get about_developerModeClosed => '已關閉開發者模式';

  @override
  String get about_developerModeEnabled => '已啟用開發者模式';

  @override
  String get about_feedback => '反饋問題';

  @override
  String get about_info => '資訊';

  @override
  String get about_latestVersion => '已是最新版本';

  @override
  String get about_legalese => '非官方 Linux.do 客戶端\n基於 Flutter & Material 3';

  @override
  String about_noUpdateContent(String version) {
    return '當前版本: $version\n您正在使用最新版本的 FluxDO，無需更新。';
  }

  @override
  String get about_openSourceLicense => '開源許可';

  @override
  String get about_sourceCode => '專案原始碼';

  @override
  String get about_tapToDisableDeveloperMode => '點選關閉開發者模式';

  @override
  String get about_title => '關於';

  @override
  String get deviceInfo_dohOff => 'DOH: 關閉';

  @override
  String get deviceInfo_proxyOff => '代理: 關閉';

  @override
  String get update_changelog => '更新內容';

  @override
  String get update_dontRemind => '不再提醒';

  @override
  String get update_newVersionFound => '發現新版本';

  @override
  String get update_now => '立即更新';

  @override
  String get update_rateLimited => 'GitHub API 請求過於頻繁，請稍後再試';

  @override
  String get ai_askSubtitle => 'AI 會基於話題內容為你解答';

  @override
  String get ai_askTitle => '向 AI 助手提問';

  @override
  String get ai_clearChat => '清空聊天';

  @override
  String get ai_clearChatConfirm => '確定要清空所有聊天記錄嗎？';

  @override
  String get ai_clearChatTitle => '清空聊天';

  @override
  String get ai_clearLabel => '清空';

  @override
  String get ai_copiedToClipboard => '已複製到剪貼簿';

  @override
  String get ai_copyLabel => '複製';

  @override
  String get ai_exportImage => '匯出圖片';

  @override
  String get ai_generateFailed => '生成失敗';

  @override
  String get ai_highlights => '有什麼值得關注的';

  @override
  String get ai_highlightsPrompt => '這個話題中有哪些值得關注的資訊或亮點？';

  @override
  String get ai_inputHint => '輸入訊息...';

  @override
  String get ai_likeInDev => '點贊功能開發中...';

  @override
  String get ai_listViewpoints => '列出主要觀點';

  @override
  String get ai_listViewpointsPrompt => '請列出這個話題中各樓層的主要觀點和立場。';

  @override
  String get ai_moreTooltip => '更多';

  @override
  String get ai_multiSelectExport => '多選匯出';

  @override
  String get ai_newSession => '新建會話';

  @override
  String get ai_retryLabel => '重試';

  @override
  String get ai_selectContext => '選擇上下文範圍';

  @override
  String get ai_selectExportMessages => '請選擇要匯出的訊息';

  @override
  String get ai_selectModel => '選擇模型';

  @override
  String ai_selectedCount(int count) {
    return '已選 $count 條';
  }

  @override
  String get ai_sendTooltip => '傳送';

  @override
  String ai_sessionCount(int count) {
    return '$count 條';
  }

  @override
  String get ai_sessionHistory => '會話記錄';

  @override
  String ai_sessionTitle(int index) {
    return '會話 $index';
  }

  @override
  String get ai_stopGenerate => '停止生成';

  @override
  String get ai_summarizePrompt => '請簡要總結這個話題的主要內容和討論要點。';

  @override
  String get ai_summarizeTopic => '總結這個話題';

  @override
  String get ai_swipeHint => '向左滑動可開啟 AI 助手';

  @override
  String get ai_title => 'AI 助手';

  @override
  String get ai_translatePost => '翻譯主帖';

  @override
  String get ai_translatePrompt => '請將主帖內容翻譯成英文。';

  @override
  String get ai_typingIndicator => '正在輸入';

  @override
  String get appearance_appIcon => '應用圖示';

  @override
  String get appearance_colorAmber => '琥珀';

  @override
  String get appearance_colorBlue => '藍色';

  @override
  String get appearance_colorGreen => '綠色';

  @override
  String get appearance_colorIndigo => '靛藍';

  @override
  String get appearance_colorOrange => '橙色';

  @override
  String get appearance_colorPink => '粉色';

  @override
  String get appearance_colorPurple => '紫色';

  @override
  String get appearance_colorRed => '紅色';

  @override
  String get appearance_colorTeal => '青色';

  @override
  String get appearance_contentFontSize => '內容字型大小';

  @override
  String get appearance_dialogBlur => '對話框模糊';

  @override
  String get appearance_dialogBlurDesc => '對話框彈出時模糊背景';

  @override
  String get appearance_font => '字體';

  @override
  String get appearance_fontSystem => '系統預設';

  @override
  String get appearance_iconClassic => '經典';

  @override
  String get appearance_iconModern => '現代';

  @override
  String get appearance_language => '語言';

  @override
  String get appearance_languageEn => 'English';

  @override
  String get appearance_languageSystem => '跟隨系統';

  @override
  String get appearance_languageZhCN => '简体中文';

  @override
  String get appearance_languageZhHK => '繁體中文（香港）';

  @override
  String get appearance_languageZhTW => '繁體中文（台灣）';

  @override
  String get appearance_large => '大';

  @override
  String get appearance_modeAuto => '自動';

  @override
  String get appearance_modeDark => '深色';

  @override
  String get appearance_modeLight => '淺色';

  @override
  String get appearance_panguSpacing => '閱讀混排最佳化';

  @override
  String get appearance_panguSpacingDesc => '瀏覽帖子時自動最佳化中英文間距';

  @override
  String get appearance_reading => '閱讀';

  @override
  String get appearance_schemeVariant => '配色風格';

  @override
  String get appearance_small => '小';

  @override
  String get appearance_switchIconFailed => '切換圖示失敗，請稍後重試';

  @override
  String get appearance_themeColor => '主題色彩';

  @override
  String get appearance_themeMode => '主題模式';

  @override
  String get appearance_title => '外觀';

  @override
  String get layout_selectTopicHint => '選擇一個話題檢視詳情';

  @override
  String get reading_aiSwipeEntry => 'AI 助手滑動入口';

  @override
  String get reading_aiSwipeEntryDesc => '在話題詳情頁向左滑動開啟 AI 助手';

  @override
  String get reading_expandRelatedLinks => '預設展開相關連結';

  @override
  String get reading_expandRelatedLinksDesc => '帖子中的相關連結區域預設展開顯示';

  @override
  String get reading_title => '閱讀設定';

  @override
  String get schemeVariant_content => '內容';

  @override
  String get schemeVariant_expressive => '表現力';

  @override
  String get schemeVariant_fidelity => '高保真';

  @override
  String get schemeVariant_fruitSalad => '繽紛';

  @override
  String get schemeVariant_monochrome => '單色';

  @override
  String get schemeVariant_neutral => '中性';

  @override
  String get schemeVariant_rainbow => '彩虹';

  @override
  String get schemeVariant_tonalSpot => '柔和色調';

  @override
  String get schemeVariant_vibrant => '鮮明';

  @override
  String get auth_cdkConfirmMessage => 'Linux.do CDK 將獲取你的基本資訊，是否允許？';

  @override
  String get auth_cdkConfirmTitle => '授權確認';

  @override
  String get auth_clearDataAction => '清理資料';

  @override
  String get auth_cookieRepairLogoutHint =>
      '檢測到歷史登入 Cookie 異常，應用已自動清理相關髒資料。這可能會讓舊的無效登入態立即失效，請重新登入。';

  @override
  String get auth_frequentLogoutClearDataHint =>
      '最近 24 小時內多次觸發登入失效。如果重新登入後仍反覆發生，建議前往「資料管理」清除 Cookie 或全部資料後再登入。';

  @override
  String get auth_ldcConfirmMessage => 'Linux.do Credit 將獲取你的基本資訊，是否允許？';

  @override
  String get auth_ldcConfirmTitle => '授權確認';

  @override
  String get auth_logSubject => '認證日誌';

  @override
  String get auth_loginExpiredRelogin => '登入已失效，請重新登入';

  @override
  String get auth_loginExpiredTitle => '登入失效';

  @override
  String auth_oauthExpired(String serviceName) {
    return '$serviceName 授權已過期';
  }

  @override
  String get login_browserHint => '將在瀏覽器中開啟登入頁面';

  @override
  String get login_slogan => '真誠、友善、團結、專業';

  @override
  String get migration_cookieUpgrade => '正在升級 Cookie 儲存...';

  @override
  String get migration_reloginRequired =>
      '本次版本升級優化了 Cookie 儲存機制，已清除舊的登入狀態。請重新登入。';

  @override
  String get migration_title => '資料升級';

  @override
  String get oauth_approvePageParseFailed => '授權頁面解析失敗，請確認已登入論壇';

  @override
  String get oauth_callbackFailed => '授權回調失敗';

  @override
  String get oauth_getAuthUrlFailed => '獲取授權連結失敗';

  @override
  String get oauth_missingParams => '授權回調缺少必要參數';

  @override
  String get oauth_networkError => '網路請求失敗，請檢查網路連線';

  @override
  String get oauth_noRedirectResponse => '授權服務未返回重定向';

  @override
  String get onboarding_guestAccess => '遊客訪問';

  @override
  String get onboarding_networkSettings => '網路設定';

  @override
  String get onboarding_slogan => '真誠 · 友善 · 團結 · 專業';

  @override
  String get badge_bronze => '銅牌';

  @override
  String get badge_bronzeBadge => '銅牌徽章';

  @override
  String get badge_defaultName => '徽章';

  @override
  String get badge_gold => '金牌';

  @override
  String get badge_goldBadge => '金牌徽章';

  @override
  String badge_grantedCount(int count) {
    return '已授予 $count 次';
  }

  @override
  String get badge_grantedSuffix => ' 獲得';

  @override
  String badge_granteeCount(int count) {
    return '$count 位';
  }

  @override
  String get badge_grantees => '獲得者';

  @override
  String get badge_myBadges => '我的徽章';

  @override
  String get badge_noGrantees => '暫無使用者獲得該徽章';

  @override
  String get badge_silver => '銀牌';

  @override
  String get badge_silverBadge => '銀牌徽章';

  @override
  String get myBadges_badgeUnit => '枚徽章';

  @override
  String get myBadges_empty => '暫無徽章';

  @override
  String get myBadges_title => '我的徽章';

  @override
  String get myBadges_totalEarned => '累計獲得';

  @override
  String get bookmark_deleteConfirm => '確定要刪除這個書籤嗎？';

  @override
  String get bookmark_editBookmark => '編輯書籤';

  @override
  String get bookmark_nameHint => '為書籤新增備註...';

  @override
  String get bookmark_nameLabel => '書籤名稱（可選）';

  @override
  String get bookmark_reminderCustom => '自定義';

  @override
  String get bookmark_reminderExpired => '提醒已過期';

  @override
  String get bookmark_reminderNextWeek => '下週';

  @override
  String get bookmark_reminderThreeDays => '3天后';

  @override
  String bookmark_reminderTime(String time) {
    return '提醒時間：$time';
  }

  @override
  String get bookmark_reminderTomorrow => '明天';

  @override
  String get bookmark_reminderTwoHours => '2小時後';

  @override
  String get bookmark_removed => '已取消書籤';

  @override
  String get bookmark_setReminder => '設定提醒';

  @override
  String get bookmarks_cancelReminder => '取消提醒';

  @override
  String get bookmarks_deleted => '已刪除書籤';

  @override
  String get bookmarks_empty => '暫無書籤';

  @override
  String get bookmarks_emptySearchHint => '輸入關鍵詞搜尋書籤';

  @override
  String get bookmarks_expired => ' 已過期';

  @override
  String get bookmarks_reminderCancelled => '已取消提醒';

  @override
  String get bookmarks_searchHint => '在書籤中搜尋...';

  @override
  String get bookmarks_title => '我的書籤';

  @override
  String get readLater_title => '稍後閱讀';

  @override
  String get categoryTopics_createPost => '發帖';

  @override
  String get categoryTopics_empty => '該分類下暫無話題';

  @override
  String get category_addHint => '點選下方分類新增到標籤欄';

  @override
  String get category_allCategories => '全部分類';

  @override
  String get category_available => '可新增';

  @override
  String get category_browse => '瀏覽分類';

  @override
  String get category_dragHint => '拖拽排序，點選移除';

  @override
  String get category_editHint => '點選\"編輯\"新增常用分類到標籤欄';

  @override
  String get category_editMyCategories => '編輯我的分類';

  @override
  String get category_levelMuted => '靜音';

  @override
  String get category_levelMutedDesc => '不接收此分類的任何通知';

  @override
  String get category_levelRegular => '常規';

  @override
  String get category_levelRegularDesc => '只在被 @ 提及或回覆時通知';

  @override
  String get category_levelTracking => '跟蹤';

  @override
  String get category_levelTrackingDesc => '顯示新帖未讀計數';

  @override
  String get category_levelWatching => '關注';

  @override
  String get category_levelWatchingDesc => '每個新回覆都通知';

  @override
  String get category_levelWatchingFirstPost => '關注新話題';

  @override
  String get category_levelWatchingFirstPostDesc => '此分類有新話題時通知';

  @override
  String category_loadFailed(String error) {
    return '載入分類失敗: $error';
  }

  @override
  String get category_myCategories => '我的分類';

  @override
  String get category_noCategories => '暫無分類';

  @override
  String get category_noCategoriesFound => '未找到相關分類';

  @override
  String category_parentAll(String name) {
    return '$name（全部）';
  }

  @override
  String get category_searchHint => '搜尋分類...';

  @override
  String get tagTopics_empty => '該標籤下暫無話題';

  @override
  String tag_maxTagsReached(int max) {
    return '最多隻能選擇 $max 個標籤';
  }

  @override
  String get tag_noTags => '暫無可用標籤';

  @override
  String get tag_noTagsFound => '未找到相關標籤';

  @override
  String tag_requiredGroupWarning(String name, int minCount) {
    return '需從 \"$name\" 標籤組選擇至少 $minCount 個標籤';
  }

  @override
  String tag_requiredTagGroupHint(String name, int minCount) {
    return '需從 \"$name\" 選擇至少 $minCount 個';
  }

  @override
  String get tag_searchHint => '搜尋標籤...';

  @override
  String tag_searchWithCount(int count) {
    return '搜尋標籤 (已選 $count)...';
  }

  @override
  String tag_searchWithMax(int selected, int max) {
    return '搜尋標籤 (已選 $selected/$max)...';
  }

  @override
  String tag_searchWithMin(int selected, int min) {
    return '搜尋標籤 (已選 $selected, 至少 $min)...';
  }

  @override
  String tag_topicCount(int count) {
    return '$count 個話題';
  }

  @override
  String get common_about => '關於';

  @override
  String get common_add => '新增';

  @override
  String get common_addBookmark => '新增書籤';

  @override
  String get common_added => '已新增';

  @override
  String get common_all => '全部';

  @override
  String get common_allow => '允許';

  @override
  String get common_authExpired => '授權已過期';

  @override
  String get common_back => '返回';

  @override
  String get common_bookmarkAdded => '已新增書籤';

  @override
  String get common_bookmarkRemoved => '已取消書籤';

  @override
  String get common_bookmarkUpdated => '書籤已更新';

  @override
  String get common_cancel => '取消';

  @override
  String get common_cannotOpenBrowser => '無法開啟瀏覽器';

  @override
  String get common_checkInput => '請檢查輸入';

  @override
  String get common_checkNetworkRetry => '請檢查網路後重試';

  @override
  String get common_clear => '清除';

  @override
  String common_clearFailed(String error) {
    return '清除失敗: $error';
  }

  @override
  String get common_clipboardUnavailable => '剪貼簿不可用';

  @override
  String get common_close => '關閉';

  @override
  String get common_closePreview => '關閉預覽';

  @override
  String get common_codeCopied => '已複製程式碼';

  @override
  String get common_confirm => '確定';

  @override
  String get common_continue => '繼續';

  @override
  String get common_continueVisit => '繼續訪問';

  @override
  String get common_copiedToClipboard => '已複製到剪貼簿';

  @override
  String get common_copy => '複製';

  @override
  String get common_copyLink => '複製連結';

  @override
  String get common_copyQuote => '複製引用';

  @override
  String get common_custom => '自定義';

  @override
  String get common_decodeAvif => '解碼 AVIF';

  @override
  String get common_delete => '刪除';

  @override
  String get common_deleteBookmark => '刪除書籤';

  @override
  String get common_deleted => '已刪除';

  @override
  String get common_deny => '拒絕';

  @override
  String get common_details => '詳情';

  @override
  String get common_discard => '捨棄';

  @override
  String get common_done => '完成';

  @override
  String get common_edit => '編輯';

  @override
  String get common_editTopic => '編輯話題';

  @override
  String get common_enable => '開啟';

  @override
  String get common_error => '發生錯誤';

  @override
  String get common_errorDetails => '錯誤詳情';

  @override
  String get common_exit => '退出';

  @override
  String get common_exitPreview => '退出預覽';

  @override
  String get common_export => '匯出';

  @override
  String get common_failed => '失敗';

  @override
  String get common_fillComplete => '請填寫完整資訊';

  @override
  String get common_filter => '篩選';

  @override
  String get common_gotIt => '知道了';

  @override
  String get common_help => '幫助';

  @override
  String get common_hint => '提示';

  @override
  String get common_import => '匯入';

  @override
  String get common_later => '稍後';

  @override
  String get common_linkCopied => '連結已複製';

  @override
  String get common_loadFailed => '載入失敗';

  @override
  String get common_loadFailedRetry => '載入失敗，請重試';

  @override
  String get common_loadFailedTapRetry => '載入失敗，點選重試';

  @override
  String get common_loading => '載入中...';

  @override
  String get common_loadingData => '載入資料...';

  @override
  String get common_login => '登入';

  @override
  String get common_logout => '退出登入';

  @override
  String get common_more => '更多';

  @override
  String get common_name => '名稱';

  @override
  String get common_networkDisconnected => '網路連線已斷開';

  @override
  String get common_noContent => '暫無內容';

  @override
  String get common_noData => '暫無資料';

  @override
  String get common_noMore => '沒有更多了';

  @override
  String get common_notConfigured => '未配置';

  @override
  String get common_notSet => '未設定';

  @override
  String get common_notification => '通知';

  @override
  String get common_ok => '好';

  @override
  String common_operationFailed(String error) {
    return '操作失敗：$error';
  }

  @override
  String get common_paste => '貼上';

  @override
  String get common_pleaseLogin => '請先登入';

  @override
  String get common_pleaseWait => '請稍候...';

  @override
  String get common_preview => '預覽';

  @override
  String get common_publish => '釋出';

  @override
  String get common_quote => '引用';

  @override
  String get common_quoteCopied => '已複製引用';

  @override
  String get common_reAuth => '重新授權';

  @override
  String get common_recentlyUsed => '最近使用';

  @override
  String get common_redo => '重做';

  @override
  String get common_refresh => '重新整理';

  @override
  String get common_remove => '移除';

  @override
  String get common_reply => '回覆';

  @override
  String get common_report => '舉報';

  @override
  String get common_reset => '重置';

  @override
  String get common_restore => '恢復';

  @override
  String get common_restoreDefault => '恢復預設';

  @override
  String get common_restored => '已恢復';

  @override
  String get common_retry => '重試';

  @override
  String get common_save => '儲存';

  @override
  String get common_search => '搜尋';

  @override
  String get common_searchHint => '搜尋...';

  @override
  String get common_searchMore => '搜尋更多';

  @override
  String get common_send => '傳送';

  @override
  String get common_share => '分享';

  @override
  String get common_shareFailed => '分享失敗，請重試';

  @override
  String get common_shareImage => '分享圖片';

  @override
  String get common_shareLink => '分享連結';

  @override
  String common_sizeBytes(String size) {
    return '$size 位元組';
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
  String get common_skip => '跳過';

  @override
  String get common_success => '成功';

  @override
  String get common_test => '測試';

  @override
  String get common_title => '標題';

  @override
  String get common_trustRequirements => '信任要求';

  @override
  String get common_understood => '我知道了';

  @override
  String get common_undo => '撤銷';

  @override
  String get common_unknown => '未知';

  @override
  String get common_unknownError => '未知錯誤';

  @override
  String get common_upload => '上傳';

  @override
  String get common_view => '檢視';

  @override
  String get common_viewAll => '檢視全部';

  @override
  String get common_viewDetails => '檢視詳情';

  @override
  String createTopic_charCount(int count) {
    return '$count 字元';
  }

  @override
  String get createTopic_confirmPublish => '確定釋出';

  @override
  String get createTopic_contentHint => '正文內容 (支援 Markdown)...';

  @override
  String get createTopic_continueEditing => '繼續編輯';

  @override
  String get createTopic_discardPost => '放棄帖子';

  @override
  String get createTopic_discardPostContent => '你想放棄你的帖子嗎？';

  @override
  String get createTopic_enterContent => '請輸入內容';

  @override
  String get createTopic_enterTitle => '請輸入標題';

  @override
  String createTopic_loadCategoryFailed(String error) {
    return '載入分類失敗: $error';
  }

  @override
  String createTopic_minContentLength(int min) {
    return '內容至少需要 $min 個字元';
  }

  @override
  String createTopic_minTags(int min) {
    return '此分類至少需要 $min 個標籤';
  }

  @override
  String createTopic_minTitleLength(int min) {
    return '標題至少需要 $min 個字元';
  }

  @override
  String get createTopic_noContent => '（無內容）';

  @override
  String get createTopic_noTitle => '（無標題）';

  @override
  String get createTopic_pendingReview => '你的帖子已提交，正在等待稽核';

  @override
  String get createTopic_restoreDraft => '恢復草稿';

  @override
  String get createTopic_restoreDraftContent => '檢測到未傳送的草稿，是否恢復？';

  @override
  String get createTopic_selectCategory => '請選擇分類';

  @override
  String get createTopic_templateNotModified => '您尚未修改分類别範本內容，確定要釋出嗎？';

  @override
  String get createTopic_title => '建立話題';

  @override
  String get createTopic_titleHint => '鍵入一個吸引人的標題...';

  @override
  String get editTopic_editPm => '編輯私信';

  @override
  String get editTopic_editTopic => '編輯話題';

  @override
  String editTopic_loadContentFailed(String error) {
    return '載入內容失敗: $error';
  }

  @override
  String get backup_invalidFormat => '無效的備份檔案格式';

  @override
  String get backup_missingDataField => '備份檔案格式錯誤：缺少 data 欄位';

  @override
  String get dataManagement_aiChatCleared => 'AI 聊天資料已清除';

  @override
  String get dataManagement_aiChatData => 'AI 聊天資料';

  @override
  String get dataManagement_allCleared => '所有快取已清除，請重新登入';

  @override
  String dataManagement_apiKeysCount(int count) {
    return '包含 $count 個 API Key';
  }

  @override
  String get dataManagement_autoManagement => '自動管理';

  @override
  String dataManagement_backupSource(String version) {
    return '備份來源: v$version';
  }

  @override
  String get dataManagement_backupSubject => 'FluxDO 資料備份';

  @override
  String get dataManagement_cacheManagement => '快取管理';

  @override
  String get dataManagement_calculating => '計算中...';

  @override
  String get dataManagement_clearAiChatContent => '將刪除所有 AI 聊天記錄，此操作不可恢復。';

  @override
  String get dataManagement_clearAiChatTitle => '清除 AI 聊天資料';

  @override
  String get dataManagement_clearAll => '全部清除';

  @override
  String get dataManagement_clearAllCache => '清除所有快取';

  @override
  String get dataManagement_clearAllContent =>
      '將清除所有快取資料，包括圖片快取、AI 聊天資料和 Cookie。\n\n清除 Cookie 後需要重新登入。';

  @override
  String get dataManagement_clearAllTitle => '清除所有快取';

  @override
  String get dataManagement_clearAndLogout => '清除並退出登入';

  @override
  String get dataManagement_clearCookieContent => '清除 Cookie 後需要重新登入，確定要繼續嗎？';

  @override
  String get dataManagement_clearCookieTitle => '清除 Cookie 快取';

  @override
  String get dataManagement_clearOnExit => '退出時清除圖片快取';

  @override
  String get dataManagement_clearOnExitDesc => '下次啟動時自動清除圖片快取';

  @override
  String get dataManagement_confirmImport => '確認匯入';

  @override
  String get dataManagement_cookieCache => 'Cookie 快取';

  @override
  String get dataManagement_cookieCleared => 'Cookie 快取已清除，請重新登入';

  @override
  String get dataManagement_dataBackup => '資料備份';

  @override
  String get dataManagement_exportData => '匯出資料';

  @override
  String get dataManagement_exportDesc => '將偏好設定匯出為檔案';

  @override
  String dataManagement_exportFailed(String error) {
    return '匯出失敗: $error';
  }

  @override
  String dataManagement_exportTime(String time) {
    return '匯出時間: $time';
  }

  @override
  String get dataManagement_imageCache => '圖片快取';

  @override
  String get dataManagement_imageCacheCleared => '圖片快取已清除';

  @override
  String get dataManagement_importAndRestart => '匯入並重啟';

  @override
  String get dataManagement_importData => '匯入資料';

  @override
  String get dataManagement_importDesc => '從備份檔案恢復偏好設定';

  @override
  String dataManagement_importFailed(String error) {
    return '匯入失敗: $error';
  }

  @override
  String get dataManagement_importSuccess => '資料已匯入，請重啟應用';

  @override
  String get dataManagement_importWarning => '匯入後將覆蓋當前對應的設定項，需要重啟應用生效。';

  @override
  String get dataManagement_noCache => '無快取';

  @override
  String dataManagement_settingsCount(int count) {
    return '包含 $count 項設定';
  }

  @override
  String get dataManagement_title => '資料管理';

  @override
  String get appLogs_appStart => '應用啟動';

  @override
  String get appLogs_clearContent => '確定要清除所有日誌嗎？此操作不可撤銷。';

  @override
  String get appLogs_clearLogs => '清除日誌';

  @override
  String get appLogs_clearTitle => '清除日誌';

  @override
  String get appLogs_copyAll => '複製全部';

  @override
  String get appLogs_copyDeviceInfo => '複製裝置資訊';

  @override
  String get appLogs_duration => '耗時';

  @override
  String get appLogs_error => '錯誤';

  @override
  String get appLogs_errorType => '錯誤型別';

  @override
  String get appLogs_event => '事件';

  @override
  String get appLogs_feedbackSending => '正在傳送回報…';

  @override
  String get appLogs_feedbackSent => '回報已傳送';

  @override
  String get appLogs_feedbackTitle => '應用日誌回報';

  @override
  String get appLogs_level => '級別';

  @override
  String get appLogs_lifecycle => '生命週期';

  @override
  String get appLogs_lifecycleEvent => '生命週期事件';

  @override
  String get appLogs_logoutActive => '主動退出';

  @override
  String get appLogs_logoutPassive => '被動退出';

  @override
  String get appLogs_logsCleared => '日誌已清除';

  @override
  String get appLogs_message => '訊息';

  @override
  String get appLogs_method => '方法';

  @override
  String get appLogs_noLogs => '暫無日誌';

  @override
  String get appLogs_noMatchingLogs => '無匹配日誌';

  @override
  String get appLogs_reason => '原因';

  @override
  String get appLogs_request => '請求';

  @override
  String get appLogs_sendFeedback => '私訊回報日誌';

  @override
  String get appLogs_shareLogs => '分享日誌';

  @override
  String get appLogs_shareSubject => '應用日誌';

  @override
  String get appLogs_stack => '堆疊';

  @override
  String get appLogs_stackTrace => '堆疊跟蹤';

  @override
  String get appLogs_statusCode => '狀態碼';

  @override
  String get appLogs_tag => '標籤';

  @override
  String get appLogs_time => '時間';

  @override
  String get appLogs_title => '應用日誌';

  @override
  String get appLogs_type => '型別';

  @override
  String get appLogs_user => '使用者';

  @override
  String get appLogs_userLogin => '使用者登入';

  @override
  String get appLogs_version => '版本';

  @override
  String get debugTools_cfLogs => 'CF 驗證日誌';

  @override
  String get debugTools_cfLogsCleared => 'CF 日誌已清除';

  @override
  String get debugTools_cfLogsDesc => '檢視 Cloudflare 驗證詳情';

  @override
  String get debugTools_cfLogsTitle => 'CF 驗證日誌';

  @override
  String get debugTools_clearCfLogs => '清除 CF 日誌';

  @override
  String get debugTools_clearCfLogsConfirm => '確定要清除所有 CF 驗證日誌嗎？';

  @override
  String get debugTools_clearCfLogsTitle => '清除 CF 日誌';

  @override
  String get debugTools_clearLogs => '清除日誌';

  @override
  String get debugTools_clearLogsConfirm => '確定要清除所有日誌嗎？';

  @override
  String get debugTools_clearLogsTitle => '清除日誌';

  @override
  String get debugTools_debugLogs => '除錯日誌';

  @override
  String get debugTools_exportCfLogs => '匯出 CF 日誌';

  @override
  String get debugTools_logsCleared => '日誌已清除';

  @override
  String get debugTools_noCfLogs => '暫無 CF 驗證日誌';

  @override
  String get debugTools_noCfLogsHint => '觸發 CF 驗證後會產生日誌';

  @override
  String get debugTools_noCfLogsToShare => '暫無 CF 日誌可分享';

  @override
  String get debugTools_noLogs => '暫無日誌';

  @override
  String get debugTools_noLogsHint => '啟用 DOH 併發起請求後會產生日誌';

  @override
  String get debugTools_noLogsToShare => '暫無日誌可分享';

  @override
  String get debugTools_shareLogs => '分享日誌';

  @override
  String get debugTools_viewLogs => '檢視日誌';

  @override
  String get dohDetail_addServer => '新增伺服器';

  @override
  String get dohDetail_bootstrapIpHelper => '直接用 IP 連線 DoH 伺服器，繞過 DNS 解析';

  @override
  String get dohDetail_bootstrapIpHint => '用逗號分隔，如 1.1.1.1, 1.0.0.1';

  @override
  String get dohDetail_bootstrapIpOptional => 'Bootstrap IP（可選）';

  @override
  String get dohDetail_clearCache => '清空快取';

  @override
  String dohDetail_clearDnsCacheFailed(String error) {
    return '清空 DNS 快取失敗: $error';
  }

  @override
  String get dohDetail_copyAddress => '複製地址';

  @override
  String get dohDetail_deleteServer => '刪除伺服器';

  @override
  String dohDetail_deleteServerConfirm(String name) {
    return '確定要刪除 \"$name\" 嗎？';
  }

  @override
  String get dohDetail_dnsCacheCleared => 'DNS 快取已清空';

  @override
  String dohDetail_dnsCacheDesc(int count) {
    return '當前已快取 $count 個域名。代理模式和查詢模式共用快取，TTL 臨近到期會後臺重新整理。';
  }

  @override
  String dohDetail_dnsCacheRefreshed(int count) {
    return 'DNS 快取已強制重新整理（$count 個域名）';
  }

  @override
  String get dohDetail_dnsCacheRefreshedSimple => 'DNS 快取已強制重新整理';

  @override
  String get dohDetail_dnsCacheSection => 'DNS 快取';

  @override
  String get dohDetail_dohAddress => 'DoH 地址';

  @override
  String get dohDetail_dohAddressCopied => '已複製 DoH 地址';

  @override
  String get dohDetail_echSameAsDnsDesc => '使用 DNS 解析伺服器查詢 ECH 配置';

  @override
  String get dohDetail_echServer => 'ECH 伺服器';

  @override
  String get dohDetail_editServer => '編輯伺服器';

  @override
  String get dohDetail_exampleDns => '例如：My DNS';

  @override
  String get dohDetail_forceRefresh => '強制重新整理';

  @override
  String get dohDetail_gatewayDisabledDesc => '已關閉，使用 MITM 雙重 TLS';

  @override
  String get dohDetail_gatewayEnabledDesc => '單次 TLS，透過反向代理轉發';

  @override
  String get dohDetail_gatewayMode => 'Gateway 模式';

  @override
  String get dohDetail_ipAddress => 'IP 地址';

  @override
  String get dohDetail_ipv6Prefer => 'IPv6 優先';

  @override
  String get dohDetail_ipv6PreferDesc => '優先嚐試 IPv6，失敗自動回落 IPv4';

  @override
  String get dohDetail_localDnsCache => '共享本地 DNS 快取';

  @override
  String get dohDetail_noServers => '暫無伺服器';

  @override
  String get dohDetail_processing => '處理中';

  @override
  String dohDetail_refreshDnsCacheFailed(String error) {
    return '強制重新整理 DNS 快取失敗: $error';
  }

  @override
  String get dohDetail_sameAsDns => '與 DNS 相同';

  @override
  String get dohDetail_selectEchServer => '選擇 ECH 伺服器';

  @override
  String get dohDetail_serverIp => '服務端 IP';

  @override
  String get dohDetail_serverIpHint => '指定連線 IP，跳過 DNS 解析';

  @override
  String get dohDetail_servers => '伺服器';

  @override
  String get dohDetail_testAllSpeed => '全部測速';

  @override
  String get dohDetail_testSpeed => '測速';

  @override
  String get dohDetail_testingSpeed => '測速中';

  @override
  String get dohDetail_title => 'DOH 詳細設定';

  @override
  String get dohDetail_urlMustHttps => '地址必須以 https:// 開頭';

  @override
  String get dohSettings_certAllDone => '已完成所有步驟';

  @override
  String get dohSettings_certDialogDesc => 'HTTPS 攔截需要安裝並信任 CA 憑證，每台裝置產生唯一憑證';

  @override
  String get dohSettings_certDialogTitle => 'CA 憑證安裝';

  @override
  String get dohSettings_certDownloadFailed => '描述檔下載失敗';

  @override
  String get dohSettings_certDownloadHint => '點擊下方按鈕，Safari 會彈出下載提示，請點擊「允許」。';

  @override
  String get dohSettings_certDownloadProfile => '下載描述檔';

  @override
  String get dohSettings_certInstall => '安裝';

  @override
  String get dohSettings_certInstallHint => 'HTTPS 攔截需要安裝並信任憑證';

  @override
  String get dohSettings_certInstallProfileHint =>
      '前往 設定 → 一般 → VPN與裝置管理，找到 DOH Proxy CA 描述檔並安裝。';

  @override
  String get dohSettings_certInstalled => 'CA 憑證已安裝';

  @override
  String get dohSettings_certInstalledNext => '已安裝，下一步';

  @override
  String get dohSettings_certOpenSettings => '打開設定';

  @override
  String get dohSettings_certPreparing => '正在準備...';

  @override
  String get dohSettings_certRegenerate => '重新產生憑證';

  @override
  String get dohSettings_certRegenerateFailed => '憑證重新產生失敗';

  @override
  String get dohSettings_certRegenerated => '新憑證已產生';

  @override
  String get dohSettings_certReinstall => '重新安裝';

  @override
  String get dohSettings_certReinstallHint => '點擊可重新安裝或更換憑證';

  @override
  String get dohSettings_certRequired => '需要安裝 CA 憑證';

  @override
  String get dohSettings_certStepDownload => '下載描述檔';

  @override
  String get dohSettings_certStepInstall => '安裝描述檔';

  @override
  String get dohSettings_certStepTrust => '信任憑證';

  @override
  String get dohSettings_certTrustHint =>
      '前往 設定 → 一般 → 關於本機 → 憑證信任設定，開啟 DOH Proxy CA 的信任開關。';

  @override
  String get dohSettings_disabledDesc => '使用系統預設 DNS';

  @override
  String get dohSettings_enabledDesc => '已啟用加密 DNS 解析';

  @override
  String get dohSettings_errorCopied => '已複製錯誤資訊';

  @override
  String get dohSettings_moreSettings => '更多設定';

  @override
  String get dohSettings_moreSettingsDesc => '伺服器、IPv6、ECH 等';

  @override
  String get dohSettings_perDeviceCert => '裝置獨有憑證';

  @override
  String get dohSettings_perDeviceCertDisabledDesc => '啟用後每台裝置產生獨立的 CA 憑證，更安全';

  @override
  String get dohSettings_perDeviceCertEnabledDesc => '已啟用，每台裝置使用獨立 CA 憑證';

  @override
  String dohSettings_port(int port) {
    return '埠 $port';
  }

  @override
  String get dohSettings_proxyNotStarted => '代理未啟動';

  @override
  String get dohSettings_proxyRunning => '代理執行中';

  @override
  String get dohSettings_proxyStartFailed => '代理啟動失敗，DoH/ECH 無法生效';

  @override
  String get dohSettings_restartProxy => '重啟代理';

  @override
  String get dohSettings_restarting => '正在重啟...';

  @override
  String get dohSettings_starting => '正在啟動...';

  @override
  String get dohSettings_suppressedByVpn => '已被 VPN 自動關閉，VPN 斷開後將自動恢復';

  @override
  String get doh_cannotConnect => '無法連線到 DOH 服務';

  @override
  String get doh_executableNotFound => '找不到代理可執行檔案';

  @override
  String get doh_invalidHttpResponse => '無效的 HTTP 響應';

  @override
  String get doh_queryFailed => 'DOH 查詢失敗';

  @override
  String get doh_serverAlibaba => '阿里 DNS';

  @override
  String doh_serverError(String statusLine) {
    return 'DOH 伺服器返回錯誤: $statusLine';
  }

  @override
  String get doh_serverTencent => '騰訊 DNS';

  @override
  String get doh_startTimeout => '代理啟動超時（5秒內未響應）';

  @override
  String get doh_unknownReason => '未知原因';

  @override
  String get codeBlock_chart => '圖表';

  @override
  String get codeBlock_chartLoadFailed => '圖表載入失敗';

  @override
  String get codeBlock_code => '程式碼';

  @override
  String codeBlock_renderFailed(String error) {
    return '程式碼塊渲染失敗: $error';
  }

  @override
  String draft_topicTitle(String id) {
    return '話題 #$id';
  }

  @override
  String get draft_untitled => '無標題';

  @override
  String get drafts_deleteContent => '確定要刪除這個草稿嗎？';

  @override
  String get drafts_deleteDraft => '刪除草稿';

  @override
  String drafts_deleteFailed(String error) {
    return '刪除失敗: $error';
  }

  @override
  String get drafts_deleteTitle => '刪除草稿';

  @override
  String get drafts_deleted => '草稿已刪除';

  @override
  String get drafts_draft => '草稿';

  @override
  String get drafts_empty => '暫無草稿';

  @override
  String get drafts_newTopic => '新話題';

  @override
  String get drafts_pmIncomplete => '私信草稿資料不完整';

  @override
  String get drafts_privateMessage => '私信';

  @override
  String drafts_replyToPost(int number) {
    return '回覆 #$number';
  }

  @override
  String get drafts_title => '我的草稿';

  @override
  String get editor_hintText => '說點什麼吧... (支援 Markdown)';

  @override
  String get editor_noContent => '（無內容）';

  @override
  String get link_insertTitle => '插入連結';

  @override
  String get link_textHint => '顯示的文字';

  @override
  String get link_textLabel => '連結文字';

  @override
  String get link_textRequired => '請輸入連結文字';

  @override
  String get link_urlRequired => '請輸入 URL';

  @override
  String get mention_group => '群組';

  @override
  String get mention_noUserFound => '未找到匹配使用者';

  @override
  String get mention_searchHint => '輸入使用者名稱搜尋';

  @override
  String get template_empty => '暫無可用範本';

  @override
  String get template_insertTitle => '插入範本';

  @override
  String get template_loadError => '載入範本失敗';

  @override
  String get template_searchHint => '搜尋範本…';

  @override
  String get template_tooltip => '範本';

  @override
  String get toolbar_attachFileTooltip => '上傳附件';

  @override
  String get toolbar_boldPlaceholder => '粗體文字';

  @override
  String get toolbar_codePlaceholder => '在此處鍵入或貼上程式碼';

  @override
  String get toolbar_gridMinImages => '需要至少 2 張圖片才能建立網格';

  @override
  String get toolbar_gridNeedConsecutive => '需要至少 2 張連續的圖片才能建立網格';

  @override
  String get toolbar_h1 => 'H1 - 一級標題';

  @override
  String get toolbar_h2 => 'H2 - 二級標題';

  @override
  String get toolbar_h3 => 'H3 - 三級標題';

  @override
  String get toolbar_h4 => 'H4 - 四級標題';

  @override
  String get toolbar_h5 => 'H5 - 五級標題';

  @override
  String get toolbar_imageGridTooltip => '圖片網格';

  @override
  String get toolbar_imagesAlreadyInGrid => '這些圖片已經在網格中了';

  @override
  String get toolbar_italicPlaceholder => '斜體文字';

  @override
  String get toolbar_mixOptimize => '混排最佳化';

  @override
  String get toolbar_quotePlaceholder => '引用文字';

  @override
  String get toolbar_spoilerPlaceholder => '劇透內容';

  @override
  String get toolbar_spoilerTooltip => '劇透';

  @override
  String get toolbar_strikethroughPlaceholder => '刪除線文字';

  @override
  String get emoji_activities => '活動';

  @override
  String get emoji_animals => '動物';

  @override
  String get emoji_flags => '旗幟';

  @override
  String get emoji_food => '食物';

  @override
  String get emoji_loadFailed => '載入表情失敗';

  @override
  String get emoji_notFound => '沒有找到表情';

  @override
  String get emoji_objects => '物體';

  @override
  String get emoji_people => '人物';

  @override
  String get emoji_searchHint => '搜尋表情...';

  @override
  String get emoji_searchNotFound => '未找到相關表情';

  @override
  String get emoji_searchPrompt => '輸入關鍵詞搜尋表情';

  @override
  String get emoji_searchTooltip => '搜尋表情';

  @override
  String get emoji_smileys => '表情';

  @override
  String get emoji_symbols => '符號';

  @override
  String get emoji_tab => '表情';

  @override
  String get emoji_travel => '旅行';

  @override
  String get sticker_addFromMarket => '從市場新增';

  @override
  String get sticker_addTooltip => '新增表情包';

  @override
  String get sticker_added => '已新增';

  @override
  String sticker_emojiCount(int count) {
    return '$count 個表情';
  }

  @override
  String get sticker_groupEmpty => '該分組暫無表情包';

  @override
  String get sticker_loadFailed => '載入表情包失敗';

  @override
  String get sticker_marketEmpty => '暫無可用的表情包';

  @override
  String get sticker_marketLoadFailed => '載入市場失敗';

  @override
  String get sticker_marketTitle => '表情包市場';

  @override
  String get sticker_noStickers => '還沒有表情包';

  @override
  String get sticker_tab => '表情包';

  @override
  String get error_addBookmarkFailed => '新增書籤失敗：響應格式異常';

  @override
  String get error_avifDecodeNoFrames => 'AVIF 解碼失敗：無幀資料';

  @override
  String get error_badRequest => '請求錯誤';

  @override
  String get error_badRequestParams => '請求引數錯誤';

  @override
  String get error_cannotConnectCheckNetwork => '無法在規定時間內連線到伺服器，請檢查網路';

  @override
  String get error_certificateError => '證書異常';

  @override
  String get error_certificateVerifyFailed => '伺服器證書驗證失敗，請檢查網路環境';

  @override
  String get error_connectionTimeout => '連線超時';

  @override
  String get error_contentDeleted => '內容已被刪除';

  @override
  String get error_createTopicFailed => '建立話題失敗';

  @override
  String get error_dataException => '資料異常';

  @override
  String get error_forbidden => '沒有許可權';

  @override
  String get error_forbiddenAccess => '沒有許可權訪問';

  @override
  String get error_gone => '已刪除';

  @override
  String get error_imageFormatUnsupported => '圖片格式不支援或不符合要求';

  @override
  String get error_imageTooBig => '圖片檔案過大，請壓縮後重試';

  @override
  String get error_internalServerError => '伺服器內部錯誤';

  @override
  String get error_loadFailed => '載入失敗';

  @override
  String get error_networkCheckSettings => '網路連線失敗，請檢查網路設定';

  @override
  String get error_networkRequestFailed => '網路請求失敗';

  @override
  String get error_networkUnavailable => '網路不可用';

  @override
  String get error_notFound => '內容不存在';

  @override
  String get error_notFoundOrDeleted => '內容不存在或已被刪除';

  @override
  String get error_notLoggedInNoUsername => '未登入或無法獲取使用者名稱';

  @override
  String get error_providerDisposed => 'Provider 已銷燬';

  @override
  String get error_rateLimited => '請求過於頻繁';

  @override
  String get error_rateLimitedRetryLater => '請求過於頻繁，請稍後再試';

  @override
  String get error_replyFailed => '回覆失敗';

  @override
  String get error_requestCancelled => '請求取消';

  @override
  String get error_requestCancelledMsg => '請求已取消';

  @override
  String get error_requestFailed => '請求失敗';

  @override
  String error_requestFailedWithCode(int statusCode) {
    return '請求失敗 ($statusCode)';
  }

  @override
  String get error_requestTimeoutRetry => '請求超時，請稍後重試';

  @override
  String get error_requestUnprocessable => '請求無法處理';

  @override
  String get error_responseTimeout => '響應超時';

  @override
  String get error_securityChallenge => '安全驗證';

  @override
  String get error_sendPMFailed => '傳送私信失敗';

  @override
  String get error_serverError => '伺服器錯誤';

  @override
  String get error_serverResponseTooLong => '伺服器響應時間過長，請稍後重試';

  @override
  String get error_serverUnavailable => '伺服器不可用';

  @override
  String get error_serviceUnavailable => '伺服器不可用';

  @override
  String get error_serviceUnavailableRetry => '伺服器暫時不可用，請稍後重試';

  @override
  String get error_tooManyRequests => '請求過於頻繁';

  @override
  String get error_topicDetailEmpty => '話題詳情為空';

  @override
  String get error_unauthorized => '未登入';

  @override
  String get error_unauthorizedExpired => '未登入或登入已過期';

  @override
  String get error_unknown => '未知錯誤';

  @override
  String get error_unknownResponseFormat => '未知響應格式';

  @override
  String get error_unprocessable => '無法處理';

  @override
  String get error_unrecognizedDataFormat => '伺服器返回了無法識別的資料格式';

  @override
  String get error_updatePostFailed => '更新帖子失敗：響應格式異常';

  @override
  String get error_uploadNoUrl => '上傳響應中未包含 URL';

  @override
  String get browsingHistory_empty => '暫無瀏覽歷史';

  @override
  String get browsingHistory_emptySearchHint => '輸入關鍵詞搜尋瀏覽歷史';

  @override
  String get browsingHistory_searchHint => '在瀏覽歷史中搜尋...';

  @override
  String get browsingHistory_title => '瀏覽歷史';

  @override
  String get myTopics_empty => '暫無話題';

  @override
  String get myTopics_emptySearchHint => '輸入關鍵詞搜尋我的話題';

  @override
  String get myTopics_searchHint => '在我的話題中搜尋...';

  @override
  String get myTopics_title => '我的話題';

  @override
  String get imageEditor_adjust => '調整';

  @override
  String get imageEditor_applyingChanges => '正在應用更改';

  @override
  String get imageEditor_arrow => '箭頭';

  @override
  String get imageEditor_arrowBoth => '雙端箭頭';

  @override
  String get imageEditor_arrowEnd => '終點箭頭';

  @override
  String get imageEditor_arrowStart => '起點箭頭';

  @override
  String get imageEditor_bgMode => '背景模式';

  @override
  String get imageEditor_blur => '模糊';

  @override
  String get imageEditor_brightness => '亮度';

  @override
  String get imageEditor_brush => '畫筆';

  @override
  String get imageEditor_changeOpacity => '調整透明度';

  @override
  String get imageEditor_circle => '圓形';

  @override
  String get imageEditor_closeWarningMessage => '確定要關閉圖片編輯器嗎？你的更改將不會被儲存。';

  @override
  String get imageEditor_closeWarningTitle => '關閉圖片編輯器？';

  @override
  String get imageEditor_color => '顏色';

  @override
  String get imageEditor_contrast => '對比度';

  @override
  String get imageEditor_cropRotate => '裁剪/旋轉';

  @override
  String get imageEditor_dashDotLine => '點劃線';

  @override
  String get imageEditor_dashLine => '虛線';

  @override
  String get imageEditor_emoji => '表情';

  @override
  String get imageEditor_emojiActivities => '活動';

  @override
  String get imageEditor_emojiAnimals => '動物與自然';

  @override
  String get imageEditor_emojiFlags => '旗幟';

  @override
  String get imageEditor_emojiFood => '食物與飲品';

  @override
  String get imageEditor_emojiObjects => '物品';

  @override
  String get imageEditor_emojiSmileys => '笑臉與人物';

  @override
  String get imageEditor_emojiSymbols => '符號';

  @override
  String get imageEditor_emojiTravel => '旅行與地點';

  @override
  String get imageEditor_eraser => '橡皮擦';

  @override
  String get imageEditor_exposure => '曝光';

  @override
  String get imageEditor_fade => '褪色';

  @override
  String get imageEditor_fill => '填充';

  @override
  String get imageEditor_filter => '濾鏡';

  @override
  String get imageEditor_flip => '翻轉';

  @override
  String get imageEditor_fontSize => '字型大小';

  @override
  String get imageEditor_freeStyle => '自由繪製';

  @override
  String get imageEditor_hexagon => '六邊形';

  @override
  String get imageEditor_hue => '色調';

  @override
  String get imageEditor_initializingEditor => '正在初始化編輯器';

  @override
  String get imageEditor_inputText => '輸入文字';

  @override
  String get imageEditor_line => '直線';

  @override
  String get imageEditor_lineWidth => '線條寬度';

  @override
  String get imageEditor_luminance => '明度';

  @override
  String get imageEditor_noFilter => '無濾鏡';

  @override
  String get imageEditor_opacity => '透明度';

  @override
  String get imageEditor_pixelate => '畫素化';

  @override
  String get imageEditor_polygon => '多邊形';

  @override
  String get imageEditor_ratio => '比例';

  @override
  String get imageEditor_rectangle => '矩形';

  @override
  String get imageEditor_rotate => '旋轉';

  @override
  String get imageEditor_rotateScale => '旋轉和縮放';

  @override
  String get imageEditor_saturation => '飽和度';

  @override
  String get imageEditor_sharpness => '銳度';

  @override
  String get imageEditor_sticker => '貼紙';

  @override
  String get imageEditor_strokeWidth => '線條粗細';

  @override
  String get imageEditor_temperature => '色溫';

  @override
  String get imageEditor_text => '文字';

  @override
  String get imageEditor_textAlign => '文字對齊';

  @override
  String get imageEditor_toggleFill => '切換填充';

  @override
  String get imageEditor_zoom => '縮放';

  @override
  String get imageFormat_generic => '圖片';

  @override
  String get imageFormat_gif => 'GIF 動圖';

  @override
  String get imageFormat_jpeg => 'JPEG 圖片';

  @override
  String get imageFormat_png => 'PNG 圖片';

  @override
  String get imageFormat_webp => 'WebP 圖片';

  @override
  String get imageUpload_compressionQuality => '壓縮質量：';

  @override
  String get imageUpload_confirmTitle => '上傳圖片確認';

  @override
  String get imageUpload_editImage => '編輯圖片';

  @override
  String imageUpload_editNotSupported(String format) {
    return '$format 暫不支援編輯，否則會丟失動畫';
  }

  @override
  String get imageUpload_editNotSupportedLabel => '當前格式不支援編輯';

  @override
  String imageUpload_estimatedSize(String size) {
    return '約 $size';
  }

  @override
  String get imageUpload_gridLayoutHint => '上傳後將自動使用 [grid] 網格佈局';

  @override
  String get imageUpload_keepAtLeastOne => '至少需要保留一張圖片';

  @override
  String imageUpload_keepOriginal(String format) {
    return '$format 將保留原圖上傳，不執行客戶端壓縮。';
  }

  @override
  String imageUpload_multiTitle(int count) {
    return '上傳 $count 張圖片';
  }

  @override
  String imageUpload_originalSize(String size) {
    return '原始大小：$size';
  }

  @override
  String imageUpload_processFailed(String error) {
    return '處理圖片失敗: $error';
  }

  @override
  String imageUpload_totalEstimatedSize(String size) {
    return '約 $size';
  }

  @override
  String imageUpload_totalOriginalSize(String size) {
    return '總大小：$size';
  }

  @override
  String imageUpload_uploadCount(int count) {
    return '上傳 $count 張';
  }

  @override
  String get imageViewer_grantPermission => '請授予相簿訪問許可權';

  @override
  String get imageViewer_imageSaved => '圖片已儲存到相簿';

  @override
  String imageViewer_saveFailed(String error) {
    return '儲存失敗: $error';
  }

  @override
  String get imageViewer_saveFailedRetry => '儲存失敗，請重試';

  @override
  String get image_copied => '圖片已複製';

  @override
  String get image_copyFailed => '複製圖片失敗';

  @override
  String get image_copyImage => '複製圖片';

  @override
  String get image_copyLink => '複製連結';

  @override
  String get image_fetchFailed => '獲取圖片失敗';

  @override
  String get image_viewFull => '檢視大圖';

  @override
  String get invite_collapseOptions => '收起連結選項';

  @override
  String get invite_createFailed => '生成邀請連結失敗';

  @override
  String get invite_createLink => '建立邀請連結';

  @override
  String get invite_created => '邀請已建立';

  @override
  String get invite_creating => '建立中...';

  @override
  String get invite_description => '描述 (可選)';

  @override
  String get invite_expandOptions => '編輯連結選項或透過電子郵件傳送。';

  @override
  String invite_expiryDate(String date) {
    return '截止 $date';
  }

  @override
  String get invite_expiryTime => '有效截止時間';

  @override
  String get invite_fixed => '固定';

  @override
  String get invite_inviteMembers => '邀請成員';

  @override
  String get invite_latestResult => '最新生成結果';

  @override
  String get invite_linkCopied => '邀請連結已複製';

  @override
  String get invite_linkGenerated => '邀請連結已生成';

  @override
  String get invite_maxRedemptions => '最大使用次數';

  @override
  String get invite_never => '從不';

  @override
  String get invite_noExpiry => '無過期時間';

  @override
  String get invite_noLinks => '暫無生成邀請連結';

  @override
  String get invite_permissionDenied => '服務端拒絕了當前賬號的邀請許可權';

  @override
  String invite_rateLimited(String waitText) {
    return '出錯了：您執行此操作的次數過多。請等待 $waitText 後再試。';
  }

  @override
  String get invite_restriction => '限制為 (可選)';

  @override
  String get invite_restrictionHelper => '填寫郵箱或域名';

  @override
  String get invite_restrictionHint => 'name@example.com 或者 example.com';

  @override
  String get invite_shareSubject => 'Linux.do 邀請連結';

  @override
  String get invite_summaryDay1 => '連結最多可用於 1 個使用者，並且將在 1 天后到期。';

  @override
  String invite_summaryExpiry(String expiry) {
    return '連結最多可用於 1 個使用者，並且將在 $expiry 後到期。';
  }

  @override
  String get invite_summaryNever => '連結最多可用於 1 個使用者，並且永不過期。';

  @override
  String get invite_title => '邀請連結';

  @override
  String get invite_trustLevelTooLow => '當前賬號尚未達到 L3，無法建立邀請連結';

  @override
  String invite_usableCount(int count) {
    return '可用 $count 次';
  }

  @override
  String get appLink_alipay => '支付寶';

  @override
  String get appLink_amap => '高德地圖';

  @override
  String get appLink_baidu => '百度';

  @override
  String get appLink_baiduNetdisk => '百度網盤';

  @override
  String appLink_continueVisitConfirm(String name) {
    return '繼續訪問$name？';
  }

  @override
  String get appLink_ctrip => '攜程';

  @override
  String get appLink_dianping => '大眾點評';

  @override
  String get appLink_dingtalk => '釘釘';

  @override
  String get appLink_douban => '豆瓣';

  @override
  String get appLink_douyin => '抖音';

  @override
  String get appLink_eleme => '餓了麼';

  @override
  String get appLink_email => '郵件';

  @override
  String get appLink_externalApp => '外部應用';

  @override
  String get appLink_fliggy => '飛豬';

  @override
  String get appLink_jd => '京東';

  @override
  String get appLink_kuaishou => '快手';

  @override
  String get appLink_map => '地圖';

  @override
  String get appLink_meituan => '美團';

  @override
  String get appLink_meituanWaimai => '美團外賣';

  @override
  String appLink_openAppConfirm(String name) {
    return '此網站想開啟$name應用';
  }

  @override
  String get appLink_phone => '電話';

  @override
  String get appLink_pinduoduo => '拼多多';

  @override
  String get appLink_playStore => 'Play 商店';

  @override
  String get appLink_qqMap => '騰訊地圖';

  @override
  String get appLink_sms => '簡訊';

  @override
  String get appLink_suning => '蘇寧';

  @override
  String get appLink_taobao => '淘寶';

  @override
  String get appLink_toutiao => '今日頭條';

  @override
  String get appLink_weibo => '微博';

  @override
  String get appLink_weixin => '微信';

  @override
  String get appLink_xiaohongshu => '小紅書';

  @override
  String get appLink_zhihu => '知乎';

  @override
  String get externalLink_blocked => '連結已被阻止';

  @override
  String get externalLink_blockedMessage => '此連結已被列入黑名單，無法訪問';

  @override
  String get externalLink_contactAdmin => '如有疑問，請聯絡站點管理員';

  @override
  String get externalLink_leavingMessage => '您即將訪問外部網站';

  @override
  String get externalLink_leavingTitle => '即將離開';

  @override
  String get externalLink_securityWarningHint => '可能包含推廣內容或存在安全隱患，請謹慎訪問';

  @override
  String get externalLink_securityWarningMessage => '此連結被標記為潛在風險連結';

  @override
  String get externalLink_securityWarningTitle => '安全警告';

  @override
  String get externalLink_shortLinkMessage => '此連結為短連結服務，無法預覽真實目標';

  @override
  String get externalLink_shortLinkTitle => '短連結提醒';

  @override
  String get externalLink_shortLinkWarning => '短連結可能隱藏真實目的地，請確認來源可信';

  @override
  String get iframe_exitInteraction => '退出互動';

  @override
  String get onebox_linkPreview => '連結預覽';

  @override
  String get chat_thread => '執行緒';

  @override
  String get github_commentedOn => ' 評論於 ';

  @override
  String github_moreFiles(int count) {
    return '... 還有 $count 個檔案';
  }

  @override
  String get github_viewFullCode => '點選檢視完整程式碼';

  @override
  String metaverse_authFailed(String error) {
    return '授權失敗: $error';
  }

  @override
  String get metaverse_cdkAuthSuccess => 'CDK 授權成功';

  @override
  String get metaverse_cdkDesc => '連線賬戶，開啟 CDK 權益';

  @override
  String get metaverse_cdkReauthSuccess => 'CDK 重新授權成功';

  @override
  String get metaverse_cdkService => 'CDK 服務';

  @override
  String get metaverse_comingSoon => '更多服務接入中...';

  @override
  String get metaverse_ldcAuthSuccess => 'LDC 授權成功';

  @override
  String get metaverse_ldcDesc => '連線賬戶，開啟積分權益';

  @override
  String get metaverse_ldcReauthSuccess => 'LDC 重新授權成功';

  @override
  String get metaverse_ldcService => 'LDC 積分服務';

  @override
  String get metaverse_myServices => '我的服務';

  @override
  String get metaverse_title => '元宇宙';

  @override
  String get nav_home => '首頁';

  @override
  String get nav_mine => '我的';

  @override
  String toast_authorizationFailed(String error) {
    return '授權失敗: $error';
  }

  @override
  String get toast_credentialCleared => '憑證已清除';

  @override
  String get toast_credentialIncomplete => '請填寫完整的憑證資訊';

  @override
  String get toast_credentialSaved => '憑證儲存成功';

  @override
  String get toast_networkDisconnected => '網路連線已斷開';

  @override
  String get toast_networkRestored => '網路已恢復';

  @override
  String get toast_operationFailedRetry => '操作失敗，請重試';

  @override
  String get toast_pressAgainToExit => '再按一次返回鍵退出';

  @override
  String toast_rewardError(String error) {
    return '打賞失敗: $error';
  }

  @override
  String get toast_rewardFailed => '打賞失敗';

  @override
  String get toast_rewardNotConfigured => '請先配置打賞憑證';

  @override
  String get toast_rewardSuccess => '打賞成功！';

  @override
  String get advancedSettings_networkAdapter => '網路介面卡';

  @override
  String get advancedSettings_networkAdapterDesc => '管理 Cronet 和備用介面卡設定';

  @override
  String get networkAdapter_adapterType => '介面卡型別';

  @override
  String get networkAdapter_autoFallback => '已自動降級';

  @override
  String get networkAdapter_autoFallbackDesc => '檢測到 Cronet 不可用，已切換到備用介面卡';

  @override
  String get networkAdapter_controlOptions => '控制選項';

  @override
  String get networkAdapter_currentStatus => '當前狀態';

  @override
  String get networkAdapter_degradeReason => 'Cronet 降級原因';

  @override
  String get networkAdapter_devTest => '開發者測試';

  @override
  String get networkAdapter_fallback => '備用';

  @override
  String get networkAdapter_fallbackStatus => '降級狀態';

  @override
  String get networkAdapter_forceFallback => '強制使用備用介面卡';

  @override
  String get networkAdapter_forceFallbackDesc =>
      '禁用 Cronet，使用 NetworkHttpAdapter';

  @override
  String get networkAdapter_native => '原生';

  @override
  String get networkAdapter_resetFallback => '重置降級狀態';

  @override
  String get networkAdapter_resetFallbackDesc => '清除降級記錄，下次啟動重新嘗試 Cronet';

  @override
  String get networkAdapter_resetSuccess => '已重置，重啟應用後生效';

  @override
  String get networkAdapter_settingSaved => '設定已儲存，重啟應用後生效';

  @override
  String get networkAdapter_simulateError => '模擬 Cronet 錯誤';

  @override
  String get networkAdapter_simulateErrorDesc => '觸發降級流程，測試自動降級功能';

  @override
  String get networkAdapter_simulateSuccess => '已觸發模擬降級，請檢視降級狀態';

  @override
  String get networkAdapter_title => '網路介面卡';

  @override
  String get networkAdapter_viewReason => '檢視降級原因';

  @override
  String get networkSettings_advanced => '高階';

  @override
  String get networkSettings_auxiliary => '輔助功能';

  @override
  String get networkSettings_debug => '除錯';

  @override
  String get networkSettings_engine => '網路引擎';

  @override
  String get networkSettings_maxConcurrent => '最大並行數';

  @override
  String get networkSettings_maxPerWindow => '視窗請求上限';

  @override
  String get networkSettings_proxy => '網路代理';

  @override
  String get networkSettings_title => '網路設定';

  @override
  String get networkSettings_windowSeconds => '視窗時長';

  @override
  String get networkSettings_windowSecondsSuffix => '秒';

  @override
  String get network_adapterNativeAndroid => 'Cronet 介面卡';

  @override
  String get network_adapterNativeIos => 'Cupertino 介面卡';

  @override
  String get network_adapterNetwork => 'Network 介面卡';

  @override
  String get network_adapterRhttp => 'rhttp 引擎';

  @override
  String get network_adapterWebView => 'WebView 介面卡';

  @override
  String get network_badRequest => '請求引數錯誤';

  @override
  String get network_forbidden => '沒有許可權執行此操作';

  @override
  String get network_internalError => '伺服器內部錯誤';

  @override
  String get network_notFound => '請求的資源不存在';

  @override
  String get network_postPendingReview => '你的帖子已提交，正在等待稽核';

  @override
  String get network_rateLimited => '請求過於頻繁，請稍後再試';

  @override
  String network_rateLimitedWait(String duration) {
    return '請求過於頻繁，請等待 $duration 後再試';
  }

  @override
  String network_requestFailed(int statusCode) {
    return '請求失敗 ($statusCode)';
  }

  @override
  String network_serverUnavailable(int statusCode) {
    return '伺服器暫時不可用 ($statusCode)';
  }

  @override
  String get network_serverUnavailableRetry => '伺服器暫時不可用，請稍後再試';

  @override
  String get network_unauthorized => '未登入或登入已過期';

  @override
  String get network_unprocessable => '請求無法處理';

  @override
  String get rhttpEngine_alwaysUse => '始終使用';

  @override
  String rhttpEngine_currentAdapter(String adapter) {
    return '當前: $adapter';
  }

  @override
  String get rhttpEngine_disabledDesc => '啟用後使用 Rust 網路引擎';

  @override
  String get rhttpEngine_echFallbackHint =>
      'ECH 啟用時 WebView 仍透過本地代理兜底；rhttp 直連會優先嚐試自身的 ECH';

  @override
  String get rhttpEngine_enabledDesc => 'HTTP/2 多路複用 · Rust reqwest';

  @override
  String get rhttpEngine_proxyDohOnly => '僅代理/DOH';

  @override
  String get rhttpEngine_title => 'rhttp 引擎';

  @override
  String get rhttpEngine_useMode => '使用模式';

  @override
  String get notification_adminNewSuggestions => '網站資訊中心有新建議';

  @override
  String get notification_assignedTopic => '話題已分配給你';

  @override
  String get notification_backgroundRunning => '正在後臺執行，保持通知接收';

  @override
  String notification_boost(String username) {
    return '$username Boost 了你的帖子';
  }

  @override
  String notification_boostWithContent(String username, String content) {
    return '$username: $content';
  }

  @override
  String notification_boostByMany(String username, int count) {
    return '$username 等 $count 人 Boost 了你的帖子';
  }

  @override
  String get notification_bookmarkReminder => '書籤提醒';

  @override
  String get notification_channelBackground => '後臺執行';

  @override
  String get notification_channelBackgroundDesc => '保持 FluxDO 在後臺接收通知';

  @override
  String get notification_channelDiscourse => 'Discourse 通知';

  @override
  String get notification_channelDiscourseDesc => '來自 Discourse 論壇的通知';

  @override
  String get notification_chatGroupMention => '群組在聊天中被提及';

  @override
  String notification_chatInvitation(String username) {
    return '$username 邀請你參與聊天';
  }

  @override
  String notification_chatMention(String username) {
    return '$username 在聊天中提及了你';
  }

  @override
  String notification_chatMessage(String username) {
    return '$username 傳送了聊天訊息';
  }

  @override
  String notification_chatQuotedPost(String username) {
    return '$username 在聊天中引用了你';
  }

  @override
  String get notification_chatWatchedThread => '你關注的聊天話題有新訊息';

  @override
  String get notification_circlesActivity => '圈子有新動態';

  @override
  String get notification_codeReviewApproved => '程式碼稽核已透過';

  @override
  String notification_createdNewTopic(String username) {
    return '$username 建立了新話題';
  }

  @override
  String get notification_custom => '自定義通知';

  @override
  String notification_editedPost(String username) {
    return '$username 編輯了帖子';
  }

  @override
  String get notification_empty => '暫無通知';

  @override
  String notification_eventInvitation(String username) {
    return '$username 邀請你參加活動';
  }

  @override
  String get notification_eventReminder => '活動提醒';

  @override
  String notification_followingYou(String displayName) {
    return '$displayName 開始關注你';
  }

  @override
  String notification_grantedBadge(String badgeName) {
    return '獲得了 \'$badgeName\'';
  }

  @override
  String notification_groupMessageSummary(String groupName, int count) {
    return '$groupName 收件箱有 $count 條訊息';
  }

  @override
  String notification_invitedToPM(String username) {
    return '$username 邀請你參與私信';
  }

  @override
  String notification_invitedToTopic(String username) {
    return '$username 邀請你參與話題';
  }

  @override
  String notification_inviteeAccepted(String displayName) {
    return '$displayName 接受了你的邀請';
  }

  @override
  String notification_liked(String username) {
    return '$username 讚了你的帖子';
  }

  @override
  String notification_likedByMany(String username, int count) {
    return '$username 和其他 $count 人讚了你的帖子';
  }

  @override
  String notification_likedByTwo(String username, String username2) {
    return '$username、$username2 讚了你的帖子';
  }

  @override
  String notification_likedMultiplePosts(String displayName, int count) {
    return '$displayName 點讚了你的 $count 個帖子';
  }

  @override
  String notification_linkedMultiplePosts(String displayName, int count) {
    return '$displayName 連結了你的 $count 個帖子';
  }

  @override
  String notification_linkedPost(String username) {
    return '$username 連結了你的帖子';
  }

  @override
  String get notification_markAllRead => '全部標為已讀';

  @override
  String notification_membershipAccepted(String groupName) {
    return '加入 \'$groupName\' 的申請已被接受';
  }

  @override
  String notification_membershipPending(int count, String groupName) {
    return '$count 個未處理的 \'$groupName\' 成員申請';
  }

  @override
  String notification_mentioned(String username) {
    return '$username 在帖子中提及了你';
  }

  @override
  String notification_movedPost(String username) {
    return '$username 移動了帖子';
  }

  @override
  String get notification_newFeaturesAvailable => '有新功能可用！';

  @override
  String get notification_newNotification => '新通知';

  @override
  String notification_newPostPublished(String username) {
    return '$username 釋出了新帖子';
  }

  @override
  String get notification_newTopic => '新建話題';

  @override
  String notification_peopleLikedPost(int count) {
    return '$count 人讚了你的帖子';
  }

  @override
  String notification_peopleLinkedPost(int count) {
    return '$count 人連結了你的帖子';
  }

  @override
  String get notification_postApproved => '你的帖子已被批准';

  @override
  String notification_privateMsgSent(String username) {
    return '$username 傳送了私信';
  }

  @override
  String notification_qaCommented(String username) {
    return '$username 評論了問答';
  }

  @override
  String notification_quoted(String username) {
    return '$username 引用了你的帖子';
  }

  @override
  String notification_reaction(String username) {
    return '$username 對你的帖子做出了反應';
  }

  @override
  String notification_replied(String username) {
    return '$username 回覆了你的帖子';
  }

  @override
  String notification_repliedTopic(String username) {
    return '$username 回覆了話題';
  }

  @override
  String get notification_topicReminder => '話題提醒';

  @override
  String get notification_typeAdminProblems => '管理員問題';

  @override
  String get notification_typeAssignedTopic => '話題指派';

  @override
  String get notification_typeBoost => 'Boost';

  @override
  String get notification_typeBookmarkReminder => '書籤提醒';

  @override
  String get notification_typeChatGroupMention => '群聊提及';

  @override
  String get notification_typeChatInvitation => '聊天邀請';

  @override
  String get notification_typeChatMention => '聊天提及';

  @override
  String get notification_typeChatMessage => '聊天訊息';

  @override
  String get notification_typeChatQuotedPost => '聊天引用';

  @override
  String get notification_typeChatWatchedThread => '聊天關注話題';

  @override
  String get notification_typeCirclesActivity => '圈子活動';

  @override
  String get notification_typeCodeReviewApproved => '程式碼稽核透過';

  @override
  String get notification_typeCustom => '自定義';

  @override
  String get notification_typeEdited => '編輯';

  @override
  String get notification_typeEventInvitation => '活動邀請';

  @override
  String get notification_typeEventReminder => '活動提醒';

  @override
  String get notification_typeFollowing => '關注';

  @override
  String get notification_typeFollowingCreatedTopic => '關注的使用者建立了話題';

  @override
  String get notification_typeFollowingReplied => '關注的使用者回覆了';

  @override
  String get notification_typeGrantedBadge => '獲得徽章';

  @override
  String get notification_typeGroupMentioned => '群組提及';

  @override
  String get notification_typeGroupMessageSummary => '群組訊息摘要';

  @override
  String get notification_typeInvitedToPM => '私信邀請';

  @override
  String get notification_typeInvitedToTopic => '話題邀請';

  @override
  String get notification_typeInviteeAccepted => '邀請已接受';

  @override
  String get notification_typeLiked => '點贊';

  @override
  String get notification_typeLikedConsolidated => '點贊彙總';

  @override
  String get notification_typeLinked => '連結';

  @override
  String get notification_typeLinkedConsolidated => '連結彙總';

  @override
  String get notification_typeMembershipAccepted => '成員申請已接受';

  @override
  String get notification_typeMembershipConsolidated => '成員申請彙總';

  @override
  String get notification_typeMentioned => '提及';

  @override
  String get notification_typeMovedPost => '帖子移動';

  @override
  String get notification_typeNewFeatures => '新功能';

  @override
  String get notification_typePostApproved => '帖子已批准';

  @override
  String get notification_typePosted => '發帖';

  @override
  String get notification_typePrivateMessage => '私信';

  @override
  String get notification_typeQACommented => '問答評論';

  @override
  String get notification_typeQuoted => '引用';

  @override
  String get notification_typeReaction => '反應';

  @override
  String get notification_typeReplied => '回覆';

  @override
  String get notification_typeTopicReminder => '話題提醒';

  @override
  String get notification_typeUnknown => '未知';

  @override
  String get notification_typeVotesReleased => '投票釋出';

  @override
  String get notification_typeWatchingCategoryOrTag => '關注分類或標籤';

  @override
  String get notification_typeWatchingFirstPost => '關注首帖';

  @override
  String get notification_votesReleased => '投票已釋出';

  @override
  String notification_watchingCategoryNewPost(String username) {
    return '$username 釋出了新帖子';
  }

  @override
  String get notifications_empty => '暫無通知';

  @override
  String get notifications_markAllRead => '全部標為已讀';

  @override
  String get notifications_title => '通知';

  @override
  String get poll_closed => '已關閉';

  @override
  String get poll_count => '計數';

  @override
  String get poll_percentage => '百分比';

  @override
  String get poll_undo => '撤銷';

  @override
  String get poll_viewResults => '檢視結果';

  @override
  String get poll_vote => '投票';

  @override
  String poll_voters(int count) {
    return '$count 投票人';
  }

  @override
  String get post_acceptSolution => '採納為解決方案';

  @override
  String get post_collapseReplies => '收起回覆';

  @override
  String get post_contentRequired => '請輸入內容';

  @override
  String get post_deleteReplyConfirm => '確定要刪除這條回覆嗎？此操作可以撤銷。';

  @override
  String get post_deleteReplyTitle => '刪除回覆';

  @override
  String get post_detail => '帖子詳情';

  @override
  String get post_discardConfirm => '你想放棄你的帖子嗎？';

  @override
  String get post_discardTitle => '放棄帖子';

  @override
  String post_editPostTitle(int postNumber) {
    return '編輯帖子 #$postNumber';
  }

  @override
  String post_firstPostNotice(String username) {
    return '這是 $username 的首次發帖——讓我們歡迎 TA 加入社群！';
  }

  @override
  String get post_flagDescriptionHint => '請描述具體問題...';

  @override
  String get post_flagFailed => '舉報失敗，請稍後重試';

  @override
  String post_flagMessageUser(String username) {
    return '向 @$username 傳送訊息';
  }

  @override
  String get post_flagNotifyModerators => '私下通知管理人員';

  @override
  String get post_flagSubmitted => '舉報已提交';

  @override
  String get post_flagTitle => '舉報帖子';

  @override
  String get post_generateShareImage => '生成分享圖片';

  @override
  String get post_lastReadHere => '上次看到這裡';

  @override
  String post_loadContentFailed(String error) {
    return '載入內容失敗: $error';
  }

  @override
  String get post_loadMoreReplies => '載入更多回復';

  @override
  String get post_longTimeAgo => '很久以前';

  @override
  String get post_meBadge => '我';

  @override
  String post_moreLinks(int count) {
    return '還有 $count 條';
  }

  @override
  String get post_noReactions => '暫無回應';

  @override
  String get post_opBadge => '主';

  @override
  String get post_pendingReview => '你的帖子已提交，正在等待稽核';

  @override
  String get post_reactions => '回應';

  @override
  String get post_relatedLinks => '相關連結';

  @override
  String post_relatedRepliesCount(int count) {
    return '相關回覆共 $count 條';
  }

  @override
  String post_replyCount(int count) {
    return '$count 條回覆';
  }

  @override
  String get post_replySent => '回覆已傳送';

  @override
  String get post_replySentAction => '檢視';

  @override
  String get post_replyTo => '回覆給';

  @override
  String get post_replyToTopic => '回覆話題';

  @override
  String post_replyToUser(String username) {
    return '回覆 @$username';
  }

  @override
  String post_returningUserNotice(String username, String timeText) {
    return '好久不見 $username——TA 的上一條帖子是 $timeText。';
  }

  @override
  String post_sendPmTitle(String username) {
    return '傳送私信給 @$username';
  }

  @override
  String get post_solutionAccepted => '已採納為解決方案';

  @override
  String get post_solutionUnaccepted => '已取消採納';

  @override
  String get post_solved => '已解決';

  @override
  String get post_submitFlag => '提交舉報';

  @override
  String get post_tipLdc => '打賞 LDC';

  @override
  String get post_titleRequired => '請輸入標題';

  @override
  String get post_topicSolved => '此話題已解決';

  @override
  String get post_unacceptSolution => '取消採納';

  @override
  String get post_unsolved => '待解決';

  @override
  String get post_viewBestAnswer => '檢視最佳答案';

  @override
  String get post_viewHiddenInfo => '檢視隱藏的資訊';

  @override
  String get post_whisperIndicator => '僅管理員可見';

  @override
  String get smallAction_archivedDisabled => '取消歸檔了話題';

  @override
  String get smallAction_archivedEnabled => '歸檔了話題';

  @override
  String get smallAction_autobumped => '自動頂帖';

  @override
  String get smallAction_autoclosedDisabled => '話題被自動開啟';

  @override
  String get smallAction_autoclosedEnabled => '話題被自動關閉';

  @override
  String get smallAction_bannerDisabled => '移除了橫幅';

  @override
  String get smallAction_bannerEnabled => '將話題設為橫幅';

  @override
  String get smallAction_categoryChanged => '更新了類別';

  @override
  String get smallAction_closedDisabled => '開啟了話題';

  @override
  String get smallAction_closedEnabled => '關閉了話題';

  @override
  String get smallAction_forwarded => '轉發了郵件';

  @override
  String get smallAction_invitedGroup => '邀請了';

  @override
  String get smallAction_invitedUser => '邀請了';

  @override
  String get smallAction_openTopic => '轉換為話題';

  @override
  String get smallAction_pinnedDisabled => '取消置頂了話題';

  @override
  String get smallAction_pinnedEnabled => '置頂了話題';

  @override
  String get smallAction_pinnedGloballyDisabled => '取消全站置頂';

  @override
  String get smallAction_pinnedGloballyEnabled => '全站置頂了話題';

  @override
  String get smallAction_privateTopic => '轉換為私信';

  @override
  String get smallAction_publicTopic => '轉換為公開話題';

  @override
  String get smallAction_removedGroup => '移除了';

  @override
  String get smallAction_removedUser => '移除了';

  @override
  String get smallAction_splitTopic => '拆分了話題';

  @override
  String get smallAction_tagsChanged => '更新了標籤';

  @override
  String get smallAction_userLeft => '離開了對話';

  @override
  String get smallAction_visibleDisabled => '取消公開了話題';

  @override
  String get smallAction_visibleEnabled => '公開了話題';

  @override
  String get vote_cancelled => '已取消投票';

  @override
  String get vote_closed => '已關閉';

  @override
  String get vote_label => '投票';

  @override
  String get vote_pleaseLogin => '請先登入';

  @override
  String get vote_success => '投票成功';

  @override
  String get vote_successNoRemaining => '投票成功，您的投票已用完';

  @override
  String vote_successRemaining(int remaining) {
    return '投票成功，剩餘 $remaining 票';
  }

  @override
  String get vote_topicClosed => '話題已關閉，無法投票';

  @override
  String get vote_voted => '已投票';

  @override
  String get preheat_logoutConfirm => '確定要退出當前賬號嗎？退出後將清除本地登入資訊。';

  @override
  String get preheat_logoutMessage => '使用者主動退出登入（預熱失敗頁面）';

  @override
  String get preheat_networkSettings => '網路設定';

  @override
  String get preheat_retryConnection => '重試連線';

  @override
  String get preheat_userSkipped => '使用者跳過預載入';

  @override
  String table_rowCount(int count) {
    return '共 $count 行';
  }

  @override
  String get httpProxy_auth => '認證';

  @override
  String get httpProxy_base64PskHint => '請輸入 Base64 編碼後的 32 位元組預共享金鑰';

  @override
  String get httpProxy_cipher => '加密演算法';

  @override
  String get httpProxy_cipherNotSet => '未設定演算法';

  @override
  String get httpProxy_configTitle => '配置上游代理';

  @override
  String get httpProxy_disabledDesc =>
      '為本地閘道器配置遠端 HTTP / SOCKS5 / Shadowsocks 代理';

  @override
  String get httpProxy_disabledHint =>
      '開啟後會保留代理模式開關，由本地閘道器統一接管 Dio、WebView 和 Shadowsocks 出口';

  @override
  String get httpProxy_dohProxyHint =>
      '當前會透過本地 DoH 閘道器轉發到上游代理；關閉 DoH 時會切換為純代理轉發';

  @override
  String httpProxy_enabledDesc(String protocol) {
    return '已啟用 $protocol 上游代理，由本地閘道器統一轉發';
  }

  @override
  String get httpProxy_fillServerAndPort => '請填寫伺服器地址和埠';

  @override
  String get httpProxy_importSsLink => '匯入 ss:// 連結';

  @override
  String httpProxy_importedNode(String remarks) {
    return '已匯入節點：$remarks';
  }

  @override
  String get httpProxy_keyBase64Psk => '金鑰（Base64 PSK）';

  @override
  String get httpProxy_password => '密碼';

  @override
  String get httpProxy_port => '埠';

  @override
  String get httpProxy_portHint => '例如：8080 或 1080';

  @override
  String get httpProxy_portInvalid => '埠無效';

  @override
  String get httpProxy_protocol => '協議';

  @override
  String get httpProxy_proxyAutoTest => '儲存後會自動測試，也可以手動重新測試';

  @override
  String get httpProxy_requireAuth => '需要認證';

  @override
  String get httpProxy_selectSsCipher => '請選擇受支援的 Shadowsocks 加密演算法';

  @override
  String get httpProxy_server => '上游代理伺服器';

  @override
  String get httpProxy_serverAddress => '伺服器地址';

  @override
  String get httpProxy_serverAddressHint =>
      '例如：192.168.1.1 或 proxy.example.com';

  @override
  String get httpProxy_ssConfigSaved => '儲存後會校驗 Shadowsocks 配置，並建議返回首頁做實際訪問驗證';

  @override
  String get httpProxy_ssImportSuccess => 'Shadowsocks 連結匯入成功';

  @override
  String get httpProxy_ssLink => 'Shadowsocks 連結';

  @override
  String get httpProxy_suppressedByVpn => '已被 VPN 自動關閉，VPN 斷開後將自動恢復';

  @override
  String get httpProxy_testAvailability => '測試代理可用性';

  @override
  String get httpProxy_testingProxy => '正在驗證是否能透過當前代理訪問 linux.do';

  @override
  String get httpProxy_testingSsConfig => '正在校驗 Shadowsocks 配置是否可由本地閘道器接管';

  @override
  String get httpProxy_title => '上游代理';

  @override
  String httpProxy_username(String username) {
    return '使用者名稱: $username';
  }

  @override
  String get httpProxy_usernameLabel => '使用者名稱';

  @override
  String get proxy_cannotConnect => '無法連線代理伺服器';

  @override
  String get proxy_connectionClosed => '連線已被遠端關閉';

  @override
  String get proxy_fillAddressPort => '請先填寫代理地址和埠';

  @override
  String get proxy_httpAuthFailed => 'HTTP 代理認證失敗（407）';

  @override
  String proxy_httpConnectFailed(String statusLine) {
    return 'HTTP 代理 CONNECT 失敗：$statusLine';
  }

  @override
  String get proxy_notConfigured => '未配置代理伺服器';

  @override
  String get proxy_responseTimeout => '等待代理響應超時';

  @override
  String get proxy_socks5AddrTypeNotSupported => '地址型別不支援';

  @override
  String get proxy_socks5AuthFailed => 'SOCKS5 認證失敗';

  @override
  String get proxy_socks5AuthRejected => 'SOCKS5 不接受當前認證方式';

  @override
  String get proxy_socks5CommandNotSupported => '命令不支援';

  @override
  String proxy_socks5ConnectFailed(String reply) {
    return 'SOCKS5 CONNECT 失敗：$reply';
  }

  @override
  String get proxy_socks5ConnectInvalidVersion => 'SOCKS5 CONNECT 響應版本無效';

  @override
  String get proxy_socks5ConnectionRefused => '目標拒絕連線';

  @override
  String get proxy_socks5CredentialsTooLong => 'SOCKS5 使用者名稱或密碼過長';

  @override
  String get proxy_socks5GeneralFailure => '普通失敗';

  @override
  String get proxy_socks5HostUnreachable => '主機不可達';

  @override
  String get proxy_socks5HostnameTooLong => 'SOCKS5 目標主機名過長';

  @override
  String get proxy_socks5InvalidVersion => 'SOCKS5 響應版本無效';

  @override
  String get proxy_socks5NetworkUnreachable => '網路不可達';

  @override
  String get proxy_socks5NotAllowed => '規則不允許';

  @override
  String get proxy_socks5TtlExpired => 'TTL 已過期';

  @override
  String proxy_socks5UnknownAddrType(String hex) {
    return 'SOCKS5 返回了未知地址型別：0x$hex';
  }

  @override
  String proxy_socks5UnknownError(String hex) {
    return '未知錯誤（0x$hex）';
  }

  @override
  String proxy_socks5UnsupportedAuth(String hex) {
    return 'SOCKS5 返回了不支援的認證方式：0x$hex';
  }

  @override
  String get proxy_ss2022KeyHint => '請填寫 Shadowsocks 2022 的金鑰（Base64 PSK）';

  @override
  String get proxy_ss2022KeyInvalidBase64 =>
      'Shadowsocks 2022 金鑰必須是有效的 Base64 字串';

  @override
  String proxy_ss2022KeyInvalidLength(int length) {
    return 'Shadowsocks 2022 金鑰長度無效：解碼後必須為 $length 位元組';
  }

  @override
  String get proxy_ssBase64DecodeFailed => 'ss:// 連結 Base64 解碼失敗';

  @override
  String get proxy_ssCannotParseCipher => '無法解析加密演算法和密碼';

  @override
  String get proxy_ssIncomplete => 'Shadowsocks 配置不完整';

  @override
  String get proxy_ssInvalidIpv6 => 'IPv6 地址格式無效';

  @override
  String get proxy_ssInvalidPort => '埠無效';

  @override
  String get proxy_ssLinkContentEmpty => 'ss:// 連結內容為空';

  @override
  String get proxy_ssLinkEmpty => '連結不能為空';

  @override
  String get proxy_ssMissingAddress => '缺少伺服器地址';

  @override
  String get proxy_ssMissingPort => '缺少埠';

  @override
  String get proxy_ssOnlySsProtocol => '僅支援 ss:// 連結';

  @override
  String get proxy_ssPasswordHint => '請填寫 Shadowsocks 密碼';

  @override
  String get proxy_ssSaved => 'Shadowsocks 配置已儲存';

  @override
  String get proxy_ssSavedDetail =>
      '當前版本會透過本地閘道器接管 Shadowsocks 出站；請啟用代理後返回首頁進行實際訪問驗證';

  @override
  String get proxy_ssSelectCipher => '請選擇受支援的 Shadowsocks 加密演算法';

  @override
  String proxy_ssUnsupportedCipher(String ciphers) {
    return '當前版本僅支援 $ciphers';
  }

  @override
  String proxy_targetResponseError(String statusLine) {
    return '目標站點響應異常：$statusLine';
  }

  @override
  String get proxy_testFailed => '代理測試失敗';

  @override
  String get proxy_testSuccess => '代理可用';

  @override
  String proxy_testSuccessDetail(String protocol, String host, int statusCode) {
    return '已透過 $protocol 代理訪問 $host，HTTP $statusCode';
  }

  @override
  String get proxy_testTimeout => '代理測試超時';

  @override
  String proxy_testTimeoutDetail(int seconds, String host) {
    return '連線或握手超過 $seconds 秒，未能完成 $host 可用性驗證';
  }

  @override
  String get proxy_testTlsFailed => 'TLS 握手失敗';

  @override
  String get vpnToggle_and => ' 和 ';

  @override
  String get vpnToggle_connected => 'VPN 已連線';

  @override
  String get vpnToggle_disconnected => 'VPN 未連線';

  @override
  String get vpnToggle_subtitle => '檢測到 VPN 時自動關閉 DOH 和代理，斷開後恢復';

  @override
  String get vpnToggle_suppressedSuffix => '已被自動關閉，VPN 斷開後將自動恢復';

  @override
  String get vpnToggle_title => 'VPN 自動切換';

  @override
  String get vpnToggle_upstreamProxy => '上游代理';

  @override
  String get cdk_balance => 'CDK 積分';

  @override
  String get cdk_points => '積分';

  @override
  String get cdk_reAuthHint => '請重新授權以檢視積分';

  @override
  String get ldc_balance => 'LDC 餘額';

  @override
  String ldc_dailyIncome(String amount) {
    return '今日收入 $amount';
  }

  @override
  String get ldc_reAuthHint => '請重新授權以檢視餘額';

  @override
  String get reward_authFailed => '認證失敗，請檢查 Client ID 和 Client Secret';

  @override
  String get reward_clearCredential => '清除憑證';

  @override
  String get reward_configDialogTitle => '配置 LDC 打賞憑證';

  @override
  String get reward_configHint => '請輸入在 credit.linux.do 申請的憑證';

  @override
  String get reward_configured => '已配置，可在帖子中打賞';

  @override
  String reward_confirmMessage(String target, int amount) {
    return '確定向 $target 打賞 $amount LDC 嗎？';
  }

  @override
  String get reward_confirmTitle => '確認打賞';

  @override
  String get reward_createApp => '建立應用';

  @override
  String get reward_customAmount => '自定義金額';

  @override
  String get reward_defaultError => '打賞失敗';

  @override
  String reward_duplicateWarning(int remaining) {
    return '請勿重複打賞，$remaining秒後可再次操作';
  }

  @override
  String get reward_goToCreateApp => '前往建立應用 →';

  @override
  String reward_httpError(int statusCode) {
    return '請求失敗: HTTP $statusCode';
  }

  @override
  String reward_networkError(String error) {
    return '網路錯誤: $error';
  }

  @override
  String get reward_notConfigured => '配置憑證以啟用打賞功能';

  @override
  String get reward_noteHint => '感謝分享！';

  @override
  String get reward_noteLabel => '備註（可選）';

  @override
  String get reward_selectAmount => '選擇金額';

  @override
  String get reward_selectOrInputAmount => '請選擇或輸入金額';

  @override
  String get reward_sheetTitle => '打賞 LDC';

  @override
  String reward_submitWithAmount(int amount) {
    return '打賞 $amount LDC';
  }

  @override
  String get reward_title => 'LDC 打賞';

  @override
  String reward_unknownError(String error) {
    return '未知錯誤: $error';
  }

  @override
  String get search_advancedSearch => '高階搜尋';

  @override
  String search_afterDate(String date) {
    return '$date 之後';
  }

  @override
  String get search_applyFilter => '應用篩選';

  @override
  String search_beforeDate(String date) {
    return '$date 之前';
  }

  @override
  String get search_category => '分類';

  @override
  String search_categoryLoadFailed(String error) {
    return '載入分類失敗: $error';
  }

  @override
  String get search_clearAll => '清除全部';

  @override
  String get search_currentFilter => '當前篩選';

  @override
  String get search_custom => '自定義';

  @override
  String get search_dateRange => '時間範圍';

  @override
  String get search_emptyHint => '輸入關鍵詞搜尋';

  @override
  String get search_error => '搜尋出錯';

  @override
  String get search_filterBookmarks => '書籤';

  @override
  String get search_filterCreated => '我的話題';

  @override
  String get search_filterSeen => '瀏覽歷史';

  @override
  String get search_hintText => '搜尋 @使用者 #分類 tags:標籤';

  @override
  String get search_lastMonth => '最近一月';

  @override
  String get search_lastWeek => '最近一週';

  @override
  String get search_lastYear => '最近一年';

  @override
  String search_likeCount(String count) {
    return '$count 點贊';
  }

  @override
  String get search_noLimit => '不限';

  @override
  String get search_noPopularTags => '暫無熱門標籤';

  @override
  String get search_noResults => '沒有找到相關結果';

  @override
  String get search_popularTags => '熱門標籤';

  @override
  String get search_recentSearches => '最近搜尋';

  @override
  String search_replyCount(int count) {
    return '$count 條回覆';
  }

  @override
  String search_resultCount(int count, String more) {
    return '$count$more 條結果';
  }

  @override
  String get search_selectDateRange => '選擇時間範圍';

  @override
  String get search_selectedTags => '已選標籤';

  @override
  String get search_sortLabel => '排序：';

  @override
  String get search_sortLatest => '最新帖子';

  @override
  String get search_sortLatestTopic => '最新話題';

  @override
  String get search_sortLikes => '最受歡迎';

  @override
  String get search_sortRelevance => '相關性';

  @override
  String get search_sortViews => '最多瀏覽';

  @override
  String get search_status => '狀態';

  @override
  String get search_statusArchived => '已歸檔';

  @override
  String get search_statusClosed => '已關閉';

  @override
  String get search_statusOpen => '進行中';

  @override
  String get search_statusSolved => '已解決';

  @override
  String get search_statusUnsolved => '未解決';

  @override
  String get search_tags => '標籤';

  @override
  String search_tagsLoadFailed(String error) {
    return '載入標籤失敗: $error';
  }

  @override
  String get search_topicSearchHint => '輸入關鍵詞搜尋本話題';

  @override
  String get search_tryOtherKeywords => '請嘗試其他關鍵詞';

  @override
  String get search_users => '使用者';

  @override
  String search_viewCount(String count) {
    return '$count 瀏覽';
  }

  @override
  String get cfVerify_cooldown => '驗證太頻繁，請稍後再試';

  @override
  String get cfVerify_desc => '手動觸發過盾驗證';

  @override
  String get cfVerify_failed => '驗證未透過';

  @override
  String get cfVerify_success => '驗證成功';

  @override
  String get cfVerify_title => 'Cloudflare 驗證';

  @override
  String get cf_abandonVerifyMessage => '退出驗證將導致相關功能無法使用，確定要退出嗎？';

  @override
  String get cf_abandonVerifyTitle => '放棄驗證？';

  @override
  String get cf_autoVerifyTimeout => '自動驗證超時，請手動完成驗證';

  @override
  String get cf_backgroundVerifying => '後臺驗證中... (點選開啟)';

  @override
  String get cf_cannotOpenVerifyPage => '無法開啟驗證頁面，請稍後重試';

  @override
  String get cf_challengeFailedCooldown => '安全驗證失敗，已進入冷卻期，請稍後再試';

  @override
  String get cf_challengeNotEffective => '驗證未生效，請稍後重試';

  @override
  String get cf_continueVerify => '繼續驗證';

  @override
  String get cf_cooldown => '請稍後再試';

  @override
  String get cf_failedRetry => '安全驗證失敗，請重試';

  @override
  String cf_failedWithCause(String cause) {
    return '安全驗證失敗: $cause';
  }

  @override
  String get cf_helpContent =>
      '這是 Cloudflare 安全驗證頁面。\n\n請完成頁面上的驗證挑戰（如勾選框或滑塊）。\n\n驗證成功後會自動關閉此頁面。\n\n如果長時間無法完成，可以嘗試：\n• 點選重新整理按鈕重新載入\n• 檢查網路連線\n• 關閉後稍後再試';

  @override
  String get cf_helpTitle => '驗證幫助';

  @override
  String cf_loadFailed(String description) {
    return '載入失敗: $description';
  }

  @override
  String get cf_securityVerifyTitle => '安全驗證';

  @override
  String get cf_userCancelled => '驗證已取消';

  @override
  String get cf_verifyIncomplete => '驗證未完成，請重試';

  @override
  String cf_verifyLonger(int seconds) {
    return '驗證時間較長，還剩 $seconds 秒';
  }

  @override
  String get cf_verifyTimeout => '驗證超時，請重試';

  @override
  String cf_verifying(int seconds) {
    return '驗證中... ${seconds}s';
  }

  @override
  String get hcaptcha_clear => '清除';

  @override
  String get hcaptcha_clearConfirm => '確定要清除 hCaptcha 無障礙 Cookie 嗎？';

  @override
  String get hcaptcha_cookieCleared => 'hCaptcha 無障礙 Cookie 已清除';

  @override
  String get hcaptcha_cookieNotFound => '未找到 hCaptcha 無障礙 Cookie，請先完成註冊';

  @override
  String get hcaptcha_cookieNotSet => 'Cookie 未設定';

  @override
  String get hcaptcha_cookieSaved => 'hCaptcha 無障礙 Cookie 已儲存';

  @override
  String get hcaptcha_cookieSet => 'Cookie 已設定 ✓';

  @override
  String get hcaptcha_done => '完成';

  @override
  String get hcaptcha_pasteCookie => '貼上 Cookie';

  @override
  String get hcaptcha_pasteDialogDesc =>
      '在瀏覽器中造訪 hCaptcha 無障礙頁面註冊後，從瀏覽器開發人員工具中複製名為 hc_accessibility 的 Cookie 值貼到下方。';

  @override
  String get hcaptcha_pasteDialogHint => '請輸入 hc_accessibility Cookie 值';

  @override
  String get hcaptcha_pasteDialogTitle => '貼上 hCaptcha Cookie';

  @override
  String get hcaptcha_pasteLink => '貼上登入連結';

  @override
  String get hcaptcha_pasteLinkInvalid => '剪貼簿中沒有有效的 hCaptcha 連結';

  @override
  String get hcaptcha_subtitle => '視障使用者可跳過 hCaptcha 驗證';

  @override
  String get hcaptcha_title => 'hCaptcha 無障礙';

  @override
  String get hcaptcha_webviewGet => 'WebView 取得';

  @override
  String get hcaptcha_webviewTitle => 'hCaptcha 無障礙';

  @override
  String get config_seedUserTitle => '種子使用者';

  @override
  String get preferences_advanced => '高階';

  @override
  String get preferences_androidNativeCdp => 'WebView Cookie 同步';

  @override
  String get preferences_androidNativeCdpDesc => '優先使用原生 CDP；異常時可關閉並回退相容模式。';

  @override
  String get preferences_anonymousShare => '匿名分享';

  @override
  String get preferences_anonymousShareDesc => '分享連結時不附帶個人使用者標識';

  @override
  String get preferences_autoFillLogin => '自動填充登入';

  @override
  String get preferences_autoFillLoginDesc => '記住賬號密碼，登入時自動填充';

  @override
  String get preferences_autoPanguSpacing => '自動混排最佳化';

  @override
  String get preferences_autoPanguSpacingDesc => '輸入時自動插入中英文混排空格';

  @override
  String get preferences_basic => '基礎';

  @override
  String get preferences_cfClearanceRefresh => 'cf_clearance 自動續期';

  @override
  String get preferences_cfClearanceRefreshDesc =>
      '透過後台 WebView 自動續期 cf_clearance Cookie';

  @override
  String get preferences_crashlytics => '崩潰日誌上報';

  @override
  String get preferences_crashlyticsDesc => '發生崩潰時自動上報日誌，幫助開發者定位問題';

  @override
  String get preferences_editor => '編輯器';

  @override
  String get preferences_enableCrashlyticsContent =>
      '本應用使用 Firebase Crashlytics 收集崩潰資訊以改進應用穩定性。\n\n收集的資料包括裝置資訊和崩潰詳情，不包含個人隱私資料。您可以在設定中關閉此功能。';

  @override
  String get preferences_enableCrashlyticsTitle => '資料收集說明';

  @override
  String get preferences_enterUrl => '輸入 URL';

  @override
  String get preferences_hideBarOnScroll => '滾動收起導航欄';

  @override
  String get preferences_hideBarOnScrollDesc => '首頁滾動時自動收起頂欄和底欄';

  @override
  String get preferences_longPressPreview => '長按預覽';

  @override
  String get preferences_longPressPreviewDesc => '長按話題卡片快速預覽內容';

  @override
  String get preferences_openLinksInApp => '外部連結使用內建瀏覽器';

  @override
  String get preferences_openLinksInAppDesc => '貼內外部連結優先在應用內開啟';

  @override
  String get preferences_portraitLock => '豎屏鎖定';

  @override
  String get preferences_portraitLockDesc => '鎖定螢幕方向為豎屏';

  @override
  String get preferences_stickerSource => '表情包資料來源';

  @override
  String get preferences_title => '功能設定';

  @override
  String get settings_about => '關於 FluxDO';

  @override
  String get settings_appearance => '外觀設定';

  @override
  String get settings_dataManagement => '資料管理';

  @override
  String get settings_network => '網路設定';

  @override
  String get settings_preferences => '功能設定';

  @override
  String get settings_reading => '閱讀設定';

  @override
  String get settings_searchEmpty => '未找到符合的設定項';

  @override
  String get settings_searchHint => '搜尋設定項...';

  @override
  String get settings_shortcuts => '快捷鍵';

  @override
  String get settings_title => '應用設定';

  @override
  String get shortcuts_closeOverlay => '關閉浮層';

  @override
  String shortcuts_conflict(String action) {
    return '與「$action」衝突';
  }

  @override
  String get shortcuts_content => '內容';

  @override
  String get shortcuts_createTopic => '建立話題';

  @override
  String get shortcuts_customizeHint => '在 設定 > 快捷鍵 中自訂';

  @override
  String get shortcuts_navigateBack => '返回';

  @override
  String get shortcuts_navigateBackAlt => '返回（備用）';

  @override
  String get shortcuts_navigation => '導航';

  @override
  String get shortcuts_nextItem => '下一個條目';

  @override
  String get shortcuts_nextTab => '下一個分類';

  @override
  String get shortcuts_openItem => '開啟選中條目';

  @override
  String get shortcuts_openSearch => '搜尋';

  @override
  String get shortcuts_openSettings => '開啟設定';

  @override
  String get shortcuts_previousItem => '上一個條目';

  @override
  String get shortcuts_previousTab => '上一個分類';

  @override
  String get shortcuts_recordKey => '請按下新的快捷鍵組合';

  @override
  String get shortcuts_refresh => '重新整理';

  @override
  String get shortcuts_resetAll => '恢復所有預設';

  @override
  String get shortcuts_resetOne => '恢復預設';

  @override
  String get shortcuts_showHelp => '快捷鍵說明';

  @override
  String get shortcuts_switchPane => '切換面板焦點';

  @override
  String get shortcuts_switchToProfile => '切換到個人';

  @override
  String get shortcuts_switchToTopics => '切換到話題';

  @override
  String get shortcuts_toggleAiPanel => 'AI 助手面板';

  @override
  String get shortcuts_toggleNotifications => '通知面板';

  @override
  String get download_alreadyInProgress => '已有下載任務正在進行';

  @override
  String get download_checksumFailed => '檔案校驗失敗，下載的檔案可能已損壞';

  @override
  String get download_connecting => '正在連線...';

  @override
  String download_downloading(String name) {
    return '正在下載 $name';
  }

  @override
  String download_failed(String error) {
    return '下載失敗: $error';
  }

  @override
  String download_failedWithError(String error) {
    return '下載失敗: $error';
  }

  @override
  String download_installFailed(String error) {
    return '安裝失敗: $error';
  }

  @override
  String get download_installStarted => '已開始安裝';

  @override
  String get download_installing => '正在安裝...';

  @override
  String get download_internalError => '下載安裝過程中發生內部錯誤';

  @override
  String get download_noInstallPermission => '未授予安裝許可權，請在設定中允許安裝未知應用';

  @override
  String get download_verifying => '正在校驗檔案...';

  @override
  String export_exporting(int progress, int total) {
    return '匯出中 ($progress/$total)';
  }

  @override
  String get export_exportingNoProgress => '匯出中...';

  @override
  String export_failed(String error) {
    return '匯出失敗: $error';
  }

  @override
  String get export_fetchPostsFailed => '獲取帖子資料失敗';

  @override
  String get export_firstPostOnly => '僅主帖';

  @override
  String get export_format => '匯出格式';

  @override
  String export_markdownLimit(int max) {
    return 'Markdown 格式最多匯出前 $max 條帖子';
  }

  @override
  String get export_noPostsToExport => '沒有可匯出的帖子';

  @override
  String get export_range => '匯出範圍';

  @override
  String get export_title => '匯出文章';

  @override
  String get share_aiAssistant => 'AI 助手';

  @override
  String get share_aiQuestion => '提問';

  @override
  String get share_aiReply => 'AI 回覆';

  @override
  String get share_aiReplyAlt => 'AI 助手回覆';

  @override
  String get share_cannotGetPostId => '無法獲取主帖 ID';

  @override
  String get share_copyFailed => '複製失敗，請重試';

  @override
  String get share_exportChatImage => '匯出對話圖片';

  @override
  String get share_exportImage => '匯出圖片';

  @override
  String get share_generatedByAi => '由 FluxDO AI 助手生成';

  @override
  String get share_getPostFailed => '獲取主帖失敗';

  @override
  String get share_imageCopied => '圖片已複製';

  @override
  String get share_imageSaved => '圖片已儲存到相簿';

  @override
  String get share_loadingPost => '正在載入帖子...';

  @override
  String get share_replyToTopic => '回覆話題';

  @override
  String get share_saveFailed => '儲存失敗，請重試';

  @override
  String get share_savePermissionDenied => '儲存失敗，請授予相簿許可權';

  @override
  String get share_saveToGallery => '儲存到相簿';

  @override
  String get share_fileSaved => '檔案已儲存';

  @override
  String get share_selectSaveLocation => '選擇儲存位置';

  @override
  String get share_screenshotFailed => '截圖失敗';

  @override
  String get share_shareImageTitle => '分享圖片';

  @override
  String get share_themeBlack => '純黑';

  @override
  String get share_themeBlue => '藍調';

  @override
  String get share_themeClassic => '經典';

  @override
  String get share_themeDark => '深色';

  @override
  String get share_themeGreen => '綠野';

  @override
  String get share_themeWhite => '純白';

  @override
  String get share_uploadFailed => '上傳失敗，請重試';

  @override
  String get share_uploading => '正在上傳...';

  @override
  String time_days(int count) {
    return '$count 天';
  }

  @override
  String time_daysAgo(int count) {
    return '$count天前';
  }

  @override
  String time_fullDate(int year, int month, int day) {
    return '$year年$month月$day日';
  }

  @override
  String time_hours(int count) {
    return '$count 小時';
  }

  @override
  String time_hoursAgo(int count) {
    return '$count小時前';
  }

  @override
  String get time_justNow => '剛剛';

  @override
  String time_minutes(int count) {
    return '$count 分鐘';
  }

  @override
  String time_minutesAgo(int count) {
    return '$count分鐘前';
  }

  @override
  String time_monthsAgo(int count) {
    return '$count個月前';
  }

  @override
  String time_seconds(int count) {
    return '$count 秒';
  }

  @override
  String time_shortDate(int month, int day) {
    return '$month月$day日';
  }

  @override
  String get time_today => '今天';

  @override
  String time_tooltipTime(
    int year,
    int month,
    int day,
    String hour,
    String minute,
    String second,
  ) {
    return '$year年$month月$day日 $hour:$minute:$second';
  }

  @override
  String time_weeksAgo(int count) {
    return '$count周前';
  }

  @override
  String time_yearsAgo(int count) {
    return '$count年前';
  }

  @override
  String get time_yesterday => '昨天';

  @override
  String get topicDetail_addToReadLater => '加入浮窗';

  @override
  String get topicDetail_addToReadLaterSuccess => '已加入浮窗';

  @override
  String get topicDetail_aiAssistant => 'AI 助手';

  @override
  String get topicDetail_authorOnly => '只看題主';

  @override
  String get topicDetail_cannotOpenBrowser => '無法開啟瀏覽器';

  @override
  String get topicDetail_editBookmark => '編輯書籤';

  @override
  String get topicDetail_editTopic => '編輯話題';

  @override
  String get topicDetail_exportArticle => '匯出文章';

  @override
  String get topicDetail_generateShareImage => '生成分享圖片';

  @override
  String get topicDetail_hotOnly => '只看熱門';

  @override
  String get topicDetail_loadFailedTapRetry => '載入失敗，點選重試';

  @override
  String get topicDetail_loading => '載入中...';

  @override
  String get topicDetail_moreOptions => '更多選項';

  @override
  String get topicDetail_openInBrowser => '在瀏覽器開啟';

  @override
  String topicDetail_readLaterFull(int max) {
    return '浮窗已滿（最多 $max 個）';
  }

  @override
  String get topicDetail_removeFromReadLater => '移出浮窗';

  @override
  String get topicDetail_removeFromReadLaterSuccess => '已從浮窗移除';

  @override
  String get topicDetail_replyLabel => '回覆';

  @override
  String get topicDetail_scrollToTop => '回到頂部';

  @override
  String get topicDetail_searchHint => '在本話題中搜尋...';

  @override
  String get topicDetail_searchTopic => '搜尋本話題';

  @override
  String topicDetail_setToLevel(String level) {
    return '已設定為$level';
  }

  @override
  String get topicDetail_shareLink => '分享連結';

  @override
  String topicDetail_showHiddenReplies(int count) {
    return '顯示 $count 條隱藏回覆';
  }

  @override
  String get topicDetail_topLevelOnly => '只看頂層';

  @override
  String get topicDetail_viewAll => '檢視全部';

  @override
  String get topicDetail_viewsLabel => '瀏覽';

  @override
  String get topicSort_activity => '活躍度';

  @override
  String get topicSort_created => '建立時間';

  @override
  String get topicSort_default => '預設';

  @override
  String get topicSort_likes => '點贊數';

  @override
  String get topicSort_posters => '參與者';

  @override
  String get topicSort_posts => '回覆數';

  @override
  String get topicSort_views => '瀏覽量';

  @override
  String get topic_addTags => '新增標籤';

  @override
  String get topic_aiSummary => 'AI 摘要';

  @override
  String get topic_atCurrentPosition => '正位於此';

  @override
  String get topic_createdAt => '建立於 ';

  @override
  String get topic_currentFloor => '當前樓層';

  @override
  String get topic_filterHot => '熱門';

  @override
  String get topic_filterLatest => '最新';

  @override
  String get topic_filterNew => '新話題';

  @override
  String topic_filterTooltip(String label) {
    return '篩選: $label';
  }

  @override
  String get topic_filterTop => '排行榜';

  @override
  String get topic_filterUnread => '未讀完';

  @override
  String get topic_filterUnseen => '未瀏覽';

  @override
  String get topic_flagInappropriate => '不當內容';

  @override
  String get topic_flagInappropriateDesc => '此帖子包含不適當的內容';

  @override
  String get topic_flagOffTopic => '離題';

  @override
  String get topic_flagOffTopicDesc => '此帖子與當前討論無關，應該移動到其他話題';

  @override
  String get topic_flagOther => '其他問題';

  @override
  String get topic_flagOtherDesc => '需要版主關注的其他問題';

  @override
  String get topic_flagSpam => '垃圾資訊';

  @override
  String get topic_flagSpamDesc => '此帖子是廣告或垃圾資訊';

  @override
  String get topic_generateAiSummary => '生成 AI 摘要';

  @override
  String get topic_generatingSummary => '正在生成摘要...';

  @override
  String get topic_jump => '跳轉';

  @override
  String get topic_lastReply => '最後回覆 ';

  @override
  String get topic_levelMuted => '靜音';

  @override
  String get topic_levelMutedDesc => '不接收任何通知';

  @override
  String get topic_levelRegular => '常規';

  @override
  String get topic_levelRegularDesc => '只在被 @ 提及或回覆時通知';

  @override
  String get topic_levelTracking => '跟蹤';

  @override
  String get topic_levelTrackingDesc => '顯示未讀計數';

  @override
  String get topic_levelWatching => '關注';

  @override
  String get topic_levelWatchingDesc => '每個新回覆都通知';

  @override
  String topic_likeCount(String count) {
    return '$count 點贊';
  }

  @override
  String topic_minTagsRequired(int min) {
    return '至少選擇 $min 個標籤';
  }

  @override
  String topic_newRepliesSinceSummary(int count) {
    return '有 $count 條新回覆';
  }

  @override
  String get topic_noSummary => '暫無摘要';

  @override
  String get topic_notificationSettings => '訂閱設定';

  @override
  String get topic_participants => '參與者';

  @override
  String get topic_readyToJump => '準備跳轉';

  @override
  String topic_remainingTags(int remaining) {
    return '還需 $remaining 個標籤';
  }

  @override
  String topic_replyCount(int count) {
    return '$count 條回覆';
  }

  @override
  String get topic_selectCategory => '選擇分類';

  @override
  String topic_sortTooltip(String label) {
    return '排序: $label';
  }

  @override
  String get topic_summaryLoadFailed => '載入摘要失敗';

  @override
  String topic_tagGroupRequirement(String name, int minCount) {
    return '從 $name 選擇 $minCount 個';
  }

  @override
  String get topic_updatedAt => '更新於 ';

  @override
  String topic_viewCount(String count) {
    return '$count 瀏覽';
  }

  @override
  String get topicsScreen_createTopic => '建立話題';

  @override
  String get topicsScreen_myDrafts => '我的草稿';

  @override
  String get topics_browseCategories => '瀏覽分類';

  @override
  String get topics_debugJump => '除錯：跳轉話題';

  @override
  String get topics_dismiss => '忽略';

  @override
  String topics_dismissConfirmContent(String label) {
    return '確定要忽略全部$label嗎？';
  }

  @override
  String get topics_dismissConfirmTitle => '忽略確認';

  @override
  String get topics_jump => '跳轉';

  @override
  String get topics_jumpToTopic => '跳轉到話題';

  @override
  String get topics_newTopics => '新話題';

  @override
  String get topics_noTopics => '沒有相關話題';

  @override
  String get topics_searchHint => '搜尋話題...';

  @override
  String get topics_topicId => '話題 ID';

  @override
  String get topics_topicIdHint => '例如: 1095754';

  @override
  String get topics_unreadTopics => '未讀話題';

  @override
  String topics_viewNewTopics(int count) {
    return '檢視 $count 個新的或更新的話題';
  }

  @override
  String get followList_followers => '粉絲';

  @override
  String get followList_following => '關注';

  @override
  String get profileStats_addItems => '點擊新增統計項';

  @override
  String get profileStats_allItemsAdded => '所有統計項已新增';

  @override
  String get profileStats_availableItems => '可新增項目';

  @override
  String get profileStats_bookmarkCount => '書籤數';

  @override
  String get profileStats_columnsPerRow => '每行數量';

  @override
  String get profileStats_dataSource => '資料來源';

  @override
  String get profileStats_daysVisited => '造訪天數';

  @override
  String get profileStats_editTitle => '統計卡片自訂';

  @override
  String get profileStats_enabledItems => '已新增項目';

  @override
  String get profileStats_guideMessage => '點擊統計卡片可自訂展示項目、佈局和資料來源';

  @override
  String get profileStats_incompatibleSource => '不相容目前資料來源';

  @override
  String get profileStats_layoutGrid => '網格';

  @override
  String get profileStats_layoutMode => '佈局模式';

  @override
  String get profileStats_layoutScroll => '滾動';

  @override
  String get profileStats_layoutSettings => '佈局設定';

  @override
  String get profileStats_likesGiven => '送讚';

  @override
  String get profileStats_likesReceived => '獲讚';

  @override
  String get profileStats_likesReceivedDays => '獲讚天數';

  @override
  String get profileStats_likesReceivedUsers => '獲讚人數';

  @override
  String get profileStats_loadError => '資料載入失敗，已回退到全量統計';

  @override
  String get profileStats_noItemsSelected => '未選擇任何統計項';

  @override
  String get profileStats_postCount => '發帖數';

  @override
  String get profileStats_postsRead => '已讀帖子';

  @override
  String get profileStats_recentTimeRead => '近60天閱讀';

  @override
  String get profileStats_selectItems => '統計項目';

  @override
  String get profileStats_sourceConnect => '信任等級週期';

  @override
  String get profileStats_sourceDaily => '本日';

  @override
  String get profileStats_sourceMonthly => '本月';

  @override
  String get profileStats_sourceQuarterly => '本季';

  @override
  String get profileStats_sourceSummary => '全量統計';

  @override
  String get profileStats_sourceWeekly => '本週';

  @override
  String get profileStats_sourceYearly => '本年';

  @override
  String get profileStats_timeRead => '閱讀時間';

  @override
  String get profileStats_topicCount => '主題數';

  @override
  String get profileStats_topicsEntered => '瀏覽主題';

  @override
  String get profileStats_topicsRepliedTo => '回覆主題';

  @override
  String get profile_aboutFluxDO => '關於 FluxDO';

  @override
  String get profile_aiModelService => 'AI 模型服務';

  @override
  String get profile_appearance => '外觀設定';

  @override
  String get profile_browsingHistory => '瀏覽歷史';

  @override
  String get profile_cdkReauthSuccess => 'CDK 重新授權成功';

  @override
  String get profile_confirmLogout => '確認退出';

  @override
  String get profile_dataManagement => '資料管理';

  @override
  String get profile_daysVisited => '訪問天數';

  @override
  String get profile_editProfile => '編輯資料';

  @override
  String get profile_inviteLinks => '邀請連結';

  @override
  String get profile_ldcReauthSuccess => 'LDC 重新授權成功';

  @override
  String get profile_likesReceived => '獲得點贊';

  @override
  String get profile_loadingData => '載入資料...';

  @override
  String get profile_loggingOut => '正在退出...';

  @override
  String get profile_loginForMore => '登入後體驗更多功能';

  @override
  String get profile_loginLinuxDo => '登入 Linux.do';

  @override
  String get profile_logoutContent => '確定要退出登入嗎？';

  @override
  String get profile_logoutCurrentAccount => '退出當前賬號';

  @override
  String get profile_metaverse => '元宇宙';

  @override
  String get profile_myBadges => '我的徽章';

  @override
  String get profile_myBookmarks => '我的書籤';

  @override
  String get profile_myDrafts => '我的草稿';

  @override
  String get profile_myTopics => '我的話題';

  @override
  String get profile_networkSettings => '網路設定';

  @override
  String get profile_notLoggedIn => '未登入';

  @override
  String get profile_postCount => '發表回覆';

  @override
  String get profile_postsRead => '閱讀帖子';

  @override
  String get profile_preferences => '功能設定';

  @override
  String get profile_settings => '應用設定';

  @override
  String get profile_trustRequirements => '信任要求';

  @override
  String get trustLevel_activity => '活躍程度';

  @override
  String get trustLevel_appBarTitle => '信任要求';

  @override
  String get trustLevel_compliance => '合規記錄';

  @override
  String get trustLevel_interaction => '互動參與';

  @override
  String trustLevel_parseFailed(String error) {
    return '解析失敗: $error';
  }

  @override
  String get trustLevel_parseNotFound => '未找到信任級別資訊 (div.card)';

  @override
  String trustLevel_requestFailed(int statusCode) {
    return '請求失敗: $statusCode';
  }

  @override
  String get trustLevel_title => '信任級別要求';

  @override
  String get userProfile_actionCreatedTopic => '釋出了話題';

  @override
  String get userProfile_actionDefault => '動態';

  @override
  String get userProfile_actionLike => '點贊';

  @override
  String get userProfile_actionLiked => '被贊';

  @override
  String get userProfile_actionReplied => '回覆了';

  @override
  String get userProfile_bio => '個人簡介';

  @override
  String userProfile_catPostCount(int count) {
    return '$count 回覆';
  }

  @override
  String userProfile_catTopicCount(int count) {
    return '$count 話題';
  }

  @override
  String get userProfile_follow => '關注';

  @override
  String get userProfile_followed => '已關注';

  @override
  String get userProfile_followers => '粉絲';

  @override
  String get userProfile_following => '關注';

  @override
  String get userProfile_fourMonths => '四個月';

  @override
  String get userProfile_ignored => '已忽略';

  @override
  String get userProfile_joinDate => '加入時間';

  @override
  String get userProfile_laterThisWeek => '本週稍後';

  @override
  String get userProfile_laterToday => '今天稍後';

  @override
  String userProfile_linkClicks(int count) {
    return '$count 次點選';
  }

  @override
  String get userProfile_location => '位置';

  @override
  String get userProfile_message => '私信';

  @override
  String get userProfile_moreInfo => '更多資訊';

  @override
  String get userProfile_mostLiked => '贊最多';

  @override
  String get userProfile_mostLikedBy => '被誰讚的最多';

  @override
  String get userProfile_mostRepliedTo => '最多回復至';

  @override
  String get userProfile_mute => '免打擾';

  @override
  String get userProfile_nextMonday => '下週一';

  @override
  String get userProfile_nextMonth => '下個月';

  @override
  String get userProfile_noBio => '這個人很懶，什麼都沒寫';

  @override
  String get userProfile_noContent => '暫無內容';

  @override
  String get userProfile_noReactions => '暫無回應';

  @override
  String get userProfile_noSummary => '暫無總結資料';

  @override
  String get userProfile_normal => '常規';

  @override
  String get userProfile_oneYear => '一年';

  @override
  String get userProfile_permanent => '永久';

  @override
  String get userProfile_permanentlySilenced => '該使用者已被永久禁言';

  @override
  String get userProfile_permanentlySuspended => '該使用者已被永久封禁';

  @override
  String get userProfile_reacted => '回應了';

  @override
  String get userProfile_restored => '已恢復常規通知';

  @override
  String get userProfile_selectIgnoreDuration => '選擇忽略時長';

  @override
  String get userProfile_setToIgnore => '已設定為忽略';

  @override
  String get userProfile_setToMute => '已設定為免打擾';

  @override
  String get userProfile_shareUser => '分享使用者';

  @override
  String get userProfile_silencedBannerForever => '該使用者已被永久禁言';

  @override
  String userProfile_silencedBannerUntil(String date) {
    return '該使用者已被禁言至 $date';
  }

  @override
  String get userProfile_silencedStatus => '禁言狀態';

  @override
  String userProfile_silencedUntil(String date) {
    return '禁言至 $date';
  }

  @override
  String get userProfile_sixMonths => '六個月';

  @override
  String get userProfile_statsLikes => '獲贊';

  @override
  String get userProfile_statsReplies => '回覆';

  @override
  String get userProfile_statsTopics => '話題';

  @override
  String get userProfile_statsVisits => '訪問';

  @override
  String get userProfile_suspendedBannerForever => '該使用者已被永久封禁';

  @override
  String userProfile_suspendedBannerUntil(String date) {
    return '該使用者已被封禁至 $date';
  }

  @override
  String get userProfile_suspendedStatus => '封禁狀態';

  @override
  String userProfile_suspendedUntil(String date) {
    return '封禁至 $date';
  }

  @override
  String get userProfile_tabActivity => '動態';

  @override
  String get userProfile_tabLikes => '贊';

  @override
  String get userProfile_tabReactions => '回應';

  @override
  String get userProfile_tabReplies => '回覆';

  @override
  String get userProfile_tabSummary => '總結';

  @override
  String get userProfile_tabTopics => '話題';

  @override
  String get userProfile_threeMonths => '三個月';

  @override
  String get userProfile_tomorrow => '明天';

  @override
  String get userProfile_topBadges => '熱門徽章';

  @override
  String get userProfile_topCategories => '熱門類別';

  @override
  String get userProfile_topLinks => '熱門連結';

  @override
  String get userProfile_topReplies => '熱門回覆';

  @override
  String get userProfile_topTopics => '熱門話題';

  @override
  String userProfile_topicHash(String id) {
    return '話題 #$id';
  }

  @override
  String get userProfile_twoMonths => '兩個月';

  @override
  String get userProfile_twoWeeks => '兩週';

  @override
  String get userProfile_website => '網站';

  @override
  String get user_trustLevel0 => 'L0 新使用者';

  @override
  String get user_trustLevel1 => 'L1 基本使用者';

  @override
  String get user_trustLevel2 => 'L2 成員';

  @override
  String get user_trustLevel3 => 'L3 活躍使用者';

  @override
  String get user_trustLevel4 => 'L4 領袖';

  @override
  String user_trustLevelUnknown(int level) {
    return '等級 $level';
  }

  @override
  String get webviewLogin_clearSaved => '清除已儲存的密碼';

  @override
  String get webviewLogin_clearSavedContent => '確定要清除已儲存的登入憑證嗎？下次登入時需要手動輸入。';

  @override
  String get webviewLogin_clearSavedTitle => '清除已儲存的密碼';

  @override
  String get webviewLogin_emailLoginInvalidLink => '無效的登入連結';

  @override
  String get webviewLogin_emailLoginPaste => '貼上登入連結';

  @override
  String webviewLogin_lastLogin(String username) {
    return '上次登入: @$username';
  }

  @override
  String get webviewLogin_loginSuccess => '登入成功！';

  @override
  String get webviewLogin_savedPassword => '已儲存的密碼';

  @override
  String get webviewLogin_title => '登入 Linux.do';

  @override
  String get webview_browser => '瀏覽器';

  @override
  String get webview_cannotOpenBrowser => '無法開啟外部瀏覽器';

  @override
  String get webview_goBack => '後退';

  @override
  String get webview_goForward => '前進';

  @override
  String get webview_noAppForLink => '未找到可處理此連結的應用';

  @override
  String get webview_openExternal => '在外部瀏覽器開啟';

  @override
  String webview_openFailed(String error) {
    return '開啟失敗: $error';
  }
}
