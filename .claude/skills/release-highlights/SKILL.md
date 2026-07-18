---
name: release-highlights
description: 发 stable 版前起草用户视角的版本亮点(highlights/v<版本>.md)。用户说「起草亮点」「写更新亮点」「准备发版日志」时使用。
---

# 起草版本亮点

为即将发布的 stable 版本起草 `highlights/v<版本>.md`。该文件由 CI(`scripts/ci/compose_release_notes.py`)在发版时消费:GitHub Release 正文 = 亮点 + 折叠的全量明细,Telegram / AltStore 只发亮点。

## 步骤

1. **定范围**:
   ```bash
   PREV=$(git describe --tags --abbrev=0 --exclude='*-*' HEAD)   # 上一个 stable tag
   git log --oneline --no-merges "$PREV"..HEAD
   ```
2. **定目标版本**:取最近 tag 的核心版本(如 `v0.2.23-beta.20` → `v0.2.23`)。若无 beta 序列或有歧义,直接问用户这次要发什么版本号。
3. **读写作约定**:`highlights/README.md`,严格遵守(用户视角、禁实现术语、`###` 分节、1000~2000 字)。
4. **聚类提炼**:把范围内提交按用户可感知的主题聚类(新功能 / 界面焕新 / 流畅度 / 稳定性…),几十个同主题 commit 合成一条人话。凡是用户没有感知的(重构、诊断设施、CI、依赖升级)一律不写。对拿不准"用户看到什么"的提交,读对应代码或 commit body 确认,不要凭 commit 标题脑补功能。
5. **写文件**:`highlights/v<版本>.md`(无 H1 标题,直接开场段落起笔)。若同版本文件已存在,先读旧稿,在其基础上增量更新而非覆盖。
6. **交稿**:提醒用户人工审读修改后随代码提交(tag 必须打在包含该文件的 commit 上,CI 才能读到),再执行 `just release`。

## 自查

- 每条 bullet 单独念给非程序员听是否能懂?出现 rebuild / provider / saveLayer 等词即打回。
- Telegram 上限 4096 字符,正文加标题链接后仍需留余量。
- 分节只用 `###`(`##` 会被 TG 管线丢弃)。
