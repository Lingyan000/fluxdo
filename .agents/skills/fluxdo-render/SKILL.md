---
name: fluxdo-render
description: 在修改 `packages/fluxdo_render`（帖子 HTML 解析、节点渲染、编辑器、fixture）或处理其 golden 测试失败时使用。覆盖全量 golden 的运行与判读、存量像素漂移的排除、基线更新与 fixture 索引生成。
---

# fluxdo_render 渲染子包

`packages/fluxdo_render` 是独立的 git 子模块，也是应用里唯一的 HTML 渲染引擎。子包只依赖 Flutter，不感知宿主的主题系统：宿主通过 `ThemeData.extensions` 注入 `FluxdoRenderPalette`（语义色）、`FluxdoRenderShapes`（圆角）、`FluxdoRenderStyle`（标题字体、引用块）。未注入时的外观必须与默认一致。

## 验证

在子包根目录执行：

```sh
fvm dart analyze lib
fvm flutter test
```

- `test/golden_framework_smoke_test.dart` 名为 smoke，实际会遍历所有 fixture 做 golden 比对。只有 heading、paragraph 有单独的 golden 测试，其他节点全靠这个套件覆盖，所以改了渲染不能只跑对应的单测。
- 本机存在存量像素漂移：部分 golden 在干净代码上也会以 0.05%～0.2% 的差异失败。判断是否由自己引起，要对比改动前后同一个用例的差异值：

  ```sh
  fvm flutter test test/golden_framework_smoke_test.dart --plain-name "<用例名>"
  git stash push -u -q    # 仅当子包里只有你的改动时
  fvm flutter test test/golden_framework_smoke_test.dart --plain-name "<用例名>"
  git stash pop -q
  ```

  两次差异值相同，就与本次改动无关。
- 确实需要更新基线时，加 `--update-goldens` 重新生成，然后打开新的 png 目检（测试字体渲染成方块，图形保持真实形状），确认无误后连同 png 一起提交。再用 `git status test/golden/` 检查有没有波及无关节点；有波及说明改动带了副作用。

## Fixture

1. 放进 `test/fixtures/<节点>/`。
2. 重新生成索引，否则 example 演示应用里看不到新 fixture：

   ```sh
   dart run test/fixtures/scripts/gen_fixtures_index.dart
   ```

   生成的 `lib/src/dev/fixtures_index.g.dart` 需要提交。
3. 跑一遍上面的验证。

## 排查「渲染里少了东西」

宿主在渲染前会对 cooked HTML 做预处理（例如 emoji、链接点击数）。直接拿原始 cooked 测试时内容缺失，属于数据流问题，不是渲染问题。

## 提交

子模块先提交并推送，再在主仓提交子模块指针，见 [fluxdo-commit](../fluxdo-commit/SKILL.md)。
