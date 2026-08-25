// 全局图标中心层 —— Flux 图标统一收口
//
// 规则（务必遵守）：
//   1. 全 App 只用 Material Symbols Rounded 一种风格；缺失时走自绘（AppCustomIcon）。
//   2. 业务/页面代码禁止直接引用 `Icons.*` / `Symbols.*` / `PhosphorIcons.*`，
//      所有图标必须经过本文件暴露的 AppIcons 常量。
//   3. "操作类"图标恒为线框；渲染由全局 IconTheme 统一控制 fill=0 / weight=400 /
//      grade=0 / opticalSize=24。
//   4. "状态类"图标（同一概念有 选中/未选中 两态）用同一个 IconData，渲染时通过
//      `Icon(..., fill: isActive ? 1 : 0)` 切换实/空。**绝不允许** 用
//      xxx_border / xxx_outline 这种不同名字的变体表达同一概念的两态。
//   5. 自绘图标：用 [AppCustomIcon] 包装 [IconPainterBuilder]，并在调用处用
//      [AppIcon] 渲染。AppCustomIcon 同样支持 fill/size/color，遵循 IconTheme。
//   6. 例外：社区数据驱动的 badge/tag/category 图标继续走 font_awesome。
library;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'icon_painters.dart';

/// 一个"图标值"——可能是字体图标（[IconData]）或自绘图标（[AppCustomIcon]）。
///
/// 中心层暴露的所有图标常量都是 [AppIconSpec]；调用方用 [AppIcon] 渲染时
/// 不需要关心背后是字体还是自绘。
sealed class AppIconSpec {
  const AppIconSpec();
}

/// 字体图标（Material Symbols 等）。
class AppFontIcon extends AppIconSpec {
  final IconData data;
  const AppFontIcon(this.data);
}

/// 自绘图标。提供一个 painter builder：`(color, fill) → CustomPainter`。
///
/// `fill` 取自全局 IconTheme 或调用方 [AppIcon] 传入；painter 应在 0~1 之间平滑
/// 过渡轮廓与填充。如果自绘图标只支持单形态，painter 可忽略 fill。
class AppCustomIcon extends AppIconSpec {
  final IconPainterBuilder painterBuilder;

  /// 设计稿尺寸（painter 用归一化坐标时应基于此 box）。渲染时按 size 缩放。
  final Size designSize;
  const AppCustomIcon(this.painterBuilder, {this.designSize = const Size(24, 24)});
}

/// painter 构造函数签名。color/fill 由 [AppIcon] 渲染时注入。
typedef IconPainterBuilder = CustomPainter Function({
  required Color color,
  required double fill,
  required double strokeWidth,
});

/// 内部隐式转换：直接把 [IconData] 当 [AppIconSpec] 用。
extension IconDataToSpec on IconData {
  AppFontIcon get asSpec => AppFontIcon(this);
}

/// 全 App 图标统一出口。仅暴露常量，不要在这里写组件。
abstract final class AppIcons {
  // ─── 导航 / 通用操作 ────────────────────────────────────────────────
  static const close = Symbols.close_rounded;
  static const back = Symbols.arrow_back_rounded;
  static const forward = Symbols.arrow_forward_rounded;
  static const up = Symbols.arrow_upward_rounded;
  static const down = Symbols.arrow_downward_rounded;
  static const chevronLeft = Symbols.chevron_left_rounded;
  static const chevronRight = Symbols.chevron_right_rounded;
  static const expandMore = Symbols.expand_more_rounded;
  static const expandLess = Symbols.expand_less_rounded;
  static const dropdown = Symbols.arrow_drop_down_rounded;
  static const dropup = Symbols.arrow_drop_up_rounded;
  static const menu = Symbols.menu_rounded;
  static const moreHoriz = Symbols.more_horiz_rounded;
  static const moreVert = Symbols.more_vert_rounded;
  static const check = Symbols.check_rounded;
  static const checkAll = Symbols.done_all_rounded;
  static const add = Symbols.add_rounded;
  static const remove = Symbols.remove_rounded;
  static const search = Symbols.search_rounded;
  static const filter = Symbols.filter_list_rounded;
  static const filterOff = Symbols.filter_list_off_rounded;
  static const sort = Symbols.sort_rounded;
  static const tune = Symbols.tune_rounded;
  static const refresh = Symbols.refresh_rounded;
  static const sync = Symbols.sync_rounded;

  // ─── 文件 / 内容操作 ───────────────────────────────────────────────
  static const copy = Symbols.content_copy_rounded;
  static const cut = Symbols.content_cut_rounded;
  static const paste = Symbols.content_paste_rounded;
  static const delete = Symbols.delete_rounded;
  static const edit = Symbols.edit_rounded;
  static const save = Symbols.save_rounded;
  static const saveAlt = Symbols.save_alt_rounded;
  static const download = Symbols.download_rounded;
  static const upload = Symbols.upload_rounded;
  static const share = Symbols.share_rounded;
  static const reply = Symbols.reply_rounded;
  static const replyAll = Symbols.reply_all_rounded;
  static const forwardMsg = Symbols.forward_rounded;
  static const send = Symbols.send_rounded;
  static const openInNew = Symbols.open_in_new_rounded;
  static const link = Symbols.link_rounded;
  static const linkOff = Symbols.link_off_rounded;
  static const code = Symbols.code_rounded;
  static const formatQuote = Symbols.format_quote_rounded;

