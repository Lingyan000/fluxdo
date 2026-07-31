/// HtmlTextMapper 反查行为验证:全选快路径、lightbox meta 遮罩去噪、
/// 多行段落部分选中不带出兄弟行、内联格式保留。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/html_text_mapper.dart';

void main() {
  test('全选:选中文本等于整帖时直接返回完整 cooked', () {
    const cooked = '<p>第一段</p><p>第二段</p>';
    final result = HtmlTextMapper.extractHtml(cooked, '第一段\n第二段');
    expect(result, cooked);
  });

  test('全选(含图片):img 以 title/alt 计入投影文本,仍命中快路径', () {
    const cooked =
        '<p>前文</p>'
        '<p><img src="https://x.test/a.png" alt="a.png" title="a.png"></p>';
    final result = HtmlTextMapper.extractHtml(cooked, '前文\na.png');
    expect(result, cooked);
  });

  test('lightbox meta 遮罩文本不计入缓冲区,跨图片选区反查成功', () {
    // meta 是纯 CSS hover 遮罩,渲染选区里不存在;不排除会与 img 的
    // title/alt 重复贡献文本,把后续偏移量全部错位。
    const cooked = '<p>前文</p>'
        '<div class="lightbox-wrapper">'
        '<a class="lightbox" href="https://x.test/orig.png">'
        '<img src="https://x.test/opt.png" alt="img.png" title="img.png">'
        '<div class="meta">'
        '<span class="filename">img.png</span>'
        '<span class="informations">100×100</span>'
        '</div></a></div>'
        '<p>后文字</p>';
    final result = HtmlTextMapper.extractHtml(cooked, 'img.png\n后文字');
    expect(result, isNotNull);
    expect(result, contains('<img'));
    expect(result, contains('后文字'));
  });

  test('多行段落只选一行:不把 <p> 的兄弟行整段带出', () {
    const cooked = '<p>一行<br>二行<br>三行</p>';
    // 父元素文本 != 节点文本,没有格式需要保留,应返回 null 降级纯文本,
    // 而不是返回整个 <p> 把三行都带出来。
    final result = HtmlTextMapper.extractHtml(cooked, '二行');
    expect(result, isNull);
  });

  test('完整选中内联格式节点:保留格式标记', () {
    const cooked = '<p>前 <b>加粗</b> 后</p>';
    final result = HtmlTextMapper.extractHtml(cooked, '加粗');
    expect(result, '<b>加粗</b>');
  });
}
