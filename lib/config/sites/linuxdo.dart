import 'package:flutter/material.dart';
import '../site_customization.dart';
import '../../widgets/common/holographic_text.dart';

/// linux.do 站点自定义配置
final linuxdoCustomization = SiteCustomization(
  avatarGlowRules: [
    AvatarGlowRule(
      primaryGroupName: 'g-merchant',
      glowColor: Color(0xFFF5BF03),
    ),
    AvatarGlowRule(
      username: 'neo',
      glowColor: Color(0xFF00AEFF),
    ),
  ],
  userTitleStyleRules: [
    UserTitleStyleRule(
      title: '种子用户',
      builder: (title, fontSize) =>
          HolographicText(text: title, fontSize: fontSize),
    ),
    // Premium 头衔跟"种子用户"是同一套站点头衔渐变特效,视觉上应当一致。
    UserTitleStyleRule(
      title: 'Premium',
      builder: (title, fontSize) =>
          HolographicText(text: title, fontSize: fontSize),
    ),
  ],
  linkSecurityConfig: _linuxdoLinkSecurityConfig,
);

/// linux.do 链接安全配置
///
/// 严格对应 JS 主题组件中的配置（settings）+ 社区内置域名（COMMUNITY_*_DOMAINS）合并结果
const _linuxdoLinkSecurityConfig = LinkSecurityConfig(
  enableExitConfirmation: true,
  internalDomains: [
    // settings: internal_domains
    '*.linux.do',
    'localhost',
    // COMMUNITY_INTERNAL_DOMAINS
    '*.local',
    '^127(?:\\.(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)){3}',
    '^10(?:\\.(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)){3}',
    '^169\\.254(?:\\.(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)){2}',
    '^192\\.168(?:\\.(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)){2}',
    '^172\\.(?:1[6-9]|2\\d|3[0-1])(?:\\.(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)){2}',
  ],
  trustedDomains: [
    // settings: trusted_domains
    '*.idcflare.com',
    '*.uasm.net',
    '*.wegram.org',
    // COMMUNITY_TRUSTED_DOMAINS
    '*.zhile.io',
    '*.fuclaude.com',
    '*.linuxdo.org',
    '*.deeplx.org',
    '*.oaifree.com',
    '*.oaipro.com',
    '*.uasm.com',
    't.me/linux_do_channel',
    't.me/idcflare',
    't.me/ja_netfilter_group',
    'github.com/linux-do/*',
  ],
  riskyDomains: [
    // COMMUNITY_RISKY_DOMAINS
    'bit.ly', 'tinyurl.com', 't.co', 'goo.gl', 'ow.ly', 'buff.ly',
    'adf.ly', 'short.link', '*.short.link', 'tiny.cc', 'is.gd',
    'cli.gs', 'pic.gd', 'dwarfurl.com', 'yfrog.com', 'migre.me',
    'ff.im', 'tiny.pl', 'url4.eu', 'tr.im', 'twit.ac', 'su.pr',
    'twurl.nl', 'snipurl.com', 'budurl.com', 'short.to', 'ping.fm',
    'digg.com', 'post.ly', 'just.as', 'bkite.com', 'snipr.com',
    'fic.kr', 'loopt.us', 'doiop.com', 'twitthis.com', 'htxt.it',
    'alturl.com', 'redirx.com', 'digbig.com', 'short.ie',
    'u.mavrev.com', 'kl.am', 'wp.me', 'rubyurl.com', 'om.ly',
    'to.ly', 'bit.do', 'lnkd.in', 'db.tt', 'qr.ae', 'bitly.com',
    'cur.lv', 'ity.im', 'q.gs', 'po.st', 'bc.vc', 'u.to', 'j.mp',
    'buzurl.com', 'cutt.us', 'u.bb', 'yourls.org', 'x.co',
    'prettylinkpro.com', 'scrnch.me', 'filoops.info', 'vzturl.com',
    'qr.net', '1url.com', 'tweez.me', 'v.gd', 'link.zip',
  ],
  dangerousDomains: [
    // COMMUNITY_DANGEROUS_DOMAINS
    '**aff=',
  ],
  blockedDomains: [
    // settings: blocked_domains
    '*.chiddns.com',
    '*.chiclaude.com',
    '*.kcursor.xyz',
  ],
);
