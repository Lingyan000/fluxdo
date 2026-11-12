// 每个页面独立保存筛选和分页，晚到的请求不能覆盖新筛选的结果。
const api = 'https://api2.ldspro.qzz.io/api/shop';
const views = new Map();
const money = n => Number.isFinite(Number(n)) ? Number(n).toFixed(2) + ' LDC' : '—';
const display = v => v == null ? '' : String(v);
function stockValue(p) {
  const candidates = [p.availableStock,p.available_stock,p.cdkStats && p.cdkStats.available,p.stock];
  const n = Number(candidates.find(v => v != null && v !== ''));
  return n === -1 || Number.isSafeInteger(n) && n >= 0 ? n : null;
}
function stockLabel(p) {
  const n = stockValue(p);
  return n === -1 ? '不限' : n === null ? '未提供' : String(n);
}
function purchaseBounds(p, link) {
  const stock = stockValue(p), rule = p.purchaseLimit || p.purchase_limit || {};
  const shared = (p.productType || p.product_type) === 'cdk' && (p.sharedCdkEnabled === true || Number(p.shared_cdk_enabled) === 1);
  const cap = shared ? 1 : Number(rule.quantity ?? p.maxPurchaseQuantity ?? p.max_purchase_quantity);
  const mode = shared ? 'per_user' : rule.mode || p.purchaseLimitType || p.purchase_limit_type || (cap > 0 ? 'per_order' : 'none');
  const rest = rule.remainingQuantity ?? rule.remaining_quantity;
  const remaining = rest != null && rest !== '' && Number.isSafeInteger(Number(rest)) && Number(rest) >= 0 ? Number(rest) : null;
  const limited = Number.isSafeInteger(cap) && cap > 0 && mode !== 'none';
  const exhausted = mode === 'per_user' && !rule.bypassed && (rule.reached === true || remaining === 0);
  const limit = Math.min(5000, link || stock === -1 ? 5000 : stock || 0, limited ? cap : 5000,
    mode === 'per_user' && !rule.bypassed && remaining != null ? remaining : 5000);
  const period = Number(rule.periodDays ?? rule.period_days ?? p.purchaseLimitPeriodDays ?? p.purchase_limit_period_days);
  let label = limited ? (mode === 'per_user' ? (period > 0 ? '近 '+period+' 天' : '累计') : '单次')+'限购 '+cap+' 件' : '';
  if (mode === 'per_user' && remaining != null && !rule.bypassed) label += ' · 当前可购 '+remaining+' 件';
  return {limit, label, buy:p.canPurchase !== false && !exhausted && limit > 0};
}
function params(obj) {
  return Object.keys(obj).filter(k => obj[k] !== '').map(k =>
    encodeURIComponent(k) + '=' + encodeURIComponent(obj[k])).join('&');
}
async function read(path, withSession) {
  const res = await fluxdo.fetch(api + path, {auth:withSession === true});
  if (!res.ok) {
    const error = Error('请求失败（HTTP ' + res.status + '）');
    error.status = res.status;
    if (res.status === 409) {
      try {const body = res.json(); error.code = (body.error && body.error.code) || body.code;}
      catch (_) {}
    }
    throw error;
  }
  const result = res.json();
  if (!result.success || !result.data) throw Error('暂时无法读取士多数据');
  return result.data;
}
function write(ctx, values) {
  for (const key of Object.keys(values)) ctx.setData(key, values[key]);
}
function market(ctx) {
  return views.get(ctx.surface);
}
const sortOptions = [
  {label:'默认排序',sort:'',direction:''},{label:'最新',sort:'created_at',direction:'DESC'},
  {label:'低价',sort:'final_price',direction:'ASC'},{label:'高价',sort:'final_price',direction:'DESC'},
  {label:'热销',sort:'sold_count',direction:'DESC'}
];
function showFilters(ctx,s) {
  const mark = selected => selected ? 'tonal' : 'text';
  write(ctx,{
    categories:(s.categories || []).map(c => ({...c,selected:c.id === s.cat,variant:mark(c.id === s.cat)})),
    sorts:sortOptions.map(o => ({...o,selected:o.sort === s.sort && o.direction === s.direction,variant:mark(o.sort === s.sort && o.direction === s.direction)})),
    selection:(s.catName || '全部') + ' · ' + (s.sortName || '默认排序')
  });
}
async function load(ctx, more) {
  const s = market(ctx);
  if (!s || (more && (s.loading || !s.more))) return;
  const seq = ++s.seq;
  const page = more ? s.page + 1 : 1;
  if (!more) { s.rows = []; s.more = false; s.cursor = ''; s.page = 0; }
  s.loading = true;
  write(ctx, {loading:true, more:false, message:'', webFallback:false, rows:s.rows});
  try {
    const q = {pageSize:12, search:s.search, categoryId:s.cat, inStock:s.stock?'true':'',
      sortBy:s.sort, sortOrder:s.direction, priceMin:s.min, priceMax:s.max};
    if (more && s.cursor) q.cursor = s.cursor; else q.page = page;
    if (!s.sort || s.search) q.ranking = 'auto';
    const result = await read('/products?' + params(q));
    if (market(ctx) !== s || seq !== s.seq) return;
    const products = result.products;
    if (!Array.isArray(products)) throw Error('商品列表格式有误');
    const seen = new Set(s.rows.map(r => r.id));
    const rows = products.filter(p => p && p.id != null && !seen.has(String(p.id))).map(p => ({
      id:String(p.id), title:display(p.name), image:display(p.image_url),
      price:money(p.final_price == null ? p.price : p.final_price),
      category:display(p.category_name), stock:'库存 '+stockLabel(p),
      info:money(p.final_price == null ? p.price : p.final_price) + ' · ' + display(p.category_name) +
        ' · 库存 ' + stockLabel(p)
    }));
    s.rows = s.rows.concat(rows); s.page = page;
    const paging = result.pagination || {};
    s.cursor = paging.nextCursor || '';
    s.more = typeof paging.hasMore === 'boolean' ? paging.hasMore :
      !!s.cursor || page < Number(paging.totalPages) || page * 12 < Number(paging.total);
    write(ctx,{rows:s.rows, more:s.more, message:s.rows.length ? '' : '没有符合条件的商品'});
  } catch (e) {
    if (more && s.cursor && e.code === 'RANKING_CURSOR_STALE' && seq === s.seq) return load(ctx,false);
    if (seq === s.seq) write(ctx,{message:String(e.message),more:s.more,webFallback:true});
  } finally {
    if (seq === s.seq) {s.loading = false; ctx.setData('loading',false);}
  }
}
async function categories(ctx) {
  const s = market(ctx), revision = s.categoryRevision = (s.categoryRevision || 0) + 1;
  const current = () => market(ctx) === s && revision === s.categoryRevision;
  const base = [{id:'',name:'全部'}];
  if (!s.categories) {s.categories = base; showFilters(ctx,s);}
  try {
    const data = await read('/categories');
    if (!current()) return;
    s.categories = base.concat(data.categories.map(c => ({id:String(c.id),name:c.name})));
    showFilters(ctx,s);
  } catch (_) {if (current()) ctx.setData('categoryMessage','分类加载失败，可刷新重试');}
}
async function detail(ctx) {
  const s = market(ctx);
  if (!s) return;
  s.quoteEnabled = false;
  clearQuote(ctx,s);
  const seq = ++s.seq;
  write(ctx,{ready:false,loading:true,error:'',buy:false});
  try {
    const auth = await fluxdo.auth.status();
    if (seq !== s.seq || market(ctx) !== s) return;
    write(ctx,{authorized:auth.authorized,linkProduct:false});
    if (ctx.page === 'review') {
      s.checkoutEnabled = auth.authorized && auth.checkoutUnit === 'LDC';
      s.record = null;
      write(ctx,{nativeOrder:s.checkoutEnabled,orderState:'idle',orderNote:'',orderBusy:!!s.orderBusy});
      if (s.checkoutEnabled) await checkoutStatus(ctx,s);
      if (seq !== s.seq || market(ctx) !== s) return;
    }
    let productData;
    const path = '/products/' + encodeURIComponent(ctx.params.id);
    try {productData = await read(path,auth.authorized);}
    catch (e) {
      if (!auth.authorized || e.status !== 401 || seq !== s.seq || market(ctx) !== s) throw e;
      auth.authorized = false;
      if (s.checkoutEnabled) {s.checkoutEnabled=false;s.record=null;write(ctx,{nativeOrder:false,orderState:'idle',orderNote:''});}
      productData = await read(path,false);
    }
    const p = productData.product;
    if (seq !== s.seq || market(ctx) !== s) return;
    if (!p || p.id == null || String(p.id) !== String(ctx.params.id)) throw Error('找不到这件商品');
    s.id = String(p.id);
    s.linkProduct = (p.productType || p.product_type) === 'link';
    ctx.setData('linkProduct',s.linkProduct);
    if (s.linkProduct && !s.record?.productId) ctx.setData('nativeOrder',false);
    const bounds = purchaseBounds(p,s.linkProduct);
    s.buy = bounds.buy;
    const unit = p.final_price == null ? (p.price == null ? NaN : Number(p.price) * Number(p.discount == null ? 1 : p.discount)) : Number(p.final_price);
    s.unit = Number.isFinite(unit) && unit >= 0 ? unit : NaN;
    s.limit = bounds.limit;
    s.quantity = Math.max(1,Math.min(s.quantity || 1,s.limit));
    s.quoteEnabled = ctx.page === 'review' && s.buy && !s.linkProduct && auth.authorized && (auth.queries || []).includes('orderQuote');
    clearQuote(ctx,s);
    write(ctx,{ready:true,title:display(p.name),description:display(p.description),image:display(p.image_url),
      seller:'卖家：' + (display(p.seller_name || p.seller_username) || '未提供'),
      price:money(s.unit),canAdd:s.buy && s.quantity < s.limit,canRemove:s.buy && s.quantity > 1,
      quantity:String(s.quantity),estimate:money(s.unit*s.quantity),
      details:display(p.category_name) + ' · 库存 ' + stockLabel(p) +
        ' · 已售 ' + display(p.sold_count),
      conditions:'等级要求 TL' + display(p.purchase_trust_level || 0) +
        (bounds.label ? ' · ' + bounds.label : '') +
        (p.auto_delivery ? ' · 自动交付' : ''), buy:s.buy});
    if (s.quoteEnabled && (!s.record || s.record.state === 'idle')) await quote(ctx);
  } catch (e) {if (seq === s.seq) ctx.setData('error',String(e.message));}
  finally {if (seq === s.seq) ctx.setData('loading',false);}
}
// 分页失败可以继续读同一页，授权失效则清空上一账号的数据。
const statusLabels = {pending:'待支付',pending_payment:'待支付',paying:'支付中',paid:'已支付',
  delivered:'已交付',completed:'已完成',cancelled:'已取消',refunded:'已退款',refund_pending:'退款中',
  refund_failed:'退款失败',external_dispute:'争议处理中',expired:'已过期',uploaded:'已上传',failed:'失败'};
