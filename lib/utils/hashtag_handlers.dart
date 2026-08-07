import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxdo_render/fluxdo_render.dart'
    show hashtagIconResolver, hashtagTapHandler;

import '../models/category.dart';
import '../providers/category_provider.dart';
import '../utils/discourse_url_parser.dart';
import '../utils/font_awesome_helper.dart';
import '../utils/tag_icon_list.dart';
import '../widgets/layout/home_workspace_scope.dart';

/// hashtag 药丸(`#分类`/`#标签`)的宿主接入 —— 子包只管画药丸,
/// 图标解析与点击导航都在这里组装(注入点契约见子包 hashtag_icons.dart)。
///
/// 启动期调用一次 [installHashtagHandlers](与 EmojiHandler 同一单例口径)。
void installHashtagHandlers() {
  hashtagIconResolver = _resolveIcon;
  hashtagTapHandler = _handleTap;
}

/// 图标解析:分类药丸优先查分类自己配的图标(cooked 里给的默认图标是
/// `square-full` 色块,不是分类真正的图标 —— 数据在 site.categories,
/// 与编辑器 `#` 补全下拉同源);标签药丸查 [TagIconList];都没有再试
/// cooked 自带的图标名;返回 null 时子包按分类/标签兜底。
IconData? _resolveIcon(BuildContext context, String? iconName, String href) {
  final category = _categoryFromHref(context, href);
  if (category != null) {
    var icon = FontAwesomeHelper.getIcon(category.icon)?.data;
    // 子分类没配图标时用父分类的(topic_detail_header 同款回退)
    if (icon == null && category.parentCategoryId != null) {
      final parent = _categoryById(context, category.parentCategoryId!);
      icon = FontAwesomeHelper.getIcon(parent?.icon)?.data;
    }
    if (icon != null) return icon;
  }

  final tag = DiscourseUrlParser.parseTag(href);
  if (tag != null) {
    final info = TagIconList.get(tag);
    if (info != null) return info.icon.data;
  }

  // square-full 是 Discourse 的"没图标"占位色块,画出来是一坨实心方块,
  // 不如让子包按类型兜底(folder/tag)。
  if (iconName != null && iconName != 'square-full') {
    return FontAwesomeHelper.getIcon(iconName)?.data;
  }
  return null;
}

/// 点击:首页平行视界内,分类/标签药丸直接替换左栏列表(与正文里
/// 普通分类/标签链接同一行为,launchContentLink 同款判定);不在
/// 平行视界(话题详情页等)返回 false,退回 linkHandler 走既有链路
/// (那里同样会处理 /c/ 与 /tag/,还带 WebView 等兜底)。
bool _handleTap(BuildContext context, String href, String? ref, String label) {
  final workspace = HomeWorkspaceScope.maybeOf(context);
  if (workspace == null) return false;

  final category = _categoryFromHref(context, href);
  if (category != null) {
    workspace.onShowCategory(category);
    return true;
  }

  // 标签真名优先取 ref(服务端写下的引用串;中文标签的 URL 段是
  // `<id>-tag` slug,推不回真名),其次 URL,最后药丸文字。
  var tag = ref ?? DiscourseUrlParser.parseTag(href) ?? label;
  if (tag.endsWith('::tag')) {
    tag = tag.substring(0, tag.length - '::tag'.length);
  }
  if (tag.isNotEmpty && !href.contains('/c/')) {
    workspace.onShowTag(tag);
    return true;
  }
  return false;
}

Category? _categoryFromHref(BuildContext context, String href) {
  final info = DiscourseUrlParser.parseCategory(href);
  return info == null ? null : _categoryById(context, info.categoryId);
}

Category? _categoryById(BuildContext context, int id) {
  final container = ProviderScope.containerOf(context, listen: false);
  return container.read(categoryMapProvider).value?[id];
}
