# 语义编辑树生产接入

**当前默认入口已完成迁移。最终实施状态、测试记录与边界见 [生产验收](semantic-production-acceptance.md)。**
下文保留设计及逐轮实施记录，历史“未启用/尚需”的措辞不代表当前状态。


> **当前状态更新：** 下文是迁移各阶段的历史审查，不是当前入口状态。默认 RichComposer 现已采用 `SemanticComposerCodec → SemanticEditorSession`，粘贴、上传临时历史、导出失败门禁及恢复 UI 已接生产；旧 `markdownToDoc` 生产调用为 0。后文“默认入口未切换”“真实上传尚未接”等仅对应当时快照。当前测试证据、表格最后迁移门禁及新发现的提交时序风险统一见 [生产迁移独立验收](semantic-production-acceptance.md)，不得以本文旧计数或旧结论代替最终验收。

本次仅审查源码，不改业务、不替代适配实现。以下“应提供”是接口契约建议，不代表已有实现；评审基于当前 `port_probe`、EditorState 和 composer 源码。

## 决策

**不能把 ProbeCodec 复制、导出后直接替换生产 codec。** 可以先增加独立生产树及适配器，但在事务/历史同步和能力门禁完成前，不启用 rich composer 新路径。最小路径保留现有编辑视图、IME 和块命令，将旧 `List<EditorBlock>` 定位为新树的可编辑投影，而非能够无损还原新树的真源。

## 已核验现状与切换点

| 源码位置 | 当前行为 | 生产切换要求 |
| --- | --- | --- |
| 历史旧 `composer_doc_codec.dart`（现已删除） | `ComposerTokenImportPipeline<List<EditorBlock>>`；convert 调 `importEditorTokens(raw,dto).document`，serialize 调 `docToRaw` | 生产入口返回“语义树 + 投影 + 双向绑定/能力结果”的会话文档，不能只返回 flatten 后 blocks。门禁使用同一生产导出器 |
| `composer_import_pipeline.dart` | token 解析、转换、序列化、两次普通 cook 共预算；严格完整 HTML 比较；unsupported 返回失败 | 保留预算、失败分类、保原文语义；cook 等价只是辅助门禁，不能证明 attrs/树结构无损 |
| `rich_composer_editor.dart::_importInitial` | guarded 导入，insertEscapeGaps，构造 `EditorState(blocks:gapped)`，按导出结果安装 mirror baseline | 在构造处交付树/绑定；逃生段和自动补段标识为投影节点，空时不写进语义树，输入后须晋升真实节点 |
| `EditorState::_commit`、`undo/redo` | 仅更新 blocks/selection；历史条目也仅保存这两者，undo/redo 直接替换 blocks | 事务同步树、绑定和投影；历史一起恢复。仅在 `_commit` 加 hook 不够，undo/redo、临时历史清理也须覆盖 |
| `EditorState::exportMarkdown` | IR 在临时块快照 spin 收口，然后 `docToMarkdown`；copySelection 同用此方法 | 新导出应对临时语义快照应用收口，不改变活动树/选区/历史；整篇与片段导出分开定义 |
| `rich_composer_editor.dart::_exportForMirror` | 过滤上传占位，再将剩余 blocks 当 fragment 导出 | 需要“整篇树导出，排除临时节点”的接口；不能误把所有正文当普通剪贴板片段，丢根级 attrs/绑定 |
| `ComposerRawMirror::install/flush` | 初始导出为 baseline，相等时恢复导入 raw；revision 是缓存键；外部 controller 改写永久使会话失效 | 保留此保护；所有影响语义导出的变更必须改变缓存键。mirror 不保存树、不能补偿结构丢失 |

除了初始导入，`rich_composer_editor.dart` 中上传结果、插入 Markdown、富粘贴、编辑对象及 `FluxdoEditor.markdownImporter` 都调用 `markdownToDoc`。应提供携带语义来源的片段接口并迁移所有调用；保留裸 blocks 入口会绕过保护。`pasteBlocks` 还创建临时 `EditorState(blocks:_blocks)`，该草稿也必须携带并事务化语义状态。

## 双模型怎样同步才不丢

现有 `TextBlock` 只有 kind/headingLevel/ordered/depth/listStart/listLoose/containers，容器帧只有各自固定字段。没有通用 attrs，也没有完整 list/list_item 树。现有容器 groupId 可以区分实例，但不是完整语义节点绑定。因此“新树 → 旧块 → 根据块重建整棵新树”不可作为生产往返。

