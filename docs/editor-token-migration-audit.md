# 编辑 token 迁移能力审计

> 本文保留 token 迁移阶段的能力矩阵和历史证据。当前默认入口已采用正式 semantic codec/session，不是旧扁平 importer；最新生产测试结果、已连接接口与剩余签收门禁见 [Semantic 生产迁移独立验收](semantic-production-acceptance.md)。

## 当前修复与验收

下方矩阵保留最初审计快照以便追溯，不能当作修复后的能力描述。本轮已经落地：

- 正常 raw HTML video/audio 恢复真实媒体节点；原HTML和未编辑属性守恒，编辑更新及撤销有独立测试。
- poll 恢复 PollNode 结构和既有表单协议；表格 alignment 贯穿编辑与 separator。
- A1 附件原链、A2–A4 日期周期/布尔值/范围、A5 嵌套列表起号与松紧空行均已修复。
- A6/A7 模型无法表示的空/重复嵌套HTML节点保完整源码，不再静默压平。
- A8 非TeX数学暂保源码，不能把AsciiMath改写为TeX。
- 常用BBCode b/i/u/s、inline spoiler恢复mark并保来源；hashtag恢复原子引用。
- 脚注单段定义、重复/命名引用与行内脚注恢复；DTO对象可选undefined属性按JSON语义省略。
- `editor_token_audit_test.dart`已升级为34项真实cook守恒断言，不再仅输出探针结果。

主代理复跑子包非golden **1761项通过**；主仓库媒体/poll/table/date/footnote/完整混合正文 **73项通过**。
复杂多段脚注、模型无法表达的HTML结构和未注册第三方颜色/字号插件仍有明确边界，
不能宣称任意Discourse插件都已完全结构化编辑。音频title与PollNode.title为显示fallback，
实际编辑以媒体源码或poll rawHtml/表单为真源，不应只更新fallback字段期待重写正文。

## 范围与复现

这是并行开发期间的只读快照；业务文件可能随后由主代理修复。下面「实测」指真实本地 `assets/cook/discourse-cook.js`，构造 mock 正文，经 DTO → `importEditorTokens` → `blockNodesToDoc` → `docToMarkdown`。不是浏览器官方 ProseMirror 实测，也不是服务端 cook 等价证明。

```sh
node tools/discourse-cook-bundle/test/audit-token-matrix.mjs
cd packages/fluxdo_render
flutter test --no-pub test/editor_token_audit_test.dart --reporter expanded
```

34 个样本保存为 `test/fixtures/audit_token_matrix.json`。审计测试打印 raw、编辑块类型、unsupported、back，并对首个TextBlock调用真实content.insert追加“审计追加”后输出afterEdit；纯岛没有伪造可进入编辑能力。测试通过仅表示探针执行完成，不表示无损。修复时应将对应项升级为具体语义断言。现有 `editor_token_importer_test.dart` 的多数项目只验证「非空」不足以验收迁移。

官方基线：`~/f/discourse/frontend/discourse/app/static/prosemirror/core/{schema,parser,serializer}.js`，`extensions/register-default.js` 注册的所有节点/mark扩展；插件 `*/assets/javascripts/lib/rich-editor-extension.js`，以及 policy/calendar 的初始化扩展。schema 继承 prosemirror-markdown 默认节点和 marks。官方未知 token 抛 `UnsupportedTokenError`，不代表官方支持所有 Markdown 插件。

本项目审阅入口：`packages/fluxdo_render/lib/src/editor/model/{editor_token_importer,doc_converter,markdown_serializer}.dart`、`src/node/inline_node.dart`。旧能力列指迁移前模型/转换器已有表达能力，不假定旧 HTML 导入每种输入都通过 cook 等价门禁。

标记：**结构化**＝有专用节点或mark；**源码**＝完整原文岛保留，不是可视化能力；**不支持**＝整篇明确拒绝；**静默丢失**＝成功导入但写回损坏。结构化岛仍只能通过源码编辑，不等于可进入编辑。

## 先阻断数据损坏

