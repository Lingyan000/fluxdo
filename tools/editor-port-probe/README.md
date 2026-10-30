# 独立 Discourse JS oracle（Dart 移植成本探针）

这不是新生产 bundle，也不是独立重写的 Markdown oracle。测试目录内用 esbuild **直接加载固定 Discourse commit 的 parser、schema、serializer、8 个扩展完整源文件**，由真实 ProseMirror 执行。运行方式和 JSON/编辑协议见 [CONTRACT.md](CONTRACT.md)。

## 固定版本与可复现性

- Discourse：`b3b561e5fad412c038e222499ebe22050b4a8de4`。
- 默认源码路径 `/Users/pengyongteng1/f/discourse`；可用 `DISCOURSE_ROOT` 指向同一 commit。build 检查 HEAD 及所有加载源码内容与 commit blob 相等，拒绝脏源码。
- ProseMirror、orderedmap 测试依赖使用该仓库 `pnpm-lock.yaml` 的锁定版本；本目录自己的 lock 固定完整依赖图。没有 pubspec 或 app 运行依赖改动。
- `source-manifest.v1.json` 记录被打包的每个官方文件 SHA-256、上游 lock、测试 lock、现有 tokenizer bundle hash。测试检测产物与实时转换/hash 一致。
- 本机实际使用 pnpm 8.15.9、Node 24；安装已完成，未发生网络失败或切换搜索服务。先阅读了 pnpm skill。

## 明确 adaptation（不能称作全官方编辑器）

1. 将官方 core/parser 的 `../lib/markdown-it` 模块替换为 DTO 注入函数。token 来自**未修改**的 `assets/cook/discourse-cook.js` 的 `parseForEditor`；其版本由 hash 固定，而不是声称该 bundle 所有代码都出自这里的 commit。
2. DTO 补回官方 handler 所需的 `attrGet` 方法；每次 parse 深拷贝，因为 quote/link/footnote 官方逻辑会原地修改 token。map/meta（含 Fluxdo source range）保留，不参与重新解释。
3. `link.js` 的 UI-only `plugin-utils` 两个 import 用一调用即抛错的替身；parse/schema/serialize 路径不调用它们。其余依赖（含 typography helper）为官方源码或真实 ProseMirror 包。没有自己实现 link/quote/details/HTML/footnote handler。
4. jsdom 25.0.1 提供 HTML `DOMParser`，仅用于官方 HTML attrs 提取。非真实浏览器 EditorView，没有布局/选择区/键盘/IME。
5. 不初始化 extension 的 plugins、inputRules、nodeViews 等 UI 部分。编辑是契约定义的 JSON 变更 + 官方 Node 校验；不是交易系统，不触发 HTML 空行归一化、自动 linkify 等 appendTransaction。
6. 仅启用所列 8 个代表扩展，加 ProseMirror 默认 Markdown schema/parsers/serializers。没有宣称覆盖完整 Discourse 编辑器。关闭 typography，开启 linkify/footnotes；settings 写入输出。
7. esbuild 忽略上游 app tsconfig（这里仅构建 JS）。测试 DOM 和 bundle 在独立 Node VM/模块中运行，不写生产文件。

## 已观测的官方异常

固定版本的 `footnote-named-multi-ref` 实测序列化为 `甲^[命^[命名脚注]注]乙[^1]\n\n[^1]: `：第一个脚注出现嵌套错位，第二个引用为空。oracle 如实保留，不修补官方 handler。源码中收集原始 childPos 后顺序 replace、未映射后续位置，是可能原因（源码推断，不是已验证的完整上游 bug 诊断）。不能为了差分全绿而把它隐藏；Dart 若采用更合理语义，应显式记录行为差异。

## 实际 Dart 移植至少需要的接口范围

- markdown-it token DTO：递归 children、attrs 查询、meta、markup、hidden、可修改 token 列表；bbcode 多 handler 分派及不支持 token 明确失败。
- schema：NodeSpec/MarkSpec、默认属性、content expression（`block+`、`summary block+`、`inline*`）、默认空节点补全、合法性检查、marks 顺序与排除规则。
- parser state：open/closeNode、open/closeMark、addText/addNode、parseTokens、top/stack；支持官方 footnote 重建 stack 和 tokens.splice。
- 树模型：Node/Fragment/Slice，content 遍历、descendants 相对位置、replace/fromJSON/toJSON/check；脚注多引用替换不能仅按字符串模拟。
- serializer state：write/text/esc、renderInline/renderContent、wrapBlock、renderList、delim/closed/list tight 状态、mark mixable、inAutolink，以及扩展 afterSerialize hooks。尾部换行是比较契约的一部分。
- HTML：DOMParser 的属性解析/实体解码、白名单 htmlAttrs；HTML block 独立原文节点。
- 编辑/生产接入额外范围：PM positions/steps/mapping/transactions、schema-preserving replace、selection、inputRules、plugins、nodeViews、剪贴板、IME、undo。**这些不在当前 oracle 的测试覆盖内**，不能由本次用例推断已可移植。

95 个 mock（28个结构/文本样例与67个属性值边界）包含基础 heading、fenced code、空列表项、tight 列表非1起号、Unicode UTF-16替换；额外覆盖标准 Markdown 空/嵌套 blockquote、前后段落空引用、嵌套 loose list、相邻/嵌套/转义 marks，并涵盖空/嵌套 quote/details、显式/裸/angle/title/attachment link、loose bullet/ordered lists、嵌套 small、ruby attrs、空 kbd、HTML block、命名脚注多 ref 与多段脚注。原文和官方序列化存在损失/规范化时如实保留，不把 raw 原样透传当正确。
