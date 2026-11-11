---
name: fluxdo-l10n
description: 在新增或修改界面文案、给文案加参数、补繁体或英文翻译，以及遇到 l10n 生成报错或 `AppLocalizations` 找不到 getter 时使用。覆盖 arb 模块的放置、文本插入式编辑、placeholders 声明与生成校验。
---

# FluxDO 国际化

文案源文件是 `lib/l10n/modules/<模块>/<模块>_{zh,en,zh_HK,zh_TW}.arb`，由 slang 生成代码（`slang.yaml`：基准语言 `zh`，缺失时回退到 `zh`）。生成产物不入库。

## 新增键

1. 选现有模块，键名带模块前缀，例如 `appearance_themeResetConfirm`。取消、确认、删除、编辑、重置等通用词先查 `common` 模块是否已有。
2. 四个语言文件都要加，放在相关键附近。`zh_HK`、`zh_TW` 用繁体字和对应地区的用词，不要直接复制简体。
3. 以某个现有键所在行为锚点，在其后插入新行。不要把 arb 解析成 JSON 再整体写回：会打乱键顺序，还会冲掉别人并行加的键。
4. 带参数的文案在文本里写 `{name}`，并在 `zh` 的 arb 中声明，否则生成会失败：

   ```json
   "appearance_customThemeImported": "已导入「{name}」",
   "@appearance_customThemeImported": {
     "placeholders": { "name": { "type": "String" } }
   },
   ```

5. 生成并校验：

   ```sh
   just l10n
   just l10n-check
   ```

## 使用

- 有 `BuildContext`：`context.l10n.appearance_xxx`
- 没有 context（服务层、静态函数）：`S.current.appearance_xxx`
- 带参数：`context.l10n.appearance_customThemeImported(name)`

## 常见报错

- **`The getter 'xxx' isn't defined for the type 'AppLocalizations'`**：生成产物过期，执行 `just l10n`。拉取别人的提交或新建 worktree 后最常见。
- **生成时报 placeholder 错误**：`zh` 的 arb 缺少对应的 `@key` 声明。
