import 'package:flutter/material.dart';
import 'color_utils.dart';
import 'font_awesome_helper.dart';

class TagIconInfo {
  final IconData icon;
  final Color color;

  const TagIconInfo({required this.icon, required this.color});
}

class TagIconList {
  // Format: "tag,icon,color|tag,icon,color"
  static const String _raw =
      '公告,bullhorn,#00aeff|精华神帖,thumbs-up,#00aeff|快问快答,circle-question,#669d34|nsfw,triangle-exclamation,#F7941D|文档,book,#75b6d7|碎碎碎念,droplet,#00aeff|病友,user-injured,#F7941D|人工智能,brain,#bd93f9|游戏,gamepad,#669d34|职场,briefcase,#669d34|拼车,car,#669d34|网络安全,user-secret,#ff1111|金融经济,hand-holding-dollar,#669d34|赏金任务,comment-dollar,#669d34|音乐,music,#669d34|影视,video,#669d34|旅行,route,#669d34|美食,pepper-hot,#669d34|二次元,venus,#669d34|动漫,face-smile,#669d34|软件开发,file-code,#669d34|配置优化,terminal,#669d34|软件测试,bug,#669d34|软件调试,spider,#669d34|vps,server,#669d34|硬件开发,file-code,#669d34|硬件测试,bug,#669d34|硬件调试,spider,#669d34|摄影,camera,#669d34|嵌入式,microchip,#669d34|健身,heart-pulse,#669d34|算法,calculator,#669d34|抽奖,shuffle,#F7941D|aff,arrow-pointer,#f7941D|订阅节点,network-wired,#669d34|数据库,database,#669d34|计算机网络,ethernet,#669d34|纯水,faucet,#f7941d|求资源,hands-praying,#669d34|禁水,droplet-slash,#ff5555|树洞,tree,#669d34|危险,radiation,#ff1111|封禁,user-slash,#ff4444|livestream,headset,#00aeff|转载,share,#669d34|推广,receipt,#669d34|高级推广,coins,#F5bF03|公益推广,receipt,#669d34|优质博文,blog,#00aeff|作品集,palette,#669d34|原创,lightbulb,#00aeff|集中帖,people-group,#00aeff';

  static final Map<String, TagIconInfo> _map = _buildMap();

  static TagIconInfo? get(String tagName) {
    final key = tagName.trim();
    if (key.isEmpty) return null;
    return _map[key];
  }

  static Map<String, TagIconInfo> _buildMap() {
    final map = <String, TagIconInfo>{};
    final items = _raw.split('|');
    for (final item in items) {
      final parts = item.split(',');
      if (parts.length < 3) continue;
      final name = parts[0].trim();
      final iconName = parts[1].trim();
      final colorHex = parts[2].trim();
      if (name.isEmpty || iconName.isEmpty || colorHex.isEmpty) continue;
      final icon = FontAwesomeHelper.getIcon(iconName);
      if (icon == null) continue;
      map[name] = TagIconInfo(icon: icon, color: ColorUtils.parseHex(colorHex));
    }
    return map;
  }

}
