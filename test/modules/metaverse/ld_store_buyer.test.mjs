import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import vm from 'node:vm';
const script=readFileSync(new URL('../../fixtures/metaverse/ld-store/main.js',import.meta.url),'utf8');
const storefront=JSON.parse(readFileSync(new URL('../../fixtures/metaverse/ld-store-public.json',import.meta.url),'utf8'));
const campaign={id:'c1',name:'测试券',discountType:'fixed_amount',fixedAmount:2,minSpend:5,scopeType:'product',productId:'p1',sellerUsername:'seller',claimable:true};
function setup({authorized=true,claims=null,consent=true,respond=()=>({}),timers=false,streams=false,locale='zh'}={}) {
  const handlers=new Map(),calls=[],nav=[],confirmations=[];
  const pendingTimers=new Map(),streamCalls=[];let timerId=0;
  const api={
    on:(name,handler)=>handlers.set(name,handler),
    host:{environment:async()=>({locale})},
    user:{get:async()=>({id:42,username:'tester'})},
    credentials:{status:async(_name,options)=>({authorized,...(authorized && options?.jwt && claims ? {claims} : {})}),remove:async()=>{authorized=false;},capture:async()=>{throw Error('unexpected capture');}},
    permissions:{status:async()=>({identity:true,serviceAccount:true,payments:true}),request:async()=>true},
    crypto:{pkce:async()=>({verifier:'v',challenge:'c',method:'S256'}),uuid:async()=> 'uuid'},
    storage:{get:async()=>null},
    dialogs:{confirm:async options=>{confirmations.push(options);return consent;}},
    connect:{authorize:async()=>null},
    navigate:async(page,args)=>nav.push({page,args}),
    navigation:{dismiss:async()=>nav.push({dismiss:true})},
    browser:{open:async(url,options)=>nav.push({url,options})},
    toast:async()=>{},
    fetch:async(url,options={})=>{
      const request={url:new URL(url),method:options.method||'GET',...options};calls.push(request);
      const result=await respond(request);
      return {ok:!(result?.failure),status:result?.failure||200,json:()=>result?.failure ? {success:false,error:result.message} : {success:true,data:result}};
    },
  };
  if(streams)api.streams={open:async options=>{streamCalls.push({open:options});return options.id;},close:async id=>streamCalls.push({close:id})};
  vm.runInNewContext(script,{fluxdo:api,console:{warn:()=>{},log:()=>{}},...(timers ? {
    setTimeout:(fn,delay)=>{const id=++timerId;pendingTimers.set(id,{fn,delay});return id;},
    clearTimeout:id=>pendingTimers.delete(id),
  } : {})});
  let sequence=0;
  async function page(name,params={}) {
    const data={},ctx={surface:String(++sequence),page:name,params,api,setData:(key,value)=>data[key]=value};
    await handlers.get('page.open')(ctx);return {ctx,data};
  }
  const fire=(p,name,args={})=>handlers.get(name)(p.ctx,args);
  return {api,handlers,calls,nav,confirmations,page,fire,pendingTimers,streamCalls,setLocale(value){locale=value;},setAuthorized(value){authorized=value;},async tick(){const [id,timer]=pendingTimers.entries().next().value;pendingTimers.delete(id);await timer.fn();}};
}
test('繁体账号标题和入口保留士多名称',async()=>{
  for(const locale of ['zh-TW','zh-HK']){
    const t=setup({authorized:false,locale});
    const p=await t.page('account');
    assert.equal(p.data.pageTitle,'我的士多');
    assert.ok(Object.values(p.data.i18n).includes('我的士多'));
    assert.ok(!Object.values(p.data.i18n).includes('我計程車多'));
  }
});
test('不同意士多协议时不初始化授权也不调用 Connect',async()=>{
  const t=setup({consent:false});const ctx={api:t.api,setData:()=>{}};
  await t.handlers.get('login')(ctx);
  assert.equal(t.calls.length,0);assert.equal(t.confirmations[0].agreement.url,'https://ldcstore.com/docs/terms');
});
test('求购会话按实际协议读取，历史去重，发送防连点并由服务端决定资格',async()=>{
  let sends=0;
  const t=setup({timers:true,respond:r=>{
    if(r.url.pathname.endsWith('/conversations/my'))return {conversations:[{id:12,request:{id:7,title:'求购开发工具'},unreadCount:1,latestMessage:{content:'你好'},status:'negotiating'}],pagination:{hasMore:false}};
    if(r.url.pathname.endsWith('/buy-sessions/12'))return {session:{id:12,status:'negotiating',canSendMessage:true,role:'requester'},request:{id:7,title:'求购开发工具'},order:{orderNo:'chat-order'}};
    if(r.url.pathname.endsWith('/messages')){if(r.method==='POST'){sends++;return {message:{id:3,sessionId:12,content:r.body.content,senderRole:'requester'}};}return {messages:[{id:2,sessionId:12,content:'你好',createdAt:1000,senderRole:'provider'}],pagination:{hasMoreBefore:true,latestMessageId:2}};}
    return {};
  }});
  const list=await t.page('chats');assert.equal(list.data.rows[0].id,'12');await t.fire(list,'chatOpen',{id:'12'});assert.deepEqual({...t.nav[0].args},{id:'12',requestId:'7'});
  const p=await t.page('chat',{id:'12',requestId:'7'});assert.equal(p.data.canSend,true);assert.equal(p.data.chatRows.length,1);
  await t.fire(p,'chatOrder');assert.deepEqual({...t.nav.at(-1).args},{no:'chat-order'});
  await t.fire(p,'chatOlder');assert.equal(p.data.chatRows.length,1);assert.ok(t.calls.some(r=>r.url.searchParams.get('beforeId')==='2'));
  await t.fire(p,'chatInput',{value:'测试消息'});await Promise.all([t.fire(p,'chatSend'),t.fire(p,'chatSend')]);assert.equal(sends,1);assert.equal(p.data.chatDraft,'');assert.equal(p.data.chatRows.length,2);
  assert.ok([...t.pendingTimers.values()].some(timer=>timer.delay===15000));
  t.setAuthorized(false);await t.fire(p,'chatRefresh');
  assert.equal(p.data.canSend,false);assert.equal(p.data.chatRows.length,0);assert.equal(p.data.chatOrder,'');
  await t.fire(p,'chatOrder');assert.equal(t.nav.length,2);
  assert.ok(![...t.pendingTimers.values()].some(timer=>timer.delay===15000));
});
test('关闭会话不能发送，离页后的迟到响应不展示，发送超时不自动重试',async()=>{
  let closed=true,fail=false,sends=0;
  const t=setup({consent:false,respond:r=>{
    if(r.url.pathname.endsWith('/buy-sessions/12'))return {session:{id:12,status:closed?'closed':'negotiating',canSendMessage:!closed}};
    if(r.url.pathname.endsWith('/messages')){if(r.method==='POST'){sends++;if(fail)throw Error('offline');return {message:{id:2}};}return {messages:[],pagination:{}};}return {};
  }});
  const p=await t.page('chat',{id:'12',requestId:'7'});await t.fire(p,'chatInput',{value:'消息'});await t.fire(p,'chatSend');assert.equal(sends,0);
  closed=false;await t.fire(p,'chatRefresh');fail=true;await t.fire(p,'chatSend');await t.fire(p,'chatSend');assert.equal(sends,1);assert.equal(p.data.chatDraft,'消息');assert.equal(t.confirmations.length,1);
  let release;const pending=new Promise(r=>release=r),other=setup({respond:r=>r.url.pathname.endsWith('/buy-sessions/12')?pending:{messages:[],pagination:{}}});
  const opening=other.page('chat',{id:'12',requestId:'7'});await new Promise(r=>setImmediate(r));await other.handlers.get('page.hide')({surface:'1',page:'chat',params:{id:'12',requestId:'7'},api:other.api,setData:()=>{}});
  release({session:{id:12,status:'negotiating',canSendMessage:true}});const hidden=await opening;assert.notEqual(hidden.data.canSend,true);
});
test('售罄发卡商品读取补货状态，用户重复点击只订阅一次',async()=>{
  let subscribed=false;
  const t=setup({respond:r=>{
    if(r.url.pathname.endsWith('/restock-subscription')){if(r.method==='POST')subscribed=true;return {productId:'p1',subscribed,canSubscribe:true,outOfStock:true};}
    if(r.url.pathname.endsWith('/comments'))return {comments:[],commentEnabled:true};
    return {product:{id:'p1',product_type:'cdk',stock:0}};
  }});
  const p=await t.page('product',{id:'p1'});await new Promise(r=>setImmediate(r));assert.equal(p.data.restockAvailable,true);
  await t.fire(p,'subscribeRestock');await t.fire(p,'subscribeRestock');
  assert.equal(t.calls.filter(r=>r.method==='POST').length,1);assert.equal(p.data.restockSubscribed,true);
});
test('有库存及普通商品不订阅补货，未登录不发写请求',async()=>{
  for(const product of [{id:'p1',productType:'cdk',stock:2},{id:'p1',productType:'normal',stock:0}]){
    const t=setup({respond:r=>r.url.pathname.endsWith('/comments')?{comments:[]}:{product}}),p=await t.page('product',{id:'p1'});
    await t.fire(p,'subscribeRestock');assert.ok(!t.calls.some(r=>r.url.pathname.endsWith('/restock-subscription')));
  }
  const t=setup({authorized:false,respond:r=>r.url.pathname.endsWith('/comments')?{comments:[]}:{product:{id:'p1',productType:'cdk',stock:0}}}),p=await t.page('product',{id:'p1'});
  await t.fire(p,'subscribeRestock');assert.ok(!t.calls.some(r=>r.method==='POST'));
});
test('评论赞踩以服务端结果为准，同一票再次点击撤销，删除需要资格和确认',async()=>{
  const comment={id:'c1',status:'approved',content:'测试评论',canDelete:true,viewerVote:'',upvoteCount:0,downvoteCount:0};
  const t=setup({respond:r=>{
    if(r.url.pathname.endsWith('/vote'))return {viewerVote:r.body.voteType,upvoteCount:r.body.voteType==='up'?1:0,downvoteCount:0};
    if(r.url.pathname.endsWith('/comments'))return {comments:[comment],commentEnabled:true};
    return {product:{id:'p1',stock:2}};
  }});
  const p=await t.page('product',{id:'p1'});await new Promise(r=>setImmediate(r));
  await t.fire(p,'commentVote',{id:'c1',vote:'up'});assert.equal(p.data.comments[0].upvoteCount,1);
  await t.fire(p,'commentVote',{id:'c1',vote:'up'});assert.equal(p.data.comments[0].votedUp,false);
  await t.fire(p,'commentDelete',{id:'other'});assert.equal(t.confirmations.length,0);
  await t.fire(p,'commentDelete',{id:'c1'});assert.equal(t.calls.filter(r=>r.method==='DELETE').length,1);assert.equal(t.confirmations.length,1);
});
test('回复长度与资格校验，成功后不重复提交并在返回时更新评论',async()=>{
  const t=setup({respond:r=>r.method==='POST'?{reply:{id:'r1',content:r.body.content,status:'pending'}}:{}});
  const p=await t.page('comment',{mode:'reply',id:'c1',productId:'p1',author:'reader'});
  await t.fire(p,'postReply',{values:{content:'a'}});assert.equal(t.calls.length,0);
  await t.fire(p,'postReply',{values:{content:'这是测试回复'}});await t.fire(p,'postReply',{values:{content:'这是测试回复'}});
  assert.equal(t.calls.length,1);assert.equal(p.data.replySubmitted,true);assert.equal(p.data.replyResult,'审核中');
});
test('退出登录后迟到的回复与举报结果不能恢复旧账号内容',async()=>{
  for(const mode of ['reply','report']){
    let release;const hold=new Promise(r=>release=r);
    const t=setup({respond:r=>r.method==='POST'?hold:{}});
    const account=await t.page('account');
    const p=await t.page('comment',{mode,type:'product',id:'p1',productId:'p1',author:'reader'});
    const action=mode==='reply'?'postReply':'submitReport';
    const saving=t.fire(p,action,{values:mode==='reply'?{content:'迟到的测试回复'}:{category:'other',reason:'迟到的测试举报'}});
    while(!t.calls.some(r=>r.method==='POST'))await new Promise(r=>setImmediate(r));
    await t.fire(account,'signOut');
    release(mode==='reply'?{reply:{id:'r1'}}:{reportId:1,targetType:'product'});await saving;
    assert.equal(p.data.authorized,false);assert.equal(p.data.replySubmitted,false);assert.equal(p.data.reportSubmitted,false);
    assert.equal(Object.keys(p.data.reportReceipt).length,0);
  }
});
test('界面语言可切换，表单输入原样提交且不含内部文案标记',async()=>{
  const t=setup({locale:'en',respond:r=>r.method==='POST'?{reply:{id:'r1',content:r.body.content,status:'pending'}}:{}});
  const p=await t.page('comment',{mode:'reply',id:'c1',productId:'p1',author:'我的昵称'});
  assert.equal(p.data.communityFields[0].label,'Reply');assert.ok(p.data.communityTitle.includes('我的昵称'));
  const requests=t.calls.length;t.setLocale('zh-HK');await t.fire(p,'host.environmentChanged');
  assert.equal(p.data.communityFields[0].label,'回覆內容');assert.equal(t.calls.length,requests);
  await t.fire(p,'postReply',{values:{content:'用户原文保持不变'}});
  assert.equal(t.calls.at(-1).body.content,'用户原文保持不变');assert.ok(!JSON.stringify(t.calls.at(-1).body).includes('\uE000'));
});
test('四语原生社区页面由真实脚本生成完整显示状态',async()=>{
  const fixtures=[];
  const report={id:1,targetType:'product',productName:'测试商品',status:'awaiting_info',reportReason:'商品使用说明与实际情况不同，请核查。',reportCategory:'content_mismatch',createdAt:'2026-11-20T00:00:00Z'};
  for(const locale of ['zh','zh-TW','zh-HK','en']){
    const t=setup({locale,respond:r=>r.url.pathname.endsWith('/reports')?{reports:[report],stats:{open:1,awaitingInfo:1,closed:0},pagination:{hasMore:false}}:
      r.url.pathname.includes('/reports/')?{report,events:[{publicNote:'请补充使用时出现的问题。',createdAt:'2026-11-21T00:00:00Z'}],evidence:[]}:
      r.url.pathname.endsWith('/restock-subscription')?{productId:'p1',canSubscribe:true,subscribed:false}:
      r.url.pathname.endsWith('/comments')?{commentEnabled:true,comments:[{id:'c1',status:'approved',content:'使用中有一点疑问。',user:{username:'buyer'},upvoteCount:3,downvoteCount:0,canDelete:true}],pagination:{hasMore:false}}:
      {product:{id:'p1',name:'测试商品',productType:'cdk',stock:0,price:5}}});
    for(const [widget,page,params]of [['CommunityForm','comment',{mode:'report',type:'product',id:'p1',name:'测试商品'}],['ReplyForm','comment',{mode:'reply',id:'c1',author:'reader'}],['Reports','reports',{}],['ReportDetail','report',{type:'product',id:'1'}],['Product','product',{id:'p1'}]]){
      const p=await t.page(page,params);await flush();
      assert.equal(p.data.ready,true);assert.equal(p.data.error,'');
      const {i18n,...data}=p.data;fixtures.push({locale,widget,data});
    }
  }
  if(process.env.LD_STORE_UI_FIXTURES)writeFileSync(process.env.LD_STORE_UI_FIXTURES,JSON.stringify(fixtures,null,2)+'\n');
});
test('举报采用当前服务分类和提交令牌，网络失败不自动重放',async()=>{
  let failed=true,ids=0;
  const t=setup({respond:()=>{if(failed)throw Error('offline');return {reportId:8,targetType:'product'};}});t.api.crypto.uuid=async()=>String(++ids);
  const p=await t.page('comment',{mode:'report',type:'product',id:'p1',name:'商品'}),values={category:'delivery_issue',reason:'测试中的问题说明',orderNo:'O1'};
  await t.fire(p,'submitReport',{values});assert.equal(t.calls.length,1);assert.equal(p.data.reportSubmitted,false);
  failed=false;await t.fire(p,'submitReport',{values});assert.equal(t.calls[0].body.submissionToken,t.calls[1].body.submissionToken);
  assert.equal(t.calls[1].body.category,'delivery_issue');assert.equal(p.data.reportSubmitted,true);
  await t.fire(p,'reportDetail');assert.deepEqual(JSON.parse(JSON.stringify(t.nav.at(-1))),{page:'report',args:{id:'8',type:'product'}});
});
test('举报分页保留对象类型，详情校验归属并展示处理记录',async()=>{
  const report={id:1,targetType:'comment',productId:'p1',status:'awaiting_info',reportReason:'测试反馈',reportCategoryLabel:'事实争议'};
  const t=setup({respond:r=>r.url.pathname.endsWith('/reports')?{reports:[report],stats:{open:1,awaitingInfo:1},pagination:{hasMore:false}}:{report,events:[{publicNote:'请补充发生时间',createdAt:'2026-11-20T00:00:00Z'}],evidence:[]}});
  const p=await t.page('reports');assert.equal(p.data.rows[0].id,'comment:1');
  await t.fire(p,'reportDetail',{id:'comment:1'});assert.equal(t.nav.at(-1).args.type,'comment');
  const detail=await t.page('report',{type:'comment',id:'1'});assert.equal(detail.data.events[0].message,'请补充发生时间');
  const wrong=await t.page('report',{type:'product',id:'1'});assert.match(wrong.data.error,/不符/);
});
test('未登录举报与回复页不请求，举报分类不能跨对象提交',async()=>{
  const t=setup({authorized:false});for(const page of ['reports','report','comment'])await t.page(page,{type:'product',id:'1'});
  assert.equal(t.calls.length,0);
  const other=setup(),p=await other.page('comment',{mode:'report',type:'comment',id:'c1'});
  await other.fire(p,'submitReport',{values:{category:'delivery_issue',reason:'不应通过的分类'}});assert.equal(other.calls.length,0);
});
test('商品列表保留折扣、原价和已售，非折扣商品不伪造优惠',async()=>{
  const t=setup({respond:r=>r.url.pathname.endsWith('/categories')?{categories:[]}:{products:[
    {id:'p1',name:'折扣商品',price:20,discount:0.75,sold_count:12,stock:8},
    {id:'p2',name:'原价商品',price:6,sold_count:0,stock:-1}],pagination:{total:2}}});
  const p=await t.page('market');
  assert.equal(p.data.rows[0].discount,'25% 优惠');assert.equal(p.data.rows[0].sold,'已售 12');
  assert.equal(p.data.rows[0].originalLabel,'原价 20.00');assert.equal(p.data.rows[0].value,'15.00');
  assert.equal(p.data.rows[1].discount,'');assert.equal(p.data.rows[1].sold,'已售 0');
});
test('服务卡片取数有明确加载状态，刷新失败保留上次统计',async()=>{
  let resolve,failed=false;
  const hold=new Promise(r=>resolve=r);
  const t=setup({respond:async r=>{await hold;if(failed)throw Error('offline');return r.url.pathname.endsWith('/attention')?{pendingPaymentCount:3,awaitingDeliveryCount:2,unusedCouponCount:4}:{totalUnread:5};}});
  const data={},ctx={surface:'card',params:{},api:t.api,setData:(k,v)=>data[k]=v};
  const loading=t.handlers.get('card.load')(ctx);
  await flush();
  assert.equal(data.overviewLoading,true);assert.equal(data.stats,undefined);
  resolve();await loading;
  assert.equal(data.overviewLoading,false);assert.equal(data.stats[0].value,'3');
  failed=true;await t.handlers.get('card.refresh')(ctx);
  assert.equal(data.overviewLoading,false);assert.equal(data.stats[0].value,'3');assert.ok(data.overviewError);
});
test('Connect 取消后不访问回调、不交换令牌',async()=>{
  const t=setup({respond:()=>({state:'s',auth_url:'https://connect.linux.do/oauth2/authorize?redirect_uri=https%3A%2F%2Fapi.ldspro.qzz.io%2Fapi%2Fauth%2Fcallback&state=s'})});
  const data={};await t.handlers.get('login')({api:t.api,setData:(k,v)=>data[k]=v});
  assert.equal(t.calls.length,1);assert.equal(t.calls[0].url.pathname,'/api/auth/init');assert.equal(data.loginError,'');
});
test('收藏分页去重，搜索重置页码',async()=>{
  const t=setup({respond:r=>({products:[{id:r.url.searchParams.get('page')==='1'?'p1':'p2',name:'商品',stock:-1,price:2}],pagination:{totalPages:2}})});
  const p=await t.page('favorites');assert.equal(p.data.rows.length,1);assert.equal(p.data.rows[0].stock,'库存 不限');
  await t.fire(p,'buyerMore');assert.equal(p.data.rows.length,2);assert.equal(p.data.more,false);
  await t.fire(p,'favoriteSearch',{value:'测试'});await t.fire(p,'buyerRefresh');
  assert.equal(t.calls.at(-1).url.searchParams.get('search'),'测试');assert.equal(t.calls.at(-1).url.searchParams.get('page'),'1');
});
test('未登录收藏与优惠券页不会发出带凭证请求',async()=>{
  const t=setup({authorized:false});for(const name of ['favorites','coupons','refund','comment']){
    const p=await t.page(name);assert.equal(p.data.needsSession,true);
  }assert.equal(t.calls.length,0);
});
test('收藏增删采用 POST 和 DELETE，成功后才切换状态',async()=>{
  const t=setup({respond:r=>r.url.pathname.endsWith('/favorite')?null:r.url.pathname.endsWith('/comments')?{comments:[],pagination:{},commentEnabled:true}:{product:{id:'p1',name:'商品',stock:2,price:3,isFavorited:false}}});
  const p=await t.page('product',{id:'p1'});await t.fire(p,'favorite');assert.equal(p.data.favoriteLabel,'已收藏');
  await t.fire(p,'favorite');assert.equal(p.data.favoriteLabel,'收藏商品');
  assert.deepEqual(t.calls.filter(r=>r.url.pathname.endsWith('/favorite')).map(r=>r.method),['POST','DELETE']);
});
test('收藏动作并发只提交一次',async()=>{
  let resolve;const hold=new Promise(r=>resolve=r);
  const t=setup({respond:r=>r.url.pathname.endsWith('/favorite')?hold:r.url.pathname.endsWith('/comments')?{comments:[],pagination:{}}:{product:{id:'p1',stock:3}}});
  const p=await t.page('product',{id:'p1'}),one=t.fire(p,'favorite'),two=t.fire(p,'favorite');
  resolve(null);await Promise.all([one,two]);assert.equal(t.calls.filter(r=>r.method==='POST').length,1);
});
test('评论仅已购且未评分时提供评分，正文长度在提交前校验',async()=>{
  const t=setup({respond:r=>r.method==='GET'?{commentEnabled:true,viewerHasPurchased:true,viewerRating:{hasRated:false}}:{comment:{id:'c'},message:'等待审核'}});
  const p=await t.page('comment',{id:'p1'});assert.equal(p.data.fields.length,2);
  await t.fire(p,'postComment',{values:{content:'太短'}});assert.equal(t.calls.length,1);
  await t.fire(p,'postComment',{values:{content:'这里是有效的评论内容',rating:'5'}});
  assert.equal(t.calls.at(-1).body.rating,5);assert.equal(p.data.commentSubmitted,true);assert.equal(p.data.commentResult,'等待审核');
});
for(const fields of [{viewerHasPurchased:false},{viewerHasPurchased:true,viewerRating:{hasRated:true}}]){
 test('不符合评分条件时忽略构造的评分字段 '+JSON.stringify(fields),async()=>{
  const t=setup({respond:r=>r.method==='GET'?{commentEnabled:true,...fields}:{comment:{id:'c'}}});
  const p=await t.page('comment',{id:'p1'});assert.equal(p.data.fields.length,1);
  await t.fire(p,'postComment',{values:{content:'有效的评论内容',rating:'5'}});assert.equal(t.calls.at(-1).body.rating,undefined);
 });
}
test('关闭评论和提交失败不会显示成功',async()=>{
  const t=setup({respond:()=>({commentEnabled:false})});const p=await t.page('comment',{id:'p1'});
  await t.fire(p,'postComment',{values:{content:'有效的评论内容'}});assert.equal(t.calls.length,1);assert.equal(p.data.commentSubmitted,false);
});
test('优惠券公开读取，领取成功关联到我的券',async()=>{
  const t=setup({respond:r=>r.method==='POST'?{claim:{id:'cl1',status:'available'},campaign,alreadyClaimed:false}:campaign});
  const p=await t.page('coupon',{token:'fixture'});await t.fire(p,'claimCoupon');
  assert.equal(p.data.claimed,true);assert.equal(p.data.canClaim,false);assert.equal(t.calls.at(-1).credential,'account');
  await t.fire(p,'claimCoupon');assert.equal(t.calls.filter(r=>r.method==='POST').length,1);
});
test('已领取或暂停券不发起重复领取',async()=>{
  const t=setup({respond:()=>({...campaign,claimable:false,claimed:false,state:'paused'})});const p=await t.page('coupon',{token:'fixture'});
  await t.fire(p,'claimCoupon');assert.equal(t.calls.length,1);assert.equal(p.data.claimLabel,'卖家暂停领取');
});
test('优惠券列表切换分类与占用订单导航',async()=>{
  const t=setup({respond:()=>({items:[{claimId:'cl',claimStatus:'reserved',reservedOrderNo:'O1',campaign}],pagination:{totalPages:1}})});
  const p=await t.page('coupons');await t.fire(p,'couponUse',{id:'cl'});assert.deepEqual(t.nav[0].page,'order');assert.equal(t.nav[0].args.no,'O1');
  await t.fire(p,'couponTab',{value:'used'});assert.equal(t.calls.at(-1).url.searchParams.get('status'),'used');
});
test('店铺券导航按官网商户身份参数读取商品',async()=>{
  const t=setup({respond:r=>r.url.pathname.includes('/merchants/')?{merchant:{username:'seller'},products:[],pagination:{hasMore:false}}:{items:[{claimId:'cl',campaign:{...campaign,scopeType:'store',sellerSite:'linux.do',sellerUserId:8}}],pagination:{}}});
  const p=await t.page('coupons');await t.fire(p,'couponUse',{id:'cl'});const target=t.nav[0];assert.equal(target.page,'merchant');
  await t.page(target.page,target.args);assert.equal(t.calls.at(-1).url.pathname,'/api/shop/merchants/seller');assert.equal(t.calls.at(-1).url.searchParams.get('userId'),'8');
});
const eligible={role:'buyer',eligibility:{canApply:true,code:null,message:'可申请退款'},refund:null,disputeGuideUrl:'https://ldcstore.com/docs/refunds'};
const form={values:{reasonCode:'other',reasonDetail:'测试中的完整问题描述，不提交到真实服务',buyerContactedSeller:false}};
test('退款遵循服务端资格，未联系卖家也可按网站规则申请',async()=>{
  let submitted=false;
  const t=setup({respond:r=>{if(r.method==='POST')submitted=true;return submitted?{...eligible,eligibility:{...eligible.eligibility,canApply:false},refund:{orderNo:'O1',status:'requested',refundAmount:5,events:[]}}:eligible;}});
  const p=await t.page('refund',{no:'O1'});await t.fire(p,'applyRefund',form);
  assert.equal(t.calls.filter(r=>r.method==='POST').length,1);assert.equal(t.calls.find(r=>r.method==='POST').body.buyerContactedSeller,false);
  assert.equal(p.data.refundState,'等待卖家处理');assert.equal(p.data.canApply,false);
});
test('取消退款确认不产生写请求',async()=>{
  const t=setup({consent:false,respond:()=>eligible});const p=await t.page('refund',{no:'O1'});await t.fire(p,'applyRefund',form);
  assert.equal(t.calls.length,1);assert.equal(t.confirmations.length,1);
});
test('退款返回不确定时只查单，不重放写请求',async()=>{
  const t=setup({respond:r=>{if(r.method==='POST')throw Error('连接中断');return eligible;}});
  const p=await t.page('refund',{no:'O1'});await t.fire(p,'applyRefund',form);
  assert.equal(t.calls.filter(r=>r.method==='POST').length,1);assert.equal(t.calls.length,3);assert.match(p.data.buyerError,/核对最新售后状态/);
});
test('服务端禁止退款或订单号不符时不能申请',async()=>{
  const t=setup({respond:()=>({...eligible,eligibility:{canApply:false,message:'不在申请期限'},refund:{orderNo:'wrong',status:'requested',refundAmount:3,events:[]}})});
  const p=await t.page('refund',{no:'O1'});await t.fire(p,'applyRefund',form);assert.equal(t.calls.length,1);assert.match(p.data.error,/订单号/);
});
test('退款原因和描述校验阻止无效提交',async()=>{
  const t=setup({respond:()=>eligible});const p=await t.page('refund',{no:'O1'});await t.fire(p,'applyRefund',{values:{reasonCode:'forged',reasonDetail:'不足'}});
  assert.equal(t.calls.length,1);assert.equal(t.confirmations.length,0);
});
test('分页错误保留已有内容，手动重试同页',async()=>{
  let fail=true;
  const t=setup({respond:r=>{if(r.url.searchParams.get('page')==='2'&&fail)return {failure:503,message:'暂不可用'};return {products:[{id:r.url.searchParams.get('page'),name:'商品'}],pagination:{totalPages:2}};}});
  const p=await t.page('favorites');await t.fire(p,'buyerMore');assert.equal(p.data.rows.length,1);assert.match(p.data.error,/暂不可用/);
  fail=false;await t.fire(p,'buyerRetry');assert.equal(p.data.rows.length,2);assert.equal(t.calls.at(-1).url.searchParams.get('page'),'2');
});
test('401 清除当前页面私人列表，提示重新登录',async()=>{
  const t=setup({respond:()=>({failure:401})});const p=await t.page('coupons');assert.equal(p.data.rows.length,0);assert.equal(p.data.needsSession,true);assert.equal(p.data.authorized,false);
});

