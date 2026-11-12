// 插件脚本：运行在独立的 JS 引擎里，只能通过全局 fluxdo 对象与宿主交互。
const API = 'https://api.example.com';

async function loadBalance(ctx) {
  ctx.setData('loading', true);
  ctx.setData('error', '');
  try {
    // 宿主按 account 声明的 origin、路径和方法附带凭证。
    const res = await fluxdo.fetch(API + '/v1/balance', { credential: 'account' });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    ctx.setData('balance', String(res.json().balance));
  } catch (e) {
    ctx.setData('error', e.message);
  } finally {
    ctx.setData('loading', false);
  }
}

// 元宇宙页里的卡片出现时。
fluxdo.on('card.load', (ctx) => {
  ctx.setData('balance', '--');
  return loadBalance(ctx);
});

// 界面里 event "refresh" 触发。
fluxdo.on('refresh', loadBalance);

// 页面打开时；由帖内链接进入时 ctx.params 带着清单 path 里捕获的参数。
fluxdo.on('page.open', async (ctx) => {
  if (ctx.page !== 'order') return;
  ctx.setData('orderId', ctx.params.id);
  ctx.setData('status', '加载中…');
  ctx.setData('items', []);
  const res = await fluxdo.fetch(API + '/v1/orders/' + encodeURIComponent(ctx.params.id), { credential: 'account' });
  const order = res.json();
  ctx.setData('status', order.status);
  ctx.setData('items', order.items);
});

fluxdo.on('login', async (ctx) => {
  if (await ctx.api.credentials.request('account')) await loadBalance(ctx);
});
