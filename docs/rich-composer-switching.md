# 富文本与源码切换：官方对照及迁移约束

## 核验基线

本地 Discourse 源码 commit：`b3b561e5fad412c038e222499ebe22050b4a8de4`。
以下路径相对于其 `frontend/discourse/app/`：

- `static/prosemirror/core/parser.js`：Markdown-it token 直接映射 schema，不支持的 token 抛出 `UnsupportedTokenError`。
- `static/prosemirror/lib/markdown-it.js`：编辑解析排除 onebox、watched-words、censored；不是阅读 cook。
- `static/prosemirror/components/prosemirror-editor.gjs`：初始/外部值导入只替换文档；内容事务才导出；lastSerialized 防止回声导入。
- `static/prosemirror/extensions/html-block.js`：保留 token.content（首尾 trim），编辑态显示源码，原样序列化。
- `components/d-editor.gjs`：两种编辑器共享 Markdown value；预览 cook 是单独路径。

官方并不保证任意语法字节级无损；不要照搬未知 HTML 属性被忽略的行为。

## 当前生产链路

默认生产入口已经采用 `semantic_composer_codec.dart`：

`raw → parseForEditor → DTO v1 → SemanticComposerCodec → SemanticEditorSession → 绑定的 EditorState 投影`。

整篇导出来自 `session.exportTree()`，不是从裸 EditorBlock 重建树。
旧 `composer_doc_codec.dart` 和整篇 `importEditorTokens` 路径已删除，历史回归已迁正式链路。最新验收及剩余门禁见
[Semantic 生产迁移独立验收](semantic-production-acceptance.md)。

独立编辑引擎排除 onebox/watched-words/censored；普通 cook 仅用于预览与
导入前后辅助门禁。旧 cookForEditor 已删除，阅读解析器也不再接受编辑专用源码占位。

DTO 透传 type/tag/nesting/attrs/content/markup/info/children/meta/map/block/hidden。
BBCode 原生 map 可能不含闭合标签；包装官方规则记录实际消费范围到
meta.fluxdoSource，只有 root=true、范围合法、tokenCount匹配才允许原文切片。
未知嵌套内容不能据此猜测来源；必须由完整顶层单元保留或明确失败。

未支持可编辑模型的可靠顶层单元保留为 rawMarkdown 源码块；这与 rawHtml
分开，导出均保持源码，不加代码围栏。此兼容策略不等于全部插件都有结构化
编辑能力。严格 cooked 门禁仍保留，不以迁移 token 为由删除。

## 本轮安全边界

实现与回归应覆盖：

1. 无内容修改时保留原始文本；选区移动、聚焦及 IR 展开不是提交内容修改。
2. 整篇回写使用 semantic 树导出；IR、选区和对象复制经语义 export binding，继续过滤上传临时节点。
3. 导入绑定原文快照；过期结果不能覆盖新草稿。外部文本替换不能被旧 flush 覆盖。
4. 导入全过程失败/超时安全返回，原文保持；超时不能中断同步 JS，不宣称提供线程隔离。
5. 门禁保护代码缩进、尾空格、空行；诊断不输出用户正文。

## 扩展覆盖与后续约束

核心 token 导入已接通。扩展继续按双向协议维护；新增支持不能只输出文字或
渲染 HTML，不得忽略未知子 token。固定上游版本及插件配置。

按双向能力分阶段迁移：

| 范围 | 导入与导出要求 |
| --- | --- |
| 段落、标题、列表、引用、代码 | 层级、软硬换行、编号和代码空白守恒 |
| 链接、图片 | 显式/自动链接来源、upload 地址、尺寸与缩放独立保留 |
| HTML block / inline | 使用真实 token 边界与属性策略；不做全局正则修复 |
| details、grid、poll 等插件 | 每个扩展配套模型、解析、序列化与 mock 差分样例 |
| 未知 token | 明确失败；只有来源范围可靠且上下文可恢复时才局部保留源码 |

基础 token 路径使用真实 bundle DTO、多轮 cooked 等价及可编辑模型断言验证。未修改节点源片段复用
需要可靠 source map；嵌套容器/上下文变化要使相关片段失效，不能按空行切割。

还需统一三页面切换协议：上传中切换、输入法 composing、预览返回、导入中
切换与错误原因应使用统一状态和约束，而不是各按钮分别加判断。

## 验证分层

- 测试正文、名称、地址全部重新 mock，不复制用户内容。
- Node 真实 bundle 的多轮往返：独立于移动端平台通道。
- 编解码故障注入：每阶段 null、异常、超时和真实空白差异。
- 宿主生命周期：无编辑切换、立即提交、IR 光标停留、卸载回写、草稿替换。
- 三页面上传与中文输入法切换需交互/真机验证；不能由纯模型测试替代。

## 历史验证记录

以下为 token 迁移阶段记录，不是当前 semantic 测试总数；当前组合结果以 [生产验收](semantic-production-acceptance.md) 为准。

子包非 golden 全量测试通过。全量出现的33项golden失败，已在同环境使用
子包 git archive HEAD 的隔离副本（不含本轮修改）复跑对应三个测试文件，
得到完全相同失败列表；未更新golden。该基线问题独立跟进，不能宣称全量绿灯。

移动端 QuickJS/JSC、中文输入法与三页面端到端切换仍需真机验证。

### 当前兼容边界

本轮媒体、投票、表格对齐、日期范围/周期、BBCode来源、附件原链、嵌套松散列表及
基础脚注已恢复结构化能力，详见 `editor-token-migration-audit.md` 的修复与验收节。
不是所有 HTML 都应变为源码：完整 video/audio 优先真实媒体节点，复杂混合 HTML
才保源。模型无法表达的重复/空HTML行内结构以及非TeX数学暂保完整源码。

复杂多段脚注安全拒绝（宿主保留原文），未注册第三方color/size样式仍待独立扩展。
这些边界不以通过若干样例冒充全部兼容。

### 空引用边界

末尾独立 `>` 是合法空引用，不是可删除的空白。官方token包含空的
blockquote_open/close；doc_converter必须补带QuoteFrame的空TextBlock，
否则节点在展平阶段消失。嵌套`> >`同理。回归必须包含完整正文后追加
空引用，不能在mock时把它当提问分隔符删掉。