test('拒绝登录权限给出可重试提示，不初始化服务授权',async()=>{
 const t=setup();t.api.permissions.status=async()=>({identity:false,serviceAccount:false});t.api.permissions.request=async()=>false;
 const p=await t.page('account');t.calls.length=0;await t.fire(p,'login');
 assert.equal(t.calls.length,0);assert.equal(t.confirmations.length,0);assert.match(p.data.loginError,/未允许登录所需权限/);
});
test('支付权限拒绝后不读取支付链接或调用收银台',async()=>{
 const t=setup({respond:()=>({order:{orderNo:'O1',status:'pending',amount:5}})});
 const p=await t.page('order',{no:'O1'});t.api.permissions.status=async()=>({identity:true,serviceAccount:true,payments:false});t.api.permissions.request=async()=>false;
 await t.fire(p,'payOrder');assert.equal(t.calls.length,1);assert.match(p.data.paymentNote,/未允许支付权限/);
});
test('商品详情兼容混合字段，折扣异常退回原价，类型和购买限制正确',async()=>{
 let product={id:'p1',name:'工具',price:'10',discount:0,stock:2,product_type:'cdk',seller_username:'seller',is_test_mode:'false'};
 const t=setup({respond:r=>r.url.pathname.endsWith('/comments')?{comments:[],pagination:{}}:{product}});
 let p=await t.page('product',{id:'p1'});assert.equal(p.data.value,'10.00');assert.equal(p.data.seller,'卖家：seller');assert.equal(p.data.buy,true);
 product={...product,is_test_mode:'true'};p=await t.page('product',{id:'p1'});assert.equal(p.data.buy,false);assert.match(p.data.buyLabel,/测试/);
 product={...product,is_test_mode:false,seller_user_id:42};p=await t.page('product',{id:'p1'});assert.equal(p.data.buy,false);assert.match(p.data.buyLabel,/自己的商品/);
 product={...product,seller_site:'other.example'};p=await t.page('product',{id:'p1'});assert.equal(p.data.buy,true);
 product={...product,product_type:'store',stock:0};p=await t.page('product',{id:'p1'});assert.equal(p.data.linkProduct,true);assert.equal(p.data.buy,true);
});
const storeClaims=(overrides={})=>({sub:'42',site:'linux.do',trust_level:3,exp:Math.floor(Date.now()/1000)+3600,...overrides});
function trustShop({claims=storeClaims(),profile={authenticated:true,user:{id:42,site:'linux.do'}},product={}}={}) {
  return setup({claims,respond:r=>{
    if(r.url.pathname.endsWith('/auth/verify'))return profile;
    if(r.url.pathname.endsWith('/quote'))return {productId:'p1',quantity:1,productSubtotal:5,payableAmount:5,coupons:[]};
    if(r.url.pathname.endsWith('/products/p1'))return {product:{id:'p1',price:5,stock:2,purchase_trust_level:1,...product}};
    return {};
  }});
}
test('校验接口只返回身份时使用士多凭证等级，L3 可兑换最低 L1 商品并进入核价',async()=>{
  for(const level of [0,1,2,3,4,'3'])for(const required of [1,3,4]) {
    const t=trustShop({claims:storeClaims({trust_level:level}),product:{purchase_trust_level:required}});
    // 论坛等级和士多会话可能不同，购买资格不从宿主论坛资料推断。
    t.api.user.get=async()=>({id:42,username:'tester',trustLevel:4});
    const product=await t.page('product',{id:'p1'}),allowed=Number(level)>=required;
    assert.equal(product.data.buy,allowed,`TL${level} / 最低 TL${required}`);
    await t.fire(product,'review');assert.equal(t.nav.length,allowed?1:0);
    const review=await t.page('review',{id:'p1'});
    assert.equal(review.data.canSubmit,allowed);
    assert.equal(t.calls.filter(r=>r.url.pathname.endsWith('/quote')).length,allowed?1:0);
    assert.ok(t.calls.every(r=>r.method==='GET'||r.url.pathname.endsWith('/quote')));
  }
});
test('服务端明确返回的等级优先且保留真实 L0，账号页与购买页判断一致',async()=>{
  for(const level of [0,'0',1,'3']) {
    const t=trustShop({profile:{authenticated:true,user:{id:'42',trust_level:level}}});
    const account=await t.page('account');assert.match(account.data.accountMeta,new RegExp('TL'+level+'$'));
    const product=await t.page('product',{id:'p1'});assert.equal(product.data.buy,Number(level)>=1);
  }
  const t=trustShop({claims:null,profile:{authenticated:true,user:{id:42,trustLevel:3}}});
  assert.equal((await t.page('product',{id:'p1'})).data.buy,true);
});
test('未知或不属于当前有效会话的等级不能伪装成 L0 或放行核价',async()=>{
  const candidates=[null,...[null,'',' ',true,[],{},-1,5,3.5,'3x'].map(trust_level=>storeClaims({trust_level})),
    storeClaims({sub:'99'}),storeClaims({site:'idcflare.com'}),storeClaims({exp:1}),storeClaims({exp:null}),
    storeClaims({nbf:Math.floor(Date.now()/1000)+3600})];
  for(const claims of candidates) {
    const t=trustShop({claims}),p=await t.page('review',{id:'p1'});
    assert.equal(p.data.buy,false);assert.equal(p.data.canSubmit,false);
    assert.match(p.data.buyLabel,/暂时无法核对购买资格/);
    assert.equal(t.calls.some(r=>r.url.pathname.endsWith('/quote')),false);
  }
});
test('身份校验失败或服务故障时不使用凭证声明放行购买',async()=>{
  for(const profile of [{authenticated:false,user:{id:42}},{authenticated:true,user:{id:99}},
    {authenticated:true,user:{id:42,site:'idcflare.com'}},{failure:401},{failure:503}]) {
    const t=trustShop({profile}),p=await t.page('review',{id:'p1'});
    assert.equal(p.data.buy,false);assert.equal(p.data.canSubmit,false);
    assert.equal(t.calls.some(r=>r.url.pathname.endsWith('/quote')),false);
    if(profile.failure!==503)assert.equal(p.data.authorized,false);
  }
});
test('等级读取失败不能覆盖售罄、测试商品或自己的商品等确定原因',async()=>{
  for(const [product,label]of [[{stock:0},/已售罄/],[{isTestMode:true},/测试中/],[{sellerUserId:42},/自己的商品/]]) {
    const t=trustShop({claims:null,product}),p=await t.page('product',{id:'p1'});
    assert.equal(p.data.buy,false);assert.match(p.data.buyLabel,label);
  }
});
test('详情使用权威可用库存和已购限额，CDK 不限库存不误报售罄',async()=>{
 let product={id:'p1',price:5,product_type:'cdk',cdk_stats:{total:-1},stock:0};
 const t=setup({respond:r=>r.url.pathname.endsWith('/comments')?{comments:[],pagination:{}}:{product}});
 let p=await t.page('product',{id:'p1'});assert.equal(p.data.buy,true);assert.equal(p.data.metrics[0].value,'不限');
 product={...product,available_stock:0};p=await t.page('product',{id:'p1'});assert.equal(p.data.buy,false);
 product={...product,available_stock:10,purchase_limit:{mode:'per_user',quantity:2,remaining_quantity:0}};
 p=await t.page('product',{id:'p1'});assert.equal(p.data.buy,false);
});
test('筛选弹层取消保留原条件，确认后才刷新源页面',async()=>{
 const t=setup({respond:r=>r.url.pathname.endsWith('/categories')?{categories:[]}:{products:[],pagination:{}}});
 const p=await t.page('market');const f=await t.page('filters',{source:p.ctx.surface});
 await t.fire(f,'input',{field:'min',value:'5'});await t.fire(f,'surface.close');await t.fire(p,'page.resume');
 assert.equal(t.calls.filter(r=>r.url.pathname.endsWith('/products')).length,1);
 const next=await t.page('filters',{source:p.ctx.surface});await t.fire(next,'input',{field:'min',value:'5'});await t.fire(next,'input',{field:'max',value:'3'});
 await t.fire(next,'applyFilters');assert.equal(t.nav.length,0);assert.match(next.data.filterError,/有效/);
 await t.fire(next,'input',{field:'max',value:'8'});await t.fire(next,'applyFilters');assert.equal(t.nav.at(-1).dismiss,true);
 await t.fire(p,'page.resume');const query=t.calls.filter(request=>request.url.pathname.endsWith('/products')).at(-1).url.searchParams;assert.equal(query.get('priceMin'),'5');assert.equal(query.get('priceMax'),'8');
});
test('搜索防抖合并请求，显式提交和隐藏不遗留重复定时器',async()=>{
 const t=setup({timers:true,respond:r=>r.url.pathname.endsWith('/categories')?{categories:[]}:{products:[],pagination:{}}});
 const p=await t.page('market');await t.fire(p,'input',{field:'search',value:'a'});await t.fire(p,'input',{field:'search',value:'ab'});
 assert.equal(t.pendingTimers.size,1);await t.fire(p,'apply');assert.equal(t.pendingTimers.size,0);assert.equal(t.calls.at(-1).url.searchParams.get('search'),'ab');
 await t.fire(p,'input',{field:'search',value:'abc'});await t.fire(p,'page.hide');assert.equal(t.pendingTimers.size,0);
 await t.fire(p,'page.resume');assert.equal(t.calls.filter(request=>request.url.pathname.endsWith('/products')).at(-1).url.searchParams.get('search'),'abc');
});
test('订单明细包括优惠和时间线，交付内容默认隐藏且离开后收起',async()=>{
 const t=setup({respond:()=>({order:{order_no:'O1',status:'delivered',quantity:2,amount:8,product_subtotal:10,original_price:12,
  coupon_snapshot:'{"name":"测试券","coupon_discount_amount":2}',cdk:['code-1','code-2'],product:{id:'p1',name:'商品',description:'**使用说明**'},paid_at:'2026-11-01T01:00:00Z',ldc_trade_no:'T1'},logs:[{action:'deliver',created_at:'2026-11-01T02:00:00Z'}]})});
 const p=await t.page('order',{no:'O1'});assert.equal(p.data.deliveryText,'');assert.equal(p.data.hasDelivery,true);
 assert.equal(p.data.fields.find(f=>f.label==='优惠金额').value,'− 2.00 LDC');assert.equal(p.data.orderEvents[0].title,'发货完成');
 assert.equal(p.data.tradeNo,'T1');assert.equal(p.data.usage,'**使用说明**');await t.fire(p,'delivery');assert.equal(p.data.deliveryText,'code-1\ncode-2');
 await t.fire(p,'page.hide');assert.equal(p.data.deliveryText,'');await t.fire(p,'page.resume');assert.equal(t.calls.filter(r=>r.url.pathname.includes('/orders/')).length,1);
 await t.fire(p,'repurchase');assert.equal(t.nav.at(-1).args.id,'p1');
});
test('支付未明确时禁再次付款和取消，可见订单才轮询且完成后停止',async()=>{
 let status='pending',failure=0;
 const t=setup({timers:true,respond:()=>failure?{failure}:{order:{orderNo:'O1',status,paymentInitStatus:'unknown',amount:3}}});
 const p=await t.page('order',{no:'O1'});assert.equal(p.data.canPay,false);assert.equal(p.data.canCancel,false);assert.equal(t.pendingTimers.size,1);
 await t.fire(p,'page.hide');assert.equal(t.pendingTimers.size,0);await t.fire(p,'page.resume');assert.equal(t.pendingTimers.size,1);
 failure=503;await t.tick();assert.equal(t.pendingTimers.size,1);assert.equal(p.data.ready,true);
 failure=0;status='delivered';await t.tick();assert.equal(t.pendingTimers.size,0);assert.equal(p.data.error,'');
});
test('系统消息支持分页筛选，只在点击后标记已读，并跳转原生订单',async()=>{
 const t=setup({respond:r=>r.method==='POST'?{}:{messages:[{id:'m1',title:'已发货',content:'请查收',is_read:false,link:'/order/O1'}],pagination:{totalPages:1},summary:{totalUnread:1}}});
 const p=await t.page('messages');assert.equal(p.data.rows[0].read,false);assert.equal(t.calls.every(r=>r.method==='GET'),true);
 await t.fire(p,'messageOpen',{id:'m1'});assert.equal(t.nav.at(-1).page,'order');assert.equal(t.nav.at(-1).args.no,'O1');
 await t.fire(p,'messageRead',{id:'m1'});assert.equal(p.data.rows[0].read,true);assert.equal(t.calls.at(-1).url.pathname,'/api/shop/messages/system/m1/read');
 await t.fire(p,'messageTab',{value:'unread'});assert.equal(t.calls.at(-1).url.searchParams.get('readStatus'),'unread');
});
test('全部消息已读需确认，取消不会写入',async()=>{
 const t=setup({consent:false,respond:()=>({messages:[],pagination:{},summary:{}})});const p=await t.page('messages');await t.fire(p,'messagesReadAll');assert.equal(t.calls.length,1);
});