最小安全契约：

1. 导入保留完整不可变树；投影记录稳定节点身份、容器/列表归属、文本/原子偏移映射。仅用 content 索引 path 不够：分裂、删除、粘贴后 path 会变。树属性保留还应涵盖 marks、嵌套 Map/List。
2. 文本编辑只替换对应叶内容；属性命令只 patch 明确触及的字段；未触及节点/祖先的 type、attrs、子树次序保持不变。不能用 UI 模型默认值反向覆盖树上已有值。IR 物化/收口是表示变化，不是格式属性重置。
3. 分裂/合并/缩进/容器包裹/跨块删除必须有明确树变换与身份映射。未实现的操作应在执行前拒绝或禁用；不能先改旧块、再在 flush 时发现无法同步。
4. 每个事务应先计算并验证新树、投影、绑定，成功后一次提交和通知；不允许监听器观察到“旧树 + 新块”。结构操作失败不产生半事务。
5. 历史保存上述组合快照，连续输入合并、IME composing、undo/redo 同步恢复。`forgetTransientBlockInHistory`、上传替换、`replaceBlockRange` 也要清理对应树/绑定，不能 undo 恢复失去任务归属的占位。
6. 粘贴/复制必须保留片段语义，重分配身份但保持片段内部归属。首尾合并按现有编辑契约明确哪些属性由宿主获胜，不能默默丢弃片段未投影信息。

可行的首阶段限制是：仅允许已验证可投影/可同步的节点和命令；其余整篇保原文回源码模式，或使用有完整保留和导出契约的不可编辑语义孤岛。不能将未知节点丢弃后再借 cook 相等放行。

## probe 不能继承为生产保证的部分

- `port_probe/README.md` 明确没有 selection/history/transaction/mapping；applyEdit 的 insertText 只用于空 paragraph，replaceText 不允许空 text。它不是现有键盘/IME 事务替代品。
- `tools/editor-port-probe/README.md` 记录固定官方版本多引用脚注产生嵌套错位及空引用；probe 故意对齐该 oracle。生产必须独立选择正确脚注语义并记录差异，或拒绝此类输入；不能把差分全绿当正确性。当前生产语义 parser 有独立 ref/definition 校验，不应被原型的顺序位置替换覆盖。
- `ProbeSchema` 是受限内容表达式/填充检查，不是完整 PM schema。attrs 测试和 oracle coercion 现象只能说明具体样本行为，不能据此默许所有类型。生产必须按节点/mark 字段定义类型、缺省、null、枚举与边界策略；未知原有 attrs 保留，用户 patch 未声明字段拒绝。无支持类型不得字符串化/真假值转换后悄悄写回。
- probe 不支持 image、表格、mention、emoji、上传、onebox 等；HTML allowlist 中未知标签的官方忽略行为，也不能未经能力检查搬进已有富文本编辑路径。

## video/audio 不退化要求（已有代码不是空白能力）

`editor_token_importer.dart` 已处理 HTML 媒体和 `|video` / `|audio` 上传标记；`markdown_serializer.dart::serializeIslandNode` 已区分 LazyVideoNode、上传短链及 HTML VideoNode/AudioNode。`raw_media_html.dart` 有明确保源机制：

- 接受单个显式闭合媒体根；限制子标签 source/track/a；拒绝脚本、嵌套媒体等；主源只接受相对地址或 http/https/upload。
- VideoNode 保留 src/origSrc/mime/poster/width/height/loop，并存 rawHtml + signature；未改动直接返回原 HTML。
- 编辑后局部更新属性，保留未覆盖属性与 source/track 等；换源清理旧备用源、更新对应下载链接。

新树中必须保留这些元数据与保源行为，投影继续生成可用播放器/岛，而不是将 `<video>` 当未知 HTML 忽略或普通代码。不能以“新路径不支持 video，降级源码”宣称能力无回归：若首阶段如此限制，必须明确该功能尚未达到替换启用条件。新增通用 opaque 节点也必须有独立可验证序列化和安全投影契约。

## 启用前必做清单

