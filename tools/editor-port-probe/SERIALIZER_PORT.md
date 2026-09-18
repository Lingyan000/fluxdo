# 独立 Dart serializer 移植记录

实现：`packages/fluxdo_render/lib/src/editor/port_probe/serializer.dart`。
公开入口：`String serializeProbe(ProbeNode doc)`；只引用独立 `model.dart`，不调用生产 `docToMarkdown`，无新增依赖。

## 来源对应

固定 Discourse commit、各文件 SHA-256 见 `source-manifest.v1.json`。

| 来源 | Dart 对应 |
| --- | --- |
| `prosemirror-markdown@1.13.4/src/to_markdown.ts` | 延迟 `closed`、`flushClose`、`write/text/esc`、`wrapBlock/renderList`、`renderInline` active mark 栈、mixable 重排、首尾空白外移、code fence/backticks |
| Discourse `core/serializer.js` | 文本 autolink 转义开关、hard_break 的 inTable 分支、convert 后置 serializer 时序 |
| `extensions/link.js` | markup 决定 autolink/linkify，attachment、data-orig-href 优先、href/title 转义；不根据编辑后文本重新推断链接类型 |
| `extensions/quote.js` | displayName/username/postNumber/topicId BBCode 参数及显式尾换行 |
| `extensions/bullet-list.js`、`ordered-list.js` | 扩展只覆写 schema 默认 tight=true，序列化算法仍来自 PM；state 缺省 tight=false，真实 schema attrs 由 model/parser 提供 |
| `extensions/html-inline.js` | htmlAttrs 按插入顺序写入及四种 HTML 属性转义，递归 renderInline |
| `extensions/html-block.js` | 不转义原始文本，显式双换行 |
| details `rich-editor-extension.js` | summary 独立输出、直接文本子节点、引号替换、忽略 open 属性、结束双换行 |
| footnote `rich-editor-extension.js` | 单段 inline footnote、块脚注登记/后置渲染、四空格缩进；保留官方单段 renderContent 绕过 mark 行为 |

## 最小运行 API 与成本

约 400 行 Dart 状态机，不是全 PM 移植。依赖模型仅需：node 的 type/attrs/content/marks/text/textContent/copy，mark 的 type/attrs，以及 sameMarks 结构比较和 ProbeUnsupported。

内部状态：out、delim、closed、atBlockStart、inTightList、inAutolink、linkMarkup、inTable、footnoteContents。
内部算法接口：flushClose、write、text、esc、closeBlock、wrapBlock、render、renderContent、renderInline、renderList、markString、isMarkAhead、backticksFor、afterSerialize。

已实现本次八扩展实际需要的状态。inTable 仅用于 core hard_break 分支，不表示已移植 table 扩展；本次没有图片节点、通用 serializer 注册系统、完整 schema/content-match、DOM Serializer、UI plugin、事务映射或 typography 设置反向替换。oracle 固定 typography=false，因此原样文本正是其语义。未使用的 PM quote/repeat/ensureNewLine 公共辅助接口没有独立暴露（重复字符串使用 Dart 操作符）。这些是扩展范围时的新增成本，不能由当前通过测试推断完整编辑器兼容。

## 验证

`cd packages/fluxdo_render && flutter test test/editor/port_probe_serializer_test.dart`

实际通过 95 个 oracle case，包括标准空/嵌套 blockquote、嵌套 loose list、基础 marks、八扩展和真实编辑后输出。测试从 oracle 的 doc 构造不可变节点，调用 applyProbeEdit 后重新序列化；原文及编辑后都使用 String 精确比较，包含尾换行，不做 normalize/trim。

实现保留上游 `isMarkAhead` 对 hard_break 的双递增语义以及扩展自身的反直觉输出；这是兼容性探针，不是推荐生产沿用这些行为。
