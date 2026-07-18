// Bundle 入口：把 Discourse 官方 cook 管线封成两个全局函数。
//
//   __fluxdoCook.init(optJsonString) -> "ok"        （站点数据注入，建 engine）
//   __fluxdoCook.cook(rawMarkdown)   -> cooked HTML  （与服务端一致的输出）
//
// 数据流对齐 discourse 服务端 lib/pretty_text.rb 的 MiniRacer 上下文：
// 同一份 discourse-markdown-it + pretty-text 源码 + 官方插件 markdown
// features，只是 optInput 由 app 侧从 PreloadedDataService 提供。
import "./globals-setup.js";

import DiscourseMarkdownIt from "discourse-markdown-it";
import {
  emojiReplacementRegex,
  replacements as emojiReplacements,
} from "pretty-text/emoji/data";
import { applyCachedInlineOnebox } from "pretty-text/inline-oneboxer";
import { setLocalCache as setOneboxCache } from "pretty-text/oneboxer-cache";

// footnote 插件依赖 vendored UMD 全局（footnotes.js 检查
// window.markdownitFootnote）。esbuild 把 UMD 当 CJS 处理会走
// module.exports 分支、跳过全局挂载，所以这里显式挂回去。
import markdownitFootnote from "$discourse/plugins/footnote/assets/vendor/javascripts/markdown-it-footnote.js";

// 官方插件的 markdown features（全部纯 markdown-it、无 DOM）。
// 是否生效由 siteSettings 的对应开关决定（spoiler_enabled、poll_enabled、
// discourse_math_enabled…），与服务端行为一致——打包进来不会误开。
import * as spoilerAlert from "$discourse/plugins/spoiler-alert/assets/javascripts/lib/discourse-markdown/spoiler-alert.js";
import * as details from "$discourse/plugins/discourse-details/assets/javascripts/lib/discourse-markdown/details.js";
import * as footnotes from "$discourse/plugins/footnote/assets/javascripts/lib/discourse-markdown/footnotes.js";
import * as discourseMath from "$discourse/plugins/discourse-math/assets/javascripts/lib/discourse-markdown/discourse-math.js";
import * as poll from "$discourse/plugins/poll/assets/javascripts/lib/discourse-markdown/poll.js";
import * as policy from "$discourse/plugins/discourse-policy/assets/javascripts/lib/discourse-markdown/policy.js";
import * as checklist from "$discourse/plugins/checklist/assets/javascripts/lib/discourse-markdown/checklist.js";
import * as localDates from "$discourse/plugins/discourse-local-dates/assets/javascripts/lib/discourse-markdown/discourse-local-dates.js";
import * as chatTranscript from "$discourse/plugins/chat/assets/javascripts/lib/discourse-markdown/chat-transcript.js";
import * as chatHtmlInline from "$discourse/plugins/chat/assets/javascripts/lib/discourse-markdown/chat-html-inline.js";

globalThis.markdownitFootnote = markdownitFootnote;

// 对齐 discourse/app/static/markdown-it/features.js 的 loadPluginFeatures：
// { id, setup, priority }
function feature(id, mod) {
  return { id, setup: mod.setup, priority: mod.priority ?? 0 };
}

const PLUGIN_FEATURES = [
  feature("spoiler-alert", spoilerAlert),
  feature("details", details),
  feature("footnotes", footnotes),
  feature("discourse-math", discourseMath),
  feature("poll", poll),
  feature("policy", policy),
  feature("checklist", checklist),
  feature("discourse-local-dates", localDates),
  feature("chat-transcript", chatTranscript),
  feature("chat-html-inline", chatHtmlInline),
];

