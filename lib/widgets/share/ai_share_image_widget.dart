import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:jovial_svg/jovial_svg.dart';
import 'package:markdown/markdown.dart' as md;
import '../../constants.dart';
import '../../l10n/s.dart';
import '../../services/emoji_handler.dart';
import '../../utils/url_helper.dart';
import '../../utils/time_utils.dart';
import '../common/emoji_text.dart';
import '../content/discourse_html_content/discourse_html_content_widget.dart';
import 'share_image_preview.dart';

/// AI 分享图片 Widget
/// 用于生成可截图的 AI 消息分享图片，支持单条或多条消息
class AiShareImageWidget extends StatelessWidget {
  /// AI 消息列表（按时间正序）
  final List<AiChatMessage> messages;

  /// 话题标题
  final String topicTitle;

  /// 话题 ID
  final int topicId;

  /// 话题 slug
  final String? topicSlug;

  /// 用于截图的 key
  final GlobalKey repaintBoundaryKey;

  /// 分享图片主题
  final ShareImageTheme shareTheme;

  const AiShareImageWidget({
    super.key,
    required this.messages,
    required this.topicTitle,
    required this.topicId,
    this.topicSlug,
    required this.repaintBoundaryKey,
    required this.shareTheme,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = shareTheme.isDark;
    final bgColor = shareTheme.bgColor;
    final cardColor = shareTheme.cardColor;

    final textColor = isDark ? Colors.white : Colors.black;
    final secondaryTextColor = isDark
        ? Colors.white.withValues(alpha: 0.6)
        : Colors.black.withValues(alpha: 0.6);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.1);

    return RepaintBoundary(
      key: repaintBoundaryKey,
      child: Container(
        width: 375,
        padding: const EdgeInsets.all(20),
        color: bgColor,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Logo + AI 助手标识
            _buildHeader(textColor),
            const SizedBox(height: 16),

            // 话题标题
            _buildTitle(context, textColor),
            const SizedBox(height: 12),

            // 分隔线
            Container(height: 1, color: borderColor),
            const SizedBox(height: 12),

            // 消息内容
            ...messages.asMap().entries.map((entry) {
              final index = entry.key;
              final message = entry.value;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (messages.length > 1)
                    _buildMessageRoleLabel(message, textColor, secondaryTextColor),
                  if (messages.length > 1)
                    const SizedBox(height: 6),
                  _buildContent(context, message, cardColor, textColor),
                  if (index < messages.length - 1)
                    const SizedBox(height: 12),
                ],
              );
            }),

            const SizedBox(height: 16),

            // 分隔线
            Container(height: 1, color: borderColor),
            const SizedBox(height: 12),

            // 底部链接/时间
            _buildFooter(secondaryTextColor),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(Color textColor) {
    return Row(
      children: [
        SizedBox(
          width: 28,
          height: 28,
          child: ScalableImageWidget.fromSISource(
            si: ScalableImageSource.fromSvg(
              rootBundle,
              'assets/logo.svg',
              warnF: (_) {},
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          'LINUX DO',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: textColor.withValues(alpha: 0.8),
          ),
        ),
        const Spacer(),
        Icon(
          Icons.auto_awesome,
          size: 16,
          color: textColor.withValues(alpha: 0.5),
        ),
        const SizedBox(width: 4),
        Text(
          S.current.share_aiAssistant,
          style: TextStyle(
            fontSize: 12,
            color: textColor.withValues(alpha: 0.5),
          ),
        ),
      ],
    );
  }

  Widget _buildTitle(BuildContext context, Color textColor) {
    final titleStyle = TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      color: textColor.withValues(alpha: 0.9),
      height: 1.4,
    );

    return Text.rich(
      TextSpan(
        style: titleStyle,
        children: EmojiText.buildEmojiSpans(context, topicTitle, titleStyle),
      ),
    );
  }

  /// 构建消息角色标签（多消息模式下区分用户/AI）
  Widget _buildMessageRoleLabel(
    AiChatMessage message,
    Color textColor,
    Color secondaryTextColor,
  ) {
    final isUser = message.role == ChatRole.user;
    return Row(
      children: [
        Icon(
          isUser ? Icons.person : Icons.auto_awesome,
          size: 14,
          color: secondaryTextColor,
        ),
        const SizedBox(width: 4),
        Text(
          isUser ? S.current.share_aiQuestion : S.current.share_aiReply,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: secondaryTextColor,
          ),
        ),
      ],
    );
  }

