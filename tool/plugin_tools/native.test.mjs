import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile, writeFile, mkdtemp, rm} from 'node:fs/promises';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {resolve, dirname} from 'node:path';
import {spawn} from 'node:child_process';
import {createInterface} from 'node:readline';
import {setTimeout as delay} from 'node:timers/promises';
const toolsRoot=process.env.FLUXDO_PLUGIN_TOOLS;
if(!toolsRoot)throw new Error('设置 FLUXDO_PLUGIN_TOOLS 为独立工具仓库目录');
const cliRoot=process.env.FLUXDO_PLUGIN_CLI??resolve(toolsRoot,'packages/cli');
const {createPluginDevServer}=await import(pathToFileURL(resolve(cliRoot,'dist/dev/server.mjs')).href);

const base=dirname(fileURLToPath(import.meta.url));
const project=resolve(base,'../..');
const dart=process.env.FLUXDO_DART ?? 'dart';

class NativePeer {
  constructor(){
    this.pending=new Map();this.waiters=[];this.messages=[];this.timers=new Map();this.seq=0;this.failures=[];
    this.child=spawn(dart,['run','tool/plugin_tools/quickjs_peer.dart'],{
      cwd:project,stdio:['pipe','pipe','pipe'],windowsHide:true,
    });
    this.exit=new Promise(resolve=>this.child.once('exit',resolve));
    this.child.stderr.on('data',()=>{});
    this.child.once('error',error=>this.failures.push(error));
    createInterface({input:this.child.stdout}).on('line',line=>{
      let packet;try{packet=JSON.parse(line);}catch{return;}
      if(packet.type==='result') {
        const pending=this.pending.get(packet.id);this.pending.delete(packet.id);
        if(pending)packet.ok?pending.resolve():pending.reject(new Error(packet.error));
        return;
      }
      const message=packet.type==='message'?packet.message:packet;
      message.index=this.messages.length;this.messages.push(message);
      for(const waiter of [...this.waiters]) if(waiter.predicate(message)){
        clearTimeout(waiter.timer);this.waiters.splice(this.waiters.indexOf(waiter),1);waiter.resolve(message);
      }
      if(message.t==='dev'&&message.kind==='transport'){
        try{this.connection.receive(message.payload);}catch(error){this.failures.push(error);}
      }
      if(message.t==='timer'){
        if(message.op==='clear'){clearTimeout(this.timers.get(message.id));this.timers.delete(message.id);}
        else this.timers.set(message.id,setTimeout(()=>{
          this.timers.delete(message.id);this.evaluate('__fluxdoMetaverse.timer('+message.id+')').catch(error=>this.failures.push(error));
        },message.ms));
      }
    });
  }
  evaluate(code){
    const id=++this.seq;
    return new Promise((resolve,reject)=>{this.pending.set(id,{resolve,reject});this.child.stdin.write(JSON.stringify({id,code})+'\n');});
  }
  wait(predicate,timeout=10000){
    const existing=this.messages.find(predicate);if(existing)return Promise.resolve(existing);
    return new Promise((resolve,reject)=>{
      const waiter={predicate,resolve};
      waiter.timer=setTimeout(()=>{this.waiters.splice(this.waiters.indexOf(waiter),1);reject(new Error('消息等待超时：'+JSON.stringify(this.messages.slice(-5))));},timeout);
      this.waiters.push(waiter);
    });
  }
  async start(server){
    await this.wait(m=>m.type==='ready',60000);
    this.connection=server.connect(payload=>{
      this.messages.push({t:'hot-payload',payload,index:this.messages.length});
      this.evaluate('__devReceive('+JSON.stringify(payload)+')').catch(error=>this.failures.push(error));
    });
    await this.evaluate(await readFile(resolve(cliRoot,'dist/dev/runner.js'),'utf8'));
    await this.evaluate(`
      const post=message=>sendMessage('fluxdoMetaverse',JSON.stringify({t:'dev',...message}));
      globalThis.__runner=FluxdoDev.createPluginModuleRunner({
        transport:{
          connect(handlers){globalThis.__devReceive=payload=>handlers.onMessage(payload);},
          disconnect(){globalThis.__devReceive=()=>{};},
          send(payload){post({kind:'transport',payload});}
        },
        onReloadRequired(payload){post({kind:'reload-required',payload});}
      });
      globalThis.__devImport=path=>__runner.import(path).then(()=>post({kind:'loaded',path}),error=>post({kind:'import-error',path,error:String(error)}));
      __devImport('/main.ts');
    `);
    const loaded=await this.wait(m=>m.t==='dev'&&(m.kind==='loaded'||m.kind==='import-error'));
    assert.equal(loaded.kind,'loaded',JSON.stringify(loaded));
  }
  async dispatch(){
    const after=this.messages.length;
    await this.evaluate('__fluxdoMetaverse.dispatch("increment",'+JSON.stringify(JSON.stringify({surface:'s1',kind:'card'}))+',"{}")');
    return this.wait(m=>m.index>=after&&m.t==='data');
  }
  async close(){
    this.connection?.close();
    for(const timer of this.timers.values())clearTimeout(timer);
    for(const waiter of this.waiters)clearTimeout(waiter.timer);
    this.child.stdin.end(JSON.stringify({type:'close'})+'\n');
    const timeout=setTimeout(()=>this.child.kill(),5000);timeout.unref();
    await this.exit;clearTimeout(timeout);
  }
}

