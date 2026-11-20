// 从 Discourse 源码的 pretty-text/emoji/data 导出标准表情名集合（规范名 + 别名），
// 生成 lib/utils/emoji_names.g.dart，供 app 判断 `:name:` 是否为真实表情。
//
// 与 cook bundle 同源（DISCOURSE_SRC），升级 Discourse 后随 `pnpm build` 一起重新生成。
import * as esbuild from 'esbuild';
import { execFile } from 'node:child_process';
import { writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(__dirname, '../..');
const outFile = path.join(projectRoot, 'lib/utils/emoji_names.g.dart');

const discourseSrc = path.resolve(
  process.env.DISCOURSE_SRC ?? path.join(homedir(), 'f/discourse'),
);
const dataFile = path.join(
  discourseSrc,
  'frontend/discourse/pretty-text/emoji/data.ts',
);

let discourseCommit = 'unknown';
try {
  const { stdout } = await promisify(execFile)(
    'git',
    ['-C', discourseSrc, 'rev-parse', 'HEAD'],
  );
  discourseCommit = stdout.trim();
} catch {
  /* 非 git checkout（如 tarball）时保持 unknown */
}

const result = await esbuild.build({
  entryPoints: [dataFile],
  bundle: true,
  format: 'esm',
  write: false,
  logLevel: 'warning',
});
const source = result.outputFiles[0].text;
const { emojis, aliases } = await import(
  `data:text/javascript;base64,${Buffer.from(source).toString('base64')}`
);

// 官方 emojiExists：emojis 或 aliasMap（别名 → 规范名）里有即为标准表情
const names = new Set(emojis);
for (const list of Object.values(aliases)) {
  for (const alias of list) names.add(alias);
}

const dartString = (s) => `'${s.replace(/[\\'$]/g, (c) => `\\${c}`)}'`;
const lines = [...names].sort().map((name) => `  ${dartString(name)},`);

await writeFile(
  outFile,
  '// 由 tools/discourse-cook-bundle/gen-emoji-names.mjs 根据 Discourse 源码\n' +
    '// pretty-text/emoji/data 生成，勿手改。升级后在该目录执行 `pnpm build`。\n' +
    `// source: discourse@${discourseCommit}\n` +
    '\n' +
    '/// 标准表情名（规范名 + 别名，不含肤色后缀与站点自定义表情）。\n' +
    'const standardEmojiNames = <String>{\n' +
    `${lines.join('\n')}\n` +
    '};\n',
);

console.log(
  `✓ ${path.relative(projectRoot, outFile)}  ${names.size} names (discourse@${discourseCommit.slice(0, 10)})`,
);