// ---------------------------------------------------------------------------
// hashtagLookup：客户端本地实现（服务端是 Ruby helper 查库）。
// 数据源 = /site 预加载里的 categories + top_tags，覆盖预览常用面；
// 查不到时返回 undefined → cook 输出 span.hashtag-raw（与 web 预览
// 未验证 hashtag 的降级一致）。
// 支持 `slug`、`parent:child`（分类层级）、`slug::type`（显式类型后缀）。
// ---------------------------------------------------------------------------
function buildHashtagLookup({ categories, tagNames, baseUri }) {
  const bySlug = new Map();
  const byId = new Map();
  for (const c of categories) {
    if (!c || typeof c.slug !== "string") {
      continue;
    }
    bySlug.set(c.slug.toLowerCase(), c);
    byId.set(c.id, c);
  }
  const tags = new Set(tagNames.map((t) => String(t).toLowerCase()));

  function categoryResult(cat, ref) {
    const parent = cat.parent_category_id
      ? byId.get(cat.parent_category_id)
      : null;
    const slugPath = parent ? `${parent.slug}/${cat.slug}` : cat.slug;
    const result = {
      type: "category",
      id: cat.id,
      slug: cat.slug,
      ref,
      text: cat.name ?? cat.slug,
      relative_url: `${baseUri}/c/${slugPath}/${cat.id}`,
    };
    // style_type/emoji/icon 是较新版本 discourse 的分类字段，有则透传。
    if (cat.style_type) {
      result.style_type = cat.style_type;
      if (cat.emoji) {
        result.emoji = cat.emoji;
      }
      if (cat.icon) {
        result.icon = cat.icon;
      }
    }
    return result;
  }

  function lookupCategory(ref) {
    // parent:child → 在 parent 下找 child
    if (ref.includes(":")) {
      const [parentSlug, childSlug] = ref.split(":");
      const parent = bySlug.get(parentSlug);
      if (!parent) {
        return undefined;
      }
      for (const c of bySlug.values()) {
        if (c.slug.toLowerCase() === childSlug && c.parent_category_id === parent.id) {
          return categoryResult(c, ref);
        }
      }
      return undefined;
    }
    const cat = bySlug.get(ref);
    return cat ? categoryResult(cat, ref) : undefined;
  }

  function lookupTag(ref) {
    if (!tags.has(ref)) {
      return undefined;
    }
    return {
      type: "tag",
      id: ref,
      slug: ref,
      ref,
      text: ref,
      relative_url: `${baseUri}/tag/${ref}`,
    };
  }

  return function hashtagLookup(slug, _userId, typesInPriorityOrder) {
    if (typeof slug !== "string" || !slug.length) {
      return undefined;
    }
    let ref = slug.toLowerCase();
    let forcedType = null;
    const typeSep = ref.indexOf("::");
    if (typeSep >= 0) {
      forcedType = ref.slice(typeSep + 2);
      ref = ref.slice(0, typeSep);
    }

    const order = forcedType
      ? [forcedType]
      : Array.isArray(typesInPriorityOrder) && typesInPriorityOrder.length
        ? typesInPriorityOrder
        : ["category", "tag"];

    for (const type of order) {
      let result;
      if (type === "category") {
        result = lookupCategory(ref);
      } else if (type === "tag") {
        result = lookupTag(ref);
      }
      if (result) {
        if (forcedType) {
          result.ref = slug.toLowerCase();
        }
        return result;
      }
    }
    return undefined;
  };
}

// ---------------------------------------------------------------------------
// unicode emoji → :name:（进而被 emoji feature 转成 <img class="emoji">）。
// 算法逐行照抄服务端 lib/pretty_text/shims.js 的 __setUnicode，保证与
// 服务端 cooked 一致（web composer 预览没这一步，我们比它更贴近服务端）。
// replacements / regex 数据来自 pretty-text/emoji/data（与服务端同源生成）。
// ---------------------------------------------------------------------------
function buildEmojiUnicodeReplacer() {
  const regexp = new RegExp(emojiReplacementRegex, "g");

  return function (text) {
    regexp.lastIndex = 0;

    let m;
    while ((m = regexp.exec(text)) !== null) {
      let match = m[0];

      let replacement = emojiReplacements[match];

      if (!replacement) {
        // if we can't find replacement for an emoji match
        // attempts to look for the same without trailing variation selector
        match = match.replace(/\ufe0f$/g, "");
        replacement = emojiReplacements[match];
      }

      if (!replacement) {
        continue;
      }

      replacement = ":" + replacement + ":";
      const before = text.charAt(m.index - 1);
      if (!/\B/.test(before)) {
        replacement = "\u200b" + replacement;
      }
      text = text.replace(match, replacement);
    }

    // fixes Safari VARIATION SELECTOR-16 issue with some emojis
    text = text.replace(/\ufe0f/g, "");

    return text;
  };
}

