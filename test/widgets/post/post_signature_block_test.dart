import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/post/post_signature_block.dart';

void main() {
  group('小尾巴图片来源限制', () {
    test('允许指定的三个域名', () {
      expect(
        PostSignatureBlock.isAllowedImageUrl(
          'https://prompt.iwooji.com/signature.svg',
        ),
        isTrue,
      );
      expect(
        PostSignatureBlock.isAllowedImageUrl(
          'https://cdn3.ldstatic.com/signature.png',
        ),
        isTrue,
      );
      expect(
        PostSignatureBlock.isAllowedImageUrl(
          'https://idcflare.com/signature.webp',
        ),
        isTrue,
      );
    });

    test('拒绝其他域名和伪装域名', () {
      expect(
        PostSignatureBlock.isAllowedImageUrl(
          'https://example.com/signature.svg',
        ),
        isFalse,
      );
      expect(
        PostSignatureBlock.isAllowedImageUrl(
          'https://cdn3.ldstatic.com.example.com/signature.svg',
        ),
        isFalse,
      );
      expect(
        PostSignatureBlock.isAllowedImageUrl(
          'https://cdn.prompt.iwooji.com/signature.svg',
        ),
        isFalse,
      );
      expect(
        PostSignatureBlock.isAllowedImageUrl(
          'https://www.idcflare.com/signature.svg',
        ),
        isFalse,
      );
      expect(
        PostSignatureBlock.isAllowedImageUrl(
          'https://example.com/prompt.iwooji.com/signature.svg',
        ),
        isFalse,
      );
    });

    test('拒绝相对地址和非 HTTP 协议', () {
      expect(PostSignatureBlock.isAllowedImageUrl('/signature.svg'), isFalse);
      expect(
        PostSignatureBlock.isAllowedImageUrl(
          'file://cdn3.ldstatic.com/signature.svg',
        ),
        isFalse,
      );
    });
  });
}
