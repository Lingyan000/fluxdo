# 差分契约 v1

文件：`oracle-fixtures.v1.json`。输入用 `fixtures.mjs` 或 CLI JSON；禁止把测试依赖加入 Flutter app。

顶层 `{version:1, oracle, settings, provenance, cases:[...]}`。每例：

- `id`：稳定字符串；`raw`：原始 Markdown。
- `tokens`：现有 `parseForEditor` DTO v1 的 token 数组，**官方 parser 修改前**的深拷贝。保留全部 attrs/meta/map/children，不把 token 的方法序列化。
- `doc`、`editedDoc`：真实 ProseMirror `Node.toJSON()`。默认 attrs 依官方 schema，省略空 content 不等于 null。
- `serialized`、`editedSerialized`：真实官方 serializer 输出，包含原样尾部换行；不要求与 raw 相等。
- `edit`：null（无编辑）或下面定义的一个操作；不是 ProseMirror transaction，不运行编辑器插件。
- `status:'ok'`；失败为 `status:'error', error:{stage,name,message}`，保留失败前已产字段，无隐式 fallback。stage 为 tokenize/parse/serialize/edit/editedSerialize；输入级错误为 input。CLI 任一失败退出码 1。

## 编辑定义（JS 与 Dart 共用）

`path: number[]` 从根 doc 开始，每个数字索引当前节点的 `content`，不是 PM 位置或源码位置。

1. `{op:'replaceText',path,from,to,text}`：目标必须为 text 节点；from/to 为该 text 字符串的 UTF-16 code-unit 半开区间。只替换文字，保留 marks；不自动拆分/合并节点、不重跑 linkify。空 text 非法，需显式失败。
2. `{op:'setAttrs',path,attrs}`：合并目标节点已定义的 schema attrs。未知 key 拒绝。不用于 marks，不改节点 type；不得自动丢弃未知属性。

3. `{op:'insertText',path,text}`：目标必须为没有content的空paragraph，text为非空字符串；加入一个不带marks的text子节点，专用于验证空文档/空容器的首次输入。不是通用插入事务。

修改 JSON 后必须用官方 `schema.nodeFromJSON()` 加 `Node.check()` 校验，再序列化。`setAttrs` 对详情 open 的修改可能不影响 Markdown，这是正确 oracle 结果。

## CLI

```sh
cd tools/editor-port-probe
pnpm install --frozen-lockfile
pnpm build
pnpm generate
pnpm test
printf '%s' '{"id":"live","raw":"[链接](https://example.com)","edit":{"op":"replaceText","path":[0,0],"from":0,"to":0,"text":"新"}}' | node cli.mjs
node cli.mjs /path/to/input.json
```

输入可为单例、数组或 `{cases:[...]}`。stdout 是完整实时 oracle JSON；不要用 pnpm 的脚本启动输出做 JSON 管道（pnpm 会打印脚本 banner）。
