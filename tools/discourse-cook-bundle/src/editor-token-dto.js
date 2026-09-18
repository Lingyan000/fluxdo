// DTO v1：不调用 toJSON，也不静默删除未知插件元数据；不可表达时安全失败。
export function serializeEditorTokens(tokens) {
  const ancestors = new Set();
  function enter(value, callback) {
    if (ancestors.has(value)) throw new Error("编辑 token 存在循环引用");
    if (ancestors.size >= 256) throw new Error("编辑 token 嵌套过深");
    ancestors.add(value);
    try { return callback(); } finally { ancestors.delete(value); }
  }
  function jsonValue(value) {
    if (value === null || typeof value === "string" || typeof value === "boolean") return value;
    if (typeof value === "number" && Number.isFinite(value)) return value;
    if (typeof value !== "object") throw new Error("编辑 token 元数据不是 JSON 值");
    return enter(value, () => {
      if (Array.isArray(value)) return Array.from(value, jsonValue);
      const proto = Object.getPrototypeOf(value);
      if (proto !== Object.prototype && proto !== null) throw new Error("编辑 token 元数据不是普通对象");
      if (Object.getOwnPropertySymbols(value).length) throw new Error("编辑 token 元数据含 Symbol");
      const result = Object.create(null);
      for (const key of Object.keys(value)) {
        const descriptor = Object.getOwnPropertyDescriptor(value, key);
        if (!Object.prototype.hasOwnProperty.call(descriptor, "value")) throw new Error("编辑 token 元数据含访问器");
        // 官方脚注等 token 的可选属性会显式为 undefined，按 JSON 对象语义省略。
        if (descriptor.value !== undefined) result[key] = jsonValue(descriptor.value);
      }
      return result;
    });
  }
  function tokenDto(token) {
    return enter(token, () => ({
      type: token.type,
      tag: token.tag,
      nesting: token.nesting,
      attrs: token.attrs == null ? null : jsonValue(token.attrs),
      content: token.content,
      markup: token.markup,
      info: token.info,
      children: token.children == null ? null : enter(token.children, () => token.children.map(tokenDto)),
      meta: token.meta == null ? null : jsonValue(token.meta),
      map: token.map == null ? null : jsonValue(token.map),
      block: token.block,
      hidden: token.hidden,
    }));
  }
  return { version: 1, tokens: enter(tokens, () => tokens.map(tokenDto)) };
}
