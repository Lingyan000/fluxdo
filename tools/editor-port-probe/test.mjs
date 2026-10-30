import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { envelope, runCase } from './oracle.mjs';
import { fixtures } from './fixtures.mjs';
const golden=JSON.parse(readFileSync(new URL('./oracle-fixtures.v1.json',import.meta.url),'utf8'));
test('全部样例实时官方转换与版本化产物逐字段相等',()=>{assert.deepEqual(JSON.parse(JSON.stringify(envelope(fixtures))),golden);assert.ok(golden.cases.every(c=>c.status==='ok' && c.edit && c.editedDoc && typeof c.editedSerialized==='string'));});
test('重复调用不受官方原地修改 token 的污染',()=>{assert.deepEqual(envelope(fixtures),envelope(fixtures));});
test('引用、details、HTML、脚注、列表均确实经过官方扩展',()=>{
 const byId=Object.fromEntries(golden.cases.map(c=>[c.id,c]));
 assert.equal(byId['quote-empty'].doc.content[0].type,'quote');
 assert.equal(byId['details-empty'].doc.content[0].type,'details');
 assert.equal(byId['html-block'].doc.content[0].type,'html_block');
 assert.equal(byId['html-empty-kbd'].doc.content[0].content[1].type,'html_inline');
 assert.equal(byId['footnote-named-multi-ref'].doc.content[0].content[1].type,'footnote');
 assert.equal(byId['list-loose-bullet'].doc.content[0].attrs.tight,false);
 assert.equal(byId['link-attachment'].doc.content[0].content[0].marks[0].attrs.attachment,true);
});
test('不支持的扩展明确失败而非透传原文',()=>{const r=runCase({id:'unsupported',raw:'~~删~~'});assert.equal(r.status,'error');assert.equal(r.error.stage,'parse');assert.equal(r.serialized,undefined);});
test('错误操作不会静默成功',()=>{
 for(const edit of [{op:'bad',path:[]},{op:'replaceText',path:[8],from:0,to:0,text:'x'},{op:'setAttrs',path:[0],attrs:{unknown:true}},{op:'replaceText',path:[0,0],from:0,to:1,text:''}]){
  const result=runCase({id:'invalid',raw:'x',edit});assert.equal(result.status,'error');assert.equal(result.error.stage,'edit');
 }
});
test('UTF-16 编辑保留 marks',()=>{const r=runCase({id:'unicode',raw:'[a😀b](https://example.com)',edit:{op:'replaceText',path:[0,0],from:1,to:3,text:'汉'}});assert.equal(r.editedDoc.content[0].content[0].text,'a汉b');assert.deepEqual(r.doc.content[0].content[0].marks,r.editedDoc.content[0].content[0].marks);});
test('依赖与 tokenizer hash 未漂移',()=>{
 const hash=p=>createHash('sha256').update(readFileSync(new URL(p,import.meta.url))).digest('hex');
 assert.equal(hash('../../assets/cook/discourse-cook.js'),golden.provenance.tokenizer.sha256);
 assert.equal(hash('./pnpm-lock.yaml'),golden.provenance.testLockSha256);
});
test('CLI 实时 stdin JSON；输入错误明确退出',()=>{
 const invoke=input=>spawnSync(process.execPath,[new URL('./cli.mjs',import.meta.url).pathname],{input,encoding:'utf8'});
 const ok=invoke(JSON.stringify({id:'live',raw:'测试'}));assert.equal(ok.status,0);assert.equal(JSON.parse(ok.stdout).cases[0].serialized,'测试');
 const bad=invoke('{');assert.equal(bad.status,1);assert.equal(JSON.parse(bad.stdout).error.stage,'input');
});