const initial=`import {counter} from './counter';
const previous=import.meta.hot.data.reloads??0;
fluxdo.on('increment',ctx=>{
 counter.value+=1;
 ctx.setData('result',{count:counter.value,caption:'v1',initializations:globalThis.counterInitializations,reloads:previous});
});
if(import.meta.hot){
 import.meta.hot.accept();
 import.meta.hot.dispose(data=>{data.reloads=previous+1;});
}
`;

test('Vite 在真实 QuickJS 中更新 TS 模块并保持未改动模块状态', {timeout:120000}, async t=>{
  const root=await mkdtemp(resolve(project,'build/plugin-tools-native-'));
  const outside=resolve(root,'../outside-secret.ts');
  await writeFile(resolve(root,'package.json'),'{"private":true,"type":"module"}');
  await writeFile(resolve(root,'counter.ts'),'export const counter={value:0};globalThis.counterInitializations=(globalThis.counterInitializations??0)+1;');
  await writeFile(resolve(root,'main.ts'),initial);
  await writeFile(resolve(root,'node-import.ts'),"import fs from 'node:fs'; export default fs;");
  await writeFile(outside,'globalThis.OUTSIDE_WAS_EXECUTED=true;export const secret=42;');
  const server=createPluginDevServer({root});
  const peer=new NativePeer();
  const service=await server;
  t.after(async()=>{await peer.close();await service.close();await rm(root,{recursive:true,force:true});await rm(outside,{force:true});});
  await peer.start(service);
  let data=await peer.dispatch();
  assert.deepEqual(data.v,{count:1,caption:'v1',initializations:1,reloads:0});
  await peer.dispatch();
  const changed=performance.now();
  await writeFile(resolve(root,'main.ts'),initial.replace("caption:'v1'","caption:'v2'"));
  for(let attempt=0;attempt<100;attempt++){
    await delay(25);data=await peer.dispatch();if(data.v.caption==='v2')break;
  }
  assert.equal(data.v.caption,'v2');assert.equal(data.v.initializations,1);assert.equal(data.v.reloads,1);
  const next=await peer.dispatch();assert.equal(next.v.count,data.v.count+1,'事件处理器不应重复执行');
  t.diagnostic(`本机文件改动至新模块可执行：${Math.round(performance.now()-changed)} ms`);

  const beforeError=peer.messages.length;
  await writeFile(resolve(root,'main.ts'),'export const broken: = ;');
  await peer.wait(m=>m.index>=beforeError&&m.t==='log'&&/Unexpected|Expected|Failed to reload|Internal Server Error/.test(m.message));
  assert.equal((await peer.dispatch()).v.caption,'v2','语法错误时保留旧处理器');
  await writeFile(resolve(root,'main.ts'),initial.replace("caption:'v1'","caption:'v3'"));
  for(let attempt=0;attempt<100;attempt++){
    await delay(25);data=await peer.dispatch();if(data.v.caption==='v3')break;
  }
  assert.equal(data.v.caption,'v3');

  await peer.evaluate('__devImport("/node-import.ts")');
  const refused=await peer.wait(m=>m.kind==='import-error'&&m.path==='/node-import.ts');
  assert.match(refused.error,/不支持此导入/);
  const outsideUrl='/@fs/'+outside.replaceAll('\\','/');
  await peer.evaluate('__devImport('+JSON.stringify(outsideUrl)+')');
  const forbidden=await peer.wait(m=>m.kind==='import-error'&&m.path===outsideUrl);
  assert.match(forbidden.error,/outside|denied|403|allow/i);
  await peer.evaluate('console.log("capabilities",typeof process,typeof require,typeof fetch,typeof document,typeof OUTSIDE_WAS_EXECUTED)');
  const capabilities=await peer.wait(m=>m.t==='log'&&m.message.startsWith('capabilities'));
  assert.equal(capabilities.message,'capabilities undefined undefined undefined undefined undefined');
  assert.deepEqual(peer.failures,[]);

  const reloadStart=peer.messages.length;
  await peer.evaluate('__devReceive({type:"full-reload",path:"*"})');
  await peer.wait(m=>m.index>=reloadStart&&m.kind==='reload-required');
  assert.equal((await peer.dispatch()).v.initializations,1,'需要整插件重启时必须先交还宿主协调');
});