  Widget _buildContent(
    BuildContext context,
    AiChatMessage message,
    Color cardColor,
    Color textColor,
  ) {
    // 复用 MarkdownBody 的 Markdown→HTML 转换逻辑
    final html = _markdownToHtml(message.content);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: DiscourseHtmlContent(
        html: html,
        textStyle: TextStyle(
          fontSize: 14,
          height: 1.6,
          color: textColor.withValues(alpha: 0.85),
        ),
        compact: false,
        enableSelectionArea: false,
        enablePanguSpacing: false,
        screenshotMode: true,
      ),
    );
  }

  /// 将 Markdown 转换为 HTML（复用 MarkdownBody 的逻辑）
  String _markdownToHtml(String data) {
    // 1. 处理 Emoji 替换
    var processedData = EmojiHandler().replaceEmojis(data);

    // 2. 预处理 Discourse 图片格式
    processedData = _processDiscourseImages(processedData);

    // 3. 确保标准 markdown 图片前后有空行
    processedData = processedData.replaceAllMapped(
      RegExp(r'(?<!\n\n)(!\[[^\]]*\]\([^)]+\))'),
      (m) => '\n\n${m.group(1)!}',
    );
    processedData = processedData.replaceAllMapped(
      RegExp(r'(!\[[^\]]*\]\([^)]+\))(?!\n\n)'),
      (m) => '${m.group(1)!}\n\n',
    );
    processedData = processedData.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    processedData = processedData.trim();

    // 4. 使用 GitHub Flavored Markdown 扩展集转换为 HTML
    return md.markdownToHtml(
      processedData,
      extensionSet: md.ExtensionSet.gitHubFlavored,
    );
  }

  /// 处理 Discourse 图片格式
  String _processDiscourseImages(String text) {
    final discourseImageRegex = RegExp(
      r'!\[([^\]|]*)\|(\d+)x(\d+)\]\(([^)\s]+)\)',
    );

    return text.replaceAllMapped(discourseImageRegex, (match) {
      final alt = match.group(1) ?? '';
      final width = match.group(2)!;
      final height = match.group(3)!;
      var src = match.group(4) ?? '';

      src = UrlHelper.resolveUrlWithCdn(src);

      return '\n\n<img src="$src" alt="$alt" width="$width" height="$height">\n\n';
    });
  }

  Widget _buildFooter(Color secondaryTextColor) {
    final url = '${AppConstants.baseUrl}/t/${topicSlug ?? '-'}/$topicId';
    final time = messages.isNotEmpty
        ? TimeUtils.formatDetailTime(messages.last.createdAt)
        : '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 生成标识
        Row(
          children: [
            Icon(
              Icons.auto_awesome,
              size: 12,
              color: secondaryTextColor,
            ),
            const SizedBox(width: 4),
            Text(
              S.current.share_generatedByAi,
              style: TextStyle(
                fontSize: 11,
                color: secondaryTextColor,
              ),
            ),
            if (time.isNotEmpty) ...[
              const Spacer(),
              Text(
                time,
                style: TextStyle(
                  fontSize: 11,
                  color: secondaryTextColor,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        // 链接
        Row(
          children: [
            Icon(
              Icons.link,
              size: 12,
              color: secondaryTextColor,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                url,
                style: TextStyle(
                  fontSize: 10,
                  color: secondaryTextColor,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
