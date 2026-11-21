import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const script=readFileSync(new URL('../../fixtures/metaverse/ld-store/main.js',import.meta.url),'utf8');
const campaign={id:'c1',name:'测试券',discountType:'fixed_amount',fixedAmount:2,minSpend:5,scopeType:'product',productId:'p1',sellerUsername:'seller',claimable:true};
function setup({authorized=true,consent=true,respond=()=>({}),timers=false,streams=false}={}) {
  const handlers=new Map(),calls=[],nav=[],confirmations=[];
  const pendingTimers=new Map(),streamCalls=[];let timerId=0;
  const api={
    on:(name,handler)=>handlers.set(name,handler),
    user:{get:async()=>({id:42,username:'tester'})},
    credentials:{status:async()=>({authorized}),remove:async()=>{},capture:async()=>{throw Error('unexpected capture');}},
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
  return {api,handlers,calls,nav,confirmations,page,fire,pendingTimers,streamCalls,async tick(){const [id,timer]=pendingTimers.entries().next().value;pendingTimers.delete(id);await timer.fn();}};
}
test('不同意士多协议时不初始化授权也不调用 Connect',async()=>{
  const t=setup({consent:false});const ctx={api:t.api,setData:()=>{}};
  await t.handlers.get('login')(ctx);
  assert.equal(t.calls.length,0);assert.equal(t.confirmations[0].agreement.url,'https://ldcstore.com/docs/terms');
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
 await t.fire(p,'page.resume');assert.equal(t.calls.at(-1).url.searchParams.get('priceMin'),'5');assert.equal(t.calls.at(-1).url.searchParams.get('priceMax'),'8');
});
test('搜索防抖合并请求，显式提交和隐藏不遗留重复定时器',async()=>{
 const t=setup({timers:true,respond:r=>r.url.pathname.endsWith('/categories')?{categories:[]}:{products:[],pagination:{}}});
 const p=await t.page('market');await t.fire(p,'input',{field:'search',value:'a'});await t.fire(p,'input',{field:'search',value:'ab'});
 assert.equal(t.pendingTimers.size,1);await t.fire(p,'apply');assert.equal(t.pendingTimers.size,0);assert.equal(t.calls.at(-1).url.searchParams.get('search'),'ab');
 await t.fire(p,'input',{field:'search',value:'abc'});await t.fire(p,'page.hide');assert.equal(t.pendingTimers.size,0);
 await t.fire(p,'page.resume');assert.equal(t.calls.at(-1).url.searchParams.get('search'),'abc');
});
test('订单明细包括优惠和时间线，交付内容默认隐藏且离开后收起',async()=>{
 const t=setup({respond:()=>({order:{order_no:'O1',status:'delivered',quantity:2,amount:8,product_subtotal:10,original_price:12,
  coupon_snapshot:'{"name":"测试券","coupon_discount_amount":2}',cdk:['code-1','code-2'],product:{id:'p1',name:'商品',description:'**使用说明**'},paid_at:'2026-11-01T01:00:00Z',ldc_trade_no:'T1'},logs:[{action:'deliver',created_at:'2026-11-01T02:00:00Z'}]})});
 const p=await t.page('order',{no:'O1'});assert.equal(p.data.deliveryText,'');assert.equal(p.data.hasDelivery,true);
 assert.equal(p.data.fields.find(f=>f.label==='优惠金额').value,'− 2.00 LDC');assert.equal(p.data.orderEvents[0].title,'发货完成');
 assert.equal(p.data.tradeNo,'T1');assert.equal(p.data.usage,'**使用说明**');await t.fire(p,'delivery');assert.equal(p.data.deliveryText,'code-1\ncode-2');
 await t.fire(p,'page.hide');assert.equal(p.data.deliveryText,'');await t.fire(p,'page.resume');assert.equal(t.calls.length,1);
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
 const filter=t.fire(p,'messageTab',{value:'read'});assert.equal(p.data.rows.length,0);await filter;
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
 const refreshing=t.fire(p,'ordersRefresh');assert.equal(p.data.hasDelivery,true);assert.equal(p.data.deliveryText,'');
 release({order});await refreshing;assert.equal(p.data.hasDelivery,true);assert.equal(p.data.deliveryText,'');
});
