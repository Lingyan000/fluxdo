# 版本亮点(highlights)

每个 **stable** 版本一份 `v<版本号>.md`(例如 `v0.2.23.md`),内容是**用户视角**的版本亮点。
发版 tag 推送后,CI 会自动读取对应文件并组装到三个渠道:

| 渠道 | 组装方式 |
| --- | --- |
| GitHub Release | 亮点正文 + `<details>` 折叠的完整 commit 明细 + 下载表格 |
| Telegram 频道 | 只发亮点正文(+ compare 链接、贡献者致谢) |
| AltStore | 亮点纯文本化(去 markdown 语法),按段落截断到 1500 字符 |

对应 tag 的亮点文件**不存在时自动回退**为现状的全量 commit 明细,不会挡发版;
beta / rc 版本不读亮点文件(增量小,明细本身可读)。

组装逻辑见 `scripts/ci/compose_release_notes.py`,CI 接线见 `.github/workflows/build.yaml` 的 upload job。

## 起草

在 Claude Code 里运行 `/release-highlights`,会基于「上一个 stable tag → HEAD」的提交自动起草,
**人工修订后提交**,再执行 `just release`。tag 打在包含亮点文件的 commit 上,CI 才能读到。

## 写作约定

- **用户视角**:每条先讲用户得到了什么,再讲(可选)是什么。禁止出现实现术语
  (rebuild、saveLayer、provider、WidgetSpan、msgbus 之类)。
- **合并同主题**:几十个性能 commit 合成一条「更顺滑」;一个功能的十几次迭代合成一节。
- **分节用 `###`**,禁用 `##`(Telegram 渲染管线会丢弃 `##` 行)。节标题带一个 emoji。
- **结构**:开场 1~2 句点出版本主线 → 5~8 个 `###` 节 → 每节 1~5 条 bullet 或短段。
- **篇幅**:全文 1000~2000 字。Telegram 单条消息上限 4096 字符,超长会被分片/截断。
- 修复类只挑用户真实痛过的(频繁弹盾、崩溃、播不了);内部重构、诊断设施、CI 改动一律不进。
- 实验性功能明确标注「实验性」。
