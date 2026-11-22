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
      if (!await requestAccess(client,['identity','serviceAccount'])) throw Error('oauth_permission_denied');
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
      if (error.message === 'oauth_permission_denied') throw Error('未允许登录所需权限，再次点击登录可重新申请。');
      if (error.message === 'oauth_account_required') throw Error('请先登录 FluxDO 的 Linux DO 账号。');
      const reason = /^[a-z_0-9]+$/.test(error.message || '') ? error.message : 'request_failed';
      console.warn('login stage=' + stage + ' reason=' + reason);
      const label = {initialize:'服务初始化',authorization:'Connect 授权',callback:'服务回调',exchange:'会话交换',verification:'账号校验'};
      throw Error('登录在「' + label[stage] + '」阶段未完成，请重试。');
    }
  }

  async function status(withClaims=false) {
    if (loginTask) await loginTask.catch(() => false);
    const current = await fluxdo.credentials.status('account',withClaims ? {jwt:true} : undefined);
    const permissions = await fluxdo.permissions.status();
    if (!permissions.identity || !permissions.serviceAccount) current.authorized = false;
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
      if (result && result.state !== 'cancelled') {
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
// 一个脚本实例只持有一条消息流，页面切换时交给仍可见的界面。
let notificationOwner=null, notificationSync=null, notificationAgain=false, notificationBlocked=false;
let notificationRetryAt=0, notificationRetryTimer=null;
let notificationSummary=null, notificationRevision=0, notificationFallback=null;
function visibleNotificationView() {
  return [...views.values()].find(s=>s.ctx && !s.hidden) || null;
}
function stopNotificationFallback() {
  if(notificationFallback)clearTimeout(notificationFallback);
  notificationFallback=null;
}
function scheduleNotificationFallback() {
  stopNotificationFallback();
  if(!notificationOwner || notificationBlocked || typeof setTimeout!=='function')return;
  notificationFallback=setTimeout(async()=>{
    notificationFallback=null;
    const owner=notificationOwner;
    try {await refreshNotificationSnapshot(owner);await updateMessageViews(false);} catch(_) {}
    if(owner===notificationOwner)scheduleNotificationFallback();
  },60000);
}
function setNotificationSummary(value) {
  if(!value || typeof value!=='object')return;
  value=normalizeOrderData(value);notificationSummary=value;notificationRevision++;
  for(const s of views.values()) {
    if(!s.ctx)continue;
    if(s.overviewStats) {
      s.overviewStats=s.overviewStats.map(stat=>stat.label==='未读消息' ? {...stat,value:display(Math.max(0,Number(value.totalUnread)||0))} : stat);
      s.ctx.setData('stats',s.overviewStats);
    }
    if(s.ctx.page==='messages')s.ctx.setData('unread',(Number(value.systemUnread)||0)>0);
  }
}
async function refreshNotificationSnapshot(owner) {
  if(!owner || owner!==notificationOwner || market(owner.ctx)!==owner || owner.hidden)return;
  const revision=notificationRevision;
  const value=await read('/messages/unread-summary',true);
  if(owner===notificationOwner && !owner.hidden && revision===notificationRevision)setNotificationSummary(value);
}
function messageSignature(rows) {
  return JSON.stringify(rows.map(m=>[String(m.id),m.title,m.content,flag(m.isRead ?? m.is_read ?? m.read),m.link]));
}
async function updateMessageViews(changed=true) {
  await Promise.all([...views.values()].filter(s=>s.ctx?.page==='messages').map(async s=>{
    s.messagesCheckPending=true;
    if(changed) {
      s.messagesRevision=(s.messagesRevision || 0)+1;
      if(s.messagesLoaded && (s.hidden || s.page>1)) {
        s.messagesChanged=true;s.ctx.setData('messagesChanged',true);
      }
    }
    await syncMessageView(s);
  }));
}
async function syncMessageView(s) {
  if(s.hidden || s.loading || s.buyerBusy || (s.page>1 && s.messagesChanged) || !s.messagesCheckPending || market(s.ctx)!==s)return;
  s.messagesCheckPending=false;
  await loadMessages(s.ctx,false,true);
}
function waitNotificationRetry(delay) {
  if(notificationRetryTimer)clearTimeout(notificationRetryTimer);
  notificationRetryTimer=setTimeout(()=>{
    notificationRetryTimer=null;notificationRetryAt=0;syncNotifications();
  },delay);
}
async function syncNotifications() {
  notificationAgain=true;
  if(notificationSync)return notificationSync;
  notificationSync=(async()=>{
    while(notificationAgain) {
      notificationAgain=false;
      const next=visibleNotificationView();
      if(next===notificationOwner)continue;
      const previous=notificationOwner;notificationOwner=null;stopNotificationFallback();
      if(previous) {try {await previous.ctx.api.streams.close('notifications');} catch(_) {}}
      if(!next || notificationBlocked || !next.ctx.api.streams)continue;
      if(Date.now()<notificationRetryAt) {
        if(!notificationRetryTimer)waitNotificationRetry(notificationRetryAt-Date.now());
        continue;
      }
      const status=await next.ctx.api.credentials.status('account');
      if(!status.authorized || market(next.ctx)!==next || next.hidden)continue;
      notificationOwner=next;
      try {
        await next.ctx.api.streams.open({id:'notifications',url:api+'/notifications/stream',credential:'account',headers:{Origin:'https://ldcstore.com'}});
      } catch(_) {if(notificationOwner===next)scheduleNotificationFallback();}
    }
  })().catch(()=>{}).finally(()=>{notificationSync=null;});
  return notificationSync;
}
fluxdo.on('stream.event',(ctx,args)=>{
  if(args.id!=='notifications' || notificationOwner?.ctx.surface!==ctx.surface || notificationOwner.hidden)return;
  let value;try {value=JSON.parse(args.data);} catch(_) {return;}
  if(args.event==='stream.closed' && typeof setTimeout==='function') {
    const delay=Math.max(value.reason==='connection_limit' ? 60000 : 1000,Math.min(3600000,Number(value.retryAfterMs)||0));
    notificationRetryAt=Date.now()+delay;
    const owner=notificationOwner;notificationOwner=null;stopNotificationFallback();
    owner.ctx.api.streams.close('notifications').catch(()=>{});
    waitNotificationRetry(delay);return;
  }
  if(args.event==='summary.updated')setNotificationSummary(value);
  if(args.event==='system-message.changed')return updateMessageViews().catch(()=>{});
});
fluxdo.on('stream.state',(ctx,args)=>{
  const owner=notificationOwner;
  if(args.id!=='notifications' || owner?.ctx.surface!==ctx.surface || owner.hidden)return;
  if(args.state==='open') {
    stopNotificationFallback();
    // 补查摘要和已打开的消息页，恢复断线期间的遗漏；不刷新商品或重置订单。
    return Promise.all([refreshNotificationSnapshot(owner),updateMessageViews(false)]).catch(()=>{});
  } else if(args.state==='retrying')scheduleNotificationFallback();
  else if(args.state==='closed') {
    if(args.status===401 || args.status===403 || /credential/.test(args.reason || '')) {
      notificationBlocked=true;stopNotificationFallback();
      for(const s of views.values())if(s.ctx?.page==='messages'){
        s.seq++;s.rows=[];s.more=false;s.loading=false;s.messagesChanged=false;s.messagesLoaded=false;s.messagesCheckPending=false;
        write(s.ctx,{rows:[],more:false,loading:false,loadingMore:false,messagesChanged:false,needsSession:true,authorized:false,error:'士多会话已失效，请重新登录。'});
      }
    } else scheduleNotificationFallback();
  }
});

const money = n => n!=null && n!=='' && Number.isFinite(Number(n)) ? Number(n).toFixed(2) + ' LDC' : '—';
const display = v => v == null ? '' : String(v);
const flag = v => v === true || v === 1 || v === '1' || v === 'true';
function stockValue(p) {
  p=normalizeOrderData(p);
  const candidates = [p.availableStock,p.available_stock,p.cdkStats && p.cdkStats.available,p.stock,p.stockQuantity,p.stock_quantity];
  const direct=candidates.slice(0,3).find(v=>v!=null && v!=='');
  if(direct==null && p.productType==='cdk' && Number(p.cdkStats?.total)===-1)return -1;
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
async function readPublic(path,session) {
  const auth=session || await ldStore.status();
  try {return await read(path,auth.authorized);}
  catch(error) {
    if(!auth.authorized || error.status!==401)throw error;
    auth.authorized=false;
    return read(path,false);
  }
}
function write(ctx, values) {
  for (const key of Object.keys(values)) ctx.setData(key, values[key]);
}
function market(ctx) {
  return views.get(ctx.surface);
}
function invalidateViews(except, affected=()=>true) {
  for (const state of views.values()) {
    if (state !== except && affected(state)) state.dirty = true;
  }
}
function orderChanged(order,except) {
  const no=order?.orderNo || order?.order_no;
  // 已加载列表直接替换该笔订单，保留分页与滚动；再次兑换时由详情和核价重新检查资格。
  for(const s of views.values()) {
    if(s===except || !s.ctx)continue;
    const page=s.ctx.page;
    if(page==='orders' && no && order.status) {
      const row=orderSummary(normalizeOrderData(order));
      s.rows=(s.rows || []).flatMap(old=>old.no!==no ? [old] :
        s.orderStatus && !s.orderStatus.split(',').includes(order.status) ? [] : [{...old,...row,image:row.image || old.image}]);
      s.ctx.setData('rows',s.rows);
    } else if(page==='order' && s.ctx.params.no===no) s.dirty=true;
    else if(page==='account' || page==null || page==='coupons') s.dirty=true;
  }
}
function refreshView(ctx) {
  const s = market(ctx);
  if (!s || s.hidden || s.paymentBusy || s.orderBusy) return;
  s.dirty = false;
  if (['favorites','coupons','coupon','refund','comment','merchant'].includes(ctx.page)) return loadBuyerPage(ctx,false);
  if (ctx.page === 'order' || ctx.page === 'orders') return loadOrders(ctx,false);
  if (ctx.page === 'review' || ctx.page === 'product') return detail(ctx);
  if (ctx.page === 'account' || ctx.page == null) return loadOverview(ctx);
  if (ctx.page === 'messages') return loadMessages(ctx,false);
  if(s.categoriesDirty){s.categoriesDirty=false;return Promise.all([categories(ctx),load(ctx,false)]);}
  return load(ctx,false);
}
function productView(raw) {
  const p=normalizeOrderData(raw), base=p.price==null || p.price==='' ? NaN : Number(p.price), rawDiscount=Number(p.discount);
  // 列表投影省略封面时，不能把它当成商品详情已经确认无图。
  const image=mediaUrl(p.imageUrl) || cachedProductImage(p.id);if(p.id!=null && image)rememberProductImage(String(p.id),image);
  const discount=rawDiscount>0 && rawDiscount<=1 ? rawDiscount : 1;
  const value=p.finalPrice == null || p.finalPrice==='' ? base*discount : Number(p.finalPrice);
  const original=Number.isFinite(base) && base>value ? base.toFixed(2) : '';
  const type=p.productType || p.type || 'normal';
  return {id:display(p.id),title:display(p.name),image,hiddenItem:false,preferenceTime:'',
    price:money(value),value:Number.isFinite(value) ? value.toFixed(2) : '—',original,
    discount:original ? Math.round((1-value/base)*100)+'% 优惠' : '',originalLabel:original ? '原价 '+original : '',
    type, typeLabel:({cdk:'自动发卡',normal:flag(p.autoDelivery) ? '自动发货' : '手动发货',link:'外链商品',store:'小店'})[type] || '商品',
    listingNote:[p.duoPromotion?.kind==='paid' ? '广告' : '',flag(p.isPinned) && flag(p.pinIsPaid) ? (p.pinType==='category' ? '士多优选' : '士多甄选') : '',flag(p.isTestMode) ? '测试商品' : ''].filter(Boolean).join(' · '),
    typeIcon:({cdk:'key',normal:'gift',link:'link',store:'storefront'})[type] || 'gift',
    category:display(p.categoryName), stock:'库存 '+stockLabel(p),sold:'已售 '+display(p.soldCount ?? 0),
    sellerName:display(p.sellerName || p.sellerUsername),sellerUsername:display(p.sellerUsername),sellerAvatar:accountAvatar({avatar:p.sellerAvatar,avatarUrl:p.sellerAvatarUrl}),
    availability:({offline:'已下架',inactive:'已下架',offline_manual:'已下架',pending:'审核中',pending_ai:'审核中',pending_manual:'待人工审核',rejected:'已拒绝',ai_rejected:'已拒绝',manual_rejected:'已拒绝'})[p.status] || '',
    test:flag(p.isTestMode),info:money(value)+' · 库存 '+stockLabel(p)};
}
const sortOptions = [
  {label:'默认排序',sort:'updated_at',direction:'DESC'},{label:'最新',sort:'created_at',direction:'DESC'},
  {label:'低价',sort:'final_price',direction:'ASC'},{label:'高价',sort:'final_price',direction:'DESC'},
  {label:'热销',sort:'sold_count',direction:'DESC'}
];
const slateIdPattern=/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i;
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
  if (s.searchTimer) {clearTimeout(s.searchTimer);s.searchTimer=null;}
  const seq = ++s.seq;
  const page = more ? s.page + 1 : 1;s.marketRetryMore=more;
  const queryKey=JSON.stringify([s.search,s.cat,s.sort,s.direction,s.stock,s.min,s.max]);
  if (!more && s.queryKey!==queryKey) {s.rows=[];s.more=false;s.cursor='';s.page=0;}
  s.queryKey=queryKey;
  s.loading = true;
  write(ctx, {loading:!more, loadingMore:more, more:false, message:'', webFallback:false, rows:s.rows});
  try {
    const defaultSort=!s.sort || s.sort==='updated_at';
    const q = {pageSize:12, search:s.search, categoryId:s.cat, inStock:s.stock?'true':'',
      sortBy:defaultSort ? '' : s.sort, sortOrder:defaultSort ? '' : s.direction, priceMin:s.min, priceMax:s.max};
    if (more && s.cursor) q.cursor = s.cursor; else q.page = page;
    if (defaultSort || s.search) q.ranking = 'auto';
    const rotating=defaultSort && !s.search && !more;
    if(rotating){
      const rotation=await ctx.api.crypto.uuid();
      if(seq!==s.seq || market(ctx)!==s)return;
      if(slateIdPattern.test(rotation))q.rotationId=rotation;
      const last=s.slates?.get(queryKey);if(last?.expires>Date.now())q.previousSlateId=last.id;
    }
    const result = await readPublic('/products?' + params(q));
    if (market(ctx) !== s || seq !== s.seq) return;
    const products = result.products;
    if (!Array.isArray(products)) throw Error('商品列表格式有误');
    const seen = new Set(more ? s.rows.map(r => r.id) : []);
    const rows = products.filter(product=>{if(product?.id==null || seen.has(String(product.id)))return false;seen.add(String(product.id));return true;}).map(productView);
    s.rows = more ? s.rows.concat(rows) : rows; s.page = page;
    const paging = result.pagination || {};
    s.cursor = paging.nextCursor || '';
    if(rotating && slateIdPattern.test(result.rankingContext?.slateId)){
      s.slates=s.slates || new Map();s.slates.delete(queryKey);s.slates.set(queryKey,{id:result.rankingContext.slateId,expires:Date.now()+1800000});
      if(s.slates.size>20)s.slates.delete(s.slates.keys().next().value);
    }
    s.more = typeof paging.hasMore === 'boolean' ? paging.hasMore :
      !!s.cursor || page < Number(paging.totalPages) || page * 12 < Number(paging.total);
    write(ctx,{rows:s.rows, more:s.more, message:'',total:display(paging.total ?? s.rows.length)+' 件商品'});
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
    const data = await readPublic('/categories');
    if (!current()) return;
    s.categories = base.concat(data.categories.map(c => ({id:String(c.id),name:c.name})));
    showFilters(ctx,s);ctx.setData('categoryMessage','');
  } catch (_) {if (current()) ctx.setData('categoryMessage','分类加载失败，可刷新重试');}
}
async function detail(ctx) {
  const s = market(ctx);
  if (!s) return;
  s.quoteEnabled = false;
  clearQuote(ctx,s,!!s.product);
  const seq = ++s.seq;
  write(ctx,{ready:!!s.product,initialLoading:!s.product,loading:true,error:'',externalError:'',buy:false});
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
      productData = await read(path,false);ctx.setData('authorized',false);
    }
    const p = normalizeOrderData(productData.product);
    if (seq !== s.seq || market(ctx) !== s) return;
    if (!p || p.id == null || String(p.id) !== String(ctx.params.id)) throw Error('找不到这件商品');
    s.id = String(p.id);
    s.favorited = p.isFavorited === true;
    write(ctx,{favorited:s.favorited,favoriteLabel:s.favorited ? '已收藏' : '收藏商品',buyerError:''});
    s.product=p;
    s.linkProduct = ['link','store'].includes(p.productType || p.type);
    ctx.setData('linkProduct',s.linkProduct);
    if (s.linkProduct && !s.record?.productId) ctx.setData('nativeOrder',false);
    const bounds = purchaseBounds(s.product,s.linkProduct);
    const currentAccount = auth.authorized ? await ctx.api.user.get() : null;
    if (seq !== s.seq || market(ctx) !== s) return;
    const own = !!currentAccount && (!p.sellerSite || p.sellerSite==='linux.do') && String(p.sellerUserId)===String(currentAccount.id);
    let blocked = !s.linkProduct && stockValue(s.product)===0 ? '已售罄' : !bounds.buy ? '当前不可兑换' : '';
    if (!s.linkProduct && flag(p.isTestMode) && !own) blocked='测试中，仅卖家可兑换';
    if (!s.linkProduct && !flag(p.isTestMode) && own) blocked='不能兑换自己的商品';
    // 有登录态时核对士多认可的等级，最终库存和购买限制仍以核价接口为准。
    const required=Number(s.product.purchaseTrustLevel || 0);
    if (required>0 && auth.authorized) {
      try {
        const viewer=normalizeOrderData(await read('/auth/verify',true));
        if (Number(viewer.user?.trustLevel ?? viewer.trustLevel ?? 0)<required) blocked='需要信任等级 TL'+required;
      } catch (_) { blocked='暂时无法核对购买资格，请刷新重试'; }
      if (seq !== s.seq || market(ctx) !== s) return;
    }
    bounds.buy = !blocked && (s.linkProduct || bounds.buy);
    const view=productView(p);
    write(ctx,{...view,product:view,buyLabel:blocked || (s.linkProduct ? '查看兑换方式' : '立即兑换'),
      quantityValue:s.quantity || 1,quantityMax:bounds.limit,
      rules:[bounds.label, required>0 ? '需要信任等级 TL'+required : '', flag(p.isTestMode) ? '测试商品' : ''].filter(Boolean),
      sellerProfileAvailable:!!p.sellerUsername && (!p.sellerSite || p.sellerSite==='linux.do'),
      metrics:[{label:'库存',value:stockLabel(p)},{label:'已售',value:display(s.product.soldCount ?? 0)},{label:'浏览',value:display(s.product.viewCount ?? 0)}],
      listedAt:s.product.createdAt ? '上架于 '+storeDate(s.product.createdAt) : ''});
    s.buy = bounds.buy;
    const unit = Number(view.value);
    s.unit = Number.isFinite(unit) && unit >= 0 ? unit : NaN;
    s.limit = bounds.limit;
    s.quantity = Math.max(1,Math.min(s.quantity || 1,s.limit));
    s.quoteEnabled = ctx.page === 'review' && s.buy && !s.linkProduct && auth.authorized && (auth.queries || []).includes('orderQuote');
    clearQuote(ctx,s,!!s.quoteDisplayed && s.quoteEnabled);
    write(ctx,{ready:true,initialLoading:false,title:display(p.name),description:display(p.description),image:view.image,
      seller:'卖家：' + (display(p.sellerName || p.sellerUsername) || '未提供'),
      price:money(s.unit),canAdd:s.buy && s.quantity < s.limit,canRemove:s.buy && s.quantity > 1,
      quantity:String(s.quantity),quantityValue:s.quantity,quantityMax:s.limit,estimate:money(s.unit*s.quantity),
      details:display(p.categoryName) + ' · 库存 ' + stockLabel(p) +
        ' · 已售 ' + display(p.soldCount),
      conditions:'等级要求 TL' + display(p.purchaseTrustLevel || 0) +
        (bounds.label ? ' · ' + bounds.label : '') +
        (flag(p.autoDelivery) ? ' · 自动交付' : ''), buy:s.buy});
    if (s.quoteEnabled && (!s.record || s.record.state === 'idle')) await quote(ctx);
    if (ctx.page === 'product') loadComments(ctx,false);
  } catch (e) {if (seq === s.seq) ctx.setData('error',String(e.message));}
  finally {if (seq === s.seq) write(ctx,{loading:false,initialLoading:false});}
}
async function loadComments(ctx,more) {
  const s = market(ctx);
  if (!s || ctx.page !== 'product' || (more && s.commentsLoading)) return;
  const revision = s.commentsRevision = (s.commentsRevision || 0) + 1;
  const current = () => market(ctx) === s && s.commentsRevision === revision;
  const page = more ? (s.commentsPage || 1) + 1 : 1;s.commentsRetryMore=more;
  s.commentsLoading = true;
  write(ctx,{commentsLoading:true,commentsError:''});
  try {
    const data = normalizeOrderData(await readPublic('/products/' + encodeURIComponent(ctx.params.id) +
      '/comments?page=' + page + '&pageSize=10'));
    if (!current()) return;
    if (!Array.isArray(data.comments)) throw Error('评论数据格式有误');
    const visible=data.commentEnabled===false ? [] : data.comments;
    const rows = visible.map(c => ({...commentRow(c),replyCount:Number(c.replyCount || 0),
      replyLabel:Number(c.replyCount)>0 ? '查看 '+c.replyCount+' 条回复' : '',replies:[],repliesOpen:false,repliesLoading:false,repliesMore:false,repliesError:'',repliesEmpty:false}));
    const previous = more && data.commentEnabled!==false ? s.comments || [] : [];
    s.comments = mergeRows(previous,rows);
    s.commentsPage = page;
    const paging = data.pagination || {};
    const summary=data.summary || {};
    write(ctx,{comments:s.comments,commentsMore:hasNextPage(paging,page,rows.length,10),commentStatsReady:!!data.summary,
      commentStats:[{label:'评分',value:Number(summary.ratedCount)>0 ? Number(summary.averageRating).toFixed(1)+' / 5' : '暂无'},
        {label:'已评分',value:display(summary.ratedCount ?? 0)},{label:'收藏',value:display(summary.favoriteCount ?? 0)},
        {label:'评论 / 回复',value:display(summary.visibleCommentCount ?? paging.total ?? 0)+' / '+display(summary.visibleReplyCount ?? 0)}],
      canComment:data.commentEnabled === true,
      commentsMessage:data.commentEnabled === false ? display(data.disabledReason) || '该商品已关闭评论' : s.comments.length ? '' : '暂无评论'});
  } catch (e) {
    if (current()) ctx.setData('commentsError',String(e.message));
  } finally {
    if (current()) {s.commentsLoading = false;ctx.setData('commentsLoading',false);}
  }
}
function commentRow(c) {
  const user=c.user || c;
  const rating=c.ratingValue ?? c.rating;
  return {id:String(c.id),author:display(user.nickname || user.username || c.nickname || c.username) || '用户',
    handle:user.nickname && user.username && user.nickname!==user.username ? '@'+user.username : '',
    avatar:accountAvatar(user) || accountAvatar(c),time:storeTime(c.createdAt),content:display(c.content),
    badge:[flag(c.isSeller) ? '卖家' : '',flag(c.isPurchased) ? '已购' : ''].filter(Boolean).join(' · '),
    rating:flag(c.isPurchased) && Number(rating)>=1 && Number(rating)<=5 ? String(rating)+' / 5' : '',
    moderation:({pending:'审核中',pending_ai:'审核中',pending_manual:'人工审核中',ai_rejected:'未通过审核',manual_rejected:'未通过审核',rejected:'未通过审核'})[c.status] || ''};
}
async function loadReplies(ctx,id,more=false) {
  const s=market(ctx),row=s?.comments?.find(c=>c.id===id);
  if(!row || row.repliesLoading || more && !row.repliesMore || s.hidden)return;
  const current=()=>market(ctx)===s && s.comments.includes(row);
  const page=more ? row.repliesPage+1 : 1;
  row.repliesOpen=true;row.repliesLoading=true;row.repliesError='';ctx.setData('comments',s.comments);
  try {
    const data=normalizeOrderData(await readPublic('/comments/'+encodeURIComponent(id)+'/replies?page='+page+'&pageSize=10'));
    if(!current())return;
    if(!Array.isArray(data.replies))throw Error('回复数据格式有误');
    row.replies=mergeRows(more ? row.replies : [],data.replies.map(commentRow));
    row.repliesPage=page;row.repliesMore=hasNextPage(data.pagination,page,data.replies.length,10);
    row.repliesEmpty=row.replies.length===0;
  } catch(error) {if(current())row.repliesError=error.message;}
  finally {if(current()){row.repliesLoading=false;ctx.setData('comments',s.comments);}}
}
fluxdo.on('commentReplies',(ctx,a)=>loadReplies(ctx,a.id,a.more===true));
fluxdo.on('commentsRetry',ctx => loadComments(ctx,market(ctx)?.commentsRetryMore===true));
fluxdo.on('commentsMore',ctx => loadComments(ctx,true));
// 分页失败可以继续读同一页，授权失效则清空上一账号的数据。
const statusLabels = {pending:'待付款',pending_payment:'待付款',paying:'支付中',creating:'正在创建支付',confirming:'支付确认中',paid:'待发货',
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
function mediaUrl(value) {
  if(typeof value!=='string')return '';
  const url=value.trim();if(!url || url.length>8192)return '';
  if(url.startsWith('//'))return 'https:'+url;
  if(url.startsWith('/'))return 'https://ldcstore.com'+url;
  return /^https?:\/\/[^/\s]+\//i.test(url) ? url : '';
}
// 订单只保证商品标识。复用已浏览商品的图片，缺失时按商品合并公开查询。
const productImages=new Map();let imageSession=0;
function rememberProductImage(id,url,ttl=600000) {
  productImages.delete(id);productImages.set(id,{url,expires:Date.now()+ttl});
  while(productImages.size>128)productImages.delete(productImages.keys().next().value);
  return url;
}
function cachedProductImage(id) {
  const entry=productImages.get(String(id));return entry?.expires>Date.now() ? entry.url : '';
}
let imageWorkers=0;
const imageQueue=[],imageRequests=new Map();
function lookupProductImage(id,current) {
  const pending=imageRequests.get(id);
  if(pending){pending.watchers.push(current);return pending.promise;}
  const cached=productImages.get(id);
  if(cached?.expires>Date.now())return Promise.resolve(cached.url);
  const task={id,session:imageSession,watchers:[current]};task.promise=new Promise(resolve=>{task.resolve=resolve;});
  imageRequests.set(id,task);imageQueue.push(task);drainProductImages();return task.promise;
}
function drainProductImages() {
  while(imageWorkers<3 && imageQueue.length) {
    const item=imageQueue.shift();
    if(item.session!==imageSession || !item.watchers.some(current=>current())){if(imageRequests.get(item.id)===item)imageRequests.delete(item.id);item.resolve('');continue;}
    imageWorkers++;
    readPublic('/products/'+encodeURIComponent(item.id)).then(data=>{
      const p=normalizeOrderData(data.product);
      return item.session===imageSession ? rememberProductImage(item.id,String(p?.id)===item.id ? mediaUrl(p.imageUrl) : '') : '';
    }).catch(()=>item.session===imageSession ? rememberProductImage(item.id,'',60000) : '').then(url=>{
      if(imageRequests.get(item.id)===item)imageRequests.delete(item.id);imageWorkers--;item.resolve(url);drainProductImages();
    });
  }
}
function fillOrderImages(ctx,s) {
  const seq=s.seq,current=()=>market(ctx)===s && s.seq===seq && !s.hidden;
  const rows=ctx.page==='order' && s.order ? [orderSummary(s.order)] : s.rows || [];
  if(ctx.page==='order' && rows[0]?.image && current())ctx.setData('orderImage',rows[0].image);
  for(const row of rows) {
    if(row.image || !/^[A-Za-z0-9_-]{1,128}$/.test(row.productId))continue;
    lookupProductImage(row.productId,current).then(url=>{
      if(!current())return;
      if(ctx.page==='order')write(ctx,{orderImage:url,orderImageLoading:false});
      else {s.rows=s.rows.map(r=>r.productId===row.productId && !r.image ? {...r,image:url,imageLoading:false} : r);ctx.setData('rows',s.rows);}
    });
  }
}
function orderSummary(o) {
  if (!o || typeof o.orderNo !== 'string' || !o.orderNo || typeof o.status !== 'string') {
    throw Error('订单数据格式有误');
  }
  const status = o.displayStatus || o.status;
  const amount = o.amount == null ? o.totalPrice : o.amount;
  const productId=display(o.productId || o.product?.id);
  const image=mediaUrl(o.product?.imageUrl || o.productImage || o.productImageUrl || o.imageUrl) || cachedProductImage(productId);
  return {no:o.orderNo, title:display(o.product && o.product.name || o.productName) || '商品订单',
    state:Object.prototype.hasOwnProperty.call(statusLabels,status) ? statusLabels[status] : '未知状态',
    amount:amount == null || amount === '' ? '—' : money(amount),
    image,imageLoading:!image && /^[A-Za-z0-9_-]{1,128}$/.test(productId) && !(productImages.get(productId)?.expires>Date.now()),
    productId,seller:display(o.sellerNickname || o.sellerName || o.sellerUsername || o.seller?.username),
    quantity:'× '+display(o.quantity ?? o.productQuantity ?? 1),created:storeDate(o.createdAt),time:storeTime(o.createdAt)};
}
function orderParty(order,role) {
  const handle=display(order[role+'Username'] || order[role]?.username).trim().replace(/^@+/,''),name=display(order[role+'Nickname'] || order[role+'Name']).trim();
  return [name && name.replace(/^@+/,'').toLowerCase()!==handle.toLowerCase() ? name : '',handle ? '@'+handle : ''].filter(Boolean).join(' · ');
}
async function loadOrders(ctx, append, silent=false) {
  const s = market(ctx), detailPage = ctx.page === 'order';
  if (!s || (append && (s.loading || !s.more || detailPage))) return;
  const seq = ++s.seq, current = () => market(ctx) === s && seq === s.seq;
  if (!silent) s.revealed = false;
  const page=append ? (s.page || 0)+1 : 1;
  s.ordersRetryMore=append;
  if(!detailPage && s.ordersQuery!==s.orderStatus){s.rows=[];s.more=false;s.ordersQuery=s.orderStatus;}
  s.loading = true;
  if (!silent) write(ctx,{loading:!append,loadingMore:append,initialLoading:detailPage && !s.order,ready:!!s.order,needsSession:false,error:'',empty:false,rows:s.rows,more:false,
    hasDelivery:!!s.deliveryText,deliveryText:'',deliveryAction:'查看交付内容'});
  const sessionMissing = message => {
    clearOrderData(ctx,s);write(ctx,{needsSession:true,authorized:false,error:message});
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
      const previous=s.order;
      s.order=data.order;
      if(previous && previous.status!==data.order.status)orderChanged(data.order,s);
      const delivery = data.order.deliveryType;
      const rawContent = data.order.cdk || data.order.deliveryContent;
      const content = Array.isArray(rawContent) ? rawContent.filter(x=>typeof x==='string').join('\n') : rawContent;
      const awaiting=['pending','pending_payment','paying'].includes(data.order.status);
      const confirming=['pending','creating','unknown'].includes(data.order.paymentInitStatus);
      let snapshot=data.order.couponSnapshot || {};
      if(typeof snapshot==='string') {try {snapshot=normalizeOrderData(JSON.parse(snapshot));} catch (_) {snapshot={};}}
      const count=Number(data.order.quantity ?? data.order.productQuantity),quantity=Number.isSafeInteger(count) && count>0 ? count : 1;
      const total=Number(data.order.productSubtotal ?? data.order.amount ?? data.order.totalPrice);
      const listed=Number(data.order.product?.price),original=Number(data.order.originalPrice) || listed*quantity;
      const couponDiscount=Number(data.order.couponDiscountAmount ?? snapshot.couponDiscountAmount ?? 0);
      const unitPrice=listed>0 ? listed : original/quantity,rate=Number(data.order.product?.discount);
      const reducedUnit=rate>0 && rate<1 ? unitPrice*rate : data.order.productSubtotal!=null && original>total ? total/quantity : unitPrice;
      const fields=[['数量',String(quantity)],...(unitPrice>0 ? [['商品单价',money(unitPrice)]] : []),
        ...(reducedUnit>=0 && reducedUnit<unitPrice ? [['折后单价',money(reducedUnit)]] : []),['商品小计',money(total)],
        ...(original>total ? [['商品优惠','− '+money(original-total)]] : []),
        ...(couponDiscount>0 ? [['优惠券',display(snapshot.name) || '已使用优惠券'],...(snapshot.discountType ? [['用券规则',couponRule(snapshot)]] : []),['优惠金额','− '+money(couponDiscount)]] : []),
        ['应付积分',row.amount],...['seller','buyer'].map(role=>[role==='seller' ? '卖家' : '买家',orderParty(data.order,role)]).filter(([,value])=>value)].map(([label,value])=>({label,value}));
      const times=[['创建时间',data.order.createdAt],['支付时间',data.order.paidAt || data.order.paidTime],['发货截止',data.order.fulfillment?.deadlineAt || data.order.fulfillmentDeadlineAt],['发货时间',data.order.deliveredAt],['完成时间',data.order.completedAt],['取消时间',data.order.cancelledAt],['退款时间',data.order.refundedAt]]
        .filter(([,time])=>!!time).map(([label,time])=>({label,value:storeDate(time)}));
      const logs={create:'创建订单',pay:'支付成功',deliver:'发货完成',complete:'确认收货',cancel:'取消订单',expire:'订单过期',refund:'订单退款',refund_request:'申请退款',refund_reject:'拒绝退款',repay:'重新发起支付',lock_cdk:'锁定卡密',unlock_cdk:'释放卡密',admin_complete:'管理员完结'};
      const deadline=data.order.payExpiredAt || data.order.expireAt || data.order.expiredAt;
      write(ctx,{orderImage:row.image,orderImageLoading:row.imageLoading,productId:row.productId,quantity:row.quantity,sellerName:row.seller,fields,times,
        tradeNo:display(data.order.ldcTradeNo),usage:display(data.order.product?.description || data.order.productDescription),
        orderEvents:latestEvents(data.logs).map(e=>({title:logs[e.action] || display(e.action) || '订单更新',message:display(e.remark || e.note || e.message),time:storeDate(e.createdAt || e.time)})),
        statusNote:awaiting ? confirming ? '支付结果确认中，请勿重复兑换。' : deadline ? '请在 '+storeDate(deadline)+' 前完成付款' : '订单待付款，付款后将按商品约定交付。' : data.order.status==='paid' ? '付款已确认，等待交付。' : '',
        canCheck:awaiting,canRepurchase:!!row.productId,canCancel:awaiting && !confirming});
      s.deliveryText = ['delivered','completed'].includes(data.order.status) && typeof content==='string' ? content : '';
      if(!s.deliveryText)s.revealed=false;
      write(ctx,{ready:true,orderTitle:row.title,orderNo:row.no,state:row.state,amount:row.amount,
        canPay:auth.paymentSupported && ['pending','pending_payment'].includes(data.order.status) && !confirming,
        paymentAvailable:!s.paymentBusy,cancelLabel:'取消订单',
        hasDelivery:!!s.deliveryText,
        deliveryText:s.revealed ? s.deliveryText : '',error:'',
        delivery:delivery === 'auto' || data.order.productType==='cdk' ? '自动发货' : '手动发货'});
      scheduleOrderPoll(ctx,s);
    } else {
      const data = normalizeOrderData(
        await read('/orders?' + params({
          role: 'buyer', page: page, pageSize: 20, status: s.orderStatus || ''
        }), true)
      );
      if (!current()) return;
      if (!Array.isArray(data.orders) || !data.pagination) throw Error('订单列表格式有误');
      const rows = data.orders.map(orderSummary), seen = new Set(append ? s.rows.map(r => r.no) : []);
      if(!append)s.rows=[];
      for (const row of rows) {
        if (seen.has(row.no)) continue;
        seen.add(row.no); s.rows.push(row);
      }
      s.page = page;
      s.more = hasNextPage(data.pagination,page,rows.length);
      write(ctx,{rows:s.rows,more:s.more,empty:!s.rows.length,ready:true});
    }
  } catch (e) {
    if (!current()) return;
    if (e.status === 401 || e.message === 'auth_required') sessionMissing('士多会话已失效。');
    else if (e.status === 403) sessionMissing('当前账号无权查看这些订单。');
    else {write(ctx,{error:String(e.message),more:s.more});if(silent)scheduleOrderPoll(ctx,s);}
  } finally {
    if (current()) {s.loading = false;write(ctx,{loading:false,initialLoading:false,loadingMore:false});fillOrderImages(ctx,s);}
  }
}
function clearOrderData(ctx,s) {
  s.rows=[];s.page=0;s.more=false;s.order=null;s.deliveryText='';s.revealed=false;
  if(s.poll){clearTimeout(s.poll);s.poll=null;}
  write(ctx,{rows:[],ready:false,more:false,empty:false,orderTitle:'',orderNo:'',state:'',amount:'',delivery:'',deliveryText:'',hasDelivery:false,
    orderImage:'',orderImageLoading:false,fields:[],times:[],orderEvents:[],usage:'',tradeNo:'',paymentNote:'',statusNote:'',canPay:false,canCheck:false,canCancel:false,canRepurchase:false});
}
function scheduleOrderPoll(ctx,s) {
  if (s.poll) clearTimeout(s.poll);
  if (market(ctx)!==s || s.hidden || typeof setTimeout!=='function' || !s.order || !['pending','pending_payment','paying','paid'].includes(s.order.status)) return;
  s.poll=setTimeout(async()=>{s.poll=null;if(market(ctx)===s && !s.hidden) {if(s.paymentBusy || s.loading)scheduleOrderPoll(ctx,s);else await loadOrders(ctx,false,true);}},4000);
}
const orderFilters = [
  {status:'',label:'全部',name:'全部订单'}, {status:'pending',label:'待付款',name:'待付款订单'},
  {status:'paid',label:'待发货',name:'待发货订单'}, {status:'delivered',label:'已发货',name:'已发货订单'},
  {status:'completed',label:'已完成',name:'已完成订单'}, {status:'cancelled,expired',label:'已取消',name:'已取消订单'},
  {status:'refund_pending,refunded,refund_failed,external_dispute',label:'退款',name:'退款订单'},
];
function showOrderFilters(ctx) {
  const status = market(ctx).orderStatus || '';
  ctx.setData('orderFilters',orderFilters.map(filter => ({...filter,selected:filter.status === status})));
}
function accountAvatar(user) {
  for(const raw of [user.animatedAvatar,user.avatar,user.avatarUrl,user.avatarTemplate]) {
    if(typeof raw!=='string' || !raw.trim())continue;
    let url=raw.trim().replace(/\{size\}/g,'128');
    if(url.startsWith('//'))url='https:'+url;
    else if(url.startsWith('/'))url='https://linux.do'+url;
    if(!/^https?:\/\//i.test(url))continue;
    // 士多公开头像代理用于论坛头像，仍由宿主匿名图片出口获取。
    if(/^https?:\/\/(?:linux\.do|idcflare\.com)\/(?:user_avatar|letter_avatar_proxy)\//i.test(url))return api+'/avatar-proxy?url='+encodeURIComponent(url);
    return url;
  }
  return '';
}
let identityRevision=0,identityTask=null,identityValue=null,identitySigningOut=false;
function clearAccountIdentity() {
  identityRevision++;identityTask=null;identityValue=null;
  publishAccountIdentity({authorized:false,accountName:'',accountAvatar:'',accountMeta:''});
}
function publishAccountIdentity(value) {
  for(const s of views.values())if(['market','account'].includes(s.ctx?.page))write(s.ctx,value);
}
async function loadAccountIdentity(ctx,refresh=false) {
  if(identitySigningOut)return null;
  const revision=identityRevision;
  const auth=await ldStore.status(true),account=auth.authorized ? await ctx.api.user.get() : null;
  if(revision!==identityRevision)return null;
  if(!auth.authorized || !account?.id){clearAccountIdentity();return null;}
  const claims=normalizeOrderData(auth.claims || {});
  const key=JSON.stringify([account.id,auth.expiresAt,claims]);
  if(!refresh && identityValue?.key===key){publishAccountIdentity(identityValue.value);return identityValue.value;}
  if(identityTask?.key===key)return identityTask.promise;
  const promise=(async()=>{
    try {
      const profile=normalizeOrderData(await read('/auth/verify',true));
      if(revision!==identityRevision)return null;
      if(profile.authenticated!==true || String(profile.user?.id)!==String(account.id) ||
        (profile.user?.site || 'linux.do')!=='linux.do') {
        clearAccountIdentity();const error=Error('士多会话已失效。');error.status=401;throw error;
      }
      // 旧会话可直接读取声明，头像不依赖校验接口是否附带完整用户资料。
      const sameClaims=String(claims.sub ?? claims.id)===String(account.id) && (claims.site || 'linux.do')==='linux.do';
      const level=profile.user.trustLevel ?? (sameClaims ? claims.trustLevel : null);
      const value={authorized:true,accountName:display(profile.user.name || (sameClaims && claims.name) || profile.user.username || account.username),
        accountMeta:['@'+(profile.user.username || account.username),level!=null ? 'TL'+level : ''].filter(Boolean).join(' · '),
        accountAvatar:accountAvatar(profile.user) || (sameClaims ? accountAvatar(claims) : '')};
      identityValue={key,value};publishAccountIdentity(value);return value;
    } catch(error) {
      if(revision===identityRevision && error.status===401)clearAccountIdentity();
      throw error;
    } finally {if(revision===identityRevision)identityTask=null;}
  })();
  identityTask={key,promise};return promise;
}
async function loadOverview(ctx) {
  const s=market(ctx);
  write(ctx,{overviewLoading:true,overviewInitialLoading:!s?.overviewLoaded,overviewError:''});
  const revision=s ? s.overviewRevision=(s.overviewRevision || 0)+1 : 0;
  const current=()=>!s || (market(ctx)===s && s.overviewRevision===revision);
  try {
    const auth=await ldStore.status();if(!current())return;ctx.setData('authorized',auth.authorized);
    if(auth.authorized) {
      const account=await ctx.api.user.get();if(!current())return;
      if(!s.overviewLoaded)ctx.setData('accountName',display(account?.username));
      if(ctx.page==='account') {
        try {await loadAccountIdentity(ctx,!!s.overviewLoaded);if(!current())return;}
        catch(error) {if(error.status===401)throw error;}
      }
      if(!current())return;
      const [raw,unread]=await Promise.all([read('/user/attention',true),read('/messages/unread-summary',true)]);
      const data=normalizeOrderData(raw),unreadData=normalizeOrderData(unread);
      if(!current())return;
      s.overviewStats=[{label:'待付款',value:display(data.pendingPaymentCount ?? 0)},{label:'待发货',value:display(data.awaitingDeliveryCount ?? 0)},
        {label:'优惠券',value:display(data.unusedCouponCount ?? 0)},{label:'未读消息',value:display(notificationSummary?.totalUnread ?? unreadData.totalUnread ?? 0)}];
      ctx.setData('stats',s.overviewStats);
      if(ctx.page==='account') {
        const recent=(data.recentOrders || []).filter(order=>order.orderNo || order.id).map(order=>({no:display(order.orderNo || order.id),title:display(order.productName) || '商品订单',subtitle:[statusLabels[order.status] || '未知状态',order.amount!=null ? money(order.amount) : ''].filter(Boolean).join(' · ')}));
        write(ctx,{recentOrders:recent,hasRecentOrders:!!recent.length});
        if(s.spendingOpen)await loadSpending(ctx,s);
        if(!current())return;
      }
      write(ctx,{refundHint:Number(data.refundAttentionCount)>0 ? display(data.refundAttentionCount)+' 笔售后待处理' : '',couponHint:Number(data.expiringCouponCount)>0 ? display(data.expiringCouponCount)+' 张即将到期' : ''});
    } else {
      clearPrivateOverview(ctx,s);write(ctx,{accountName:'',accountAvatar:'',accountMeta:'',refundHint:'',couponHint:''});
      const data=await read('/stats');
      if(!current())return;
      ctx.setData('stats',[{label:'在售商品',value:display(data.products?.online ?? '—')},{label:'今日订单',value:display(data.orders?.today ?? '—')},{label:'店铺',value:display(data.stores ?? '—')}]);
    }
    s.overviewLoaded=true;ctx.setData('overviewError','');
  } catch (error) {if(current()){
    if(error.status===401){clearAccountIdentity();clearPrivateOverview(ctx,s);s.overviewLoaded=false;s.overviewStats=null;write(ctx,{authorized:false,stats:[],refundHint:'',couponHint:''});}
    write(ctx,{overviewError:'暂时无法更新统计，仍可进入浏览'});
  }}
  finally {if(current())write(ctx,{overviewLoading:false,overviewInitialLoading:false});}
}
function clearPrivateOverview(ctx,state) {
  state.spendingRevision=(state.spendingRevision || 0)+1;state.spendingOpen=false;state.spendingLoaded=false;state.spendingLoading=false;
  write(ctx,{recentOrders:[],hasRecentOrders:false,spendingOpen:false,spendingLoading:false,spendingEmpty:false,spendingSummary:'',spendingRows:[],spendingError:''});
}
async function loadSpending(ctx,state) {
  if(state.spendingLoading)return;
  const revision=state.spendingRevision=(state.spendingRevision || 0)+1;
  const current=()=>market(ctx)===state && state.spendingRevision===revision;
  state.spendingLoading=true;write(ctx,{spendingLoading:true,spendingError:''});
  try {
    if(!(await ldStore.status()).authorized){if(current())clearPrivateOverview(ctx,state);return;}
    const dashboard=normalizeOrderData(await read('/user/dashboard',true));
    if(!current())return;
    if(!dashboard.overview || !Array.isArray(dashboard.spendingDistribution?.categories))throw Error('消费记录格式有误');
    const rows=dashboard.spendingDistribution.categories.slice().sort((left,right)=>Number(right.amount)-Number(left.amount));
    const total=Math.max(Number(dashboard.spendingDistribution.totals?.amount) || 0, rows.reduce((sum,row)=>sum+Math.max(0,Number(row.amount) || 0),0));
    write(ctx,{spendingEmpty:!rows.length,spendingSummary:'累计 '+display(dashboard.overview.totalPurchaseOrders ?? 0)+' 单 · '+money(dashboard.overview.totalSpent ?? 0),
      spendingRows:rows.map(row=>({label:display(row.categoryName) || '其他',value:money(row.amount)+' · '+(total ? Math.round(Number(row.amount)*100/total) : 0)+'%'}))});state.spendingLoaded=true;
  } catch(error){if(current()){if(error.status===401){clearPrivateOverview(ctx,state);ctx.setData('authorized',false);}else ctx.setData('spendingError',error.message);}}
  finally {if(current()){state.spendingLoading=false;ctx.setData('spendingLoading',false);}}
}
fluxdo.on('spending',ctx=>{const state=market(ctx);if(ctx.page!=='account' || !state)return;state.spendingOpen=!state.spendingOpen;ctx.setData('spendingOpen',state.spendingOpen);if(state.spendingOpen && !state.spendingLoaded)return loadSpending(ctx,state);});
fluxdo.on('spendingRetry',ctx=>{const state=market(ctx);if(ctx.page==='account' && state?.spendingOpen)return loadSpending(ctx,state);});
fluxdo.on('card.load',ctx=>{views.set(ctx.surface,{ctx,seq:0,visibility:0});syncNotifications();return loadOverview(ctx);});
fluxdo.on('card.hide',ctx=>{const s=market(ctx);if(s)s.hidden=true;return syncNotifications();});
fluxdo.on('card.resume',ctx=>{const s=market(ctx);if(s)s.hidden=false;return syncNotifications();});
fluxdo.on('card.refresh',loadOverview);
fluxdo.on('page.open',ctx => {
  const s = {ctx,seq:0,visibility:0,rows:[],cat:'',search:'',sort:'updated_at',direction:'DESC',stock:false,min:'',max:''};
  views.set(ctx.surface,s);
  syncNotifications();
  write(ctx,{externalBusy:false,externalError:''});
  if(ctx.page==='filters') {
    const source=views.get(ctx.params.source); if(!source)return;
    s.source=source; s.cat=source.cat;s.sort=source.sort;s.direction=source.direction;s.min=source.min;s.max=source.max;s.stock=source.stock;s.categories=source.categories;
    s.catName=source.catName;s.sortName=source.sortName;showFilters(ctx,s);write(ctx,{min:s.min,max:s.max,stock:s.stock});return;
  }
  if(ctx.page==='account'){clearPrivateOverview(ctx,s);return loadOverview(ctx);}
  if(ctx.page==='messages')return loadMessages(ctx,false);
  if (['favorites','coupons','coupon','refund','comment','merchant'].includes(ctx.page)) return loadBuyerPage(ctx,false);
  if (ctx.page === 'product') write(ctx,{comments:[],commentStatsReady:false,commentsError:'',commentsMessage:'',commentsMore:false,commentsLoading:false});
  if (ctx.page === 'orders' || ctx.page === 'order') {
    s.orderStatus=ctx.params.status || '';ctx.setData('filterName','全部订单');
    showOrderFilters(ctx);
    return loadOrders(ctx,false);
  }
  if (ctx.page === 'product' || ctx.page === 'review') return detail(ctx);
  write(ctx,{selection:'全部 · 默认排序',stock:false,categoryMessage:'',filters:false,
    filterLabel:'筛选与排序'});
  write(ctx,{accountName:'',accountAvatar:'',authorized:false});
  loadAccountIdentity(ctx).catch(()=>{});
  return Promise.all([categories(ctx),load(ctx,false)]);
});
fluxdo.on('surface.close',ctx => {const s=market(ctx);if(s?.poll)clearTimeout(s.poll);if(s?.searchTimer)clearTimeout(s.searchTimer);views.delete(ctx.surface);return syncNotifications();});
// 页面暂时被遮住时保留内容、筛选和分页，只收起已展开的交付内容。
fluxdo.on('page.hide',ctx => {
  const s = market(ctx);
  if (!s) return;
  s.hidden = true;
  syncNotifications();
  s.visibility++;
  if(s.poll) {clearTimeout(s.poll);s.poll=null;}
  if(s.searchTimer) {clearTimeout(s.searchTimer);s.searchTimer=null;s.dirty=true;}
  if (ctx.page === 'order') {
    s.revealed = false;
    write(ctx,{deliveryText:'',deliveryAction:'查看交付内容'});
  }
});
fluxdo.on('page.resume',(ctx,args) => {
  const s = market(ctx);
  if (!s) return;
  s.hidden = false;
  syncNotifications();
  if(ctx.page==='market')loadAccountIdentity(ctx).catch(()=>{});
  if(ctx.page==='messages')syncMessageView(s).catch(()=>{});
  if(s.commentsStale && ctx.page==='product'){s.commentsStale=false;loadComments(ctx,false);}
  if (s.createdNavigation) return openCreatedOrder(ctx,s);
  if (s.dirty) {showFilters(ctx,s);return refreshView(ctx);}
  if(ctx.page==='order')scheduleOrderPoll(ctx,s);
  if(ctx.page==='order' || ctx.page==='orders')fillOrderImages(ctx,s);
});
fluxdo.on('market',() => fluxdo.navigate('market'));
fluxdo.on('product',(ctx,a) => fluxdo.navigate('product',{id:a.id}));
fluxdo.on('login',async ctx => {
  const s = market(ctx);
  write(ctx,{loggingIn:true,loginError:''});
  try {
    if (!await ldStore.login(ctx.api)) return;
    clearAccountIdentity();await loadAccountIdentity(ctx).catch(()=>{});
    notificationBlocked=false;notificationSummary=null;notificationRetryAt=0;
    if(notificationRetryTimer)clearTimeout(notificationRetryTimer);notificationRetryTimer=null;
    if(notificationOwner) {try {await notificationOwner.ctx.api.streams.close('notifications');}catch(_) {}}
    notificationOwner=null;syncNotifications();
    relogCatalog();invalidateViews(s);
    if (s) s.dirty = false;
    if (ctx.page === 'orders' || ctx.page === 'order') await loadOrders(ctx,false);
    else if (['favorites','coupons','coupon','refund','comment','merchant'].includes(ctx.page)) await loadBuyerPage(ctx,false);
    else if (ctx.page === 'product' || ctx.page === 'review') await detail(ctx);
    else if(ctx.page==='account')await loadOverview(ctx);
    else if(ctx.page==='messages')await loadMessages(ctx,false);
    else if(ctx.page==='market')await refreshView(ctx);
    else ctx.setData('authorized',true);
  } catch (error) {ctx.setData('loginError',error.message || '登录未完成，请稍后重试。');}
  finally {ctx.setData('loggingIn',false);}
});
async function requestAccess(client,names) {
  const status=await client.permissions.status();
  const missing=names.filter(name=>!status[name]);
  return !missing.length || await client.permissions.request(missing);
}
async function payOrder(ctx,cancel) {
  const s = market(ctx);
  if (!s || s.paymentBusy || ctx.page !== 'order') return;
  if (!cancel && !await requestAccess(ctx.api,['identity','serviceAccount','payments'])) {ctx.setData('paymentNote','未允许支付权限，再次点击支付可重新申请。');return;}
  if (cancel && !await ctx.api.dialogs.confirm({title:'取消订单',message:'取消后将无法继续支付此订单。',confirmLabel:'取消订单'})) return;
  s.cancelConfirmed = false;
  ctx.setData('cancelLabel','取消订单');
  s.paymentBusy=true;write(ctx,{paymentBusy:true,paymentAvailable:false,paymentNote:''});
  try {
    const result = cancel ? await ldStore.cancel(ctx.api,ctx.params.no) :
      await ldStore.pay(ctx.api,ctx.params.no);
    if (result != null && result !== false && (cancel || result.state !== 'cancelled')) {
      await loadOrders(ctx,false,true);
      if(market(ctx)===s)orderChanged(s.order,s);
    }
  } catch (_) {
    await loadOrders(ctx,false,true);
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
fluxdo.on('orders',(_ctx,args) => fluxdo.navigate('orders',args || {}));
fluxdo.on('order',(_ctx,args) => fluxdo.navigate('order',{no:args.no}));
fluxdo.on('ordersRefresh',ctx => loadOrders(ctx,false));
fluxdo.on('ordersRetry',ctx => loadOrders(ctx,market(ctx)?.ordersRetryMore===true));
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
function clearQuote(ctx,s,preserve=false) {
  if (ctx.page !== 'review') return;
  s.quoteSeq = (s.quoteSeq || 0) + 1; s.quote = null; s.quoting = false;
  s.orderIntent = null;
  if(!preserve)s.quoteDisplayed=false;
  write(ctx,{canQuote:s.quoteEnabled,canSubmit:false,quoting:false,quoteNote:'',
    ...(!preserve ? {quoteReady:false,couponRows:[],unavailableCoupons:[],payable:''} : {})});
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
  s.quoteDisplayed=true;
  write(ctx,{quoteReady:true,couponRows:q.coupons.map(c => ({
      id:c.id,label:c.name + ' · ' + money(c.amount),subtitle:c.detail,selected:c === coupon,variant:c === coupon ? 'tonal' : 'text'
    })),unavailableCoupons:q.unavailable,choice:coupon ? coupon.name : '不使用优惠券',noCoupon:!coupon,noneVariant:coupon ? 'text' : 'tonal',
    quoteNote:expired ? '之前选择的优惠券已不可用，请核对新报价。' : '',
    payable:money(coupon ? coupon.amount : q.base)});
}
const validAmount = n => typeof n === 'number' && Number.isFinite(n) && n >= 0;
async function quote(ctx) {
  const s = market(ctx);
  if (!s || ctx.page !== 'review' || !s.quoteEnabled || s.quoting) return;
  const hasQuote=!!s.quoteDisplayed;
  clearQuote(ctx,s,true);
  const seq = s.quoteSeq, quantity = s.quantity, current = () => market(ctx) === s && seq === s.quoteSeq;
  s.quoting = true; write(ctx,{quoting:true,quoteInitialLoading:!hasQuote});
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
    const result = response.json(), q = normalizeOrderData(result.data);
    if (!result.success || !q || String(q.productId) !== s.id || q.quantity !== quantity ||
        !Array.isArray(q.coupons) || !validAmount(q.payableAmount)) throw Error('士多返回的报价与当前商品或数量不符');
    const eligible = q.coupons.filter(c => c && c.eligible === true);
    const base = q.productSubtotal ?? (eligible.length === 0 ? q.payableAmount : null);
    if (!validAmount(base)) throw Error('士多未返回可核对的商品小计');
    const coupons = eligible.map(c => {
      if (c.claimId == null || !validAmount(c.payableAmount)) throw Error('优惠券报价无法核对');
      return {id:String(c.claimId),name:display(c.campaign?.name) || '优惠券',amount:c.payableAmount,
        detail:[c.couponDiscountAmount!=null ? '减 '+money(c.couponDiscountAmount) : '',c.campaign?.expiresAt ? '有效至 '+storeDate(c.campaign.expiresAt) : ''].filter(Boolean).join(' · ')};
    });
    s.quote = {base,coupons,unavailable:q.coupons.filter(item=>item?.eligible===false).map(item=>({label:display(item.campaign?.name) || '优惠券',reason:display(item.reason) || '当前不可使用'}))};
    showQuote(ctx,s);
  } catch (e) {
    if (current()) ctx.setData('quoteNote',e.message === 'query_not_granted' ? '当前会话没有报价权限' : String(e.message));
  } finally {
    if (current()) {s.quoting=false;write(ctx,{quoting:false,quoteInitialLoading:false});}
  }
}
fluxdo.on('quote',quote);
fluxdo.on('quoteCoupon',(ctx,a) => {
  const s = market(ctx);
  if (s && s.quote && !s.quoting && ctx.page === 'review' && (a.id === '' || s.quote.coupons.some(c => c.id === a.id))) {
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
      ? await fluxdo.prepareNavigation('order',{replace:true}) : null;
    const result = await ldStore.submission(kind,
      kind === 'submit' ? s.orderIntent : kind === 'finish' ? s.record.orderNo : null);
    if (result?.state === 'created' || result?.state === 'pending')orderChanged(result,s);
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
    return fluxdo.navigate('order',{no:r.orderNo},{replace:true});
  }
});
fluxdo.on('quantity',(ctx,a) => {
  const s = market(ctx);
  if (!s || ctx.page !== 'review' || !s.buy || (!Number.isInteger(a.value) && a.step !== 1 && a.step !== -1)) return;
  s.quantity = Math.min(s.limit,Math.max(1,Number.isInteger(a.value) ? a.value : s.quantity + a.step));
  clearQuote(ctx,s);
  write(ctx,{quantity:String(s.quantity),quantityValue:s.quantity,estimate:money(s.unit * s.quantity),
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
fluxdo.on('refresh',ctx => {ctx.setData('categoryMessage','');loadAccountIdentity(ctx,true).catch(()=>{});return Promise.all([categories(ctx),load(ctx,false)]);});
fluxdo.on('more',ctx => load(ctx,true));
fluxdo.on('filters',ctx => fluxdo.navigate('filters',{source:ctx.surface}));
fluxdo.on('applyFilters',async ctx=>{
  const s=market(ctx);if(!s?.source)return;
  if((s.min && (!Number.isFinite(Number(s.min)) || Number(s.min)<0)) || (s.max && (!Number.isFinite(Number(s.max)) || Number(s.max)<0)) || (s.min && s.max && Number(s.min)>Number(s.max))) {ctx.setData('filterError','请填写有效的价格范围');return;}
  for(const key of ['cat','catName','sort','sortName','direction','stock','min','max'])s.source[key]=s[key];
  s.source.dirty=true;await ctx.api.navigation.dismiss();
});
fluxdo.on('resetFilters',ctx=>{const s=market(ctx);Object.assign(s,{cat:'',catName:'全部',sort:'updated_at',direction:'DESC',sortName:'默认排序',stock:false,min:'',max:''});showFilters(ctx,s);write(ctx,{min:'',max:'',stock:false,filterError:''});});
fluxdo.on('input',(ctx,a) => {
  market(ctx)[a.field] = display(a.value).trim();
  ctx.setData(a.field,display(a.value));
  const s=market(ctx);
  if(a.field==='search' && typeof setTimeout==='function') {if(s.searchTimer)clearTimeout(s.searchTimer);s.searchTimer=setTimeout(()=>{if(market(ctx)===s && !s.hidden)load(ctx,false);},350);}
});
fluxdo.on('apply',ctx => load(ctx,false));
fluxdo.on('stock',(ctx,a) => {market(ctx).stock = a.value; ctx.setData('stock',a.value);if(ctx.page!=='filters')return load(ctx,false);});
fluxdo.on('select',(ctx,a) => {
  const s = market(ctx);
  if (a.cat !== undefined) {s.cat=a.cat;s.catName=a.label;}
  else {s.sort=a.sort;s.direction=a.direction;s.sortName=a.label;}
  showFilters(ctx,s);
  if(ctx.page!=='filters')return load(ctx,false);
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
function hasNextPage(paging, page, count, size=20) {
  if(!count || !paging)return false;
  if(typeof paging.hasMore==='boolean')return paging.hasMore;
  if(paging.totalPages!=null)return page<Number(paging.totalPages);
  return page*(Number(paging.pageSize) || size)<Number(paging.total);
}
function mergeRows(previous,rows) {
  const seen=new Set(previous.map(row=>row.id));
  return previous.concat(rows.filter(row=>{if(seen.has(row.id))return false;seen.add(row.id);return true;}));
}
function couponRule(c) {
  if (c.discountType === 'fixed_amount') return '减 '+money(c.fixedAmount);
  if (c.discountType === 'percentage') return (Number(c.percentageBps) / 1000).toFixed(1)+' 折 · 仅优惠 1 件';
  return '优惠规则暂不可用';
}
function storeMillis(value) {
  const text=display(value).trim();
  if(typeof value==='number' || /^\d{10}(?:\d{3})?$/.test(text)) {
    const number=Number(value);return number>0 ? new Date(number<1e10 ? number*1000 : number).getTime() : NaN;
  }
  if(!/^\d{4}-\d{2}-\d{2}(?:$|[ T]\d\d:\d\d)/.test(text))return NaN;
  let date=text.replace(' ','T');
  if(date.length===10)date+='T00:00:00';
  if(/[+-]\d{2}$/.test(date))date+=':00';
  if(!/(Z|[+-]\d{2}:?\d{2})$/i.test(date))date+='Z';
  return Date.parse(date);
}
function storeTime(value) {
  const time=storeMillis(value);return Number.isFinite(time) ? new Date(time).toISOString() : '';
}
function storeDate(value) {
  const time=storeMillis(value);return Number.isFinite(time) ? new Date(time+8*3600000).toISOString().slice(0,16).replace('T',' ')+'（北京时间）' : '—';
}
function latestEvents(events) {
  const time=event=>storeMillis(event.createdAt || event.time) || 0;
  return (Array.isArray(events) ? events : []).slice().reverse().sort((left,right)=>time(right)-time(left));
}
function couponRow(c, claim = {}, tab='') {
  claim = claim || {};
  const reserved = claim.claimStatus === 'reserved' || claim.status === 'reserved';
  const used = tab==='used' || claim.claimStatus === 'used' || claim.status === 'used';
  const expired=tab==='expired' || ['expired','disabled'].includes(c.state) || !!claim.invalidReason;
  const scheduled=c.state==='scheduled' || storeMillis(c.startsAt)>Date.now();
  const orderNo=display(reserved ? claim.reservedOrderNo : used ? claim.usedOrderNo : '');
  const action=orderNo ? reserved ? '查看占用订单' : '查看使用订单' : used || reserved || expired || scheduled || (claim.status && claim.status!=='available') ? '' : '查看适用商品';
  return {id:String(claim.claimId ?? claim.id ?? c.id),title:display(c.name),rule:couponRule(c),
    seller:'卖家：'+display(c.sellerUsername),
    scope:c.scopeType === 'product' ? display(c.productName) || '指定商品' : '该卖家店铺内商品',
    minimum:Number(c.minSpend)>0 ? '满 '+money(c.minSpend) : '无门槛',
    starts:storeDate(c.startsAt),expires:storeDate(c.expiresAt),
    usedAt:used && claim.usedAt ? storeDate(claim.usedAt) : '',actualDiscount:used && claim.actualDiscountAmount!=null ? money(claim.actualDiscountAmount) : '',
    state:reserved ? '待支付订单占用' : used ? '已使用' : display(claim.invalidReason) || (expired ? '已失效' : scheduled ? '待生效' : ''),
    productId:c.scopeType === 'product' && c.productId != null ? String(c.productId) : '',
    sellerId:display(c.sellerUserId), sellerUsername:display(c.sellerUsername), sellerSite:display(c.sellerSite),
    quantity:c.remainingQuantity!=null && c.totalQuantity!=null ? display(c.remainingQuantity)+' / '+display(c.totalQuantity) : '',orderNo,action};
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
  const page = more ? (s.page || 1) + 1 : 1;s.buyerRetryMore=more;
  const queryKey=JSON.stringify([s.search,s.couponTab,s.collection]);
  if(!more && s.buyerQuery!==queryKey){s.rows=[];s.more=false;s.buyerReady=false;}
  s.buyerQuery=queryKey;
  s.loading = true;
  write(ctx,{loading:!more,loadingMore:more,error:'',buyerError:'',needsSession:false,ready:!!s.buyerReady,initialLoading:!s.buyerReady,more:false,rows:s.rows});
  try {
    const auth = await ldStore.status();
    if (!current()) return;
    write(ctx,{authorized:auth.authorized});
    if (!auth.authorized && !['coupon','merchant'].includes(ctx.page)) {
      clearBuyerData(ctx,s);write(ctx,{needsSession:true,error:'登录士多后继续'}); return;
    }
    if (ctx.page === 'favorites' || ctx.page === 'coupons' || ctx.page === 'merchant') {
      const coupons = ctx.page === 'coupons';
      if (coupons) ctx.setData('tabs',couponTabs.map(t=>({...t,selected:t.value === (s.couponTab || 'unused')})));
      if(ctx.page==='favorites')write(ctx,{collections:[{id:'favorites',label:'已收藏',selected:s.collection!=='blocked'},{id:'blocked',label:'不感兴趣',selected:s.collection==='blocked'}],
        search:s.search,collectionHint:s.collection==='blocked' ? '搜索已隐藏的商品' : '搜索收藏的商品',collectionEmpty:s.collection==='blocked' ? '没有已隐藏的商品' : '还没有收藏商品'});
      const data = ctx.page==='merchant' ? normalizeOrderData(await readPublic('/merchants/'+encodeURIComponent(ctx.params.username)+'?'+params({page,site:ctx.params.site || '',userId:ctx.params.userId || ''}),auth)) : await buyerRequest(ctx, coupons
        ? '/my-coupons?'+params({status:s.couponTab || 'unused',page,pageSize:20})
        : (s.collection==='blocked' ? '/blocked-products?' : '/favorites?')+params({search:s.search,page,pageSize:20}), 'GET', undefined, auth.authorized);
      if (!current()) return;
      if(ctx.page==='merchant' && !more) {
        if(!data.merchant?.username)throw Error('缺少店铺资料');
        const merchant=data.merchant,username=merchant.username,profile=data.profile || {};
        const sameId=profile.userId!=null && merchant.userId!=null && String(profile.userId)===String(merchant.userId);
        const sameName=typeof profile.username==='string' && profile.username.toLowerCase()===username.toLowerCase();
        const sameProfile=(sameId || sameName) && (!profile.userId || !merchant.userId || sameId) && (!profile.username || sameName) && (!profile.site || !merchant.site || profile.site===merchant.site);
        write(ctx,{merchantReady:true,merchantTitle:merchant.name || username,merchantMeta:['@'+username,merchant.trustLevel!=null ? 'TL'+merchant.trustLevel : ''].filter(Boolean).join(' · '),
          merchantAvatar:accountAvatar(merchant) || (sameProfile ? accountAvatar(profile) : ''),
          merchantStats:[['在售',data.stats?.onlineCount],['上架',data.stats?.totalListedCount],['销量',data.stats?.totalSoldCount]].filter(([,value])=>value!=null).map(([label,value])=>({label,value:display(value)}))});
      }
      const entries = coupons ? data.items : ctx.page==='merchant' ? data.products ?? [] : data.products;
      if (!Array.isArray(entries)) throw Error('列表数据格式有误');
      const rows = entries.map(row=>coupons ? couponRow(row.campaign || {},row,s.couponTab || 'unused') : {...productView(row),hiddenItem:ctx.page==='favorites' && s.collection==='blocked',
        preferenceTime:ctx.page==='favorites' ? storeTime((s.collection==='blocked' ? row.blockedAt : row.favoritedAt) || row.updatedAt || row.createdAt) : ''});
      s.rows=mergeRows(more ? s.rows : [],rows);s.page=page;
      s.more=hasNextPage(data.pagination,page,rows.length);
      write(ctx,{ready:true,rows:s.rows,more:s.more});
    } else if (ctx.page === 'coupon') {
      const token = String(ctx.params.token || '');
      if (!/^[A-Za-z0-9_-]{1,256}$/.test(token)) throw Error('优惠券链接无效');
      const data = normalizeOrderData(await readPublic('/coupons/'+encodeURIComponent(token),auth));
      if (!current()) return;
      if (!data || data.id == null) throw Error('优惠券数据格式有误');
      s.coupon=data;s.claimAuthorized=auth.authorized;
      const states = {scheduled:'尚未开始领取',expired:'优惠券已过期',paused:'卖家暂停领取',closed:'已停止领取',sold_out:'优惠券已领完',disabled:'优惠券已停用'};
      write(ctx,{ready:true,authorized:auth.authorized,coupon:couponRow(data,data.claim),description:display(data.description),
        canClaim:auth.authorized && data.claimable === true && !data.claimed,claimed:data.claimed === true,
        claimLabel:data.claimed ? '已领取' : states[data.state] || '领取优惠券'});
    } else if (ctx.page === 'comment') {
      const data = await buyerRequest(ctx, '/products/'+encodeURIComponent(ctx.params.id)+'/comments?page=1&pageSize=1');
      if (!current()) return;
      s.canComment=data.commentEnabled === true;
      s.canRate=data.viewerHasPurchased === true && data.viewerRating?.hasRated !== true;
      const fields=[{name:'content',label:'评论内容',hint:'分享使用体验或提出问题（5–500 字）',type:'multiline',required:true,maxLength:500}];
      if (s.canRate) fields.push({name:'rating',label:'商品评分（选填）',type:'choice',options:[{value:'',label:'不评分'},...Array.from({length:5},(_,i)=>({value:String(i+1),label:String(i+1)+' 星'}))]});
      write(ctx,{ready:true,canComment:s.canComment,fields,commentSubmitted:false,
        error:s.canComment ? '' : display(data.disabledReason) || '该商品已关闭评论'});
    } else if (ctx.page === 'refund') {
      const data = await buyerRequest(ctx, '/orders/'+encodeURIComponent(ctx.params.no)+'/refund');
      if (!current()) return;
      if (!data || data.role !== 'buyer' || !data.eligibility || typeof data.eligibility.canApply !== 'boolean') throw Error('退款状态格式有误');
      const refund=data.refund;
      if (refund && String(refund.orderNo) !== String(ctx.params.no)) throw Error('退款订单号与请求不一致');
      s.refund=data;
      write(ctx,{ready:true,canApply:!refund && data.eligibility.canApply === true,
        refundState:refund ? refundLabels[refund.status] || '状态待核对' : '申请售后',
        refundAmount:refund ? money(refund.refundAmount) : '',refundMessage:display(data.eligibility.message),
        reason:display(refund?.reasonDetail),deadline:refund?.decisionDeadlineAt ? '处理时限：'+storeDate(refund.decisionDeadlineAt) : '',
        refundDetails:refund ? [['退款原因',refundReasons.find(reason=>reason.value===refund.reasonCode)?.label || (refund.reasonCode==='shipment_timeout' ? '卖家超时未发货' : '')],
          ['申请时间',refund.requestedAt ? storeDate(refund.requestedAt) : ''],['卖家说明',refund.sellerResponse]].filter(([,value])=>!!value).map(([label,value])=>({label,value})) : [],
        events:latestEvents(refund?.events).map(event=>({title:refundEvents[event.action] || '售后状态更新',message:display(event.message),
          time:[({seller:'卖家',buyer:'买家',admin:'平台',system:'系统'})[event.actorType],event.actorName ? '@'+String(event.actorName).replace(/^@/,'') : '',storeDate(event.createdAt)].filter(Boolean).join(' · ')})),
        refundFields:[{name:'reasonCode',label:'退款原因',type:'choice',required:true,options:refundReasons},
          {name:'reasonDetail',label:'问题描述',hint:'请说明具体问题（10–500 字）',type:'multiline',required:true,maxLength:500},
          {name:'buyerContactedSeller',label:'已联系卖家协商',type:'toggle',value:false}],
        hasGuide:typeof data.disputeGuideUrl === 'string' && data.disputeGuideUrl.startsWith('https://')});
    }
    if(current())s.buyerReady=true;
  } catch (error) {
    if (current()) {if(error.status===401)clearBuyerData(ctx,s);write(ctx,{error:error.message,needsSession:error.status===401,more:s.more,canApply:false});}
  } finally {if (current()) {s.loading=false;write(ctx,{loading:false,initialLoading:false,loadingMore:false});}}
}
function clearBuyerData(ctx,state) {
  state.rows=[];state.page=0;state.more=false;state.buyerReady=false;state.refund=null;state.coupon=null;state.canComment=false;state.canRate=false;
  write(ctx,{authorized:false,ready:false,rows:[],more:false,canApply:false,canComment:false,canClaim:false,claimed:false,commentSubmitted:false,refundAmount:'',refundState:'',refundMessage:'',reason:'',deadline:'',refundDetails:[],events:[],hasGuide:false});
}
function relogCatalog() {
  imageSession++;productImages.clear();imageRequests.clear();
  for(const state of views.values())if(state.ctx?.page==='market') {
    state.slates?.clear();
    state.seq++;state.categoryRevision=(state.categoryRevision || 0)+1;state.rows=[];state.page=0;state.more=false;state.cursor='';state.dirty=true;state.categoriesDirty=true;
    state.categories=[{id:'',name:'全部'}];state.cat='';state.catName='全部';showFilters(state.ctx,state);
    write(state.ctx,{rows:[],more:false,total:'',categoryMessage:''});
  }
}
async function buyerAction(ctx, action) {
  const s=market(ctx);
  if (!s || s.buyerBusy || s.hidden) return;
  s.buyerBusy=true;write(ctx,{buyerBusy:true,buyerError:''});
  try { await action(s); }
  catch(error) {if (market(ctx)===s) write(ctx,{buyerError:error.message,...(error.status===401 ? {authorized:false,needsSession:true} : {})});}
  finally {s.buyerBusy=false;if(market(ctx)===s){ctx.setData('buyerBusy',false);if(ctx.page==='messages')await syncMessageView(s);}}
}
fluxdo.on('favorites',()=>fluxdo.navigate('favorites'));
fluxdo.on('coupons',()=>fluxdo.navigate('coupons'));
fluxdo.on('buyerRefresh',ctx=>loadBuyerPage(ctx,false));
fluxdo.on('buyerMore',ctx=>loadBuyerPage(ctx,true));
fluxdo.on('favoriteSearch',(ctx,a)=>{const s=market(ctx);if(s)s.search=String(a.value || '').slice(0,200);});
fluxdo.on('collectionTab',(ctx,args)=>{const state=market(ctx);if(ctx.page!=='favorites' || !state || !['favorites','blocked'].includes(args.id) || args.id===(state.collection || 'favorites'))return;
  state.collectionSearch=state.collectionSearch || {};state.collectionSearch[state.collection || 'favorites']=state.search;state.collection=args.id;state.search=state.collectionSearch[args.id] || '';return loadBuyerPage(ctx,false);});
fluxdo.on('couponTab',(ctx,a)=>{const s=market(ctx);if(s && couponTabs.some(t=>t.value===a.value) && !s.loading) {s.couponTab=a.value;return loadBuyerPage(ctx,false);}});
fluxdo.on('favorite',ctx=>buyerAction(ctx,async s=>{
  if (!(await ldStore.status()).authorized) {ctx.setData('authorized',false);throw Error('请先登录士多');}
  await buyerRequest(ctx, '/products/'+encodeURIComponent(ctx.params.id)+'/favorite',s.favorited ? 'DELETE' : 'POST');
  s.favorited=!s.favorited;invalidateViews(s,v=>v.ctx?.page==='favorites');
  write(ctx,{favorited:s.favorited,favoriteLabel:s.favorited ? '已收藏' : '收藏商品'});
}));
fluxdo.on('comment',ctx=>fluxdo.navigate('comment',{id:ctx.params.id}));
fluxdo.on('postComment',(ctx,a)=>buyerAction(ctx,async s=>{
  const content=String(a.values?.content || '').trim(),rating=Number(a.values?.rating);
  if (!s.canComment || content.length<5 || content.length>500) throw Error('请填写 5–500 字的评论');
  const body={content};
  if(s.canRate && Number.isInteger(rating) && rating>=1 && rating<=5) body.rating=rating;
  const result=await buyerRequest(ctx, '/products/'+encodeURIComponent(ctx.params.id)+'/comments','POST',body);
  for(const v of views.values())if(v.ctx?.page==='product' && v.ctx.params.id===ctx.params.id)v.commentsStale=true;
  s.canComment=false;
  write(ctx,{commentSubmitted:true,canComment:false,commentResult:result?.message || '评论已提交，以士多审核结果为准'});
}));
fluxdo.on('claimCoupon',ctx=>buyerAction(ctx,async s=>{
  if (!s.claimAuthorized || !s.coupon?.claimable || s.coupon.claimed) return;
  const result=await buyerRequest(ctx, '/coupons/'+encodeURIComponent(ctx.params.token)+'/claim','POST');
  if (!result?.claim || !result.campaign) throw Error('领取结果待确认，请刷新优惠券');
  s.coupon={...result.campaign,claimed:true,claim:result.claim};invalidateViews(s,v=>['coupons','review','account'].includes(v.ctx?.page) || v.ctx?.page==null);
  write(ctx,{coupon:couponRow(result.campaign,result.claim),claimed:true,canClaim:false,claimLabel:'已领取'});
}));
fluxdo.on('couponUse',(ctx,a)=>{
  const s=market(ctx),row=ctx.page==='coupon' ? s?.coupon && couponRow(s.coupon,s.coupon.claim) : s?.rows?.find(r=>r.id===a.id);
  if (!row?.action) return;
  if (row.orderNo) return fluxdo.navigate('order',{no:row.orderNo});
  if (row.productId) return fluxdo.navigate('product',{id:row.productId});
  if (!row.sellerUsername) return fluxdo.navigate('market');
  return fluxdo.navigate('merchant',{username:row.sellerUsername,site:row.sellerSite,userId:row.sellerId});
});
fluxdo.on('restoreProduct',(ctx,args)=>buyerAction(ctx,async state=>{
  if(ctx.page!=='favorites' || state.collection!=='blocked' || !state.rows.some(row=>row.id===args.id && row.hiddenItem))return;
  const latest=state.seq;
  await buyerRequest(ctx,'/products/'+encodeURIComponent(args.id)+'/block','DELETE');
  invalidateViews(state,view=>view.ctx?.page==='market');
  if(market(ctx)!==state || latest!==state.seq)return;
  state.buyerBusy=false;await loadBuyerPage(ctx,false);
}));
fluxdo.on('refund',ctx=>fluxdo.navigate('refund',{no:ctx.params.no}));
fluxdo.on('applyRefund',(ctx,a)=>buyerAction(ctx,async s=>{
  const values=a.values || {},reason=String(values.reasonDetail || '').trim();
  if (s.refund?.refund || !s.refund?.eligibility?.canApply) throw Error('当前订单不可提交新的退款申请');
  if (!refundReasons.some(r=>r.value===values.reasonCode) || reason.length<10 || reason.length>500) throw Error('请选择退款原因，并填写 10–500 字的问题描述');
  if (!await ctx.api.dialogs.confirm({title:'提交退款申请',message:'订单 '+ctx.params.no+'\n'+refundReasons.find(r=>r.value===values.reasonCode).label+'\n提交后由士多和卖家处理，可在这里查看进度。',confirmLabel:'确认提交'})) return;
  if (market(ctx)!==s) return;
  let note;
  try {
    await buyerRequest(ctx, '/orders/'+encodeURIComponent(ctx.params.no)+'/refund','POST',{
      reasonCode:values.reasonCode,reasonDetail:reason,buyerContactedSeller:values.buyerContactedSeller===true});
    invalidateViews(s,v=>['order','refund'].includes(v.ctx?.page) && v.ctx.params.no===ctx.params.no || v.ctx?.page==='account' || v.ctx?.page==null);
  } catch(error) {
    // 发送后只查询状态，不自动重复提交。
    note=error.message+'。请核对最新售后状态后再操作。';
  }
  s.buyerBusy=false;
  await loadBuyerPage(ctx,false);
  if(note)ctx.setData('buyerError',note);
}));
fluxdo.on('refundGuide',ctx=>{const url=market(ctx)?.refund?.disputeGuideUrl;if(url)return fluxdo.browser.open(url,{mode:'inApp'});});

fluxdo.on('marketRetry',ctx=>load(ctx,market(ctx)?.marketRetryMore===true));
fluxdo.on('buyerRetry',ctx=>loadBuyerPage(ctx,market(ctx)?.buyerRetryMore===true));

fluxdo.on('account',()=>fluxdo.navigate('account'));
fluxdo.on('messages',()=>fluxdo.navigate('messages'));
fluxdo.on('overviewRefresh',loadOverview);
fluxdo.on('signOut',async ctx=>{
  if(!await ctx.api.dialogs.confirm({title:'退出士多登录',message:'退出后仍可浏览商品。再次兑换时需要重新授权。',confirmLabel:'退出登录'}))return;
  identitySigningOut=true;clearAccountIdentity();
  notificationBlocked=true;notificationSummary=null;notificationRetryAt=0;stopNotificationFallback();
  if(notificationRetryTimer)clearTimeout(notificationRetryTimer);notificationRetryTimer=null;
  if(notificationOwner) {try {await notificationOwner.ctx.api.streams.close('notifications');}catch(_) {}}
  notificationOwner=null;
  relogCatalog();
  for(const v of views.values())if(v.ctx){v.seq++;v.overviewLoaded=false;v.overviewStats=null;v.overviewRevision=(v.overviewRevision || 0)+1;
    if(v.ctx.page==='account')clearPrivateOverview(v.ctx,v);
    if(['favorites','coupons','coupon','comment','refund'].includes(v.ctx.page))clearBuyerData(v.ctx,v);
    if(['orders','order'].includes(v.ctx.page))clearOrderData(v.ctx,v);
    if(v.ctx.page==='messages'){v.rows=[];v.page=0;v.more=false;v.messagesLoaded=false;v.messagesCheckPending=false;v.messagesChanged=false;write(v.ctx,{rows:[],more:false,unread:false,messagesChanged:false});}
    if(v.ctx.page==='product'){v.comments=[];v.commentsRevision=(v.commentsRevision || 0)+1;v.commentsPage=0;v.commentsLoading=false;write(v.ctx,{comments:[],commentsMore:false,commentsLoading:false,commentStatsReady:false,canComment:false});}
    write(v.ctx,{accountName:'',accountAvatar:'',accountMeta:'',authorized:false,stats:[]});}
  try {await ctx.api.credentials.remove('account');}
  finally {clearAccountIdentity();identitySigningOut=false;}
  invalidateViews(null,v=>v.ctx?.page!=='market');await loadOverview(ctx);
});
fluxdo.on('seller',ctx=>{const p=market(ctx)?.product;if(p?.sellerUsername)return fluxdo.navigate('merchant',{username:p.sellerUsername,userId:display(p.sellerUserId),site:p.sellerSite || 'linux.do'});});
fluxdo.on('contentLink',(ctx,a)=>{if(typeof a.url==='string' && /^https?:\/\//i.test(a.url))return ctx.api.browser.open(a.url,{mode:'ask'});});
fluxdo.on('repurchase',ctx=>{const o=market(ctx)?.order;const id=o?.productId || o?.product?.id;if(id)return fluxdo.navigate('product',{id:String(id)});});
fluxdo.on('checkPayment',async ctx=>{
  const s=market(ctx);if(!s || s.paymentBusy)return;
  s.paymentBusy=true;write(ctx,{paymentBusy:true,paymentNote:''});
  try {await buyerRequest(ctx,'/orders/'+encodeURIComponent(ctx.params.no)+'/refresh','POST');await loadOrders(ctx,false,true);}
  catch(e){ctx.setData('paymentNote',e.message);}
  finally {s.paymentBusy=false;ctx.setData('paymentBusy',false);}
});

fluxdo.on('sellerProfile',ctx=>{const p=market(ctx)?.product;if(p?.sellerUsername && (!p.sellerSite || p.sellerSite==='linux.do'))return ctx.api.forum.open({type:'user',username:p.sellerUsername});});

const messageTabs=[{value:'',label:'全部'},{value:'unread',label:'未读'},{value:'read',label:'已读'}];
const messageTypes={notification:'系统通知',seller_pending_delivery:'待发货提醒',seller_fulfillment_deadline:'卖家发货时限提醒',buyer_fulfillment_deadline:'发货保障通知',seller_fulfillment_policy:'卖家履约记录通知',product_offline:'商品下架通知',zero_stock_auto_offline:'库存下架提醒',product_comment:'商品评论通知',comment_reply:'评论回复通知',product_restock:'商品补货通知',buyer_order_delivered:'商品发货提醒',refund_reconciled:'退款核对结果',seller_restock_alert:'卖家补货提醒',restock_alert:'卖家补货提醒',top_service_active:'甄选服务生效通知',top_service_expired:'甄选服务到期通知'};
function messageType(type) {
  const refund=/^(?:buyer|seller)_refund_(processing|succeeded|failed|unknown|exception|external_dispute)$/.exec(type);
  return refund ? ({processing:'退款处理中',succeeded:'退款成功通知',failed:'退款异常通知',exception:'退款异常通知',unknown:'退款待核对通知',external_dispute:'Credit 处理通知'})[refund[1]] : messageTypes[type] || '系统通知';
}
async function loadMessages(ctx,more,silent=false) {
  const s=market(ctx);if(!s || s.buyerBusy || (more && (s.loading || !s.more)))return;
  if(silent && s.loading){s.messagesCheckPending=true;return;}
  const revision=++s.seq,current=()=>market(ctx)===s && revision===s.seq;s.messagesRetryMore=more;
  const page=more ? (s.page || 1)+1 : 1;
  const queryKey=JSON.stringify([s.readStatus || '',s.search || '']);
  const probe=silent && s.page>1 && s.messagesQuery===queryKey;
  const messagesRevision=s.messagesRevision || 0;
  if(s.messagesQuery!==queryKey){s.rows=[];s.page=0;s.more=false;s.messagesLoaded=false;s.messagesFirstSignature=null;s.messagesQuery=queryKey;}
  s.messagesCheckPending=false;s.loading=true;
  write(ctx,{rows:s.rows,loading:!more && !silent,loadingMore:more,error:'',buyerError:'',needsSession:false,
    tabs:messageTabs.map(t=>({...t,selected:t.value===(s.readStatus || '')}))});
  try {
    const auth=await ldStore.status();if(!current())return;
    ctx.setData('authorized',auth.authorized);
    if(!auth.authorized){s.rows=[];s.more=false;s.messagesLoaded=false;s.messagesChanged=false;s.messagesCheckPending=false;write(ctx,{needsSession:true,error:'登录士多后查看消息',rows:[],more:false,messagesChanged:false});return;}
    const data=await buyerRequest(ctx,'/messages/system?'+params({page,pageSize:20,readStatus:s.readStatus || '',search:s.search || ''}));
    if(!current())return;
    if(silent && s.hidden){s.messagesCheckPending=true;return;}
    if(!Array.isArray(data.messages))throw Error('消息数据格式有误');
    const signature=messageSignature(data.messages);
    if(probe) {
      s.messagesChanged=s.messagesChanged || s.messagesFirstSignature!==signature;
    } else {
      const rows=data.messages.map(m=>({id:String(m.id),title:display(m.title) || '系统消息',content:display(m.content),type:messageType(m.messageType),
        time:storeTime(m.createdAt),read:flag(m.isRead ?? m.is_read ?? m.read),link:display(m.link)}));
      s.rows=mergeRows(more ? s.rows : [],rows);s.page=page;s.more=hasNextPage(data.pagination,page,data.messages.length);
      s.messagesLoaded=true;
      if(!more) {s.messagesFirstSignature=signature;s.messagesChanged=messagesRevision!==(s.messagesRevision || 0);}
      write(ctx,{rows:s.rows,more:s.more,unread:Number(data.summary?.totalUnread || 0)>0});
    }
    ctx.setData('messagesChanged',!!s.messagesChanged);
  } catch(e) {if(current()){
    if(e.status===401){s.rows=[];s.more=false;s.messagesLoaded=false;s.messagesChanged=false;s.messagesCheckPending=false;write(ctx,{rows:[],authorized:false,needsSession:true,messagesChanged:false});}
    write(ctx,{error:e.message,more:!!s.more});
  }}
  finally {
    if(current()) {
      s.loading=false;write(ctx,{loading:false,loadingMore:false});
      if(s.messagesCheckPending && !s.hidden)await syncMessageView(s);
    }
  }
}
fluxdo.on('messagesRefresh',ctx=>loadMessages(ctx,false));
fluxdo.on('messagesMore',ctx=>loadMessages(ctx,true));
fluxdo.on('messagesRetry',ctx=>loadMessages(ctx,market(ctx)?.messagesRetryMore===true));
fluxdo.on('messageTab',(ctx,a)=>{const s=market(ctx);if(s && messageTabs.some(t=>t.value===a.value)){s.readStatus=a.value;return loadMessages(ctx,false);}});
fluxdo.on('messageRead',(ctx,a)=>buyerAction(ctx,async s=>{
  const row=s.rows.find(r=>r.id===a.id);if(!row || row.read)return;
  await buyerRequest(ctx,'/messages/system/'+encodeURIComponent(row.id)+'/read','POST');
  if(market(ctx)!==s)return;
  row.read=true;ctx.setData('rows',s.rows);invalidateViews(s,v=>v.ctx?.page==='account' || v.ctx?.page==null);
  if(s.readStatus==='unread'){s.rows=s.rows.filter(r=>r.id!==row.id);ctx.setData('rows',s.rows);}
  if(s.page===1)s.messagesFirstSignature=messageSignature(s.rows);
}));
fluxdo.on('messagesReadAll',ctx=>buyerAction(ctx,async s=>{
  if(!await ctx.api.dialogs.confirm({title:'全部标记已读',message:'将士多的全部系统消息标记为已读。',confirmLabel:'标记已读'}))return;
  if(market(ctx)!==s)return;
  await buyerRequest(ctx,'/messages/system/read-all','POST');invalidateViews(s,v=>v.ctx?.page==='account' || v.ctx?.page==null);
  s.buyerBusy=false;await loadMessages(ctx,false);
}));
fluxdo.on('messageOpen',(ctx,a)=>{
  const link=market(ctx)?.rows.find(r=>r.id===a.id)?.link;if(!link)return;
  const relative=link.replace(/^https:\/\/ldcstore\.com(?=\/)/,'');
  const match=/^\/(product|coupon|order)\/([A-Za-z0-9_-]{1,256})(?:[?#]|$)/.exec(relative);
  if(match)return fluxdo.navigate(match[1],{[match[1]==='product' ? 'id' : match[1]==='coupon' ? 'token' : 'no']:match[2]});
  if(relative.startsWith('/') && !relative.startsWith('//') && !relative.includes('\\'))return ctx.api.browser.open('https://ldcstore.com'+relative,{mode:'inApp'});
});
fluxdo.on('webMessages',()=>fluxdo.session.open('/user/messages'));
