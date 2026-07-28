// 渲染帧标识核验 · Deno Deploy 入口
// 只做静态托管:解析全部在浏览器 Web Worker 中完成,图片不上传。
// 部署:deployctl deploy --project=<name> main.ts(或控制台指向本文件)

const dir = new URL(".", import.meta.url);

const routes: Record<string, [string, string]> = {
  "/": ["index.html", "text/html; charset=utf-8"],
  "/extract.js": ["extract.js", "text/javascript; charset=utf-8"],
};

Deno.serve(async (req: Request) => {
  const path = new URL(req.url).pathname;
  const entry = routes[path];
  if (!entry) {
    return new Response("Not Found", { status: 404 });
  }
  const body = await Deno.readFile(new URL(entry[0], dir));
  return new Response(body, {
    headers: {
      "content-type": entry[1],
      "cache-control": "no-cache",
    },
  });
});
