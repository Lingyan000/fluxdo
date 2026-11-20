# discourse-cook-bundle

把 Discourse 官方 markdown→cooked HTML 管线（`frontend/discourse-markdown-it` +
`frontend/pretty-text` + 官方插件的 markdown features）用 esbuild 打成无
DOM 依赖的 IIFE bundle，由 `fluxdo_js_runtime` 在独立的后台 QuickJS 实例中执行，
五个原生平台共用这条编辑器预览管线。

Discourse 服务端本身就是用 MiniRacer（裸 V8）跑这同一份 JS 完成 cook 的，
所以整条管线天然 DOM-free，这里只做打包和数据注入，不改写任何管线逻辑。

## 构建

```bash
# 需要本机有 discourse 源码 checkout（默认 ~/f/discourse，可用环境变量覆盖）
DISCOURSE_SRC=~/f/discourse pnpm build
pnpm test   # node 冒烟测试，覆盖 22 个 feature fixture
```

产物：`assets/cook/discourse-cook.js`（提交进 git，头注释带源 commit）。

同一次构建还会从 `pretty-text/emoji/data` 生成 `lib/utils/emoji_names.g.dart`
（标准表情名 + 别名），app 展示短代码时据此判断表情是否存在。

## 运行时 API（bundle 挂在 globalThis）

```js
__fluxdoCook.init(optJsonString)  // 注入站点数据建 engine，返回 "ok"
__fluxdoCook.cook(rawMarkdown)    // → cooked HTML
__fluxdoCook.seedOnebox(url, html)              // 块级 onebox 结果灌缓存
__fluxdoCook.seedInlineOnebox(url, title, cls)  // 行内 onebox 标题灌缓存
__fluxdoCook.isReady()            // → bool
```

`optJsonString` 由 Dart 侧 `DiscourseCookService` 从 PreloadedDataService
组装：`{ baseUri, siteSettings, site: {censored_regexp, watched_words_*,
custom_emoji_translation, denied_emojis, markdown_additional_options,
hashtag_configurations, hashtag_icons, categories}, customEmoji, tagNames }`。

## 客户端预览 cook 与服务端 cooked 的已知差异

与 Discourse web composer 预览的降级行为一致：

| 项 | 客户端输出 | 说明 |
|---|---|---|
| mention | `<span class="mention">` | 服务端的 `<a class="mention">` 是 Ruby 后处理；Dart 侧 `postProcessCooked` 会补成 `a.mention` |
| upload:// | `transparent.png` + `data-orig-src` | fluxdo_render 已支持 data-orig-src 异步解析 |
| 裸链接 onebox | 首 cook 出 `a.onebox` / `inline-onebox-loading` 占位 | Dart 侧 `resolveOneboxes` 请求 /onebox、/inline-onebox 后 seed 缓存并重 cook，占位替换为卡片/标题 |
| hashtag | 本地 categories/top_tags 查表 | 查不到降级 `span.hashtag-raw` |
| unicode emoji | 转 `img.emoji`（emojiUnicodeReplacer 照抄服务端 shims 算法） | 与服务端 cooked 一致；Discourse web 预览反而不做这步 |

## 升级 Discourse 管线版本

`cd ~/f/discourse && git pull`，然后重新 `pnpm build && pnpm test`。
若 build 报 "import 了未映射的模块"，说明上游新增了依赖：确认该模块无
DOM/Ember 依赖后加进 `build.mjs` 的 `DISCOURSE_LIB_PASSTHROUGH`，或在
`shims/` 写 stub。