// ---------------------------------------------------------------------------
// init / cook
// ---------------------------------------------------------------------------
let engine = null;

function normalizeCustomEmoji(customEmoji) {
  // 接受 [{name, url}] 或 {name: url} 两种形态，输出 pretty-text/emoji
  // 期望的 map（opts.customEmoji[code].url || opts.customEmoji[code]）。
  if (Array.isArray(customEmoji)) {
    const map = {};
    for (const e of customEmoji) {
      if (e && typeof e.name === "string" && typeof e.url === "string") {
        map[e.name] = e.url;
      }
    }
    return map;
  }
  return customEmoji ?? {};
}

function init(optJsonString) {
  const d = JSON.parse(optJsonString);
  const siteSettings = d.siteSettings ?? {};
  const site = d.site ?? {};
  const baseUri = typeof d.baseUri === "string" ? d.baseUri : "";

  const getURL = (url) =>
    baseUri && typeof url === "string" && url.startsWith("/")
      ? baseUri + url
      : url;

  const hashtagConfigurations = site.hashtag_configurations ?? {};

  engine = DiscourseMarkdownIt.withCustomFeatures(PLUGIN_FEATURES).withOptions({
    siteSettings,
    getURL,
    formatUsername: (username) => username,
    customEmoji: normalizeCustomEmoji(d.customEmoji),
    customEmojiTranslation: site.custom_emoji_translation ?? {},
    emojiDenyList: site.denied_emojis ?? [],
    censoredRegexp: site.censored_regexp ?? [],
    watchedWordsReplace: site.watched_words_replace ?? null,
    watchedWordsLink: site.watched_words_link ?? null,
    additionalOptions: site.markdown_additional_options ?? {},
    emojiUnicodeReplacer: buildEmojiUnicodeReplacer(),
    previewing: true,
    hashtagTypesInPriorityOrder:
      hashtagConfigurations["topic-composer"] ?? ["category", "tag"],
    hashtagIcons: site.hashtag_icons ?? null,
    hashtagLookup: buildHashtagLookup({
      categories: Array.isArray(site.categories) ? site.categories : [],
      tagNames: Array.isArray(d.tagNames) ? d.tagNames : [],
      baseUri,
    }),
  });

  return "ok";
}

function cook(raw) {
  if (!engine) {
    throw new Error("__fluxdoCook.init() must be called first");
  }
  return engine.cook(raw);
}

// ---------------------------------------------------------------------------
// onebox seed：Dart 侧请求 /onebox 与 /inline-onebox 后把结果灌进
// pretty-text 的缓存，下一次 cook 时 onebox feature 直接命中——
// 与 Discourse web 预览「异步取回后再渲染」同一套缓存机制。
// ---------------------------------------------------------------------------

// 块级 onebox：/onebox 返回的 HTML 片段（aside.onebox…）。
// oneboxer-cache 的 lookupCache 读 `.outerHTML`，Discourse web 里存的是
// DOM 元素，这里裸引擎没有 DOM，用同形对象即可。
function seedOnebox(url, html) {
  // 首个标签注入 data-fluxdo-onebox-url 标记:站内话题的 onebox HTML
  // 是 aside.quote(与真引用卡同形),Dart 解析层靠此标记区分「onebox
  // 展开物(raw=裸 URL)」与「用户手写引用(raw=[quote])」——序列化
  // 写错即毁帖。标记只存在于编辑器预览 cook,服务端 cooked 永远没有。
  const cleanUrl = url.replace(/\/$/, "");
  const marked = String(html).replace(
    /<([a-zA-Z][\w-]*)/,
    (m, tag) =>
      `<${tag} data-fluxdo-onebox-url="${cleanUrl.replace(/"/g, "&quot;")}"`
  );
  setOneboxCache(cleanUrl, { outerHTML: marked });
  return "ok";
}

// 行内 onebox：/inline-onebox 返回的 {url, title, css_class}。
function seedInlineOnebox(url, title, cssClass) {
  applyCachedInlineOnebox(url, {
    url,
    title: title || null,
    css_class: cssClass || null,
  });
  return "ok";
}

globalThis.__fluxdoCook = {
  init,
  cook,
  seedOnebox,
  seedInlineOnebox,
  isReady: () => engine != null,
};