const messageResult={messages:[{id:'m1',title:'订单已发货',content:'请查看订单',isRead:false}],pagination:{totalPages:2},summary:{totalUnread:1}};
const flush=()=>new Promise(resolve=>setImmediate(resolve));
test('消息页共用一条订阅，隐藏交接，关闭取消，不写已读',async()=>{
  const t=setup({streams:true,respond:()=>messageResult});
  const a=await t.page('messages');await flush();
  const b=await t.page('messages');await flush();
  assert.equal(t.streamCalls.filter(c=>c.open).length,1);
  await t.fire(a,'page.hide');await flush();
  assert.equal(t.streamCalls.filter(c=>c.open).length,2);
  await t.fire(b,'surface.close');await flush();
  assert.equal(t.streamCalls.filter(c=>c.close).length,2);
  assert.equal(t.calls.filter(c=>c.method!=='GET').length,0);
});
test('未登录不订阅；401 停止兜底，恢复页面不重试失效会话',async()=>{
  const guest=setup({streams:true,authorized:false});await guest.page('messages');await flush();assert.equal(guest.streamCalls.length,0);
  const t=setup({streams:true,timers:true,respond:()=>messageResult}),p=await t.page('messages');await flush();
  await t.fire(p,'stream.state',{id:'notifications',state:'closed',status:401});
  assert.equal(p.data.needsSession,true);assert.equal(t.pendingTimers.size,0);
  await t.fire(p,'page.hide');await t.fire(p,'page.resume');await flush();
  assert.equal(t.streamCalls.filter(c=>c.open).length,1);
});
test('SSE 首页面静默同步保留内容，翻页后只提示更新',async()=>{
  let release,hold=false;const waiting=new Promise(r=>release=r);
  const t=setup({streams:true,respond:r=>hold?waiting:{...messageResult,messages:[{...messageResult.messages[0],id:r.url.searchParams.get('page')==='2'?'m2':'m1'}]}});
  const p=await t.page('messages');await flush();
  hold=true;
  const updating=t.fire(p,'stream.event',{id:'notifications',event:'system-message.changed',data:'{}'});
  await flush();assert.equal(p.data.rows.length,1);assert.equal(p.data.loading,false);
  release(messageResult);await updating;await flush();hold=false;
  await t.fire(p,'messagesMore');const count=t.calls.length;
  await t.fire(p,'stream.event',{id:'notifications',event:'system-message.changed',data:'{}'});
  assert.equal(t.calls.length,count);assert.equal(p.data.rows.length,2);assert.equal(p.data.messagesChanged,true);
});
test('连接恢复补查摘要，失效连接和未知事件不能覆盖消息',async()=>{
  const t=setup({streams:true,timers:true,respond:r=>r.url.pathname.endsWith('unread-summary')?{totalUnread:3,systemUnread:2}:messageResult});
  const p=await t.page('messages');await flush();
  await t.fire(p,'stream.state',{id:'notifications',state:'retrying'});assert.equal(t.pendingTimers.size,1);
  await t.fire(p,'stream.state',{id:'notifications',state:'open'});assert.equal(t.pendingTimers.size,0);
  assert.ok(t.calls.some(c=>c.url.pathname.endsWith('unread-summary')));
  const before=t.calls.length;
  await t.fire(p,'stream.event',{id:'notifications',event:'payment.success',data:'{}'});
  assert.equal(t.calls.length,before);
  await t.fire(p,'page.hide');
  await t.fire(p,'stream.event',{id:'notifications',event:'summary.updated',data:'{"systemUnread":99}'});
  assert.equal(t.calls.length,before);
});

