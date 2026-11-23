import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import {createHash} from 'node:crypto';
import {pathToFileURL} from 'node:url';
import {resolve} from 'node:path';
const root=new URL('../../',import.meta.url);
const dts=readFileSync(new URL('test/fixtures/metaverse/sdk/fluxdo.d.ts',root),'utf8').replaceAll('\r\n','\n');
const contract=JSON.parse(readFileSync(new URL('test/fixtures/metaverse/sdk/contract.json',root),'utf8'));
assert.equal(createHash('sha256').update(dts).digest('hex'),contract.typesSha256);
if(process.env.FLUXDO_PLUGIN_TOOLS){
 const sdk=pathToFileURL(resolve(process.env.FLUXDO_PLUGIN_TOOLS,'packages/sdk/types/global.d.ts'));
 assert.equal(readFileSync(sdk,'utf8').replaceAll('\r\n','\n'),dts,'工具 SDK 与宿主兼容夹具不同步');
}
const featureSource=readFileSync(new URL('packages/fluxdo_plugin_runtime/lib/src/plugin_features.dart',root),'utf8');
const featureBody=/enum PluginFeature\s*{([^}]+)}/.exec(featureSource)[1];
assert.deepEqual([...featureBody.matchAll(/\b(\w+)\s*,/g)].map(m=>m[1]).sort(),[...contract.features].sort());
// tsc 负责语法和类型检查；此处只提取 Api 的成员层级，与实际 JS 导出核对。
const declarations=dts.replace(/\/\*[\s\S]*?\*\//g,'');
const declaredFeatures=[.../type Feature\s*=([^;]+);/.exec(declarations)[1].matchAll(/'([^']+)'/g)].map(m=>m[1]).sort();
assert.deepEqual(declaredFeatures,[...contract.features].sort(),'Feature 类型须覆盖全部宿主能力');
if(process.env.FLUXDO_PLUGIN_TOOLS){
 const schema=JSON.parse(readFileSync(resolve(process.env.FLUXDO_PLUGIN_TOOLS,'packages/sdk/schema/plugin.schema.json'),'utf8'));
 assert.deepEqual([...schema.properties.requiredFeatures.items.enum].sort(),declaredFeatures,'清单 schema 与 Feature 类型须一致');
}
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
const prelude=readFileSync(new URL('packages/fluxdo_plugin_runtime/lib/src/metaverse_plugin_prelude.dart',root),'utf8').replaceAll('\r\n','\n').split('r'+quotes,2)[1].split(quotes+';',1)[0];
const context=vm.createContext({sendMessage:()=>{}});vm.runInContext(prelude,context);
const actual=Object.entries(context.fluxdo).flatMap(([name,value])=>typeof value==='function'?[name]:Object.keys(value).map(method=>name+'.'+method));
assert.deepEqual(signatures.sort(),actual.sort(),'SDK 声明必须覆盖真实桥接方法');
const examples=readFileSync(new URL('lib/modules/metaverse/developer/metaverse_api_examples.dart',root),'utf8');
const documented=[...examples.matchAll(/MetaverseApiExample\(\s*'([^']+)'/g)].map(match=>match[1]);
assert.deepEqual(documented.sort(),actual.filter(name=>name!=='on').sort(),'开发中心必须覆盖全部公开异步 API');
console.log('SDK 类型与开发中心覆盖全部 '+actual.length+' 个公开方法');

if(process.env.FLUXDO_PLUGIN_TOOLS){
 const tools=process.env.FLUXDO_PLUGIN_TOOLS;
 assert.equal(readFileSync(resolve(tools,'packages/sdk/testing/prelude.js'),'utf8').replaceAll('\r\n','\n'),prelude,'模拟宿主必须使用同版生产前导脚本');
 assert.deepEqual(JSON.parse(readFileSync(resolve(tools,'packages/sdk/schema/components.json'),'utf8')),JSON.parse(readFileSync(new URL('test/fixtures/metaverse/sdk/components.json',root),'utf8')),'组件契约必须同步');
}
