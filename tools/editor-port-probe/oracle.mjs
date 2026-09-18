import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { JSDOM } from 'jsdom';
import * as pmModel from 'prosemirror-model';
import { Parser, createSchema, Serializer, extensions } from './dist/official.mjs';
const sandbox = {console};
vm.createContext(sandbox);
vm.runInContext(readFileSync(new URL('../../assets/cook/discourse-cook.js',import.meta.url),'utf8'),sandbox);
export const settings={enable_markdown_linkify:true,enable_markdown_footnotes:true,enable_markdown_typographer:false};
sandbox.__fluxdoCook.init(JSON.stringify({siteSettings:settings}));
globalThis.DOMParser=new JSDOM('').window.DOMParser;
function restore(tokens) {
 return tokens.map(t=>({...t,children:t.children && restore(t.children),attrGet(name){return this.attrs?.find(a=>a[0]===name)?.[1] ?? null;}}));
}
const params={pmModel,getContext:()=>({siteSettings:settings})};
export const schema=createSchema(extensions);
const parser=new Parser(extensions,params);
const serializer=new Serializer(extensions,params);
export function applyEdit(doc,edit) {
 const json=structuredClone(doc);
 if(!edit || !Array.isArray(edit.path)) throw Error('缺少 edit.path');
 let node=json;
 for(const index of edit.path){if(!Number.isInteger(index)||index<0||!node.content?.[index]) throw Error('无效 edit.path');node=node.content[index];}
 if(edit.op==='insertText'){
  if(node.type!=='paragraph'||node.content?.length||typeof edit.text!=='string'||!edit.text.length) throw Error('insertText 仅支持空段落');
  node.content=[{type:'text',text:edit.text}];
 }else if(edit.op==='replaceText'){
  const {from,to,text}=edit;
  if(node.type!=='text'||!Number.isInteger(from)||!Number.isInteger(to)||from<0||to<from||to>node.text.length||typeof text!=='string') throw Error('无效 replaceText');
  node.text=node.text.slice(0,from)+text+node.text.slice(to);
 }else if(edit.op==='setAttrs'){
  if(!edit.attrs||typeof edit.attrs!=='object'||Array.isArray(edit.attrs)) throw Error('无效 attrs');
  for(const k of Object.keys(edit.attrs)) if(!(k in (schema.nodes[node.type]?.spec.attrs||{}))) throw Error('未定义节点属性 '+k);
  node.attrs={...node.attrs,...edit.attrs};
 }else throw Error('未知 edit.op');
 const result=schema.nodeFromJSON(json);result.check();return result;
}
export function runCase(input){
 const {id,raw,edit=null}=input;
 let stage='tokenize';
 const output={id,raw,edit};
 try{
  if(typeof raw!=='string') throw Error('raw 必须为字符串');
  output.tokens=JSON.parse(sandbox.__fluxdoCook.parseForEditor(raw)).tokens;
  // 官方 quote/link/footnote handler 会修改 token，必须对完整 DTO 深拷贝。
  globalThis.__editorProbeParse=()=>restore(structuredClone(output.tokens));
  stage='parse';const doc=parser.convert(schema,raw);doc.check();output.doc=doc.toJSON();
  stage='serialize';output.serialized=serializer.convert(doc);
  if(edit){stage='edit';const edited=applyEdit(output.doc,edit);output.editedDoc=edited.toJSON();stage='editedSerialize';output.editedSerialized=serializer.convert(edited);}
  output.status='ok';
 }catch(e){output.status='error';output.error={stage,name:e.name,message:e.message||'官方 UnsupportedTokenError（不支持此 token）'};}
 finally{delete globalThis.__editorProbeParse;}
 return output;
}
export function envelope(cases){return {version:1,oracle:'discourse-prosemirror-adapted',settings,provenance:JSON.parse(readFileSync(new URL('./source-manifest.v1.json',import.meta.url),'utf8')),cases:cases.map(runCase)};}
