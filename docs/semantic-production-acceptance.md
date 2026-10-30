# 语义编辑内核生产迁移验收

## 当前结论

默认富文本已迁移到 `SemanticComposerCodec → SemanticEditorSession`，不再是未启用原型。
本次验收覆盖现有应用编辑功能及公开命令、上传、草稿、页面提交和模式切换；不承诺未知第三方插件、
任意未来语法或设备网络解码必然正常。测试使用实际 Flutter widget/平台输入桥、官方 tokenizer 和
Node/本机 JS 引擎；没有把这些测试表述为手机真机人工验收。没有自动提交git或发布二进制。

## 生产链路核验

- [x] RichComposer 默认导入构造正式 session；文档树、投影与稳定来源在提交前同步，历史原子恢复。
- [x] 宿主旧 `markdownToDoc` / `docToRaw` / `serializeIslandNode` / `forgetTransientBlockInHistory` 调用清零；旧codec只保兼容测试/其它明确调用。
- [x] Markdown插入、HTML富粘贴、HR/callout输入规则走 semantic callbacks，异步selection/bookmark竞争不覆盖新输入。
- [x] 代码/HTML/投票对象源码、表格文本与行列、网格排序增删都有语义来源同步；原视频仍为VideoNode，不退代码块。
- [x] copy/cut及对象复制走绑定导出；IR先按原始选区切片再归一化，不补选区外href，完整链接保title和原始来源。
- [x] 列表/标题/引用/details/spoiler/callout、跨块删除、分裂合并、任意caret片段插入、undo/redo有真实编辑回归。
- [x] wrap祖先和未知属性在外部段落结构变化时保留；空引用、空容器不被无意删除。
- [x] 同源URL的不同图片重排/删除按对象来源保各自未知属性；表格行列来源不以文字猜测。
- [x] 上传在任意光标和容器插入临时来源，导出过滤；成功/取消重映射current/undo/redo，不复活孤儿；迟到请求不插入别篇。

## 页面与故障闭环

- [x] create/edit/reply/private-message所有发布、预览、切模式和草稿raw消费先检查`flushToController():bool`。
- [x] 导出失败保留当前树、阻止帖子写请求，正常关闭不丢防抖窗口内输入。
- [x] 异步校验/插件/确认等待后再次同步并比较批准快照，内容或相关参数变化则要求重新提交，不发旧raw也不绕过校验。
- [x] 紧急备份按站点、子路径、已登录账号scope隔离；重开显示恢复/丢弃，恢复必须明确确认，成功才删指定记录，失败保留。
- [x] 实际页面测试验证最后字符后立即PUT包含最新raw；创建/编辑/回复编辑/私信导出故障无写请求；真实延迟插件期间输入不提交旧正文。
- [x] 表格文字异步回声尚未完成时的新增列请求等待回声，文字/结构/来源/对齐均保留；外部替换不套旧操作。

## 最终命令与证据

主仓库：

```sh
flutter test --no-pub --concurrency=2 test
```

最终 **1919通过、22跳过**，日志 `/tmp/production-root-final-all.log`。跳过是既有环境/平台或专用性能门禁，
不将跳过算作通过。此前全量的11个对象UI失败已真实修复，保留原测试断言，未通过删除测试规避。

子包：

```sh
cd packages/fluxdo_render
find test -name '*test.dart' ! -name '*golden*' -print0 | xargs -0 flutter test --no-pub
```

最终 **2241通过**，已包含表格pending来源修复后的重新全量运行，日志 `/tmp/production-package-signed.log`；主仓库表格pending专项另有3项通过。
阅读golden单独存在此前已在隔离HEAD复现的基线差异，未改快照，也不称其全绿。

额外关键验收：

- 正式生产真实bundle+编辑序列60项，含导出再导入与undo/redo。
- 原子链接真实点击→宿主对话框→保存→撤销。
- 表格异步文字+结构专项3项：`semantic_table_pending_structure_test.dart`。
- JS tokenizer专测、26项阅读cook及onebox seed回归通过。
- 主宿主、三页面、正式codec/recovery及内核新文件定向analyze通过；`git diff --check`通过。

## 有意保留的边界

- tokenizer仍用现有原生JS，新增正式文档/解析适配/序列化/编辑同步为Dart；没有生产引入ProseMirror JS运行时。
- 原型`port_probe`只作官方差分测试，不在生产依赖链；不照搬已知上游重复脚注位置损坏。
- 真正无法表达的未知token/属性操作仍明确拒绝，严守原文；拒绝不被当作已支持功能。
- 表格已有文字编辑使用异步codec，结构请求排队而不抢写；这不是无异步模型。
- 编辑话题的元数据与正文是两次服务端请求；若元数据成功后正文在等待期间变化，正文会中止重试，不回滚已成功的元数据。
