# 编辑迁移后的旧逻辑清理

## 删除的重复入口

- 主仓库 `composer_doc_codec.dart`（旧整篇 token→EditorBlock 编解码）。
- `ComposerImportPipeline` 旧 HTML cook 导入管道；保留生产 `ComposerTokenImportPipeline`。
- `DiscourseCookService.cookForEditor` 与 JS bundle `__fluxdoCook.cookForEditor`。
- 阅读 `ParagraphParser` 的编辑专用 `htmlSourceBlocks` 占位旁路。
- 子包旧 `editor_token_importer.dart` 整篇转换器及导出。

## 保留而非误删

- 正式 `SemanticComposerCodec` / `SemanticDocumentCodec` 与官方 token API、普通阅读 cook。
- `EditorState` 的独立无绑定模式，以及仍用于独立编辑器/阅读节点的 Markdown 序列化。
- 共享 `poll_codec.dart` / `island_inline_serializer.dart`：正式语义编解码和独立旧编辑器共同使用局部纯规则，不存在整篇新→旧→新循环。
- `port_probe` 官方差分原型与其测试：只用于验证移植，不参与生产运行。

## 回归迁移原则

旧入口测试迁到正式语义树、实际 EditorState 和语义导出；保留完整正文、链接编码、HTML、图片缩放、
投票、脚注及异常门禁等重要case。Node helper集中在 `test/helpers/discourse_cook_node.dart`，
支持一致的siteSettings覆盖，不能单边开启插件制造假通过。

清理过程中发现正式链路与旧回归的差异必须修复，不通过删case或改期待失败消除红灯。


## 清理后补齐的回归

- 原链接测试保持IR实际展开/停留导出覆盖，迁移为生产semantic会话，不以选区未展开代替。
- 畸形poll从有效根fixture进行单字段变异：children/attrs非法类型、叶nesting、闭合错配均拒绝。
- 脚注label与显示定位ID分开，命名脚注引用/定义使用一致fn编号关联。
- 特殊编码/反斜杠裸链保持来源；复杂或unsafe媒体只能保源码，不能升级为播放器。
- 字面BBCode来源只在tokenizer确认原文未转义且文本未修改时保留，编辑后来源失效。

这些不是删除测试绕过失败；迁移后的7组主回归141项通过。


## 最终验证

- 主仓库全量：1927通过、22跳过（`flutter test --no-pub --concurrency=2 test`）。
- 子包非golden全量：2243通过。
- 主/子本轮修改核心文件定向analyze无问题；主仓与子包diff检查通过。
- JS阅读cook 26项与onebox seed、token API移除断言通过；官方差分oracle 8项通过。
- oracle已重建并同步新tokenizer hash，官方95例语义对照未按清理修改期待值。
- 源码残留检索仅剩测试中断言cookForEditor不存在，不再有旧API实现或引用。

未删除阅读渲染、独立无绑定EditorState或官方对照原型；历史测试文件名保留不表示旧生产入口仍存在。
