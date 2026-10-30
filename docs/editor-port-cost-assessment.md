# 官方编辑语义移植成本初评

> 本文是原型与成本评估历史记录，不代表当前默认入口仍未启用。正式 semantic codec/session 已接入 RichComposer；生产证据与签收门禁见 [Semantic 生产迁移独立验收](semantic-production-acceptance.md)，不要将本文原型测试计数用作生产验收。

## 范围

初评阶段基于本地 Discourse checkout 只读核验；后续原型实现与测试依赖见本文末节。
物理行包括注释/空行，不是工作量或有效SLOC。

- static/prosemirror/core：7文件658行；parser/schema/serializer共224行。
- static/prosemirror/extensions：29文件4982行（包括注册文件）。
- plugins/*/assets/javascripts/lib/rich-editor-extension.js：8文件2079行。
- 合计44文件7719行，不含ProseMirror依赖、其他插件入口、辅助组件或测试。

这些范围不能当作完整移植规模。parser调用prosemirror-markdown的MarkdownParser；
schema调用prosemirror-model；serializer调用MarkdownSerializerState，核心实现不在224行内。

## 分层判断

1. 属性声明、token分派、各节点parse/serialize：适合Dart移植，但依赖兼容模型和状态接口。
2. 文档树、mark顺序、空节点约束、Fragment/Slice、序列化上下文：主要语义工作，不能用现有扁平模型无损假设跳过。
3. transaction/selection/mapping/history：高成本，暂无理由为切换功能整体移植。
4. DOM/Ember/NodeView/上传UI：不是编解码目标，保留Flutter实现。
5. 完全不运行JS还需替换当前Discourse tokenizer（及若要完全移除JS，现cook预览）：与只翻译编辑codec是不同范围。

实际抽样：image.js共492行，parse/serialize区域45行；details扩展85行，parse/serialize区域45行。
这些只能说明可剥离UI，不可外推全库可翻译百分比。

## 推荐决策方法

优先做受限移植验证而非立即引入整个官方JS文档运行时，也不承诺低成本全Dart：

- 保留当前官方tokenizer，验证官方等价Dart文档树与编解码状态。
- 选空/嵌套容器、链接来源与属性、松散列表、HTML行内嵌套、脚注作纵向样本。
- 每个样本同时核对官方文档结构、序列化、一次实际编辑后的结果，不仅比较cook。
- 记录真正需要实现的model/state API与差异；若需不断重建ProseMirror底层才能完成，则原生JS复用成本更合理。
- 待该验证后再给开发时间/维护量估计；当前仅源码初评，未验证性能或给出可信工期。

长期同步成本：移植规则应记录上游路径/commit，模块对应，自动差分测试；不能继续在一个转换器里堆特例。
用户已有优于官方的原生媒体显示等能力应作为有意差异保留，不能以逐字复刻为由倒退。


## 已实施验证结果

### 交付

- `tools/editor-port-probe/`：固定官方commit的真实parser/schema/serializer及8扩展测试oracle，CLI、锁文件、逐源hash与契约。
- `packages/fluxdo_render/lib/src/editor/port_probe/`：独立Dart树、schema子集、parser stack、serializer state、路径编辑。未加入生产导出入口，未替换现有编辑器。
- `tools/editor-port-probe/verify.sh`：从任意目录安装锁定测试依赖、构建并核验oracle、执行Dart差分和analyze。
- 许可与来源保留于原型 `NOTICE.md`、`licenses/`。语言翻译不改变上游许可。

### 实测证据

95个mock：28个结构/文本样例＋67个属性值边界。逐项比较官方文档JSON、序列化字符串、
实际路径编辑后的JSON和字符串。原型测试组合290项通过，JS oracle 8项通过，原型及测试
analyze无问题；现有生产token与媒体回归44项通过。未用cook相等代替官方结构等价。

Dart原型物理行：model319、parser390、serializer476、入口19，共1204行（含注释空行，
不含测试/说明）。依赖已有Dart html库，无新增pub包、无新增app JS文档内核运行依赖。
官方JS和DOM仅用于测试对照，现有JS tokenizer仍保留。

### 实际成本判断

**代表性编解码规则直接移植Dart可行，范围可控，值得优先走Dart；无需仅为这些规则引入
ProseMirror JS生产运行时。** 但不是224行入口的机械翻译：这次实际需要约1200行独立
模型/栈/状态机，以及以下兼容工作：

- 属性默认值、mark顺序、空节点createAndFill、嵌套树和闭合Slice位置替换。
- Markdown转义/列表分隔符/mark混排/尾换行状态。
- JS truthiness、字符串与数值转换；独立review揭示null/false/数字字符串等差异，补齐67项后通过。
- 固定版本来源、可再生官方oracle和差分负例。这些是持续维护成本，不能只数业务分支。

这支持“继续按模块直接移植编解码”的技术选择，不支持“整个编辑内核翻译成本低”。
生产接入仍需文档映射/现有Flutter编辑事务适配和未覆盖插件，不在本次受限可行性验证内。
整个tokenizer/阅读cook移植亦不在本次范围；本结论不是完全去掉JS。

### 有意差异与上游异常

官方重复命名脚注的原位置多次替换在此固定版本产生错位嵌套。oracle忠实记录，Dart探针
为测兼容成本复现同输出；不应作为生产修复方案。已有未知属性在Dart树中保留，而未知
setAttrs键拒绝；这是明确的保真策略，并非完整PM schema等价。正无穷repeat在官方可
挂起，探针明确拒绝；不执行不终止的行为。详见CONTRACT和原型README。

没有进行正式性能基准，也没有可信总人日数据；因此不报告未经测量的倍率或工期。

最终验收补齐空文档、空列表、空引用、嵌套空引用的首次插入编辑；95例均包含全部四项比较，没有跳过编辑后验证。
