// 每个页面独立保存筛选和分页，晚到的请求不能覆盖新筛选的结果。
const api = 'https://api2.ldspro.qzz.io/api/shop';
// 士多协议由插件实现，宿主提供网络、凭证、Connect 与收银台。
const ldStore = (() => {
  const site = 'https://ldcstore.com';
  const callback = site + '/auth/callback';
  let loginTask = null;
  let orderQueue = Promise.resolve();

  function address(value, source) {
    if (typeof value !== 'string' || value.length > 32768) throw Error('oauth_invalid_redirect');
    if (source && value.startsWith('//')) value = 'https:' + value;
    if (source && value.startsWith('/')) value = source.origin + value;
    if (source && /^[?#]/.test(value)) value = source.endpoint + value;
    const parts = /^(https:\/\/[^/?#]+)(\/[^?#]*)?(\?[^#]*)?(#.*)?$/.exec(value);
    if (!parts || /[\s\\@]/.test(parts[1])) throw Error('oauth_invalid_redirect');
    return {url: value, origin: parts[1], endpoint: parts[1] + (parts[2] || '/'),
      query: (parts[3] || '').slice(1), fragment: (parts[4] || '').slice(1)};
  }

  function parameter(text, name) {
    const fields = text.split('&').filter(field => field.split('=')[0] === name);
    if (fields.length !== 1) return null;
    return decodeURIComponent(fields[0].slice(name.length + 1));
  }

  function decodeBase64(value) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    const input = value.replace(/-/g, '+').replace(/_/g, '/').replace(/\s/g, '+');
    if (!/^[A-Za-z0-9+/]*={0,2}$/.test(input) || input.replace(/=/g, '').length % 4 === 1) {
      throw Error('oauth_invalid_handoff');
    }
    let bits = 0, count = 0, encoded = '';
    for (const char of input.replace(/=/g, '')) {
      bits = (bits << 6) | alphabet.indexOf(char);
      count += 6;
      if (count >= 8) {
        count -= 8;
        encoded += '%' + ((bits >>> count) & 255).toString(16).padStart(2, '0');
      }
    }
    return decodeURIComponent(encoded);
  }

  function htmlValue(value) {
    return value.replace(/&(#x[0-9a-f]+|#\d+|amp|quot|apos|lt|gt);/gi, (raw, entity) => {
      if (entity[0] !== '#') return {amp:'&',quot:'"',apos:"'",lt:'<',gt:'>'}[entity.toLowerCase()];
      const code = entity[1].toLowerCase() === 'x' ? parseInt(entity.slice(2), 16) : Number(entity.slice(1));
      return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : raw;
    });
  }

  function htmlCallback(body, source) {
    const candidates = new Set();
    function add(value) {
      try {
        const target = address(value.trim(), source);
        if (target.endpoint === callback &&
            /(?:^|&)ldsp_oauth=/.test(target.fragment + '&' + target.query)) candidates.add(target.url);
      } catch (_) {}
    }
    const markup = body.replace(/<!--[\s\S]*?-->/g, '');
    for (const tag of markup.match(/<(?:a|meta)\b[^>]*>/gi) || []) {
      const attrs = {};
      const pattern = /([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/g;
      let attr;
      while ((attr = pattern.exec(tag))) attrs[attr[1].toLowerCase()] = htmlValue(attr[2] ?? attr[3] ?? attr[4]);
      if (/^<a\b/i.test(tag) && attrs.href) add(attrs.href);
      if (/^<meta\b/i.test(tag) && (attrs['http-equiv'] || '').toLowerCase() === 'refresh') {
        const match = /^\s*\d+(?:\.\d+)?\s*;\s*url\s*=\s*(.*?)\s*$/i.exec(attrs.content || '');
        if (match) add(match[1].replace(/^(['"])([\s\S]*)\1$/, '$2'));
      }
    }
    const scripts = /<script\b([^>]*)>([\s\S]*?)<\/script\s*>/gi;
    const literals = /\/\/[^\r\n]*|\/\*[\s\S]*?\*\/|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`/g;
    let script;
    while ((script = scripts.exec(markup))) {
      if (/\bsrc\s*=/i.test(script[1])) continue;
      let literal;
      while ((literal = literals.exec(script[2]))) {
        const text = literal[0];
        if (text[0] === '/' || (text[0] === '`' && text.includes('${'))) continue;
        try {
          const json = text[0] === '"' ? text : '"' + text.slice(1, -1)
            .replace(/\\.|"/g, part => part === "\\'" ? "'" : part === '\\`' ? '`' : part === '"' ? '\\"' : part) + '"';
          add(JSON.parse(json));
        } catch (_) {}
      }
    }
    if (candidates.size !== 1) throw Error('oauth_invalid_callback');
    return candidates.values().next().value;
  }

  async function jsonRequest(client, url, options) {
    const response = await client.fetch(url, options);
    let body;
    try { body = response.json(); } catch (_) { throw Error('service_invalid_response'); }
    if (!response.ok || body?.success !== true) {
      const error = Error('service_http_' + response.status);
      error.status = response.status;
      throw error;
    }
    return body.data ?? body;
  }

  async function login(client) {
    let stage = 'initialize', captured = false;
    try {
      const account = await client.user.get();
      if (!account?.id) throw Error('oauth_account_required');
      if (!await client.dialogs.confirm({
        title:'登录 LD士多',
        message:'使用 Linux DO 账号登录后，可收藏商品、领取优惠券并查看订单。请先阅读士多服务条款。',
        confirmLabel:'使用 Linux DO 账号登录',
        agreement:{label:'《LD士多服务条款》',url:'https://ldcstore.com/docs/terms'},
      })) return false;
      const pkce = await client.crypto.pkce();
      const initial = await jsonRequest(client,
        'https://api1.ldspro.qzz.io/api/auth/init?' + params({
          site:'linux.do', return_url:callback, code_challenge:pkce.challenge,
        }), {headers:{Accept:'application/json', Origin:site}});
      if (typeof initial.state !== 'string' || !initial.state || typeof initial.auth_url !== 'string') {
        throw Error('oauth_invalid_init');
      }
      const serviceCallback = address(parameter(address(initial.auth_url).query, 'redirect_uri'));
      stage = 'authorization';
      const authorized = await client.connect.authorize(initial.auth_url);
      if (authorized === null) return false;
      let target = address(authorized);
      stage = 'callback';
      for (let hop = 0; target.endpoint !== callback && hop < 8; hop++) {
        if (target.endpoint !== serviceCallback.endpoint) throw Error('oauth_invalid_redirect');
        const response = await client.fetch(target.url, {
          headers:{Accept:'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'},
        });
        let next;
        if (response.status >= 300 && response.status < 400) next = response.headers.location;
        else if (response.status === 200 && (response.headers['content-type'] || '').startsWith('text/html')) {
          next = htmlCallback(response.body, target);
        }
        target = address(next, target);
      }
      if (target.endpoint !== callback) throw Error('oauth_redirect_limit');
      const encoded = parameter(target.fragment, 'ldsp_oauth') ?? parameter(target.query, 'ldsp_oauth');
      if (!encoded || encoded.length > 32768) throw Error('oauth_invalid_handoff');
      const decoded = decodeBase64(encoded);
      let handoff;
      try { handoff = JSON.parse(decoded); } catch (_) { handoff = JSON.parse(decodeURIComponent(decoded)); }
      if (handoff.s !== initial.state || !Number.isInteger(handoff.exp) || handoff.exp <= 0 ||
          typeof handoff.c !== 'string' || !/^[A-Za-z0-9_-]{43,128}$/.test(handoff.c)) {
        throw Error('oauth_state_mismatch');
      }
      stage = 'exchange';
      const result = await client.credentials.capture('account', {
        url:api + '/auth/exchange', method:'POST', headers:{Origin:site},
        body:{code:handoff.c, state:initial.state, verifier:pkce.verifier, origin:site},
      }, {tokenPath:['data','token'], jwt:true});
      captured = true;
      stage = 'verification';
      const verified = await jsonRequest(client, api + '/auth/verify', {credential:'account', headers:{Origin:site}});
      const current = await client.user.get();
      const claims = result.claims;
      if (current?.id !== account.id || verified.authenticated !== true ||
          String(verified.user?.id) !== String(account.id) ||
          String(claims?.sub ?? claims?.id) !== String(account.id) ||
          (verified.user?.site ?? 'linux.do') !== 'linux.do' ||
          (claims?.site ?? 'linux.do') !== 'linux.do' ||
          !Number.isInteger(claims?.exp) || claims.exp * 1000 <= Date.now()) {
        throw Error('oauth_identity_mismatch');
      }
      return true;
    } catch (error) {
      if (captured) await client.credentials.remove('account');
      const reason = /^[a-z_0-9]+$/.test(error.message || '') ? error.message : 'request_failed';
      console.warn('login stage=' + stage + ' reason=' + reason);
      const label = {initialize:'服务初始化',authorization:'Connect 授权',callback:'服务回调',exchange:'会话交换',verification:'账号校验'};
      throw Error('登录在「' + label[stage] + '」阶段未完成，请重试。');
    }
  }

  async function status() {
    if (loginTask) await loginTask.catch(() => false);
    const current = await fluxdo.credentials.status('account');
    return {...current, paymentSupported:true, checkoutUnit:'LDC', queries:['orderQuote']};
  }

  async function session() {
    const account = await fluxdo.user.get();
    if (!account?.id || !(await status()).authorized) throw Error('auth_required');
    return account.id;
  }

  async function checkSession(account) {
    if (await session() !== account) throw Error('checkout_session_changed');
  }

  function validIntent(intent) {
    return intent && /^[A-Za-z0-9_-]{1,128}$/.test(intent.productId || '') &&
      Number.isInteger(intent.quantity) && intent.quantity >= 1 && intent.quantity <= 5000 &&
      typeof intent.expectedAmount === 'number' && Number.isFinite(intent.expectedAmount) &&
      intent.expectedAmount >= 0 && intent.expectedAmount <= 1e9 &&
      Number(intent.expectedAmount.toFixed(2)) === intent.expectedAmount &&
      (intent.couponClaimId == null || /^[A-Za-z0-9_-]{1,128}$/.test(intent.couponClaimId));
  }

  function validateRecord(saved) {
    if (saved == null) return null;
    if (!validIntent(saved) || !/^ord_[0-9a-f]{32}$/.test(saved.token || '') ||
        !['pending','missing','created'].includes(saved.state) ||
        (saved.state === 'created' && !/^[A-Za-z0-9_-]{1,128}$/.test(saved.orderNo || ''))) {
      throw Error('checkout_record_invalid');
    }
    return saved;
  }

  async function record(account) {
    const key = 'submission:' + account;
    const saved = await fluxdo.storage.get(key);
    if (saved != null) return validateRecord(saved);
    const legacy = await fluxdo.storage.get('legacyApi1Records');
    if (!legacy || typeof legacy !== 'object') return null;
    const scope = 'v1:' + await fluxdo.crypto.sha256(JSON.stringify([
      api + '/orders', api + '/order-submissions', 'linux.do:' + account, 'LDC',
    ]));
    if (!Object.prototype.hasOwnProperty.call(legacy, scope)) return null;
    let restored;
    try { restored = validateRecord(JSON.parse(legacy[scope])); }
    catch (_) { throw Error('checkout_record_invalid'); }
    await checkSession(account);
    delete legacy[scope];
    await fluxdo.storage.setMany({
      [key]:restored,
      legacyApi1Records:Object.keys(legacy).length ? legacy : null,
    });
    return restored;
  }

  async function saveRecord(account, value) {
    await checkSession(account);
    await fluxdo.storage.set('submission:' + account, value);
  }

  async function requestOrder(account, pending, create) {
    let response, body;
    try {
      await checkSession(account);
      response = await fluxdo.fetch(api + (create ? '/orders' : '/order-submissions/' + pending.token), {
        credential:'account', method:create ? 'POST' : 'GET',
        ...(create ? {body:{productId:pending.productId, quantity:pending.quantity,
          expectedAmount:pending.expectedAmount, submissionToken:pending.token,
          ...(pending.couponClaimId ? {couponClaimId:pending.couponClaimId} : {})}} : {}),
      });
      body = response.json();
    } catch (_) {}
    await checkSession(account);
    const next = {...pending, state:'pending'};
    delete next.orderNo;
    if (response?.ok && body?.success === true && body.data) {
      const order = create ? body.data : body.data.exists === true ? body.data.order : null;
      const no = order?.orderNo ?? order?.order_no;
      if (typeof no === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(no)) {
        next.state = 'created'; next.orderNo = no;
      } else if (!create && body.data.exists === false && body.data.order == null) next.state = 'missing';
    } else if (create && [400,409,422].includes(response?.status) && body?.success === false) {
      const code = body.error?.code ?? body.errorCode ?? body.code;
      if (typeof code === 'string' && code && code !== 'ORDER_SUBMISSION_CONFLICT' && code !== 'PUBLIC_ID_REQUIRED') {
        await saveRecord(account, null);
        return {state:'rejected'};
      }
    }
    await saveRecord(account, next);
    return {...next, ...([401,403].includes(response?.status) ? {issue:'authorization'} : {})};
  }

  async function submission(action, value) {
    const account = await session();
    const previous = await record(account);
    await checkSession(account);
    if (action === 'status') return previous || {state:'idle'};
    if (action === 'finish') {
      if (previous?.state !== 'created' || previous.orderNo !== value) throw Error('checkout_lookup_required');
      return saveRecord(account, null);
    }
    if (action === 'recover') {
      if (!previous || previous.state === 'created') return previous || {state:'idle'};
      return requestOrder(account, previous, false);
    }
    if (action === 'submit' && previous) return previous;
    if (action === 'retry' && previous?.state !== 'missing') throw Error('checkout_lookup_required');
    const intent = action === 'retry' ? previous : value;
    if (!validIntent(intent)) throw Error('checkout_invalid_intent');
    const pending = {...intent, state:'pending',
      token:previous?.token || 'ord_' + (await fluxdo.crypto.uuid()).replace(/-/g, '')};
    await saveRecord(account, pending);
    return requestOrder(account, pending, true);
  }

  return {
    status,
    login(client) {
      if (loginTask) return loginTask;
      loginTask = login(client).finally(() => { loginTask = null; });
      return loginTask;
    },
    submission(action, value) {
      const task = orderQueue.then(() => submission(action, value));
      orderQueue = task.catch(() => {});
      return task;
    },
    async pay(client, no) {
      const account = await session();
      const orderPath = api + '/orders/' + encodeURIComponent(no);
      const details = await jsonRequest(client, orderPath + '?role=buyer', {credential:'account'});
      const order = details.order;
      if (!order || (order.orderNo ?? order.order_no) !== no || order.status !== 'pending') throw Error('payment_order_unavailable');
      const payment = await jsonRequest(client, orderPath + '/payment-url', {credential:'account'});
      await checkSession(account);
      const result = await client.payments.request({provider:'linuxDoCredit',
        url:payment.paymentUrl ?? payment.payment_url, reference:no,
        amount:order.amount ?? order.totalPrice ?? order.total_price});
      if (result) {
        await checkSession(account);
        try { await jsonRequest(client, orderPath + '/refresh', {credential:'account', method:'POST'}); }
        catch (_) { console.warn('delivery refresh pending'); }
      }
      return result;
    },
    async cancel(client, no) {
      await session();
      await jsonRequest(client, api + '/orders/' + encodeURIComponent(no) + '/cancel', {credential:'account', method:'POST'});
      return {state:'cancelled'};
    },
  };
})();
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
  const res = await fluxdo.fetch(api + path, withSession ? {credential:'account'} : {});
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
function invalidateViews(except) {
  for (const state of views.values()) {
    if (state !== except) state.dirty = true;
  }
}
function refreshView(ctx) {
  const s = market(ctx);
  if (!s || s.hidden || s.paymentBusy || s.orderBusy) return;
  s.dirty = false;
  if (['favorites','coupons','coupon','refund','comment','merchant'].includes(ctx.page)) return loadBuyerPage(ctx,false);
  if (ctx.page === 'order' || ctx.page === 'orders') return loadOrders(ctx,false);
  if (ctx.page === 'review' || ctx.page === 'product') return detail(ctx);
  return load(ctx,false);
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
  write(ctx, {loading:!more, loadingMore:more, more:false, message:'', webFallback:false, rows:s.rows});
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
      category:display(p.category_name), stock:'库存 '+stockLabel({...p,stock_quantity:p.stockQuantity ?? p.stock_quantity}),
      info:money(p.final_price == null ? p.price : p.final_price) + ' · ' + display(p.category_name) +
        ' · 库存 ' + stockLabel(p)
    }));
    s.rows = s.rows.concat(rows); s.page = page;
    const paging = result.pagination || {};
    s.cursor = paging.nextCursor || '';
    s.more = typeof paging.hasMore === 'boolean' ? paging.hasMore :
      !!s.cursor || page < Number(paging.totalPages) || page * 12 < Number(paging.total);
    write(ctx,{rows:s.rows, more:s.more, message:''});
  } catch (e) {
    if (more && s.cursor && e.code === 'RANKING_CURSOR_STALE' && seq === s.seq) return load(ctx,false);
    if (seq === s.seq) write(ctx,{message:String(e.message),more:s.more,webFallback:true});
  } finally {
    if (seq === s.seq) {s.loading = false; write(ctx,{loading:false,loadingMore:false});}
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
  write(ctx,{ready:false,loading:true,error:'',externalError:'',buy:false});
  try {
    const auth = await ldStore.status();
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
    s.favorited = p.isFavorited === true;
    write(ctx,{favoriteLabel:s.favorited ? '已收藏' : '收藏商品',buyerError:''});
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
    if (ctx.page === 'product') loadComments(ctx,false);
  } catch (e) {if (seq === s.seq) ctx.setData('error',String(e.message));}
  finally {if (seq === s.seq) ctx.setData('loading',false);}
}
async function loadComments(ctx,more) {
  const s = market(ctx);
  if (!s || ctx.page !== 'product' || (more && s.commentsLoading)) return;
  const revision = s.commentsRevision = (s.commentsRevision || 0) + 1;
  const current = () => market(ctx) === s && s.commentsRevision === revision;
  const page = more ? (s.commentsPage || 1) + 1 : 1;
  s.commentsLoading = true;
  write(ctx,{commentsLoading:true,commentsError:''});
  try {
    const auth = await ldStore.status();
    const data = normalizeOrderData(await read('/products/' + encodeURIComponent(ctx.params.id) +
      '/comments?page=' + page + '&pageSize=10',auth.authorized));
    if (!current()) return;
    if (!Array.isArray(data.comments)) throw Error('评论数据格式有误');
    const rows = data.comments.map(c => ({id:String(c.id),
      author:display(c.nickname || c.username) || '用户',content:display(c.content),
      rating:c.ratingValue == null ? '' : String(c.ratingValue) + ' / 5'}));
    const previous = more ? s.comments || [] : [];
    const ids = new Set(previous.map(c => c.id));
    s.comments = previous.concat(rows.filter(c => !ids.has(c.id)));
    s.commentsPage = page;
    const paging = data.pagination || {};
    write(ctx,{comments:s.comments,commentsMore:paging.hasMore === true || page < Number(paging.totalPages),
      canComment:data.commentEnabled === true,
      commentsMessage:data.commentEnabled === false ? '该商品已关闭评论' : s.comments.length ? '' : '暂无评论'});
  } catch (e) {
    if (current()) ctx.setData('commentsError',String(e.message));
  } finally {
    if (current()) {s.commentsLoading = false;ctx.setData('commentsLoading',false);}
  }
}
fluxdo.on('commentsRetry',ctx => loadComments(ctx,false));
fluxdo.on('commentsMore',ctx => loadComments(ctx,true));
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
    const auth = await ldStore.status();
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
        paymentAvailable:!s.paymentBusy,cancelLabel:'取消订单',
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
fluxdo.on('card.load',async ctx => ctx.setData('authorized',(await ldStore.status()).authorized));
fluxdo.on('page.open',ctx => {
  const s = {seq:0,visibility:0,rows:[],cat:'',search:'',sort:'',direction:'',stock:false,min:'',max:''};
  views.set(ctx.surface,s);
  write(ctx,{externalBusy:false,externalError:''});
  if (['favorites','coupons','coupon','refund','comment','merchant'].includes(ctx.page)) return loadBuyerPage(ctx,false);
  if (ctx.page === 'product') write(ctx,{comments:[],commentsError:'',commentsMessage:'',commentsMore:false,commentsLoading:false});
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
// 页面暂时被遮住时保留内容、筛选和分页，只收起已展开的交付内容。
fluxdo.on('page.hide',ctx => {
  const s = market(ctx);
  if (!s) return;
  s.hidden = true;
  s.visibility++;
  if (ctx.page === 'order') {
    s.revealed = false;
    write(ctx,{deliveryText:'',deliveryAction:'查看交付内容'});
  }
});
fluxdo.on('page.resume',(ctx,args) => {
  const s = market(ctx);
  if (!s) return;
  s.hidden = false;
  if (s.createdNavigation) return openCreatedOrder(ctx,s);
  if (s.dirty) return refreshView(ctx);
});
fluxdo.on('market',() => fluxdo.navigate('market'));
fluxdo.on('product',(ctx,a) => fluxdo.navigate('product',{id:a.id}));
fluxdo.on('login',async ctx => {
  const s = market(ctx);
  write(ctx,{loggingIn:true,loginError:''});
  try {
    if (!await ldStore.login(ctx.api)) return;
    invalidateViews(s);
    if (s) s.dirty = false;
    if (ctx.page === 'orders' || ctx.page === 'order') await loadOrders(ctx,false);
    else if (['favorites','coupons','coupon','refund','comment','merchant'].includes(ctx.page)) await loadBuyerPage(ctx,false);
    else if (ctx.page === 'product' || ctx.page === 'review') await detail(ctx);
    else ctx.setData('authorized',true);
  } catch (error) {ctx.setData('loginError',error.message || '登录未完成，请稍后重试。');}
  finally {ctx.setData('loggingIn',false);}
});
async function payOrder(ctx,cancel) {
  const s = market(ctx);
  if (!s || s.paymentBusy || ctx.page !== 'order') return;
  if (cancel && !s.cancelConfirmed) {
    s.cancelConfirmed = true;
    write(ctx,{cancelLabel:'确认取消订单',paymentNote:'取消后将无法继续支付此订单，再次点击确认。'});
    return;
  }
  s.cancelConfirmed = false;
  ctx.setData('cancelLabel','取消订单');
  s.paymentBusy=true;write(ctx,{paymentBusy:true,paymentAvailable:false,paymentNote:''});
  try {
    const result = cancel ? await ldStore.cancel(ctx.api,ctx.params.no) :
      await ldStore.pay(ctx.api,ctx.params.no);
    if (result != null) invalidateViews();
  } catch (_) {
    invalidateViews();
    ctx.setData('paymentNote','操作未完成，请刷新订单核对当前状态。');
  }
  finally {
    s.paymentBusy=false;write(ctx,{paymentBusy:false,paymentAvailable:true});
    if (market(ctx) === s && s.dirty) await refreshView(ctx);
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
  if (!s || !s.buy || s.hidden) return;
  if (s.linkProduct) return openExternalProduct(ctx);
  return fluxdo.navigate('review',{id:s.id});
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
    const response = await ctx.api.fetch(api + '/orders/quote', {
      credential:'account', method:'POST', body:{productId:s.id,quantity},
    });
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
  const current = () => rev === s.checkoutRevision && market(ctx) === s;
  try {
    let result = await ldStore.submission('status');
    if (result.state === 'created') {
      await ldStore.submission('finish',result.orderNo);
      result = {state:'idle'};
    }
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
    const openOrder = kind !== 'finish' && typeof fluxdo.prepareNavigation === 'function'
      ? await fluxdo.prepareNavigation('order') : null;
    const result = await ldStore.submission(kind,
      kind === 'submit' ? s.orderIntent : kind === 'finish' ? s.record.orderNo : null);
    if (result?.state === 'created' || result?.state === 'pending') invalidateViews(s);
    if (result?.state === 'created') {
      showSubmission(ctx,s,result);
      if (openOrder) s.createdNavigation = {open:openOrder,orderNo:result.orderNo};
    }
    if (result?.state === 'rejected') {
      clearQuote(ctx,s);note='士多未接受本次订单，请重新查价并核对数量。';
    } else if (result?.issue === 'authorization') {
      note='士多没有接受当前账号的授权。恢复授权后，请查这笔订单的原提交结果。';
    } else if (kind === 'finish') {showSubmission(ctx,s,{state:'idle'});clearQuote(ctx,s);}
  } catch (_) {note='未能确认操作结果，请先查看当前订单记录。';}
  finally {
    s.orderBusy=false;
    if (market(ctx) === s) {
      write(ctx,{orderBusy:false,orderNote:note});
      if (s.createdNavigation) await openCreatedOrder(ctx,s);
      else if (s.dirty && !s.hidden) await refreshView(ctx);
      else if (s.record?.state !== 'created') await checkoutStatus(ctx,s);
    }
  }
}
async function openCreatedOrder(ctx,s) {
  const navigation = s.createdNavigation;
  if (!navigation || s.hidden || s.orderBusy || market(ctx) !== s) return;
  s.createdNavigation = null;
  try {
    await navigation.open({no:navigation.orderNo});
    await ldStore.submission('finish',navigation.orderNo);
    showSubmission(ctx,s,{state:'idle'});
    clearQuote(ctx,s);
    s.dirty = true;
  } catch (_) {
    write(ctx,{orderNote:'订单已创建，请打开订单查看详情。'});
  }
}
fluxdo.on('submitOrder',ctx => checkoutAction(ctx,'submit'));
fluxdo.on('lookupSubmission',ctx => checkoutAction(ctx,'recover'));
fluxdo.on('retrySubmission',ctx => checkoutAction(ctx,'retry'));
fluxdo.on('finishSubmission',ctx => checkoutAction(ctx,'finish'));
fluxdo.on('createdOrder',async ctx => {
  const r = market(ctx)?.record;
  if (r?.state === 'created') {
    await ldStore.submission('finish',r.orderNo);
    showSubmission(ctx,market(ctx),{state:'idle'});
    return fluxdo.navigate('order',{no:r.orderNo});
  }
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
async function openExternalProduct(ctx) {
  const s = market(ctx);
  if (!s || !s.buy || !s.linkProduct || s.hidden || s.externalBusy) return;
  const seq = s.seq, visibility = s.visibility;
  const current = () => market(ctx) === s && seq === s.seq && visibility === s.visibility;
  s.externalBusy = true;
  write(ctx,{externalBusy:true,externalError:''});
  try {
    const auth = await ldStore.status();
    if (!current()) return;
    const response = await ctx.api.fetch(api + '/products/' + encodeURIComponent(s.id) + '/external-link',
      auth.authorized ? {credential:'account'} : {});
    if (!current()) return;
    if (!response.ok) throw Error('读取兑换地址失败（HTTP ' + response.status + '）');
    const result = response.json();
    const target = result.success === true && typeof result.data?.paymentLink === 'string'
      ? result.data.paymentLink.trim() : '';
    if (!/^https?:\/\/[^\s/]+/i.test(target)) throw Error('士多返回的兑换地址无效');
    await ctx.api.openUrl(target);
  } catch (error) {
    if (current()) ctx.setData('externalError',error.message || '未能打开兑换地址，请重试。');
  } finally {
    s.externalBusy = false;
    if (market(ctx) === s) ctx.setData('externalBusy',false);
  }
}
fluxdo.on('buy',openExternalProduct);
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


// 买家业务仅属于士多插件，宿主不识别这些路由、字段和状态。
async function buyerRequest(ctx, path, method = 'GET', body, authenticated = true) {
  const response = await ctx.api.fetch(api + path, {
    method, ...(authenticated ? {credential:'account'} : {}),
    ...(body === undefined ? {} : {body}),
  });
  let result;
  try { result = response.json(); } catch (_) { throw Error('士多返回了无法识别的数据，请稍后重试'); }
  if (!response.ok || result.success !== true) {
    const message = typeof result.error === 'string' ? result.error : result.error?.message;
    const error = Error(response.status === 401 ? '登录已过期，请重新登录士多' : message || result.message || '请求失败（HTTP '+response.status+'）');
    error.status = response.status;
    throw error;
  }
  return normalizeOrderData(result.data);
}
function hasNextPage(paging, page, count) {
  return count > 0 && (paging?.hasMore === true || page < Number(paging?.totalPages) || page * 20 < Number(paging?.total));
}
function buyerRow(p) {
  return {id:String(p.id),title:display(p.name),image:display(p.imageUrl),
    price:money(p.finalPrice ?? p.price),stock:'库存 '+stockLabel({...p,stock_quantity:p.stockQuantity ?? p.stock_quantity})};
}
function couponRule(c) {
  if (c.discountType === 'fixed_amount') return '减 '+money(c.fixedAmount);
  if (c.discountType === 'percentage') return (Number(c.percentageBps) / 1000).toFixed(1)+' 折 · 仅优惠 1 件';
  return '优惠规则暂不可用';
}
function storeDate(value) {
  if (!value) return '—';
  let raw = value;
  if (typeof raw === 'string' && !/(Z|[+-]\d{2}:?\d{2})$/i.test(raw)) raw = raw.replace(' ','T')+'Z';
  const date = new Date(raw), time = date.getTime();
  return Number.isFinite(time) ? new Date(time+8*3600000).toISOString().slice(0,16).replace('T',' ')+'（北京时间）' : '—';
}
function couponRow(c, claim = {}) {
  claim = claim || {};
  const reserved = claim.claimStatus === 'reserved' || claim.status === 'reserved';
  const used = claim.claimStatus === 'used' || claim.status === 'used';
  return {id:String(claim.claimId ?? claim.id ?? c.id),title:display(c.name),rule:couponRule(c),
    seller:'卖家：'+display(c.sellerUsername),
    scope:c.scopeType === 'product' ? display(c.productName) || '指定商品' : '该卖家店铺内商品',
    minimum:Number(c.minSpend)>0 ? '满 '+money(c.minSpend) : '无门槛',
    starts:storeDate(c.startsAt),expires:storeDate(c.expiresAt),
    state:reserved ? '待支付订单占用' : used ? '已使用' : display(claim.invalidReason) || '',
    productId:c.scopeType === 'product' && c.productId != null ? String(c.productId) : '',
    sellerId:display(c.sellerUserId), sellerUsername:display(c.sellerUsername), sellerSite:display(c.sellerSite),
    orderNo:display(reserved ? claim.reservedOrderNo : used ? claim.usedOrderNo : ''),
    action:reserved || used ? '查看订单' : '查看适用商品'};
}
const couponTabs = [{value:'unused',label:'未使用'},{value:'used',label:'已使用'},{value:'expired',label:'已过期'}];
const refundReasons = [
  {value:'not_received_or_unusable',label:'未收到或无法使用'},
  {value:'not_as_described',label:'与物品描述不符'},
  {value:'duplicate_or_mistaken_purchase',label:'重复购买或误购'},
  {value:'seller_agreed',label:'卖家已同意退款'}, {value:'other',label:'其他问题'},
];
const refundLabels = {requested:'等待卖家处理',negotiating:'协商中',processing:'退款执行中',
  failed:'退款执行失败',unknown:'退款结果待核对',refunded:'已退款',rejected:'申请已拒绝',external_dispute:'已转 Credit 处理'};
const refundEvents = {requested:'提交退款申请',contacted:'卖家联系协商',contact_updated:'更新协商记录',
  approved:'卖家同意退款',rejected:'卖家拒绝申请',refund_succeeded:'退款成功',refund_failed:'退款执行失败',
  refund_unknown:'退款结果待核对',external_dispute_detected:'转 Credit 处理',response_timeout_approved:'超时自动同意退款',
  admin_approved:'管理员同意退款',admin_rejected:'管理员拒绝申请',admin_overridden:'管理员改判退款',
  automatic_refund_started:'超时保障退款',seller_refund_started:'卖家主动退款',response_policy_enrolled:'通知处理时限',
  response_deadline_reminder:'提醒处理时限',admin_retry_started:'管理员核查后重试',refund_admin_confirmed:'登记核对结果',
  admin_confirmed_refunded:'确认已退款',admin_confirmed_failed:'确认未完成退款',admin_confirmed_external_dispute:'确认转 Credit 处理'};
async function loadBuyerPage(ctx, more) {
  const s = market(ctx);
  if (!s || s.buyerBusy || (more && (s.loading || !s.more))) return;
  const revision = ++s.seq, current = () => market(ctx) === s && s.seq === revision;
  const page = more ? (s.page || 1) + 1 : 1;
  if (!more) {s.rows=[];s.more=false;}
  s.loading = true;
  write(ctx,{loading:!more,loadingMore:more,error:'',buyerError:'',needsSession:false,ready:false,more:false,rows:s.rows});
  try {
    const auth = await ldStore.status();
    if (!current()) return;
    write(ctx,{authorized:auth.authorized});
    if (!auth.authorized && !['coupon','merchant'].includes(ctx.page)) {
      write(ctx,{needsSession:true,error:'登录士多后继续',canApply:false}); return;
    }
    if (ctx.page === 'favorites' || ctx.page === 'coupons' || ctx.page === 'merchant') {
      const coupons = ctx.page === 'coupons';
      if (coupons) ctx.setData('tabs',couponTabs.map(t=>({...t,selected:t.value === (s.couponTab || 'unused')})));
      const data = await buyerRequest(ctx, ctx.page === 'merchant'
        ? '/merchants/'+encodeURIComponent(ctx.params.username)+'?'+params({page,site:ctx.params.site || '',userId:ctx.params.userId || ''})
        : coupons
        ? '/my-coupons?'+params({status:s.couponTab || 'unused',page,pageSize:20})
        : '/favorites?'+params({search:s.search,page,pageSize:20}), 'GET', undefined, auth.authorized);
      if(ctx.page==='merchant')ctx.setData('merchantTitle',display(data.merchant?.username)+' 的商品');
      if (!current()) return;
      const entries = coupons ? data.items : data.products;
      if (!Array.isArray(entries)) throw Error('列表数据格式有误');
      const rows = entries.map(row=>coupons ? couponRow(row.campaign || {},row) : buyerRow(row));
      const ids = new Set(s.rows.map(row=>row.id));
      s.rows=s.rows.concat(rows.filter(row=>!ids.has(row.id)));s.page=page;
      s.more=hasNextPage(data.pagination,page,rows.length);
      write(ctx,{ready:true,rows:s.rows,more:s.more});
    } else if (ctx.page === 'coupon') {
      const token = String(ctx.params.token || '');
      if (!/^[A-Za-z0-9_-]{1,256}$/.test(token)) throw Error('优惠券链接无效');
      const data = await buyerRequest(ctx, '/coupons/'+encodeURIComponent(token),'GET',undefined,auth.authorized);
      if (!current()) return;
      if (!data || data.id == null) throw Error('优惠券数据格式有误');
      s.coupon=data;
      const states = {scheduled:'尚未开始领取',expired:'优惠券已过期',paused:'卖家暂停领取',closed:'已停止领取',sold_out:'优惠券已领完',disabled:'优惠券已停用'};
      write(ctx,{ready:true,coupon:couponRow(data,data.claim),description:display(data.description),
        canClaim:data.claimable === true && !data.claimed,claimed:data.claimed === true,
        claimLabel:data.claimed ? '已领取' : states[data.state] || '领取优惠券'});
    } else if (ctx.page === 'comment') {
      const data = await buyerRequest(ctx, '/products/'+encodeURIComponent(ctx.params.id)+'/comments?page=1&pageSize=1');
      if (!current()) return;
      s.canComment=data.commentEnabled === true;
      s.canRate=data.viewerHasPurchased === true && data.viewerRating?.hasRated !== true;
      const fields=[{name:'content',label:'评论内容',hint:'分享使用体验或提出问题（5–500 字）',type:'multiline',required:true,maxLength:500}];
      if (s.canRate) fields.push({name:'rating',label:'商品评分（选填）',type:'choice',options:[{value:'',label:'不评分'},...Array.from({length:5},(_,i)=>({value:String(i+1),label:String(i+1)+' 星'}))]});
      write(ctx,{ready:true,canComment:s.canComment,fields,commentSubmitted:false,
        error:s.canComment ? '' : '该商品已关闭评论'});
    } else if (ctx.page === 'refund') {
      const data = await buyerRequest(ctx, '/orders/'+encodeURIComponent(ctx.params.no)+'/refund');
      if (!current()) return;
      if (!data || data.role !== 'buyer' || !data.eligibility || typeof data.eligibility.canApply !== 'boolean') throw Error('退款状态格式有误');
      const refund=data.refund;
      if (refund && String(refund.orderNo) !== String(ctx.params.no)) throw Error('退款订单号与请求不一致');
      s.refund=data;
      write(ctx,{ready:true,canApply:data.eligibility.canApply === true,
        refundState:refund ? refundLabels[refund.status] || '状态待核对' : '申请售后',
        refundAmount:refund ? money(refund.refundAmount) : '',refundMessage:display(data.eligibility.message),
        reason:display(refund?.reasonDetail),deadline:refund?.decisionDeadlineAt ? '处理时限：'+storeDate(refund.decisionDeadlineAt) : '',
        events:(refund?.events || []).slice().reverse().map(e=>({
          title:refundEvents[e.action] || '售后状态更新',message:display(e.message),time:storeDate(e.createdAt)})),
        refundFields:[{name:'reasonCode',label:'退款原因',type:'choice',required:true,options:refundReasons},
          {name:'reasonDetail',label:'问题描述',hint:'请说明具体问题（10–500 字）',type:'multiline',required:true,maxLength:500},
          {name:'buyerContactedSeller',label:'已联系卖家协商',type:'toggle',value:false}],
        hasGuide:typeof data.disputeGuideUrl === 'string' && data.disputeGuideUrl.startsWith('https://')});
    }
  } catch (error) {
    if (current()) write(ctx,{error:error.message,needsSession:error.status===401,more:s.more,canApply:false,
      ...(error.status===401 ? {authorized:false,rows:[]} : {})});
  } finally {if (current()) {s.loading=false;write(ctx,{loading:false,loadingMore:false});}}
}
async function buyerAction(ctx, action) {
  const s=market(ctx);
  if (!s || s.buyerBusy || s.hidden) return;
  s.buyerBusy=true;write(ctx,{buyerBusy:true,buyerError:''});
  try { await action(s); }
  catch(error) {if (market(ctx)===s) write(ctx,{buyerError:error.message,...(error.status===401 ? {authorized:false,needsSession:true} : {})});}
  finally {s.buyerBusy=false;if(market(ctx)===s) ctx.setData('buyerBusy',false);}
}
fluxdo.on('favorites',()=>fluxdo.navigate('favorites'));
fluxdo.on('coupons',()=>fluxdo.navigate('coupons'));
fluxdo.on('buyerRefresh',ctx=>loadBuyerPage(ctx,false));
fluxdo.on('buyerMore',ctx=>loadBuyerPage(ctx,true));
fluxdo.on('favoriteSearch',(ctx,a)=>{const s=market(ctx);if(s)s.search=String(a.value || '').slice(0,200);});
fluxdo.on('couponTab',(ctx,a)=>{const s=market(ctx);if(s && couponTabs.some(t=>t.value===a.value) && !s.loading) {s.couponTab=a.value;return loadBuyerPage(ctx,false);}});
fluxdo.on('favorite',ctx=>buyerAction(ctx,async s=>{
  if (!(await ldStore.status()).authorized) {ctx.setData('authorized',false);throw Error('请先登录士多');}
  await buyerRequest(ctx, '/products/'+encodeURIComponent(ctx.params.id)+'/favorite',s.favorited ? 'DELETE' : 'POST');
  s.favorited=!s.favorited;invalidateViews(s);
  write(ctx,{favoriteLabel:s.favorited ? '已收藏' : '收藏商品'});
}));
fluxdo.on('comment',ctx=>fluxdo.navigate('comment',{id:ctx.params.id}));
fluxdo.on('postComment',(ctx,a)=>buyerAction(ctx,async s=>{
  const content=String(a.values?.content || '').trim(),rating=Number(a.values?.rating);
  if (!s.canComment || content.length<5 || content.length>500) throw Error('请填写 5–500 字的评论');
  const body={content};
  if(s.canRate && Number.isInteger(rating) && rating>=1 && rating<=5) body.rating=rating;
  const result=await buyerRequest(ctx, '/products/'+encodeURIComponent(ctx.params.id)+'/comments','POST',body);
  invalidateViews(s);s.canComment=false;
  write(ctx,{commentSubmitted:true,canComment:false,commentResult:result?.message || '评论已提交，以士多审核结果为准'});
}));
fluxdo.on('claimCoupon',ctx=>buyerAction(ctx,async s=>{
  if (!s.coupon?.claimable || s.coupon.claimed) return;
  const result=await buyerRequest(ctx, '/coupons/'+encodeURIComponent(ctx.params.token)+'/claim','POST');
  if (!result?.claim || !result.campaign) throw Error('领取结果待确认，请刷新优惠券');
  s.coupon={...result.campaign,claimed:true,claim:result.claim};invalidateViews(s);
  write(ctx,{coupon:couponRow(result.campaign,result.claim),claimed:true,canClaim:false,claimLabel:'已领取'});
}));
fluxdo.on('couponUse',(ctx,a)=>{
  const s=market(ctx),row=ctx.page==='coupon' ? couponRow(s.coupon,s.coupon.claim) : s.rows.find(r=>r.id===a.id);
  if (!row) return;
  if (row.orderNo) return fluxdo.navigate('order',{no:row.orderNo});
  if (row.productId) return fluxdo.navigate('product',{id:row.productId});
  if (!row.sellerUsername) return fluxdo.navigate('market');
  return fluxdo.navigate('merchant',{username:row.sellerUsername,site:row.sellerSite,userId:row.sellerId});
});
fluxdo.on('refund',ctx=>fluxdo.navigate('refund',{no:ctx.params.no}));
fluxdo.on('applyRefund',(ctx,a)=>buyerAction(ctx,async s=>{
  const values=a.values || {},reason=String(values.reasonDetail || '').trim();
  if (!s.refund?.eligibility?.canApply) throw Error('当前订单不可提交新的退款申请');
  if (!refundReasons.some(r=>r.value===values.reasonCode) || reason.length<10 || reason.length>500) throw Error('请选择退款原因，并填写 10–500 字的问题描述');
  if (!await ctx.api.dialogs.confirm({title:'提交退款申请',message:'订单 '+ctx.params.no+'\n'+refundReasons.find(r=>r.value===values.reasonCode).label+'\n提交后由士多和卖家处理，可在这里查看进度。',confirmLabel:'确认提交'})) return;
  if (market(ctx)!==s) return;
  let note;
  try {
    await buyerRequest(ctx, '/orders/'+encodeURIComponent(ctx.params.no)+'/refund','POST',{
      reasonCode:values.reasonCode,reasonDetail:reason,buyerContactedSeller:values.buyerContactedSeller===true});
    invalidateViews(s);
  } catch(error) {
    // 发送后只查询状态，不自动重复提交。
    note=error.message+'。请核对最新售后状态后再操作。';
  }
  s.buyerBusy=false;
  await loadBuyerPage(ctx,false);
  if(note)ctx.setData('buyerError',note);
}));
fluxdo.on('refundGuide',ctx=>{const url=market(ctx)?.refund?.disputeGuideUrl;if(url)return fluxdo.browser.open(url,{mode:'inApp'});});

fluxdo.on('marketRetry',ctx=>load(ctx,(market(ctx)?.rows.length || 0)>0));
fluxdo.on('buyerRetry',ctx=>loadBuyerPage(ctx,(market(ctx)?.rows.length || 0)>0));
