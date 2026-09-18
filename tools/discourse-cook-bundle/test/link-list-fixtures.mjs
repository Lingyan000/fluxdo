// 独立真实 bundle mock 夹具，不访问网络或真实用户正文。
import { readFile, writeFile } from 'node:fs/promises';
import vm from 'node:vm';
const context = vm.createContext({console});
vm.runInContext(await readFile(new URL('../../../assets/cook/discourse-cook.js', import.meta.url), 'utf8'), context);
const api = context.__fluxdoCook;
api.init(JSON.stringify({siteSettings:{enable_markdown_linkify:true}}));
const cases = {
  angle: '<https://mock.example/path>',
  email: '<mock@example.test>',
  original: '[mock](upload://mock.pdf)',
  titledAttachment: '[mock|attachment](upload://mock.pdf "mock title")',
  parents: '- mock\n\n  3. child\n  4. next\n\n- other\n\n  7. child\n  8. next',
};
const out = {};
for (const [name, raw] of Object.entries(cases)) out[name] = {raw, ...JSON.parse(api.parseForEditor(raw))};
await writeFile(new URL('../../../packages/fluxdo_render/test/fixtures/link_list_tokens.json', import.meta.url), JSON.stringify(out, null, 2) + '\n');
