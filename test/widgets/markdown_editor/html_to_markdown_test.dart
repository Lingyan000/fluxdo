/// 剪贴板 HTML → markdown 清洗层(html2md 管线)行为验证:
/// 常见结构(标题/强调/链接/列表/引用/代码/表格/图片)、Word 垃圾
/// 剥离、脏 HTML 降级不炸、空产物返回 null。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/html_to_markdown.dart';

void main() {
  test('基本块与行内:标题/粗斜体/链接/列表/引用', () {
    final md = clipboardHtmlToMarkdown('''
<h2>标题二</h2>
<p>正文 <strong>加粗</strong> 与 <em>斜体</em>,<a href="https://example.com">链接</a>。</p>
<ul><li>甲</li><li>乙</li></ul>
<ol><li>一</li><li>二</li></ol>
<blockquote><p>引用行</p></blockquote>
''')!;
    expect(md, contains('## 标题二'));
    expect(md, contains('**加粗**'));
    expect(md, contains('*斜体*'));
    expect(md, contains('[链接](https://example.com)'));
    // html2md 列表 marker 后跟对齐空格(`-   甲`),cook 接受;粘贴
    // 产物经序列化器重写后归一,无需后处理
    expect(md, matches(RegExp(r'-\s+甲')));
    expect(md, matches(RegExp(r'1\.\s+一')));
    expect(md, contains('> 引用行'));
  });

  test('代码块 = fenced;行内代码保留', () {
    final md = clipboardHtmlToMarkdown(
      '<pre><code>void main() {}\n</code></pre><p>行内 <code>x = 1</code></p>',
    )!;
    expect(md, contains('```'));
    expect(md, contains('void main() {}'));
    expect(md, contains('`x = 1`'));
  });

  test('图片 → markdown 图', () {
    final md = clipboardHtmlToMarkdown(
      '<p><img src="https://x.test/a.png" alt="示意"></p>',
    )!;
    expect(md, contains('![示意](https://x.test/a.png)'));
  });

  test('表格转换(观察 html2md 能力面)', () {
    final md = clipboardHtmlToMarkdown('''
<table>
<thead><tr><th>列A</th><th>列B</th></tr></thead>
<tbody><tr><td>1</td><td>2</td></tr></tbody>
</table>
''');
    // html2md 若不支持表格会退化为纯文本行 —— 断言内容至少不丢
    expect(md, isNotNull);
    expect(md, contains('列A'));
    expect(md, contains('1'));
  });

  test('Word 垃圾:条件注释/o:p/style 块剥离,nbsp 归一', () {
    final md = clipboardHtmlToMarkdown('''
<html xmlns:o="urn:schemas-microsoft-com:office:office">
<head><style>p.MsoNormal { margin: 0; }</style></head>
<body>
<!--[if gte mso 9]><xml><o:OfficeDocumentSettings/></xml><![endif]-->
<p class="MsoNormal">Word&nbsp;正文<o:p></o:p></p>
</body></html>
''')!;
    expect(md, contains('Word 正文'));
    expect(md, isNot(contains('MsoNormal')));
    expect(md, isNot(contains('mso')));
    expect(md, isNot(contains(' ')));
  });

  test('嵌套 div 汤不产生大段空行', () {
    final md = clipboardHtmlToMarkdown(
      '<div><div><div><p>甲</p></div></div><div><div><p>乙</p></div></div></div>',
    )!;
    expect(md, isNot(contains('\n\n\n')));
    expect(md, contains('甲'));
    expect(md, contains('乙'));
  });

  test('空/纯标签输入返回 null', () {
    expect(clipboardHtmlToMarkdown(''), isNull);
    expect(clipboardHtmlToMarkdown('<div><span></span></div>'), isNull);
  });

  test('data:/file: 图剥离(留 alt 文本;正常 http 图保留)', () {
    final md = clipboardHtmlToMarkdown(
      '<p>前 <img src="data:image/png;base64,iVBORw0KGgoAAAANSUhEU" alt="截图"> 中'
      ' <img src="file:///C:/Users/x/pic.png"> 后'
      ' <img src="https://x.test/ok.png" alt="好图"></p>',
    )!;
    expect(md, isNot(contains('data:')));
    expect(md, isNot(contains('file:')));
    expect(md, contains('截图'), reason: 'alt 文本占位保留');
    expect(md, contains('![好图](https://x.test/ok.png)'));
  });

  test('代码编辑器着色 dump(等宽字体族)→ null 走纯文本', () {
    // VSCode 复制代码的典型 html 形态
    expect(
      clipboardHtmlToMarkdown(
        '<meta charset=\'utf-8\'><div style="color: #d4d4d4;background-color:'
        ' #1e1e1e;font-family: Consolas, \'Courier New\', monospace;'
        'font-size: 14px;"><div><span style="color:#569cd6;">void</span>'
        '<span> main() {}</span></div></div>',
      ),
      isNull,
    );
    // 正文里出现 "Courier" 字样(非 style)不误伤
    expect(
      clipboardHtmlToMarkdown('<p>Courier 是一种字体</p>'),
      contains('Courier'),
    );
  });
}
