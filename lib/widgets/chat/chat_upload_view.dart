import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../constants.dart';
import '../../models/chat/chat_message.dart';
import '../../pages/image_viewer_page.dart';
import '../common/cached_image.dart';

/// 消息附带的上传文件:图片直接展示(限宽等比),其它文件画成附件卡片,
/// 点击用系统方式打开源链接。图片/附件**不在** cooked HTML 里(官方
/// `Chat::MessageSerializer` 单独给 `uploads` 数组,网页端也是正文下方
/// 另行渲染),任何展示聊天消息正文的地方都要单独渲染这个,不能只信 cooked。
class ChatUploadView extends StatelessWidget {
  const ChatUploadView({super.key, required this.upload});

  final ChatUpload upload;

  String get _resolvedUrl {
    final url = upload.url;
    if (url.startsWith('//')) return 'https:$url';
    if (url.startsWith('/')) return '${AppConstants.baseUrl}$url';
    return url;
  }

  @override
  Widget build(BuildContext context) {
    if (upload.isImage) {
      final width = upload.width;
      final height = upload.height;
      final aspect = (width != null && height != null && height > 0)
          ? width / height
          : null;
      return GestureDetector(
        onTap: () => ImageViewerPage.open(
          context,
          _resolvedUrl,
          heroTag: 'chat_upload_${upload.id ?? upload.url}',
          filenames: [upload.originalFilename],
          enableShare: true,
        ),
        child: Hero(
          tag: 'chat_upload_${upload.id ?? upload.url}',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320, maxHeight: 320),
              child: aspect != null
                  ? AspectRatio(
                      aspectRatio: aspect,
                      child: CachedImage(url: _resolvedUrl, fit: BoxFit.cover),
                    )
                  : CachedImage(url: _resolvedUrl, fit: BoxFit.contain),
            ),
          ),
        ),
      );
    }
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => launchUrl(Uri.parse(_resolvedUrl),
          mode: LaunchMode.externalApplication),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.attach_file_rounded, size: 18),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                upload.originalFilename ?? '附件',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
