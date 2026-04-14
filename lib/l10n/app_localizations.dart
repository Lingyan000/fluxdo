import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
    Locale('zh', 'HK'),
    Locale('zh', 'TW'),
  ];

  /// No description provided for @about_appLogs.
  ///
  /// In zh, this message translates to:
  /// **'应用日志'**
  String get about_appLogs;

  /// No description provided for @about_checkUpdate.
  ///
  /// In zh, this message translates to:
  /// **'检查更新'**
  String get about_checkUpdate;

  /// No description provided for @about_checkUpdateError.
  ///
  /// In zh, this message translates to:
  /// **'无法检查更新，请稍后重试。\n错误信息: {error}'**
  String about_checkUpdateError(String error);

  /// No description provided for @about_checkUpdateFailed.
  ///
  /// In zh, this message translates to:
  /// **'检查更新失败'**
  String get about_checkUpdateFailed;

  /// No description provided for @about_develop.
  ///
  /// In zh, this message translates to:
  /// **'开发'**
  String get about_develop;

  /// No description provided for @about_developerMode.
  ///
  /// In zh, this message translates to:
  /// **'开发者模式'**
  String get about_developerMode;

  /// No description provided for @about_developerModeAlreadyEnabled.
  ///
  /// In zh, this message translates to:
  /// **'开发者模式已启用'**
  String get about_developerModeAlreadyEnabled;

  /// No description provided for @about_developerModeClosed.
  ///
  /// In zh, this message translates to:
  /// **'已关闭开发者模式'**
  String get about_developerModeClosed;

  /// No description provided for @about_developerModeEnabled.
  ///
  /// In zh, this message translates to:
  /// **'已启用开发者模式'**
  String get about_developerModeEnabled;

  /// No description provided for @about_feedback.
  ///
  /// In zh, this message translates to:
  /// **'反馈问题'**
  String get about_feedback;

  /// No description provided for @about_info.
  ///
  /// In zh, this message translates to:
  /// **'信息'**
  String get about_info;

  /// No description provided for @about_latestVersion.
  ///
  /// In zh, this message translates to:
  /// **'已是最新版本'**
  String get about_latestVersion;

  /// No description provided for @about_legalese.
  ///
  /// In zh, this message translates to:
  /// **'非官方 Linux.do 客户端\n基于 Flutter & Material 3'**
  String get about_legalese;

  /// No description provided for @about_noUpdateContent.
  ///
  /// In zh, this message translates to:
  /// **'当前版本: {version}\n您正在使用最新版本的 FluxDO，无需更新。'**
  String about_noUpdateContent(String version);

  /// No description provided for @about_openSourceLicense.
  ///
  /// In zh, this message translates to:
  /// **'开源许可'**
  String get about_openSourceLicense;

  /// No description provided for @about_sourceCode.
  ///
  /// In zh, this message translates to:
  /// **'项目源码'**
  String get about_sourceCode;

  /// No description provided for @about_tapToDisableDeveloperMode.
  ///
  /// In zh, this message translates to:
  /// **'点击关闭开发者模式'**
  String get about_tapToDisableDeveloperMode;

  /// No description provided for @about_title.
  ///
  /// In zh, this message translates to:
  /// **'关于'**
  String get about_title;

  /// No description provided for @deviceInfo_dohOff.
  ///
  /// In zh, this message translates to:
  /// **'DOH: 关闭'**
  String get deviceInfo_dohOff;

  /// No description provided for @deviceInfo_proxyOff.
  ///
  /// In zh, this message translates to:
  /// **'代理: 关闭'**
  String get deviceInfo_proxyOff;

  /// No description provided for @update_changelog.
  ///
  /// In zh, this message translates to:
  /// **'更新内容'**
  String get update_changelog;

  /// No description provided for @update_dontRemind.
  ///
  /// In zh, this message translates to:
  /// **'不再提醒'**
  String get update_dontRemind;

  /// No description provided for @update_newVersionFound.
  ///
  /// In zh, this message translates to:
  /// **'发现新版本'**
  String get update_newVersionFound;

  /// No description provided for @update_now.
  ///
  /// In zh, this message translates to:
  /// **'立即更新'**
  String get update_now;

  /// No description provided for @update_rateLimited.
  ///
  /// In zh, this message translates to:
  /// **'GitHub API 请求过于频繁，请稍后再试'**
  String get update_rateLimited;

  /// No description provided for @ai_askSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'AI 会基于话题内容为你解答'**
  String get ai_askSubtitle;

  /// No description provided for @ai_askTitle.
  ///
  /// In zh, this message translates to:
  /// **'向 AI 助手提问'**
  String get ai_askTitle;

  /// No description provided for @ai_clearChat.
  ///
  /// In zh, this message translates to:
  /// **'清空聊天'**
  String get ai_clearChat;

  /// No description provided for @ai_clearChatConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定要清空所有聊天记录吗？'**
  String get ai_clearChatConfirm;

  /// No description provided for @ai_clearChatTitle.
  ///
  /// In zh, this message translates to:
  /// **'清空聊天'**
  String get ai_clearChatTitle;

  /// No description provided for @ai_clearLabel.
  ///
  /// In zh, this message translates to:
  /// **'清空'**
  String get ai_clearLabel;

  /// No description provided for @ai_copiedToClipboard.
  ///
  /// In zh, this message translates to:
  /// **'已复制到剪贴板'**
  String get ai_copiedToClipboard;

  /// No description provided for @ai_copyLabel.
  ///
  /// In zh, this message translates to:
  /// **'复制'**
  String get ai_copyLabel;

  /// No description provided for @ai_exportImage.
  ///
  /// In zh, this message translates to:
  /// **'导出图片'**
  String get ai_exportImage;

  /// No description provided for @ai_generateFailed.
  ///
  /// In zh, this message translates to:
  /// **'生成失败'**
  String get ai_generateFailed;

  /// No description provided for @ai_highlights.
  ///
  /// In zh, this message translates to:
  /// **'有什么值得关注的'**
  String get ai_highlights;

  /// No description provided for @ai_highlightsPrompt.
  ///
  /// In zh, this message translates to:
  /// **'这个话题中有哪些值得关注的信息或亮点？'**
  String get ai_highlightsPrompt;

  /// No description provided for @ai_inputHint.
  ///
  /// In zh, this message translates to:
  /// **'输入消息...'**
  String get ai_inputHint;

  /// No description provided for @ai_likeInDev.
  ///
  /// In zh, this message translates to:
  /// **'点赞功能开发中...'**
  String get ai_likeInDev;

  /// No description provided for @ai_listViewpoints.
  ///
  /// In zh, this message translates to:
  /// **'列出主要观点'**
  String get ai_listViewpoints;

  /// No description provided for @ai_listViewpointsPrompt.
  ///
  /// In zh, this message translates to:
  /// **'请列出这个话题中各楼层的主要观点和立场。'**
  String get ai_listViewpointsPrompt;

  /// No description provided for @ai_moreTooltip.
  ///
  /// In zh, this message translates to:
  /// **'更多'**
  String get ai_moreTooltip;

  /// No description provided for @ai_multiSelectExport.
  ///
  /// In zh, this message translates to:
  /// **'多选导出'**
  String get ai_multiSelectExport;

  /// No description provided for @ai_newSession.
  ///
  /// In zh, this message translates to:
  /// **'新建会话'**
  String get ai_newSession;

  /// No description provided for @ai_retryLabel.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get ai_retryLabel;

  /// No description provided for @ai_selectContext.
  ///
  /// In zh, this message translates to:
  /// **'选择上下文范围'**
  String get ai_selectContext;

  /// No description provided for @ai_selectExportMessages.
  ///
  /// In zh, this message translates to:
  /// **'请选择要导出的消息'**
  String get ai_selectExportMessages;

  /// No description provided for @ai_selectModel.
  ///
  /// In zh, this message translates to:
  /// **'选择模型'**
  String get ai_selectModel;

  /// No description provided for @ai_selectedCount.
  ///
  /// In zh, this message translates to:
  /// **'已选 {count} 条'**
  String ai_selectedCount(int count);

  /// No description provided for @ai_sendTooltip.
  ///
  /// In zh, this message translates to:
  /// **'发送'**
  String get ai_sendTooltip;

  /// No description provided for @ai_sessionCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 条'**
  String ai_sessionCount(int count);

  /// No description provided for @ai_sessionHistory.
  ///
  /// In zh, this message translates to:
  /// **'会话记录'**
  String get ai_sessionHistory;

  /// No description provided for @ai_sessionTitle.
  ///
  /// In zh, this message translates to:
  /// **'会话 {index}'**
  String ai_sessionTitle(int index);

  /// No description provided for @ai_stopGenerate.
  ///
  /// In zh, this message translates to:
  /// **'停止生成'**
  String get ai_stopGenerate;

  /// No description provided for @ai_summarizePrompt.
  ///
  /// In zh, this message translates to:
  /// **'请简要总结这个话题的主要内容和讨论要点。'**
  String get ai_summarizePrompt;

  /// No description provided for @ai_summarizeTopic.
  ///
  /// In zh, this message translates to:
  /// **'总结这个话题'**
  String get ai_summarizeTopic;

  /// No description provided for @ai_swipeHint.
  ///
  /// In zh, this message translates to:
  /// **'向左滑动可打开 AI 助手'**
  String get ai_swipeHint;

  /// No description provided for @ai_title.
  ///
  /// In zh, this message translates to:
  /// **'AI 助手'**
  String get ai_title;

  /// No description provided for @ai_translatePost.
  ///
  /// In zh, this message translates to:
  /// **'翻译主帖'**
  String get ai_translatePost;

  /// No description provided for @ai_translatePrompt.
  ///
  /// In zh, this message translates to:
  /// **'请将主帖内容翻译成英文。'**
  String get ai_translatePrompt;

  /// No description provided for @ai_typingIndicator.
  ///
  /// In zh, this message translates to:
  /// **'正在输入'**
  String get ai_typingIndicator;

  /// No description provided for @appearance_appIcon.
  ///
  /// In zh, this message translates to:
  /// **'应用图标'**
  String get appearance_appIcon;

  /// No description provided for @appearance_colorAmber.
  ///
  /// In zh, this message translates to:
  /// **'琥珀'**
  String get appearance_colorAmber;

  /// No description provided for @appearance_colorBlue.
  ///
  /// In zh, this message translates to:
  /// **'蓝色'**
  String get appearance_colorBlue;

  /// No description provided for @appearance_colorGreen.
  ///
  /// In zh, this message translates to:
  /// **'绿色'**
  String get appearance_colorGreen;

  /// No description provided for @appearance_colorIndigo.
  ///
  /// In zh, this message translates to:
  /// **'靛蓝'**
  String get appearance_colorIndigo;

  /// No description provided for @appearance_colorOrange.
  ///
  /// In zh, this message translates to:
  /// **'橙色'**
  String get appearance_colorOrange;

  /// No description provided for @appearance_colorPink.
  ///
  /// In zh, this message translates to:
  /// **'粉色'**
  String get appearance_colorPink;

  /// No description provided for @appearance_colorPurple.
  ///
  /// In zh, this message translates to:
  /// **'紫色'**
  String get appearance_colorPurple;

  /// No description provided for @appearance_colorRed.
  ///
  /// In zh, this message translates to:
  /// **'红色'**
  String get appearance_colorRed;

  /// No description provided for @appearance_colorTeal.
  ///
  /// In zh, this message translates to:
  /// **'青色'**
  String get appearance_colorTeal;

  /// No description provided for @appearance_contentFontSize.
  ///
  /// In zh, this message translates to:
  /// **'内容字体大小'**
  String get appearance_contentFontSize;

  /// No description provided for @appearance_dialogBlur.
  ///
  /// In zh, this message translates to:
  /// **'对话框模糊'**
  String get appearance_dialogBlur;

  /// No description provided for @appearance_dialogBlurDesc.
  ///
  /// In zh, this message translates to:
  /// **'对话框弹出时模糊背景'**
  String get appearance_dialogBlurDesc;

  /// No description provided for @appearance_font.
  ///
  /// In zh, this message translates to:
  /// **'字体'**
  String get appearance_font;

  /// No description provided for @appearance_fontSystem.
  ///
  /// In zh, this message translates to:
  /// **'系统默认'**
  String get appearance_fontSystem;

  /// No description provided for @appearance_iconClassic.
  ///
  /// In zh, this message translates to:
  /// **'经典'**
  String get appearance_iconClassic;

  /// No description provided for @appearance_iconModern.
  ///
  /// In zh, this message translates to:
  /// **'现代'**
  String get appearance_iconModern;

  /// No description provided for @appearance_language.
  ///
  /// In zh, this message translates to:
  /// **'语言'**
  String get appearance_language;

  /// No description provided for @appearance_languageEn.
  ///
  /// In zh, this message translates to:
  /// **'English'**
  String get appearance_languageEn;

  /// No description provided for @appearance_languageSystem.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get appearance_languageSystem;

  /// No description provided for @appearance_languageZhCN.
  ///
  /// In zh, this message translates to:
  /// **'简体中文'**
  String get appearance_languageZhCN;

  /// No description provided for @appearance_languageZhHK.
  ///
  /// In zh, this message translates to:
  /// **'繁體中文（香港）'**
  String get appearance_languageZhHK;

  /// No description provided for @appearance_languageZhTW.
  ///
  /// In zh, this message translates to:
  /// **'繁體中文（台灣）'**
  String get appearance_languageZhTW;

  /// No description provided for @appearance_large.
  ///
  /// In zh, this message translates to:
  /// **'大'**
  String get appearance_large;

  /// No description provided for @appearance_modeAuto.
  ///
  /// In zh, this message translates to:
  /// **'自动'**
  String get appearance_modeAuto;

  /// No description provided for @appearance_modeDark.
  ///
  /// In zh, this message translates to:
  /// **'深色'**
  String get appearance_modeDark;

  /// No description provided for @appearance_modeLight.
  ///
  /// In zh, this message translates to:
  /// **'浅色'**
  String get appearance_modeLight;

  /// No description provided for @appearance_panguSpacing.
  ///
  /// In zh, this message translates to:
  /// **'阅读混排优化'**
  String get appearance_panguSpacing;

  /// No description provided for @appearance_panguSpacingDesc.
  ///
  /// In zh, this message translates to:
  /// **'浏览帖子时自动优化中英文间距'**
  String get appearance_panguSpacingDesc;

  /// No description provided for @appearance_reading.
  ///
  /// In zh, this message translates to:
  /// **'阅读'**
  String get appearance_reading;

  /// No description provided for @appearance_schemeVariant.
  ///
  /// In zh, this message translates to:
  /// **'配色风格'**
  String get appearance_schemeVariant;

  /// No description provided for @appearance_small.
  ///
  /// In zh, this message translates to:
  /// **'小'**
  String get appearance_small;

  /// No description provided for @appearance_switchIconFailed.
  ///
  /// In zh, this message translates to:
  /// **'切换图标失败，请稍后重试'**
  String get appearance_switchIconFailed;

  /// No description provided for @appearance_themeColor.
  ///
  /// In zh, this message translates to:
  /// **'主题色彩'**
  String get appearance_themeColor;

  /// No description provided for @appearance_themeMode.
  ///
  /// In zh, this message translates to:
  /// **'主题模式'**
  String get appearance_themeMode;

  /// No description provided for @appearance_title.
  ///
  /// In zh, this message translates to:
  /// **'外观'**
  String get appearance_title;

  /// No description provided for @layout_selectTopicHint.
  ///
  /// In zh, this message translates to:
  /// **'选择一个话题查看详情'**
  String get layout_selectTopicHint;

  /// No description provided for @reading_aiSwipeEntry.
  ///
  /// In zh, this message translates to:
  /// **'AI 助手滑动入口'**
  String get reading_aiSwipeEntry;

  /// No description provided for @reading_aiSwipeEntryDesc.
  ///
  /// In zh, this message translates to:
  /// **'在话题详情页向左滑动打开 AI 助手'**
  String get reading_aiSwipeEntryDesc;

  /// No description provided for @reading_expandRelatedLinks.
  ///
  /// In zh, this message translates to:
  /// **'默认展开相关链接'**
  String get reading_expandRelatedLinks;

  /// No description provided for @reading_expandRelatedLinksDesc.
  ///
  /// In zh, this message translates to:
  /// **'帖子中的相关链接区域默认展开显示'**
  String get reading_expandRelatedLinksDesc;

  /// No description provided for @reading_title.
  ///
  /// In zh, this message translates to:
  /// **'阅读设置'**
  String get reading_title;

  /// No description provided for @schemeVariant_content.
  ///
  /// In zh, this message translates to:
  /// **'内容'**
  String get schemeVariant_content;

  /// No description provided for @schemeVariant_expressive.
  ///
  /// In zh, this message translates to:
  /// **'表现力'**
  String get schemeVariant_expressive;

  /// No description provided for @schemeVariant_fidelity.
  ///
  /// In zh, this message translates to:
  /// **'高保真'**
  String get schemeVariant_fidelity;

  /// No description provided for @schemeVariant_fruitSalad.
  ///
  /// In zh, this message translates to:
  /// **'缤纷'**
  String get schemeVariant_fruitSalad;

  /// No description provided for @schemeVariant_monochrome.
  ///
  /// In zh, this message translates to:
  /// **'单色'**
  String get schemeVariant_monochrome;

  /// No description provided for @schemeVariant_neutral.
  ///
  /// In zh, this message translates to:
  /// **'中性'**
  String get schemeVariant_neutral;

  /// No description provided for @schemeVariant_rainbow.
  ///
  /// In zh, this message translates to:
  /// **'彩虹'**
  String get schemeVariant_rainbow;

  /// No description provided for @schemeVariant_tonalSpot.
  ///
  /// In zh, this message translates to:
  /// **'柔和色调'**
  String get schemeVariant_tonalSpot;

  /// No description provided for @schemeVariant_vibrant.
  ///
  /// In zh, this message translates to:
  /// **'鲜明'**
  String get schemeVariant_vibrant;

  /// No description provided for @auth_cdkConfirmMessage.
  ///
  /// In zh, this message translates to:
  /// **'Linux.do CDK 将获取你的基本信息，是否允许？'**
  String get auth_cdkConfirmMessage;

  /// No description provided for @auth_cdkConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'授权确认'**
  String get auth_cdkConfirmTitle;

  /// No description provided for @auth_clearDataAction.
  ///
  /// In zh, this message translates to:
  /// **'清理数据'**
  String get auth_clearDataAction;

  /// No description provided for @auth_cookieRepairLogoutHint.
  ///
  /// In zh, this message translates to:
  /// **'检测到历史登录 Cookie 异常，应用已自动清理相关脏数据。这可能会让旧的无效登录态立即失效，请重新登录。'**
  String get auth_cookieRepairLogoutHint;

  /// No description provided for @auth_frequentLogoutClearDataHint.
  ///
  /// In zh, this message translates to:
  /// **'最近 24 小时内多次触发登录失效。如果重新登录后仍反复发生，建议前往“数据管理”清除 Cookie 或全部数据后再登录。'**
  String get auth_frequentLogoutClearDataHint;

  /// No description provided for @auth_ldcConfirmMessage.
  ///
  /// In zh, this message translates to:
  /// **'Linux.do Credit 将获取你的基本信息，是否允许？'**
  String get auth_ldcConfirmMessage;

  /// No description provided for @auth_ldcConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'授权确认'**
  String get auth_ldcConfirmTitle;

  /// No description provided for @auth_logSubject.
  ///
  /// In zh, this message translates to:
  /// **'认证日志'**
  String get auth_logSubject;

  /// No description provided for @auth_loginExpiredRelogin.
  ///
  /// In zh, this message translates to:
  /// **'登录已失效，请重新登录'**
  String get auth_loginExpiredRelogin;

  /// No description provided for @auth_loginExpiredTitle.
  ///
  /// In zh, this message translates to:
  /// **'登录失效'**
  String get auth_loginExpiredTitle;

  /// No description provided for @auth_oauthExpired.
  ///
  /// In zh, this message translates to:
  /// **'{serviceName} 授权已过期'**
  String auth_oauthExpired(String serviceName);

  /// No description provided for @login_browserHint.
  ///
  /// In zh, this message translates to:
  /// **'将在浏览器中打开登录页面'**
  String get login_browserHint;

  /// No description provided for @login_slogan.
  ///
  /// In zh, this message translates to:
  /// **'真诚、友善、团结、专业'**
  String get login_slogan;

  /// No description provided for @migration_cookieUpgrade.
  ///
  /// In zh, this message translates to:
  /// **'正在升级 Cookie 存储...'**
  String get migration_cookieUpgrade;

  /// No description provided for @migration_reloginRequired.
  ///
  /// In zh, this message translates to:
  /// **'本次版本升级优化了 Cookie 存储机制，已清除旧的登录状态。请重新登录。'**
  String get migration_reloginRequired;

  /// No description provided for @migration_title.
  ///
  /// In zh, this message translates to:
  /// **'数据升级'**
  String get migration_title;

  /// No description provided for @oauth_approvePageParseFailed.
  ///
  /// In zh, this message translates to:
  /// **'授权页面解析失败，请确认已登录论坛'**
  String get oauth_approvePageParseFailed;

  /// No description provided for @oauth_callbackFailed.
  ///
  /// In zh, this message translates to:
  /// **'授权回调失败'**
  String get oauth_callbackFailed;

  /// No description provided for @oauth_getAuthUrlFailed.
  ///
  /// In zh, this message translates to:
  /// **'获取授权链接失败'**
  String get oauth_getAuthUrlFailed;

  /// No description provided for @oauth_missingParams.
  ///
  /// In zh, this message translates to:
  /// **'授权回调缺少必要参数'**
  String get oauth_missingParams;

  /// No description provided for @oauth_networkError.
  ///
  /// In zh, this message translates to:
  /// **'网络请求失败，请检查网络连接'**
  String get oauth_networkError;

  /// No description provided for @oauth_noRedirectResponse.
  ///
  /// In zh, this message translates to:
  /// **'授权服务未返回重定向'**
  String get oauth_noRedirectResponse;

  /// No description provided for @onboarding_guestAccess.
  ///
  /// In zh, this message translates to:
  /// **'游客访问'**
  String get onboarding_guestAccess;

  /// No description provided for @onboarding_networkSettings.
  ///
  /// In zh, this message translates to:
  /// **'网络设置'**
  String get onboarding_networkSettings;

  /// No description provided for @onboarding_slogan.
  ///
  /// In zh, this message translates to:
  /// **'真诚 · 友善 · 团结 · 专业'**
  String get onboarding_slogan;

  /// No description provided for @badge_bronze.
  ///
  /// In zh, this message translates to:
  /// **'铜牌'**
  String get badge_bronze;

  /// No description provided for @badge_bronzeBadge.
  ///
  /// In zh, this message translates to:
  /// **'铜牌徽章'**
  String get badge_bronzeBadge;

  /// No description provided for @badge_defaultName.
  ///
  /// In zh, this message translates to:
  /// **'徽章'**
  String get badge_defaultName;

  /// No description provided for @badge_gold.
  ///
  /// In zh, this message translates to:
  /// **'金牌'**
  String get badge_gold;

  /// No description provided for @badge_goldBadge.
  ///
  /// In zh, this message translates to:
  /// **'金牌徽章'**
  String get badge_goldBadge;

  /// No description provided for @badge_grantedCount.
  ///
  /// In zh, this message translates to:
  /// **'已授予 {count} 次'**
  String badge_grantedCount(int count);

  /// No description provided for @badge_grantedSuffix.
  ///
  /// In zh, this message translates to:
  /// **' 获得'**
  String get badge_grantedSuffix;

  /// No description provided for @badge_granteeCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 位'**
  String badge_granteeCount(int count);

  /// No description provided for @badge_grantees.
  ///
  /// In zh, this message translates to:
  /// **'获得者'**
  String get badge_grantees;

  /// No description provided for @badge_myBadges.
  ///
  /// In zh, this message translates to:
  /// **'我的徽章'**
  String get badge_myBadges;

  /// No description provided for @badge_noGrantees.
  ///
  /// In zh, this message translates to:
  /// **'暂无用户获得该徽章'**
  String get badge_noGrantees;

  /// No description provided for @badge_silver.
  ///
  /// In zh, this message translates to:
  /// **'银牌'**
  String get badge_silver;

  /// No description provided for @badge_silverBadge.
  ///
  /// In zh, this message translates to:
  /// **'银牌徽章'**
  String get badge_silverBadge;

  /// No description provided for @myBadges_badgeUnit.
  ///
  /// In zh, this message translates to:
  /// **'枚徽章'**
  String get myBadges_badgeUnit;

  /// No description provided for @myBadges_empty.
  ///
  /// In zh, this message translates to:
  /// **'暂无徽章'**
  String get myBadges_empty;

  /// No description provided for @myBadges_title.
  ///
  /// In zh, this message translates to:
  /// **'我的徽章'**
  String get myBadges_title;

  /// No description provided for @myBadges_totalEarned.
  ///
  /// In zh, this message translates to:
  /// **'累计获得'**
  String get myBadges_totalEarned;

  /// No description provided for @bookmark_deleteConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定要删除这个书签吗？'**
  String get bookmark_deleteConfirm;

  /// No description provided for @bookmark_editBookmark.
  ///
  /// In zh, this message translates to:
  /// **'编辑书签'**
  String get bookmark_editBookmark;

  /// No description provided for @bookmark_nameHint.
  ///
  /// In zh, this message translates to:
  /// **'为书签添加备注...'**
  String get bookmark_nameHint;

  /// No description provided for @bookmark_nameLabel.
  ///
  /// In zh, this message translates to:
  /// **'书签名称（可选）'**
  String get bookmark_nameLabel;

  /// No description provided for @bookmark_reminderCustom.
  ///
  /// In zh, this message translates to:
  /// **'自定义'**
  String get bookmark_reminderCustom;

  /// No description provided for @bookmark_reminderExpired.
  ///
  /// In zh, this message translates to:
  /// **'提醒已过期'**
  String get bookmark_reminderExpired;

  /// No description provided for @bookmark_reminderNextWeek.
  ///
  /// In zh, this message translates to:
  /// **'下周'**
  String get bookmark_reminderNextWeek;

  /// No description provided for @bookmark_reminderThreeDays.
  ///
  /// In zh, this message translates to:
  /// **'3天后'**
  String get bookmark_reminderThreeDays;

  /// No description provided for @bookmark_reminderTime.
  ///
  /// In zh, this message translates to:
  /// **'提醒时间：{time}'**
  String bookmark_reminderTime(String time);

  /// No description provided for @bookmark_reminderTomorrow.
  ///
  /// In zh, this message translates to:
  /// **'明天'**
  String get bookmark_reminderTomorrow;

  /// No description provided for @bookmark_reminderTwoHours.
  ///
  /// In zh, this message translates to:
  /// **'2小时后'**
  String get bookmark_reminderTwoHours;

  /// No description provided for @bookmark_removed.
  ///
  /// In zh, this message translates to:
  /// **'已取消书签'**
  String get bookmark_removed;

  /// No description provided for @bookmark_setReminder.
  ///
  /// In zh, this message translates to:
  /// **'设置提醒'**
  String get bookmark_setReminder;

  /// No description provided for @bookmarks_cancelReminder.
  ///
  /// In zh, this message translates to:
  /// **'取消提醒'**
  String get bookmarks_cancelReminder;

  /// No description provided for @bookmarks_deleted.
  ///
  /// In zh, this message translates to:
  /// **'已删除书签'**
  String get bookmarks_deleted;

  /// No description provided for @bookmarks_empty.
  ///
  /// In zh, this message translates to:
  /// **'暂无书签'**
  String get bookmarks_empty;

  /// No description provided for @bookmarks_emptySearchHint.
  ///
  /// In zh, this message translates to:
  /// **'输入关键词搜索书签'**
  String get bookmarks_emptySearchHint;

  /// No description provided for @bookmarks_expired.
  ///
  /// In zh, this message translates to:
  /// **' 已过期'**
  String get bookmarks_expired;

  /// No description provided for @bookmarks_reminderCancelled.
  ///
  /// In zh, this message translates to:
  /// **'已取消提醒'**
  String get bookmarks_reminderCancelled;

  /// No description provided for @bookmarks_searchHint.
  ///
  /// In zh, this message translates to:
  /// **'在书签中搜索...'**
  String get bookmarks_searchHint;

  /// No description provided for @bookmarks_title.
  ///
  /// In zh, this message translates to:
  /// **'我的书签'**
  String get bookmarks_title;

  /// No description provided for @readLater_title.
  ///
  /// In zh, this message translates to:
  /// **'稍后阅读'**
  String get readLater_title;

  /// No description provided for @categoryTopics_createPost.
  ///
  /// In zh, this message translates to:
  /// **'发帖'**
  String get categoryTopics_createPost;

  /// No description provided for @categoryTopics_empty.
  ///
  /// In zh, this message translates to:
  /// **'该分类下暂无话题'**
  String get categoryTopics_empty;

  /// No description provided for @category_addHint.
  ///
  /// In zh, this message translates to:
  /// **'点击下方分类添加到标签栏'**
  String get category_addHint;

  /// No description provided for @category_allCategories.
  ///
  /// In zh, this message translates to:
  /// **'全部分类'**
  String get category_allCategories;

  /// No description provided for @category_available.
  ///
  /// In zh, this message translates to:
  /// **'可添加'**
  String get category_available;

  /// No description provided for @category_browse.
  ///
  /// In zh, this message translates to:
  /// **'浏览分类'**
  String get category_browse;

  /// No description provided for @category_dragHint.
  ///
  /// In zh, this message translates to:
  /// **'拖拽排序，点击移除'**
  String get category_dragHint;

  /// No description provided for @category_editHint.
  ///
  /// In zh, this message translates to:
  /// **'点击\"编辑\"添加常用分类到标签栏'**
  String get category_editHint;

  /// No description provided for @category_editMyCategories.
  ///
  /// In zh, this message translates to:
  /// **'编辑我的分类'**
  String get category_editMyCategories;

  /// No description provided for @category_levelMuted.
  ///
  /// In zh, this message translates to:
  /// **'静音'**
  String get category_levelMuted;

  /// No description provided for @category_levelMutedDesc.
  ///
  /// In zh, this message translates to:
  /// **'不接收此分类的任何通知'**
  String get category_levelMutedDesc;

  /// No description provided for @category_levelRegular.
  ///
  /// In zh, this message translates to:
  /// **'常规'**
  String get category_levelRegular;

  /// No description provided for @category_levelRegularDesc.
  ///
  /// In zh, this message translates to:
  /// **'只在被 @ 提及或回复时通知'**
  String get category_levelRegularDesc;

  /// No description provided for @category_levelTracking.
  ///
  /// In zh, this message translates to:
  /// **'跟踪'**
  String get category_levelTracking;

  /// No description provided for @category_levelTrackingDesc.
  ///
  /// In zh, this message translates to:
  /// **'显示新帖未读计数'**
  String get category_levelTrackingDesc;

  /// No description provided for @category_levelWatching.
  ///
  /// In zh, this message translates to:
  /// **'关注'**
  String get category_levelWatching;

  /// No description provided for @category_levelWatchingDesc.
  ///
  /// In zh, this message translates to:
  /// **'每个新回复都通知'**
  String get category_levelWatchingDesc;

  /// No description provided for @category_levelWatchingFirstPost.
  ///
  /// In zh, this message translates to:
  /// **'关注新话题'**
  String get category_levelWatchingFirstPost;

  /// No description provided for @category_levelWatchingFirstPostDesc.
  ///
  /// In zh, this message translates to:
  /// **'此分类有新话题时通知'**
  String get category_levelWatchingFirstPostDesc;

  /// No description provided for @category_loadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载分类失败: {error}'**
  String category_loadFailed(String error);

  /// No description provided for @category_myCategories.
  ///
  /// In zh, this message translates to:
  /// **'我的分类'**
  String get category_myCategories;

  /// No description provided for @category_noCategories.
  ///
  /// In zh, this message translates to:
  /// **'暂无分类'**
  String get category_noCategories;

  /// No description provided for @category_noCategoriesFound.
  ///
  /// In zh, this message translates to:
  /// **'未找到相关分类'**
  String get category_noCategoriesFound;

  /// No description provided for @category_parentAll.
  ///
  /// In zh, this message translates to:
  /// **'{name}（全部）'**
  String category_parentAll(String name);

  /// No description provided for @category_searchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索分类...'**
  String get category_searchHint;

  /// No description provided for @tagTopics_empty.
  ///
  /// In zh, this message translates to:
  /// **'该标签下暂无话题'**
  String get tagTopics_empty;

  /// No description provided for @tag_maxTagsReached.
  ///
  /// In zh, this message translates to:
  /// **'最多只能选择 {max} 个标签'**
  String tag_maxTagsReached(int max);

  /// No description provided for @tag_noTags.
  ///
  /// In zh, this message translates to:
  /// **'暂无可用标签'**
  String get tag_noTags;

  /// No description provided for @tag_noTagsFound.
  ///
  /// In zh, this message translates to:
  /// **'未找到相关标签'**
  String get tag_noTagsFound;

  /// No description provided for @tag_requiredGroupWarning.
  ///
  /// In zh, this message translates to:
  /// **'需从 \"{name}\" 标签组选择至少 {minCount} 个标签'**
  String tag_requiredGroupWarning(String name, int minCount);

  /// No description provided for @tag_requiredTagGroupHint.
  ///
  /// In zh, this message translates to:
  /// **'需从 \"{name}\" 选择至少 {minCount} 个'**
  String tag_requiredTagGroupHint(String name, int minCount);

  /// No description provided for @tag_searchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索标签...'**
  String get tag_searchHint;

  /// No description provided for @tag_searchWithCount.
  ///
  /// In zh, this message translates to:
  /// **'搜索标签 (已选 {count})...'**
  String tag_searchWithCount(int count);

  /// No description provided for @tag_searchWithMax.
  ///
  /// In zh, this message translates to:
  /// **'搜索标签 (已选 {selected}/{max})...'**
  String tag_searchWithMax(int selected, int max);

  /// No description provided for @tag_searchWithMin.
  ///
  /// In zh, this message translates to:
  /// **'搜索标签 (已选 {selected}, 至少 {min})...'**
  String tag_searchWithMin(int selected, int min);

  /// No description provided for @tag_topicCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个话题'**
  String tag_topicCount(int count);

  /// No description provided for @common_about.
  ///
  /// In zh, this message translates to:
  /// **'关于'**
  String get common_about;

  /// No description provided for @common_add.
  ///
  /// In zh, this message translates to:
  /// **'添加'**
  String get common_add;

  /// No description provided for @common_addBookmark.
  ///
  /// In zh, this message translates to:
  /// **'添加书签'**
  String get common_addBookmark;

  /// No description provided for @common_added.
  ///
  /// In zh, this message translates to:
  /// **'已添加'**
  String get common_added;

  /// No description provided for @common_all.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get common_all;

  /// No description provided for @common_allow.
  ///
  /// In zh, this message translates to:
  /// **'允许'**
  String get common_allow;

  /// No description provided for @common_authExpired.
  ///
  /// In zh, this message translates to:
  /// **'授权已过期'**
  String get common_authExpired;

  /// No description provided for @common_back.
  ///
  /// In zh, this message translates to:
  /// **'返回'**
  String get common_back;

  /// No description provided for @common_bookmarkAdded.
  ///
  /// In zh, this message translates to:
  /// **'已添加书签'**
  String get common_bookmarkAdded;

  /// No description provided for @common_bookmarkRemoved.
  ///
  /// In zh, this message translates to:
  /// **'已取消书签'**
  String get common_bookmarkRemoved;

  /// No description provided for @common_bookmarkUpdated.
  ///
  /// In zh, this message translates to:
  /// **'书签已更新'**
  String get common_bookmarkUpdated;

  /// No description provided for @common_cancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get common_cancel;

  /// No description provided for @common_cannotOpenBrowser.
  ///
  /// In zh, this message translates to:
  /// **'无法打开浏览器'**
  String get common_cannotOpenBrowser;

  /// No description provided for @common_checkInput.
  ///
  /// In zh, this message translates to:
  /// **'请检查输入'**
  String get common_checkInput;

  /// No description provided for @common_checkNetworkRetry.
  ///
  /// In zh, this message translates to:
  /// **'请检查网络后重试'**
  String get common_checkNetworkRetry;

  /// No description provided for @common_clear.
  ///
  /// In zh, this message translates to:
  /// **'清除'**
  String get common_clear;

  /// No description provided for @common_clearFailed.
  ///
  /// In zh, this message translates to:
  /// **'清除失败: {error}'**
  String common_clearFailed(String error);

  /// No description provided for @common_clipboardUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'剪贴板不可用'**
  String get common_clipboardUnavailable;

  /// No description provided for @common_close.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get common_close;

  /// No description provided for @common_closePreview.
  ///
  /// In zh, this message translates to:
  /// **'关闭预览'**
  String get common_closePreview;

  /// No description provided for @common_codeCopied.
  ///
  /// In zh, this message translates to:
  /// **'已复制代码'**
  String get common_codeCopied;

  /// No description provided for @common_confirm.
  ///
  /// In zh, this message translates to:
  /// **'确定'**
  String get common_confirm;

  /// No description provided for @common_continue.
  ///
  /// In zh, this message translates to:
  /// **'继续'**
  String get common_continue;

  /// No description provided for @common_continueVisit.
  ///
  /// In zh, this message translates to:
  /// **'继续访问'**
  String get common_continueVisit;

  /// No description provided for @common_copiedToClipboard.
  ///
  /// In zh, this message translates to:
  /// **'已复制到剪贴板'**
  String get common_copiedToClipboard;

  /// No description provided for @common_copy.
  ///
  /// In zh, this message translates to:
  /// **'复制'**
  String get common_copy;

  /// No description provided for @common_copyLink.
  ///
  /// In zh, this message translates to:
  /// **'复制链接'**
  String get common_copyLink;

  /// No description provided for @common_copyQuote.
  ///
  /// In zh, this message translates to:
  /// **'复制引用'**
  String get common_copyQuote;

  /// No description provided for @common_custom.
  ///
  /// In zh, this message translates to:
  /// **'自定义'**
  String get common_custom;

  /// No description provided for @common_decodeAvif.
  ///
  /// In zh, this message translates to:
  /// **'解码 AVIF'**
  String get common_decodeAvif;

  /// No description provided for @common_delete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get common_delete;

  /// No description provided for @common_deleteBookmark.
  ///
  /// In zh, this message translates to:
  /// **'删除书签'**
  String get common_deleteBookmark;

  /// No description provided for @common_deleted.
  ///
  /// In zh, this message translates to:
  /// **'已删除'**
  String get common_deleted;

  /// No description provided for @common_deny.
  ///
  /// In zh, this message translates to:
  /// **'拒绝'**
  String get common_deny;

  /// No description provided for @common_details.
  ///
  /// In zh, this message translates to:
  /// **'详情'**
  String get common_details;

  /// No description provided for @common_discard.
  ///
  /// In zh, this message translates to:
  /// **'舍弃'**
  String get common_discard;

  /// No description provided for @common_done.
  ///
  /// In zh, this message translates to:
  /// **'完成'**
  String get common_done;

  /// No description provided for @common_edit.
  ///
  /// In zh, this message translates to:
  /// **'编辑'**
  String get common_edit;

  /// No description provided for @common_editTopic.
  ///
  /// In zh, this message translates to:
  /// **'编辑话题'**
  String get common_editTopic;

  /// No description provided for @common_enable.
  ///
  /// In zh, this message translates to:
  /// **'开启'**
  String get common_enable;

  /// No description provided for @common_error.
  ///
  /// In zh, this message translates to:
  /// **'发生错误'**
  String get common_error;

  /// No description provided for @common_errorDetails.
  ///
  /// In zh, this message translates to:
  /// **'错误详情'**
  String get common_errorDetails;

  /// No description provided for @common_exit.
  ///
  /// In zh, this message translates to:
  /// **'退出'**
  String get common_exit;

  /// No description provided for @common_exitPreview.
  ///
  /// In zh, this message translates to:
  /// **'退出预览'**
  String get common_exitPreview;

  /// No description provided for @common_export.
  ///
  /// In zh, this message translates to:
  /// **'导出'**
  String get common_export;

  /// No description provided for @common_failed.
  ///
  /// In zh, this message translates to:
  /// **'失败'**
  String get common_failed;

  /// No description provided for @common_fillComplete.
  ///
  /// In zh, this message translates to:
  /// **'请填写完整信息'**
  String get common_fillComplete;

  /// No description provided for @common_filter.
  ///
  /// In zh, this message translates to:
  /// **'筛选'**
  String get common_filter;

  /// No description provided for @common_gotIt.
  ///
  /// In zh, this message translates to:
  /// **'知道了'**
  String get common_gotIt;

  /// No description provided for @common_help.
  ///
  /// In zh, this message translates to:
  /// **'帮助'**
  String get common_help;

  /// No description provided for @common_hint.
  ///
  /// In zh, this message translates to:
  /// **'提示'**
  String get common_hint;

  /// No description provided for @common_import.
  ///
  /// In zh, this message translates to:
  /// **'导入'**
  String get common_import;

  /// No description provided for @common_later.
  ///
  /// In zh, this message translates to:
  /// **'稍后'**
  String get common_later;

  /// No description provided for @common_linkCopied.
  ///
  /// In zh, this message translates to:
  /// **'链接已复制'**
  String get common_linkCopied;

  /// No description provided for @common_loadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载失败'**
  String get common_loadFailed;

  /// No description provided for @common_loadFailedRetry.
  ///
  /// In zh, this message translates to:
  /// **'加载失败，请重试'**
  String get common_loadFailedRetry;

  /// No description provided for @common_loadFailedTapRetry.
  ///
  /// In zh, this message translates to:
  /// **'加载失败，点击重试'**
  String get common_loadFailedTapRetry;

  /// No description provided for @common_loading.
  ///
  /// In zh, this message translates to:
  /// **'加载中...'**
  String get common_loading;

  /// No description provided for @common_loadingData.
  ///
  /// In zh, this message translates to:
  /// **'加载数据...'**
  String get common_loadingData;

  /// No description provided for @common_login.
  ///
  /// In zh, this message translates to:
  /// **'登录'**
  String get common_login;

  /// No description provided for @common_logout.
  ///
  /// In zh, this message translates to:
  /// **'退出登录'**
  String get common_logout;

  /// No description provided for @common_more.
  ///
  /// In zh, this message translates to:
  /// **'更多'**
  String get common_more;

  /// No description provided for @common_name.
  ///
  /// In zh, this message translates to:
  /// **'名称'**
  String get common_name;

  /// No description provided for @common_networkDisconnected.
  ///
  /// In zh, this message translates to:
  /// **'网络连接已断开'**
  String get common_networkDisconnected;

  /// No description provided for @common_noContent.
  ///
  /// In zh, this message translates to:
  /// **'暂无内容'**
  String get common_noContent;

  /// No description provided for @common_noData.
  ///
  /// In zh, this message translates to:
  /// **'暂无数据'**
  String get common_noData;

  /// No description provided for @common_noMore.
  ///
  /// In zh, this message translates to:
  /// **'没有更多了'**
  String get common_noMore;

  /// No description provided for @common_notConfigured.
  ///
  /// In zh, this message translates to:
  /// **'未配置'**
  String get common_notConfigured;

  /// No description provided for @common_notSet.
  ///
  /// In zh, this message translates to:
  /// **'未设置'**
  String get common_notSet;

  /// No description provided for @common_notification.
  ///
  /// In zh, this message translates to:
  /// **'通知'**
  String get common_notification;

  /// No description provided for @common_ok.
  ///
  /// In zh, this message translates to:
  /// **'好'**
  String get common_ok;

  /// No description provided for @common_operationFailed.
  ///
  /// In zh, this message translates to:
  /// **'操作失败：{error}'**
  String common_operationFailed(String error);

  /// No description provided for @common_paste.
  ///
  /// In zh, this message translates to:
  /// **'粘贴'**
  String get common_paste;

  /// No description provided for @common_pleaseLogin.
  ///
  /// In zh, this message translates to:
  /// **'请先登录'**
  String get common_pleaseLogin;

  /// No description provided for @common_pleaseWait.
  ///
  /// In zh, this message translates to:
  /// **'请稍候...'**
  String get common_pleaseWait;

  /// No description provided for @common_preview.
  ///
  /// In zh, this message translates to:
  /// **'预览'**
  String get common_preview;

  /// No description provided for @common_publish.
  ///
  /// In zh, this message translates to:
  /// **'发布'**
  String get common_publish;

  /// No description provided for @common_quote.
  ///
  /// In zh, this message translates to:
  /// **'引用'**
  String get common_quote;

  /// No description provided for @common_quoteCopied.
  ///
  /// In zh, this message translates to:
  /// **'已复制引用'**
  String get common_quoteCopied;

  /// No description provided for @common_reAuth.
  ///
  /// In zh, this message translates to:
  /// **'重新授权'**
  String get common_reAuth;

  /// No description provided for @common_recentlyUsed.
  ///
  /// In zh, this message translates to:
  /// **'最近使用'**
  String get common_recentlyUsed;

  /// No description provided for @common_redo.
  ///
  /// In zh, this message translates to:
  /// **'重做'**
  String get common_redo;

  /// No description provided for @common_refresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新'**
  String get common_refresh;

  /// No description provided for @common_remove.
  ///
  /// In zh, this message translates to:
  /// **'移除'**
  String get common_remove;

  /// No description provided for @common_reply.
  ///
  /// In zh, this message translates to:
  /// **'回复'**
  String get common_reply;

  /// No description provided for @common_report.
  ///
  /// In zh, this message translates to:
  /// **'举报'**
  String get common_report;

  /// No description provided for @common_reset.
  ///
  /// In zh, this message translates to:
  /// **'重置'**
  String get common_reset;

  /// No description provided for @common_restore.
  ///
  /// In zh, this message translates to:
  /// **'恢复'**
  String get common_restore;

  /// No description provided for @common_restoreDefault.
  ///
  /// In zh, this message translates to:
  /// **'恢复默认'**
  String get common_restoreDefault;

  /// No description provided for @common_restored.
  ///
  /// In zh, this message translates to:
  /// **'已恢复'**
  String get common_restored;

  /// No description provided for @common_retry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get common_retry;

  /// No description provided for @common_save.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get common_save;

  /// No description provided for @common_search.
  ///
  /// In zh, this message translates to:
  /// **'搜索'**
  String get common_search;

  /// No description provided for @common_searchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索...'**
  String get common_searchHint;

  /// No description provided for @common_searchMore.
  ///
  /// In zh, this message translates to:
  /// **'搜索更多'**
  String get common_searchMore;

  /// No description provided for @common_send.
  ///
  /// In zh, this message translates to:
  /// **'发送'**
  String get common_send;

  /// No description provided for @common_share.
  ///
  /// In zh, this message translates to:
  /// **'分享'**
  String get common_share;

  /// No description provided for @common_shareFailed.
  ///
  /// In zh, this message translates to:
  /// **'分享失败，请重试'**
  String get common_shareFailed;

  /// No description provided for @common_shareImage.
  ///
  /// In zh, this message translates to:
  /// **'分享图片'**
  String get common_shareImage;

  /// No description provided for @common_shareLink.
  ///
  /// In zh, this message translates to:
  /// **'分享链接'**
  String get common_shareLink;

  /// No description provided for @common_sizeBytes.
  ///
  /// In zh, this message translates to:
  /// **'{size} 字节'**
  String common_sizeBytes(String size);

  /// No description provided for @common_sizeGB.
  ///
  /// In zh, this message translates to:
  /// **'{size} GB'**
  String common_sizeGB(String size);

  /// No description provided for @common_sizeKB.
  ///
  /// In zh, this message translates to:
  /// **'{size} KB'**
  String common_sizeKB(String size);

  /// No description provided for @common_sizeMB.
  ///
  /// In zh, this message translates to:
  /// **'{size} MB'**
  String common_sizeMB(String size);

  /// No description provided for @common_skip.
  ///
  /// In zh, this message translates to:
  /// **'跳过'**
  String get common_skip;

  /// No description provided for @common_success.
  ///
  /// In zh, this message translates to:
  /// **'成功'**
  String get common_success;

  /// No description provided for @common_test.
  ///
  /// In zh, this message translates to:
  /// **'测试'**
  String get common_test;

  /// No description provided for @common_title.
  ///
  /// In zh, this message translates to:
  /// **'标题'**
  String get common_title;

  /// No description provided for @common_trustRequirements.
  ///
  /// In zh, this message translates to:
  /// **'信任要求'**
  String get common_trustRequirements;

  /// No description provided for @common_understood.
  ///
  /// In zh, this message translates to:
  /// **'我知道了'**
  String get common_understood;

  /// No description provided for @common_undo.
  ///
  /// In zh, this message translates to:
  /// **'撤销'**
  String get common_undo;

  /// No description provided for @common_unknown.
  ///
  /// In zh, this message translates to:
  /// **'未知'**
  String get common_unknown;

  /// No description provided for @common_unknownError.
  ///
  /// In zh, this message translates to:
  /// **'未知错误'**
  String get common_unknownError;

  /// No description provided for @common_upload.
  ///
  /// In zh, this message translates to:
  /// **'上传'**
  String get common_upload;

  /// No description provided for @common_view.
  ///
  /// In zh, this message translates to:
  /// **'查看'**
  String get common_view;

  /// No description provided for @common_viewAll.
  ///
  /// In zh, this message translates to:
  /// **'查看全部'**
  String get common_viewAll;

  /// No description provided for @common_viewDetails.
  ///
  /// In zh, this message translates to:
  /// **'查看详情'**
  String get common_viewDetails;

  /// No description provided for @createTopic_charCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 字符'**
  String createTopic_charCount(int count);

  /// No description provided for @createTopic_confirmPublish.
  ///
  /// In zh, this message translates to:
  /// **'确定发布'**
  String get createTopic_confirmPublish;

  /// No description provided for @createTopic_contentHint.
  ///
  /// In zh, this message translates to:
  /// **'正文内容 (支持 Markdown)...'**
  String get createTopic_contentHint;

  /// No description provided for @createTopic_continueEditing.
  ///
  /// In zh, this message translates to:
  /// **'继续编辑'**
  String get createTopic_continueEditing;

  /// No description provided for @createTopic_discardPost.
  ///
  /// In zh, this message translates to:
  /// **'放弃帖子'**
  String get createTopic_discardPost;

  /// No description provided for @createTopic_discardPostContent.
  ///
  /// In zh, this message translates to:
  /// **'你想放弃你的帖子吗？'**
  String get createTopic_discardPostContent;

  /// No description provided for @createTopic_enterContent.
  ///
  /// In zh, this message translates to:
  /// **'请输入内容'**
  String get createTopic_enterContent;

  /// No description provided for @createTopic_enterTitle.
  ///
  /// In zh, this message translates to:
  /// **'请输入标题'**
  String get createTopic_enterTitle;

  /// No description provided for @createTopic_loadCategoryFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载分类失败: {error}'**
  String createTopic_loadCategoryFailed(String error);

  /// No description provided for @createTopic_minContentLength.
  ///
  /// In zh, this message translates to:
  /// **'内容至少需要 {min} 个字符'**
  String createTopic_minContentLength(int min);

  /// No description provided for @createTopic_minTags.
  ///
  /// In zh, this message translates to:
  /// **'此分类至少需要 {min} 个标签'**
  String createTopic_minTags(int min);

  /// No description provided for @createTopic_minTitleLength.
  ///
  /// In zh, this message translates to:
  /// **'标题至少需要 {min} 个字符'**
  String createTopic_minTitleLength(int min);

  /// No description provided for @createTopic_noContent.
  ///
  /// In zh, this message translates to:
  /// **'（无内容）'**
  String get createTopic_noContent;

  /// No description provided for @createTopic_noTitle.
  ///
  /// In zh, this message translates to:
  /// **'（无标题）'**
  String get createTopic_noTitle;

  /// No description provided for @createTopic_pendingReview.
  ///
  /// In zh, this message translates to:
  /// **'你的帖子已提交，正在等待审核'**
  String get createTopic_pendingReview;

  /// No description provided for @createTopic_restoreDraft.
  ///
  /// In zh, this message translates to:
  /// **'恢复草稿'**
  String get createTopic_restoreDraft;

  /// No description provided for @createTopic_restoreDraftContent.
  ///
  /// In zh, this message translates to:
  /// **'检测到未发送的草稿，是否恢复？'**
  String get createTopic_restoreDraftContent;

  /// No description provided for @createTopic_selectCategory.
  ///
  /// In zh, this message translates to:
  /// **'请选择分类'**
  String get createTopic_selectCategory;

  /// No description provided for @createTopic_templateNotModified.
  ///
  /// In zh, this message translates to:
  /// **'您尚未修改分类模板内容，确定要发布吗？'**
  String get createTopic_templateNotModified;

  /// No description provided for @createTopic_title.
  ///
  /// In zh, this message translates to:
  /// **'创建话题'**
  String get createTopic_title;

  /// No description provided for @createTopic_titleHint.
  ///
  /// In zh, this message translates to:
  /// **'键入一个吸引人的标题...'**
  String get createTopic_titleHint;

  /// No description provided for @editTopic_editPm.
  ///
  /// In zh, this message translates to:
  /// **'编辑私信'**
  String get editTopic_editPm;

  /// No description provided for @editTopic_editTopic.
  ///
  /// In zh, this message translates to:
  /// **'编辑话题'**
  String get editTopic_editTopic;

  /// No description provided for @editTopic_loadContentFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载内容失败: {error}'**
  String editTopic_loadContentFailed(String error);

  /// No description provided for @backup_invalidFormat.
  ///
  /// In zh, this message translates to:
  /// **'无效的备份文件格式'**
  String get backup_invalidFormat;

  /// No description provided for @backup_missingDataField.
  ///
  /// In zh, this message translates to:
  /// **'备份文件格式错误：缺少 data 字段'**
  String get backup_missingDataField;

  /// No description provided for @dataManagement_aiChatCleared.
  ///
  /// In zh, this message translates to:
  /// **'AI 聊天数据已清除'**
  String get dataManagement_aiChatCleared;

  /// No description provided for @dataManagement_aiChatData.
  ///
  /// In zh, this message translates to:
  /// **'AI 聊天数据'**
  String get dataManagement_aiChatData;

  /// No description provided for @dataManagement_allCleared.
  ///
  /// In zh, this message translates to:
  /// **'所有缓存已清除，请重新登录'**
  String get dataManagement_allCleared;

  /// No description provided for @dataManagement_apiKeysCount.
  ///
  /// In zh, this message translates to:
  /// **'包含 {count} 个 API Key'**
  String dataManagement_apiKeysCount(int count);

  /// No description provided for @dataManagement_autoManagement.
  ///
  /// In zh, this message translates to:
  /// **'自动管理'**
  String get dataManagement_autoManagement;

  /// No description provided for @dataManagement_backupSource.
  ///
  /// In zh, this message translates to:
  /// **'备份来源: v{version}'**
  String dataManagement_backupSource(String version);

  /// No description provided for @dataManagement_backupSubject.
  ///
  /// In zh, this message translates to:
  /// **'FluxDO 数据备份'**
  String get dataManagement_backupSubject;

  /// No description provided for @dataManagement_cacheManagement.
  ///
  /// In zh, this message translates to:
  /// **'缓存管理'**
  String get dataManagement_cacheManagement;

  /// No description provided for @dataManagement_calculating.
  ///
  /// In zh, this message translates to:
  /// **'计算中...'**
  String get dataManagement_calculating;

  /// No description provided for @dataManagement_clearAiChatContent.
  ///
  /// In zh, this message translates to:
  /// **'将删除所有 AI 聊天记录，此操作不可恢复。'**
  String get dataManagement_clearAiChatContent;

  /// No description provided for @dataManagement_clearAiChatTitle.
  ///
  /// In zh, this message translates to:
  /// **'清除 AI 聊天数据'**
  String get dataManagement_clearAiChatTitle;

  /// No description provided for @dataManagement_clearAll.
  ///
  /// In zh, this message translates to:
  /// **'全部清除'**
  String get dataManagement_clearAll;

  /// No description provided for @dataManagement_clearAllCache.
  ///
  /// In zh, this message translates to:
  /// **'清除所有缓存'**
  String get dataManagement_clearAllCache;

  /// No description provided for @dataManagement_clearAllContent.
  ///
  /// In zh, this message translates to:
  /// **'将清除所有缓存数据，包括图片缓存、AI 聊天数据和 Cookie。\n\n清除 Cookie 后需要重新登录。'**
  String get dataManagement_clearAllContent;

  /// No description provided for @dataManagement_clearAllTitle.
  ///
  /// In zh, this message translates to:
  /// **'清除所有缓存'**
  String get dataManagement_clearAllTitle;

  /// No description provided for @dataManagement_clearAndLogout.
  ///
  /// In zh, this message translates to:
  /// **'清除并退出登录'**
  String get dataManagement_clearAndLogout;

  /// No description provided for @dataManagement_clearCookieContent.
  ///
  /// In zh, this message translates to:
  /// **'清除 Cookie 后需要重新登录，确定要继续吗？'**
  String get dataManagement_clearCookieContent;

  /// No description provided for @dataManagement_clearCookieTitle.
  ///
  /// In zh, this message translates to:
  /// **'清除 Cookie 缓存'**
  String get dataManagement_clearCookieTitle;

  /// No description provided for @dataManagement_clearOnExit.
  ///
  /// In zh, this message translates to:
  /// **'退出时清除图片缓存'**
  String get dataManagement_clearOnExit;

  /// No description provided for @dataManagement_clearOnExitDesc.
  ///
  /// In zh, this message translates to:
  /// **'下次启动时自动清除图片缓存'**
  String get dataManagement_clearOnExitDesc;

  /// No description provided for @dataManagement_confirmImport.
  ///
  /// In zh, this message translates to:
  /// **'确认导入'**
  String get dataManagement_confirmImport;

  /// No description provided for @dataManagement_cookieCache.
  ///
  /// In zh, this message translates to:
  /// **'Cookie 缓存'**
  String get dataManagement_cookieCache;

  /// No description provided for @dataManagement_cookieCleared.
  ///
  /// In zh, this message translates to:
  /// **'Cookie 缓存已清除，请重新登录'**
  String get dataManagement_cookieCleared;

  /// No description provided for @dataManagement_dataBackup.
  ///
  /// In zh, this message translates to:
  /// **'数据备份'**
  String get dataManagement_dataBackup;

  /// No description provided for @dataManagement_exportData.
  ///
  /// In zh, this message translates to:
  /// **'导出数据'**
  String get dataManagement_exportData;

  /// No description provided for @dataManagement_exportDesc.
  ///
  /// In zh, this message translates to:
  /// **'将偏好设置导出为文件'**
  String get dataManagement_exportDesc;

  /// No description provided for @dataManagement_exportFailed.
  ///
  /// In zh, this message translates to:
  /// **'导出失败: {error}'**
  String dataManagement_exportFailed(String error);

  /// No description provided for @dataManagement_exportTime.
  ///
  /// In zh, this message translates to:
  /// **'导出时间: {time}'**
  String dataManagement_exportTime(String time);

  /// No description provided for @dataManagement_imageCache.
  ///
  /// In zh, this message translates to:
  /// **'图片缓存'**
  String get dataManagement_imageCache;

  /// No description provided for @dataManagement_imageCacheCleared.
  ///
  /// In zh, this message translates to:
  /// **'图片缓存已清除'**
  String get dataManagement_imageCacheCleared;

  /// No description provided for @dataManagement_importAndRestart.
  ///
  /// In zh, this message translates to:
  /// **'导入并重启'**
  String get dataManagement_importAndRestart;

  /// No description provided for @dataManagement_importData.
  ///
  /// In zh, this message translates to:
  /// **'导入数据'**
  String get dataManagement_importData;

  /// No description provided for @dataManagement_importDesc.
  ///
  /// In zh, this message translates to:
  /// **'从备份文件恢复偏好设置'**
  String get dataManagement_importDesc;

  /// No description provided for @dataManagement_importFailed.
  ///
  /// In zh, this message translates to:
  /// **'导入失败: {error}'**
  String dataManagement_importFailed(String error);

  /// No description provided for @dataManagement_importSuccess.
  ///
  /// In zh, this message translates to:
  /// **'数据已导入，请重启应用'**
  String get dataManagement_importSuccess;

  /// No description provided for @dataManagement_importWarning.
  ///
  /// In zh, this message translates to:
  /// **'导入后将覆盖当前对应的设置项，需要重启应用生效。'**
  String get dataManagement_importWarning;

  /// No description provided for @dataManagement_noCache.
  ///
  /// In zh, this message translates to:
  /// **'无缓存'**
  String get dataManagement_noCache;

  /// No description provided for @dataManagement_settingsCount.
  ///
  /// In zh, this message translates to:
  /// **'包含 {count} 项设置'**
  String dataManagement_settingsCount(int count);

  /// No description provided for @dataManagement_title.
  ///
  /// In zh, this message translates to:
  /// **'数据管理'**
  String get dataManagement_title;

  /// No description provided for @appLogs_appStart.
  ///
  /// In zh, this message translates to:
  /// **'应用启动'**
  String get appLogs_appStart;

  /// No description provided for @appLogs_clearContent.
  ///
  /// In zh, this message translates to:
  /// **'确定要清除所有日志吗？此操作不可撤销。'**
  String get appLogs_clearContent;

  /// No description provided for @appLogs_clearLogs.
  ///
  /// In zh, this message translates to:
  /// **'清除日志'**
  String get appLogs_clearLogs;

  /// No description provided for @appLogs_clearTitle.
  ///
  /// In zh, this message translates to:
  /// **'清除日志'**
  String get appLogs_clearTitle;

  /// No description provided for @appLogs_copyAll.
  ///
  /// In zh, this message translates to:
  /// **'复制全部'**
  String get appLogs_copyAll;

  /// No description provided for @appLogs_copyDeviceInfo.
  ///
  /// In zh, this message translates to:
  /// **'复制设备信息'**
  String get appLogs_copyDeviceInfo;

  /// No description provided for @appLogs_duration.
  ///
  /// In zh, this message translates to:
  /// **'耗时'**
  String get appLogs_duration;

  /// No description provided for @appLogs_error.
  ///
  /// In zh, this message translates to:
  /// **'错误'**
  String get appLogs_error;

  /// No description provided for @appLogs_errorType.
  ///
  /// In zh, this message translates to:
  /// **'错误类型'**
  String get appLogs_errorType;

  /// No description provided for @appLogs_event.
  ///
  /// In zh, this message translates to:
  /// **'事件'**
  String get appLogs_event;

  /// No description provided for @appLogs_feedbackSending.
  ///
  /// In zh, this message translates to:
  /// **'正在发送反馈…'**
  String get appLogs_feedbackSending;

  /// No description provided for @appLogs_feedbackSent.
  ///
  /// In zh, this message translates to:
  /// **'反馈已发送'**
  String get appLogs_feedbackSent;

  /// No description provided for @appLogs_feedbackTitle.
  ///
  /// In zh, this message translates to:
  /// **'应用日志反馈'**
  String get appLogs_feedbackTitle;

  /// No description provided for @appLogs_level.
  ///
  /// In zh, this message translates to:
  /// **'级别'**
  String get appLogs_level;

  /// No description provided for @appLogs_lifecycle.
  ///
  /// In zh, this message translates to:
  /// **'生命周期'**
  String get appLogs_lifecycle;

  /// No description provided for @appLogs_lifecycleEvent.
  ///
  /// In zh, this message translates to:
  /// **'生命周期事件'**
  String get appLogs_lifecycleEvent;

  /// No description provided for @appLogs_logoutActive.
  ///
  /// In zh, this message translates to:
  /// **'主动退出'**
  String get appLogs_logoutActive;

  /// No description provided for @appLogs_logoutPassive.
  ///
  /// In zh, this message translates to:
  /// **'被动退出'**
  String get appLogs_logoutPassive;

  /// No description provided for @appLogs_logsCleared.
  ///
  /// In zh, this message translates to:
  /// **'日志已清除'**
  String get appLogs_logsCleared;

  /// No description provided for @appLogs_message.
  ///
  /// In zh, this message translates to:
  /// **'消息'**
  String get appLogs_message;

  /// No description provided for @appLogs_method.
  ///
  /// In zh, this message translates to:
  /// **'方法'**
  String get appLogs_method;

  /// No description provided for @appLogs_noLogs.
  ///
  /// In zh, this message translates to:
  /// **'暂无日志'**
  String get appLogs_noLogs;

  /// No description provided for @appLogs_noMatchingLogs.
  ///
  /// In zh, this message translates to:
  /// **'无匹配日志'**
  String get appLogs_noMatchingLogs;

  /// No description provided for @appLogs_reason.
  ///
  /// In zh, this message translates to:
  /// **'原因'**
  String get appLogs_reason;

  /// No description provided for @appLogs_request.
  ///
  /// In zh, this message translates to:
  /// **'请求'**
  String get appLogs_request;

  /// No description provided for @appLogs_sendFeedback.
  ///
  /// In zh, this message translates to:
  /// **'私信反馈日志'**
  String get appLogs_sendFeedback;

  /// No description provided for @appLogs_shareLogs.
  ///
  /// In zh, this message translates to:
  /// **'分享日志'**
  String get appLogs_shareLogs;

  /// No description provided for @appLogs_shareSubject.
  ///
  /// In zh, this message translates to:
  /// **'应用日志'**
  String get appLogs_shareSubject;

  /// No description provided for @appLogs_stack.
  ///
  /// In zh, this message translates to:
  /// **'堆栈'**
  String get appLogs_stack;

  /// No description provided for @appLogs_stackTrace.
  ///
  /// In zh, this message translates to:
  /// **'堆栈跟踪'**
  String get appLogs_stackTrace;

  /// No description provided for @appLogs_statusCode.
  ///
  /// In zh, this message translates to:
  /// **'状态码'**
  String get appLogs_statusCode;

  /// No description provided for @appLogs_tag.
  ///
  /// In zh, this message translates to:
  /// **'标签'**
  String get appLogs_tag;

  /// No description provided for @appLogs_time.
  ///
  /// In zh, this message translates to:
  /// **'时间'**
  String get appLogs_time;

  /// No description provided for @appLogs_title.
  ///
  /// In zh, this message translates to:
  /// **'应用日志'**
  String get appLogs_title;

  /// No description provided for @appLogs_type.
  ///
  /// In zh, this message translates to:
  /// **'类型'**
  String get appLogs_type;

  /// No description provided for @appLogs_user.
  ///
  /// In zh, this message translates to:
  /// **'用户'**
  String get appLogs_user;

  /// No description provided for @appLogs_userLogin.
  ///
  /// In zh, this message translates to:
  /// **'用户登录'**
  String get appLogs_userLogin;

  /// No description provided for @appLogs_version.
  ///
  /// In zh, this message translates to:
  /// **'版本'**
  String get appLogs_version;

  /// No description provided for @debugTools_cfLogs.
  ///
  /// In zh, this message translates to:
  /// **'CF 验证日志'**
  String get debugTools_cfLogs;

  /// No description provided for @debugTools_cfLogsCleared.
  ///
  /// In zh, this message translates to:
  /// **'CF 日志已清除'**
  String get debugTools_cfLogsCleared;

  /// No description provided for @debugTools_cfLogsDesc.
  ///
  /// In zh, this message translates to:
  /// **'查看 Cloudflare 验证详情'**
  String get debugTools_cfLogsDesc;

  /// No description provided for @debugTools_cfLogsTitle.
  ///
  /// In zh, this message translates to:
  /// **'CF 验证日志'**
  String get debugTools_cfLogsTitle;

  /// No description provided for @debugTools_clearCfLogs.
  ///
  /// In zh, this message translates to:
  /// **'清除 CF 日志'**
  String get debugTools_clearCfLogs;

  /// No description provided for @debugTools_clearCfLogsConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定要清除所有 CF 验证日志吗？'**
  String get debugTools_clearCfLogsConfirm;

  /// No description provided for @debugTools_clearCfLogsTitle.
  ///
  /// In zh, this message translates to:
  /// **'清除 CF 日志'**
  String get debugTools_clearCfLogsTitle;

  /// No description provided for @debugTools_clearLogs.
  ///
  /// In zh, this message translates to:
  /// **'清除日志'**
  String get debugTools_clearLogs;

  /// No description provided for @debugTools_clearLogsConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定要清除所有日志吗？'**
  String get debugTools_clearLogsConfirm;

  /// No description provided for @debugTools_clearLogsTitle.
  ///
  /// In zh, this message translates to:
  /// **'清除日志'**
  String get debugTools_clearLogsTitle;

  /// No description provided for @debugTools_debugLogs.
  ///
  /// In zh, this message translates to:
  /// **'调试日志'**
  String get debugTools_debugLogs;

  /// No description provided for @debugTools_exportCfLogs.
  ///
  /// In zh, this message translates to:
  /// **'导出 CF 日志'**
  String get debugTools_exportCfLogs;

  /// No description provided for @debugTools_logsCleared.
  ///
  /// In zh, this message translates to:
  /// **'日志已清除'**
  String get debugTools_logsCleared;

  /// No description provided for @debugTools_noCfLogs.
  ///
  /// In zh, this message translates to:
  /// **'暂无 CF 验证日志'**
  String get debugTools_noCfLogs;

  /// No description provided for @debugTools_noCfLogsHint.
  ///
  /// In zh, this message translates to:
  /// **'触发 CF 验证后会产生日志'**
  String get debugTools_noCfLogsHint;

  /// No description provided for @debugTools_noCfLogsToShare.
  ///
  /// In zh, this message translates to:
  /// **'暂无 CF 日志可分享'**
  String get debugTools_noCfLogsToShare;

  /// No description provided for @debugTools_noLogs.
  ///
  /// In zh, this message translates to:
  /// **'暂无日志'**
  String get debugTools_noLogs;

  /// No description provided for @debugTools_noLogsHint.
  ///
  /// In zh, this message translates to:
  /// **'启用 DOH 并发起请求后会产生日志'**
  String get debugTools_noLogsHint;

  /// No description provided for @debugTools_noLogsToShare.
  ///
  /// In zh, this message translates to:
  /// **'暂无日志可分享'**
  String get debugTools_noLogsToShare;

  /// No description provided for @debugTools_shareLogs.
  ///
  /// In zh, this message translates to:
  /// **'分享日志'**
  String get debugTools_shareLogs;

  /// No description provided for @debugTools_viewLogs.
  ///
  /// In zh, this message translates to:
  /// **'查看日志'**
  String get debugTools_viewLogs;

  /// No description provided for @dohDetail_addServer.
  ///
  /// In zh, this message translates to:
  /// **'添加服务器'**
  String get dohDetail_addServer;

  /// No description provided for @dohDetail_bootstrapIpHelper.
  ///
  /// In zh, this message translates to:
  /// **'直接用 IP 连接 DoH 服务器，绕过 DNS 解析'**
  String get dohDetail_bootstrapIpHelper;

  /// No description provided for @dohDetail_bootstrapIpHint.
  ///
  /// In zh, this message translates to:
  /// **'用逗号分隔，如 1.1.1.1, 1.0.0.1'**
  String get dohDetail_bootstrapIpHint;

  /// No description provided for @dohDetail_bootstrapIpOptional.
  ///
  /// In zh, this message translates to:
  /// **'Bootstrap IP（可选）'**
  String get dohDetail_bootstrapIpOptional;

  /// No description provided for @dohDetail_clearCache.
  ///
  /// In zh, this message translates to:
  /// **'清空缓存'**
  String get dohDetail_clearCache;

  /// No description provided for @dohDetail_clearDnsCacheFailed.
  ///
  /// In zh, this message translates to:
  /// **'清空 DNS 缓存失败: {error}'**
  String dohDetail_clearDnsCacheFailed(String error);

  /// No description provided for @dohDetail_copyAddress.
  ///
  /// In zh, this message translates to:
  /// **'复制地址'**
  String get dohDetail_copyAddress;

  /// No description provided for @dohDetail_deleteServer.
  ///
  /// In zh, this message translates to:
  /// **'删除服务器'**
  String get dohDetail_deleteServer;

  /// No description provided for @dohDetail_deleteServerConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定要删除 \"{name}\" 吗？'**
  String dohDetail_deleteServerConfirm(String name);

  /// No description provided for @dohDetail_dnsCacheCleared.
  ///
  /// In zh, this message translates to:
  /// **'DNS 缓存已清空'**
  String get dohDetail_dnsCacheCleared;

  /// No description provided for @dohDetail_dnsCacheDesc.
  ///
  /// In zh, this message translates to:
  /// **'当前已缓存 {count} 个域名。代理模式和查询模式共用缓存，TTL 临近到期会后台刷新。'**
  String dohDetail_dnsCacheDesc(int count);

  /// No description provided for @dohDetail_dnsCacheRefreshed.
  ///
  /// In zh, this message translates to:
  /// **'DNS 缓存已强制刷新（{count} 个域名）'**
  String dohDetail_dnsCacheRefreshed(int count);

  /// No description provided for @dohDetail_dnsCacheRefreshedSimple.
  ///
  /// In zh, this message translates to:
  /// **'DNS 缓存已强制刷新'**
  String get dohDetail_dnsCacheRefreshedSimple;

  /// No description provided for @dohDetail_dnsCacheSection.
  ///
  /// In zh, this message translates to:
  /// **'DNS 缓存'**
  String get dohDetail_dnsCacheSection;

  /// No description provided for @dohDetail_dohAddress.
  ///
  /// In zh, this message translates to:
  /// **'DoH 地址'**
  String get dohDetail_dohAddress;

  /// No description provided for @dohDetail_dohAddressCopied.
  ///
  /// In zh, this message translates to:
  /// **'已复制 DoH 地址'**
  String get dohDetail_dohAddressCopied;

  /// No description provided for @dohDetail_echSameAsDnsDesc.
  ///
  /// In zh, this message translates to:
  /// **'使用 DNS 解析服务器查询 ECH 配置'**
  String get dohDetail_echSameAsDnsDesc;

  /// No description provided for @dohDetail_echServer.
  ///
  /// In zh, this message translates to:
  /// **'ECH 服务器'**
  String get dohDetail_echServer;

  /// No description provided for @dohDetail_editServer.
  ///
  /// In zh, this message translates to:
  /// **'编辑服务器'**
  String get dohDetail_editServer;

  /// No description provided for @dohDetail_exampleDns.
  ///
  /// In zh, this message translates to:
  /// **'例如：My DNS'**
  String get dohDetail_exampleDns;

  /// No description provided for @dohDetail_forceRefresh.
  ///
  /// In zh, this message translates to:
  /// **'强制刷新'**
  String get dohDetail_forceRefresh;

  /// No description provided for @dohDetail_gatewayDisabledDesc.
  ///
  /// In zh, this message translates to:
  /// **'已关闭，使用 MITM 双重 TLS'**
  String get dohDetail_gatewayDisabledDesc;

  /// No description provided for @dohDetail_gatewayEnabledDesc.
  ///
  /// In zh, this message translates to:
  /// **'单次 TLS，通过反向代理转发'**
  String get dohDetail_gatewayEnabledDesc;

  /// No description provided for @dohDetail_gatewayMode.
  ///
  /// In zh, this message translates to:
  /// **'Gateway 模式'**
  String get dohDetail_gatewayMode;

  /// No description provided for @dohDetail_ipAddress.
  ///
  /// In zh, this message translates to:
  /// **'IP 地址'**
  String get dohDetail_ipAddress;

  /// No description provided for @dohDetail_ipv6Prefer.
  ///
  /// In zh, this message translates to:
  /// **'IPv6 优先'**
  String get dohDetail_ipv6Prefer;

  /// No description provided for @dohDetail_ipv6PreferDesc.
  ///
  /// In zh, this message translates to:
  /// **'优先尝试 IPv6，失败自动回落 IPv4'**
  String get dohDetail_ipv6PreferDesc;

  /// No description provided for @dohDetail_localDnsCache.
  ///
  /// In zh, this message translates to:
  /// **'共享本地 DNS 缓存'**
  String get dohDetail_localDnsCache;

  /// No description provided for @dohDetail_noServers.
  ///
  /// In zh, this message translates to:
  /// **'暂无服务器'**
  String get dohDetail_noServers;

  /// No description provided for @dohDetail_processing.
  ///
  /// In zh, this message translates to:
  /// **'处理中'**
  String get dohDetail_processing;

  /// No description provided for @dohDetail_refreshDnsCacheFailed.
  ///
  /// In zh, this message translates to:
  /// **'强制刷新 DNS 缓存失败: {error}'**
  String dohDetail_refreshDnsCacheFailed(String error);

  /// No description provided for @dohDetail_sameAsDns.
  ///
  /// In zh, this message translates to:
  /// **'与 DNS 相同'**
  String get dohDetail_sameAsDns;

  /// No description provided for @dohDetail_selectEchServer.
  ///
  /// In zh, this message translates to:
  /// **'选择 ECH 服务器'**
  String get dohDetail_selectEchServer;

  /// No description provided for @dohDetail_serverIp.
  ///
  /// In zh, this message translates to:
  /// **'服务端 IP'**
  String get dohDetail_serverIp;

  /// No description provided for @dohDetail_serverIpHint.
  ///
  /// In zh, this message translates to:
  /// **'指定连接 IP，跳过 DNS 解析'**
  String get dohDetail_serverIpHint;

  /// No description provided for @dohDetail_servers.
  ///
  /// In zh, this message translates to:
  /// **'服务器'**
  String get dohDetail_servers;

  /// No description provided for @dohDetail_testAllSpeed.
  ///
  /// In zh, this message translates to:
  /// **'全部测速'**
  String get dohDetail_testAllSpeed;

  /// No description provided for @dohDetail_testSpeed.
  ///
  /// In zh, this message translates to:
  /// **'测速'**
  String get dohDetail_testSpeed;

  /// No description provided for @dohDetail_testingSpeed.
  ///
  /// In zh, this message translates to:
  /// **'测速中'**
  String get dohDetail_testingSpeed;

  /// No description provided for @dohDetail_title.
  ///
  /// In zh, this message translates to:
  /// **'DOH 详细设置'**
  String get dohDetail_title;

  /// No description provided for @dohDetail_urlMustHttps.
  ///
  /// In zh, this message translates to:
  /// **'地址必须以 https:// 开头'**
  String get dohDetail_urlMustHttps;

  /// No description provided for @dohSettings_certAllDone.
  ///
  /// In zh, this message translates to:
  /// **'已完成所有步骤'**
  String get dohSettings_certAllDone;

  /// No description provided for @dohSettings_certDialogDesc.
  ///
  /// In zh, this message translates to:
  /// **'HTTPS 拦截需要安装并信任 CA 证书，每台设备生成唯一证书'**
  String get dohSettings_certDialogDesc;

  /// No description provided for @dohSettings_certDialogTitle.
  ///
  /// In zh, this message translates to:
  /// **'CA 证书安装'**
  String get dohSettings_certDialogTitle;

  /// No description provided for @dohSettings_certDownloadFailed.
  ///
  /// In zh, this message translates to:
  /// **'描述文件下载失败'**
  String get dohSettings_certDownloadFailed;

  /// No description provided for @dohSettings_certDownloadHint.
  ///
  /// In zh, this message translates to:
  /// **'点击下方按钮，Safari 会弹出下载提示，请点击\"允许\"。'**
  String get dohSettings_certDownloadHint;

  /// No description provided for @dohSettings_certDownloadProfile.
  ///
  /// In zh, this message translates to:
  /// **'下载描述文件'**
  String get dohSettings_certDownloadProfile;

  /// No description provided for @dohSettings_certInstall.
  ///
  /// In zh, this message translates to:
  /// **'安装'**
  String get dohSettings_certInstall;

  /// No description provided for @dohSettings_certInstallHint.
  ///
  /// In zh, this message translates to:
  /// **'HTTPS 拦截需要安装并信任证书'**
  String get dohSettings_certInstallHint;

  /// No description provided for @dohSettings_certInstallProfileHint.
  ///
  /// In zh, this message translates to:
  /// **'前往 设置 → 通用 → VPN与设备管理，找到 DOH Proxy CA 描述文件并安装。'**
  String get dohSettings_certInstallProfileHint;

  /// No description provided for @dohSettings_certInstalled.
  ///
  /// In zh, this message translates to:
  /// **'CA 证书已安装'**
  String get dohSettings_certInstalled;

  /// No description provided for @dohSettings_certInstalledNext.
  ///
  /// In zh, this message translates to:
  /// **'已安装，下一步'**
  String get dohSettings_certInstalledNext;

  /// No description provided for @dohSettings_certOpenSettings.
  ///
  /// In zh, this message translates to:
  /// **'打开设置'**
  String get dohSettings_certOpenSettings;

  /// No description provided for @dohSettings_certPreparing.
  ///
  /// In zh, this message translates to:
  /// **'正在准备...'**
  String get dohSettings_certPreparing;

  /// No description provided for @dohSettings_certRegenerate.
  ///
  /// In zh, this message translates to:
  /// **'重新生成证书'**
  String get dohSettings_certRegenerate;

  /// No description provided for @dohSettings_certRegenerateFailed.
  ///
  /// In zh, this message translates to:
  /// **'证书重新生成失败'**
  String get dohSettings_certRegenerateFailed;

  /// No description provided for @dohSettings_certRegenerated.
  ///
  /// In zh, this message translates to:
  /// **'新证书已生成'**
  String get dohSettings_certRegenerated;

  /// No description provided for @dohSettings_certReinstall.
  ///
  /// In zh, this message translates to:
  /// **'重新安装'**
  String get dohSettings_certReinstall;

  /// No description provided for @dohSettings_certReinstallHint.
  ///
  /// In zh, this message translates to:
  /// **'点击可重新安装或更换证书'**
  String get dohSettings_certReinstallHint;

  /// No description provided for @dohSettings_certRequired.
  ///
  /// In zh, this message translates to:
  /// **'需要安装 CA 证书'**
  String get dohSettings_certRequired;

  /// No description provided for @dohSettings_certStepDownload.
  ///
  /// In zh, this message translates to:
  /// **'下载描述文件'**
  String get dohSettings_certStepDownload;

  /// No description provided for @dohSettings_certStepInstall.
  ///
  /// In zh, this message translates to:
  /// **'安装描述文件'**
  String get dohSettings_certStepInstall;

  /// No description provided for @dohSettings_certStepTrust.
  ///
  /// In zh, this message translates to:
  /// **'信任证书'**
  String get dohSettings_certStepTrust;

  /// No description provided for @dohSettings_certTrustHint.
  ///
  /// In zh, this message translates to:
  /// **'前往 设置 → 通用 → 关于本机 → 证书信任设置，开启 DOH Proxy CA 的信任开关。'**
  String get dohSettings_certTrustHint;

  /// No description provided for @dohSettings_disabledDesc.
  ///
  /// In zh, this message translates to:
  /// **'使用系统默认 DNS'**
  String get dohSettings_disabledDesc;

  /// No description provided for @dohSettings_enabledDesc.
  ///
  /// In zh, this message translates to:
  /// **'已启用加密 DNS 解析'**
  String get dohSettings_enabledDesc;

  /// No description provided for @dohSettings_errorCopied.
  ///
  /// In zh, this message translates to:
  /// **'已复制错误信息'**
  String get dohSettings_errorCopied;

  /// No description provided for @dohSettings_moreSettings.
  ///
  /// In zh, this message translates to:
  /// **'更多设置'**
  String get dohSettings_moreSettings;

  /// No description provided for @dohSettings_moreSettingsDesc.
  ///
  /// In zh, this message translates to:
  /// **'服务器、IPv6、ECH 等'**
  String get dohSettings_moreSettingsDesc;

  /// No description provided for @dohSettings_perDeviceCert.
  ///
  /// In zh, this message translates to:
  /// **'设备独有证书'**
  String get dohSettings_perDeviceCert;

  /// No description provided for @dohSettings_perDeviceCertDisabledDesc.
  ///
  /// In zh, this message translates to:
  /// **'启用后每台设备生成独立的 CA 证书，更安全'**
  String get dohSettings_perDeviceCertDisabledDesc;

  /// No description provided for @dohSettings_perDeviceCertEnabledDesc.
  ///
  /// In zh, this message translates to:
  /// **'已启用，每台设备使用独立 CA 证书'**
  String get dohSettings_perDeviceCertEnabledDesc;

  /// No description provided for @dohSettings_port.
  ///
  /// In zh, this message translates to:
  /// **'端口 {port}'**
  String dohSettings_port(int port);

  /// No description provided for @dohSettings_proxyNotStarted.
  ///
  /// In zh, this message translates to:
  /// **'代理未启动'**
  String get dohSettings_proxyNotStarted;

  /// No description provided for @dohSettings_proxyRunning.
  ///
  /// In zh, this message translates to:
  /// **'代理运行中'**
  String get dohSettings_proxyRunning;

  /// No description provided for @dohSettings_proxyStartFailed.
  ///
  /// In zh, this message translates to:
  /// **'代理启动失败，DoH/ECH 无法生效'**
  String get dohSettings_proxyStartFailed;

  /// No description provided for @dohSettings_restartProxy.
  ///
  /// In zh, this message translates to:
  /// **'重启代理'**
  String get dohSettings_restartProxy;

  /// No description provided for @dohSettings_restarting.
  ///
  /// In zh, this message translates to:
  /// **'正在重启...'**
  String get dohSettings_restarting;

  /// No description provided for @dohSettings_starting.
  ///
  /// In zh, this message translates to:
  /// **'正在启动...'**
  String get dohSettings_starting;

  /// No description provided for @dohSettings_suppressedByVpn.
  ///
  /// In zh, this message translates to:
  /// **'已被 VPN 自动关闭，VPN 断开后将自动恢复'**
  String get dohSettings_suppressedByVpn;

  /// No description provided for @doh_cannotConnect.
  ///
  /// In zh, this message translates to:
  /// **'无法连接到 DOH 服务'**
  String get doh_cannotConnect;

  /// No description provided for @doh_executableNotFound.
  ///
  /// In zh, this message translates to:
  /// **'找不到代理可执行文件'**
  String get doh_executableNotFound;

  /// No description provided for @doh_invalidHttpResponse.
  ///
  /// In zh, this message translates to:
  /// **'无效的 HTTP 响应'**
  String get doh_invalidHttpResponse;

  /// No description provided for @doh_queryFailed.
  ///
  /// In zh, this message translates to:
  /// **'DOH 查询失败'**
  String get doh_queryFailed;

  /// No description provided for @doh_serverAlibaba.
  ///
  /// In zh, this message translates to:
  /// **'阿里 DNS'**
  String get doh_serverAlibaba;

  /// No description provided for @doh_serverError.
  ///
  /// In zh, this message translates to:
  /// **'DOH 服务器返回错误: {statusLine}'**
  String doh_serverError(String statusLine);

  /// No description provided for @doh_serverTencent.
  ///
  /// In zh, this message translates to:
  /// **'腾讯 DNS'**
  String get doh_serverTencent;

  /// No description provided for @doh_startTimeout.
  ///
  /// In zh, this message translates to:
  /// **'代理启动超时（5秒内未响应）'**
  String get doh_startTimeout;

  /// No description provided for @doh_unknownReason.
  ///
  /// In zh, this message translates to:
  /// **'未知原因'**
  String get doh_unknownReason;

  /// No description provided for @codeBlock_chart.
  ///
  /// In zh, this message translates to:
  /// **'图表'**
  String get codeBlock_chart;

  /// No description provided for @codeBlock_chartLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'图表加载失败'**
  String get codeBlock_chartLoadFailed;

  /// No description provided for @codeBlock_code.
  ///
  /// In zh, this message translates to:
  /// **'代码'**
  String get codeBlock_code;

  /// No description provided for @codeBlock_renderFailed.
  ///
  /// In zh, this message translates to:
  /// **'代码块渲染失败: {error}'**
  String codeBlock_renderFailed(String error);

  /// No description provided for @draft_topicTitle.
  ///
  /// In zh, this message translates to:
  /// **'话题 #{id}'**
  String draft_topicTitle(String id);

  /// No description provided for @draft_untitled.
  ///
  /// In zh, this message translates to:
  /// **'无标题'**
  String get draft_untitled;

  /// No description provided for @drafts_deleteContent.
  ///
  /// In zh, this message translates to:
  /// **'确定要删除这个草稿吗？'**
  String get drafts_deleteContent;

  /// No description provided for @drafts_deleteDraft.
  ///
  /// In zh, this message translates to:
  /// **'删除草稿'**
  String get drafts_deleteDraft;

  /// No description provided for @drafts_deleteFailed.
  ///
  /// In zh, this message translates to:
  /// **'删除失败: {error}'**
  String drafts_deleteFailed(String error);

  /// No description provided for @drafts_deleteTitle.
  ///
  /// In zh, this message translates to:
  /// **'删除草稿'**
  String get drafts_deleteTitle;

  /// No description provided for @drafts_deleted.
  ///
  /// In zh, this message translates to:
  /// **'草稿已删除'**
  String get drafts_deleted;

  /// No description provided for @drafts_draft.
  ///
  /// In zh, this message translates to:
  /// **'草稿'**
  String get drafts_draft;

  /// No description provided for @drafts_empty.
  ///
  /// In zh, this message translates to:
  /// **'暂无草稿'**
  String get drafts_empty;

  /// No description provided for @drafts_newTopic.
  ///
  /// In zh, this message translates to:
  /// **'新话题'**
  String get drafts_newTopic;

  /// No description provided for @drafts_pmIncomplete.
  ///
  /// In zh, this message translates to:
  /// **'私信草稿数据不完整'**
  String get drafts_pmIncomplete;

  /// No description provided for @drafts_privateMessage.
  ///
  /// In zh, this message translates to:
  /// **'私信'**
  String get drafts_privateMessage;

  /// No description provided for @drafts_replyToPost.
  ///
  /// In zh, this message translates to:
  /// **'回复 #{number}'**
  String drafts_replyToPost(int number);

  /// No description provided for @drafts_title.
  ///
  /// In zh, this message translates to:
  /// **'我的草稿'**
  String get drafts_title;

  /// No description provided for @editor_hintText.
  ///
  /// In zh, this message translates to:
  /// **'说点什么吧... (支持 Markdown)'**
  String get editor_hintText;

  /// No description provided for @editor_noContent.
  ///
  /// In zh, this message translates to:
  /// **'（无内容）'**
  String get editor_noContent;

  /// No description provided for @link_insertTitle.
  ///
  /// In zh, this message translates to:
  /// **'插入链接'**
  String get link_insertTitle;

  /// No description provided for @link_textHint.
  ///
  /// In zh, this message translates to:
  /// **'显示的文字'**
  String get link_textHint;

  /// No description provided for @link_textLabel.
  ///
  /// In zh, this message translates to:
  /// **'链接文本'**
  String get link_textLabel;

  /// No description provided for @link_textRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入链接文本'**
  String get link_textRequired;

  /// No description provided for @link_urlRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入 URL'**
  String get link_urlRequired;

  /// No description provided for @mention_group.
  ///
  /// In zh, this message translates to:
  /// **'群组'**
  String get mention_group;

  /// No description provided for @mention_noUserFound.
  ///
  /// In zh, this message translates to:
  /// **'未找到匹配用户'**
  String get mention_noUserFound;

  /// No description provided for @mention_searchHint.
  ///
  /// In zh, this message translates to:
  /// **'输入用户名搜索'**
  String get mention_searchHint;

  /// No description provided for @template_empty.
  ///
  /// In zh, this message translates to:
  /// **'暂无可用模板'**
  String get template_empty;

  /// No description provided for @template_insertTitle.
  ///
  /// In zh, this message translates to:
  /// **'插入模板'**
  String get template_insertTitle;

  /// No description provided for @template_loadError.
  ///
  /// In zh, this message translates to:
  /// **'加载模板失败'**
  String get template_loadError;

  /// No description provided for @template_searchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索模板…'**
  String get template_searchHint;

  /// No description provided for @template_tooltip.
  ///
  /// In zh, this message translates to:
  /// **'模板'**
  String get template_tooltip;

  /// No description provided for @toolbar_attachFileTooltip.
  ///
  /// In zh, this message translates to:
  /// **'上传附件'**
  String get toolbar_attachFileTooltip;

  /// No description provided for @toolbar_boldPlaceholder.
  ///
  /// In zh, this message translates to:
  /// **'粗体文本'**
  String get toolbar_boldPlaceholder;

  /// No description provided for @toolbar_codePlaceholder.
  ///
  /// In zh, this message translates to:
  /// **'在此处键入或粘贴代码'**
  String get toolbar_codePlaceholder;

  /// No description provided for @toolbar_gridMinImages.
  ///
  /// In zh, this message translates to:
  /// **'需要至少 2 张图片才能创建网格'**
  String get toolbar_gridMinImages;

  /// No description provided for @toolbar_gridNeedConsecutive.
  ///
  /// In zh, this message translates to:
  /// **'需要至少 2 张连续的图片才能创建网格'**
  String get toolbar_gridNeedConsecutive;

  /// No description provided for @toolbar_h1.
  ///
  /// In zh, this message translates to:
  /// **'H1 - 一级标题'**
  String get toolbar_h1;

  /// No description provided for @toolbar_h2.
  ///
  /// In zh, this message translates to:
  /// **'H2 - 二级标题'**
  String get toolbar_h2;

  /// No description provided for @toolbar_h3.
  ///
  /// In zh, this message translates to:
  /// **'H3 - 三级标题'**
  String get toolbar_h3;

  /// No description provided for @toolbar_h4.
  ///
  /// In zh, this message translates to:
  /// **'H4 - 四级标题'**
  String get toolbar_h4;

  /// No description provided for @toolbar_h5.
  ///
  /// In zh, this message translates to:
  /// **'H5 - 五级标题'**
  String get toolbar_h5;

  /// No description provided for @toolbar_imageGridTooltip.
  ///
  /// In zh, this message translates to:
  /// **'图片网格'**
  String get toolbar_imageGridTooltip;

  /// No description provided for @toolbar_imagesAlreadyInGrid.
  ///
  /// In zh, this message translates to:
  /// **'这些图片已经在网格中了'**
  String get toolbar_imagesAlreadyInGrid;

  /// No description provided for @toolbar_italicPlaceholder.
  ///
  /// In zh, this message translates to:
  /// **'斜体文本'**
  String get toolbar_italicPlaceholder;

  /// No description provided for @toolbar_mixOptimize.
  ///
  /// In zh, this message translates to:
  /// **'混排优化'**
  String get toolbar_mixOptimize;

  /// No description provided for @toolbar_quotePlaceholder.
  ///
  /// In zh, this message translates to:
  /// **'引用文本'**
  String get toolbar_quotePlaceholder;

  /// No description provided for @toolbar_spoilerPlaceholder.
  ///
  /// In zh, this message translates to:
  /// **'剧透内容'**
  String get toolbar_spoilerPlaceholder;

  /// No description provided for @toolbar_spoilerTooltip.
  ///
  /// In zh, this message translates to:
  /// **'剧透'**
  String get toolbar_spoilerTooltip;

  /// No description provided for @toolbar_strikethroughPlaceholder.
  ///
  /// In zh, this message translates to:
  /// **'删除线文本'**
  String get toolbar_strikethroughPlaceholder;

  /// No description provided for @emoji_activities.
  ///
  /// In zh, this message translates to:
  /// **'活动'**
  String get emoji_activities;

  /// No description provided for @emoji_animals.
  ///
  /// In zh, this message translates to:
  /// **'动物'**
  String get emoji_animals;

  /// No description provided for @emoji_flags.
  ///
  /// In zh, this message translates to:
  /// **'旗帜'**
  String get emoji_flags;

  /// No description provided for @emoji_food.
  ///
  /// In zh, this message translates to:
  /// **'食物'**
  String get emoji_food;

  /// No description provided for @emoji_loadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载表情失败'**
  String get emoji_loadFailed;

  /// No description provided for @emoji_notFound.
  ///
  /// In zh, this message translates to:
  /// **'没有找到表情'**
  String get emoji_notFound;

  /// No description provided for @emoji_objects.
  ///
  /// In zh, this message translates to:
  /// **'物体'**
  String get emoji_objects;

  /// No description provided for @emoji_people.
  ///
  /// In zh, this message translates to:
  /// **'人物'**
  String get emoji_people;

  /// No description provided for @emoji_searchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索表情...'**
  String get emoji_searchHint;

  /// No description provided for @emoji_searchNotFound.
  ///
  /// In zh, this message translates to:
  /// **'未找到相关表情'**
  String get emoji_searchNotFound;

  /// No description provided for @emoji_searchPrompt.
  ///
  /// In zh, this message translates to:
  /// **'输入关键词搜索表情'**
  String get emoji_searchPrompt;

  /// No description provided for @emoji_searchTooltip.
  ///
  /// In zh, this message translates to:
  /// **'搜索表情'**
  String get emoji_searchTooltip;

  /// No description provided for @emoji_smileys.
  ///
  /// In zh, this message translates to:
  /// **'表情'**
  String get emoji_smileys;

  /// No description provided for @emoji_symbols.
  ///
  /// In zh, this message translates to:
  /// **'符号'**
  String get emoji_symbols;

  /// No description provided for @emoji_tab.
  ///
  /// In zh, this message translates to:
  /// **'表情'**
  String get emoji_tab;

  /// No description provided for @emoji_travel.
  ///
  /// In zh, this message translates to:
  /// **'旅行'**
  String get emoji_travel;

  /// No description provided for @sticker_addFromMarket.
  ///
  /// In zh, this message translates to:
  /// **'从市场添加'**
  String get sticker_addFromMarket;

  /// No description provided for @sticker_addTooltip.
  ///
  /// In zh, this message translates to:
  /// **'添加表情包'**
  String get sticker_addTooltip;

  /// No description provided for @sticker_added.
  ///
  /// In zh, this message translates to:
  /// **'已添加'**
  String get sticker_added;

  /// No description provided for @sticker_emojiCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个表情'**
  String sticker_emojiCount(int count);

  /// No description provided for @sticker_groupEmpty.
  ///
  /// In zh, this message translates to:
  /// **'该分组暂无表情包'**
  String get sticker_groupEmpty;

  /// No description provided for @sticker_loadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载表情包失败'**
  String get sticker_loadFailed;

  /// No description provided for @sticker_marketEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无可用的表情包'**
  String get sticker_marketEmpty;

  /// No description provided for @sticker_marketLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载市场失败'**
  String get sticker_marketLoadFailed;

  /// No description provided for @sticker_marketTitle.
  ///
  /// In zh, this message translates to:
  /// **'表情包市场'**
  String get sticker_marketTitle;

  /// No description provided for @sticker_noStickers.
  ///
  /// In zh, this message translates to:
  /// **'还没有表情包'**
  String get sticker_noStickers;

  /// No description provided for @sticker_tab.
  ///
  /// In zh, this message translates to:
  /// **'表情包'**
  String get sticker_tab;

  /// No description provided for @error_addBookmarkFailed.
  ///
  /// In zh, this message translates to:
  /// **'添加书签失败：响应格式异常'**
  String get error_addBookmarkFailed;

  /// No description provided for @error_avifDecodeNoFrames.
  ///
  /// In zh, this message translates to:
  /// **'AVIF 解码失败：无帧数据'**
  String get error_avifDecodeNoFrames;

  /// No description provided for @error_badRequest.
  ///
  /// In zh, this message translates to:
  /// **'请求错误'**
  String get error_badRequest;

  /// No description provided for @error_badRequestParams.
  ///
  /// In zh, this message translates to:
  /// **'请求参数错误'**
  String get error_badRequestParams;

  /// No description provided for @error_cannotConnectCheckNetwork.
  ///
  /// In zh, this message translates to:
  /// **'无法在规定时间内连接到服务器，请检查网络'**
  String get error_cannotConnectCheckNetwork;

  /// No description provided for @error_certificateError.
  ///
  /// In zh, this message translates to:
  /// **'证书异常'**
  String get error_certificateError;

  /// No description provided for @error_certificateVerifyFailed.
  ///
  /// In zh, this message translates to:
  /// **'服务器证书验证失败，请检查网络环境'**
  String get error_certificateVerifyFailed;

  /// No description provided for @error_connectionTimeout.
  ///
  /// In zh, this message translates to:
  /// **'连接超时'**
  String get error_connectionTimeout;

  /// No description provided for @error_contentDeleted.
  ///
  /// In zh, this message translates to:
  /// **'内容已被删除'**
  String get error_contentDeleted;

  /// No description provided for @error_createTopicFailed.
  ///
  /// In zh, this message translates to:
  /// **'创建话题失败'**
  String get error_createTopicFailed;

  /// No description provided for @error_dataException.
  ///
  /// In zh, this message translates to:
  /// **'数据异常'**
  String get error_dataException;

  /// No description provided for @error_forbidden.
  ///
  /// In zh, this message translates to:
  /// **'没有权限'**
  String get error_forbidden;

  /// No description provided for @error_forbiddenAccess.
  ///
  /// In zh, this message translates to:
  /// **'没有权限访问'**
  String get error_forbiddenAccess;

  /// No description provided for @error_gone.
  ///
  /// In zh, this message translates to:
  /// **'已删除'**
  String get error_gone;

  /// No description provided for @error_imageFormatUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'图片格式不支持或不符合要求'**
  String get error_imageFormatUnsupported;

  /// No description provided for @error_imageTooBig.
  ///
  /// In zh, this message translates to:
  /// **'图片文件过大，请压缩后重试'**
  String get error_imageTooBig;

  /// No description provided for @error_internalServerError.
  ///
  /// In zh, this message translates to:
  /// **'服务器内部错误'**
  String get error_internalServerError;

  /// No description provided for @error_loadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载失败'**
  String get error_loadFailed;

  /// No description provided for @error_networkCheckSettings.
  ///
  /// In zh, this message translates to:
  /// **'网络连接失败，请检查网络设置'**
  String get error_networkCheckSettings;

  /// No description provided for @error_networkRequestFailed.
  ///
  /// In zh, this message translates to:
  /// **'网络请求失败'**
  String get error_networkRequestFailed;

  /// No description provided for @error_networkUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'网络不可用'**
  String get error_networkUnavailable;

  /// No description provided for @error_notFound.
  ///
  /// In zh, this message translates to:
  /// **'内容不存在'**
  String get error_notFound;

  /// No description provided for @error_notFoundOrDeleted.
  ///
  /// In zh, this message translates to:
  /// **'内容不存在或已被删除'**
  String get error_notFoundOrDeleted;

  /// No description provided for @error_notLoggedInNoUsername.
  ///
  /// In zh, this message translates to:
  /// **'未登录或无法获取用户名'**
  String get error_notLoggedInNoUsername;

  /// No description provided for @error_providerDisposed.
  ///
  /// In zh, this message translates to:
  /// **'Provider 已销毁'**
  String get error_providerDisposed;

  /// No description provided for @error_rateLimited.
  ///
  /// In zh, this message translates to:
  /// **'请求过于频繁'**
  String get error_rateLimited;

  /// No description provided for @error_rateLimitedRetryLater.
  ///
  /// In zh, this message translates to:
  /// **'请求过于频繁，请稍后再试'**
  String get error_rateLimitedRetryLater;

  /// No description provided for @error_replyFailed.
  ///
  /// In zh, this message translates to:
  /// **'回复失败'**
  String get error_replyFailed;

  /// No description provided for @error_requestCancelled.
  ///
  /// In zh, this message translates to:
  /// **'请求取消'**
  String get error_requestCancelled;

  /// No description provided for @error_requestCancelledMsg.
  ///
  /// In zh, this message translates to:
  /// **'请求已取消'**
  String get error_requestCancelledMsg;

  /// No description provided for @error_requestFailed.
  ///
  /// In zh, this message translates to:
  /// **'请求失败'**
  String get error_requestFailed;

  /// No description provided for @error_requestFailedWithCode.
  ///
  /// In zh, this message translates to:
  /// **'请求失败 ({statusCode})'**
  String error_requestFailedWithCode(int statusCode);

  /// No description provided for @error_requestTimeoutRetry.
  ///
  /// In zh, this message translates to:
  /// **'请求超时，请稍后重试'**
  String get error_requestTimeoutRetry;

  /// No description provided for @error_requestUnprocessable.
  ///
  /// In zh, this message translates to:
  /// **'请求无法处理'**
  String get error_requestUnprocessable;

  /// No description provided for @error_responseTimeout.
  ///
  /// In zh, this message translates to:
  /// **'响应超时'**
  String get error_responseTimeout;

  /// No description provided for @error_securityChallenge.
  ///
  /// In zh, this message translates to:
  /// **'安全验证'**
  String get error_securityChallenge;

  /// No description provided for @error_sendPMFailed.
  ///
  /// In zh, this message translates to:
  /// **'发送私信失败'**
  String get error_sendPMFailed;

  /// No description provided for @error_serverError.
  ///
  /// In zh, this message translates to:
  /// **'服务器错误'**
  String get error_serverError;

  /// No description provided for @error_serverResponseTooLong.
  ///
  /// In zh, this message translates to:
  /// **'服务器响应时间过长，请稍后重试'**
  String get error_serverResponseTooLong;

  /// No description provided for @error_serverUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'服务器不可用'**
  String get error_serverUnavailable;

  /// No description provided for @error_serviceUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'服务器不可用'**
  String get error_serviceUnavailable;

  /// No description provided for @error_serviceUnavailableRetry.
  ///
  /// In zh, this message translates to:
  /// **'服务器暂时不可用，请稍后重试'**
  String get error_serviceUnavailableRetry;

  /// No description provided for @error_tooManyRequests.
  ///
  /// In zh, this message translates to:
  /// **'请求过于频繁'**
  String get error_tooManyRequests;

  /// No description provided for @error_topicDetailEmpty.
  ///
  /// In zh, this message translates to:
  /// **'话题详情为空'**
  String get error_topicDetailEmpty;

  /// No description provided for @error_unauthorized.
  ///
  /// In zh, this message translates to:
  /// **'未登录'**
  String get error_unauthorized;

  /// No description provided for @error_unauthorizedExpired.
  ///
  /// In zh, this message translates to:
  /// **'未登录或登录已过期'**
  String get error_unauthorizedExpired;

  /// No description provided for @error_unknown.
  ///
  /// In zh, this message translates to:
  /// **'未知错误'**
  String get error_unknown;

  /// No description provided for @error_unknownResponseFormat.
  ///
  /// In zh, this message translates to:
  /// **'未知响应格式'**
  String get error_unknownResponseFormat;

  /// No description provided for @error_unprocessable.
  ///
  /// In zh, this message translates to:
  /// **'无法处理'**
  String get error_unprocessable;

  /// No description provided for @error_unrecognizedDataFormat.
  ///
  /// In zh, this message translates to:
  /// **'服务器返回了无法识别的数据格式'**
  String get error_unrecognizedDataFormat;

  /// No description provided for @error_updatePostFailed.
  ///
  /// In zh, this message translates to:
  /// **'更新帖子失败：响应格式异常'**
  String get error_updatePostFailed;

  /// No description provided for @error_uploadNoUrl.
  ///
  /// In zh, this message translates to:
  /// **'上传响应中未包含 URL'**
  String get error_uploadNoUrl;

  /// No description provided for @browsingHistory_empty.
  ///
  /// In zh, this message translates to:
  /// **'暂无浏览历史'**
  String get browsingHistory_empty;

  /// No description provided for @browsingHistory_emptySearchHint.
  ///
  /// In zh, this message translates to:
  /// **'输入关键词搜索浏览历史'**
  String get browsingHistory_emptySearchHint;

  /// No description provided for @browsingHistory_searchHint.
  ///
  /// In zh, this message translates to:
  /// **'在浏览历史中搜索...'**
  String get browsingHistory_searchHint;

  /// No description provided for @browsingHistory_title.
  ///
  /// In zh, this message translates to:
  /// **'浏览历史'**
  String get browsingHistory_title;

  /// No description provided for @myTopics_empty.
  ///
  /// In zh, this message translates to:
  /// **'暂无话题'**
  String get myTopics_empty;

  /// No description provided for @myTopics_emptySearchHint.
  ///
  /// In zh, this message translates to:
  /// **'输入关键词搜索我的话题'**
  String get myTopics_emptySearchHint;

  /// No description provided for @myTopics_searchHint.
  ///
  /// In zh, this message translates to:
  /// **'在我的话题中搜索...'**
  String get myTopics_searchHint;

  /// No description provided for @myTopics_title.
  ///
  /// In zh, this message translates to:
  /// **'我的话题'**
  String get myTopics_title;

  /// No description provided for @imageEditor_adjust.
  ///
  /// In zh, this message translates to:
  /// **'调整'**
  String get imageEditor_adjust;

  /// No description provided for @imageEditor_applyingChanges.
  ///
  /// In zh, this message translates to:
  /// **'正在应用更改'**
  String get imageEditor_applyingChanges;

  /// No description provided for @imageEditor_arrow.
  ///
  /// In zh, this message translates to:
  /// **'箭头'**
  String get imageEditor_arrow;

  /// No description provided for @imageEditor_arrowBoth.
  ///
  /// In zh, this message translates to:
  /// **'双端箭头'**
  String get imageEditor_arrowBoth;

  /// No description provided for @imageEditor_arrowEnd.
  ///
  /// In zh, this message translates to:
  /// **'终点箭头'**
  String get imageEditor_arrowEnd;

  /// No description provided for @imageEditor_arrowStart.
  ///
  /// In zh, this message translates to:
  /// **'起点箭头'**
  String get imageEditor_arrowStart;

  /// No description provided for @imageEditor_bgMode.
  ///
  /// In zh, this message translates to:
  /// **'背景模式'**
  String get imageEditor_bgMode;

  /// No description provided for @imageEditor_blur.
  ///
  /// In zh, this message translates to:
  /// **'模糊'**
  String get imageEditor_blur;

  /// No description provided for @imageEditor_brightness.
  ///
  /// In zh, this message translates to:
  /// **'亮度'**
  String get imageEditor_brightness;

  /// No description provided for @imageEditor_brush.
  ///
  /// In zh, this message translates to:
  /// **'画笔'**
  String get imageEditor_brush;

  /// No description provided for @imageEditor_changeOpacity.
  ///
  /// In zh, this message translates to:
  /// **'调整透明度'**
  String get imageEditor_changeOpacity;

  /// No description provided for @imageEditor_circle.
  ///
  /// In zh, this message translates to:
  /// **'圆形'**
  String get imageEditor_circle;

  /// No description provided for @imageEditor_closeWarningMessage.
  ///
  /// In zh, this message translates to:
  /// **'确定要关闭图片编辑器吗？你的更改将不会被保存。'**
  String get imageEditor_closeWarningMessage;

  /// No description provided for @imageEditor_closeWarningTitle.
  ///
  /// In zh, this message translates to:
  /// **'关闭图片编辑器？'**
  String get imageEditor_closeWarningTitle;

  /// No description provided for @imageEditor_color.
  ///
  /// In zh, this message translates to:
  /// **'颜色'**
  String get imageEditor_color;

  /// No description provided for @imageEditor_contrast.
  ///
  /// In zh, this message translates to:
  /// **'对比度'**
  String get imageEditor_contrast;

  /// No description provided for @imageEditor_cropRotate.
  ///
  /// In zh, this message translates to:
  /// **'裁剪/旋转'**
  String get imageEditor_cropRotate;

  /// No description provided for @imageEditor_dashDotLine.
  ///
  /// In zh, this message translates to:
  /// **'点划线'**
  String get imageEditor_dashDotLine;

  /// No description provided for @imageEditor_dashLine.
  ///
  /// In zh, this message translates to:
  /// **'虚线'**
  String get imageEditor_dashLine;

  /// No description provided for @imageEditor_emoji.
  ///
  /// In zh, this message translates to:
  /// **'表情'**
  String get imageEditor_emoji;

  /// No description provided for @imageEditor_emojiActivities.
  ///
  /// In zh, this message translates to:
  /// **'活动'**
  String get imageEditor_emojiActivities;

  /// No description provided for @imageEditor_emojiAnimals.
  ///
  /// In zh, this message translates to:
  /// **'动物与自然'**
  String get imageEditor_emojiAnimals;

  /// No description provided for @imageEditor_emojiFlags.
  ///
  /// In zh, this message translates to:
  /// **'旗帜'**
  String get imageEditor_emojiFlags;

  /// No description provided for @imageEditor_emojiFood.
  ///
  /// In zh, this message translates to:
  /// **'食物与饮品'**
  String get imageEditor_emojiFood;

  /// No description provided for @imageEditor_emojiObjects.
  ///
  /// In zh, this message translates to:
  /// **'物品'**
  String get imageEditor_emojiObjects;

  /// No description provided for @imageEditor_emojiSmileys.
  ///
  /// In zh, this message translates to:
  /// **'笑脸与人物'**
  String get imageEditor_emojiSmileys;

  /// No description provided for @imageEditor_emojiSymbols.
  ///
  /// In zh, this message translates to:
  /// **'符号'**
  String get imageEditor_emojiSymbols;

  /// No description provided for @imageEditor_emojiTravel.
  ///
  /// In zh, this message translates to:
  /// **'旅行与地点'**
  String get imageEditor_emojiTravel;

  /// No description provided for @imageEditor_eraser.
  ///
  /// In zh, this message translates to:
  /// **'橡皮擦'**
  String get imageEditor_eraser;

  /// No description provided for @imageEditor_exposure.
  ///
  /// In zh, this message translates to:
  /// **'曝光'**
  String get imageEditor_exposure;

  /// No description provided for @imageEditor_fade.
  ///
  /// In zh, this message translates to:
  /// **'褪色'**
  String get imageEditor_fade;

  /// No description provided for @imageEditor_fill.
  ///
  /// In zh, this message translates to:
  /// **'填充'**
  String get imageEditor_fill;

  /// No description provided for @imageEditor_filter.
  ///
  /// In zh, this message translates to:
  /// **'滤镜'**
  String get imageEditor_filter;

  /// No description provided for @imageEditor_flip.
  ///
  /// In zh, this message translates to:
  /// **'翻转'**
  String get imageEditor_flip;

  /// No description provided for @imageEditor_fontSize.
  ///
  /// In zh, this message translates to:
  /// **'字体大小'**
  String get imageEditor_fontSize;

  /// No description provided for @imageEditor_freeStyle.
  ///
  /// In zh, this message translates to:
  /// **'自由绘制'**
  String get imageEditor_freeStyle;

  /// No description provided for @imageEditor_hexagon.
  ///
  /// In zh, this message translates to:
  /// **'六边形'**
  String get imageEditor_hexagon;

  /// No description provided for @imageEditor_hue.
  ///
  /// In zh, this message translates to:
  /// **'色调'**
  String get imageEditor_hue;

  /// No description provided for @imageEditor_initializingEditor.
  ///
  /// In zh, this message translates to:
  /// **'正在初始化编辑器'**
  String get imageEditor_initializingEditor;

  /// No description provided for @imageEditor_inputText.
  ///
  /// In zh, this message translates to:
  /// **'输入文字'**
  String get imageEditor_inputText;

  /// No description provided for @imageEditor_line.
  ///
  /// In zh, this message translates to:
  /// **'直线'**
  String get imageEditor_line;

  /// No description provided for @imageEditor_lineWidth.
  ///
  /// In zh, this message translates to:
  /// **'线条宽度'**
  String get imageEditor_lineWidth;

  /// No description provided for @imageEditor_luminance.
  ///
  /// In zh, this message translates to:
  /// **'明度'**
  String get imageEditor_luminance;

  /// No description provided for @imageEditor_noFilter.
  ///
  /// In zh, this message translates to:
  /// **'无滤镜'**
  String get imageEditor_noFilter;

  /// No description provided for @imageEditor_opacity.
  ///
  /// In zh, this message translates to:
  /// **'透明度'**
  String get imageEditor_opacity;

  /// No description provided for @imageEditor_pixelate.
  ///
  /// In zh, this message translates to:
  /// **'像素化'**
  String get imageEditor_pixelate;

  /// No description provided for @imageEditor_polygon.
  ///
  /// In zh, this message translates to:
  /// **'多边形'**
  String get imageEditor_polygon;

  /// No description provided for @imageEditor_ratio.
  ///
  /// In zh, this message translates to:
  /// **'比例'**
  String get imageEditor_ratio;

  /// No description provided for @imageEditor_rectangle.
  ///
  /// In zh, this message translates to:
  /// **'矩形'**
  String get imageEditor_rectangle;

  /// No description provided for @imageEditor_rotate.
  ///
  /// In zh, this message translates to:
  /// **'旋转'**
  String get imageEditor_rotate;

  /// No description provided for @imageEditor_rotateScale.
  ///
  /// In zh, this message translates to:
  /// **'旋转和缩放'**
  String get imageEditor_rotateScale;

  /// No description provided for @imageEditor_saturation.
  ///
  /// In zh, this message translates to:
  /// **'饱和度'**
  String get imageEditor_saturation;

  /// No description provided for @imageEditor_sharpness.
  ///
  /// In zh, this message translates to:
  /// **'锐度'**
  String get imageEditor_sharpness;

  /// No description provided for @imageEditor_sticker.
  ///
  /// In zh, this message translates to:
  /// **'贴纸'**
  String get imageEditor_sticker;

  /// No description provided for @imageEditor_strokeWidth.
  ///
  /// In zh, this message translates to:
  /// **'线条粗细'**
  String get imageEditor_strokeWidth;

  /// No description provided for @imageEditor_temperature.
  ///
  /// In zh, this message translates to:
  /// **'色温'**
  String get imageEditor_temperature;

  /// No description provided for @imageEditor_text.
  ///
  /// In zh, this message translates to:
  /// **'文字'**
  String get imageEditor_text;

  /// No description provided for @imageEditor_textAlign.
  ///
  /// In zh, this message translates to:
  /// **'文字对齐'**
  String get imageEditor_textAlign;

  /// No description provided for @imageEditor_toggleFill.
  ///
  /// In zh, this message translates to:
  /// **'切换填充'**
  String get imageEditor_toggleFill;

  /// No description provided for @imageEditor_zoom.
  ///
  /// In zh, this message translates to:
  /// **'缩放'**
  String get imageEditor_zoom;

  /// No description provided for @imageFormat_generic.
  ///
  /// In zh, this message translates to:
  /// **'图片'**
  String get imageFormat_generic;

  /// No description provided for @imageFormat_gif.
  ///
  /// In zh, this message translates to:
  /// **'GIF 动图'**
  String get imageFormat_gif;

  /// No description provided for @imageFormat_jpeg.
  ///
  /// In zh, this message translates to:
  /// **'JPEG 图片'**
  String get imageFormat_jpeg;

  /// No description provided for @imageFormat_png.
  ///
  /// In zh, this message translates to:
  /// **'PNG 图片'**
  String get imageFormat_png;

  /// No description provided for @imageFormat_webp.
  ///
  /// In zh, this message translates to:
  /// **'WebP 图片'**
  String get imageFormat_webp;

  /// No description provided for @imageUpload_compressionQuality.
  ///
  /// In zh, this message translates to:
  /// **'压缩质量：'**
  String get imageUpload_compressionQuality;

  /// No description provided for @imageUpload_confirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'上传图片确认'**
  String get imageUpload_confirmTitle;

  /// No description provided for @imageUpload_editImage.
  ///
  /// In zh, this message translates to:
  /// **'编辑图片'**
  String get imageUpload_editImage;

  /// No description provided for @imageUpload_editNotSupported.
  ///
  /// In zh, this message translates to:
  /// **'{format} 暂不支持编辑，否则会丢失动画'**
  String imageUpload_editNotSupported(String format);

  /// No description provided for @imageUpload_editNotSupportedLabel.
  ///
  /// In zh, this message translates to:
  /// **'当前格式不支持编辑'**
  String get imageUpload_editNotSupportedLabel;

  /// No description provided for @imageUpload_estimatedSize.
  ///
  /// In zh, this message translates to:
  /// **'约 {size}'**
  String imageUpload_estimatedSize(String size);

  /// No description provided for @imageUpload_gridLayoutHint.
  ///
  /// In zh, this message translates to:
  /// **'上传后将自动使用 [grid] 网格布局'**
  String get imageUpload_gridLayoutHint;

  /// No description provided for @imageUpload_keepAtLeastOne.
  ///
  /// In zh, this message translates to:
  /// **'至少需要保留一张图片'**
  String get imageUpload_keepAtLeastOne;

  /// No description provided for @imageUpload_keepOriginal.
  ///
  /// In zh, this message translates to:
  /// **'{format} 将保留原图上传，不执行客户端压缩。'**
  String imageUpload_keepOriginal(String format);

  /// No description provided for @imageUpload_multiTitle.
  ///
  /// In zh, this message translates to:
  /// **'上传 {count} 张图片'**
  String imageUpload_multiTitle(int count);

  /// No description provided for @imageUpload_originalSize.
  ///
  /// In zh, this message translates to:
  /// **'原始大小：{size}'**
  String imageUpload_originalSize(String size);

  /// No description provided for @imageUpload_processFailed.
  ///
  /// In zh, this message translates to:
  /// **'处理图片失败: {error}'**
  String imageUpload_processFailed(String error);

  /// No description provided for @imageUpload_totalEstimatedSize.
  ///
  /// In zh, this message translates to:
  /// **'约 {size}'**
  String imageUpload_totalEstimatedSize(String size);

  /// No description provided for @imageUpload_totalOriginalSize.
  ///
  /// In zh, this message translates to:
  /// **'总大小：{size}'**
  String imageUpload_totalOriginalSize(String size);

  /// No description provided for @imageUpload_uploadCount.
  ///
  /// In zh, this message translates to:
  /// **'上传 {count} 张'**
  String imageUpload_uploadCount(int count);

  /// No description provided for @imageViewer_grantPermission.
  ///
  /// In zh, this message translates to:
  /// **'请授予相册访问权限'**
  String get imageViewer_grantPermission;

  /// No description provided for @imageViewer_imageSaved.
  ///
  /// In zh, this message translates to:
  /// **'图片已保存到相册'**
  String get imageViewer_imageSaved;

  /// No description provided for @imageViewer_saveFailed.
  ///
  /// In zh, this message translates to:
  /// **'保存失败: {error}'**
  String imageViewer_saveFailed(String error);

  /// No description provided for @imageViewer_saveFailedRetry.
  ///
  /// In zh, this message translates to:
  /// **'保存失败，请重试'**
  String get imageViewer_saveFailedRetry;

  /// No description provided for @image_copied.
  ///
  /// In zh, this message translates to:
  /// **'图片已复制'**
  String get image_copied;

  /// No description provided for @image_copyFailed.
  ///
  /// In zh, this message translates to:
  /// **'复制图片失败'**
  String get image_copyFailed;

  /// No description provided for @image_copyImage.
  ///
  /// In zh, this message translates to:
  /// **'复制图片'**
  String get image_copyImage;

  /// No description provided for @image_copyLink.
  ///
  /// In zh, this message translates to:
  /// **'复制链接'**
  String get image_copyLink;

  /// No description provided for @image_fetchFailed.
  ///
  /// In zh, this message translates to:
  /// **'获取图片失败'**
  String get image_fetchFailed;

  /// No description provided for @image_viewFull.
  ///
  /// In zh, this message translates to:
  /// **'查看大图'**
  String get image_viewFull;

  /// No description provided for @invite_collapseOptions.
  ///
  /// In zh, this message translates to:
  /// **'收起链接选项'**
  String get invite_collapseOptions;

  /// No description provided for @invite_createFailed.
  ///
  /// In zh, this message translates to:
  /// **'生成邀请链接失败'**
  String get invite_createFailed;

  /// No description provided for @invite_createLink.
  ///
  /// In zh, this message translates to:
  /// **'创建邀请链接'**
  String get invite_createLink;

  /// No description provided for @invite_created.
  ///
  /// In zh, this message translates to:
  /// **'邀请已创建'**
  String get invite_created;

  /// No description provided for @invite_creating.
  ///
  /// In zh, this message translates to:
  /// **'创建中...'**
  String get invite_creating;

  /// No description provided for @invite_description.
  ///
  /// In zh, this message translates to:
  /// **'描述 (可选)'**
  String get invite_description;

  /// No description provided for @invite_expandOptions.
  ///
  /// In zh, this message translates to:
  /// **'编辑链接选项或通过电子邮件发送。'**
  String get invite_expandOptions;

  /// No description provided for @invite_expiryDate.
  ///
  /// In zh, this message translates to:
  /// **'截止 {date}'**
  String invite_expiryDate(String date);

  /// No description provided for @invite_expiryTime.
  ///
  /// In zh, this message translates to:
  /// **'有效截止时间'**
  String get invite_expiryTime;

  /// No description provided for @invite_fixed.
  ///
  /// In zh, this message translates to:
  /// **'固定'**
  String get invite_fixed;

  /// No description provided for @invite_inviteMembers.
  ///
  /// In zh, this message translates to:
  /// **'邀请成员'**
  String get invite_inviteMembers;

  /// No description provided for @invite_latestResult.
  ///
  /// In zh, this message translates to:
  /// **'最新生成结果'**
  String get invite_latestResult;

  /// No description provided for @invite_linkCopied.
  ///
  /// In zh, this message translates to:
  /// **'邀请链接已复制'**
  String get invite_linkCopied;

  /// No description provided for @invite_linkGenerated.
  ///
  /// In zh, this message translates to:
  /// **'邀请链接已生成'**
  String get invite_linkGenerated;

  /// No description provided for @invite_maxRedemptions.
  ///
  /// In zh, this message translates to:
  /// **'最大使用次数'**
  String get invite_maxRedemptions;

  /// No description provided for @invite_never.
  ///
  /// In zh, this message translates to:
  /// **'从不'**
  String get invite_never;

  /// No description provided for @invite_noExpiry.
  ///
  /// In zh, this message translates to:
  /// **'无过期时间'**
  String get invite_noExpiry;

  /// No description provided for @invite_noLinks.
  ///
  /// In zh, this message translates to:
  /// **'暂无生成邀请链接'**
  String get invite_noLinks;

  /// No description provided for @invite_permissionDenied.
  ///
  /// In zh, this message translates to:
  /// **'服务端拒绝了当前账号的邀请权限'**
  String get invite_permissionDenied;

  /// No description provided for @invite_rateLimited.
  ///
  /// In zh, this message translates to:
  /// **'出错了：您执行此操作的次数过多。请等待 {waitText} 后再试。'**
  String invite_rateLimited(String waitText);

  /// No description provided for @invite_restriction.
  ///
  /// In zh, this message translates to:
  /// **'限制为 (可选)'**
  String get invite_restriction;

  /// No description provided for @invite_restrictionHelper.
  ///
  /// In zh, this message translates to:
  /// **'填写邮箱或域名'**
  String get invite_restrictionHelper;

  /// No description provided for @invite_restrictionHint.
  ///
  /// In zh, this message translates to:
  /// **'name@example.com 或者 example.com'**
  String get invite_restrictionHint;

  /// No description provided for @invite_shareSubject.
  ///
  /// In zh, this message translates to:
  /// **'Linux.do 邀请链接'**
  String get invite_shareSubject;

  /// No description provided for @invite_summaryDay1.
  ///
  /// In zh, this message translates to:
  /// **'链接最多可用于 1 个用户，并且将在 1 天后到期。'**
  String get invite_summaryDay1;

  /// No description provided for @invite_summaryExpiry.
  ///
  /// In zh, this message translates to:
  /// **'链接最多可用于 1 个用户，并且将在 {expiry} 后到期。'**
  String invite_summaryExpiry(String expiry);

  /// No description provided for @invite_summaryNever.
  ///
  /// In zh, this message translates to:
  /// **'链接最多可用于 1 个用户，并且永不过期。'**
  String get invite_summaryNever;

  /// No description provided for @invite_title.
  ///
  /// In zh, this message translates to:
  /// **'邀请链接'**
  String get invite_title;

  /// No description provided for @invite_trustLevelTooLow.
  ///
  /// In zh, this message translates to:
  /// **'当前账号尚未达到 L3，无法创建邀请链接'**
  String get invite_trustLevelTooLow;

  /// No description provided for @invite_usableCount.
  ///
  /// In zh, this message translates to:
  /// **'可用 {count} 次'**
  String invite_usableCount(int count);

  /// No description provided for @appLink_alipay.
  ///
  /// In zh, this message translates to:
  /// **'支付宝'**
  String get appLink_alipay;

  /// No description provided for @appLink_amap.
  ///
  /// In zh, this message translates to:
  /// **'高德地图'**
  String get appLink_amap;

  /// No description provided for @appLink_baidu.
  ///
  /// In zh, this message translates to:
  /// **'百度'**
  String get appLink_baidu;

  /// No description provided for @appLink_baiduNetdisk.
  ///
  /// In zh, this message translates to:
  /// **'百度网盘'**
  String get appLink_baiduNetdisk;

  /// No description provided for @appLink_continueVisitConfirm.
  ///
  /// In zh, this message translates to:
  /// **'继续访问{name}？'**
  String appLink_continueVisitConfirm(String name);

  /// No description provided for @appLink_ctrip.
  ///
  /// In zh, this message translates to:
  /// **'携程'**
  String get appLink_ctrip;

  /// No description provided for @appLink_dianping.
  ///
  /// In zh, this message translates to:
  /// **'大众点评'**
  String get appLink_dianping;

  /// No description provided for @appLink_dingtalk.
  ///
  /// In zh, this message translates to:
  /// **'钉钉'**
  String get appLink_dingtalk;

  /// No description provided for @appLink_douban.
  ///
  /// In zh, this message translates to:
  /// **'豆瓣'**
  String get appLink_douban;

  /// No description provided for @appLink_douyin.
  ///
  /// In zh, this message translates to:
  /// **'抖音'**
  String get appLink_douyin;

  /// No description provided for @appLink_eleme.
  ///
  /// In zh, this message translates to:
  /// **'饿了么'**
  String get appLink_eleme;

  /// No description provided for @appLink_email.
  ///
  /// In zh, this message translates to:
  /// **'邮件'**
  String get appLink_email;

  /// No description provided for @appLink_externalApp.
  ///
  /// In zh, this message translates to:
  /// **'外部应用'**
  String get appLink_externalApp;

  /// No description provided for @appLink_fliggy.
  ///
  /// In zh, this message translates to:
  /// **'飞猪'**
  String get appLink_fliggy;

  /// No description provided for @appLink_jd.
  ///
  /// In zh, this message translates to:
  /// **'京东'**
  String get appLink_jd;

  /// No description provided for @appLink_kuaishou.
  ///
  /// In zh, this message translates to:
  /// **'快手'**
  String get appLink_kuaishou;

  /// No description provided for @appLink_map.
  ///
  /// In zh, this message translates to:
  /// **'地图'**
  String get appLink_map;

  /// No description provided for @appLink_meituan.
  ///
  /// In zh, this message translates to:
  /// **'美团'**
  String get appLink_meituan;

  /// No description provided for @appLink_meituanWaimai.
  ///
  /// In zh, this message translates to:
  /// **'美团外卖'**
  String get appLink_meituanWaimai;

  /// No description provided for @appLink_openAppConfirm.
  ///
  /// In zh, this message translates to:
  /// **'此网站想打开{name}应用'**
  String appLink_openAppConfirm(String name);

  /// No description provided for @appLink_phone.
  ///
  /// In zh, this message translates to:
  /// **'电话'**
  String get appLink_phone;

  /// No description provided for @appLink_pinduoduo.
  ///
  /// In zh, this message translates to:
  /// **'拼多多'**
  String get appLink_pinduoduo;

  /// No description provided for @appLink_playStore.
  ///
  /// In zh, this message translates to:
  /// **'Play 商店'**
  String get appLink_playStore;

  /// No description provided for @appLink_qqMap.
  ///
  /// In zh, this message translates to:
  /// **'腾讯地图'**
  String get appLink_qqMap;

  /// No description provided for @appLink_sms.
  ///
  /// In zh, this message translates to:
  /// **'短信'**
  String get appLink_sms;

  /// No description provided for @appLink_suning.
  ///
  /// In zh, this message translates to:
  /// **'苏宁'**
  String get appLink_suning;

  /// No description provided for @appLink_taobao.
  ///
  /// In zh, this message translates to:
  /// **'淘宝'**
  String get appLink_taobao;

  /// No description provided for @appLink_toutiao.
  ///
  /// In zh, this message translates to:
  /// **'今日头条'**
  String get appLink_toutiao;

  /// No description provided for @appLink_weibo.
  ///
  /// In zh, this message translates to:
  /// **'微博'**
  String get appLink_weibo;

  /// No description provided for @appLink_weixin.
  ///
  /// In zh, this message translates to:
  /// **'微信'**
  String get appLink_weixin;

  /// No description provided for @appLink_xiaohongshu.
  ///
  /// In zh, this message translates to:
  /// **'小红书'**
  String get appLink_xiaohongshu;

  /// No description provided for @appLink_zhihu.
  ///
  /// In zh, this message translates to:
  /// **'知乎'**
  String get appLink_zhihu;

  /// No description provided for @externalLink_blocked.
  ///
  /// In zh, this message translates to:
  /// **'链接已被阻止'**
  String get externalLink_blocked;

  /// No description provided for @externalLink_blockedMessage.
  ///
  /// In zh, this message translates to:
  /// **'此链接已被列入黑名单，无法访问'**
  String get externalLink_blockedMessage;

  /// No description provided for @externalLink_contactAdmin.
  ///
  /// In zh, this message translates to:
  /// **'如有疑问，请联系站点管理员'**
  String get externalLink_contactAdmin;

  /// No description provided for @externalLink_leavingMessage.
  ///
  /// In zh, this message translates to:
  /// **'您即将访问外部网站'**
  String get externalLink_leavingMessage;

  /// No description provided for @externalLink_leavingTitle.
  ///
  /// In zh, this message translates to:
  /// **'即将离开'**
  String get externalLink_leavingTitle;

  /// No description provided for @externalLink_securityWarningHint.
  ///
  /// In zh, this message translates to:
  /// **'可能包含推广内容或存在安全隐患，请谨慎访问'**
  String get externalLink_securityWarningHint;

  /// No description provided for @externalLink_securityWarningMessage.
  ///
  /// In zh, this message translates to:
  /// **'此链接被标记为潜在风险链接'**
  String get externalLink_securityWarningMessage;

  /// No description provided for @externalLink_securityWarningTitle.
  ///
  /// In zh, this message translates to:
  /// **'安全警告'**
  String get externalLink_securityWarningTitle;

  /// No description provided for @externalLink_shortLinkMessage.
  ///
  /// In zh, this message translates to:
  /// **'此链接为短链接服务，无法预览真实目标'**
  String get externalLink_shortLinkMessage;

  /// No description provided for @externalLink_shortLinkTitle.
  ///
  /// In zh, this message translates to:
  /// **'短链接提醒'**
  String get externalLink_shortLinkTitle;

  /// No description provided for @externalLink_shortLinkWarning.
  ///
  /// In zh, this message translates to:
  /// **'短链接可能隐藏真实目的地，请确认来源可信'**
  String get externalLink_shortLinkWarning;

  /// No description provided for @iframe_exitInteraction.
  ///
  /// In zh, this message translates to:
  /// **'退出交互'**
  String get iframe_exitInteraction;

  /// No description provided for @onebox_linkPreview.
  ///
  /// In zh, this message translates to:
  /// **'链接预览'**
  String get onebox_linkPreview;

  /// No description provided for @chat_thread.
  ///
  /// In zh, this message translates to:
  /// **'线程'**
  String get chat_thread;

  /// No description provided for @github_commentedOn.
  ///
  /// In zh, this message translates to:
  /// **' 评论于 '**
  String get github_commentedOn;

  /// No description provided for @github_moreFiles.
  ///
  /// In zh, this message translates to:
  /// **'... 还有 {count} 个文件'**
  String github_moreFiles(int count);

  /// No description provided for @github_viewFullCode.
  ///
  /// In zh, this message translates to:
  /// **'点击查看完整代码'**
  String get github_viewFullCode;

  /// No description provided for @metaverse_authFailed.
  ///
  /// In zh, this message translates to:
  /// **'授权失败: {error}'**
  String metaverse_authFailed(String error);

  /// No description provided for @metaverse_cdkAuthSuccess.
  ///
  /// In zh, this message translates to:
  /// **'CDK 授权成功'**
  String get metaverse_cdkAuthSuccess;

  /// No description provided for @metaverse_cdkDesc.
  ///
  /// In zh, this message translates to:
  /// **'连接账户，开启 CDK 权益'**
  String get metaverse_cdkDesc;

  /// No description provided for @metaverse_cdkReauthSuccess.
  ///
  /// In zh, this message translates to:
  /// **'CDK 重新授权成功'**
  String get metaverse_cdkReauthSuccess;

  /// No description provided for @metaverse_cdkService.
  ///
  /// In zh, this message translates to:
  /// **'CDK 服务'**
  String get metaverse_cdkService;

  /// No description provided for @metaverse_comingSoon.
  ///
  /// In zh, this message translates to:
  /// **'更多服务接入中...'**
  String get metaverse_comingSoon;

  /// No description provided for @metaverse_ldcAuthSuccess.
  ///
  /// In zh, this message translates to:
  /// **'LDC 授权成功'**
  String get metaverse_ldcAuthSuccess;

  /// No description provided for @metaverse_ldcDesc.
  ///
  /// In zh, this message translates to:
  /// **'连接账户，开启积分权益'**
  String get metaverse_ldcDesc;

  /// No description provided for @metaverse_ldcReauthSuccess.
  ///
  /// In zh, this message translates to:
  /// **'LDC 重新授权成功'**
  String get metaverse_ldcReauthSuccess;

  /// No description provided for @metaverse_ldcService.
  ///
  /// In zh, this message translates to:
  /// **'LDC 积分服务'**
  String get metaverse_ldcService;

  /// No description provided for @metaverse_myServices.
  ///
  /// In zh, this message translates to:
  /// **'我的服务'**
  String get metaverse_myServices;

  /// No description provided for @metaverse_title.
  ///
  /// In zh, this message translates to:
  /// **'元宇宙'**
  String get metaverse_title;

  /// No description provided for @nav_home.
  ///
  /// In zh, this message translates to:
  /// **'首页'**
  String get nav_home;

  /// No description provided for @nav_mine.
  ///
  /// In zh, this message translates to:
  /// **'我的'**
  String get nav_mine;

  /// No description provided for @toast_authorizationFailed.
  ///
  /// In zh, this message translates to:
  /// **'授权失败: {error}'**
  String toast_authorizationFailed(String error);

  /// No description provided for @toast_credentialCleared.
  ///
  /// In zh, this message translates to:
  /// **'凭证已清除'**
  String get toast_credentialCleared;

  /// No description provided for @toast_credentialIncomplete.
  ///
  /// In zh, this message translates to:
  /// **'请填写完整的凭证信息'**
  String get toast_credentialIncomplete;

  /// No description provided for @toast_credentialSaved.
  ///
  /// In zh, this message translates to:
  /// **'凭证保存成功'**
  String get toast_credentialSaved;

  /// No description provided for @toast_networkDisconnected.
  ///
  /// In zh, this message translates to:
  /// **'网络连接已断开'**
  String get toast_networkDisconnected;

  /// No description provided for @toast_networkRestored.
  ///
  /// In zh, this message translates to:
  /// **'网络已恢复'**
  String get toast_networkRestored;

  /// No description provided for @toast_operationFailedRetry.
  ///
  /// In zh, this message translates to:
  /// **'操作失败，请重试'**
  String get toast_operationFailedRetry;

  /// No description provided for @toast_pressAgainToExit.
  ///
  /// In zh, this message translates to:
  /// **'再按一次返回键退出'**
  String get toast_pressAgainToExit;

  /// No description provided for @toast_rewardError.
  ///
  /// In zh, this message translates to:
  /// **'打赏失败: {error}'**
  String toast_rewardError(String error);

  /// No description provided for @toast_rewardFailed.
  ///
  /// In zh, this message translates to:
  /// **'打赏失败'**
  String get toast_rewardFailed;

  /// No description provided for @toast_rewardNotConfigured.
  ///
  /// In zh, this message translates to:
  /// **'请先配置打赏凭证'**
  String get toast_rewardNotConfigured;

  /// No description provided for @toast_rewardSuccess.
  ///
  /// In zh, this message translates to:
  /// **'打赏成功！'**
  String get toast_rewardSuccess;

  /// No description provided for @advancedSettings_networkAdapter.
  ///
  /// In zh, this message translates to:
  /// **'网络适配器'**
  String get advancedSettings_networkAdapter;

  /// No description provided for @advancedSettings_networkAdapterDesc.
  ///
  /// In zh, this message translates to:
  /// **'管理 Cronet 和备用适配器设置'**
  String get advancedSettings_networkAdapterDesc;

  /// No description provided for @networkAdapter_adapterType.
  ///
  /// In zh, this message translates to:
  /// **'适配器类型'**
  String get networkAdapter_adapterType;

  /// No description provided for @networkAdapter_autoFallback.
  ///
  /// In zh, this message translates to:
  /// **'已自动降级'**
  String get networkAdapter_autoFallback;

  /// No description provided for @networkAdapter_autoFallbackDesc.
  ///
  /// In zh, this message translates to:
  /// **'检测到 Cronet 不可用，已切换到备用适配器'**
  String get networkAdapter_autoFallbackDesc;

  /// No description provided for @networkAdapter_controlOptions.
  ///
  /// In zh, this message translates to:
  /// **'控制选项'**
  String get networkAdapter_controlOptions;

  /// No description provided for @networkAdapter_currentStatus.
  ///
  /// In zh, this message translates to:
  /// **'当前状态'**
  String get networkAdapter_currentStatus;

  /// No description provided for @networkAdapter_degradeReason.
  ///
  /// In zh, this message translates to:
  /// **'Cronet 降级原因'**
  String get networkAdapter_degradeReason;

  /// No description provided for @networkAdapter_devTest.
  ///
  /// In zh, this message translates to:
  /// **'开发者测试'**
  String get networkAdapter_devTest;

  /// No description provided for @networkAdapter_fallback.
  ///
  /// In zh, this message translates to:
  /// **'备用'**
  String get networkAdapter_fallback;

  /// No description provided for @networkAdapter_fallbackStatus.
  ///
  /// In zh, this message translates to:
  /// **'降级状态'**
  String get networkAdapter_fallbackStatus;

  /// No description provided for @networkAdapter_forceFallback.
  ///
  /// In zh, this message translates to:
  /// **'强制使用备用适配器'**
  String get networkAdapter_forceFallback;

  /// No description provided for @networkAdapter_forceFallbackDesc.
  ///
  /// In zh, this message translates to:
  /// **'禁用 Cronet，使用 NetworkHttpAdapter'**
  String get networkAdapter_forceFallbackDesc;

  /// No description provided for @networkAdapter_native.
  ///
  /// In zh, this message translates to:
  /// **'原生'**
  String get networkAdapter_native;

  /// No description provided for @networkAdapter_resetFallback.
  ///
  /// In zh, this message translates to:
  /// **'重置降级状态'**
  String get networkAdapter_resetFallback;

  /// No description provided for @networkAdapter_resetFallbackDesc.
  ///
  /// In zh, this message translates to:
  /// **'清除降级记录，下次启动重新尝试 Cronet'**
  String get networkAdapter_resetFallbackDesc;

  /// No description provided for @networkAdapter_resetSuccess.
  ///
  /// In zh, this message translates to:
  /// **'已重置，重启应用后生效'**
  String get networkAdapter_resetSuccess;

  /// No description provided for @networkAdapter_settingSaved.
  ///
  /// In zh, this message translates to:
  /// **'设置已保存，重启应用后生效'**
  String get networkAdapter_settingSaved;

  /// No description provided for @networkAdapter_simulateError.
  ///
  /// In zh, this message translates to:
  /// **'模拟 Cronet 错误'**
  String get networkAdapter_simulateError;

  /// No description provided for @networkAdapter_simulateErrorDesc.
  ///
  /// In zh, this message translates to:
  /// **'触发降级流程，测试自动降级功能'**
  String get networkAdapter_simulateErrorDesc;

  /// No description provided for @networkAdapter_simulateSuccess.
  ///
  /// In zh, this message translates to:
  /// **'已触发模拟降级，请查看降级状态'**
  String get networkAdapter_simulateSuccess;

  /// No description provided for @networkAdapter_title.
  ///
  /// In zh, this message translates to:
  /// **'网络适配器'**
  String get networkAdapter_title;

  /// No description provided for @networkAdapter_viewReason.
  ///
  /// In zh, this message translates to:
  /// **'查看降级原因'**
  String get networkAdapter_viewReason;

  /// No description provided for @networkSettings_advanced.
  ///
  /// In zh, this message translates to:
  /// **'高级'**
  String get networkSettings_advanced;

  /// No description provided for @networkSettings_auxiliary.
  ///
  /// In zh, this message translates to:
  /// **'辅助功能'**
  String get networkSettings_auxiliary;

  /// No description provided for @networkSettings_debug.
  ///
  /// In zh, this message translates to:
  /// **'调试'**
  String get networkSettings_debug;

  /// No description provided for @networkSettings_engine.
  ///
  /// In zh, this message translates to:
  /// **'网络引擎'**
  String get networkSettings_engine;

  /// No description provided for @networkSettings_maxConcurrent.
  ///
  /// In zh, this message translates to:
  /// **'最大并发数'**
  String get networkSettings_maxConcurrent;

  /// No description provided for @networkSettings_maxPerWindow.
  ///
  /// In zh, this message translates to:
  /// **'窗口请求上限'**
  String get networkSettings_maxPerWindow;

  /// No description provided for @networkSettings_proxy.
  ///
  /// In zh, this message translates to:
  /// **'网络代理'**
  String get networkSettings_proxy;

  /// No description provided for @networkSettings_title.
  ///
  /// In zh, this message translates to:
  /// **'网络设置'**
  String get networkSettings_title;

  /// No description provided for @networkSettings_windowSeconds.
  ///
  /// In zh, this message translates to:
  /// **'窗口时长'**
  String get networkSettings_windowSeconds;

  /// No description provided for @networkSettings_windowSecondsSuffix.
  ///
  /// In zh, this message translates to:
  /// **'秒'**
  String get networkSettings_windowSecondsSuffix;

  /// No description provided for @network_adapterNativeAndroid.
  ///
  /// In zh, this message translates to:
  /// **'Cronet 适配器'**
  String get network_adapterNativeAndroid;

  /// No description provided for @network_adapterNativeIos.
  ///
  /// In zh, this message translates to:
  /// **'Cupertino 适配器'**
  String get network_adapterNativeIos;

  /// No description provided for @network_adapterNetwork.
  ///
  /// In zh, this message translates to:
  /// **'Network 适配器'**
  String get network_adapterNetwork;

  /// No description provided for @network_adapterRhttp.
  ///
  /// In zh, this message translates to:
  /// **'rhttp 引擎'**
  String get network_adapterRhttp;

  /// No description provided for @network_adapterWebView.
  ///
  /// In zh, this message translates to:
  /// **'WebView 适配器'**
  String get network_adapterWebView;

  /// No description provided for @network_badRequest.
  ///
  /// In zh, this message translates to:
  /// **'请求参数错误'**
  String get network_badRequest;

  /// No description provided for @network_forbidden.
  ///
  /// In zh, this message translates to:
  /// **'没有权限执行此操作'**
  String get network_forbidden;

  /// No description provided for @network_internalError.
  ///
  /// In zh, this message translates to:
  /// **'服务器内部错误'**
  String get network_internalError;

  /// No description provided for @network_notFound.
  ///
  /// In zh, this message translates to:
  /// **'请求的资源不存在'**
  String get network_notFound;

  /// No description provided for @network_postPendingReview.
  ///
  /// In zh, this message translates to:
  /// **'你的帖子已提交，正在等待审核'**
  String get network_postPendingReview;

  /// No description provided for @network_rateLimited.
  ///
  /// In zh, this message translates to:
  /// **'请求过于频繁，请稍后再试'**
  String get network_rateLimited;

  /// No description provided for @network_rateLimitedWait.
  ///
  /// In zh, this message translates to:
  /// **'请求过于频繁，请等待 {duration} 后再试'**
  String network_rateLimitedWait(String duration);

  /// No description provided for @network_requestFailed.
  ///
  /// In zh, this message translates to:
  /// **'请求失败 ({statusCode})'**
  String network_requestFailed(int statusCode);

  /// No description provided for @network_serverUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'服务器暂时不可用 ({statusCode})'**
  String network_serverUnavailable(int statusCode);

  /// No description provided for @network_serverUnavailableRetry.
  ///
  /// In zh, this message translates to:
  /// **'服务器暂时不可用，请稍后再试'**
  String get network_serverUnavailableRetry;

  /// No description provided for @network_unauthorized.
  ///
  /// In zh, this message translates to:
  /// **'未登录或登录已过期'**
  String get network_unauthorized;

  /// No description provided for @network_unprocessable.
  ///
  /// In zh, this message translates to:
  /// **'请求无法处理'**
  String get network_unprocessable;

  /// No description provided for @rhttpEngine_alwaysUse.
  ///
  /// In zh, this message translates to:
  /// **'始终使用'**
  String get rhttpEngine_alwaysUse;

  /// No description provided for @rhttpEngine_currentAdapter.
  ///
  /// In zh, this message translates to:
  /// **'当前: {adapter}'**
  String rhttpEngine_currentAdapter(String adapter);

  /// No description provided for @rhttpEngine_disabledDesc.
  ///
  /// In zh, this message translates to:
  /// **'启用后使用 Rust 网络引擎'**
  String get rhttpEngine_disabledDesc;

  /// No description provided for @rhttpEngine_echFallbackHint.
  ///
  /// In zh, this message translates to:
  /// **'ECH 启用时 WebView 仍通过本地代理兜底；rhttp 直连会优先尝试自身的 ECH'**
  String get rhttpEngine_echFallbackHint;

  /// No description provided for @rhttpEngine_enabledDesc.
  ///
  /// In zh, this message translates to:
  /// **'HTTP/2 多路复用 · Rust reqwest'**
  String get rhttpEngine_enabledDesc;

  /// No description provided for @rhttpEngine_proxyDohOnly.
  ///
  /// In zh, this message translates to:
  /// **'仅代理/DOH'**
  String get rhttpEngine_proxyDohOnly;

  /// No description provided for @rhttpEngine_title.
  ///
  /// In zh, this message translates to:
  /// **'rhttp 引擎'**
  String get rhttpEngine_title;

  /// No description provided for @rhttpEngine_useMode.
  ///
  /// In zh, this message translates to:
  /// **'使用模式'**
  String get rhttpEngine_useMode;

  /// No description provided for @webviewAdapter_disabledDesc.
  ///
  /// In zh, this message translates to:
  /// **'使用浏览器内核发送请求，可改善登录稳定性'**
  String get webviewAdapter_disabledDesc;

  /// No description provided for @webviewAdapter_enabledDesc.
  ///
  /// In zh, this message translates to:
  /// **'主站 API 请求通过浏览器内核发送'**
  String get webviewAdapter_enabledDesc;

  /// No description provided for @webviewAdapter_hint.
  ///
  /// In zh, this message translates to:
  /// **'仅主站 API 请求通过 WebView 发送，图片加载和消息推送不受影响'**
  String get webviewAdapter_hint;

  /// No description provided for @webviewAdapter_title.
  ///
  /// In zh, this message translates to:
  /// **'WebView 网络引擎'**
  String get webviewAdapter_title;

  /// No description provided for @notification_adminNewSuggestions.
  ///
  /// In zh, this message translates to:
  /// **'网站信息中心有新建议'**
  String get notification_adminNewSuggestions;

  /// No description provided for @notification_assignedTopic.
  ///
  /// In zh, this message translates to:
  /// **'话题已分配给你'**
  String get notification_assignedTopic;

  /// No description provided for @notification_backgroundRunning.
  ///
  /// In zh, this message translates to:
  /// **'正在后台运行，保持通知接收'**
  String get notification_backgroundRunning;

  /// No description provided for @notification_boost.
  ///
  /// In zh, this message translates to:
  /// **'{username} Boost 了你的帖子'**
  String notification_boost(String username);

  /// No description provided for @notification_boostWithContent.
  ///
  /// In zh, this message translates to:
  /// **'{username}: {content}'**
  String notification_boostWithContent(String username, String content);

  /// No description provided for @notification_boostByMany.
  ///
  /// In zh, this message translates to:
  /// **'{username} 等 {count} 人 Boost 了你的帖子'**
  String notification_boostByMany(String username, int count);

  /// No description provided for @notification_bookmarkReminder.
  ///
  /// In zh, this message translates to:
  /// **'书签提醒'**
  String get notification_bookmarkReminder;

  /// No description provided for @notification_channelBackground.
  ///
  /// In zh, this message translates to:
  /// **'后台运行'**
  String get notification_channelBackground;

  /// No description provided for @notification_channelBackgroundDesc.
  ///
  /// In zh, this message translates to:
  /// **'保持 FluxDO 在后台接收通知'**
  String get notification_channelBackgroundDesc;

  /// No description provided for @notification_channelDiscourse.
  ///
  /// In zh, this message translates to:
  /// **'Discourse 通知'**
  String get notification_channelDiscourse;

  /// No description provided for @notification_channelDiscourseDesc.
  ///
  /// In zh, this message translates to:
  /// **'来自 Discourse 论坛的通知'**
  String get notification_channelDiscourseDesc;

  /// No description provided for @notification_chatGroupMention.
  ///
  /// In zh, this message translates to:
  /// **'群组在聊天中被提及'**
  String get notification_chatGroupMention;

  /// No description provided for @notification_chatInvitation.
  ///
  /// In zh, this message translates to:
  /// **'{username} 邀请你参与聊天'**
  String notification_chatInvitation(String username);

  /// No description provided for @notification_chatMention.
  ///
  /// In zh, this message translates to:
  /// **'{username} 在聊天中提及了你'**
  String notification_chatMention(String username);

  /// No description provided for @notification_chatMessage.
  ///
  /// In zh, this message translates to:
  /// **'{username} 发送了聊天消息'**
  String notification_chatMessage(String username);

  /// No description provided for @notification_chatQuotedPost.
  ///
  /// In zh, this message translates to:
  /// **'{username} 在聊天中引用了你'**
  String notification_chatQuotedPost(String username);

  /// No description provided for @notification_chatWatchedThread.
  ///
  /// In zh, this message translates to:
  /// **'你关注的聊天话题有新消息'**
  String get notification_chatWatchedThread;

  /// No description provided for @notification_circlesActivity.
  ///
  /// In zh, this message translates to:
  /// **'圈子有新动态'**
  String get notification_circlesActivity;

  /// No description provided for @notification_codeReviewApproved.
  ///
  /// In zh, this message translates to:
  /// **'代码审核已通过'**
  String get notification_codeReviewApproved;

  /// No description provided for @notification_createdNewTopic.
  ///
  /// In zh, this message translates to:
  /// **'{username} 创建了新话题'**
  String notification_createdNewTopic(String username);

  /// No description provided for @notification_custom.
  ///
  /// In zh, this message translates to:
  /// **'自定义通知'**
  String get notification_custom;

  /// No description provided for @notification_editedPost.
  ///
  /// In zh, this message translates to:
  /// **'{username} 编辑了帖子'**
  String notification_editedPost(String username);

  /// No description provided for @notification_empty.
  ///
  /// In zh, this message translates to:
  /// **'暂无通知'**
  String get notification_empty;

  /// No description provided for @notification_eventInvitation.
  ///
  /// In zh, this message translates to:
  /// **'{username} 邀请你参加活动'**
  String notification_eventInvitation(String username);

  /// No description provided for @notification_eventReminder.
  ///
  /// In zh, this message translates to:
  /// **'活动提醒'**
  String get notification_eventReminder;

  /// No description provided for @notification_followingYou.
  ///
  /// In zh, this message translates to:
  /// **'{displayName} 开始关注你'**
  String notification_followingYou(String displayName);

  /// No description provided for @notification_grantedBadge.
  ///
  /// In zh, this message translates to:
  /// **'获得了 \'{badgeName}\''**
  String notification_grantedBadge(String badgeName);

  /// No description provided for @notification_groupMessageSummary.
  ///
  /// In zh, this message translates to:
  /// **'{groupName} 收件箱有 {count} 条消息'**
  String notification_groupMessageSummary(String groupName, int count);

  /// No description provided for @notification_invitedToPM.
  ///
  /// In zh, this message translates to:
  /// **'{username} 邀请你参与私信'**
  String notification_invitedToPM(String username);

  /// No description provided for @notification_invitedToTopic.
  ///
  /// In zh, this message translates to:
  /// **'{username} 邀请你参与话题'**
  String notification_invitedToTopic(String username);

  /// No description provided for @notification_inviteeAccepted.
  ///
  /// In zh, this message translates to:
  /// **'{displayName} 接受了你的邀请'**
  String notification_inviteeAccepted(String displayName);

  /// No description provided for @notification_liked.
  ///
  /// In zh, this message translates to:
  /// **'{username} 赞了你的帖子'**
  String notification_liked(String username);

  /// No description provided for @notification_likedByMany.
  ///
  /// In zh, this message translates to:
  /// **'{username} 和其他 {count} 人赞了你的帖子'**
  String notification_likedByMany(String username, int count);

  /// No description provided for @notification_likedByTwo.
  ///
  /// In zh, this message translates to:
  /// **'{username}、{username2} 赞了你的帖子'**
  String notification_likedByTwo(String username, String username2);

  /// No description provided for @notification_likedMultiplePosts.
  ///
  /// In zh, this message translates to:
  /// **'{displayName} 点赞了你的 {count} 个帖子'**
  String notification_likedMultiplePosts(String displayName, int count);

  /// No description provided for @notification_linkedMultiplePosts.
  ///
  /// In zh, this message translates to:
  /// **'{displayName} 链接了你的 {count} 个帖子'**
  String notification_linkedMultiplePosts(String displayName, int count);

  /// No description provided for @notification_linkedPost.
  ///
  /// In zh, this message translates to:
  /// **'{username} 链接了你的帖子'**
  String notification_linkedPost(String username);

  /// No description provided for @notification_markAllRead.
  ///
  /// In zh, this message translates to:
  /// **'全部标为已读'**
  String get notification_markAllRead;

  /// No description provided for @notification_membershipAccepted.
  ///
  /// In zh, this message translates to:
  /// **'加入 \'{groupName}\' 的申请已被接受'**
  String notification_membershipAccepted(String groupName);

  /// No description provided for @notification_membershipPending.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个未处理的 \'{groupName}\' 成员申请'**
  String notification_membershipPending(int count, String groupName);

  /// No description provided for @notification_mentioned.
  ///
  /// In zh, this message translates to:
  /// **'{username} 在帖子中提及了你'**
  String notification_mentioned(String username);

  /// No description provided for @notification_movedPost.
  ///
  /// In zh, this message translates to:
  /// **'{username} 移动了帖子'**
  String notification_movedPost(String username);

  /// No description provided for @notification_newFeaturesAvailable.
  ///
  /// In zh, this message translates to:
  /// **'有新功能可用！'**
  String get notification_newFeaturesAvailable;

  /// No description provided for @notification_newNotification.
  ///
  /// In zh, this message translates to:
  /// **'新通知'**
  String get notification_newNotification;

  /// No description provided for @notification_newPostPublished.
  ///
  /// In zh, this message translates to:
  /// **'{username} 发布了新帖子'**
  String notification_newPostPublished(String username);

  /// No description provided for @notification_newTopic.
  ///
  /// In zh, this message translates to:
  /// **'新建话题'**
  String get notification_newTopic;

  /// No description provided for @notification_peopleLikedPost.
  ///
  /// In zh, this message translates to:
  /// **'{count} 人赞了你的帖子'**
  String notification_peopleLikedPost(int count);

  /// No description provided for @notification_peopleLinkedPost.
  ///
  /// In zh, this message translates to:
  /// **'{count} 人链接了你的帖子'**
  String notification_peopleLinkedPost(int count);

  /// No description provided for @notification_postApproved.
  ///
  /// In zh, this message translates to:
  /// **'你的帖子已被批准'**
  String get notification_postApproved;

  /// No description provided for @notification_privateMsgSent.
  ///
  /// In zh, this message translates to:
  /// **'{username} 发送了私信'**
  String notification_privateMsgSent(String username);

  /// No description provided for @notification_qaCommented.
  ///
  /// In zh, this message translates to:
  /// **'{username} 评论了问答'**
  String notification_qaCommented(String username);

  /// No description provided for @notification_quoted.
  ///
  /// In zh, this message translates to:
  /// **'{username} 引用了你的帖子'**
  String notification_quoted(String username);

  /// No description provided for @notification_reaction.
  ///
  /// In zh, this message translates to:
  /// **'{username} 对你的帖子做出了反应'**
  String notification_reaction(String username);

  /// No description provided for @notification_replied.
  ///
  /// In zh, this message translates to:
  /// **'{username} 回复了你的帖子'**
  String notification_replied(String username);

  /// No description provided for @notification_repliedTopic.
  ///
  /// In zh, this message translates to:
  /// **'{username} 回复了话题'**
  String notification_repliedTopic(String username);

  /// No description provided for @notification_topicReminder.
  ///
  /// In zh, this message translates to:
  /// **'话题提醒'**
  String get notification_topicReminder;

  /// No description provided for @notification_typeAdminProblems.
  ///
  /// In zh, this message translates to:
  /// **'管理员问题'**
  String get notification_typeAdminProblems;

  /// No description provided for @notification_typeAssignedTopic.
  ///
  /// In zh, this message translates to:
  /// **'话题指派'**
  String get notification_typeAssignedTopic;

  /// No description provided for @notification_typeBoost.
  ///
  /// In zh, this message translates to:
  /// **'Boost'**
  String get notification_typeBoost;

  /// No description provided for @notification_typeBookmarkReminder.
  ///
  /// In zh, this message translates to:
  /// **'书签提醒'**
  String get notification_typeBookmarkReminder;

  /// No description provided for @notification_typeChatGroupMention.
  ///
  /// In zh, this message translates to:
  /// **'群聊提及'**
  String get notification_typeChatGroupMention;

  /// No description provided for @notification_typeChatInvitation.
  ///
  /// In zh, this message translates to:
  /// **'聊天邀请'**
  String get notification_typeChatInvitation;

  /// No description provided for @notification_typeChatMention.
  ///
  /// In zh, this message translates to:
  /// **'聊天提及'**
  String get notification_typeChatMention;

  /// No description provided for @notification_typeChatMessage.
  ///
  /// In zh, this message translates to:
  /// **'聊天消息'**
  String get notification_typeChatMessage;

  /// No description provided for @notification_typeChatQuotedPost.
  ///
  /// In zh, this message translates to:
  /// **'聊天引用'**
  String get notification_typeChatQuotedPost;

  /// No description provided for @notification_typeChatWatchedThread.
  ///
  /// In zh, this message translates to:
  /// **'聊天关注话题'**
  String get notification_typeChatWatchedThread;

  /// No description provided for @notification_typeCirclesActivity.
  ///
  /// In zh, this message translates to:
  /// **'圈子活动'**
  String get notification_typeCirclesActivity;

  /// No description provided for @notification_typeCodeReviewApproved.
  ///
  /// In zh, this message translates to:
  /// **'代码审核通过'**
  String get notification_typeCodeReviewApproved;

  /// No description provided for @notification_typeCustom.
  ///
  /// In zh, this message translates to:
  /// **'自定义'**
  String get notification_typeCustom;

  /// No description provided for @notification_typeEdited.
  ///
  /// In zh, this message translates to:
  /// **'编辑'**
  String get notification_typeEdited;

  /// No description provided for @notification_typeEventInvitation.
  ///
  /// In zh, this message translates to:
  /// **'活动邀请'**
  String get notification_typeEventInvitation;

  /// No description provided for @notification_typeEventReminder.
  ///
  /// In zh, this message translates to:
  /// **'活动提醒'**
  String get notification_typeEventReminder;

  /// No description provided for @notification_typeFollowing.
  ///
  /// In zh, this message translates to:
  /// **'关注'**
  String get notification_typeFollowing;

  /// No description provided for @notification_typeFollowingCreatedTopic.
  ///
  /// In zh, this message translates to:
  /// **'关注的用户创建了话题'**
  String get notification_typeFollowingCreatedTopic;

  /// No description provided for @notification_typeFollowingReplied.
  ///
  /// In zh, this message translates to:
  /// **'关注的用户回复了'**
  String get notification_typeFollowingReplied;

  /// No description provided for @notification_typeGrantedBadge.
  ///
  /// In zh, this message translates to:
  /// **'获得徽章'**
  String get notification_typeGrantedBadge;

  /// No description provided for @notification_typeGroupMentioned.
  ///
  /// In zh, this message translates to:
  /// **'群组提及'**
  String get notification_typeGroupMentioned;

  /// No description provided for @notification_typeGroupMessageSummary.
  ///
  /// In zh, this message translates to:
  /// **'群组消息摘要'**
  String get notification_typeGroupMessageSummary;

  /// No description provided for @notification_typeInvitedToPM.
  ///
  /// In zh, this message translates to:
  /// **'私信邀请'**
  String get notification_typeInvitedToPM;

  /// No description provided for @notification_typeInvitedToTopic.
  ///
  /// In zh, this message translates to:
  /// **'话题邀请'**
  String get notification_typeInvitedToTopic;

  /// No description provided for @notification_typeInviteeAccepted.
  ///
  /// In zh, this message translates to:
  /// **'邀请已接受'**
  String get notification_typeInviteeAccepted;

  /// No description provided for @notification_typeLiked.
  ///
  /// In zh, this message translates to:
  /// **'点赞'**
  String get notification_typeLiked;

  /// No description provided for @notification_typeLikedConsolidated.
  ///
  /// In zh, this message translates to:
  /// **'点赞汇总'**
  String get notification_typeLikedConsolidated;

  /// No description provided for @notification_typeLinked.
  ///
  /// In zh, this message translates to:
  /// **'链接'**
  String get notification_typeLinked;

  /// No description provided for @notification_typeLinkedConsolidated.
  ///
  /// In zh, this message translates to:
  /// **'链接汇总'**
  String get notification_typeLinkedConsolidated;

  /// No description provided for @notification_typeMembershipAccepted.
  ///
  /// In zh, this message translates to:
  /// **'成员申请已接受'**
  String get notification_typeMembershipAccepted;

  /// No description provided for @notification_typeMembershipConsolidated.
  ///
  /// In zh, this message translates to:
  /// **'成员申请汇总'**
  String get notification_typeMembershipConsolidated;

  /// No description provided for @notification_typeMentioned.
  ///
  /// In zh, this message translates to:
  /// **'提及'**
  String get notification_typeMentioned;

  /// No description provided for @notification_typeMovedPost.
  ///
  /// In zh, this message translates to:
  /// **'帖子移动'**
  String get notification_typeMovedPost;

  /// No description provided for @notification_typeNewFeatures.
  ///
  /// In zh, this message translates to:
  /// **'新功能'**
  String get notification_typeNewFeatures;

  /// No description provided for @notification_typePostApproved.
  ///
  /// In zh, this message translates to:
  /// **'帖子已批准'**
  String get notification_typePostApproved;

  /// No description provided for @notification_typePosted.
  ///
  /// In zh, this message translates to:
  /// **'发帖'**
  String get notification_typePosted;

  /// No description provided for @notification_typePrivateMessage.
  ///
  /// In zh, this message translates to:
  /// **'私信'**
  String get notification_typePrivateMessage;

  /// No description provided for @notification_typeQACommented.
  ///
  /// In zh, this message translates to:
  /// **'问答评论'**
  String get notification_typeQACommented;

  /// No description provided for @notification_typeQuoted.
  ///
  /// In zh, this message translates to:
  /// **'引用'**
  String get notification_typeQuoted;

  /// No description provided for @notification_typeReaction.
  ///
  /// In zh, this message translates to:
  /// **'反应'**
  String get notification_typeReaction;

  /// No description provided for @notification_typeReplied.
  ///
  /// In zh, this message translates to:
  /// **'回复'**
  String get notification_typeReplied;

  /// No description provided for @notification_typeTopicReminder.
  ///
  /// In zh, this message translates to:
  /// **'话题提醒'**
  String get notification_typeTopicReminder;

  /// No description provided for @notification_typeUnknown.
  ///
  /// In zh, this message translates to:
  /// **'未知'**
  String get notification_typeUnknown;

  /// No description provided for @notification_typeVotesReleased.
  ///
  /// In zh, this message translates to:
  /// **'投票发布'**
  String get notification_typeVotesReleased;

  /// No description provided for @notification_typeWatchingCategoryOrTag.
  ///
  /// In zh, this message translates to:
  /// **'关注分类或标签'**
  String get notification_typeWatchingCategoryOrTag;

  /// No description provided for @notification_typeWatchingFirstPost.
  ///
  /// In zh, this message translates to:
  /// **'关注首帖'**
  String get notification_typeWatchingFirstPost;

  /// No description provided for @notification_votesReleased.
  ///
  /// In zh, this message translates to:
  /// **'投票已发布'**
  String get notification_votesReleased;

  /// No description provided for @notification_watchingCategoryNewPost.
  ///
  /// In zh, this message translates to:
  /// **'{username} 发布了新帖子'**
  String notification_watchingCategoryNewPost(String username);

  /// No description provided for @notifications_empty.
  ///
  /// In zh, this message translates to:
  /// **'暂无通知'**
  String get notifications_empty;

  /// No description provided for @notifications_markAllRead.
  ///
  /// In zh, this message translates to:
  /// **'全部标为已读'**
  String get notifications_markAllRead;

  /// No description provided for @notifications_title.
  ///
  /// In zh, this message translates to:
  /// **'通知'**
  String get notifications_title;

  /// No description provided for @boost_created.
  ///
  /// In zh, this message translates to:
  /// **'Boost 已发送'**
  String get boost_created;

  /// No description provided for @boost_deleteConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定要删除这条 Boost 吗？'**
  String get boost_deleteConfirm;

  /// No description provided for @boost_deleteFailed.
  ///
  /// In zh, this message translates to:
  /// **'Boost 删除失败'**
  String get boost_deleteFailed;

  /// No description provided for @boost_deleted.
  ///
  /// In zh, this message translates to:
  /// **'Boost 已删除'**
  String get boost_deleted;

  /// No description provided for @boost_failed.
  ///
  /// In zh, this message translates to:
  /// **'Boost 发送失败'**
  String get boost_failed;

  /// No description provided for @boost_flagSubmitted.
  ///
  /// In zh, this message translates to:
  /// **'举报已提交'**
  String get boost_flagSubmitted;

  /// No description provided for @boost_flagTitle.
  ///
  /// In zh, this message translates to:
  /// **'举报 Boost'**
  String get boost_flagTitle;

  /// No description provided for @boost_limitReached.
  ///
  /// In zh, this message translates to:
  /// **'此帖子的 Boost 数量已达上限'**
  String get boost_limitReached;

  /// No description provided for @boost_placeholder.
  ///
  /// In zh, this message translates to:
  /// **'说点什么...'**
  String get boost_placeholder;

  /// No description provided for @boost_send.
  ///
  /// In zh, this message translates to:
  /// **'发送'**
  String get boost_send;

  /// No description provided for @boost_tooLong.
  ///
  /// In zh, this message translates to:
  /// **'内容过长，最多 {count} 个字符'**
  String boost_tooLong(int count);

  /// No description provided for @nested_flatView.
  ///
  /// In zh, this message translates to:
  /// **'切换平铺视图'**
  String get nested_flatView;

  /// No description provided for @nested_loadMore.
  ///
  /// In zh, this message translates to:
  /// **'加载更多'**
  String get nested_loadMore;

  /// No description provided for @nested_loadMoreReplies.
  ///
  /// In zh, this message translates to:
  /// **'加载更多回复'**
  String get nested_loadMoreReplies;

  /// No description provided for @nested_repliesCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 条回复'**
  String nested_repliesCount(int count);

  /// No description provided for @nested_sortNew.
  ///
  /// In zh, this message translates to:
  /// **'最新'**
  String get nested_sortNew;

  /// No description provided for @nested_sortOld.
  ///
  /// In zh, this message translates to:
  /// **'最旧'**
  String get nested_sortOld;

  /// No description provided for @nested_sortTop.
  ///
  /// In zh, this message translates to:
  /// **'热门'**
  String get nested_sortTop;

  /// No description provided for @nested_title.
  ///
  /// In zh, this message translates to:
  /// **'树形视图'**
  String get nested_title;

  /// No description provided for @poll_closed.
  ///
  /// In zh, this message translates to:
  /// **'已关闭'**
  String get poll_closed;

  /// No description provided for @poll_count.
  ///
  /// In zh, this message translates to:
  /// **'计数'**
  String get poll_count;

  /// No description provided for @poll_percentage.
  ///
  /// In zh, this message translates to:
  /// **'百分比'**
  String get poll_percentage;

  /// No description provided for @poll_undo.
  ///
  /// In zh, this message translates to:
  /// **'撤销'**
  String get poll_undo;

  /// No description provided for @poll_viewResults.
  ///
  /// In zh, this message translates to:
  /// **'查看结果'**
  String get poll_viewResults;

  /// No description provided for @poll_vote.
  ///
  /// In zh, this message translates to:
  /// **'投票'**
  String get poll_vote;

  /// No description provided for @poll_voters.
  ///
  /// In zh, this message translates to:
  /// **'{count} 投票人'**
  String poll_voters(int count);

  /// No description provided for @post_acceptSolution.
  ///
  /// In zh, this message translates to:
  /// **'采纳为解决方案'**
  String get post_acceptSolution;

  /// No description provided for @post_collapseReplies.
  ///
  /// In zh, this message translates to:
  /// **'收起回复'**
  String get post_collapseReplies;

  /// No description provided for @post_contentRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入内容'**
  String get post_contentRequired;

  /// No description provided for @post_deleteReplyConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定要删除这条回复吗？此操作可以撤销。'**
  String get post_deleteReplyConfirm;

  /// No description provided for @post_deleteReplyTitle.
  ///
  /// In zh, this message translates to:
  /// **'删除回复'**
  String get post_deleteReplyTitle;

  /// No description provided for @post_detail.
  ///
  /// In zh, this message translates to:
  /// **'帖子详情'**
  String get post_detail;

  /// No description provided for @post_discardConfirm.
  ///
  /// In zh, this message translates to:
  /// **'你想放弃你的帖子吗？'**
  String get post_discardConfirm;

  /// No description provided for @post_discardTitle.
  ///
  /// In zh, this message translates to:
  /// **'放弃帖子'**
  String get post_discardTitle;

  /// No description provided for @post_editPostTitle.
  ///
  /// In zh, this message translates to:
  /// **'编辑帖子 #{postNumber}'**
  String post_editPostTitle(int postNumber);

  /// No description provided for @post_firstPostNotice.
  ///
  /// In zh, this message translates to:
  /// **'这是 {username} 的首次发帖——让我们欢迎 TA 加入社区！'**
  String post_firstPostNotice(String username);

  /// No description provided for @post_flagDescriptionHint.
  ///
  /// In zh, this message translates to:
  /// **'请描述具体问题...'**
  String get post_flagDescriptionHint;

  /// No description provided for @post_flagFailed.
  ///
  /// In zh, this message translates to:
  /// **'举报失败，请稍后重试'**
  String get post_flagFailed;

  /// No description provided for @post_flagMessageUser.
  ///
  /// In zh, this message translates to:
  /// **'向 @{username} 发送消息'**
  String post_flagMessageUser(String username);

  /// No description provided for @post_flagNotifyModerators.
  ///
  /// In zh, this message translates to:
  /// **'私下通知管理人员'**
  String get post_flagNotifyModerators;

  /// No description provided for @post_flagSubmitted.
  ///
  /// In zh, this message translates to:
  /// **'举报已提交'**
  String get post_flagSubmitted;

  /// No description provided for @post_flagTitle.
  ///
  /// In zh, this message translates to:
  /// **'举报帖子'**
  String get post_flagTitle;

  /// No description provided for @post_generateShareImage.
  ///
  /// In zh, this message translates to:
  /// **'生成分享图片'**
  String get post_generateShareImage;

  /// No description provided for @post_lastReadHere.
  ///
  /// In zh, this message translates to:
  /// **'上次看到这里'**
  String get post_lastReadHere;

  /// No description provided for @post_loadContentFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载内容失败: {error}'**
  String post_loadContentFailed(String error);

  /// No description provided for @post_loadMoreReplies.
  ///
  /// In zh, this message translates to:
  /// **'加载更多回复'**
  String get post_loadMoreReplies;

  /// No description provided for @post_longTimeAgo.
  ///
  /// In zh, this message translates to:
  /// **'很久以前'**
  String get post_longTimeAgo;

  /// No description provided for @post_meBadge.
  ///
  /// In zh, this message translates to:
  /// **'我'**
  String get post_meBadge;

  /// No description provided for @post_moreLinks.
  ///
  /// In zh, this message translates to:
  /// **'还有 {count} 条'**
  String post_moreLinks(int count);

  /// No description provided for @post_noReactions.
  ///
  /// In zh, this message translates to:
  /// **'暂无回应'**
  String get post_noReactions;

  /// No description provided for @post_opBadge.
  ///
  /// In zh, this message translates to:
  /// **'主'**
  String get post_opBadge;

  /// No description provided for @post_pendingReview.
  ///
  /// In zh, this message translates to:
  /// **'你的帖子已提交，正在等待审核'**
  String get post_pendingReview;

  /// No description provided for @post_reactions.
  ///
  /// In zh, this message translates to:
  /// **'回应'**
  String get post_reactions;

  /// No description provided for @post_relatedLinks.
  ///
  /// In zh, this message translates to:
  /// **'相关链接'**
  String get post_relatedLinks;

  /// No description provided for @post_relatedRepliesCount.
  ///
  /// In zh, this message translates to:
  /// **'相关回复共 {count} 条'**
  String post_relatedRepliesCount(int count);

  /// No description provided for @post_replyCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 条回复'**
  String post_replyCount(int count);

  /// No description provided for @post_replySent.
  ///
  /// In zh, this message translates to:
  /// **'回复已发送'**
  String get post_replySent;

  /// No description provided for @post_replySentAction.
  ///
  /// In zh, this message translates to:
  /// **'查看'**
  String get post_replySentAction;

  /// No description provided for @post_replyTo.
  ///
  /// In zh, this message translates to:
  /// **'回复给'**
  String get post_replyTo;

  /// No description provided for @post_replyToTopic.
  ///
  /// In zh, this message translates to:
  /// **'回复话题'**
  String get post_replyToTopic;

  /// No description provided for @post_replyToUser.
  ///
  /// In zh, this message translates to:
  /// **'回复 @{username}'**
  String post_replyToUser(String username);

  /// No description provided for @post_returningUserNotice.
  ///
  /// In zh, this message translates to:
  /// **'好久不见 {username}——TA 的上一条帖子是 {timeText}。'**
  String post_returningUserNotice(String username, String timeText);

  /// No description provided for @post_sendPmTitle.
  ///
  /// In zh, this message translates to:
  /// **'发送私信给 @{username}'**
  String post_sendPmTitle(String username);

  /// No description provided for @post_solutionAccepted.
  ///
  /// In zh, this message translates to:
  /// **'已采纳为解决方案'**
  String get post_solutionAccepted;

  /// No description provided for @post_solutionUnaccepted.
  ///
  /// In zh, this message translates to:
  /// **'已取消采纳'**
  String get post_solutionUnaccepted;

  /// No description provided for @post_solved.
  ///
  /// In zh, this message translates to:
  /// **'已解决'**
  String get post_solved;

  /// No description provided for @post_submitFlag.
  ///
  /// In zh, this message translates to:
  /// **'提交举报'**
  String get post_submitFlag;

  /// No description provided for @post_tipLdc.
  ///
  /// In zh, this message translates to:
  /// **'打赏 LDC'**
  String get post_tipLdc;

  /// No description provided for @post_titleRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入标题'**
  String get post_titleRequired;

  /// No description provided for @post_topicSolved.
  ///
  /// In zh, this message translates to:
  /// **'此话题已解决'**
  String get post_topicSolved;

  /// No description provided for @post_unacceptSolution.
  ///
  /// In zh, this message translates to:
  /// **'取消采纳'**
  String get post_unacceptSolution;

  /// No description provided for @post_unsolved.
  ///
  /// In zh, this message translates to:
  /// **'待解决'**
  String get post_unsolved;

  /// No description provided for @post_viewBestAnswer.
  ///
  /// In zh, this message translates to:
  /// **'查看最佳答案'**
  String get post_viewBestAnswer;

  /// No description provided for @post_viewHiddenInfo.
  ///
  /// In zh, this message translates to:
  /// **'查看隐藏的信息'**
  String get post_viewHiddenInfo;

  /// No description provided for @post_whisperIndicator.
  ///
  /// In zh, this message translates to:
  /// **'仅管理员可见'**
  String get post_whisperIndicator;

  /// No description provided for @smallAction_archivedDisabled.
  ///
  /// In zh, this message translates to:
  /// **'取消归档了话题'**
  String get smallAction_archivedDisabled;

  /// No description provided for @smallAction_archivedEnabled.
  ///
  /// In zh, this message translates to:
  /// **'归档了话题'**
  String get smallAction_archivedEnabled;

  /// No description provided for @smallAction_autobumped.
  ///
  /// In zh, this message translates to:
  /// **'自动顶帖'**
  String get smallAction_autobumped;

  /// No description provided for @smallAction_autoclosedDisabled.
  ///
  /// In zh, this message translates to:
  /// **'话题被自动打开'**
  String get smallAction_autoclosedDisabled;

  /// No description provided for @smallAction_autoclosedEnabled.
  ///
  /// In zh, this message translates to:
  /// **'话题被自动关闭'**
  String get smallAction_autoclosedEnabled;

  /// No description provided for @smallAction_bannerDisabled.
  ///
  /// In zh, this message translates to:
  /// **'移除了横幅'**
  String get smallAction_bannerDisabled;

  /// No description provided for @smallAction_bannerEnabled.
  ///
  /// In zh, this message translates to:
  /// **'将话题设为横幅'**
  String get smallAction_bannerEnabled;

  /// No description provided for @smallAction_categoryChanged.
  ///
  /// In zh, this message translates to:
  /// **'更新了类别'**
  String get smallAction_categoryChanged;

  /// No description provided for @smallAction_closedDisabled.
  ///
  /// In zh, this message translates to:
  /// **'打开了话题'**
  String get smallAction_closedDisabled;

  /// No description provided for @smallAction_closedEnabled.
  ///
  /// In zh, this message translates to:
  /// **'关闭了话题'**
  String get smallAction_closedEnabled;

  /// No description provided for @smallAction_forwarded.
  ///
  /// In zh, this message translates to:
  /// **'转发了邮件'**
  String get smallAction_forwarded;

  /// No description provided for @smallAction_invitedGroup.
  ///
  /// In zh, this message translates to:
  /// **'邀请了'**
  String get smallAction_invitedGroup;

  /// No description provided for @smallAction_invitedUser.
  ///
  /// In zh, this message translates to:
  /// **'邀请了'**
  String get smallAction_invitedUser;

  /// No description provided for @smallAction_openTopic.
  ///
  /// In zh, this message translates to:
  /// **'转换为话题'**
  String get smallAction_openTopic;

  /// No description provided for @smallAction_pinnedDisabled.
  ///
  /// In zh, this message translates to:
  /// **'取消置顶了话题'**
  String get smallAction_pinnedDisabled;

  /// No description provided for @smallAction_pinnedEnabled.
  ///
  /// In zh, this message translates to:
  /// **'置顶了话题'**
  String get smallAction_pinnedEnabled;

  /// No description provided for @smallAction_pinnedGloballyDisabled.
  ///
  /// In zh, this message translates to:
  /// **'取消全站置顶'**
  String get smallAction_pinnedGloballyDisabled;

  /// No description provided for @smallAction_pinnedGloballyEnabled.
  ///
  /// In zh, this message translates to:
  /// **'全站置顶了话题'**
  String get smallAction_pinnedGloballyEnabled;

  /// No description provided for @smallAction_privateTopic.
  ///
  /// In zh, this message translates to:
  /// **'转换为私信'**
  String get smallAction_privateTopic;

  /// No description provided for @smallAction_publicTopic.
  ///
  /// In zh, this message translates to:
  /// **'转换为公开话题'**
  String get smallAction_publicTopic;

  /// No description provided for @smallAction_removedGroup.
  ///
  /// In zh, this message translates to:
  /// **'移除了'**
  String get smallAction_removedGroup;

  /// No description provided for @smallAction_removedUser.
  ///
  /// In zh, this message translates to:
  /// **'移除了'**
  String get smallAction_removedUser;

  /// No description provided for @smallAction_splitTopic.
  ///
  /// In zh, this message translates to:
  /// **'拆分了话题'**
  String get smallAction_splitTopic;

  /// No description provided for @smallAction_tagsChanged.
  ///
  /// In zh, this message translates to:
  /// **'更新了标签'**
  String get smallAction_tagsChanged;

  /// No description provided for @smallAction_userLeft.
  ///
  /// In zh, this message translates to:
  /// **'离开了对话'**
  String get smallAction_userLeft;

  /// No description provided for @smallAction_visibleDisabled.
  ///
  /// In zh, this message translates to:
  /// **'取消公开了话题'**
  String get smallAction_visibleDisabled;

  /// No description provided for @smallAction_visibleEnabled.
  ///
  /// In zh, this message translates to:
  /// **'公开了话题'**
  String get smallAction_visibleEnabled;

  /// No description provided for @vote_cancelled.
  ///
  /// In zh, this message translates to:
  /// **'已取消投票'**
  String get vote_cancelled;

  /// No description provided for @vote_closed.
  ///
  /// In zh, this message translates to:
  /// **'已关闭'**
  String get vote_closed;

  /// No description provided for @vote_label.
  ///
  /// In zh, this message translates to:
  /// **'投票'**
  String get vote_label;

  /// No description provided for @vote_pleaseLogin.
  ///
  /// In zh, this message translates to:
  /// **'请先登录'**
  String get vote_pleaseLogin;

  /// No description provided for @vote_success.
  ///
  /// In zh, this message translates to:
  /// **'投票成功'**
  String get vote_success;

  /// No description provided for @vote_successNoRemaining.
  ///
  /// In zh, this message translates to:
  /// **'投票成功，您的投票已用完'**
  String get vote_successNoRemaining;

  /// No description provided for @vote_successRemaining.
  ///
  /// In zh, this message translates to:
  /// **'投票成功，剩余 {remaining} 票'**
  String vote_successRemaining(int remaining);

  /// No description provided for @vote_topicClosed.
  ///
  /// In zh, this message translates to:
  /// **'话题已关闭，无法投票'**
  String get vote_topicClosed;

  /// No description provided for @vote_voted.
  ///
  /// In zh, this message translates to:
  /// **'已投票'**
  String get vote_voted;

  /// No description provided for @preheat_logoutConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定要退出当前账号吗？退出后将清除本地登录信息。'**
  String get preheat_logoutConfirm;

  /// No description provided for @preheat_logoutMessage.
  ///
  /// In zh, this message translates to:
  /// **'用户主动退出登录（预热失败页面）'**
  String get preheat_logoutMessage;

  /// No description provided for @preheat_networkSettings.
  ///
  /// In zh, this message translates to:
  /// **'网络设置'**
  String get preheat_networkSettings;

  /// No description provided for @preheat_retryConnection.
  ///
  /// In zh, this message translates to:
  /// **'重试连接'**
  String get preheat_retryConnection;

  /// No description provided for @preheat_userSkipped.
  ///
  /// In zh, this message translates to:
  /// **'用户跳过预加载'**
  String get preheat_userSkipped;

  /// No description provided for @table_rowCount.
  ///
  /// In zh, this message translates to:
  /// **'共 {count} 行'**
  String table_rowCount(int count);

  /// No description provided for @httpProxy_auth.
  ///
  /// In zh, this message translates to:
  /// **'认证'**
  String get httpProxy_auth;

  /// No description provided for @httpProxy_base64PskHint.
  ///
  /// In zh, this message translates to:
  /// **'请输入 Base64 编码后的 32 字节预共享密钥'**
  String get httpProxy_base64PskHint;

  /// No description provided for @httpProxy_cipher.
  ///
  /// In zh, this message translates to:
  /// **'加密算法'**
  String get httpProxy_cipher;

  /// No description provided for @httpProxy_cipherNotSet.
  ///
  /// In zh, this message translates to:
  /// **'未设置算法'**
  String get httpProxy_cipherNotSet;

  /// No description provided for @httpProxy_configTitle.
  ///
  /// In zh, this message translates to:
  /// **'配置上游代理'**
  String get httpProxy_configTitle;

  /// No description provided for @httpProxy_disabledDesc.
  ///
  /// In zh, this message translates to:
  /// **'为本地网关配置远端 HTTP / SOCKS5 / Shadowsocks 代理'**
  String get httpProxy_disabledDesc;

  /// No description provided for @httpProxy_disabledHint.
  ///
  /// In zh, this message translates to:
  /// **'开启后会保留代理模式开关，由本地网关统一接管 Dio、WebView 和 Shadowsocks 出口'**
  String get httpProxy_disabledHint;

  /// No description provided for @httpProxy_dohProxyHint.
  ///
  /// In zh, this message translates to:
  /// **'当前会通过本地 DoH 网关转发到上游代理；关闭 DoH 时会切换为纯代理转发'**
  String get httpProxy_dohProxyHint;

  /// No description provided for @httpProxy_enabledDesc.
  ///
  /// In zh, this message translates to:
  /// **'已启用 {protocol} 上游代理，由本地网关统一转发'**
  String httpProxy_enabledDesc(String protocol);

  /// No description provided for @httpProxy_fillServerAndPort.
  ///
  /// In zh, this message translates to:
  /// **'请填写服务器地址和端口'**
  String get httpProxy_fillServerAndPort;

  /// No description provided for @httpProxy_importSsLink.
  ///
  /// In zh, this message translates to:
  /// **'导入 ss:// 链接'**
  String get httpProxy_importSsLink;

  /// No description provided for @httpProxy_importedNode.
  ///
  /// In zh, this message translates to:
  /// **'已导入节点：{remarks}'**
  String httpProxy_importedNode(String remarks);

  /// No description provided for @httpProxy_keyBase64Psk.
  ///
  /// In zh, this message translates to:
  /// **'密钥（Base64 PSK）'**
  String get httpProxy_keyBase64Psk;

  /// No description provided for @httpProxy_password.
  ///
  /// In zh, this message translates to:
  /// **'密码'**
  String get httpProxy_password;

  /// No description provided for @httpProxy_port.
  ///
  /// In zh, this message translates to:
  /// **'端口'**
  String get httpProxy_port;

  /// No description provided for @httpProxy_portHint.
  ///
  /// In zh, this message translates to:
  /// **'例如：8080 或 1080'**
  String get httpProxy_portHint;

  /// No description provided for @httpProxy_portInvalid.
  ///
  /// In zh, this message translates to:
  /// **'端口无效'**
  String get httpProxy_portInvalid;

  /// No description provided for @httpProxy_protocol.
  ///
  /// In zh, this message translates to:
  /// **'协议'**
  String get httpProxy_protocol;

  /// No description provided for @httpProxy_proxyAutoTest.
  ///
  /// In zh, this message translates to:
  /// **'保存后会自动测试，也可以手动重新测试'**
  String get httpProxy_proxyAutoTest;

  /// No description provided for @httpProxy_requireAuth.
  ///
  /// In zh, this message translates to:
  /// **'需要认证'**
  String get httpProxy_requireAuth;

  /// No description provided for @httpProxy_selectSsCipher.
  ///
  /// In zh, this message translates to:
  /// **'请选择受支持的 Shadowsocks 加密算法'**
  String get httpProxy_selectSsCipher;

  /// No description provided for @httpProxy_server.
  ///
  /// In zh, this message translates to:
  /// **'上游代理服务器'**
  String get httpProxy_server;

  /// No description provided for @httpProxy_serverAddress.
  ///
  /// In zh, this message translates to:
  /// **'服务器地址'**
  String get httpProxy_serverAddress;

  /// No description provided for @httpProxy_serverAddressHint.
  ///
  /// In zh, this message translates to:
  /// **'例如：192.168.1.1 或 proxy.example.com'**
  String get httpProxy_serverAddressHint;

  /// No description provided for @httpProxy_ssConfigSaved.
  ///
  /// In zh, this message translates to:
  /// **'保存后会校验 Shadowsocks 配置，并建议返回首页做实际访问验证'**
  String get httpProxy_ssConfigSaved;

  /// No description provided for @httpProxy_ssImportSuccess.
  ///
  /// In zh, this message translates to:
  /// **'Shadowsocks 链接导入成功'**
  String get httpProxy_ssImportSuccess;

  /// No description provided for @httpProxy_ssLink.
  ///
  /// In zh, this message translates to:
  /// **'Shadowsocks 链接'**
  String get httpProxy_ssLink;

  /// No description provided for @httpProxy_suppressedByVpn.
  ///
  /// In zh, this message translates to:
  /// **'已被 VPN 自动关闭，VPN 断开后将自动恢复'**
  String get httpProxy_suppressedByVpn;

  /// No description provided for @httpProxy_testAvailability.
  ///
  /// In zh, this message translates to:
  /// **'测试代理可用性'**
  String get httpProxy_testAvailability;

  /// No description provided for @httpProxy_testingProxy.
  ///
  /// In zh, this message translates to:
  /// **'正在验证是否能通过当前代理访问 linux.do'**
  String get httpProxy_testingProxy;

  /// No description provided for @httpProxy_testingSsConfig.
  ///
  /// In zh, this message translates to:
  /// **'正在校验 Shadowsocks 配置是否可由本地网关接管'**
  String get httpProxy_testingSsConfig;

  /// No description provided for @httpProxy_title.
  ///
  /// In zh, this message translates to:
  /// **'上游代理'**
  String get httpProxy_title;

  /// No description provided for @httpProxy_username.
  ///
  /// In zh, this message translates to:
  /// **'用户名: {username}'**
  String httpProxy_username(String username);

  /// No description provided for @httpProxy_usernameLabel.
  ///
  /// In zh, this message translates to:
  /// **'用户名'**
  String get httpProxy_usernameLabel;

  /// No description provided for @proxy_cannotConnect.
  ///
  /// In zh, this message translates to:
  /// **'无法连接代理服务器'**
  String get proxy_cannotConnect;

  /// No description provided for @proxy_connectionClosed.
  ///
  /// In zh, this message translates to:
  /// **'连接已被远端关闭'**
  String get proxy_connectionClosed;

  /// No description provided for @proxy_fillAddressPort.
  ///
  /// In zh, this message translates to:
  /// **'请先填写代理地址和端口'**
  String get proxy_fillAddressPort;

  /// No description provided for @proxy_httpAuthFailed.
  ///
  /// In zh, this message translates to:
  /// **'HTTP 代理认证失败（407）'**
  String get proxy_httpAuthFailed;

  /// No description provided for @proxy_httpConnectFailed.
  ///
  /// In zh, this message translates to:
  /// **'HTTP 代理 CONNECT 失败：{statusLine}'**
  String proxy_httpConnectFailed(String statusLine);

  /// No description provided for @proxy_notConfigured.
  ///
  /// In zh, this message translates to:
  /// **'未配置代理服务器'**
  String get proxy_notConfigured;

  /// No description provided for @proxy_responseTimeout.
  ///
  /// In zh, this message translates to:
  /// **'等待代理响应超时'**
  String get proxy_responseTimeout;

  /// No description provided for @proxy_socks5AddrTypeNotSupported.
  ///
  /// In zh, this message translates to:
  /// **'地址类型不支持'**
  String get proxy_socks5AddrTypeNotSupported;

  /// No description provided for @proxy_socks5AuthFailed.
  ///
  /// In zh, this message translates to:
  /// **'SOCKS5 认证失败'**
  String get proxy_socks5AuthFailed;

  /// No description provided for @proxy_socks5AuthRejected.
  ///
  /// In zh, this message translates to:
  /// **'SOCKS5 不接受当前认证方式'**
  String get proxy_socks5AuthRejected;

  /// No description provided for @proxy_socks5CommandNotSupported.
  ///
  /// In zh, this message translates to:
  /// **'命令不支持'**
  String get proxy_socks5CommandNotSupported;

  /// No description provided for @proxy_socks5ConnectFailed.
  ///
  /// In zh, this message translates to:
  /// **'SOCKS5 CONNECT 失败：{reply}'**
  String proxy_socks5ConnectFailed(String reply);

  /// No description provided for @proxy_socks5ConnectInvalidVersion.
  ///
  /// In zh, this message translates to:
  /// **'SOCKS5 CONNECT 响应版本无效'**
  String get proxy_socks5ConnectInvalidVersion;

  /// No description provided for @proxy_socks5ConnectionRefused.
  ///
  /// In zh, this message translates to:
  /// **'目标拒绝连接'**
  String get proxy_socks5ConnectionRefused;

  /// No description provided for @proxy_socks5CredentialsTooLong.
  ///
  /// In zh, this message translates to:
  /// **'SOCKS5 用户名或密码过长'**
  String get proxy_socks5CredentialsTooLong;

  /// No description provided for @proxy_socks5GeneralFailure.
  ///
  /// In zh, this message translates to:
  /// **'普通失败'**
  String get proxy_socks5GeneralFailure;

  /// No description provided for @proxy_socks5HostUnreachable.
  ///
  /// In zh, this message translates to:
  /// **'主机不可达'**
  String get proxy_socks5HostUnreachable;

  /// No description provided for @proxy_socks5HostnameTooLong.
  ///
  /// In zh, this message translates to:
  /// **'SOCKS5 目标主机名过长'**
  String get proxy_socks5HostnameTooLong;

  /// No description provided for @proxy_socks5InvalidVersion.
  ///
  /// In zh, this message translates to:
  /// **'SOCKS5 响应版本无效'**
  String get proxy_socks5InvalidVersion;

  /// No description provided for @proxy_socks5NetworkUnreachable.
  ///
  /// In zh, this message translates to:
  /// **'网络不可达'**
  String get proxy_socks5NetworkUnreachable;

  /// No description provided for @proxy_socks5NotAllowed.
  ///
  /// In zh, this message translates to:
  /// **'规则不允许'**
  String get proxy_socks5NotAllowed;

  /// No description provided for @proxy_socks5TtlExpired.
  ///
  /// In zh, this message translates to:
  /// **'TTL 已过期'**
  String get proxy_socks5TtlExpired;

  /// No description provided for @proxy_socks5UnknownAddrType.
  ///
  /// In zh, this message translates to:
  /// **'SOCKS5 返回了未知地址类型：0x{hex}'**
  String proxy_socks5UnknownAddrType(String hex);

  /// No description provided for @proxy_socks5UnknownError.
  ///
  /// In zh, this message translates to:
  /// **'未知错误（0x{hex}）'**
  String proxy_socks5UnknownError(String hex);

  /// No description provided for @proxy_socks5UnsupportedAuth.
  ///
  /// In zh, this message translates to:
  /// **'SOCKS5 返回了不支持的认证方式：0x{hex}'**
  String proxy_socks5UnsupportedAuth(String hex);

  /// No description provided for @proxy_ss2022KeyHint.
  ///
  /// In zh, this message translates to:
  /// **'请填写 Shadowsocks 2022 的密钥（Base64 PSK）'**
  String get proxy_ss2022KeyHint;

  /// No description provided for @proxy_ss2022KeyInvalidBase64.
  ///
  /// In zh, this message translates to:
  /// **'Shadowsocks 2022 密钥必须是有效的 Base64 字符串'**
  String get proxy_ss2022KeyInvalidBase64;

  /// No description provided for @proxy_ss2022KeyInvalidLength.
  ///
  /// In zh, this message translates to:
  /// **'Shadowsocks 2022 密钥长度无效：解码后必须为 {length} 字节'**
  String proxy_ss2022KeyInvalidLength(int length);

  /// No description provided for @proxy_ssBase64DecodeFailed.
  ///
  /// In zh, this message translates to:
  /// **'ss:// 链接 Base64 解码失败'**
  String get proxy_ssBase64DecodeFailed;

  /// No description provided for @proxy_ssCannotParseCipher.
  ///
  /// In zh, this message translates to:
  /// **'无法解析加密算法和密码'**
  String get proxy_ssCannotParseCipher;

  /// No description provided for @proxy_ssIncomplete.
  ///
  /// In zh, this message translates to:
  /// **'Shadowsocks 配置不完整'**
  String get proxy_ssIncomplete;

  /// No description provided for @proxy_ssInvalidIpv6.
  ///
  /// In zh, this message translates to:
  /// **'IPv6 地址格式无效'**
  String get proxy_ssInvalidIpv6;

  /// No description provided for @proxy_ssInvalidPort.
  ///
  /// In zh, this message translates to:
  /// **'端口无效'**
  String get proxy_ssInvalidPort;

  /// No description provided for @proxy_ssLinkContentEmpty.
  ///
  /// In zh, this message translates to:
  /// **'ss:// 链接内容为空'**
  String get proxy_ssLinkContentEmpty;

  /// No description provided for @proxy_ssLinkEmpty.
  ///
  /// In zh, this message translates to:
  /// **'链接不能为空'**
  String get proxy_ssLinkEmpty;

  /// No description provided for @proxy_ssMissingAddress.
  ///
  /// In zh, this message translates to:
  /// **'缺少服务器地址'**
  String get proxy_ssMissingAddress;

  /// No description provided for @proxy_ssMissingPort.
  ///
  /// In zh, this message translates to:
  /// **'缺少端口'**
  String get proxy_ssMissingPort;

  /// No description provided for @proxy_ssOnlySsProtocol.
  ///
  /// In zh, this message translates to:
  /// **'仅支持 ss:// 链接'**
  String get proxy_ssOnlySsProtocol;

  /// No description provided for @proxy_ssPasswordHint.
  ///
  /// In zh, this message translates to:
  /// **'请填写 Shadowsocks 密码'**
  String get proxy_ssPasswordHint;

  /// No description provided for @proxy_ssSaved.
  ///
  /// In zh, this message translates to:
  /// **'Shadowsocks 配置已保存'**
  String get proxy_ssSaved;

  /// No description provided for @proxy_ssSavedDetail.
  ///
  /// In zh, this message translates to:
  /// **'当前版本会通过本地网关接管 Shadowsocks 出站；请启用代理后返回首页进行实际访问验证'**
  String get proxy_ssSavedDetail;

  /// No description provided for @proxy_ssSelectCipher.
  ///
  /// In zh, this message translates to:
  /// **'请选择受支持的 Shadowsocks 加密算法'**
  String get proxy_ssSelectCipher;

  /// No description provided for @proxy_ssUnsupportedCipher.
  ///
  /// In zh, this message translates to:
  /// **'当前版本仅支持 {ciphers}'**
  String proxy_ssUnsupportedCipher(String ciphers);

  /// No description provided for @proxy_targetResponseError.
  ///
  /// In zh, this message translates to:
  /// **'目标站点响应异常：{statusLine}'**
  String proxy_targetResponseError(String statusLine);

  /// No description provided for @proxy_testFailed.
  ///
  /// In zh, this message translates to:
  /// **'代理测试失败'**
  String get proxy_testFailed;

  /// No description provided for @proxy_testSuccess.
  ///
  /// In zh, this message translates to:
  /// **'代理可用'**
  String get proxy_testSuccess;

  /// No description provided for @proxy_testSuccessDetail.
  ///
  /// In zh, this message translates to:
  /// **'已通过 {protocol} 代理访问 {host}，HTTP {statusCode}'**
  String proxy_testSuccessDetail(String protocol, String host, int statusCode);

  /// No description provided for @proxy_testTimeout.
  ///
  /// In zh, this message translates to:
  /// **'代理测试超时'**
  String get proxy_testTimeout;

  /// No description provided for @proxy_testTimeoutDetail.
  ///
  /// In zh, this message translates to:
  /// **'连接或握手超过 {seconds} 秒，未能完成 {host} 可用性验证'**
  String proxy_testTimeoutDetail(int seconds, String host);

  /// No description provided for @proxy_testTlsFailed.
  ///
  /// In zh, this message translates to:
  /// **'TLS 握手失败'**
  String get proxy_testTlsFailed;

  /// No description provided for @vpnToggle_and.
  ///
  /// In zh, this message translates to:
  /// **' 和 '**
  String get vpnToggle_and;

  /// No description provided for @vpnToggle_connected.
  ///
  /// In zh, this message translates to:
  /// **'VPN 已连接'**
  String get vpnToggle_connected;

  /// No description provided for @vpnToggle_disconnected.
  ///
  /// In zh, this message translates to:
  /// **'VPN 未连接'**
  String get vpnToggle_disconnected;

  /// No description provided for @vpnToggle_subtitle.
  ///
  /// In zh, this message translates to:
  /// **'检测到 VPN 时自动关闭 DOH 和代理，断开后恢复'**
  String get vpnToggle_subtitle;

  /// No description provided for @vpnToggle_suppressedSuffix.
  ///
  /// In zh, this message translates to:
  /// **'已被自动关闭，VPN 断开后将自动恢复'**
  String get vpnToggle_suppressedSuffix;

  /// No description provided for @vpnToggle_title.
  ///
  /// In zh, this message translates to:
  /// **'VPN 自动切换'**
  String get vpnToggle_title;

  /// No description provided for @vpnToggle_upstreamProxy.
  ///
  /// In zh, this message translates to:
  /// **'上游代理'**
  String get vpnToggle_upstreamProxy;

  /// No description provided for @cdk_balance.
  ///
  /// In zh, this message translates to:
  /// **'CDK 积分'**
  String get cdk_balance;

  /// No description provided for @cdk_points.
  ///
  /// In zh, this message translates to:
  /// **'积分'**
  String get cdk_points;

  /// No description provided for @cdk_reAuthHint.
  ///
  /// In zh, this message translates to:
  /// **'请重新授权以查看积分'**
  String get cdk_reAuthHint;

  /// No description provided for @ldc_balance.
  ///
  /// In zh, this message translates to:
  /// **'LDC 余额'**
  String get ldc_balance;

  /// No description provided for @ldc_dailyIncome.
  ///
  /// In zh, this message translates to:
  /// **'今日收入 {amount}'**
  String ldc_dailyIncome(String amount);

  /// No description provided for @ldc_reAuthHint.
  ///
  /// In zh, this message translates to:
  /// **'请重新授权以查看余额'**
  String get ldc_reAuthHint;

  /// No description provided for @reward_authFailed.
  ///
  /// In zh, this message translates to:
  /// **'认证失败，请检查 Client ID 和 Client Secret'**
  String get reward_authFailed;

  /// No description provided for @reward_clearCredential.
  ///
  /// In zh, this message translates to:
  /// **'清除凭证'**
  String get reward_clearCredential;

  /// No description provided for @reward_configDialogTitle.
  ///
  /// In zh, this message translates to:
  /// **'配置 LDC 打赏凭证'**
  String get reward_configDialogTitle;

  /// No description provided for @reward_configHint.
  ///
  /// In zh, this message translates to:
  /// **'请输入在 credit.linux.do 申请的凭证'**
  String get reward_configHint;

  /// No description provided for @reward_configured.
  ///
  /// In zh, this message translates to:
  /// **'已配置，可在帖子中打赏'**
  String get reward_configured;

  /// No description provided for @reward_confirmMessage.
  ///
  /// In zh, this message translates to:
  /// **'确定向 {target} 打赏 {amount} LDC 吗？'**
  String reward_confirmMessage(String target, int amount);

  /// No description provided for @reward_confirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认打赏'**
  String get reward_confirmTitle;

  /// No description provided for @reward_createApp.
  ///
  /// In zh, this message translates to:
  /// **'创建应用'**
  String get reward_createApp;

  /// No description provided for @reward_customAmount.
  ///
  /// In zh, this message translates to:
  /// **'自定义金额'**
  String get reward_customAmount;

  /// No description provided for @reward_defaultError.
  ///
  /// In zh, this message translates to:
  /// **'打赏失败'**
  String get reward_defaultError;

  /// No description provided for @reward_duplicateWarning.
  ///
  /// In zh, this message translates to:
  /// **'请勿重复打赏，{remaining}秒后可再次操作'**
  String reward_duplicateWarning(int remaining);

  /// No description provided for @reward_goToCreateApp.
  ///
  /// In zh, this message translates to:
  /// **'前往创建应用 →'**
  String get reward_goToCreateApp;

  /// No description provided for @reward_httpError.
  ///
  /// In zh, this message translates to:
  /// **'请求失败: HTTP {statusCode}'**
  String reward_httpError(int statusCode);

  /// No description provided for @reward_networkError.
  ///
  /// In zh, this message translates to:
  /// **'网络错误: {error}'**
  String reward_networkError(String error);

  /// No description provided for @reward_notConfigured.
  ///
  /// In zh, this message translates to:
  /// **'配置凭证以启用打赏功能'**
  String get reward_notConfigured;

  /// No description provided for @reward_noteHint.
  ///
  /// In zh, this message translates to:
  /// **'感谢分享！'**
  String get reward_noteHint;

  /// No description provided for @reward_noteLabel.
  ///
  /// In zh, this message translates to:
  /// **'备注（可选）'**
  String get reward_noteLabel;

  /// No description provided for @reward_selectAmount.
  ///
  /// In zh, this message translates to:
  /// **'选择金额'**
  String get reward_selectAmount;

  /// No description provided for @reward_selectOrInputAmount.
  ///
  /// In zh, this message translates to:
  /// **'请选择或输入金额'**
  String get reward_selectOrInputAmount;

  /// No description provided for @reward_sheetTitle.
  ///
  /// In zh, this message translates to:
  /// **'打赏 LDC'**
  String get reward_sheetTitle;

  /// No description provided for @reward_submitWithAmount.
  ///
  /// In zh, this message translates to:
  /// **'打赏 {amount} LDC'**
  String reward_submitWithAmount(int amount);

  /// No description provided for @reward_title.
  ///
  /// In zh, this message translates to:
  /// **'LDC 打赏'**
  String get reward_title;

  /// No description provided for @reward_unknownError.
  ///
  /// In zh, this message translates to:
  /// **'未知错误: {error}'**
  String reward_unknownError(String error);

  /// No description provided for @search_advancedSearch.
  ///
  /// In zh, this message translates to:
  /// **'高级搜索'**
  String get search_advancedSearch;

  /// No description provided for @search_afterDate.
  ///
  /// In zh, this message translates to:
  /// **'{date} 之后'**
  String search_afterDate(String date);

  /// No description provided for @search_applyFilter.
  ///
  /// In zh, this message translates to:
  /// **'应用筛选'**
  String get search_applyFilter;

  /// No description provided for @search_beforeDate.
  ///
  /// In zh, this message translates to:
  /// **'{date} 之前'**
  String search_beforeDate(String date);

  /// No description provided for @search_category.
  ///
  /// In zh, this message translates to:
  /// **'分类'**
  String get search_category;

  /// No description provided for @search_categoryLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载分类失败: {error}'**
  String search_categoryLoadFailed(String error);

  /// No description provided for @search_clearAll.
  ///
  /// In zh, this message translates to:
  /// **'清除全部'**
  String get search_clearAll;

  /// No description provided for @search_currentFilter.
  ///
  /// In zh, this message translates to:
  /// **'当前筛选'**
  String get search_currentFilter;

  /// No description provided for @search_custom.
  ///
  /// In zh, this message translates to:
  /// **'自定义'**
  String get search_custom;

  /// No description provided for @search_dateRange.
  ///
  /// In zh, this message translates to:
  /// **'时间范围'**
  String get search_dateRange;

  /// No description provided for @search_emptyHint.
  ///
  /// In zh, this message translates to:
  /// **'输入关键词搜索'**
  String get search_emptyHint;

  /// No description provided for @search_error.
  ///
  /// In zh, this message translates to:
  /// **'搜索出错'**
  String get search_error;

  /// No description provided for @search_filterBookmarks.
  ///
  /// In zh, this message translates to:
  /// **'书签'**
  String get search_filterBookmarks;

  /// No description provided for @search_filterCreated.
  ///
  /// In zh, this message translates to:
  /// **'我的话题'**
  String get search_filterCreated;

  /// No description provided for @search_filterSeen.
  ///
  /// In zh, this message translates to:
  /// **'浏览历史'**
  String get search_filterSeen;

  /// No description provided for @search_hintText.
  ///
  /// In zh, this message translates to:
  /// **'搜索 @用户 #分类 tags:标签'**
  String get search_hintText;

  /// No description provided for @search_lastMonth.
  ///
  /// In zh, this message translates to:
  /// **'最近一月'**
  String get search_lastMonth;

  /// No description provided for @search_lastWeek.
  ///
  /// In zh, this message translates to:
  /// **'最近一周'**
  String get search_lastWeek;

  /// No description provided for @search_lastYear.
  ///
  /// In zh, this message translates to:
  /// **'最近一年'**
  String get search_lastYear;

  /// No description provided for @search_likeCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 点赞'**
  String search_likeCount(String count);

  /// No description provided for @search_noLimit.
  ///
  /// In zh, this message translates to:
  /// **'不限'**
  String get search_noLimit;

  /// No description provided for @search_noPopularTags.
  ///
  /// In zh, this message translates to:
  /// **'暂无热门标签'**
  String get search_noPopularTags;

  /// No description provided for @search_noResults.
  ///
  /// In zh, this message translates to:
  /// **'没有找到相关结果'**
  String get search_noResults;

  /// No description provided for @search_popularTags.
  ///
  /// In zh, this message translates to:
  /// **'热门标签'**
  String get search_popularTags;

  /// No description provided for @search_recentSearches.
  ///
  /// In zh, this message translates to:
  /// **'最近搜索'**
  String get search_recentSearches;

  /// No description provided for @search_replyCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 条回复'**
  String search_replyCount(int count);

  /// No description provided for @search_resultCount.
  ///
  /// In zh, this message translates to:
  /// **'{count}{more} 条结果'**
  String search_resultCount(int count, String more);

  /// No description provided for @search_selectDateRange.
  ///
  /// In zh, this message translates to:
  /// **'选择时间范围'**
  String get search_selectDateRange;

  /// No description provided for @search_selectedTags.
  ///
  /// In zh, this message translates to:
  /// **'已选标签'**
  String get search_selectedTags;

  /// No description provided for @search_sortLabel.
  ///
  /// In zh, this message translates to:
  /// **'排序：'**
  String get search_sortLabel;

  /// No description provided for @search_sortLatest.
  ///
  /// In zh, this message translates to:
  /// **'最新帖子'**
  String get search_sortLatest;

  /// No description provided for @search_sortLatestTopic.
  ///
  /// In zh, this message translates to:
  /// **'最新话题'**
  String get search_sortLatestTopic;

  /// No description provided for @search_sortLikes.
  ///
  /// In zh, this message translates to:
  /// **'最受欢迎'**
  String get search_sortLikes;

  /// No description provided for @search_sortRelevance.
  ///
  /// In zh, this message translates to:
  /// **'相关性'**
  String get search_sortRelevance;

  /// No description provided for @search_sortViews.
  ///
  /// In zh, this message translates to:
  /// **'最多浏览'**
  String get search_sortViews;

  /// No description provided for @search_status.
  ///
  /// In zh, this message translates to:
  /// **'状态'**
  String get search_status;

  /// No description provided for @search_statusArchived.
  ///
  /// In zh, this message translates to:
  /// **'已归档'**
  String get search_statusArchived;

  /// No description provided for @search_statusClosed.
  ///
  /// In zh, this message translates to:
  /// **'已关闭'**
  String get search_statusClosed;

  /// No description provided for @search_statusOpen.
  ///
  /// In zh, this message translates to:
  /// **'进行中'**
  String get search_statusOpen;

  /// No description provided for @search_statusSolved.
  ///
  /// In zh, this message translates to:
  /// **'已解决'**
  String get search_statusSolved;

  /// No description provided for @search_statusUnsolved.
  ///
  /// In zh, this message translates to:
  /// **'未解决'**
  String get search_statusUnsolved;

  /// No description provided for @search_tags.
  ///
  /// In zh, this message translates to:
  /// **'标签'**
  String get search_tags;

  /// No description provided for @search_tagsLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载标签失败: {error}'**
  String search_tagsLoadFailed(String error);

  /// No description provided for @search_topicSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'输入关键词搜索本话题'**
  String get search_topicSearchHint;

  /// No description provided for @search_tryOtherKeywords.
  ///
  /// In zh, this message translates to:
  /// **'请尝试其他关键词'**
  String get search_tryOtherKeywords;

  /// No description provided for @search_users.
  ///
  /// In zh, this message translates to:
  /// **'用户'**
  String get search_users;

  /// No description provided for @search_viewCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 浏览'**
  String search_viewCount(String count);

  /// No description provided for @cfVerify_cooldown.
  ///
  /// In zh, this message translates to:
  /// **'验证太频繁，请稍后再试'**
  String get cfVerify_cooldown;

  /// No description provided for @cfVerify_desc.
  ///
  /// In zh, this message translates to:
  /// **'手动触发过盾验证'**
  String get cfVerify_desc;

  /// No description provided for @cfVerify_failed.
  ///
  /// In zh, this message translates to:
  /// **'验证未通过'**
  String get cfVerify_failed;

  /// No description provided for @cfVerify_success.
  ///
  /// In zh, this message translates to:
  /// **'验证成功'**
  String get cfVerify_success;

  /// No description provided for @cfVerify_title.
  ///
  /// In zh, this message translates to:
  /// **'Cloudflare 验证'**
  String get cfVerify_title;

  /// No description provided for @cf_abandonVerifyMessage.
  ///
  /// In zh, this message translates to:
  /// **'退出验证将导致相关功能无法使用，确定要退出吗？'**
  String get cf_abandonVerifyMessage;

  /// No description provided for @cf_abandonVerifyTitle.
  ///
  /// In zh, this message translates to:
  /// **'放弃验证？'**
  String get cf_abandonVerifyTitle;

  /// No description provided for @cf_autoVerifyTimeout.
  ///
  /// In zh, this message translates to:
  /// **'自动验证超时，请手动完成验证'**
  String get cf_autoVerifyTimeout;

  /// No description provided for @cf_backgroundVerifying.
  ///
  /// In zh, this message translates to:
  /// **'后台验证中... (点击打开)'**
  String get cf_backgroundVerifying;

  /// No description provided for @cf_cannotOpenVerifyPage.
  ///
  /// In zh, this message translates to:
  /// **'无法打开验证页面，请稍后重试'**
  String get cf_cannotOpenVerifyPage;

  /// No description provided for @cf_challengeFailedCooldown.
  ///
  /// In zh, this message translates to:
  /// **'安全验证失败，已进入冷却期，请稍后再试'**
  String get cf_challengeFailedCooldown;

  /// No description provided for @cf_challengeNotEffective.
  ///
  /// In zh, this message translates to:
  /// **'验证未生效，请稍后重试'**
  String get cf_challengeNotEffective;

  /// No description provided for @cf_continueVerify.
  ///
  /// In zh, this message translates to:
  /// **'继续验证'**
  String get cf_continueVerify;

  /// No description provided for @cf_cooldown.
  ///
  /// In zh, this message translates to:
  /// **'请稍后再试'**
  String get cf_cooldown;

  /// No description provided for @cf_failedRetry.
  ///
  /// In zh, this message translates to:
  /// **'安全验证失败，请重试'**
  String get cf_failedRetry;

  /// No description provided for @cf_failedWithCause.
  ///
  /// In zh, this message translates to:
  /// **'安全验证失败: {cause}'**
  String cf_failedWithCause(String cause);

  /// No description provided for @cf_helpContent.
  ///
  /// In zh, this message translates to:
  /// **'这是 Cloudflare 安全验证页面。\n\n请完成页面上的验证挑战（如勾选框或滑块）。\n\n验证成功后会自动关闭此页面。\n\n如果长时间无法完成，可以尝试：\n• 点击刷新按钮重新加载\n• 检查网络连接\n• 关闭后稍后再试'**
  String get cf_helpContent;

  /// No description provided for @cf_helpTitle.
  ///
  /// In zh, this message translates to:
  /// **'验证帮助'**
  String get cf_helpTitle;

  /// No description provided for @cf_loadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载失败: {description}'**
  String cf_loadFailed(String description);

  /// No description provided for @cf_securityVerifyTitle.
  ///
  /// In zh, this message translates to:
  /// **'安全验证'**
  String get cf_securityVerifyTitle;

  /// No description provided for @cf_userCancelled.
  ///
  /// In zh, this message translates to:
  /// **'验证已取消'**
  String get cf_userCancelled;

  /// No description provided for @cf_verifyIncomplete.
  ///
  /// In zh, this message translates to:
  /// **'验证未完成，请重试'**
  String get cf_verifyIncomplete;

  /// No description provided for @cf_verifyLonger.
  ///
  /// In zh, this message translates to:
  /// **'验证时间较长，还剩 {seconds} 秒'**
  String cf_verifyLonger(int seconds);

  /// No description provided for @cf_verifyTimeout.
  ///
  /// In zh, this message translates to:
  /// **'验证超时，请重试'**
  String get cf_verifyTimeout;

  /// No description provided for @cf_verifying.
  ///
  /// In zh, this message translates to:
  /// **'验证中... {seconds}s'**
  String cf_verifying(int seconds);

  /// No description provided for @hcaptcha_clear.
  ///
  /// In zh, this message translates to:
  /// **'清除'**
  String get hcaptcha_clear;

  /// No description provided for @hcaptcha_clearConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定要清除 hCaptcha 无障碍 Cookie 吗？'**
  String get hcaptcha_clearConfirm;

  /// No description provided for @hcaptcha_cookieCleared.
  ///
  /// In zh, this message translates to:
  /// **'hCaptcha 无障碍 Cookie 已清除'**
  String get hcaptcha_cookieCleared;

  /// No description provided for @hcaptcha_cookieNotFound.
  ///
  /// In zh, this message translates to:
  /// **'未找到 hCaptcha 无障碍 Cookie，请先完成注册'**
  String get hcaptcha_cookieNotFound;

  /// No description provided for @hcaptcha_cookieNotSet.
  ///
  /// In zh, this message translates to:
  /// **'Cookie 未设置'**
  String get hcaptcha_cookieNotSet;

  /// No description provided for @hcaptcha_cookieSaved.
  ///
  /// In zh, this message translates to:
  /// **'hCaptcha 无障碍 Cookie 已保存'**
  String get hcaptcha_cookieSaved;

  /// No description provided for @hcaptcha_cookieSet.
  ///
  /// In zh, this message translates to:
  /// **'Cookie 已设置 ✓'**
  String get hcaptcha_cookieSet;

  /// No description provided for @hcaptcha_done.
  ///
  /// In zh, this message translates to:
  /// **'完成'**
  String get hcaptcha_done;

  /// No description provided for @hcaptcha_pasteCookie.
  ///
  /// In zh, this message translates to:
  /// **'粘贴 Cookie'**
  String get hcaptcha_pasteCookie;

  /// No description provided for @hcaptcha_pasteDialogDesc.
  ///
  /// In zh, this message translates to:
  /// **'在浏览器中访问 hCaptcha 无障碍页面注册后，从浏览器开发者工具中复制名为 hc_accessibility 的 Cookie 值粘贴到下方。'**
  String get hcaptcha_pasteDialogDesc;

  /// No description provided for @hcaptcha_pasteDialogHint.
  ///
  /// In zh, this message translates to:
  /// **'请输入 hc_accessibility Cookie 值'**
  String get hcaptcha_pasteDialogHint;

  /// No description provided for @hcaptcha_pasteDialogTitle.
  ///
  /// In zh, this message translates to:
  /// **'粘贴 hCaptcha Cookie'**
  String get hcaptcha_pasteDialogTitle;

  /// No description provided for @hcaptcha_pasteLink.
  ///
  /// In zh, this message translates to:
  /// **'粘贴登录链接'**
  String get hcaptcha_pasteLink;

  /// No description provided for @hcaptcha_pasteLinkInvalid.
  ///
  /// In zh, this message translates to:
  /// **'剪贴板中没有有效的 hCaptcha 链接'**
  String get hcaptcha_pasteLinkInvalid;

  /// No description provided for @hcaptcha_subtitle.
  ///
  /// In zh, this message translates to:
  /// **'视障用户可跳过 hCaptcha 验证'**
  String get hcaptcha_subtitle;

  /// No description provided for @hcaptcha_title.
  ///
  /// In zh, this message translates to:
  /// **'hCaptcha 无障碍'**
  String get hcaptcha_title;

  /// No description provided for @hcaptcha_webviewGet.
  ///
  /// In zh, this message translates to:
  /// **'WebView 获取'**
  String get hcaptcha_webviewGet;

  /// No description provided for @hcaptcha_webviewTitle.
  ///
  /// In zh, this message translates to:
  /// **'hCaptcha 无障碍'**
  String get hcaptcha_webviewTitle;

  /// No description provided for @config_seedUserTitle.
  ///
  /// In zh, this message translates to:
  /// **'种子用户'**
  String get config_seedUserTitle;

  /// No description provided for @preferences_advanced.
  ///
  /// In zh, this message translates to:
  /// **'高级'**
  String get preferences_advanced;

  /// No description provided for @preferences_androidNativeCdp.
  ///
  /// In zh, this message translates to:
  /// **'WebView Cookie 同步'**
  String get preferences_androidNativeCdp;

  /// No description provided for @preferences_androidNativeCdpDesc.
  ///
  /// In zh, this message translates to:
  /// **'优先使用原生 CDP；异常时可关闭并回退兼容模式。'**
  String get preferences_androidNativeCdpDesc;

  /// No description provided for @preferences_anonymousShare.
  ///
  /// In zh, this message translates to:
  /// **'匿名分享'**
  String get preferences_anonymousShare;

  /// No description provided for @preferences_anonymousShareDesc.
  ///
  /// In zh, this message translates to:
  /// **'分享链接时不附带个人用户标识'**
  String get preferences_anonymousShareDesc;

  /// No description provided for @preferences_autoFillLogin.
  ///
  /// In zh, this message translates to:
  /// **'自动填充登录'**
  String get preferences_autoFillLogin;

  /// No description provided for @preferences_autoFillLoginDesc.
  ///
  /// In zh, this message translates to:
  /// **'记住账号密码，登录时自动填充'**
  String get preferences_autoFillLoginDesc;

  /// No description provided for @preferences_autoPanguSpacing.
  ///
  /// In zh, this message translates to:
  /// **'自动混排优化'**
  String get preferences_autoPanguSpacing;

  /// No description provided for @preferences_autoPanguSpacingDesc.
  ///
  /// In zh, this message translates to:
  /// **'输入时自动插入中英文混排空格'**
  String get preferences_autoPanguSpacingDesc;

  /// No description provided for @preferences_basic.
  ///
  /// In zh, this message translates to:
  /// **'基础'**
  String get preferences_basic;

  /// No description provided for @preferences_cfClearanceRefresh.
  ///
  /// In zh, this message translates to:
  /// **'cf_clearance 自动续期'**
  String get preferences_cfClearanceRefresh;

  /// No description provided for @preferences_cfClearanceRefreshDesc.
  ///
  /// In zh, this message translates to:
  /// **'通过后台 WebView 自动续期 cf_clearance Cookie'**
  String get preferences_cfClearanceRefreshDesc;

  /// No description provided for @preferences_crashlytics.
  ///
  /// In zh, this message translates to:
  /// **'崩溃日志上报'**
  String get preferences_crashlytics;

  /// No description provided for @preferences_crashlyticsDesc.
  ///
  /// In zh, this message translates to:
  /// **'发生崩溃时自动上报日志，帮助开发者定位问题'**
  String get preferences_crashlyticsDesc;

  /// No description provided for @preferences_editor.
  ///
  /// In zh, this message translates to:
  /// **'编辑器'**
  String get preferences_editor;

  /// No description provided for @preferences_enableCrashlyticsContent.
  ///
  /// In zh, this message translates to:
  /// **'本应用使用 Firebase Crashlytics 收集崩溃信息以改进应用稳定性。\n\n收集的数据包括设备信息和崩溃详情，不包含个人隐私数据。您可以在设置中关闭此功能。'**
  String get preferences_enableCrashlyticsContent;

  /// No description provided for @preferences_enableCrashlyticsTitle.
  ///
  /// In zh, this message translates to:
  /// **'数据收集说明'**
  String get preferences_enableCrashlyticsTitle;

  /// No description provided for @preferences_enterUrl.
  ///
  /// In zh, this message translates to:
  /// **'输入 URL'**
  String get preferences_enterUrl;

  /// No description provided for @preferences_hideBarOnScroll.
  ///
  /// In zh, this message translates to:
  /// **'滚动收起导航栏'**
  String get preferences_hideBarOnScroll;

  /// No description provided for @preferences_hideBarOnScrollDesc.
  ///
  /// In zh, this message translates to:
  /// **'首页滚动时自动收起顶栏和底栏'**
  String get preferences_hideBarOnScrollDesc;

  /// No description provided for @preferences_longPressPreview.
  ///
  /// In zh, this message translates to:
  /// **'长按预览'**
  String get preferences_longPressPreview;

  /// No description provided for @preferences_longPressPreviewDesc.
  ///
  /// In zh, this message translates to:
  /// **'长按话题卡片快速预览内容'**
  String get preferences_longPressPreviewDesc;

  /// No description provided for @preferences_openLinksInApp.
  ///
  /// In zh, this message translates to:
  /// **'外部链接使用内置浏览器'**
  String get preferences_openLinksInApp;

  /// No description provided for @preferences_openLinksInAppDesc.
  ///
  /// In zh, this message translates to:
  /// **'贴内外部链接优先在应用内打开'**
  String get preferences_openLinksInAppDesc;

  /// No description provided for @preferences_portraitLock.
  ///
  /// In zh, this message translates to:
  /// **'竖屏锁定'**
  String get preferences_portraitLock;

  /// No description provided for @preferences_portraitLockDesc.
  ///
  /// In zh, this message translates to:
  /// **'锁定屏幕方向为竖屏'**
  String get preferences_portraitLockDesc;

  /// No description provided for @preferences_stickerSource.
  ///
  /// In zh, this message translates to:
  /// **'表情包数据源'**
  String get preferences_stickerSource;

  /// No description provided for @preferences_title.
  ///
  /// In zh, this message translates to:
  /// **'功能设置'**
  String get preferences_title;

  /// No description provided for @settings_about.
  ///
  /// In zh, this message translates to:
  /// **'关于 FluxDO'**
  String get settings_about;

  /// No description provided for @settings_appearance.
  ///
  /// In zh, this message translates to:
  /// **'外观设置'**
  String get settings_appearance;

  /// No description provided for @settings_dataManagement.
  ///
  /// In zh, this message translates to:
  /// **'数据管理'**
  String get settings_dataManagement;

  /// No description provided for @settings_network.
  ///
  /// In zh, this message translates to:
  /// **'网络设置'**
  String get settings_network;

  /// No description provided for @settings_preferences.
  ///
  /// In zh, this message translates to:
  /// **'功能设置'**
  String get settings_preferences;

  /// No description provided for @settings_reading.
  ///
  /// In zh, this message translates to:
  /// **'阅读设置'**
  String get settings_reading;

  /// No description provided for @settings_searchEmpty.
  ///
  /// In zh, this message translates to:
  /// **'未找到匹配的设置项'**
  String get settings_searchEmpty;

  /// No description provided for @settings_searchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索设置项...'**
  String get settings_searchHint;

  /// No description provided for @settings_shortcuts.
  ///
  /// In zh, this message translates to:
  /// **'快捷键'**
  String get settings_shortcuts;

  /// No description provided for @settings_title.
  ///
  /// In zh, this message translates to:
  /// **'应用设置'**
  String get settings_title;

  /// No description provided for @shortcuts_closeOverlay.
  ///
  /// In zh, this message translates to:
  /// **'关闭浮层'**
  String get shortcuts_closeOverlay;

  /// No description provided for @shortcuts_conflict.
  ///
  /// In zh, this message translates to:
  /// **'与「{action}」冲突'**
  String shortcuts_conflict(String action);

  /// No description provided for @shortcuts_content.
  ///
  /// In zh, this message translates to:
  /// **'内容'**
  String get shortcuts_content;

  /// No description provided for @shortcuts_createTopic.
  ///
  /// In zh, this message translates to:
  /// **'创建话题'**
  String get shortcuts_createTopic;

  /// No description provided for @shortcuts_customizeHint.
  ///
  /// In zh, this message translates to:
  /// **'在 设置 > 快捷键 中自定义'**
  String get shortcuts_customizeHint;

  /// No description provided for @shortcuts_navigateBack.
  ///
  /// In zh, this message translates to:
  /// **'返回'**
  String get shortcuts_navigateBack;

  /// No description provided for @shortcuts_navigateBackAlt.
  ///
  /// In zh, this message translates to:
  /// **'返回（备用）'**
  String get shortcuts_navigateBackAlt;

  /// No description provided for @shortcuts_navigation.
  ///
  /// In zh, this message translates to:
  /// **'导航'**
  String get shortcuts_navigation;

  /// No description provided for @shortcuts_nextItem.
  ///
  /// In zh, this message translates to:
  /// **'下一个条目'**
  String get shortcuts_nextItem;

  /// No description provided for @shortcuts_nextTab.
  ///
  /// In zh, this message translates to:
  /// **'下一个分类'**
  String get shortcuts_nextTab;

  /// No description provided for @shortcuts_openItem.
  ///
  /// In zh, this message translates to:
  /// **'打开选中条目'**
  String get shortcuts_openItem;

  /// No description provided for @shortcuts_openSearch.
  ///
  /// In zh, this message translates to:
  /// **'搜索'**
  String get shortcuts_openSearch;

  /// No description provided for @shortcuts_openSettings.
  ///
  /// In zh, this message translates to:
  /// **'打开设置'**
  String get shortcuts_openSettings;

  /// No description provided for @shortcuts_previousItem.
  ///
  /// In zh, this message translates to:
  /// **'上一个条目'**
  String get shortcuts_previousItem;

  /// No description provided for @shortcuts_previousTab.
  ///
  /// In zh, this message translates to:
  /// **'上一个分类'**
  String get shortcuts_previousTab;

  /// No description provided for @shortcuts_recordKey.
  ///
  /// In zh, this message translates to:
  /// **'请按下新的快捷键组合'**
  String get shortcuts_recordKey;

  /// No description provided for @shortcuts_refresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新'**
  String get shortcuts_refresh;

  /// No description provided for @shortcuts_resetAll.
  ///
  /// In zh, this message translates to:
  /// **'恢复所有默认'**
  String get shortcuts_resetAll;

  /// No description provided for @shortcuts_resetOne.
  ///
  /// In zh, this message translates to:
  /// **'恢复默认'**
  String get shortcuts_resetOne;

  /// No description provided for @shortcuts_showHelp.
  ///
  /// In zh, this message translates to:
  /// **'快捷键帮助'**
  String get shortcuts_showHelp;

  /// No description provided for @shortcuts_switchPane.
  ///
  /// In zh, this message translates to:
  /// **'切换面板焦点'**
  String get shortcuts_switchPane;

  /// No description provided for @shortcuts_switchToProfile.
  ///
  /// In zh, this message translates to:
  /// **'切换到个人'**
  String get shortcuts_switchToProfile;

  /// No description provided for @shortcuts_switchToTopics.
  ///
  /// In zh, this message translates to:
  /// **'切换到话题'**
  String get shortcuts_switchToTopics;

  /// No description provided for @shortcuts_toggleAiPanel.
  ///
  /// In zh, this message translates to:
  /// **'AI 助手面板'**
  String get shortcuts_toggleAiPanel;

  /// No description provided for @shortcuts_toggleNotifications.
  ///
  /// In zh, this message translates to:
  /// **'通知面板'**
  String get shortcuts_toggleNotifications;

  /// No description provided for @download_alreadyInProgress.
  ///
  /// In zh, this message translates to:
  /// **'已有下载任务正在进行'**
  String get download_alreadyInProgress;

  /// No description provided for @download_checksumFailed.
  ///
  /// In zh, this message translates to:
  /// **'文件校验失败，下载的文件可能已损坏'**
  String get download_checksumFailed;

  /// No description provided for @download_connecting.
  ///
  /// In zh, this message translates to:
  /// **'正在连接...'**
  String get download_connecting;

  /// No description provided for @download_downloading.
  ///
  /// In zh, this message translates to:
  /// **'正在下载 {name}'**
  String download_downloading(String name);

  /// No description provided for @download_failed.
  ///
  /// In zh, this message translates to:
  /// **'下载失败: {error}'**
  String download_failed(String error);

  /// No description provided for @download_failedWithError.
  ///
  /// In zh, this message translates to:
  /// **'下载失败: {error}'**
  String download_failedWithError(String error);

  /// No description provided for @download_installFailed.
  ///
  /// In zh, this message translates to:
  /// **'安装失败: {error}'**
  String download_installFailed(String error);

  /// No description provided for @download_installStarted.
  ///
  /// In zh, this message translates to:
  /// **'已开始安装'**
  String get download_installStarted;

  /// No description provided for @download_installing.
  ///
  /// In zh, this message translates to:
  /// **'正在安装...'**
  String get download_installing;

  /// No description provided for @download_internalError.
  ///
  /// In zh, this message translates to:
  /// **'下载安装过程中发生内部错误'**
  String get download_internalError;

  /// No description provided for @download_noInstallPermission.
  ///
  /// In zh, this message translates to:
  /// **'未授予安装权限，请在设置中允许安装未知应用'**
  String get download_noInstallPermission;

  /// No description provided for @download_verifying.
  ///
  /// In zh, this message translates to:
  /// **'正在校验文件...'**
  String get download_verifying;

  /// No description provided for @export_exporting.
  ///
  /// In zh, this message translates to:
  /// **'导出中 ({progress}/{total})'**
  String export_exporting(int progress, int total);

  /// No description provided for @export_exportingNoProgress.
  ///
  /// In zh, this message translates to:
  /// **'导出中...'**
  String get export_exportingNoProgress;

  /// No description provided for @export_failed.
  ///
  /// In zh, this message translates to:
  /// **'导出失败: {error}'**
  String export_failed(String error);

  /// No description provided for @export_fetchPostsFailed.
  ///
  /// In zh, this message translates to:
  /// **'获取帖子数据失败'**
  String get export_fetchPostsFailed;

  /// No description provided for @export_firstPostOnly.
  ///
  /// In zh, this message translates to:
  /// **'仅主帖'**
  String get export_firstPostOnly;

  /// No description provided for @export_format.
  ///
  /// In zh, this message translates to:
  /// **'导出格式'**
  String get export_format;

  /// No description provided for @export_markdownLimit.
  ///
  /// In zh, this message translates to:
  /// **'Markdown 格式最多导出前 {max} 条帖子'**
  String export_markdownLimit(int max);

  /// No description provided for @export_noPostsToExport.
  ///
  /// In zh, this message translates to:
  /// **'没有可导出的帖子'**
  String get export_noPostsToExport;

  /// No description provided for @export_range.
  ///
  /// In zh, this message translates to:
  /// **'导出范围'**
  String get export_range;

  /// No description provided for @export_title.
  ///
  /// In zh, this message translates to:
  /// **'导出文章'**
  String get export_title;

  /// No description provided for @share_aiAssistant.
  ///
  /// In zh, this message translates to:
  /// **'AI 助手'**
  String get share_aiAssistant;

  /// No description provided for @share_aiQuestion.
  ///
  /// In zh, this message translates to:
  /// **'提问'**
  String get share_aiQuestion;

  /// No description provided for @share_aiReply.
  ///
  /// In zh, this message translates to:
  /// **'AI 回复'**
  String get share_aiReply;

  /// No description provided for @share_aiReplyAlt.
  ///
  /// In zh, this message translates to:
  /// **'AI 助手回复'**
  String get share_aiReplyAlt;

  /// No description provided for @share_cannotGetPostId.
  ///
  /// In zh, this message translates to:
  /// **'无法获取主帖 ID'**
  String get share_cannotGetPostId;

  /// No description provided for @share_copyFailed.
  ///
  /// In zh, this message translates to:
  /// **'复制失败，请重试'**
  String get share_copyFailed;

  /// No description provided for @share_exportChatImage.
  ///
  /// In zh, this message translates to:
  /// **'导出对话图片'**
  String get share_exportChatImage;

  /// No description provided for @share_exportImage.
  ///
  /// In zh, this message translates to:
  /// **'导出图片'**
  String get share_exportImage;

  /// No description provided for @share_generatedByAi.
  ///
  /// In zh, this message translates to:
  /// **'由 FluxDO AI 助手生成'**
  String get share_generatedByAi;

  /// No description provided for @share_getPostFailed.
  ///
  /// In zh, this message translates to:
  /// **'获取主帖失败'**
  String get share_getPostFailed;

  /// No description provided for @share_imageCopied.
  ///
  /// In zh, this message translates to:
  /// **'图片已复制'**
  String get share_imageCopied;

  /// No description provided for @share_imageSaved.
  ///
  /// In zh, this message translates to:
  /// **'图片已保存到相册'**
  String get share_imageSaved;

  /// No description provided for @share_loadingPost.
  ///
  /// In zh, this message translates to:
  /// **'正在加载帖子...'**
  String get share_loadingPost;

  /// No description provided for @share_replyToTopic.
  ///
  /// In zh, this message translates to:
  /// **'回复话题'**
  String get share_replyToTopic;

  /// No description provided for @share_saveFailed.
  ///
  /// In zh, this message translates to:
  /// **'保存失败，请重试'**
  String get share_saveFailed;

  /// No description provided for @share_savePermissionDenied.
  ///
  /// In zh, this message translates to:
  /// **'保存失败，请授予相册权限'**
  String get share_savePermissionDenied;

  /// No description provided for @share_saveToGallery.
  ///
  /// In zh, this message translates to:
  /// **'保存到相册'**
  String get share_saveToGallery;

  /// No description provided for @share_fileSaved.
  ///
  /// In zh, this message translates to:
  /// **'文件已保存'**
  String get share_fileSaved;

  /// No description provided for @share_selectSaveLocation.
  ///
  /// In zh, this message translates to:
  /// **'选择保存位置'**
  String get share_selectSaveLocation;

  /// No description provided for @share_screenshotFailed.
  ///
  /// In zh, this message translates to:
  /// **'截图失败'**
  String get share_screenshotFailed;

  /// No description provided for @share_shareImageTitle.
  ///
  /// In zh, this message translates to:
  /// **'分享图片'**
  String get share_shareImageTitle;

  /// No description provided for @share_themeBlack.
  ///
  /// In zh, this message translates to:
  /// **'纯黑'**
  String get share_themeBlack;

  /// No description provided for @share_themeBlue.
  ///
  /// In zh, this message translates to:
  /// **'蓝调'**
  String get share_themeBlue;

  /// No description provided for @share_themeClassic.
  ///
  /// In zh, this message translates to:
  /// **'经典'**
  String get share_themeClassic;

  /// No description provided for @share_themeDark.
  ///
  /// In zh, this message translates to:
  /// **'深色'**
  String get share_themeDark;

  /// No description provided for @share_themeGreen.
  ///
  /// In zh, this message translates to:
  /// **'绿野'**
  String get share_themeGreen;

  /// No description provided for @share_themeWhite.
  ///
  /// In zh, this message translates to:
  /// **'纯白'**
  String get share_themeWhite;

  /// No description provided for @share_uploadFailed.
  ///
  /// In zh, this message translates to:
  /// **'上传失败，请重试'**
  String get share_uploadFailed;

  /// No description provided for @share_uploading.
  ///
  /// In zh, this message translates to:
  /// **'正在上传...'**
  String get share_uploading;

  /// No description provided for @time_days.
  ///
  /// In zh, this message translates to:
  /// **'{count} 天'**
  String time_days(int count);

  /// No description provided for @time_daysAgo.
  ///
  /// In zh, this message translates to:
  /// **'{count}天前'**
  String time_daysAgo(int count);

  /// No description provided for @time_fullDate.
  ///
  /// In zh, this message translates to:
  /// **'{year}年{month}月{day}日'**
  String time_fullDate(int year, int month, int day);

  /// No description provided for @time_hours.
  ///
  /// In zh, this message translates to:
  /// **'{count} 小时'**
  String time_hours(int count);

  /// No description provided for @time_hoursAgo.
  ///
  /// In zh, this message translates to:
  /// **'{count}小时前'**
  String time_hoursAgo(int count);

  /// No description provided for @time_justNow.
  ///
  /// In zh, this message translates to:
  /// **'刚刚'**
  String get time_justNow;

  /// No description provided for @time_minutes.
  ///
  /// In zh, this message translates to:
  /// **'{count} 分钟'**
  String time_minutes(int count);

  /// No description provided for @time_minutesAgo.
  ///
  /// In zh, this message translates to:
  /// **'{count}分钟前'**
  String time_minutesAgo(int count);

  /// No description provided for @time_monthsAgo.
  ///
  /// In zh, this message translates to:
  /// **'{count}个月前'**
  String time_monthsAgo(int count);

  /// No description provided for @time_seconds.
  ///
  /// In zh, this message translates to:
  /// **'{count} 秒'**
  String time_seconds(int count);

  /// No description provided for @time_shortDate.
  ///
  /// In zh, this message translates to:
  /// **'{month}月{day}日'**
  String time_shortDate(int month, int day);

  /// No description provided for @time_today.
  ///
  /// In zh, this message translates to:
  /// **'今天'**
  String get time_today;

  /// No description provided for @time_tooltipTime.
  ///
  /// In zh, this message translates to:
  /// **'{year}年{month}月{day}日 {hour}:{minute}:{second}'**
  String time_tooltipTime(
    int year,
    int month,
    int day,
    String hour,
    String minute,
    String second,
  );

  /// No description provided for @time_weeksAgo.
  ///
  /// In zh, this message translates to:
  /// **'{count}周前'**
  String time_weeksAgo(int count);

  /// No description provided for @time_yearsAgo.
  ///
  /// In zh, this message translates to:
  /// **'{count}年前'**
  String time_yearsAgo(int count);

  /// No description provided for @time_yesterday.
  ///
  /// In zh, this message translates to:
  /// **'昨天'**
  String get time_yesterday;

  /// No description provided for @topicDetail_addToReadLater.
  ///
  /// In zh, this message translates to:
  /// **'加入浮窗'**
  String get topicDetail_addToReadLater;

  /// No description provided for @topicDetail_addToReadLaterSuccess.
  ///
  /// In zh, this message translates to:
  /// **'已加入浮窗'**
  String get topicDetail_addToReadLaterSuccess;

  /// No description provided for @topicDetail_aiAssistant.
  ///
  /// In zh, this message translates to:
  /// **'AI 助手'**
  String get topicDetail_aiAssistant;

  /// No description provided for @topicDetail_authorOnly.
  ///
  /// In zh, this message translates to:
  /// **'只看题主'**
  String get topicDetail_authorOnly;

  /// No description provided for @topicDetail_cannotOpenBrowser.
  ///
  /// In zh, this message translates to:
  /// **'无法打开浏览器'**
  String get topicDetail_cannotOpenBrowser;

  /// No description provided for @topicDetail_editBookmark.
  ///
  /// In zh, this message translates to:
  /// **'编辑书签'**
  String get topicDetail_editBookmark;

  /// No description provided for @topicDetail_editTopic.
  ///
  /// In zh, this message translates to:
  /// **'编辑话题'**
  String get topicDetail_editTopic;

  /// No description provided for @topicDetail_exportArticle.
  ///
  /// In zh, this message translates to:
  /// **'导出文章'**
  String get topicDetail_exportArticle;

  /// No description provided for @topicDetail_filter.
  ///
  /// In zh, this message translates to:
  /// **'筛选'**
  String get topicDetail_filter;

  /// No description provided for @topicDetail_generateShareImage.
  ///
  /// In zh, this message translates to:
  /// **'生成分享图片'**
  String get topicDetail_generateShareImage;

  /// No description provided for @topicDetail_hotOnly.
  ///
  /// In zh, this message translates to:
  /// **'只看热门'**
  String get topicDetail_hotOnly;

  /// No description provided for @topicDetail_loadFailedTapRetry.
  ///
  /// In zh, this message translates to:
  /// **'加载失败，点击重试'**
  String get topicDetail_loadFailedTapRetry;

  /// No description provided for @topicDetail_loading.
  ///
  /// In zh, this message translates to:
  /// **'加载中...'**
  String get topicDetail_loading;

  /// No description provided for @topicDetail_moreOptions.
  ///
  /// In zh, this message translates to:
  /// **'更多选项'**
  String get topicDetail_moreOptions;

  /// No description provided for @topicDetail_openInBrowser.
  ///
  /// In zh, this message translates to:
  /// **'在浏览器打开'**
  String get topicDetail_openInBrowser;

  /// No description provided for @topicDetail_readLaterFull.
  ///
  /// In zh, this message translates to:
  /// **'浮窗已满（最多 {max} 个）'**
  String topicDetail_readLaterFull(int max);

  /// No description provided for @topicDetail_removeFromReadLater.
  ///
  /// In zh, this message translates to:
  /// **'移出浮窗'**
  String get topicDetail_removeFromReadLater;

  /// No description provided for @topicDetail_removeFromReadLaterSuccess.
  ///
  /// In zh, this message translates to:
  /// **'已从浮窗移除'**
  String get topicDetail_removeFromReadLaterSuccess;

  /// No description provided for @topicDetail_replyLabel.
  ///
  /// In zh, this message translates to:
  /// **'回复'**
  String get topicDetail_replyLabel;

  /// No description provided for @topicDetail_scrollToTop.
  ///
  /// In zh, this message translates to:
  /// **'回到顶部'**
  String get topicDetail_scrollToTop;

  /// No description provided for @topicDetail_searchHint.
  ///
  /// In zh, this message translates to:
  /// **'在本话题中搜索...'**
  String get topicDetail_searchHint;

  /// No description provided for @topicDetail_searchTopic.
  ///
  /// In zh, this message translates to:
  /// **'搜索本话题'**
  String get topicDetail_searchTopic;

  /// No description provided for @topicDetail_setToLevel.
  ///
  /// In zh, this message translates to:
  /// **'已设置为{level}'**
  String topicDetail_setToLevel(String level);

  /// No description provided for @topicDetail_shareLink.
  ///
  /// In zh, this message translates to:
  /// **'分享链接'**
  String get topicDetail_shareLink;

  /// No description provided for @topicDetail_showHiddenReplies.
  ///
  /// In zh, this message translates to:
  /// **'显示 {count} 条隐藏回复'**
  String topicDetail_showHiddenReplies(int count);

  /// No description provided for @topicDetail_topLevelOnly.
  ///
  /// In zh, this message translates to:
  /// **'只看顶层'**
  String get topicDetail_topLevelOnly;

  /// No description provided for @topicDetail_viewAll.
  ///
  /// In zh, this message translates to:
  /// **'查看全部'**
  String get topicDetail_viewAll;

  /// No description provided for @topicDetail_viewsLabel.
  ///
  /// In zh, this message translates to:
  /// **'浏览'**
  String get topicDetail_viewsLabel;

  /// No description provided for @topicSort_activity.
  ///
  /// In zh, this message translates to:
  /// **'活跃度'**
  String get topicSort_activity;

  /// No description provided for @topicSort_created.
  ///
  /// In zh, this message translates to:
  /// **'创建时间'**
  String get topicSort_created;

  /// No description provided for @topicSort_default.
  ///
  /// In zh, this message translates to:
  /// **'默认'**
  String get topicSort_default;

  /// No description provided for @topicSort_likes.
  ///
  /// In zh, this message translates to:
  /// **'点赞数'**
  String get topicSort_likes;

  /// No description provided for @topicSort_posters.
  ///
  /// In zh, this message translates to:
  /// **'参与者'**
  String get topicSort_posters;

  /// No description provided for @topicSort_posts.
  ///
  /// In zh, this message translates to:
  /// **'回复数'**
  String get topicSort_posts;

  /// No description provided for @topicSort_views.
  ///
  /// In zh, this message translates to:
  /// **'浏览量'**
  String get topicSort_views;

  /// No description provided for @topic_addTags.
  ///
  /// In zh, this message translates to:
  /// **'添加标签'**
  String get topic_addTags;

  /// No description provided for @topic_aiSummary.
  ///
  /// In zh, this message translates to:
  /// **'AI 摘要'**
  String get topic_aiSummary;

  /// No description provided for @topic_atCurrentPosition.
  ///
  /// In zh, this message translates to:
  /// **'正位于此'**
  String get topic_atCurrentPosition;

  /// No description provided for @topic_createdAt.
  ///
  /// In zh, this message translates to:
  /// **'创建于 '**
  String get topic_createdAt;

  /// No description provided for @topic_currentFloor.
  ///
  /// In zh, this message translates to:
  /// **'当前楼层'**
  String get topic_currentFloor;

  /// No description provided for @topic_filterHot.
  ///
  /// In zh, this message translates to:
  /// **'热门'**
  String get topic_filterHot;

  /// No description provided for @topic_filterLatest.
  ///
  /// In zh, this message translates to:
  /// **'最新'**
  String get topic_filterLatest;

  /// No description provided for @topic_filterNew.
  ///
  /// In zh, this message translates to:
  /// **'新话题'**
  String get topic_filterNew;

  /// No description provided for @topic_filterTooltip.
  ///
  /// In zh, this message translates to:
  /// **'筛选: {label}'**
  String topic_filterTooltip(String label);

  /// No description provided for @topic_filterTop.
  ///
  /// In zh, this message translates to:
  /// **'排行榜'**
  String get topic_filterTop;

  /// No description provided for @topic_filterUnread.
  ///
  /// In zh, this message translates to:
  /// **'未读完'**
  String get topic_filterUnread;

  /// No description provided for @topic_filterUnseen.
  ///
  /// In zh, this message translates to:
  /// **'未浏览'**
  String get topic_filterUnseen;

  /// No description provided for @topic_flagInappropriate.
  ///
  /// In zh, this message translates to:
  /// **'不当内容'**
  String get topic_flagInappropriate;

  /// No description provided for @topic_flagInappropriateDesc.
  ///
  /// In zh, this message translates to:
  /// **'此帖子包含不适当的内容'**
  String get topic_flagInappropriateDesc;

  /// No description provided for @topic_flagOffTopic.
  ///
  /// In zh, this message translates to:
  /// **'离题'**
  String get topic_flagOffTopic;

  /// No description provided for @topic_flagOffTopicDesc.
  ///
  /// In zh, this message translates to:
  /// **'此帖子与当前讨论无关，应该移动到其他话题'**
  String get topic_flagOffTopicDesc;

  /// No description provided for @topic_flagOther.
  ///
  /// In zh, this message translates to:
  /// **'其他问题'**
  String get topic_flagOther;

  /// No description provided for @topic_flagOtherDesc.
  ///
  /// In zh, this message translates to:
  /// **'需要版主关注的其他问题'**
  String get topic_flagOtherDesc;

  /// No description provided for @topic_flagSpam.
  ///
  /// In zh, this message translates to:
  /// **'垃圾信息'**
  String get topic_flagSpam;

  /// No description provided for @topic_flagSpamDesc.
  ///
  /// In zh, this message translates to:
  /// **'此帖子是广告或垃圾信息'**
  String get topic_flagSpamDesc;

  /// No description provided for @topic_generateAiSummary.
  ///
  /// In zh, this message translates to:
  /// **'生成 AI 摘要'**
  String get topic_generateAiSummary;

  /// No description provided for @topic_generatingSummary.
  ///
  /// In zh, this message translates to:
  /// **'正在生成摘要...'**
  String get topic_generatingSummary;

  /// No description provided for @topic_jump.
  ///
  /// In zh, this message translates to:
  /// **'跳转'**
  String get topic_jump;

  /// No description provided for @topic_lastReply.
  ///
  /// In zh, this message translates to:
  /// **'最后回复 '**
  String get topic_lastReply;

  /// No description provided for @topic_levelMuted.
  ///
  /// In zh, this message translates to:
  /// **'静音'**
  String get topic_levelMuted;

  /// No description provided for @topic_levelMutedDesc.
  ///
  /// In zh, this message translates to:
  /// **'不接收任何通知'**
  String get topic_levelMutedDesc;

  /// No description provided for @topic_levelRegular.
  ///
  /// In zh, this message translates to:
  /// **'常规'**
  String get topic_levelRegular;

  /// No description provided for @topic_levelRegularDesc.
  ///
  /// In zh, this message translates to:
  /// **'只在被 @ 提及或回复时通知'**
  String get topic_levelRegularDesc;

  /// No description provided for @topic_levelTracking.
  ///
  /// In zh, this message translates to:
  /// **'跟踪'**
  String get topic_levelTracking;

  /// No description provided for @topic_levelTrackingDesc.
  ///
  /// In zh, this message translates to:
  /// **'显示未读计数'**
  String get topic_levelTrackingDesc;

  /// No description provided for @topic_levelWatching.
  ///
  /// In zh, this message translates to:
  /// **'关注'**
  String get topic_levelWatching;

  /// No description provided for @topic_levelWatchingDesc.
  ///
  /// In zh, this message translates to:
  /// **'每个新回复都通知'**
  String get topic_levelWatchingDesc;

  /// No description provided for @topic_likeCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 点赞'**
  String topic_likeCount(String count);

  /// No description provided for @topic_minTagsRequired.
  ///
  /// In zh, this message translates to:
  /// **'至少选择 {min} 个标签'**
  String topic_minTagsRequired(int min);

  /// No description provided for @topic_newRepliesSinceSummary.
  ///
  /// In zh, this message translates to:
  /// **'有 {count} 条新回复'**
  String topic_newRepliesSinceSummary(int count);

  /// No description provided for @topic_noSummary.
  ///
  /// In zh, this message translates to:
  /// **'暂无摘要'**
  String get topic_noSummary;

  /// No description provided for @topic_notificationSettings.
  ///
  /// In zh, this message translates to:
  /// **'订阅设置'**
  String get topic_notificationSettings;

  /// No description provided for @topic_participants.
  ///
  /// In zh, this message translates to:
  /// **'参与者'**
  String get topic_participants;

  /// No description provided for @topic_readyToJump.
  ///
  /// In zh, this message translates to:
  /// **'准备跳转'**
  String get topic_readyToJump;

  /// No description provided for @topic_remainingTags.
  ///
  /// In zh, this message translates to:
  /// **'还需 {remaining} 个标签'**
  String topic_remainingTags(int remaining);

  /// No description provided for @topic_replyCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 条回复'**
  String topic_replyCount(int count);

  /// No description provided for @topic_selectCategory.
  ///
  /// In zh, this message translates to:
  /// **'选择分类'**
  String get topic_selectCategory;

  /// No description provided for @topic_sortTooltip.
  ///
  /// In zh, this message translates to:
  /// **'排序: {label}'**
  String topic_sortTooltip(String label);

  /// No description provided for @topic_summaryLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载摘要失败'**
  String get topic_summaryLoadFailed;

  /// No description provided for @topic_tagGroupRequirement.
  ///
  /// In zh, this message translates to:
  /// **'从 {name} 选择 {minCount} 个'**
  String topic_tagGroupRequirement(String name, int minCount);

  /// No description provided for @topic_updatedAt.
  ///
  /// In zh, this message translates to:
  /// **'更新于 '**
  String get topic_updatedAt;

  /// No description provided for @topic_viewCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 浏览'**
  String topic_viewCount(String count);

  /// No description provided for @topicsScreen_createTopic.
  ///
  /// In zh, this message translates to:
  /// **'创建话题'**
  String get topicsScreen_createTopic;

  /// No description provided for @topicsScreen_myDrafts.
  ///
  /// In zh, this message translates to:
  /// **'我的草稿'**
  String get topicsScreen_myDrafts;

  /// No description provided for @topics_browseCategories.
  ///
  /// In zh, this message translates to:
  /// **'浏览分类'**
  String get topics_browseCategories;

  /// No description provided for @topics_debugJump.
  ///
  /// In zh, this message translates to:
  /// **'调试：跳转话题'**
  String get topics_debugJump;

  /// No description provided for @topics_dismiss.
  ///
  /// In zh, this message translates to:
  /// **'忽略'**
  String get topics_dismiss;

  /// No description provided for @topics_dismissConfirmContent.
  ///
  /// In zh, this message translates to:
  /// **'确定要忽略全部{label}吗？'**
  String topics_dismissConfirmContent(String label);

  /// No description provided for @topics_dismissConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'忽略确认'**
  String get topics_dismissConfirmTitle;

  /// No description provided for @topics_jump.
  ///
  /// In zh, this message translates to:
  /// **'跳转'**
  String get topics_jump;

  /// No description provided for @topics_jumpToTopic.
  ///
  /// In zh, this message translates to:
  /// **'跳转到话题'**
  String get topics_jumpToTopic;

  /// No description provided for @topics_newTopics.
  ///
  /// In zh, this message translates to:
  /// **'新话题'**
  String get topics_newTopics;

  /// No description provided for @topics_noTopics.
  ///
  /// In zh, this message translates to:
  /// **'没有相关话题'**
  String get topics_noTopics;

  /// No description provided for @topics_searchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索话题...'**
  String get topics_searchHint;

  /// No description provided for @topics_topicId.
  ///
  /// In zh, this message translates to:
  /// **'话题 ID'**
  String get topics_topicId;

  /// No description provided for @topics_topicIdHint.
  ///
  /// In zh, this message translates to:
  /// **'例如: 1095754'**
  String get topics_topicIdHint;

  /// No description provided for @topics_unreadTopics.
  ///
  /// In zh, this message translates to:
  /// **'未读话题'**
  String get topics_unreadTopics;

  /// No description provided for @topics_viewNewTopics.
  ///
  /// In zh, this message translates to:
  /// **'查看 {count} 个新的或更新的话题'**
  String topics_viewNewTopics(int count);

  /// No description provided for @followList_followers.
  ///
  /// In zh, this message translates to:
  /// **'粉丝'**
  String get followList_followers;

  /// No description provided for @followList_following.
  ///
  /// In zh, this message translates to:
  /// **'关注'**
  String get followList_following;

  /// No description provided for @privateMessages_title.
  ///
  /// In zh, this message translates to:
  /// **'私信'**
  String get privateMessages_title;

  /// No description provided for @privateMessages_inbox.
  ///
  /// In zh, this message translates to:
  /// **'最新'**
  String get privateMessages_inbox;

  /// No description provided for @privateMessages_sent.
  ///
  /// In zh, this message translates to:
  /// **'已发送'**
  String get privateMessages_sent;

  /// No description provided for @privateMessages_archive.
  ///
  /// In zh, this message translates to:
  /// **'归档'**
  String get privateMessages_archive;

  /// No description provided for @privateMessages_empty.
  ///
  /// In zh, this message translates to:
  /// **'暂无私信'**
  String get privateMessages_empty;

  /// No description provided for @profileStats_addItems.
  ///
  /// In zh, this message translates to:
  /// **'点击添加统计项'**
  String get profileStats_addItems;

  /// No description provided for @profileStats_allItemsAdded.
  ///
  /// In zh, this message translates to:
  /// **'所有统计项已添加'**
  String get profileStats_allItemsAdded;

  /// No description provided for @profileStats_availableItems.
  ///
  /// In zh, this message translates to:
  /// **'可添加项目'**
  String get profileStats_availableItems;

  /// No description provided for @profileStats_bookmarkCount.
  ///
  /// In zh, this message translates to:
  /// **'书签数'**
  String get profileStats_bookmarkCount;

  /// No description provided for @profileStats_columnsPerRow.
  ///
  /// In zh, this message translates to:
  /// **'每行数量'**
  String get profileStats_columnsPerRow;

  /// No description provided for @profileStats_dataSource.
  ///
  /// In zh, this message translates to:
  /// **'数据源'**
  String get profileStats_dataSource;

  /// No description provided for @profileStats_daysVisited.
  ///
  /// In zh, this message translates to:
  /// **'访问天数'**
  String get profileStats_daysVisited;

  /// No description provided for @profileStats_editTitle.
  ///
  /// In zh, this message translates to:
  /// **'统计卡片自定义'**
  String get profileStats_editTitle;

  /// No description provided for @profileStats_enabledItems.
  ///
  /// In zh, this message translates to:
  /// **'已添加项目'**
  String get profileStats_enabledItems;

  /// No description provided for @profileStats_guideMessage.
  ///
  /// In zh, this message translates to:
  /// **'点击统计卡片可自定义展示项目、布局和数据源'**
  String get profileStats_guideMessage;

  /// No description provided for @profileStats_incompatibleSource.
  ///
  /// In zh, this message translates to:
  /// **'不兼容当前数据源'**
  String get profileStats_incompatibleSource;

  /// No description provided for @profileStats_layoutGrid.
  ///
  /// In zh, this message translates to:
  /// **'网格'**
  String get profileStats_layoutGrid;

  /// No description provided for @profileStats_layoutMode.
  ///
  /// In zh, this message translates to:
  /// **'布局模式'**
  String get profileStats_layoutMode;

  /// No description provided for @profileStats_layoutScroll.
  ///
  /// In zh, this message translates to:
  /// **'滚动'**
  String get profileStats_layoutScroll;

  /// No description provided for @profileStats_layoutSettings.
  ///
  /// In zh, this message translates to:
  /// **'布局设置'**
  String get profileStats_layoutSettings;

  /// No description provided for @profileStats_likesGiven.
  ///
  /// In zh, this message translates to:
  /// **'送赞'**
  String get profileStats_likesGiven;

  /// No description provided for @profileStats_likesReceived.
  ///
  /// In zh, this message translates to:
  /// **'获赞'**
  String get profileStats_likesReceived;

  /// No description provided for @profileStats_likesReceivedDays.
  ///
  /// In zh, this message translates to:
  /// **'获赞天数'**
  String get profileStats_likesReceivedDays;

  /// No description provided for @profileStats_likesReceivedUsers.
  ///
  /// In zh, this message translates to:
  /// **'获赞人数'**
  String get profileStats_likesReceivedUsers;

  /// No description provided for @profileStats_loadError.
  ///
  /// In zh, this message translates to:
  /// **'数据加载失败，已回退到全量统计'**
  String get profileStats_loadError;

  /// No description provided for @profileStats_noItemsSelected.
  ///
  /// In zh, this message translates to:
  /// **'未选择任何统计项'**
  String get profileStats_noItemsSelected;

  /// No description provided for @profileStats_postCount.
  ///
  /// In zh, this message translates to:
  /// **'发帖数'**
  String get profileStats_postCount;

  /// No description provided for @profileStats_postsRead.
  ///
  /// In zh, this message translates to:
  /// **'已读帖子'**
  String get profileStats_postsRead;

  /// No description provided for @profileStats_recentTimeRead.
  ///
  /// In zh, this message translates to:
  /// **'近60天阅读'**
  String get profileStats_recentTimeRead;

  /// No description provided for @profileStats_selectItems.
  ///
  /// In zh, this message translates to:
  /// **'统计项目'**
  String get profileStats_selectItems;

  /// No description provided for @profileStats_sourceConnect.
  ///
  /// In zh, this message translates to:
  /// **'信任等级周期'**
  String get profileStats_sourceConnect;

  /// No description provided for @profileStats_sourceDaily.
  ///
  /// In zh, this message translates to:
  /// **'本日'**
  String get profileStats_sourceDaily;

  /// No description provided for @profileStats_sourceMonthly.
  ///
  /// In zh, this message translates to:
  /// **'本月'**
  String get profileStats_sourceMonthly;

  /// No description provided for @profileStats_sourceQuarterly.
  ///
  /// In zh, this message translates to:
  /// **'本季'**
  String get profileStats_sourceQuarterly;

  /// No description provided for @profileStats_sourceSummary.
  ///
  /// In zh, this message translates to:
  /// **'全量统计'**
  String get profileStats_sourceSummary;

  /// No description provided for @profileStats_sourceWeekly.
  ///
  /// In zh, this message translates to:
  /// **'本周'**
  String get profileStats_sourceWeekly;

  /// No description provided for @profileStats_sourceYearly.
  ///
  /// In zh, this message translates to:
  /// **'本年'**
  String get profileStats_sourceYearly;

  /// No description provided for @profileStats_timeRead.
  ///
  /// In zh, this message translates to:
  /// **'阅读时间'**
  String get profileStats_timeRead;

  /// No description provided for @profileStats_topicCount.
  ///
  /// In zh, this message translates to:
  /// **'主题数'**
  String get profileStats_topicCount;

  /// No description provided for @profileStats_topicsEntered.
  ///
  /// In zh, this message translates to:
  /// **'浏览主题'**
  String get profileStats_topicsEntered;

  /// No description provided for @profileStats_topicsRepliedTo.
  ///
  /// In zh, this message translates to:
  /// **'回复主题'**
  String get profileStats_topicsRepliedTo;

  /// No description provided for @profile_aboutFluxDO.
  ///
  /// In zh, this message translates to:
  /// **'关于 FluxDO'**
  String get profile_aboutFluxDO;

  /// No description provided for @profile_aiModelService.
  ///
  /// In zh, this message translates to:
  /// **'AI 模型服务'**
  String get profile_aiModelService;

  /// No description provided for @profile_appearance.
  ///
  /// In zh, this message translates to:
  /// **'外观设置'**
  String get profile_appearance;

  /// No description provided for @profile_browsingHistory.
  ///
  /// In zh, this message translates to:
  /// **'浏览历史'**
  String get profile_browsingHistory;

  /// No description provided for @profile_cdkReauthSuccess.
  ///
  /// In zh, this message translates to:
  /// **'CDK 重新授权成功'**
  String get profile_cdkReauthSuccess;

  /// No description provided for @profile_confirmLogout.
  ///
  /// In zh, this message translates to:
  /// **'确认退出'**
  String get profile_confirmLogout;

  /// No description provided for @profile_dataManagement.
  ///
  /// In zh, this message translates to:
  /// **'数据管理'**
  String get profile_dataManagement;

  /// No description provided for @profile_daysVisited.
  ///
  /// In zh, this message translates to:
  /// **'访问天数'**
  String get profile_daysVisited;

  /// No description provided for @profile_editProfile.
  ///
  /// In zh, this message translates to:
  /// **'编辑资料'**
  String get profile_editProfile;

  /// No description provided for @profile_inviteLinks.
  ///
  /// In zh, this message translates to:
  /// **'邀请链接'**
  String get profile_inviteLinks;

  /// No description provided for @profile_ldcReauthSuccess.
  ///
  /// In zh, this message translates to:
  /// **'LDC 重新授权成功'**
  String get profile_ldcReauthSuccess;

  /// No description provided for @profile_likesReceived.
  ///
  /// In zh, this message translates to:
  /// **'获得点赞'**
  String get profile_likesReceived;

  /// No description provided for @profile_loadingData.
  ///
  /// In zh, this message translates to:
  /// **'加载数据...'**
  String get profile_loadingData;

  /// No description provided for @profile_loggingOut.
  ///
  /// In zh, this message translates to:
  /// **'正在退出...'**
  String get profile_loggingOut;

  /// No description provided for @profile_loginForMore.
  ///
  /// In zh, this message translates to:
  /// **'登录后体验更多功能'**
  String get profile_loginForMore;

  /// No description provided for @profile_loginLinuxDo.
  ///
  /// In zh, this message translates to:
  /// **'登录 Linux.do'**
  String get profile_loginLinuxDo;

  /// No description provided for @profile_logoutContent.
  ///
  /// In zh, this message translates to:
  /// **'确定要退出登录吗？'**
  String get profile_logoutContent;

  /// No description provided for @profile_logoutCurrentAccount.
  ///
  /// In zh, this message translates to:
  /// **'退出当前账号'**
  String get profile_logoutCurrentAccount;

  /// No description provided for @profile_metaverse.
  ///
  /// In zh, this message translates to:
  /// **'元宇宙'**
  String get profile_metaverse;

  /// No description provided for @profile_privateMessages.
  ///
  /// In zh, this message translates to:
  /// **'私信'**
  String get profile_privateMessages;

  /// No description provided for @profile_myBadges.
  ///
  /// In zh, this message translates to:
  /// **'我的徽章'**
  String get profile_myBadges;

  /// No description provided for @profile_myBookmarks.
  ///
  /// In zh, this message translates to:
  /// **'我的书签'**
  String get profile_myBookmarks;

  /// No description provided for @profile_myBrowser.
  ///
  /// In zh, this message translates to:
  /// **'网页浏览'**
  String get profile_myBrowser;

  /// No description provided for @profile_myDrafts.
  ///
  /// In zh, this message translates to:
  /// **'我的草稿'**
  String get profile_myDrafts;

  /// No description provided for @profile_myTopics.
  ///
  /// In zh, this message translates to:
  /// **'我的话题'**
  String get profile_myTopics;

  /// No description provided for @profile_networkSettings.
  ///
  /// In zh, this message translates to:
  /// **'网络设置'**
  String get profile_networkSettings;

  /// No description provided for @profile_notLoggedIn.
  ///
  /// In zh, this message translates to:
  /// **'未登录'**
  String get profile_notLoggedIn;

  /// No description provided for @profile_postCount.
  ///
  /// In zh, this message translates to:
  /// **'发表回复'**
  String get profile_postCount;

  /// No description provided for @profile_postsRead.
  ///
  /// In zh, this message translates to:
  /// **'阅读帖子'**
  String get profile_postsRead;

  /// No description provided for @profile_preferences.
  ///
  /// In zh, this message translates to:
  /// **'功能设置'**
  String get profile_preferences;

  /// No description provided for @profile_settings.
  ///
  /// In zh, this message translates to:
  /// **'应用设置'**
  String get profile_settings;

  /// No description provided for @profile_trustRequirements.
  ///
  /// In zh, this message translates to:
  /// **'信任要求'**
  String get profile_trustRequirements;

  /// No description provided for @trustLevel_activity.
  ///
  /// In zh, this message translates to:
  /// **'活跃程度'**
  String get trustLevel_activity;

  /// No description provided for @trustLevel_appBarTitle.
  ///
  /// In zh, this message translates to:
  /// **'信任要求'**
  String get trustLevel_appBarTitle;

  /// No description provided for @trustLevel_compliance.
  ///
  /// In zh, this message translates to:
  /// **'合规记录'**
  String get trustLevel_compliance;

  /// No description provided for @trustLevel_interaction.
  ///
  /// In zh, this message translates to:
  /// **'互动参与'**
  String get trustLevel_interaction;

  /// No description provided for @trustLevel_parseFailed.
  ///
  /// In zh, this message translates to:
  /// **'解析失败: {error}'**
  String trustLevel_parseFailed(String error);

  /// No description provided for @trustLevel_parseNotFound.
  ///
  /// In zh, this message translates to:
  /// **'未找到信任级别信息 (div.card)'**
  String get trustLevel_parseNotFound;

  /// No description provided for @trustLevel_requestFailed.
  ///
  /// In zh, this message translates to:
  /// **'请求失败: {statusCode}'**
  String trustLevel_requestFailed(int statusCode);

  /// No description provided for @trustLevel_title.
  ///
  /// In zh, this message translates to:
  /// **'信任级别要求'**
  String get trustLevel_title;

  /// No description provided for @userProfile_actionCreatedTopic.
  ///
  /// In zh, this message translates to:
  /// **'发布了话题'**
  String get userProfile_actionCreatedTopic;

  /// No description provided for @userProfile_actionDefault.
  ///
  /// In zh, this message translates to:
  /// **'动态'**
  String get userProfile_actionDefault;

  /// No description provided for @userProfile_actionLike.
  ///
  /// In zh, this message translates to:
  /// **'点赞'**
  String get userProfile_actionLike;

  /// No description provided for @userProfile_actionLiked.
  ///
  /// In zh, this message translates to:
  /// **'被赞'**
  String get userProfile_actionLiked;

  /// No description provided for @userProfile_actionReplied.
  ///
  /// In zh, this message translates to:
  /// **'回复了'**
  String get userProfile_actionReplied;

  /// No description provided for @userProfile_bio.
  ///
  /// In zh, this message translates to:
  /// **'个人简介'**
  String get userProfile_bio;

  /// No description provided for @userProfile_catPostCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 回复'**
  String userProfile_catPostCount(int count);

  /// No description provided for @userProfile_catTopicCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 话题'**
  String userProfile_catTopicCount(int count);

  /// No description provided for @userProfile_follow.
  ///
  /// In zh, this message translates to:
  /// **'关注'**
  String get userProfile_follow;

  /// No description provided for @userProfile_followed.
  ///
  /// In zh, this message translates to:
  /// **'已关注'**
  String get userProfile_followed;

  /// No description provided for @userProfile_followers.
  ///
  /// In zh, this message translates to:
  /// **'粉丝'**
  String get userProfile_followers;

  /// No description provided for @userProfile_following.
  ///
  /// In zh, this message translates to:
  /// **'关注'**
  String get userProfile_following;

  /// No description provided for @userProfile_fourMonths.
  ///
  /// In zh, this message translates to:
  /// **'四个月'**
  String get userProfile_fourMonths;

  /// No description provided for @userProfile_ignored.
  ///
  /// In zh, this message translates to:
  /// **'已忽略'**
  String get userProfile_ignored;

  /// No description provided for @userProfile_joinDate.
  ///
  /// In zh, this message translates to:
  /// **'加入时间'**
  String get userProfile_joinDate;

  /// No description provided for @userProfile_laterThisWeek.
  ///
  /// In zh, this message translates to:
  /// **'本周稍后'**
  String get userProfile_laterThisWeek;

  /// No description provided for @userProfile_laterToday.
  ///
  /// In zh, this message translates to:
  /// **'今天稍后'**
  String get userProfile_laterToday;

  /// No description provided for @userProfile_linkClicks.
  ///
  /// In zh, this message translates to:
  /// **'{count} 次点击'**
  String userProfile_linkClicks(int count);

  /// No description provided for @userProfile_location.
  ///
  /// In zh, this message translates to:
  /// **'位置'**
  String get userProfile_location;

  /// No description provided for @userProfile_message.
  ///
  /// In zh, this message translates to:
  /// **'私信'**
  String get userProfile_message;

  /// No description provided for @userProfile_moreInfo.
  ///
  /// In zh, this message translates to:
  /// **'更多信息'**
  String get userProfile_moreInfo;

  /// No description provided for @userProfile_mostLiked.
  ///
  /// In zh, this message translates to:
  /// **'赞最多'**
  String get userProfile_mostLiked;

  /// No description provided for @userProfile_mostLikedBy.
  ///
  /// In zh, this message translates to:
  /// **'被谁赞的最多'**
  String get userProfile_mostLikedBy;

  /// No description provided for @userProfile_mostRepliedTo.
  ///
  /// In zh, this message translates to:
  /// **'最多回复至'**
  String get userProfile_mostRepliedTo;

  /// No description provided for @userProfile_mute.
  ///
  /// In zh, this message translates to:
  /// **'免打扰'**
  String get userProfile_mute;

  /// No description provided for @userProfile_nextMonday.
  ///
  /// In zh, this message translates to:
  /// **'下周一'**
  String get userProfile_nextMonday;

  /// No description provided for @userProfile_nextMonth.
  ///
  /// In zh, this message translates to:
  /// **'下个月'**
  String get userProfile_nextMonth;

  /// No description provided for @userProfile_noBio.
  ///
  /// In zh, this message translates to:
  /// **'这个人很懒，什么都没写'**
  String get userProfile_noBio;

  /// No description provided for @userProfile_noContent.
  ///
  /// In zh, this message translates to:
  /// **'暂无内容'**
  String get userProfile_noContent;

  /// No description provided for @userProfile_noReactions.
  ///
  /// In zh, this message translates to:
  /// **'暂无回应'**
  String get userProfile_noReactions;

  /// No description provided for @userProfile_noSummary.
  ///
  /// In zh, this message translates to:
  /// **'暂无总结数据'**
  String get userProfile_noSummary;

  /// No description provided for @userProfile_normal.
  ///
  /// In zh, this message translates to:
  /// **'常规'**
  String get userProfile_normal;

  /// No description provided for @userProfile_oneYear.
  ///
  /// In zh, this message translates to:
  /// **'一年'**
  String get userProfile_oneYear;

  /// No description provided for @userProfile_permanent.
  ///
  /// In zh, this message translates to:
  /// **'永久'**
  String get userProfile_permanent;

  /// No description provided for @userProfile_permanentlySilenced.
  ///
  /// In zh, this message translates to:
  /// **'该用户已被永久禁言'**
  String get userProfile_permanentlySilenced;

  /// No description provided for @userProfile_permanentlySuspended.
  ///
  /// In zh, this message translates to:
  /// **'该用户已被永久封禁'**
  String get userProfile_permanentlySuspended;

  /// No description provided for @userProfile_reacted.
  ///
  /// In zh, this message translates to:
  /// **'回应了'**
  String get userProfile_reacted;

  /// No description provided for @userProfile_restored.
  ///
  /// In zh, this message translates to:
  /// **'已恢复常规通知'**
  String get userProfile_restored;

  /// No description provided for @userProfile_selectIgnoreDuration.
  ///
  /// In zh, this message translates to:
  /// **'选择忽略时长'**
  String get userProfile_selectIgnoreDuration;

  /// No description provided for @userProfile_setToIgnore.
  ///
  /// In zh, this message translates to:
  /// **'已设置为忽略'**
  String get userProfile_setToIgnore;

  /// No description provided for @userProfile_setToMute.
  ///
  /// In zh, this message translates to:
  /// **'已设置为免打扰'**
  String get userProfile_setToMute;

  /// No description provided for @userProfile_shareUser.
  ///
  /// In zh, this message translates to:
  /// **'分享用户'**
  String get userProfile_shareUser;

  /// No description provided for @userProfile_silencedBannerForever.
  ///
  /// In zh, this message translates to:
  /// **'该用户已被永久禁言'**
  String get userProfile_silencedBannerForever;

  /// No description provided for @userProfile_silencedBannerUntil.
  ///
  /// In zh, this message translates to:
  /// **'该用户已被禁言至 {date}'**
  String userProfile_silencedBannerUntil(String date);

  /// No description provided for @userProfile_silencedStatus.
  ///
  /// In zh, this message translates to:
  /// **'禁言状态'**
  String get userProfile_silencedStatus;

  /// No description provided for @userProfile_silencedUntil.
  ///
  /// In zh, this message translates to:
  /// **'禁言至 {date}'**
  String userProfile_silencedUntil(String date);

  /// No description provided for @userProfile_sixMonths.
  ///
  /// In zh, this message translates to:
  /// **'六个月'**
  String get userProfile_sixMonths;

  /// No description provided for @userProfile_statsLikes.
  ///
  /// In zh, this message translates to:
  /// **'获赞'**
  String get userProfile_statsLikes;

  /// No description provided for @userProfile_statsReplies.
  ///
  /// In zh, this message translates to:
  /// **'回复'**
  String get userProfile_statsReplies;

  /// No description provided for @userProfile_statsTopics.
  ///
  /// In zh, this message translates to:
  /// **'话题'**
  String get userProfile_statsTopics;

  /// No description provided for @userProfile_statsVisits.
  ///
  /// In zh, this message translates to:
  /// **'访问'**
  String get userProfile_statsVisits;

  /// No description provided for @userProfile_suspendedBannerForever.
  ///
  /// In zh, this message translates to:
  /// **'该用户已被永久封禁'**
  String get userProfile_suspendedBannerForever;

  /// No description provided for @userProfile_suspendedBannerUntil.
  ///
  /// In zh, this message translates to:
  /// **'该用户已被封禁至 {date}'**
  String userProfile_suspendedBannerUntil(String date);

  /// No description provided for @userProfile_suspendedStatus.
  ///
  /// In zh, this message translates to:
  /// **'封禁状态'**
  String get userProfile_suspendedStatus;

  /// No description provided for @userProfile_suspendedUntil.
  ///
  /// In zh, this message translates to:
  /// **'封禁至 {date}'**
  String userProfile_suspendedUntil(String date);

  /// No description provided for @userProfile_tabActivity.
  ///
  /// In zh, this message translates to:
  /// **'动态'**
  String get userProfile_tabActivity;

  /// No description provided for @userProfile_tabLikes.
  ///
  /// In zh, this message translates to:
  /// **'赞'**
  String get userProfile_tabLikes;

  /// No description provided for @userProfile_tabReactions.
  ///
  /// In zh, this message translates to:
  /// **'回应'**
  String get userProfile_tabReactions;

  /// No description provided for @userProfile_tabReplies.
  ///
  /// In zh, this message translates to:
  /// **'回复'**
  String get userProfile_tabReplies;

  /// No description provided for @userProfile_tabSummary.
  ///
  /// In zh, this message translates to:
  /// **'总结'**
  String get userProfile_tabSummary;

  /// No description provided for @userProfile_tabTopics.
  ///
  /// In zh, this message translates to:
  /// **'话题'**
  String get userProfile_tabTopics;

  /// No description provided for @userProfile_threeMonths.
  ///
  /// In zh, this message translates to:
  /// **'三个月'**
  String get userProfile_threeMonths;

  /// No description provided for @userProfile_tomorrow.
  ///
  /// In zh, this message translates to:
  /// **'明天'**
  String get userProfile_tomorrow;

  /// No description provided for @userProfile_topBadges.
  ///
  /// In zh, this message translates to:
  /// **'热门徽章'**
  String get userProfile_topBadges;

  /// No description provided for @userProfile_topCategories.
  ///
  /// In zh, this message translates to:
  /// **'热门类别'**
  String get userProfile_topCategories;

  /// No description provided for @userProfile_topLinks.
  ///
  /// In zh, this message translates to:
  /// **'热门链接'**
  String get userProfile_topLinks;

  /// No description provided for @userProfile_topReplies.
  ///
  /// In zh, this message translates to:
  /// **'热门回复'**
  String get userProfile_topReplies;

  /// No description provided for @userProfile_topTopics.
  ///
  /// In zh, this message translates to:
  /// **'热门话题'**
  String get userProfile_topTopics;

  /// No description provided for @userProfile_topicHash.
  ///
  /// In zh, this message translates to:
  /// **'话题 #{id}'**
  String userProfile_topicHash(String id);

  /// No description provided for @userProfile_twoMonths.
  ///
  /// In zh, this message translates to:
  /// **'两个月'**
  String get userProfile_twoMonths;

  /// No description provided for @userProfile_twoWeeks.
  ///
  /// In zh, this message translates to:
  /// **'两周'**
  String get userProfile_twoWeeks;

  /// No description provided for @userProfile_website.
  ///
  /// In zh, this message translates to:
  /// **'网站'**
  String get userProfile_website;

  /// No description provided for @user_trustLevel0.
  ///
  /// In zh, this message translates to:
  /// **'L0 新用户'**
  String get user_trustLevel0;

  /// No description provided for @user_trustLevel1.
  ///
  /// In zh, this message translates to:
  /// **'L1 基本用户'**
  String get user_trustLevel1;

  /// No description provided for @user_trustLevel2.
  ///
  /// In zh, this message translates to:
  /// **'L2 成员'**
  String get user_trustLevel2;

  /// No description provided for @user_trustLevel3.
  ///
  /// In zh, this message translates to:
  /// **'L3 活跃用户'**
  String get user_trustLevel3;

  /// No description provided for @user_trustLevel4.
  ///
  /// In zh, this message translates to:
  /// **'L4 领袖'**
  String get user_trustLevel4;

  /// No description provided for @user_trustLevelUnknown.
  ///
  /// In zh, this message translates to:
  /// **'等级 {level}'**
  String user_trustLevelUnknown(int level);

  /// No description provided for @myBrowser_addManually.
  ///
  /// In zh, this message translates to:
  /// **'添加收藏'**
  String get myBrowser_addManually;

  /// No description provided for @myBrowser_bookmarkCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个收藏'**
  String myBrowser_bookmarkCount(int count);

  /// No description provided for @myBrowser_bookmarks.
  ///
  /// In zh, this message translates to:
  /// **'收藏'**
  String get myBrowser_bookmarks;

  /// No description provided for @myBrowser_clearCompleted.
  ///
  /// In zh, this message translates to:
  /// **'清除已完成'**
  String get myBrowser_clearCompleted;

  /// No description provided for @myBrowser_clearCompletedConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定要清除所有已完成的下载记录吗？'**
  String get myBrowser_clearCompletedConfirm;

  /// No description provided for @myBrowser_clearHistory.
  ///
  /// In zh, this message translates to:
  /// **'清空历史'**
  String get myBrowser_clearHistory;

  /// No description provided for @myBrowser_clearHistoryConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定要清空所有浏览历史吗？'**
  String get myBrowser_clearHistoryConfirm;

  /// No description provided for @myBrowser_confirmDelete.
  ///
  /// In zh, this message translates to:
  /// **'确定要删除这条收藏吗？'**
  String get myBrowser_confirmDelete;

  /// No description provided for @myBrowser_delete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get myBrowser_delete;

  /// No description provided for @myBrowser_deleted.
  ///
  /// In zh, this message translates to:
  /// **'已删除收藏'**
  String get myBrowser_deleted;

  /// No description provided for @myBrowser_downloadComplete.
  ///
  /// In zh, this message translates to:
  /// **'下载完成'**
  String get myBrowser_downloadComplete;

  /// No description provided for @myBrowser_downloadEmpty.
  ///
  /// In zh, this message translates to:
  /// **'还没有下载记录'**
  String get myBrowser_downloadEmpty;

  /// No description provided for @myBrowser_downloadFailed.
  ///
  /// In zh, this message translates to:
  /// **'下载失败'**
  String get myBrowser_downloadFailed;

  /// No description provided for @myBrowser_downloadSize.
  ///
  /// In zh, this message translates to:
  /// **'{size} MB'**
  String myBrowser_downloadSize(String size);

  /// No description provided for @myBrowser_downloadStarted.
  ///
  /// In zh, this message translates to:
  /// **'开始下载'**
  String get myBrowser_downloadStarted;

  /// No description provided for @myBrowser_downloading.
  ///
  /// In zh, this message translates to:
  /// **'下载中'**
  String get myBrowser_downloading;

  /// No description provided for @myBrowser_downloads.
  ///
  /// In zh, this message translates to:
  /// **'下载管理'**
  String get myBrowser_downloads;

  /// No description provided for @myBrowser_downloadsDesc.
  ///
  /// In zh, this message translates to:
  /// **'查看下载的文件'**
  String get myBrowser_downloadsDesc;

  /// No description provided for @myBrowser_edit.
  ///
  /// In zh, this message translates to:
  /// **'编辑'**
  String get myBrowser_edit;

  /// No description provided for @myBrowser_editTitle.
  ///
  /// In zh, this message translates to:
  /// **'编辑标题'**
  String get myBrowser_editTitle;

  /// No description provided for @myBrowser_empty.
  ///
  /// In zh, this message translates to:
  /// **'还没有收藏的网页'**
  String get myBrowser_empty;

  /// No description provided for @myBrowser_fileNotFound.
  ///
  /// In zh, this message translates to:
  /// **'文件不存在'**
  String get myBrowser_fileNotFound;

  /// No description provided for @myBrowser_history.
  ///
  /// In zh, this message translates to:
  /// **'浏览历史'**
  String get myBrowser_history;

  /// No description provided for @myBrowser_historyCleared.
  ///
  /// In zh, this message translates to:
  /// **'浏览历史已清空'**
  String get myBrowser_historyCleared;

  /// No description provided for @myBrowser_historyDesc.
  ///
  /// In zh, this message translates to:
  /// **'查看浏览过的网页'**
  String get myBrowser_historyDesc;

  /// No description provided for @myBrowser_historyEmpty.
  ///
  /// In zh, this message translates to:
  /// **'还没有浏览记录'**
  String get myBrowser_historyEmpty;

  /// No description provided for @myBrowser_inputTitle.
  ///
  /// In zh, this message translates to:
  /// **'标题（选填）'**
  String get myBrowser_inputTitle;

  /// No description provided for @myBrowser_inputUrl.
  ///
  /// In zh, this message translates to:
  /// **'输入网址'**
  String get myBrowser_inputUrl;

  /// No description provided for @myBrowser_open.
  ///
  /// In zh, this message translates to:
  /// **'打开'**
  String get myBrowser_open;

  /// No description provided for @myBrowser_title.
  ///
  /// In zh, this message translates to:
  /// **'网页浏览'**
  String get myBrowser_title;

  /// No description provided for @myBrowser_undo.
  ///
  /// In zh, this message translates to:
  /// **'撤销'**
  String get myBrowser_undo;

  /// No description provided for @myBrowser_viewDownload.
  ///
  /// In zh, this message translates to:
  /// **'查看'**
  String get myBrowser_viewDownload;

  /// No description provided for @webviewLogin_clearSaved.
  ///
  /// In zh, this message translates to:
  /// **'清除已保存的密码'**
  String get webviewLogin_clearSaved;

  /// No description provided for @webviewLogin_clearSavedContent.
  ///
  /// In zh, this message translates to:
  /// **'确定要清除已保存的登录凭证吗？下次登录时需要手动输入。'**
  String get webviewLogin_clearSavedContent;

  /// No description provided for @webviewLogin_clearSavedTitle.
  ///
  /// In zh, this message translates to:
  /// **'清除已保存的密码'**
  String get webviewLogin_clearSavedTitle;

  /// No description provided for @webviewLogin_emailLoginInvalidLink.
  ///
  /// In zh, this message translates to:
  /// **'无效的登录链接'**
  String get webviewLogin_emailLoginInvalidLink;

  /// No description provided for @webviewLogin_emailLoginPaste.
  ///
  /// In zh, this message translates to:
  /// **'粘贴登录链接'**
  String get webviewLogin_emailLoginPaste;

  /// No description provided for @webviewLogin_lastLogin.
  ///
  /// In zh, this message translates to:
  /// **'上次登录: @{username}'**
  String webviewLogin_lastLogin(String username);

  /// No description provided for @webviewLogin_loginSuccess.
  ///
  /// In zh, this message translates to:
  /// **'登录成功！'**
  String get webviewLogin_loginSuccess;

  /// No description provided for @webviewLogin_savedPassword.
  ///
  /// In zh, this message translates to:
  /// **'已保存的密码'**
  String get webviewLogin_savedPassword;

  /// No description provided for @webviewLogin_title.
  ///
  /// In zh, this message translates to:
  /// **'登录 Linux.do'**
  String get webviewLogin_title;

  /// No description provided for @webview_addBookmark.
  ///
  /// In zh, this message translates to:
  /// **'收藏此页'**
  String get webview_addBookmark;

  /// No description provided for @webview_bookmarkAdded.
  ///
  /// In zh, this message translates to:
  /// **'已收藏'**
  String get webview_bookmarkAdded;

  /// No description provided for @webview_bookmarkRemoved.
  ///
  /// In zh, this message translates to:
  /// **'已取消收藏'**
  String get webview_bookmarkRemoved;

  /// No description provided for @webview_browser.
  ///
  /// In zh, this message translates to:
  /// **'浏览器'**
  String get webview_browser;

  /// No description provided for @webview_cannotOpenBrowser.
  ///
  /// In zh, this message translates to:
  /// **'无法打开外部浏览器'**
  String get webview_cannotOpenBrowser;

  /// No description provided for @webview_go.
  ///
  /// In zh, this message translates to:
  /// **'前往'**
  String get webview_go;

  /// No description provided for @webview_goBack.
  ///
  /// In zh, this message translates to:
  /// **'后退'**
  String get webview_goBack;

  /// No description provided for @webview_goForward.
  ///
  /// In zh, this message translates to:
  /// **'前进'**
  String get webview_goForward;

  /// No description provided for @webview_inputUrl.
  ///
  /// In zh, this message translates to:
  /// **'输入或编辑网址'**
  String get webview_inputUrl;

  /// No description provided for @webview_noAppForLink.
  ///
  /// In zh, this message translates to:
  /// **'未找到可处理此链接的应用'**
  String get webview_noAppForLink;

  /// No description provided for @webview_openExternal.
  ///
  /// In zh, this message translates to:
  /// **'在外部浏览器打开'**
  String get webview_openExternal;

  /// No description provided for @webview_openFailed.
  ///
  /// In zh, this message translates to:
  /// **'打开失败: {error}'**
  String webview_openFailed(String error);

  /// No description provided for @webview_removeBookmark.
  ///
  /// In zh, this message translates to:
  /// **'取消收藏'**
  String get webview_removeBookmark;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when language+country codes are specified.
  switch (locale.languageCode) {
    case 'zh':
      {
        switch (locale.countryCode) {
          case 'HK':
            return AppLocalizationsZhHk();
          case 'TW':
            return AppLocalizationsZhTw();
        }
        break;
      }
  }

  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
