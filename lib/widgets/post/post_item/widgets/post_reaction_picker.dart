import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../models/topic.dart';
import '../../../../services/discourse_cache_manager.dart';
import '../../../../services/emoji_handler.dart';

/// 回应选择器弹窗
class PostReactionPicker {
  /// 显示回应选择器
  static void show({
    required BuildContext context,
    required ThemeData theme,
    required GlobalKey likeButtonKey,
    required List<String> reactions,
    required PostReaction? currentUserReaction,
    required void Function(String reactionId) onReactionSelected,
  }) {
    final box = likeButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;

    final buttonPos = box.localToGlobal(Offset.zero);
    final buttonSize = box.size;
    final screenWidth = MediaQuery.of(context).size.width;

    // 配置参数
    const double itemSize = 40.0;
    const double iconSize = 26.0;
    const double spacing = 1.0;
    const double padding = 4.0;
    const int crossAxisCount = 5;

    // 计算尺寸
    final int count = reactions.length;
    final int cols = count < crossAxisCount ? count : crossAxisCount;
    final int rows = (count / crossAxisCount).ceil();

    final double pickerWidth = (itemSize * cols) + (spacing * (cols - 1)) + (padding * 2) + 4.0;
    final double pickerHeight = (itemSize * rows) + (spacing * (rows - 1)) + (padding * 2);

    // 计算左边位置：居中于按钮，但限制在屏幕内
    double left = (buttonPos.dx + buttonSize.width / 2) - (pickerWidth / 2);
    if (left < 16) left = 16;
    if (left + pickerWidth > screenWidth - 16) left = screenWidth - pickerWidth - 16;

    // 计算顶部位置：默认在按钮上方
    bool isAbove = true;
    double top = buttonPos.dy - pickerHeight - 12;
    if (top < 80) {
      top = buttonPos.dy + buttonSize.height + 12;
      isAbove = false;
    }

    // 计算动画原点 Alignment
    final buttonCenterX = buttonPos.dx + buttonSize.width / 2;
    final relativeX = (buttonCenterX - left) / pickerWidth;
    final alignmentX = relativeX * 2 - 1;
    final alignmentY = isAbove ? 1.0 : -1.0;

    final transformAlignment = Alignment(alignmentX, alignmentY);

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 450),
      pageBuilder: (_, _, _) => const SizedBox(),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curvedValue = Curves.elasticOut.transform(animation.value);
        final opacity = (animation.value / 0.15).clamp(0.0, 1.0);

        return Stack(
          children: [
            // 全屏透明点击层
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => Navigator.pop(context),
                child: Container(color: Colors.transparent),
              ),
            ),
            // 气泡主体
            Positioned(
              left: left,
              top: top,
              child: Transform.scale(
                scale: curvedValue,
                alignment: transformAlignment,
                child: Opacity(
                  opacity: opacity,
                  child: Material(
                    color: Colors.transparent,
                    child: Container(
                      width: pickerWidth,
                      height: pickerHeight,
                      padding: const EdgeInsets.all(padding),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(30),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.15),
                            blurRadius: 16,
                            spreadRadius: 2,
                            offset: const Offset(0, 4),
                          ),
                        ],
                        border: Border.all(
                          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
                          width: 0.5,
                        ),
                      ),
                      child: Wrap(
                        spacing: spacing,
                        runSpacing: spacing,
                        alignment: WrapAlignment.center,
                        children: reactions.map((r) {
                          final isCurrent = currentUserReaction?.id == r;
                          return GestureDetector(
                            onTap: () {
                              HapticFeedback.lightImpact();
                              Navigator.pop(context);
                              onReactionSelected(r);
                            },
                            child: Container(
                              width: itemSize,
                              height: itemSize,
                              decoration: BoxDecoration(
                                color: isCurrent ? theme.colorScheme.primaryContainer : Colors.transparent,
                                shape: BoxShape.circle,
                              ),
                              child: Center(
                                child: Image(
                                  image: discourseImageProvider(EmojiHandler().getEmojiUrl(r)),
                                  width: iconSize,
                                  height: iconSize,
                                  errorBuilder: (_, _, _) => const Icon(Icons.emoji_emotions_outlined, size: 24),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