test('服务端连接数限制按业务提示冷却，页面切换不会提前重连',async()=>{
 const t=setup({streams:true,timers:true,respond:()=>messageResult}),p=await t.page('messages');await flush();
 await t.fire(p,'stream.event',{id:'notifications',event:'stream.closed',data:'{"reason":"connection_limit","retryAfterMs":90000}'});
 assert.equal(t.streamCalls.filter(c=>c.close).length,1);
 assert.equal([...t.pendingTimers.values()][0].delay,90000);
 await t.fire(p,'page.hide');await t.fire(p,'page.resume');await flush();
 assert.equal(t.streamCalls.filter(c=>c.open).length,1);
 await t.tick();await flush();assert.equal(t.streamCalls.filter(c=>c.open).length,2);
});

test('消息初次加载与连接事件交错时不误报，真实事件到达后合并补查',async()=>{
 let release,reads=0;const waiting=new Promise(r=>release=r);
 const t=setup({streams:true,respond:r=>r.url.pathname.endsWith('unread-summary')?{systemUnread:1}:
   ++reads===1 ? waiting : {...messageResult,messages:[{...messageResult.messages[0],id:'new'}]}});
 const data={},writes=[],ctx={surface:'first',page:'messages',params:{},api:t.api,setData:(k,v)=>{data[k]=v;writes.push([k,v]);}};
 const opening=t.handlers.get('page.open')(ctx);await flush();
 await t.handlers.get('stream.state')(ctx,{id:'notifications',state:'open'});
 await t.handlers.get('stream.event')(ctx,{id:'notifications',event:'system-message.changed',data:'{}'});
 assert.notEqual(data.messagesChanged,true);
 release(messageResult);await opening;
 assert.equal(reads,2);assert.equal(data.rows[0].id,'new');assert.equal(data.messagesChanged,false);
 assert.equal(writes.some(([k,v])=>k==='loading' && v===true),true);
});
test('消息翻页后重连先比较快照，无变化不提示，有变化不清空列表',async()=>{
 let changed=false;
 const t=setup({streams:true,respond:r=>r.url.pathname.endsWith('unread-summary')?{systemUnread:1}:
  {...messageResult,messages:[{...messageResult.messages[0],id:r.url.searchParams.get('page')==='2'?'m2':changed?'new':'m1'}]}});
 const p=await t.page('messages');await flush();await t.fire(p,'messagesMore');
 await t.fire(p,'stream.state',{id:'notifications',state:'open'});
 assert.equal(p.data.rows.length,2);assert.equal(p.data.messagesChanged,false);
 changed=true;await t.fire(p,'stream.state',{id:'notifications',state:'open'});
 assert.equal(p.data.rows.length,2);assert.equal(p.data.messagesChanged,true);
 await t.fire(p,'messagesRefresh');assert.equal(p.data.rows[0].id,'new');assert.equal(p.data.messagesChanged,false);
});
test('消息刷新保留已有条目，失败保留原内容，切换筛选不会混用',async()=>{
 let hold=false,release;const waiting=new Promise(r=>release=r);
 const t=setup({respond:()=>hold?waiting:messageResult});const p=await t.page('messages');
 hold=true;const refresh=t.fire(p,'messagesRefresh');await flush();
 assert.equal(p.data.rows[0].id,'m1');assert.equal(p.data.loading,true);
 release({failure:503,message:'暂不可用'});await refresh;
 assert.equal(p.data.rows[0].id,'m1');assert.equal(p.data.loading,false);
 const filter=t.fire(p,'messageTab',{value:'read'});await flush();assert.equal(p.data.rows.length,0);await filter;
});
test('详情报价等待只影响券与金额区域，已有商品保持可见',async()=>{
 let release;const waiting=new Promise(r=>release=r);
 const t=setup({respond:r=>r.url.pathname.endsWith('/quote')?waiting:{product:{id:'p1',name:'商品',price:5,stock:3}}});
 const data={},ctx={surface:'review',page:'review',params:{id:'p1'},api:t.api,setData:(k,v)=>data[k]=v};
 const opening=t.handlers.get('page.open')(ctx);await flush();
 assert.equal(data.ready,true);assert.equal(data.initialLoading,false);assert.equal(data.quoteInitialLoading,true);
 release({productId:'p1',quantity:1,payableAmount:5,productSubtotal:5,coupons:[]});await opening;
 assert.equal(data.payable,'5.00 LDC');assert.equal(data.quoteInitialLoading,false);
});
test('支付成功仅核对当前订单并更新已有订单行，返回商品与商城不重新加载',async()=>{
 let paid=false;const product={id:'p1',name:'商品',price:5,stock:8};
 const order=()=>({orderNo:'O1',productId:'p1',product,status:paid?'delivered':'pending',amount:5});
 const t=setup({respond:r=>{
  const path=r.url.pathname;
  if(path.endsWith('/auth/verify'))return {authenticated:true,user:{id:42}};
  if(path.endsWith('/categories'))return {categories:[]};
  if(path.endsWith('/products'))return {products:[product],pagination:{}};
  if(path.endsWith('/comments'))return {comments:[],pagination:{}};
  if(path.endsWith('/products/p1'))return {product};
  if(path.endsWith('/orders'))return {orders:[order()],pagination:{totalPages:1}};
  if(path.endsWith('/payment-url'))return {paymentUrl:'https://credit.linux.do/pay/test'};
  return {order:order()};
 }});
 t.api.payments={request:async()=>{paid=true;return {status:'success'};}};
 const market=await t.page('market'),productPage=await t.page('product',{id:'p1'}),orders=await t.page('orders'),detail=await t.page('order',{no:'O1'});
 await flush();const before=t.calls.length;await t.fire(detail,'payOrder');
 assert.equal(detail.data.state,'已交付');assert.equal(detail.data.ready,true);assert.equal(orders.data.rows[0].state,'已交付');
 assert.ok(t.calls.slice(before).every(r=>r.url.pathname.startsWith('/api/shop/orders/O1')));
 const after=t.calls.length;await t.fire(productPage,'page.resume');await t.fire(market,'page.resume');await t.fire(orders,'page.resume');
 assert.equal(t.calls.length,after);
});
test('我的士多读取服务账号头像模板，经公开图片代理加载，匿名时不查账号',async()=>{
 const t=setup({respond:r=>r.url.pathname.endsWith('/auth/verify')?{authenticated:true,user:{id:42,name:'展示名',avatar_template:'/user_avatar/linux.do/tester/{size}/123.png'}}:{}});
 const p=await t.page('account');assert.equal(p.data.accountName,'展示名');
 assert.match(p.data.accountAvatar,/^https:\/\/api2.ldspro.qzz.io\/api\/shop\/avatar-proxy\?url=/);
 assert.match(decodeURIComponent(p.data.accountAvatar),/\/128\/123.png$/);
 const guest=setup({authorized:false,respond:()=>({})}),g=await guest.page('account');
 assert.equal(g.data.accountAvatar,'');assert.equal(guest.calls.some(r=>r.url.pathname.endsWith('/auth/verify')),false);
});
test('刷新报价和详情保留原券与金额，等待期间不允许使用旧报价提交',async()=>{
 let hold=false,release;const waiting=new Promise(r=>release=r);
 const quote={productId:'p1',quantity:1,payableAmount:5,productSubtotal:5,coupons:[]};
 const t=setup({respond:r=>r.url.pathname.endsWith('/quote')?(hold?waiting:quote):{product:{id:'p1',price:5,stock:3}}});
 const p=await t.page('review',{id:'p1'});hold=true;
 const refreshing=t.fire(p,'retry');await flush();
 assert.equal(p.data.payable,'5.00 LDC');assert.equal(p.data.quoteReady,true);
 assert.equal(p.data.quoteInitialLoading,false);assert.equal(p.data.canSubmit,false);
 assert.equal(p.data.initialLoading,false);
 release(quote);await refreshing;assert.equal(p.data.canSubmit,true);
});
test('取消收银台不刷新交付，不让其他页面失效',async()=>{
 const t=setup({respond:r=>r.url.pathname.endsWith('/payment-url')?{paymentUrl:'https://credit.linux.do/pay/test'}:{order:{orderNo:'O1',status:'pending',amount:5}}});
 t.api.payments={request:async()=>({state:'cancelled'})};
 const p=await t.page('order',{no:'O1'});await t.fire(p,'payOrder');
 assert.equal(t.calls.filter(r=>r.method==='POST').length,0);
 assert.equal(t.calls.length,3);assert.equal(p.data.state,'待付款');
});
test('统计刷新保留已读数据，失效会话清除头像和私人消息',async()=>{
 let fail=false;
 const t=setup({respond:r=>fail?{failure:401}:r.url.pathname.endsWith('/auth/verify')?{authenticated:true,user:{id:42,avatar:'https://example.org/avatar.png'}}:r.url.pathname.endsWith('/attention')?{pendingPaymentCount:3}:r.url.pathname.endsWith('/messages/system')?messageResult:{}});
 const p=await t.page('account'),messages=await t.page('messages');
 assert.equal(p.data.accountAvatar,'https://example.org/avatar.png');
 const refreshing=t.fire(p,'overviewRefresh');assert.equal(p.data.overviewInitialLoading,false);await refreshing;
 fail=true;await t.fire(p,'overviewRefresh');await t.fire(messages,'messagesRefresh');
 assert.equal(p.data.accountAvatar,'');assert.equal(p.data.stats.length,0);
 assert.equal(messages.data.rows.length,0);assert.equal(messages.data.more,false);
});
test('订单手动刷新保留交付区域并收起敏感内容',async()=>{
 let hold=false,release;const waiting=new Promise(r=>release=r);
 const order={orderNo:'O1',status:'delivered',amount:5,deliveryContent:'fixture-only'};
 const t=setup({respond:()=>hold?waiting:{order}}),p=await t.page('order',{no:'O1'});
 await t.fire(p,'delivery');assert.equal(p.data.deliveryText,'fixture-only');hold=true;
 const refreshing=t.fire(p,'ordersRefresh');await flush();assert.equal(p.data.hasDelivery,true);assert.equal(p.data.deliveryText,'');
 release({order});await refreshing;assert.equal(p.data.hasDelivery,true);assert.equal(p.data.deliveryText,'');
});
const restoredClaims=storeClaims({username:'tester',avatar_template:'/user_avatar/linux.do/tester/{size}/321.png'});
test('恢复已有会话从凭证声明取得头像，商城与我的士多共用资料并保留商品',async()=>{
 const t=setup({claims:restoredClaims,respond:r=>r.url.pathname.endsWith('/auth/verify')?{authenticated:true,user:{id:42}}:{products:[],pagination:{},categories:[]}});
 const p=await t.page('market');await flush();
 assert.equal(p.data.authorized,true);assert.match(decodeURIComponent(p.data.accountAvatar),/128\/321.png$/);
 await t.fire(p,'account');assert.equal(t.nav.at(-1).page,'account');
 const a=await t.page('account');assert.equal(a.data.accountAvatar,p.data.accountAvatar);
 assert.equal(t.calls.filter(r=>r.url.pathname.endsWith('/auth/verify')).length,1);
 await t.fire(a,'signOut');assert.equal(p.data.authorized,false);assert.equal(p.data.accountAvatar,'');
 const count=t.calls.filter(r=>r.url.pathname.endsWith('/products')).length;
 await t.fire(p,'page.resume');await t.fire(p,'page.resume');
 const requests=t.calls.filter(r=>r.url.pathname.endsWith('/products'));assert.equal(requests.length,count+1);assert.equal(requests.at(-1).credential,undefined);
});
test('游客商城不请求头像，仍可点击进入我的士多',async()=>{
 const t=setup({authorized:false,respond:()=>({products:[],pagination:{},categories:[]})});
 const p=await t.page('market');await flush();await t.fire(p,'account');
 assert.equal(p.data.authorized,false);assert.equal(p.data.accountAvatar,'');
 assert.equal(t.calls.some(r=>r.url.pathname.endsWith('/auth/verify')),false);assert.equal(t.nav.at(-1).page,'account');
});
test('商城已打开时完成登录立即显示头像，退出后的迟到验证不能恢复头像',async()=>{
 let held=false,release;
 const t=setup({authorized:false,claims:restoredClaims,respond:r=>r.url.pathname.endsWith('/auth/init')?
  {state:'s',auth_url:'https://connect.linux.do/oauth2/authorize?redirect_uri=https%3A%2F%2Fapi.ldspro.qzz.io%2Fapi%2Fauth%2Fcallback&state=s'}:
  r.url.pathname.endsWith('/auth/verify') ? held ? new Promise(resolve=>release=resolve) : {authenticated:true,user:{id:42}} : {products:[],categories:[],pagination:{}}});
 const p=await t.page('market');await flush();
 t.api.connect.authorize=async()=> 'https://ldcstore.com/auth/callback#ldsp_oauth='+Buffer.from(JSON.stringify({s:'s',exp:1,c:'x'.repeat(43)})).toString('base64url');
 t.api.credentials.capture=async()=>{t.setAuthorized(true);return {claims:{...restoredClaims,exp:Math.floor(Date.now()/1000)+3600}};};
 const a=await t.page('account');await t.fire(a,'login');
 assert.equal(p.data.authorized,true);assert.ok(p.data.accountAvatar);
 held=true;const refresh=t.fire(a,'overviewRefresh');await flush();assert.ok(release);
 await t.fire(a,'signOut');release({authenticated:true,user:{id:42}});await refresh;
 assert.equal(p.data.accountAvatar,'');assert.equal(a.data.accountAvatar,'');assert.equal(p.data.authorized,false);
});
test('凭证声明属于其他账号时不展示其中头像',async()=>{
 const t=setup({claims:{...restoredClaims,sub:'99'},respond:r=>r.url.pathname.endsWith('/auth/verify')?{authenticated:true,user:{id:42}}:{}});
 const p=await t.page('account');assert.equal(p.data.accountAvatar,'');
});
test('订单缺图按商品合并查询，已有图片不查询，详情复用补图结果',async()=>{
 const orders=[{order_no:'O1',product_id:'p1',status:'delivered'},{order_no:'O2',product_id:'p1',status:'expired'},
  {order_no:'O3',product_id:'p2',status:'expired',product_image_url:'//images.example.org/p2.png'}];
 const t=setup({respond:r=>r.url.pathname.endsWith('/products/p1')?{product:{id:'p1',image_url:'https://images.example.org/p1.png'}}:
  r.url.pathname.endsWith('/orders/O1')?{order:orders[0]}:{orders,pagination:{totalPages:1}}});
 const p=await t.page('orders');await flush();
 assert.equal(t.calls.filter(r=>r.url.pathname.includes('/products/')).length,1);
 assert.equal(p.data.rows[0].image,'https://images.example.org/p1.png');assert.equal(p.data.rows[1].image,p.data.rows[0].image);
 assert.equal(p.data.rows[2].image,'https://images.example.org/p2.png');
 const detail=await t.page('order',{no:'O1'});assert.equal(detail.data.orderImage,p.data.rows[0].image);
 assert.equal(t.calls.filter(r=>r.url.pathname.includes('/products/')).length,1);
});
test('订单补图最多三个并发，隐藏后不继续发起查询，过期结果不覆盖新筛选',async()=>{
 const pending=[];let active=0,maximum=0;
 const t=setup({respond:r=>{
  if(r.url.pathname.includes('/products/')){active++;maximum=Math.max(maximum,active);return new Promise(resolve=>pending.push(()=>{active--;resolve({product:{id:r.url.pathname.split('/').at(-1),image_url:'https://images.example.org/product.png'}});}));}
  return {orders:r.url.searchParams.get('status')?[]:Array.from({length:7},(_,i)=>({orderNo:'O'+i,productId:'p'+i,status:'expired'})),pagination:{}};
 }});
 const p=await t.page('orders');await flush();assert.equal(p.data.rows.length,7);assert.equal(active,3);assert.equal(p.data.rows[0].imageLoading,true);
 await t.fire(p,'page.hide');pending.splice(0).forEach(fn=>fn());await flush();assert.equal(t.calls.filter(r=>r.url.pathname.includes('/products/')).length,3);
 await t.fire(p,'page.resume');await flush();assert.equal(active,3);
 await t.fire(p,'ordersFilter',{status:'pending',name:'待付款'});pending.splice(0).forEach(fn=>fn());await flush();
 assert.equal(maximum,3);assert.equal(p.data.rows.length,0);
});
test('商品没有图片或已下架时订单仍可用，重复订单不反复请求',async()=>{
 const t=setup({respond:r=>r.url.pathname.includes('/products/')?{failure:404}:{orders:[{orderNo:'O1',productId:'p1',status:'expired'}],pagination:{}}});
 const p=await t.page('orders');await flush();assert.equal(p.data.rows[0].image,'');assert.equal(p.data.rows[0].imageLoading,false);assert.equal(p.data.error,'');
 await t.fire(p,'ordersRefresh');await flush();assert.equal(t.calls.filter(r=>r.url.pathname.includes('/products/')).length,1);
});
test('按官网登录状态查询分类与商品，默认推荐与显式价格排序互斥',async()=>{
  const slate='6770186e-0eb7-48cb-8296-af6ef9db812b';const shop=setup({respond:request=>request.url.pathname.endsWith('/categories') ? {categories:[{id:2,name:'公益站'}]} : {products:[{...storefront.product,pin_type:'category',pin_is_paid:1,is_pinned:1,duoPromotion:{kind:'paid'}}],pagination:{hasMore:false},rankingContext:{slateId:slate}}});
  shop.api.crypto.uuid=async()=>'656e7fb5-a452-4825-a014-244374d55e8c';
  const market=await shop.page('market');
  for(const request of shop.calls.filter(request=>/\/(categories|products)$/.test(request.url.pathname)))assert.equal(request.credential,'account');
  const query=()=>shop.calls.filter(request=>request.url.pathname.endsWith('/products')).at(-1).url.searchParams;
  assert.equal(query().get('ranking'),'auto');assert.equal(query().has('sortBy'),false);
  const row=market.data.rows[0];assert.equal(row.image,storefront.product.image_url);assert.equal(row.sellerAvatar,'https://cdn.example/seller.png');assert.equal(row.value,'1.00');
  assert.equal(row.listingNote,'广告 · 士多优选');assert.ok(query().get('rotationId'));assert.equal(query().has('previousSlateId'),false);
  await shop.fire(market,'refresh');assert.equal(query().get('previousSlateId'),slate);
  await shop.fire(market,'select',{sort:'final_price',direction:'ASC',label:'低价'});assert.equal(query().get('sortBy'),'final_price');assert.equal(query().has('ranking'),false);
  assert.equal(query().has('previousSlateId'),false);assert.equal(query().has('rotationId'),false);
});
test('公开列表 401 仅匿名重试一次，私人收藏不做匿名回退',async()=>{
  const shop=setup({respond:request=>request.credential ? {failure:401} : {categories:[],products:[storefront.product],pagination:{}}});
  const market=await shop.page('market');assert.equal(market.data.rows.length,1);
  assert.deepEqual(shop.calls.filter(request=>request.url.pathname.endsWith('/products')).map(request=>request.credential),['account',undefined]);
  const favorites=await shop.page('favorites');assert.equal(favorites.data.needsSession,true);
  assert.deepEqual(shop.calls.filter(request=>request.url.pathname.endsWith('/favorites')).map(request=>request.credential),['account']);
});
test('商家资料来自独立响应，即使没有公开商品仍显示头像、信任等级和真实的零',async()=>{
  const shop=setup({authorized:false,respond:()=>({...storefront.merchant,products:[],stats:{...storefront.merchant.stats,onlineCount:0}})});
  const merchant=await shop.page('merchant',{username:'seller'});
  assert.equal(merchant.data.merchantTitle,'店主');assert.equal(merchant.data.merchantAvatar,'https://cdn.example/seller.png');assert.equal(merchant.data.merchantMeta,'@seller · TL3');
  assert.deepEqual(Array.from(merchant.data.merchantStats,stat=>stat.value),['0','1','269']);assert.equal(merchant.data.more,false);
});
test('评论使用嵌套作者资料、购买标识、评分摘要及毫秒时间，回复按需分页',async()=>{
  const sample=storefront.comments,comment={...sample.comments[0],nickname:'旧名称',avatar_url:null,reply_count:2};
  const shop=setup({authorized:false,respond:request=>request.url.pathname.endsWith('/replies') ? {replies:[{id:request.url.searchParams.get('page'),user:{username:'seller',avatar_template:'/user_avatar/linux.do/seller/{size}/1.png'},is_seller:true,content:'回复',created_at:'1794155801'}],pagination:{hasMore:request.url.searchParams.get('page')==='1'}} : request.url.pathname.endsWith('/comments') ? {...sample,comments:[comment]} : {product:storefront.product}});
  const product=await shop.page('product',{id:storefront.product.id});await flush();let row=product.data.comments[0];
  assert.equal(row.author,'买家');assert.equal(row.handle,'@buyer');assert.equal(row.avatar,'https://cdn.example/buyer.png');assert.equal(row.badge,'已购');assert.equal(row.rating,'4 / 5');assert.equal(row.time,new Date(1794155801631).toISOString());
  assert.equal(product.data.commentStats[0].value,'4.0 / 5');assert.equal(product.data.commentStats[2].value,'4');assert.equal(shop.calls.some(request=>request.url.pathname.endsWith('/replies')),false);
  await shop.fire(product,'commentReplies',{id:row.id});row=product.data.comments[0];assert.equal(row.repliesMore,true);
  assert.match(decodeURIComponent(row.replies[0].avatar),/\/128\/1.png/);assert.equal(row.replies[0].time,new Date(1794155801000).toISOString());
  await shop.fire(product,'commentReplies',{id:row.id,more:true});row=product.data.comments[0];assert.equal(row.replies[1].badge,'卖家');assert.equal(row.replies.length,2);assert.equal(row.repliesMore,false);
});
test('优惠券数量保留零，过期与已用但无订单的券不能跳到商品',async()=>{
  const shop=setup({respond:request=>request.url.pathname.includes('/my-coupons') ? {items:[{claim_id:1,claim_status:'used',actual_discount_amount:0,campaign}],pagination:{totalPages:1}} : {...campaign,remaining_quantity:0,total_quantity:30,state:'expired',claimed:true,claim:{status:'available'}}});
  const coupon=await shop.page('coupon',{token:'valid'});assert.equal(coupon.data.coupon.quantity,'0 / 30');assert.equal(coupon.data.coupon.action,'');await shop.fire(coupon,'couponUse');
  const wallet=await shop.page('coupons');await shop.fire(wallet,'couponTab',{value:'used'});assert.equal(wallet.data.rows[0].actualDiscount,'0.00 LDC');await shop.fire(wallet,'couponUse',{id:'1'});assert.equal(shop.nav.length,0);
});
test('确认订单读取下划线报价并解释不可用券，不让不可用券参与核价',async()=>{
  const shop=setup({respond:request=>request.url.pathname.endsWith('/quote') ? {product_id:'p1',quantity:1,payable_amount:5,product_subtotal:5,coupons:[{claim_id:'X',eligible:false,reason:'尚未达到最低消费',campaign:{name:'满减券'}}]} : {product:{id:'p1',price:5,stock:2}}});
  const review=await shop.page('review',{id:'p1'});assert.equal(review.data.quoteReady,true);assert.equal(review.data.unavailableCoupons[0].reason,'尚未达到最低消费');await shop.fire(review,'quoteCoupon',{id:'X'});assert.equal(review.data.noCoupon,true);assert.equal(review.data.payable,'5.00 LDC');
});
test('售后保留卖家回复并按实际时间排序；失效会话不能再看到旧的处理记录',async()=>{
  const shop=setup({respond:()=>({...eligible,eligibility:{canApply:false,message:'已处理'},refund:{order_no:'O1',status:'rejected',seller_response:'请核对交付记录',reason_code:'not_as_described',refund_amount:'7',events:[{action:'rejected',actor_type:'seller',actor_name:'seller',created_at:'1794155801'},{action:'requested',actor_type:'buyer',created_at:1794145801000}]}})});
  const refund=await shop.page('refund',{no:'O1'});assert.equal(refund.data.refundDetails.find(row=>row.label==='卖家说明').value,'请核对交付记录');assert.match(refund.data.events[0].time,/卖家 · @seller/);assert.equal(refund.data.events[0].title,'卖家拒绝申请');
  shop.setAuthorized(false);await shop.fire(refund,'buyerRefresh');assert.equal(refund.data.events.length,0);assert.equal(refund.data.refundDetails.length,0);assert.equal(refund.data.hasGuide,false);
});
test('账户直接使用待办中的订单，消费明细只在用户展开时读，退出后清空',async()=>{
  const shop=setup({respond:request=>request.url.pathname.endsWith('/attention') ? {recent_orders:[{order_no:'O1',status:'paid',product_name:'测试商品',amount:0}]} : request.url.pathname.endsWith('/dashboard') ? {overview:{total_purchase_orders:2,total_spent:'10'},spending_distribution:{categories:[{category_name:'工具',amount:10}],totals:{amount:10}}} : request.url.pathname.endsWith('/auth/verify') ? {authenticated:true,user:{id:42,trust_level:0}} : {}});
  const account=await shop.page('account');assert.equal(account.data.accountMeta,'@tester · TL0');assert.equal(account.data.recentOrders[0].no,'O1');assert.match(account.data.recentOrders[0].subtitle,/0.00 LDC/);
  assert.equal(shop.calls.some(request=>request.url.pathname.endsWith('/dashboard')),false);await shop.fire(account,'spending');assert.equal(account.data.spendingRows[0].value,'10.00 LDC · 100%');await shop.fire(account,'signOut');assert.equal(account.data.spendingRows.length,0);assert.equal(account.data.hasRecentOrders,false);
});
test('收藏和已隐藏商品分页搜索隔离，切换后忽略旧页，恢复仅限用户选中的隐藏记录',async()=>{
  let restored=false;const shop=setup({respond:request=>{if(request.method==='DELETE'){restored=true;return null;}return {products:request.url.pathname.endsWith('/blocked-products') && !restored ? [{...storefront.product,status:'offline_manual'}] : [],pagination:{hasMore:false}};}});
  const favorites=await shop.page('favorites');await shop.fire(favorites,'favoriteSearch',{value:'收藏关键词'});await shop.fire(favorites,'collectionTab',{id:'blocked'});
  const row=favorites.data.rows[0];assert.equal(row.hiddenItem,true);assert.equal(row.availability,'已下架');assert.equal(favorites.data.search,'');assert.equal(favorites.data.rows[0].image,storefront.product.image_url);
  await shop.fire(favorites,'restoreProduct',{id:'unknown'});assert.equal(restored,false);await shop.fire(favorites,'restoreProduct',{id:row.id});assert.equal(restored,true);assert.equal(favorites.data.rows.length,0);
  await shop.fire(favorites,'collectionTab',{id:'favorites'});assert.equal(favorites.data.search,'收藏关键词');
});
test('消息的秒时间戳转为原生可读时间，页面类型和重试页码独立于已有行数',async()=>{
  let fail=false;const shop=setup({respond:()=>fail ? {failure:503} : {messages:[{id:'m1',message_type:'buyer_order_delivered',created_at:1794155801}],summary:{totalUnread:0},pagination:{hasMore:false}}});
  const messages=await shop.page('messages');assert.equal(messages.data.rows[0].type,'商品发货提醒');assert.equal(messages.data.rows[0].time,new Date(1794155801000).toISOString());fail=true;await shop.fire(messages,'messagesRefresh');fail=false;await shop.fire(messages,'messagesRetry');assert.equal(shop.calls.at(-1).url.searchParams.get('page'),'1');assert.equal(messages.data.error,'');
});
test('商品摘要没有封面不阻止订单补图；缺图摘要也不抹去已取得的封面',async()=>{
  const product={id:'p1',name:'商品'},cover='/covers/商品.png';
  const shop=setup({respond:r=>r.url.pathname.endsWith('/products/p1') ? {product:{...product,image_url:cover}} : r.url.pathname.endsWith('/orders') ? {orders:[{order_no:'O1',product_id:'p1',status:'expired'}],pagination:{}} : {products:[product],categories:[],pagination:{}}});
  const market=await shop.page('market');assert.equal(market.data.rows[0].image,'');
  const orders=await shop.page('orders');await flush();assert.equal(orders.data.rows[0].image,'https://ldcstore.com'+cover);
  await shop.fire(market,'refresh');assert.equal(market.data.rows[0].image,orders.data.rows[0].image);
  assert.equal(shop.calls.filter(r=>r.url.pathname.endsWith('/products/p1')).length,1);
});
test('领券凭证过期后可匿名查看，重新授权前不允许领取',async()=>{
  const shop=setup({respond:r=>r.credential ? {failure:401} : campaign});const page=await shop.page('coupon',{token:'fixture'});
  assert.equal(page.data.ready,true);assert.equal(page.data.authorized,false);assert.equal(page.data.canClaim,false);
  await shop.fire(page,'claimCoupon');assert.equal(shop.calls.length,2);assert.equal(shop.calls.every(r=>r.method==='GET'),true);
});
test('评论和订单翻页失败只重试失败的页码，原有行保留',async()=>{
  for(const [name,resource,more,retry] of [['orders','orders','ordersMore','ordersRetry'],['product','comments','commentsMore','commentsRetry']]){
    let fail=true;const shop=setup({respond:r=>{
      if(!r.url.pathname.endsWith('/'+resource))return {product:{id:'p1',price:2,stock:1}};
      const n=r.url.searchParams.get('page');if(n==='2' && fail)return {failure:503};
      return {[resource]:[name==='orders' ? {order_no:'O'+n,status:'paid'} : {id:'C'+n,content:'评论'}],pagination:{hasMore:n==='1'}};
    }});
    const page=await shop.page(name,{id:'p1'});await flush();await shop.fire(page,more);
    const rows=()=>name==='orders' ? page.data.rows : page.data.comments;
    assert.equal(rows().length,1);fail=false;await shop.fire(page,retry);assert.equal(rows().length,2);
    assert.deepEqual(shop.calls.filter(r=>r.url.pathname.endsWith('/'+resource)).map(r=>r.url.searchParams.get('page')),['1','2','2']);
  }
});
test('按订单快照区分原单价、折后单价与券后应付，退出立刻收起私有内容',async()=>{
  const shop=setup({respond:r=>r.url.pathname.endsWith('/orders/O1') ? {order:{order_no:'O1',product_quantity:2,product:{price:10,discount:0.5},original_price:20,product_subtotal:10,coupon_discount_amount:2,amount:8,buyer_nickname:'买家',buyer_username:'tester',seller_name:'Seller',seller_username:'seller',status:'delivered',delivery_content:'模拟交付'}} : {}});
  const order=await shop.page('order',{no:'O1'});const values=Object.fromEntries(order.data.fields.map(row=>[row.label,row.value]));
  assert.deepEqual([values['商品单价'],values['折后单价'],values['商品小计'],values['应付积分']],['10.00 LDC','5.00 LDC','10.00 LDC','8.00 LDC']);
  assert.equal(values['买家'],'买家 · @tester');assert.equal(values['卖家'],'@seller');
  await shop.fire(order,'delivery');assert.equal(order.data.deliveryText,'模拟交付');
  const account=await shop.page('account');await shop.fire(account,'signOut');assert.equal(order.data.deliveryText,'');assert.equal(order.data.fields.length,0);assert.equal(order.data.orderNo,'');
});

