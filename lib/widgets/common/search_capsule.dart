import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../l10n/s.dart';

/// 首页搜索胶囊 ↔ 搜索页搜索框的跨页 Hero tag
const kSearchCapsuleHeroTag = 'topics-search-capsule';

/// 搜索胶囊静态视觉：首页头部 morph 层与 Hero flight shuttle 共用。
///
/// [iconLeftPadding]/[hintOpacity] 由 morph 进度驱动（整行态 16/1.0，
/// 收拢成 40×40 图标态 10/0.0），几何由外层 Positioned.fromRect 控制，
/// 本组件只负责内容排布，任意宽度下都成立。
class SearchCapsule extends StatelessWidget {
  const SearchCapsule({
    super.key,
    this.onTap,
    this.hintOpacity = 1.0,
    this.iconLeftPadding = 16.0,
    this.iconSize = 20.0,
    this.backgroundOpacity = 1.0,
  });

  final VoidCallback? onTap;
  final double hintOpacity;
  final double iconLeftPadding;

  /// glyph 尺寸：整行胶囊态 20（配 14 号 hint 文字），morph 落位后
  /// 插值到 24 与工具栏其他图标（🔔 等默认 24）同大
  final double iconSize;

  /// 灰底不透明度：morph 收尾阶段渐隐到 0，落位后是纯图标
  /// （与工具栏 🔔 等裸图标按钮同族，不带背景色块）
  final double backgroundOpacity;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 固定 40px 高的胶囊必须钳制系统字体缩放（AppBar 标题同款处理）：
    // HyperOS 等大字体档位下 hint 会被放大到撑破胶囊、顶着上下边缘
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.2,
      child: Material(
        color: colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.5 * backgroundOpacity,
        ),
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Row(
            children: [
              SizedBox(width: iconLeftPadding),
              Icon(
                Symbols.search_rounded,
                size: iconSize,
                color: colorScheme.onSurfaceVariant,
              ),
              Expanded(
                child: hintOpacity <= 0
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(left: 8, right: 12),
                        child: Opacity(
                          opacity: hintOpacity,
                          child: Text(
                            S.current.topics_searchHint,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.clip,
                            style: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Hero flight 期间的插值胶囊。
///
/// 旧版是 `const SearchCapsule()` 静态飞行体,与两端真实视觉都不匹配:
/// - 搜索页端没有左侧图标(在 AppBar actions),hint 文案也不同 →
///   pop 起飞瞬间图标凭空出现+文案跳变(每次都有的小闪);
/// - 首页端胶囊随头部 morph 变形(收缩态=纯图标无灰底),shuttle 却
///   永远是完整灰胶囊 → 头部收着时落地瞬间灰底消失/图标跳大跳位
///   (「有时候」的大闪)。
///
/// 现从 Hero 两端捕获真实参数插值:animation 语义两方向恒为
/// 0=首页端、1=搜索页端(与查看器 Hero 同约定)。
Widget searchCapsuleFlightShuttle(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection flightDirection,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  // 首页端 Hero child 就是 SearchCapsule 本体,morph 态参数直接读;
  // 搜索页端 child 是 TextField 容器,读不到 → null 即用整行态默认
  SearchCapsule? homeEnd;
  final fromChild = (fromHeroContext.widget as Hero).child;
  final toChild = (toHeroContext.widget as Hero).child;
  if (fromChild is SearchCapsule) {
    homeEnd = fromChild;
  } else if (toChild is SearchCapsule) {
    homeEnd = toChild;
  }
  return _SearchCapsuleFlight(animation: animation, homeEnd: homeEnd);
}

class _SearchCapsuleFlight extends StatelessWidget {
  const _SearchCapsuleFlight({required this.animation, this.homeEnd});

  final Animation<double> animation;
  final SearchCapsule? homeEnd;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final hintStyle = TextStyle(
      color: colorScheme.onSurfaceVariant,
      fontSize: 14,
    );
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.2,
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, _) {
          final v = animation.value.clamp(0.0, 1.0);
          // 几何:首页真实 morph 态 → 搜索页态(整行胶囊规格)
          final double bgOpacity = lerpDouble(
            homeEnd?.backgroundOpacity ?? 1.0,
            1.0,
            v,
          )!;
          final double iconSize = lerpDouble(
            homeEnd?.iconSize ?? 20.0,
            20.0,
            v,
          )!;
          final double iconLeft = lerpDouble(
            homeEnd?.iconLeftPadding ?? 16.0,
            16.0,
            v,
          )!;
          final double homeHintOpacity =
              (homeEnd?.hintOpacity ?? 1.0) * (1.0 - v);

          Widget hintLayer(double left, String text, double opacity) {
            if (opacity <= 0) return const SizedBox.shrink();
            return Positioned.fill(
              left: left,
              right: 12,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Opacity(
                  opacity: opacity,
                  child: Text(
                    text,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.clip,
                    style: hintStyle,
                  ),
                ),
              ),
            );
          }

          return Material(
            color: colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.5 * bgOpacity,
            ),
            borderRadius: BorderRadius.circular(20),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                // 图标:首页端常驻,搜索页端没有 → 随 v 渐隐
                Positioned.fill(
                  left: iconLeft,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Opacity(
                      opacity: 1.0 - v,
                      child: Icon(
                        Symbols.search_rounded,
                        size: iconSize,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                // 双 hint 交叉淡化(两端文案不同)
                hintLayer(
                  iconLeft + iconSize + 8,
                  S.current.topics_searchHint,
                  homeHintOpacity,
                ),
                // 搜索页 hint 左缘 = 容器 8 + 文本 8 = 16
                hintLayer(16, S.current.search_hintText, v),
              ],
            ),
          );
        },
      ),
    );
  }
}
