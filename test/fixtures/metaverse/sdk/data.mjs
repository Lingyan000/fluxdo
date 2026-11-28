/** 查询工具只调度调用方提供的读取函数；不会重试或推断业务写操作。 */
export class QueryCancelledError extends Error {
  constructor() { super('query_cancelled'); this.name = 'QueryCancelledError'; }
}
const copy = value => value === undefined ? undefined : JSON.parse(JSON.stringify(value));
function keyOf(value) {
  function normalize(v) {
    if (Array.isArray(v)) return v.map(normalize);
    if (v && typeof v === 'object') return Object.fromEntries(Object.keys(v).sort().map(k => [k, normalize(v[k])]));
    if (v === null || ['string','boolean'].includes(typeof v) || typeof v === 'number' && Number.isFinite(v)) return v;
    throw new TypeError('query_key_invalid');
  }
  return JSON.stringify(normalize(value));
}
function options(ttl, tags) {
  if (!Number.isFinite(ttl) || ttl < 0 || !Array.isArray(tags) || tags.some(tag => typeof tag !== 'string')) throw new TypeError('query_options_invalid');
}
function notify(callback, ...args) {
  // 观察者报错不改变请求的成功状态，也不让加载标记卡住。
  try { callback(...args); } catch (error) { console.error('data_observer_failed', String(error?.message ?? error)); }
}

export function createQueryClient({identity = null, maxEntries = 64, maxBytes = 2 * 1024 * 1024, now = () => Date.now()} = {}) {
  if (!Number.isInteger(maxEntries) || maxEntries < 1 || maxEntries > 1024 || !Number.isInteger(maxBytes) || maxBytes < 1) throw new TypeError('query_limits_invalid');
  const entries = new Map(), listeners = new Set();
  let generation = 0, disposed = false, currentIdentity = keyOf(identity), bytes = 0;
  function alive() { if (disposed) throw new QueryCancelledError(); }
  function state(entry) { return entry ? {data: copy(entry.data), loading: !!entry.pending, error: entry.error, stale: entry.expires <= now()} : {data: undefined, loading: false, error: null, stale: true}; }
  function emit(key, entry) { for (const listener of [...listeners]) notify(listener, copy(key), state(entry)); }
  function remove(id) { const entry = entries.get(id); if (entry) { entry.revision++; bytes -= entry.bytes; entries.delete(id); } }
  function clear() { generation++; entries.clear(); bytes = 0; }
  function entryFor(key) {
    const id = keyOf(key); let entry = entries.get(id);
    if (!entry) {
      while (entries.size >= maxEntries) remove(entries.keys().next().value);
      entry = {key: copy(key), revision: 0, data: undefined, bytes: 0, expires: 0, error: null, pending: null, tags: []};
    }
    entries.delete(id); entries.set(id, entry); return [id, entry];
  }
  function save(id, entry, data, ttl) {
    const serialized = JSON.stringify(data);
    if (serialized === undefined) throw new TypeError('query_data_invalid');
    // UTF-16 字符的 UTF-8 最多三个字节，以保守上限限制内存。
    const size = serialized.length * 3;
    if (size > maxBytes) throw new Error('query_cache_limit');
    while (bytes - entry.bytes + size > maxBytes) {
      const victim = [...entries.keys()].find(k => k !== id);
      if (victim === undefined) break;
      remove(victim);
    }
    bytes += size - entry.bytes; entry.bytes = size; entry.data = JSON.parse(serialized); entry.expires = now() + ttl;
  }
  return {
    peek(key) { alive(); return state(entries.get(keyOf(key))); },
    query(key, load, {ttl = 0, force = false, tags = []} = {}) {
      alive(); options(ttl, tags);
      const [id, entry] = entryFor(key);
      if (!force && entry.pending) return entry.pending;
      if (!force && entry.data !== undefined && entry.expires > now()) return Promise.resolve(copy(entry.data));
      const revision = ++entry.revision, epoch = generation;
      const active = () => !disposed && epoch === generation && entries.get(id) === entry && revision === entry.revision;
      entry.tags = [...new Set(tags)]; entry.error = null;
      const pending = Promise.resolve().then(() => { if (!active()) throw new QueryCancelledError(); return load({isCurrent: active}); }).then(value => {
        if (!active()) throw new QueryCancelledError(); save(id, entry, value, ttl); return copy(entry.data);
      }, error => { if (!active()) throw new QueryCancelledError(); throw error; }).catch(error => {
        if (active()) entry.error = String(error?.message ?? error); throw error;
      }).finally(() => { if (active()) { entry.pending = null; emit(key, entry); } });
      entry.pending = pending; emit(key, entry); return pending;
    },
    update(key, update, {ttl = 0, tags = []} = {}) {
      alive(); options(ttl, tags); const [id, entry] = entryFor(key);
      const value = update(copy(entry.data));
      save(id, entry, value, ttl); entry.revision++; entry.pending = null; entry.error = null; entry.tags = [...new Set(tags)]; emit(key, entry);
    },
    invalidate({key, tags} = {}) {
      alive(); if (tags !== undefined) options(0, tags);
      const target = key === undefined ? null : keyOf(key);
      for (const [id, entry] of entries) {
        if (target !== null ? target !== id : tags && !entry.tags.some(tag => tags.includes(tag))) continue;
        entry.revision++; entry.pending = null; entry.expires = 0; emit(entry.key, entry);
      }
    },
    subscribe(listener) { alive(); listeners.add(listener); return () => listeners.delete(listener); },
    setIdentity(value) {
      alive(); const next = keyOf(value); if (next === currentIdentity) return;
      currentIdentity = next; const keys = [...entries.values()].map(e => e.key); clear();
      for (const key of keys) emit(key, null);
    },
    clear() { alive(); const keys = [...entries.values()].map(e => e.key); clear(); for (const key of keys) emit(key, null); },
    dispose() { if (!disposed) { clear(); listeners.clear(); disposed = true; } },
  };
}

