# TypeScript 插件模板

在本目录运行 `npm ci`，再运行 `npm run build`。类型错误会阻止打包；esbuild 将模块合并为宿主可执行的 `main.js`，不要依赖 Node、DOM 或运行时动态 import。

回到仓库根目录运行：

```sh
dart run tool/pack_metaverse_plugin.dart docs/examples/metaverse-plugin-ts build/counter.fluxplugin
```

模板通过相对路径引用 `packages/fluxdo_plugin_runtime/sdk/fluxdo.d.ts`。复制到独立仓库时同步复制该声明，并修改 tsconfig 的 include 路径。安装后点击「增加计数」即可验证原生确认、存储和提示。