- [ ] 独立生产接口与明确支持矩阵；不直接公开 probe 作为正式模型。
- [ ] 完成上面的树/投影事务、历史、IR、片段、占位同步；未支持命令前置拦截。
- [ ] schema/attrs 边界验证与脚注生产差异策略；未知内容不静默忽略。
- [ ] 测试：在一个段落改字后，未触及的容器/列表/节点/mark attrs 和结构完整保留；空容器、相邻独立容器、列表起始编号与松紧、多段 list_item 必须覆盖。
- [ ] 测试：IME、IR 进入/退出、分裂合并、跨块替换、粘贴 re-id、undo/redo、连续输入合并、上传占位清理后不恢复孤儿状态。
- [ ] video/audio 覆盖无编辑与旁段编辑逐字保源，缩放/改 poster/换源后未知属性、track/source 处理，上传短链、LazyVideo、复制粘贴及撤销恢复。
- [ ] mirror 覆盖 no-op/纯 IR 保原文、提交前 flush、外部 controller 改写、异步导入晚到、dispose 不覆盖新文档；所有语义变更使缓存失效。
- [ ] 导出失败不能只回退到上次 controller 原文而丢掉尚未 flush 的用户编辑。现有 `flushToController` 捕获后保已有原文并回退；新适配器必须确保已接受的事务可导出，或提供可恢复当前编辑快照并阻止错误提交。

结论：可以先合入未启用的独立生产适配及测试；只有 codec 解析/序列化差分通过、不具备编辑同步与媒体回归证据时，不应切换 rich composer 默认入口。本审查未运行测试，不把源码推断当实测结果。

## 本轮已实现（默认入口未切换）

- `semantic_editor/SemanticEditorProjection`：原树到编辑投影、稳定ID/路径/原节点绑定；成功产生新不可变projection快照，不靠旧Markdown导出再解析。
- `SemanticEditorSession`：通过可选EditorDocumentBinding提交前同步树，undo/redo恢复同一组树/绑定/blocks快照。
- `EditorState.exportBlocks`：只读IR归一化快照，现exportMarkdown复用；不改变live选区、composing、revision或历史。
- 顶层段落/标题精确split/merge、同区域reorder/delete、同父简单段落split；链接内部split按原树切片验证，保持title/未知attrs。
- 单_commit绑定拒绝不写正文或历史，并保留pending输入与历史封组定时；无binding保持原路径。
- 实际Flutter输入/Enter/IR/undo测试；独立review复现的拒绝污染分组、空段merge丢attrs、link span分段不等问题均补回归。

主代理最终子包非golden全量 **2089项通过**，本轮核心文件analyze无问题。

仍不能默认启用：不透明节点目前是测试占位，媒体与完整atom投影未完成；复杂跨容器/列表结构操作、
上传临时历史、多_commit复合命令的整操作原子性仍需补齐。当前拒绝这些路径不是实现完毕，
不能把原型接上EditorState等同生产迁移完成。新命名空间未被宿主构造或生产codec使用。


## 本轮继续进展：媒体、原子与复合事务

上述“媒体未实现”是前轮状态：现在semantic适配已将native video/audio和可识别HTML视频投影为
真实媒体节点，常用image/emoji/mention/date/特殊链接原子双向同步也已验证。未知节点占位仍不得生产启用。
runAtomicEdit已隔离绑定下常用复合命令，失败回滚包含历史、IME、pending、模式与通知，
测试证明先删后拒绝不会留下半成品。内部中间态仍要通过prepare，不是任意最终合法变换都已支持。

独立review发现并修复image地址校验缺失、相同哨兵的原子来源错配、原子切片空text异常；
回归守住普通title链接保持mark而非退成不可拆原子。主代理最终2115项非golden全量通过，
定向analyze无问题；生产codec和宿主构造尚未采用新session。


## 正式入口与临时历史协议已落地

当前正式模型已从Probe完全解耦，新独立public semantic_editor.dart提供模型/codec/session。
原文可经SemanticComposerCodec真实token→tree→编辑→序列化→严格gate。不是手工树演示，也不是
旧EditorBlock序列化再解析。新codec只支持明确矩阵，table/poll等尚未纳入，不默认替换旧入口。

整根片段操作用一次性计划保来源/稳定IDs/独立容器；临时节点通过可选history remap接口原子
修改当前/undo/redo，exportTree过滤active来源，resolve后不可复活孤儿。真实上传服务尚未接此API。
独立review发现的date marks丢失、空list tight、空details标题和内容补全已修；空HTML行内节点
仍有投影限制，不以导入gate通过冒充可编辑。

验收：2151非golden子包测试、68新旧主仓库组合测试通过，定向analyze无问题。

旧入口清理已删除兼容整篇转换器、cookForEditor和HTML占位旁路；以上旧文件名仅作历史设计追溯。详见editor-legacy-cleanup.md。
