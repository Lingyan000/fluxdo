# 渲染帧标识印记 · 离线核验工具

- `extract.py` — 本地核验 CLI(`uv run extract.py 帧.png`,自检 `--self-test`)
- `web/` — 网页版核验器,Deno Deploy 部署

## 网页版部署(Deno Deploy)

解析完全在浏览器 Web Worker 内完成,图片不上传;Deno 侧只是静态托管,
无任何依赖。

```sh
# 本地预览
deno run --allow-net --allow-read web/main.ts

# 部署(二选一)
deployctl deploy --project=<项目名> web/main.ts
# 或在 dash.deno.com 新建 Playground/项目,入口指向 web/main.ts
```

三个文件都要在:`web/main.ts`、`web/index.html`、`web/extract.js`。

## 常量同步契约

编码几何/结构由三处共同实现,改任何一处必须同步其余两处:

1. `lib/widgets/render_signet/render_signet_codec.dart`(编码端,权威定义)
2. `extract.py` 头部常量区
3. `web/extract.js` 头部常量区

## 结果解读

- `verified`(已复核)= 匹配滤波主峰显著超次峰,可作为结论;
- 未复核命中是穷举噪声,**margin 极低(<0.01)的行一律不可信**,
  只看排最前的 verified 结果;
- 无印记图片可能偶发未复核候选,属预期,不会出现高 margin 的 verified 误报。