|ID|真实输入/输出|根因与执行方案|
|---|---|---|
|A1|`[mock\|attachment](upload://mock.pdf)` → `[mock\|attachment](/404)`|link token `data-orig-href` 未导入；优先原链并保 attachment，至少源码保留。已通知媒体代理协调。|
|A2|date `recurring="1.months"` 消失|LocalDateRun 无 recurring；扩模型全链路或检测后源码保留。|
|A3|date `countdown=false` → `countdown="true"`|用 containsKey 当布尔值；应保原值/明确布尔语义。|
|A4|date-range → 两个 date 加 `→`|忽略 data-range，范围不是两日期的显示拼接；新增range atom或整段源码。|
|A5|`* mock\n\n  3. nested\n  4. second` → 子列表1/2|converter仅depth==0保start；每个子列表首项均需保start，并检查重建分组。属既有模型缺陷。|
|A6|`前 <small>甲 <small>乙</small> 丙</small> 后` → 单层small|官方html_inline为嵌套节点，现转换成同种mark集合；字号累乘语义丢失。big/sup/sub同类需覆盖。|
|A7|`前 <kbd></kbd> 后` → `前  后`|零长度节点无法用mark表达；空inline先源码保留或新增节点。空kbd视觉可能无差，但结构确实丢失。|
|A8|`前 %x+y% 后` → `前 $x+y$ 后`|math token.meta.mathType丢失，AsciiMath改成TeX；非tex先源码保留，长期扩类型。|

以上均在快照实测。嵌套kbd也变单层；与small相比视觉损坏不一定明显，不能把规范化和语义损坏混为一谈。

## 完整节点/mark矩阵

