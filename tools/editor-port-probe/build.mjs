import { build } from 'esbuild';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const here = path.dirname(fileURLToPath(import.meta.url));
const root = process.env.DISCOURSE_ROOT || '/Users/pengyongteng1/f/discourse';
const commit = 'b3b561e5fad412c038e222499ebe22050b4a8de4';
if (execFileSync('git', ['-C', root, 'rev-parse', 'HEAD'], {encoding:'utf8'}).trim() !== commit) throw Error('Discourse commit 不匹配');
const pm = 'frontend/discourse/app/static/prosemirror/';
const extensions = ['link','quote','bullet-list','ordered-list','html-inline','html-block'];
const imports = extensions.map((n,i) => `import e${i} from '${root}/${pm}extensions/${n}.js';`);
for (const [i,n] of ['discourse-details','footnote'].entries()) imports.push(`import e${i+6} from '${root}/plugins/${n}/assets/javascripts/lib/rich-editor-extension.js';`);
const entry = `${imports.join('\n')}\nexport {default as Parser} from '${root}/${pm}core/parser.js';\nexport {createSchema} from '${root}/${pm}core/schema.js';\nexport {default as Serializer} from '${root}/${pm}core/serializer.js';\nexport const extensions = [${Array.from({length:8},(_,i)=>'e'+i)}];`;
await mkdir(path.join(here,'dist'),{recursive:true});
const result = await build({stdin:{contents:entry,resolveDir:here,sourcefile:'oracle-entry.js'},outfile:path.join(here,'dist/official.mjs'),bundle:true,format:'esm',platform:'node',packages:'external',tsconfigRaw:{compilerOptions:{}},metafile:true,plugins:[{name:'隔离编辑器UI',setup(b){
 b.onResolve({filter:/^\.\.\/lib\/markdown-it$/},()=>({path:'tokenizer',namespace:'adapt'}));
 b.onResolve({filter:/^discourse\/static\/prosemirror\/lib\/plugin-utils$/},()=>({path:'ui',namespace:'adapt'}));
 b.onResolve({filter:/^discourse\/static\/prosemirror\//},args=>({path:path.join(root,'frontend/discourse/app',args.path.slice('discourse/'.length)+'.js')}));
 b.onResolve({filter:/^discourse-markdown-it\//},args=>({path:path.join(root,'frontend/discourse-markdown-it/src',args.path.slice('discourse-markdown-it/'.length)+'.js')}));
 b.onLoad({filter:/.*/,namespace:'adapt'},args=>({contents:args.path==='tokenizer' ? 'export function parse(raw) { return globalThis.__editorProbeParse(raw); }' : 'function unavailable(){throw Error("Oracle 不运行 UI 插件");} export {unavailable as getChangedRanges, unavailable as markInputRule};',loader:'js'}));
}}]});
const hash = data=>createHash('sha256').update(data).digest('hex');
const sources={};
for(const name of Object.keys(result.metafile.inputs)) {
 // esbuild 的 metafile 路径相对于进程目录。
 const file=path.resolve(name);
 if(file.startsWith(root+'/')) sources[path.relative(root,file)] = hash(await readFile(file));
}
sources['pnpm-lock.yaml']=hash(await readFile(path.join(root,'pnpm-lock.yaml')));
for(const [file,sha] of Object.entries(sources)) {
 if(hash(execFileSync('git',['-C',root,'show',`${commit}:${file}`],{maxBuffer:20*1024*1024}))!==sha) throw Error('固定 commit 源文件被修改：'+file);
}
const provenance={version:1,commit,sources,tokenizer:{path:'assets/cook/discourse-cook.js',sha256:hash(await readFile(path.join(here,'../../assets/cook/discourse-cook.js')))},testLockSha256:hash(await readFile(path.join(here,'pnpm-lock.yaml'))),dependencies:JSON.parse(await readFile(path.join(here,'package.json'),'utf8')).devDependencies};
await writeFile(path.join(here,'source-manifest.v1.json'),JSON.stringify(provenance,null,2)+'\n');
console.log('官方 oracle 构建完成，已记录源码 SHA-256');
