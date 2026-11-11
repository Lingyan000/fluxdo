---
name: fluxdo-commit
description: 在提交、拆分提交、推送、或提交 `packages/fluxdo_render` 子模块改动时使用。覆盖在有他人并行改动的工作区里只提交自己的文件、混合文件的拆分暂存、提交信息格式和子模块推送顺序。
---

# FluxDO 提交与推送

工作区里经常有别人没提交的改动，分支和 HEAD 也可能被别人刚动过。下面每一步都是为了只提交自己的改动。

## 核对现场

```sh
git status --short --branch
git log --oneline -5
```

分不清某个文件是不是自己改的，就看 `git diff <文件>` 的内容是否都出自本次任务。

## 暂存

1. 按功能分组，只 `git add <具体文件>`，同一主题的多次修改合成一笔。
2. 一个文件里混着两笔提交的内容时，先构造只含第一笔内容的中间版本，再写入暂存区：

   ```sh
   git update-index --cacheinfo 100644,$(git hash-object -w <中间版本文件>),<路径>
   ```

   不要用交互式的 `git add -p`。
3. 检查 `git diff --cached --stat`。仓库里大量文件没有格式化，对整个文件跑 `dart format` 会带出几百行无关 diff；只格式化自己改的部分，并确认 diff 只出现在改动附近。

## 提交信息

- 首行沿用仓库现有风格：gitmoji 前缀（✨ 新功能、🐛 修复、🎨 样式与结构、💄 界面、♻️ 重构、⚡️ 性能），或 `feat(scope):` / `fix(scope):`。正文说明原因和要点。
- 不加 AI 工具的 `Co-Authored-By`。真人协作者的 `Co-authored-by` 可以保留，例如 squash 合并时补的联合署名。

## 子模块

`packages/fluxdo_render` 是独立仓库（`main` 分支）：

1. 在子模块里按上面的流程提交并推送。
2. 回到主仓，把 `packages/fluxdo_render`（子模块指针）随对应功能一起提交。
3. 先推子模块，再推主仓，否则主仓会指向一个不存在的提交。

## 推送

- 推送前运行 `flutter test test/architecture`，守卫测试不通过就先修复。
- 推送被拒时先 `git pull --rebase`，重新核对后再推；不要 `push --force`。