|官方节点/mark或输入|token导入|编辑后导出实际能力|迁移前模型与行动|
|---|---|---|---|
|doc / paragraph / text|结构化|TextBlock可编辑；普通空段变BlankLine|已有；补零字符与逃生段测试|
|heading h1–h6|结构化|可编辑level；当前tag整数解析|已有；非法DTO拒绝|
|blockquote|结构化|全子块可编辑才容器化，否则整棵岛|已有；空`>`实测保留|
|quote / 标题控制token|结构化|username/displayName/post/topic/full；标题仅容许官方生成token|已有；实测full保留；官方quote serializer本身未写full，不把官方视作无损oracle|
|bullet_list / ordered_list / list_item|结构化|简单inline+子列表可进入，含多段/代码/表格整树岛|已有；A5；tight/loose缺专用模型需进一步语义测试|
|code_block / fence|结构化岛|源码编辑；language与content，动态围栏|已有；不等于官方语言选择器节点视图|
|horizontal_rule|结构化岛|写`---`|已有|
|hard_break / softbreak|结构化|保soft字段，硬换行输出两空格换行|已有；官方统一hard_break，表格输出br|
|strong / em / code marks|结构化|普通Markdown/HTML标签可编辑|已有；需测试inline code含反引号、空白，岛序列化分支与TextBlock分支不同|
|bbcode_b / bbcode_i|源码（实测）|整段raw岛，不再可视化编辑|旧Strong/Em已有；补token别名|
|strikethrough s / bbcode_s|s结构化；BBCode源码（实测）|普通~~可编辑，[s]不可|旧StyledRun已有；补别名|
|underline bbcode_u|源码（实测）|[u]整段岛；HTML u也源码|旧underline已有；官方HTML解析<u>与BBCode路径不同，勿混淆|
|link普通/裸URL/autolink|结构化|普通与linkify区分；角括号来源未独立保留|旧LinkRun已有；测试独行URL导出仍能onebox|
|link title|源码（实测）|保原文，不可视化编辑title|旧模型无title，官方mark有title|
|attachment link|静默丢失A1|显示为普通mark，原链损坏|旧isAttachment/origHref已有，属于迁移漏映射|
|emoji|结构化atom|名称写回，onlyEmoji重新判定|已有；官方会补边界空格，需混排测试|
|mention|结构化atom|用户名写回|已有；状态emoji是显示派生，不属于原文丢失|
|hashtag|源码（实测）|span.hashtag-raw不识别|旧LinkRun.hashtagRef已有；补span分支|
|image|结构化atom（受限）|src/origSrc/alt/原尺寸/scale；title和extras走源码|旧ImageRun缺title/extras；媒体代理正在处理；非原文srcset/CDN/文件大小不可凭token重建|
|audio/video图片语法|结构化岛|特判单图段落生成媒体；label等属性需媒体专项|旧Audio/Video已有；不是官方单独audio/video schema，官方image.extras承载|
|grid|结构化岛（图片限定）|mode仅grid/carousel；非图片内容fallback|旧ImageGridNode已有；官方grid是block+，支持范围更大；非默认未知mode应保留而非归grid|
|onebox / onebox_inline|无对应token节点；URL结构化|只是URL而非官方异步onebox节点视图|旧OneboxNode/onebox链接已有；不能用parse无onebox推断不支持裸URL导出|
|html_block|源码HTML岛|trim后原文写回；没有DOM结构可进入|旧可解析table/media等；保源码比损坏安全，但不是同等可视化能力|
|html_inline strong/b/em/i/s/strike/code|受限结构化|转换mark；code内非纯文本fallback|旧已有；attrs非白名单源码|
|html_inline kbd/sup/sub/small/big/mark|结构化→可能静默丢失|转mark无法保空节点/同类嵌套A6/A7|官方node而非mark；不宜宣称完全对齐|
|html_inline del/ins|源码|官方html_inline支持，旧StyledRun有近似样式|补映射仍需考虑节点结构语义|
|html_inline ruby/rb/rt/rp/span(lang)|源码|未建模型，不支持可视化语言/注音节点|官方保lang；先保持源码，不能直接去壳|
|HTML a/img|受限结构化|a只href；img只src/alt/width/height，其他attrs源码|title/lang/style不能忽略；需要转义回归|
|wrap_block / wrap_inline|源码（block实测）|data attrs完整原文；无容器节点|官方保存任意data；旧通用模型不覆盖|
|table/head/body/row/cell/header_cell|无attrs表格结构化岛|无直接单元格编辑；通过Markdown源码编辑|旧TableNode已有，不是新增完整表格编辑能力|
|table alignment|源码（实测）|所有cell attrs均拒绝，完整原文保留|官方alignment字段支持；要扩模型+serializer，不只放行attrs|
|table caption/colspan/rowspan|HTML整体源码|caption实测保留，不是TableNode保留|官方Markdown表格schema也无caption/span；旧TableNode也无caption字段，不应把源码保留称作专用caption支持|
|local_date|结构化atom/静默丢失A2/A3|date/time/timezone/timezones/format/displayedTimezone；recurring缺失|旧模型同样无recurring，token已提供不能静默忽略|
|local_date_range|静默丢失A4|两个atom不能代替range|官方独立range node；需新模型或源码|
|spoiler block|结构化容器|可进入条件同blockquote；空容器实测保留|旧已有|
|inline_spoiler|源码（实测）|整段不能可视化编辑|旧SpoilerRun/mark已有；补bbcode_spoiler|
|details / summary|结构化（纯text摘要）|summary字符串，不是可编辑inline树；空details保留|旧DetailsNode已有；富摘要fallback，不得吞标记|
|math_inline / math_block|结构化岛；AsciiMath静默丢失|inline math导致整段岛，块math独立岛|旧MathInlineRun不在editable白名单；官方atom可选择拖动；A8|
|poll / poll_info及辅助token|源码（实测）|完整poll原文含关闭标签；没有PollNode与选项GUI|旧PollNode可从rawHtml重建BBCode；token迁移不是结构化poll支持|
|footnote / ref / block|不支持（启用插件实测）|footnote_block_open无完整来源导致整篇拒绝|旧FootnoteRef+FootnotesSection有表达；需要全篇关联ref/定义，不能每token局部source猜测|
|check|结构化成文本（实测）|[x]/[ ]/[X]写回；不是官方check atom点击切换|旧编辑列表机制另审；“token认得”不等于插件交互|
|chat transcript|未专门支持，来源可靠时源码否则拒绝|无chat专用token→node链|旧ChatTranscript不可序列化；需真实chat站点fixture，当前不宣称实测|
|policy|未专门支持，来源可靠时源码否则拒绝|无PolicyNode可视化|旧Policy不可序列化；官方自有attrs和serializer|
|calendar event|bundle未注册此插件|可能普通text，不能声称event支持|官方event extension存在；需明确宿主启用范围|
|color/bgcolor/size（站点第三方）|bundle未注册，常为text|源码字面串可编辑，不是marks|旧ColoredRun/SizedRun具备；不能把text往返当结构化插件支持|
|definition list / iframe / SVG|通常HTML源码岛|原HTML保留，没有旧专用节点UI|旧对应节点可序列化；不是官方默认schema承诺|
|未知token|可靠根级来源→源码，否则不支持|异常嵌套回退整个顶层单元；未知meta不证明语义支持|已有unknown无source、root=false、tokenCount篡改测试|