test('定时消息首次建基线不通知，重复任务去重，新消息更新角标',async()=>{
  let messages=[{id:1,createdAt:'2025-01-01T00:00:00Z'}],checks=0;const shown=[],badges=[],storage=new Map();
  const t=setup({respond:r=>{checks++;return r.url.pathname.endsWith('unread-summary')?{totalUnread:messages.length}:{messages};}});
  t.api.storage={get:async key=>storage.get(key)??null,compareAndSet:async(key,expected,value)=>{if(JSON.stringify(storage.get(key)??null)!==JSON.stringify(expected))return false;storage.set(key,value);return true;}};
  t.api.navigation.setBadge=async(page,count)=>badges.push({page,count});t.api.notifications={isAllowed:async()=>true,show:async options=>shown.push(options)};
  const ctx={surface:'task',kind:'task',api:t.api};await t.handlers.get('task.run')(ctx,{id:'messages'});assert.equal(shown.length,0);
  messages=[{id:2,createdAt:'2025-01-01T00:01:00Z'},...messages];await t.handlers.get('task.run')(ctx,{id:'messages'});
  assert.equal(shown.length,1);assert.equal(shown[0].page,'messages');assert.equal(badges.at(-1).count,2);
  await t.handlers.get('task.run')(ctx,{id:'messages'});assert.equal(shown.length,1);
  t.setAuthorized(false);await t.handlers.get('task.run')(ctx,{id:'messages'});assert.equal(checks,6);assert.equal(badges.at(-1).count,0);
});
test('私密证据使用宿主句柄与固定操作号，失败不自动上传，预览使用凭证',async()=>{
  const report={id:1,targetType:'product',status:'awaiting_info'},uploads=[],previews=[],released=[];let fail=true;
  const t=setup({respond:()=>({report,evidence:[{id:8}],events:[]})});
  t.api.files={pick:async()=>({handle:'handle',name:'proof.png',size:128,mimeType:'image/png'}),release:async id=>released.push(id),preview:async request=>previews.push(request),upload:async options=>{uploads.push(options);return {ok:!fail,json:()=>({success:!fail})};}};
  const p=await t.page('report',{type:'product',id:'1'});await t.fire(p,'evidenceOpen',{id:'not-owned'});assert.equal(previews.length,0);
  await t.fire(p,'evidenceOpen',{id:'8'});assert.equal(previews[0].credential,'account');
  await t.fire(p,'evidencePick');assert.equal(p.data.attachmentReady,true);await t.fire(p,'evidenceUpload');assert.equal(uploads.length,1);assert.ok(p.data.evidenceError);
  await t.fire(p,'evidencePreview');await t.fire(p,'page.hide');assert.equal(p.data.attachmentReady,true);await t.fire(p,'page.resume');
  fail=false;await t.fire(p,'evidenceUpload');assert.equal(uploads[0].fields.operationId,uploads[1].fields.operationId);assert.equal(uploads[1].encoding,'base64');assert.equal(uploads[1].field,'data');assert.deepEqual(released,['handle']);
  report.status='resolved';await t.fire(p,'buyerRefresh');await t.fire(p,'evidencePick');assert.equal(p.data.canAddEvidence,false);
});

test('宿主收回证据句柄后停止上传操作，失效句柄不再次提交',async()=>{
  let uploads=0;const t=setup({respond:()=>({report:{id:1,status:'awaiting_info'},evidence:[],events:[]})});
  t.api.files={pick:async()=>({handle:'a',name:'proof.png',mimeType:'image/png'}),upload:async()=>{uploads++;},release:async()=>{}};
  const p=await t.page('report',{type:'product',id:'1'});await t.fire(p,'evidencePick');await t.fire(p,'files.invalidated');
  assert.equal(p.data.attachmentReady,false);await t.fire(p,'evidenceUpload');assert.equal(uploads,0);
});