  // ─── 媒体 / 视图 ───────────────────────────────────────────────────
  static const image = Symbols.image_rounded;
  static const imageBroken = Symbols.broken_image_rounded;
  static const videoLibrary = Symbols.video_library_rounded;
  static const play = Symbols.play_arrow_rounded;
  static const pause = Symbols.pause_rounded;
  static const camera = Symbols.photo_camera_rounded;
  static const brush = Symbols.brush_rounded;
  static const gallery = Symbols.photo_library_rounded;

  // ─── 状态类（同一 IconData，fill 切实/空） ────────────────────────
  // 用法：`Icon(AppIcons.bookmark, fill: isBookmarked ? 1 : 0)`
  static const bookmark = Symbols.bookmark_rounded;
  static const notification = Symbols.notifications_rounded;
  static const favorite = Symbols.favorite_rounded;
  static const star = Symbols.star_rounded;
  static const heart = Symbols.favorite_rounded;
  static const visibility = Symbols.visibility_rounded;
  static const visibilityOff = Symbols.visibility_off_rounded;
  static const pushPin = Symbols.push_pin_rounded;
  static const chatBubble = Symbols.chat_bubble_rounded;
  static const thumbUp = Symbols.thumb_up_rounded;
  static const thumbDown = Symbols.thumb_down_rounded;
  static const checkBox = Symbols.check_box_rounded;
  static const radioButton = Symbols.radio_button_checked_rounded;
  static const radioButtonOff = Symbols.radio_button_unchecked_rounded;
  static const playCircle = Symbols.play_circle_rounded;

  // ─── 用户 / 账户 ───────────────────────────────────────────────────
  static const person = Symbols.person_rounded;
  static const people = Symbols.group_rounded;
  static const account = Symbols.account_circle_rounded;
  static const login = Symbols.login_rounded;
  static const logout = Symbols.logout_rounded;
  static const lock = Symbols.lock_rounded;
  static const lockOpen = Symbols.lock_open_rounded;
  static const key = Symbols.key_rounded;
  static const shield = Symbols.shield_rounded;
  static const security = Symbols.security_rounded;
  static const verifiedUser = Symbols.verified_user_rounded;
  static const medal = Symbols.workspace_premium_rounded;

  // ─── 通讯 / 通知 ───────────────────────────────────────────────────
  static const mail = Symbols.mail_rounded;
  static const forum = Symbols.forum_rounded;
  static const message = Symbols.message_rounded;
  static const announcement = Symbols.campaign_rounded;

  // ─── 状态反馈 ─────────────────────────────────────────────────────
  static const info = Symbols.info_rounded;
  static const help = Symbols.help_rounded;
  static const warning = Symbols.warning_rounded;
  static const error = Symbols.error_rounded;
  static const checkCircle = Symbols.check_circle_rounded;
  static const cancelCircle = Symbols.cancel_rounded;
  static const doNotDisturb = Symbols.do_not_disturb_on_rounded;
  static const block = Symbols.block_rounded;
  static const loading = Symbols.hourglass_top_rounded;

  // ─── 结构 / 布局 ───────────────────────────────────────────────────
  static const settings = Symbols.settings_rounded;
  static const home = Symbols.home_rounded;
  static const article = Symbols.article_rounded;
  static const book = Symbols.menu_book_rounded;
  static const autoStories = Symbols.auto_stories_rounded;
  static const folder = Symbols.folder_rounded;
  static const accountTree = Symbols.account_tree_rounded;
  static const category = Symbols.category_rounded;
  static const tag = Symbols.tag_rounded;
  static const history = Symbols.history_rounded;
  static const lockClock = Symbols.lock_clock_rounded;
  static const cloud = Symbols.cloud_rounded;
  static const cloudOff = Symbols.cloud_off_rounded;
  static const hub = Symbols.hub_rounded;
  static const language = Symbols.language_rounded;
  static const palette = Symbols.palette_rounded;
  static const colorLens = Symbols.color_lens_rounded;
  static const speed = Symbols.speed_rounded;
  static const rocket = Symbols.rocket_launch_rounded;
  static const touchApp = Symbols.touch_app_rounded;
  static const wallet = Symbols.account_balance_wallet_rounded;
  static const token = Symbols.token_rounded;
  static const description = Symbols.description_rounded;
  static const military = Symbols.military_tech_rounded;
  static const addComment = Symbols.add_comment_rounded;
  static const emoji = Symbols.emoji_emotions_rounded;
  static const autoAwesome = Symbols.auto_awesome_rounded;
  static const autoFixHigh = Symbols.auto_fix_high_rounded;
  static const callSplit = Symbols.call_split_rounded;

  // ─── 自绘图标（Material Symbols 没有合适字形时） ─────────────────
  // 表情 Tab 用的笑脸（更柔和，配合 fill 切实/空）
  static final AppCustomIcon smileyOutline = AppCustomIcon(
    ({required color, required fill, required strokeWidth}) =>
        SmileyPainter(color: color, fill: fill, strokeWidth: strokeWidth),
  );
  // 贴纸 Tab 用的贴纸图标
  static final AppCustomIcon stickerOutline = AppCustomIcon(
    ({required color, required fill, required strokeWidth}) =>
        StickerPainter(color: color, fill: fill, strokeWidth: strokeWidth),
  );
}
