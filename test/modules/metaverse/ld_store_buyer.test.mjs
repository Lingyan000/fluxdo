import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const script=readFileSync(new URL('../../fixtures/metaverse/ld-store/main.js',import.meta.url),'utf8');
const campaign={id:'c1',name:'测试券',discountType:'fixed_amount',fixedAmount:2,minSpend:5,scopeType:'product',productId:'p1',sellerUsername:'seller',claimable:true};
function setup({authorized=true,consent=true,respond=()=>({})}={}) {
  const handlers=new Map(),calls=[],nav=[],confirmations=[];
  const api={
    on:(name,handler)=>handlers.set(name,handler),
    user:{get:async()=>({id:42,username:'tester'})},
    credentials:{status:async()=>({authorized}),remove:async()=>{},capture:async()=>{throw Error('unexpected capture');}},
    crypto:{pkce:async()=>({verifier:'v',challenge:'c',method:'S256'}),uuid:async()=> 'uuid'},
    storage:{get:async()=>null},
    dialogs:{confirm:async options=>{confirmations.push(options);return consent;}},
    connect:{authorize:async()=>null},
    navigate:async(page,args)=>nav.push({page,args}),
    toast:async()=>{},
    fetch:async(url,options={})=>{
      const request={url:new URL(url),method:options.method||'GET',...options};calls.push(request);
      const result=await respond(request);
      return {ok:!(result?.failure),status:result?.failure||200,json:()=>result?.failure ? {success:false,error:result.message} : {success:true,data:result}};
    },
  };
  vm.runInNewContext(script,{fluxdo:api,console:{warn:()=>{},log:()=>{}}});
  let sequence=0;
  async function page(name,params={}) {
    const data={},ctx={surface:String(++sequence),page:name,params,api,setData:(key,value)=>data[key]=value};
    await handlers.get('page.open')(ctx);return {ctx,data};
  }
  const fire=(p,name,args={})=>handlers.get(name)(p.ctx,args);
  return {api,handlers,calls,nav,confirmations,page,fire};
}
test('不同意士多协议时不初始化授权也不调用 Connect',async()=>{
  const t=setup({consent:false});const ctx={api:t.api,setData:()=>{}};
  await t.handlers.get('login')(ctx);
  assert.equal(t.calls.length,0);assert.equal(t.confirmations[0].agreement.url,'https://ldcstore.com/docs/terms');
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
