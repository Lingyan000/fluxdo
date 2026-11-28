import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import vm from 'node:vm';

const script=JSON.parse(readFileSync(new URL('../../fixtures/metaverse/release/activity-feed-1.0.0.fluxplugin',import.meta.url),'utf8')).files['main.js'];
const clone=value=>value==null?value:JSON.parse(JSON.stringify(value));
const item=(id,day=Number(id))=>({id:String(id),action:'topics',topicId:Number(id)||1,createdAt:new Date(Date.UTC(2026,0,day)).toISOString(),title:'话题 '+id});
function setup({data=null,read=()=>({items:[]}),permissions={},locale='zh',system='allowed',scheduled=[]}={}){
  const handlers=new Map(),calls=[],toasts=[],navigations=[],notifications=[];
  let stored=clone(data),now=1000000;
  const api={
    host:{environment:async()=>({locale})},
    storage:{get:async()=>clone(stored),compareAndSet:async(_,old,next)=>{
      if(JSON.stringify(old)!==JSON.stringify(stored))return false;stored=clone(next);return true;
    }},
    permissions:{status:async()=>({forumActivity:true,forumProfiles:true,forumFollowing:true,identity:true,notifications:true,...permissions}),request:async()=>false},
    forum:{read:async args=>{calls.push(clone(args));return read(args);},open:async args=>navigations.push(args)},
    navigation:{setBadge:async()=>{},dismiss:async()=>navigations.push('dismiss')},
    notifications:{status:async()=>({authorized:true,system,canOpenSettings:true}),isAllowed:async()=>true,show:async args=>notifications.push(args),cancel:async()=>{},openSettings:async()=>navigations.push('notificationSettings')},
    tasks:{list:async()=>scheduled},toast:async text=>toasts.push(text),user:{get:async()=>({username:'owner'})},
  };
  class Clock extends Date{static now(){return now;}}
  vm.runInNewContext(script,{fluxdo:{on:(name,fn)=>handlers.set(name,fn)},Date:Clock,setTimeout:fn=>{now+=1000;queueMicrotask(fn);}});
  let serial=0;
  async function page(name='feed'){
    const data={},ctx={page:name,surface:String(++serial),api,setData:(key,value)=>data[key]=clone(value)};
    await handlers.get('page.open')(ctx,{});return {ctx,data};
  }
  const fire=(p,name,args={})=>handlers.get(name)(p.ctx,args);
  return {api,calls,toasts,navigations,notifications,page,fire,get state(){return stored;},advance:ms=>now+=ms,setLocale:value=>locale=value,
    task:()=>handlers.get('task.run')({api},{id:'refresh',background:true})};
}
const users=n=>({users:Array.from({length:n},(_,i)=>({name:'user'+i,id:i+1,avatar:''})),feed:{},serial:n,cursor:0});