// 与士多网页的订单服务边界一致，兼容接口混合返回的两种字段命名。
// 显式驼峰字段优先，保留 null、false 和 0 的业务含义。
function normalizeOrderData(value) {
  if (Array.isArray(value)) return value.map(normalizeOrderData);
  if (!value || typeof value !== 'object') return value;
  const result = Object.create(null);
  for (const key of Object.keys(value)) {
    const target = key.replace(/_([a-z0-9])/g, (_, letter) => letter.toUpperCase());
    if (target !== key && Object.prototype.hasOwnProperty.call(value, target)) {
      continue;
    }
    result[target] = normalizeOrderData(value[key]);
  }
  return result;
}
function orderSummary(o) {
  if (!o || typeof o.orderNo !== 'string' || !o.orderNo || typeof o.status !== 'string') {
    throw Error('订单数据格式有误');
  }
  const status = o.displayStatus || o.status;
  const amount = o.amount == null ? o.totalPrice : o.amount;
  return {no:o.orderNo, title:display(o.product && o.product.name || o.productName) || '商品订单',
    state:Object.prototype.hasOwnProperty.call(statusLabels,status) ? statusLabels[status] : '未知状态',
    amount:amount == null || amount === '' ? '—' : money(amount)};
}
async function loadOrders(ctx, append) {
  const s = market(ctx), detailPage = ctx.page === 'order';
  if (!s || (append && (s.loading || !s.more || detailPage))) return;
  const seq = ++s.seq, current = () => market(ctx) === s && seq === s.seq;
  s.deliveryText = ''; s.revealed = false;
  if (!append) {s.page = 0; s.more = false; s.rows = [];}
  s.loading = true;
  write(ctx,{loading:true,ready:false,needsSession:false,error:'',empty:false,rows:s.rows,more:false,
    hasDelivery:false,deliveryText:'',deliveryAction:'查看交付内容'});
  const sessionMissing = message => {
    s.rows = []; s.more = false;
    write(ctx,{rows:[],ready:false,more:false,empty:false,needsSession:true,authorized:false,error:message,
      orderTitle:'',orderNo:'',state:'',amount:'',delivery:''});
  };
  try {
    const auth = await fluxdo.auth.status();
    if (!current()) return;
    if (!auth.authorized) {sessionMissing('登录士多后查看订单和交付内容'); return;}
    ctx.setData('authorized',true);
    if (detailPage) {
      const no = ctx.params.no;
      if (typeof no !== 'string' || !no) throw Error('缺少订单号');
      const data = normalizeOrderData(
        await read('/orders/' + encodeURIComponent(no) + '?role=buyer', true)
      );
      if (!current()) return;
      const row = orderSummary(data.order);
      if (row.no !== no) throw Error('订单号与请求不一致');
      const delivery = data.order.deliveryType;
      const content = data.order.cdk || data.order.deliveryContent;
      if ((data.order.status === 'delivered' || data.order.status === 'completed') && typeof content === 'string') {
        s.deliveryText = content;
      }
      write(ctx,{ready:true,orderTitle:row.title,orderNo:row.no,state:row.state,amount:row.amount,
        canPay:auth.paymentSupported && data.order.status === 'pending',
        paymentAvailable:!s.paymentBusy,
        hasDelivery:!!s.deliveryText,
        delivery:delivery === 'auto' ? '自动发货' : delivery === 'manual' ? '手动发货' : '未提供'});
    } else {
      const page = s.page + 1;
      const data = normalizeOrderData(
        await read('/orders?' + params({
          role: 'buyer', page: page, pageSize: 20, status: s.orderStatus || ''
        }), true)
      );
      if (!current()) return;
      if (!Array.isArray(data.orders) || !data.pagination) throw Error('订单列表格式有误');
      const rows = data.orders.map(orderSummary), seen = new Set(s.rows.map(r => r.no));
      for (const row of rows) {
        if (seen.has(row.no)) continue;
        seen.add(row.no); s.rows.push(row);
      }
      s.page = page;
      s.more = rows.length > 0 && (page < Number(data.pagination.totalPages) || page * 20 < Number(data.pagination.total));
      write(ctx,{rows:s.rows,more:s.more,empty:!s.rows.length,ready:true});
    }
  } catch (e) {
    if (!current()) return;
    if (e.status === 401 || e.message === 'auth_required') sessionMissing('士多会话已失效。');
    else if (e.status === 403) sessionMissing('当前账号无权查看这些订单。');
    else write(ctx,{error:String(e.message),more:s.more});
  } finally {
    if (current()) {s.loading = false;ctx.setData('loading',false);}
  }
}
const orderFilters = [
  {status:'',label:'全部',name:'全部订单'},
  {status:'pending',label:'待支付',name:'待支付订单'},
  {status:'completed',label:'已完成',name:'已完成订单'},
];
function showOrderFilters(ctx) {
  const status = market(ctx).orderStatus || '';
  ctx.setData('orderFilters',orderFilters.map(filter => ({...filter,selected:filter.status === status})));
}
fluxdo.on('card.load',async ctx => ctx.setData('authorized',(await fluxdo.auth.status()).authorized));
fluxdo.on('page.open',ctx => {
  const s = {seq:0,rows:[],cat:'',search:'',sort:'',direction:'',stock:false,min:'',max:''};
  views.set(ctx.surface,s);
  if (ctx.page === 'orders' || ctx.page === 'order') {
    ctx.setData('filterName','全部订单');
    showOrderFilters(ctx);
    return loadOrders(ctx,false);
  }
  if (ctx.page === 'product' || ctx.page === 'review') return detail(ctx);
  write(ctx,{selection:'全部 · 默认排序',stock:false,categoryMessage:'',filters:false,
    filterLabel:'筛选与排序'});
  return Promise.all([categories(ctx),load(ctx,false)]);
});
fluxdo.on('surface.close',ctx => views.delete(ctx.surface));
// 后台或被其他路由盖住后，不再接收旧请求结果。恢复只进行读取，不依据返回动作判定支付结果。
fluxdo.on('page.hide',ctx => {
  const s = market(ctx);
  if (!s || ctx.page === 'market') return;
  s.seq++; s.buy = false; s.hidden = true;
  if (ctx.page === 'review' || ctx.page === 'product') {
    s.hidden = true;
    s.checkoutRevision = (s.checkoutRevision || 0) + 1;
    s.record = null;write(ctx,{nativeOrder:false,orderState:'idle',orderNote:'',orderSummary:''});
    s.quoteEnabled = false;delete s.couponChoice;clearQuote(ctx,s);write(ctx,{ready:false,buy:false});
  } else if (ctx.page === 'order' || ctx.page === 'orders') {
    s.deliveryText = '';s.revealed = false;
    write(ctx,{ready:false,hasDelivery:false,deliveryText:'',rows:[]});
  }
});
fluxdo.on('page.resume',ctx => {
  const s = market(ctx); if (s) s.hidden = false;
  if (ctx.page === 'order' || ctx.page === 'orders') return loadOrders(ctx,false);
  if (ctx.page === 'review' || ctx.page === 'product') return detail(ctx);
});
fluxdo.on('market',() => fluxdo.navigate('market'));
fluxdo.on('product',(ctx,a) => fluxdo.navigate('product',{id:a.id}));
fluxdo.on('login',async ctx => {
  write(ctx,{loggingIn:true,loginError:''});
  try {
    if (!await fluxdo.auth.request()) return;
    if (ctx.page === 'orders' || ctx.page === 'order') await loadOrders(ctx,false);
    else if (ctx.page === 'product' || ctx.page === 'review') await detail(ctx);
    else ctx.setData('authorized',true);
  } catch (error) {ctx.setData('loginError',error.message || '登录未完成，请稍后重试。');}
  finally {ctx.setData('loggingIn',false);}
});
async function payOrder(ctx,cancel) {
  const s = market(ctx);
  if (!s || s.paymentBusy || ctx.page !== 'order') return;
  s.paymentBusy=true;write(ctx,{paymentBusy:true,paymentAvailable:false,paymentNote:''});
  try {
    if (cancel) await fluxdo.checkout.cancel(ctx.params.no);
    else await fluxdo.checkout.pay(ctx.params.no);
  } catch (_) {ctx.setData('paymentNote','操作未完成，请刷新订单核对当前状态。');}
  finally {
    s.paymentBusy=false;write(ctx,{paymentBusy:false,paymentAvailable:true});
    if (market(ctx) === s && !s.hidden) await loadOrders(ctx,false);
  }
}
fluxdo.on('payOrder',ctx => payOrder(ctx,false));
fluxdo.on('cancelOrder',ctx => payOrder(ctx,true));
fluxdo.on('webMarket',() => fluxdo.session.open('/'));
fluxdo.on('webProduct',ctx => fluxdo.session.open('/product/' + encodeURIComponent(ctx.params.id)));
fluxdo.on('orders',() => fluxdo.navigate('orders'));
fluxdo.on('order',(_ctx,args) => fluxdo.navigate('order',{no:args.no}));
fluxdo.on('ordersRefresh',ctx => loadOrders(ctx,false));
fluxdo.on('ordersMore',ctx => loadOrders(ctx,true));
fluxdo.on('delivery',ctx => {
  const s = market(ctx);
  if (ctx.page !== 'order' || !s || !s.deliveryText) return;
  s.revealed = !s.revealed;
  write(ctx,{deliveryText:s.revealed ? s.deliveryText : '',deliveryAction:s.revealed?'收起交付内容':'查看交付内容'});
});
fluxdo.on('ordersFilter',(ctx,args) => {
  market(ctx).orderStatus = args.status;
  ctx.setData('filterName',args.name);
  showOrderFilters(ctx);
  return loadOrders(ctx,false);
});
fluxdo.on('officialOrders',() => fluxdo.session.open('/user/orders'));
fluxdo.on('review',ctx => {
  const s = market(ctx);
  if (s && s.buy) return fluxdo.navigate('review',{id:s.id});
});
function clearQuote(ctx,s) {
  if (ctx.page !== 'review') return;
  s.quoteSeq = (s.quoteSeq || 0) + 1; s.quote = null; s.quoting = false;
  s.orderIntent = null;
  write(ctx,{canQuote:s.quoteEnabled,canSubmit:false,quoteReady:false,quoting:false,quoteNote:'',couponRows:[],payable:''});
}
function showQuote(ctx,s) {
  const q = s.quote;
  // 缺省选应付最低的券；用户选过券（包括不用券）后只按新报价核对，不替用户换券。
  const manual = s.couponChoice !== undefined;
  const best = q.coupons.reduce((a,c) => c.amount < (a ? a.amount : q.base) ? c : a,null);
  const coupon = manual ? q.coupons.find(c => c.id === s.couponChoice) : best;
  const expired = manual && !!s.couponChoice && !coupon;
  if (expired) s.couponChoice = '';
  s.orderIntent = {productId:s.id,quantity:s.quantity,expectedAmount:coupon ? coupon.amount : q.base,
    ...(coupon ? {couponClaimId:coupon.id} : {})};
  ctx.setData('canSubmit',s.checkoutEnabled && s.record?.state === 'idle' && !s.orderBusy);
  write(ctx,{quoteReady:true,couponRows:q.coupons.map(c => ({
      id:c.id,label:c.name + ' · ' + money(c.amount),selected:c === coupon,variant:c === coupon ? 'tonal' : 'text'
    })),choice:coupon ? coupon.name : '不使用优惠券',noCoupon:!coupon,noneVariant:coupon ? 'text' : 'tonal',
    quoteNote:expired ? '之前选择的优惠券已不可用，请核对新报价。' : '',
    payable:money(coupon ? coupon.amount : q.base)});
}
const validAmount = n => typeof n === 'number' && Number.isFinite(n) && n >= 0;
async function quote(ctx) {
  const s = market(ctx);
  if (!s || ctx.page !== 'review' || !s.quoteEnabled || s.quoting) return;
  clearQuote(ctx,s);
  const seq = s.quoteSeq, quantity = s.quantity, current = () => market(ctx) === s && seq === s.quoteSeq;
  s.quoting = true; ctx.setData('quoting',true);
  try {
    const response = await fluxdo.auth.query('orderQuote',{productId:s.id,quantity});
    if (!current()) return;
    if (response.status === 401) {
      delete s.couponChoice;s.quoteEnabled=false;s.checkoutEnabled=false;
      write(ctx,{canQuote:false,authorized:false,nativeOrder:false});
      throw Error('士多会话已失效，请重新登录。');
    }
    if (!response.ok) throw Error('士多报价失败（HTTP '+response.status+'）');
    const result = response.json(), q = result.data;
    if (!result.success || !q || String(q.productId) !== s.id || q.quantity !== quantity ||
        !Array.isArray(q.coupons) || !validAmount(q.payableAmount)) throw Error('士多返回的报价与当前商品或数量不符');
    const eligible = q.coupons.filter(c => c && c.eligible === true);
    const base = q.productSubtotal ?? (eligible.length === 0 ? q.payableAmount : null);
    if (!validAmount(base)) throw Error('士多未返回可核对的商品小计');
    const coupons = eligible.map(c => {
      if (c.claimId == null || !validAmount(c.payableAmount)) throw Error('优惠券报价无法核对');
      return {id:String(c.claimId), name:display(c.campaign && c.campaign.name) || '优惠券',amount:c.payableAmount};
    });
    s.quote = {base,coupons};
    showQuote(ctx,s);
  } catch (e) {
    if (current()) ctx.setData('quoteNote',e.message === 'query_not_granted' ? '当前会话没有报价权限' : String(e.message));
  } finally {
    if (current()) {s.quoting=false;ctx.setData('quoting',false);}
  }
}
fluxdo.on('quote',quote);
fluxdo.on('quoteCoupon',(ctx,a) => {
  const s = market(ctx);
  if (s && s.quote && ctx.page === 'review' && (a.id === '' || s.quote.coupons.some(c => c.id === a.id))) {
    s.couponChoice = a.id;showQuote(ctx,s);
  }
});
function showSubmission(ctx,s,result) {
  s.record = result;
  const state = result.state;
  write(ctx,{orderState:state,orderSummary:result.productId ?
    '商品 '+ result.productId +' · '+result.quantity+' 件 · '+money(result.expectedAmount) : '',
    orderNo:result.orderNo || '',canSubmit:s.checkoutEnabled && state === 'idle' && !!s.orderIntent && !s.orderBusy});
}
async function checkoutStatus(ctx,s) {
  const rev = s.checkoutRevision = (s.checkoutRevision || 0)+1;
  const current = () => rev === s.checkoutRevision && market(ctx) === s && !s.hidden;
  try {
    const result = await fluxdo.checkout.status();
    if (current()) showSubmission(ctx,s,result);
  } catch (_) {if (current()) showSubmission(ctx,s,{state:'unavailable'});}
}
async function checkoutAction(ctx,kind) {
  const s = market(ctx);
  if (!s || ctx.page !== 'review' || !s.checkoutEnabled || s.hidden || s.orderBusy) return;
  if (kind === 'submit' && (!s.buy || !s.orderIntent || s.record?.state !== 'idle')) return;
  s.orderBusy=true;write(ctx,{orderBusy:true,orderNote:'',canSubmit:false});
  let note='';
  try {
    const result = kind === 'submit' ? await fluxdo.checkout.submit(s.orderIntent) :
      kind === 'retry' ? await fluxdo.checkout.retry() :
      kind === 'finish' ? await fluxdo.checkout.finish(s.record.orderNo) : await fluxdo.checkout.recover();
    if (result?.state === 'rejected') {
      clearQuote(ctx,s);note='士多未接受本次订单，请重新查价并核对数量。';
    } else if (result?.issue === 'authorization') {
      note='士多没有接受当前账号的授权。恢复授权后，请查这笔订单的原提交结果。';
    } else if (kind === 'finish') clearQuote(ctx,s);
  } catch (_) {note='未能确认操作结果，请先查看当前订单记录。';}
  finally {
    s.orderBusy=false;
    if (market(ctx) === s && !s.hidden) {
      write(ctx,{orderBusy:false,orderNote:note});
      await checkoutStatus(ctx,s);
    }
  }
}
fluxdo.on('submitOrder',ctx => checkoutAction(ctx,'submit'));
fluxdo.on('lookupSubmission',ctx => checkoutAction(ctx,'recover'));
fluxdo.on('retrySubmission',ctx => checkoutAction(ctx,'retry'));
fluxdo.on('finishSubmission',ctx => checkoutAction(ctx,'finish'));
fluxdo.on('createdOrder',ctx => {
  const r = market(ctx)?.record;
  if (r?.state === 'created') return fluxdo.navigate('order',{no:r.orderNo});
});
fluxdo.on('quantity',(ctx,a) => {
  const s = market(ctx);
  if (!s || ctx.page !== 'review' || !s.buy || (a.step !== 1 && a.step !== -1)) return;
  s.quantity = Math.min(s.limit,Math.max(1,s.quantity + a.step));
  clearQuote(ctx,s);
  write(ctx,{quantity:String(s.quantity),estimate:money(s.unit * s.quantity),
    canRemove:s.quantity > 1,canAdd:s.quantity < s.limit});
  return quote(ctx);
});
fluxdo.on('buy',async ctx => {
  const s = market(ctx);
  if (!s || !s.buy) return;
  // 链接商品的兑换目标由士多页面提供。
  const id = encodeURIComponent(s.id);
  await fluxdo.session.open((s.linkProduct ? '/product/' : '/checkout/') + id);
});
fluxdo.on('retry',ctx => detail(ctx));
fluxdo.on('refresh',ctx => {ctx.setData('categoryMessage',''); return Promise.all([categories(ctx),load(ctx,false)]);});
fluxdo.on('more',ctx => load(ctx,true));
fluxdo.on('filters',ctx => {
  const s = market(ctx);
  s.filters = !s.filters;
  write(ctx,{filters:s.filters,filterLabel:s.filters?'收起筛选':'筛选与排序'});
});
fluxdo.on('input',(ctx,a) => {
  market(ctx)[a.field] = display(a.value).trim();
  if (a.field === 'min' || a.field === 'max') ctx.setData(a.field,display(a.value));
});
fluxdo.on('apply',ctx => load(ctx,false));
fluxdo.on('stock',(ctx,a) => {market(ctx).stock = a.value; ctx.setData('stock',a.value);return load(ctx,false);});
fluxdo.on('select',(ctx,a) => {
  const s = market(ctx);
  if (a.cat !== undefined) {s.cat=a.cat;s.catName=a.label;}
  else {s.sort=a.sort;s.direction=a.direction;s.sortName=a.label;}
  showFilters(ctx,s);
  return load(ctx,false);
});