/** 页面自己的分页控制器；离页或筛选变化后不再接收旧请求。 */
export function createPagedList({load, itemKey, onChange = () => {}}) {
  let identity = null, revision = 0, pending = null, disposed = false;
  let state = {items: [], nextCursor: null, loaded: false, loading: false, loadingMore: false, error: null};
  function emit() { notify(onChange, copy(state)); }
  function cancel() { revision++; pending = null; state.loading = false; state.loadingMore = false; }
  const api = {
    get state() { return copy(state); },
    reset(value) { if (disposed) throw new QueryCancelledError(); const next = keyOf(value); if (identity === next) return; cancel(); identity = next; state = {items: [], nextCursor: null, loaded: false, loading: false, loadingMore: false, error: null}; emit(); },
    load({more = false} = {}) {
      if (disposed) return Promise.reject(new QueryCancelledError());
      if (pending) return pending;
      if (more && (!state.loaded || state.nextCursor === null)) return Promise.resolve(api.state);
      const current = ++revision, cursor = more ? state.nextCursor : null;
      const active = () => !disposed && revision === current;
      state.loading = !more; state.loadingMore = more; state.error = null;
      pending = Promise.resolve().then(() => { if (!active()) throw new QueryCancelledError(); return load({cursor, identity: identity === null ? null : JSON.parse(identity), isCurrent: active}); }).then(page => {
        if (!active()) throw new QueryCancelledError();
        if (!page || !Array.isArray(page.items) || !('nextCursor' in page)) throw new TypeError('pagination_result_invalid');
        const rows = new Map((more ? state.items : []).map(item => [keyOf(itemKey(item)), item]));
        for (const item of page.items) rows.set(keyOf(itemKey(item)), copy(item));
        const next = more && keyOf(page.nextCursor) === keyOf(cursor) ? null : copy(page.nextCursor);
        state.items = [...rows.values()]; state.loaded = true; state.nextCursor = next;
      }, error => { if (!active()) throw new QueryCancelledError(); throw error; }).catch(error => {
        if (active()) state.error = String(error?.message ?? error); throw error;
      }).finally(() => { if (active()) { pending = null; state.loading = false; state.loadingMore = false; emit(); } }).then(() => api.state);
      emit(); return pending;
    },
    update(update) { if (disposed) throw new QueryCancelledError(); const items = copy(update(copy(state.items))); if (!Array.isArray(items)) throw new TypeError('pagination_items_invalid'); cancel(); state.items = items; emit(); },
    cancel() { if (!disposed) { cancel(); emit(); } },
    dispose() { cancel(); disposed = true; },
  };
  return api;
}