test('批量更新全部名单，首次各来源仅建立基线',async()=>{
  const t=setup({data:users(4),read:args=>({items:args.resource==='actions'?[item(1)]:[{...item(2),reaction:'heart'}]})});
  const p=await t.page();await t.fire(p,'refresh');
  assert.equal(t.calls.length,12);assert.equal(p.data.progress,'已更新 4/4');
  assert.equal(p.data.stats[1].value,'0');assert.equal(t.notifications.length,0);
});
test('新动态增量与真实历史分页，不把历史标成未读',async()=>{
  let edition=0;
  const t=setup({data:users(1),read:args=>args.resource==='actions'?{items:args.offset?[item(2),item(1)]:edition?[item(5),item(4)]:[item(4),item(3)],nextOffset:args.offset?null:2}:{items:[]}});
  const p=await t.page();await t.fire(p,'refresh');edition++;
  await t.fire(p,'refresh');assert.equal(p.data.stats[1].value,'1');
  await t.fire(p,'more');assert.ok(t.calls.some(x=>x.offset===2));
  assert.deepEqual(p.data.items.map(x=>x.id),['topics:5','topics:4','topics:3','topics:2','topics:1']);
  assert.equal(p.data.items.filter(x=>x.unread).length,1);
  await t.fire(p,'read');await t.fire(p,'refresh');assert.equal(p.data.stats[1].value,'0');
});
test('部分来源失败保留已完成数据，下次从失败源继续',async()=>{
  let fail=true;
  const t=setup({data:users(1),read:args=>{if(args.resource==='reactions'&&fail)throw Error('offline');return {items:args.resource==='actions'?[item(1)]:[]};}});
  const p=await t.page();await t.fire(p,'refresh');assert.equal(t.state.feed[1].items.length,1);
  fail=false;t.calls.length=0;await t.fire(p,'refresh');assert.equal(t.calls[0].resource,'reactions');
  assert.equal(p.data.stats[1].value,'0');
});
test('后台时间预算逐页落盘，下次继续而不是反复初始化',async()=>{
  const t=setup({data:users(3),read:args=>{t.advance(8000);return {items:args.resource==='actions'?[item(1)]:[]};}});
  await t.task();assert.equal(t.calls.length,2);assert.equal(t.state.feed[1].nextSource,2);
  t.calls.length=0;await t.task();assert.equal(t.calls[0].resource,'boosts');
  assert.equal(t.calls[1].username,'user1');assert.equal(t.state.feed[1].items.length,1);
});
test('前后台并发刷新合并为一轮，删除订阅后迟到数据不写回',async()=>{
  let release;const hold=new Promise(r=>release=r);
  const t=setup({data:users(1),read:async()=>{await hold;return {items:[item(1)]};}});
  const p=await t.page(),loading=t.fire(p,'refresh');
  while(!t.calls.length)await new Promise(r=>setImmediate(r));
  await assert.rejects(t.task(),/activity_refresh_busy/);await t.fire(p,'remove',{id:1});release();await loading;
  assert.equal(t.state.users.length,0);assert.equal(t.state.feed[1],undefined);
});
test('旧版十条缓存迁移，不把更早记录当新动态',async()=>{
  const data=users(1);data.feed[1]={items:[{id:'topics:4',type:'topics',time:item(4).createdAt,unread:false}],water:{topics:item(4).createdAt}};
  const t=setup({data,read:args=>({items:args.resource==='actions'?[item(5),item(4),item(3)]:[]})});
  const p=await t.page();await t.fire(p,'refresh');assert.equal(p.data.stats[1].value,'1');
});
test('导入名单大小写去重、验证资料、一次写入，不改网站关注',async()=>{
  const t=setup({read:args=>({username:args.username,avatarUrl:'https://example.org/avatar.png'})});
  const p=await t.page('bulk');await t.fire(p,'bulkInput',{value:'@Alice\nalice, Bob；Bob'});await t.fire(p,'bulkApply');
  assert.equal(t.calls.length,2);assert.equal(t.state.users.length,2);assert.deepEqual(t.navigations,['dismiss']);
  assert.ok(t.calls.every(x=>x.resource==='user'));
});
test('导入存在无效用户时不写入半份名单，拒绝权限时不读资料',async()=>{
  const t=setup({read:args=>{if(args.username==='missing')throw Error('forum_not_found');return {username:args.username};}});
  const p=await t.page('bulk');await t.fire(p,'bulkInput',{value:'alice missing'});await t.fire(p,'bulkApply');
  assert.equal(t.state.users.length,0);assert.match(p.data.error,/没有找到/);
  const denied=setup({permissions:{forumProfiles:false}}),q=await denied.page('bulk');
  await denied.fire(q,'bulkInput',{value:'alice'});await denied.fire(q,'bulkApply');assert.equal(denied.calls.length,0);
});
test('限流冷却不会自动重放失败请求',async()=>{
  const t=setup({data:users(2),read:()=>{throw Error('forum_rate_limited');}});
  await assert.rejects(t.task(),/forum_rate_limited/);await t.task();assert.equal(t.calls.length,1);
});
test('页面隐藏后停止后续请求，重新显示不主动刷新',async()=>{
  let release;const hold=new Promise(r=>release=r);
  const t=setup({data:users(2),read:async()=>{await hold;return {items:[item(1)]};}});
  const p=await t.page(),loading=t.fire(p,'refresh');while(!t.calls.length)await new Promise(r=>setImmediate(r));
  await t.fire(p,'page.hide');release();await loading;await t.fire(p,'page.resume');assert.equal(t.calls.length,1);
});
test('四百条历史窗口继续读取，时间相同的动态也不遗漏',async()=>{
  const t=setup({data:users(1),read:args=>{
    if(args.resource!=='actions')return {items:[]};
    const offset=args.offset||0;return {items:Array.from({length:Math.min(50,500-offset)},(_,i)=>item(offset+i+1,1)),nextOffset:offset+50<500?offset+50:null};
  }});
  const p=await t.page();await t.fire(p,'refresh');const seen=new Set();
  for(let n=0;n<30;n++){
    for(const row of p.data.items)seen.add(row.id);
    if(p.data.historyWindowEnd){await t.fire(p,'historyNext');continue;}
    if(!p.data.more)break;
    await t.fire(p,'more');
    assert.ok(p.data.items.length<=400);
  }
  assert.equal(seen.size,500);
});
test('切换语言不重新取数，用户名称与话题标题保持原文',async()=>{
  const t=setup({data:users(1),locale:'en',read:args=>({items:args.resource==='actions'?[{...item(1),title:'我的原文标题'}]:[]})});
  const p=await t.page();await t.fire(p,'refresh');assert.equal(p.data.title,'1 subscriptions · 0 unread');
  assert.equal(p.data.items[0].title,'我的原文标题');const count=t.calls.length;
  t.setLocale('zh-TW');await t.fire(p,'host.environmentChanged');assert.equal(p.data.stats[0].label,'訂閱使用者');
  assert.equal(t.calls.length,count);assert.equal(p.data.items[0].title,'我的原文标题');
});
test('系统通知关闭显示设置入口，未知系统状态不会误报允许',async()=>{
  for(const system of ['denied','unknown','allowed']){
    const t=setup({system}),p=await t.page('settings');
    assert.equal(p.data.notify,true);assert.equal(p.data.notificationBlocked,system==='denied');
    assert.equal(p.data.notificationUnknown,system==='unknown');assert.equal(p.data.notificationSettings,true);
    await t.fire(p,'notificationSettings');assert.deepEqual(t.navigations,['notificationSettings']);
  }
});

if(process.env.ACTIVITY_UI_FIXTURES){
  const fixtures=[];
  for(const locale of ['zh','zh-TW','zh-HK','en']){
    const t=setup({data:users(2),locale,system:'denied',scheduled:[{id:'refresh',intervalSeconds:30,background:true}]}),settings=await t.page('settings'),bulk=await t.page('bulk');
    await t.fire(bulk,'bulkInput',{value:'@Alice\nBob'});
    fixtures.push({locale,widget:'Settings',data:settings.data},{locale,widget:'BulkImport',data:bulk.data});
  }
  writeFileSync(process.env.ACTIVITY_UI_FIXTURES,JSON.stringify(fixtures,null,2)+'\n');
}