## 插件与编辑行为矩阵（不要计入token支持率）

|官方扩展/插件|Fluxdo当前审计结论|验收动作|
|---|---|---|
|trailing-paragraph / gap cursor|已有insertEscapeGaps/stripUnusedEscapeGaps，与PM机制非相同实现|空容器、相邻岛、嵌套容器末尾退出、导出不加幽灵段|
|trailing-inline-space|未因token导入而获得官方光标/空格插件|末尾mention/image/link后输入及IME测试|
|typographer-replacements|官方serializer有reverse map；本审计未证明Fluxdo等价|开关不同站点设置，字符原文/导出双测|
|markdown-paste|Fluxdo自身粘贴路径，token解析不等于粘贴策略一致|纯文本、多段、HTML clipboard、部分selection|
|image/grid resize/drag/placeholder|媒体代理专项；节点字段只是必要条件|缩放→导出→重导入，不得只看DTO|
|onebox/onebox-toolbar/link-toolbar|官方异步解析及工具条，不属于token树|URL改动、卡片恢复、裸URL导出资格|
|emoji only-emoji / mention / hashtag lookup|Fluxdo有自有原子/展示逻辑；hashtag token还源码|边界字母、emoji相邻文字、标签异步元数据|
|table paste normalization|官方无thead粘贴归一化，Fluxdo未证明具备|HTML无thead/不规则列/空cell粘贴|
|html-block normalize-newline|官方编辑时限制连续换行；Fluxdo源码岛不同|原HTML内空行不应自动当Markdown拆块|
|checklist click/list continuation|token仅还原文本，不是官方Plugin|勾选/回车续项/永久项的UI与导出|
|details keyboard / spoiler toggle|已有容器但非官方完整插件等价|空摘要、折叠后选区、回车退出|
|footnote editor / math atom UI|token支持与独立弹窗/嵌套编辑差距明显|先防丢失，再恢复编辑能力|
|override-drag-ghost / placeholder|纯展示插件，默认注册不含placeholder.js|无需以token支持计数；平台交互另验|
|quote / code / list / hard-break inputRules与keymap|Fluxdo自有命令实现|键盘输入和导入走不同路径，分开测试|

## 重要边界

1. 空blockquote/details/spoiler已实测存在可编辑落点；不要在后续报告仍当现存bug。空inline确有丢失；两者不是同一层。
2. 嵌套未知token必须传播到根单元再源码化；不得取容器内map误截原文。现有source信任`fluxdoSource.root/tokenCount`及范围，不提供跨块引用（脚注）保证。
3. caption需区分Markdown图片后的普通斜体文本、HTML table caption、figure/figcaption。前两者本探针保留；不应据此声称专用caption模型/编辑器支持。
4. 整棵岛引用原node identity只保converter阶段；岛serializer仍可能漏attrs、定界符转义、table caption。身份保真不是Markdown保真。
5. 旧serializer关于“二次cook门禁会拦截损坏”的注释不能自动用于新token路线。A1–A8都应在token导入层或导出层主动防止，而不是期待旧门禁。
6. 后续必须对修复后的文档进行真实内容编辑（不只无编辑导出）再导出：特别mark拆分、atom旁输入、table源码对话框、容器分裂与list重组。本探针已包含TextBlock真实模型追加编辑，是完整导出链的最小阻断证据，非UI端到端覆盖。
