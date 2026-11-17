// 生命周期和用户操作都使用 ctx.api，日志自动关联当前页面。
fluxdo.on('card.load', async ctx => {
  const count = await ctx.api.storage.get<number>('count') ?? 0;
  ctx.setData('count', count);
});
fluxdo.on('increment', async ctx => {
  const approved = await ctx.api.dialogs.confirm({
    title: '更新计数', message: '确认后会更新此插件的本地计数。', confirmLabel: '确认',
  });
  if (!approved) return;
  const count = (await ctx.api.storage.get<number>('count') ?? 0) + 1;
  await ctx.api.storage.set('count', count);
  ctx.setData('count', count);
  await ctx.api.toast('计数已更新', 'success');
});
