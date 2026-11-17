import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const root=new URL('../../../',import.meta.url);
const dts=readFileSync(new URL('packages/fluxdo_plugin_runtime/sdk/fluxdo.d.ts',root),'utf8');
// tsc 负责语法和类型检查；此处只提取 Api 的成员层级，与实际 JS 导出核对。
const declarations=dts.replace(/\/\*[\s\S]*?\*\//g,'');
function block(text,open){let depth=1,end=open+1;for(;depth&&end<text.length;end++){if(text[end]==='{')depth++;if(text[end]==='}')depth--;}return {text:text.slice(open+1,end-1),end};}
const signatures=[];
function members(text,prefix=''){
  let pos=0;
  while(pos<text.length){
    const match=/^\s*(\w+)\s*(?:<[^>]*>)?\s*([(:])/.exec(text.slice(pos));
    if(!match)break;
    const name=prefix+match[1],begin=pos+match[0].length;
    if(match[2]===':'){
      const body=block(text,text.indexOf('{',begin));members(body.text,name+'.');pos=body.end;
      if(text[pos]===';')pos++;
    }else{
      signatures.push(name);let braces=0,rounds=1;pos=begin;
      for(;pos<text.length;pos++){
        const char=text[pos];if(char==='{')braces++;if(char==='}')braces--;if(char==='(')rounds++;if(char===')')rounds--;
        if(char===';'&&braces===0&&rounds===0){pos++;break;}
      }
    }
  }
}
members(block(declarations,declarations.indexOf('{',declarations.indexOf('interface Api'))).text);
const quotes=String.fromCharCode(39).repeat(3);
const prelude=readFileSync(new URL('packages/fluxdo_plugin_runtime/lib/src/metaverse_plugin_prelude.dart',root),'utf8').split('r'+quotes,2)[1].split(quotes+';',1)[0];
const context=vm.createContext({sendMessage:()=>{}});vm.runInContext(prelude,context);
const actual=Object.entries(context.fluxdo).flatMap(([name,value])=>typeof value==='function'?[name]:Object.keys(value).map(method=>name+'.'+method));
assert.deepEqual(signatures.sort(),actual.sort(),'SDK 声明必须覆盖真实桥接方法');
const examples=readFileSync(new URL('lib/modules/metaverse/developer/metaverse_api_examples.dart',root),'utf8');
const documented=[...examples.matchAll(/MetaverseApiExample\(\s*'([^']+)'/g)].map(match=>match[1]);
assert.deepEqual(documented.sort(),actual.filter(name=>name!=='on').sort(),'开发中心必须覆盖全部公开异步 API');
console.log('SDK 类型与开发中心覆盖全部 '+actual.length+' 个公开方法');
