# 草稿保存：官方实现对应与 Flutter 适配

参考 Discourse：`~/f/discourse`，commit `b3b561e5fad412c038e222499ebe22050b4a8de4`。

UI 调整已独立提交为 `da4b0687`。本文记录随后保存机制的实现及与官方代码的对应关系。

## 对之前结论的纠正

官方仓库中存在不同编辑器的草稿实现，不能用主编辑器的 `Draft.getLocal()` 占位方法概括整个项目。

- **普通发帖、回复编辑器**：通过 `/drafts.json` 保存到服务端；保存失败显示“离线草稿”。这条路径的 `getLocal()` 尚未实现本地恢复。
- **DockedComposer（嵌入式编辑器、AI 对话使用）**：`onReplyChange()` 调用 `persistDraft()`，通过 `keyValueStore` 把正文写入 `localStorage`；打开时恢复，清空或发送成功后移除。
- **FluxDO**：用 Hive 代替浏览器存储，并保存正文、标题、分类、标签和收件人。现在结合上述本地保存行为与普通编辑器的在线保存规则。

参考源码：

- [DockedComposer 本地更新与恢复](https://github.com/discourse/discourse/blob/b3b561e5fad412c038e222499ebe22050b4a8de4/frontend/discourse/app/components/docked-composer.gjs#L170)
- [DockedComposer 发送成功后清理](https://github.com/discourse/discourse/blob/b3b561e5fad412c038e222499ebe22050b4a8de4/frontend/discourse/app/components/docked-composer.gjs#L262)
- [keyValueStore 使用 localStorage](https://github.com/discourse/discourse/blob/b3b561e5fad412c038e222499ebe22050b4a8de4/frontend/discourse/app/lib/key-value-store.js#L5)
- [普通编辑器保存调度](https://github.com/discourse/discourse/blob/b3b561e5fad412c038e222499ebe22050b4a8de4/frontend/discourse/app/services/composer.js#L1910)
- [普通编辑器版本冲突处理](https://github.com/discourse/discourse/blob/b3b561e5fad412c038e222499ebe22050b4a8de4/frontend/discourse/app/models/composer.js#L1482)

## 本轮实现

| 官方行为 | Flutter 对应实现 |
| --- | --- |
| 输入更新本地草稿，不等待网络 | 输入快照变化后立即进入本地写入队列，取消原来的 400ms 可无限推迟的本地防抖 |
| 在线保存通常等待 2 秒，连续输入超过 15 秒也要保存 | 独立的 2 秒防抖与 15 秒截止计时器 |
| 保存开始就标记 `draftSaving`，不同时发送多个请求 | 首个 `await` 前占用队列，最新快照合并发送，撤销不会留下旧防抖任务 |
| 本地恢复 | 优先返回 Hive 快照；异步核对云端版本，不替换正在编辑的正文 |
| 发送成功才清理本地内容 | 云端草稿同步成功后保留本地缓存，发送或舍弃时清理 |
| 409 由用户决定是否强制覆盖 | 保留本地内容并显示冲突状态；用户明确选择覆盖后才发送 `force_save` |
| 离开页面时尝试补保存 | `AppLifecycleListener` 在切后台等节点刷新快照；页面销毁不取消已接受的保存任务 |
| 保存失败后保留当前编辑内容 | 保留本地快照，区分本机已保存与完全未保存；恢复网络时重试当前编辑中的草稿 |

富文本采用移动端适配：保留 800ms 停顿序列化，并增加 1 秒最长等待。因此连续打字也会定期生成本地快照，不会无限推迟；同时避免每个按键都序列化整篇 Markdown。

## 本地与云端版本

`LocalDraftEntry` 增加 `synced` 和 `baseFingerprint`，兼容原有记录。内容指纹忽略 `composerTime`、`typingTime` 等会话字段。

- 本地与云端一致时更新确认状态。
- 云端版本已变化且内容不匹配时停止自动上传，不把旧本地正文配上最新云端版本号。
- 云端答复通过 `recordSync()` 更新对应缓存，只在本地仍是该版本时生效，避免迟到回复覆盖其他编辑器的新输入。
- 页面关闭后的任务也会核对当前账号，避免切换账号后继续向新账号发送旧内容。

## 离线恢复与删除

草稿列表合并未同步的本地草稿，断网或请求失败时可以使用本地缓存，包含使用唯一 key 的私信草稿。在线时，已同步但不在云端列表中的旧缓存不会重新加入列表。

离线舍弃会保存空快照作为删除意图，不再让旧云端内容直接恢复。同一草稿再次打开时会核对并继续删除；当前编辑器保持打开时也会在联网后重试。此实现没有常驻的跨会话上传服务，关闭后的未同步内容通过草稿列表重新打开后继续同步。

现有 UI 约束保持：草稿状态只显示在“更多”菜单，失败或冲突标记入口；没有正文浮层或因保存状态变化调整正文留白。

## 草稿标签格式兼容

另对照已 fetch 的上游 `8d60e8637ff`：`frontend/discourse/app/models/composer.js` 的 `serializeDraftData()` 经过 `serialize()` 调用 `lib/serialize-tags.js`，标签以 `{name}` 或 `{id, name}` 对象保存；旧草稿仍可能使用字符串。上游 `lib/render-tag.js` 同样兼容两种表示。

FluxDO 在 `DraftData.fromJson()` 统一提取标签名称，禁止对整个对象调用 `toString()`，否则会显示并可能回写 `{name: 纯水}`。API 的 Map、JSON 字符串和本地缓存入口共用此解析；客户端继续保存兼容的名称数组，内容指纹也基于名称，避免对象/字符串表示差异引发误判。缺少有效字符串名称的条目忽略，不影响正文恢复。

`/user-drafts/:user_id` 的 MessageBus 通知只更新草稿数量；本次标签问题发生在草稿内容解析，而非消息传输层。创建页回归测试使用网页端对象标签，覆盖首次恢复、回到前台更新及清空标签。

## 验证

正式测试包含持续输入、关闭保存、保存串行化、撤销、409 显式覆盖、本地优先恢复、异步读取失败、联网重试、离线删除、账号切换、时长去重及缓存条件更新。

主要代码：

- `lib/services/draft_controller.dart`
- `lib/services/local_draft_store.dart`
- `lib/models/draft.dart`
- `lib/pages/drafts_page.dart`
- `lib/widgets/markdown_editor/rich_composer/rich_composer_editor.dart`

系统直接终止进程时，恢复范围仍以最后成功写入本地的快照为准；不会把尚未完成的磁盘写入宣称为已保存。
