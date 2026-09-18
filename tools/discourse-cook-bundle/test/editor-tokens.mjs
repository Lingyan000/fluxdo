// 真实 bundle 的编辑 parse 回归；所有正文和地址均为测试构造。
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import { serializeEditorTokens } from '../src/editor-token-dto.js';

const context = vm.createContext({ console });
vm.runInContext(await readFile(new URL('../../../assets/cook/discourse-cook.js', import.meta.url), 'utf8'), context);
const api = context.__fluxdoCook;
assert.throws(() => api.parseForEditor('测试'), /init/);
const options = {
  siteSettings: {
    enable_markdown_linkify: true, markdown_linkify_tlds: 'com|net|org',
    enable_mentions: true, enable_emoji: true, emoji_set: 'twitter',
    max_image_width: 690, max_image_height: 500,
    poll_enabled: true, poll_maximum_options: 30, spoiler_enabled: true,
    discourse_local_dates_enabled: true,
  },
  site: {
    censored_regexp: [{ '(mocksecret)': { case_sensitive: false } }],
    watched_words_replace: {
      '(?:\\W|^)(mockreplace)(?=\\W|$)': {
        regexp: '(mockreplace)', replacement: 'mockchanged', case_sensitive: false,
      },
    },
  },
};
api.init(JSON.stringify(options));
const flatten = (tokens) => tokens.flatMap(t => [t, ...flatten(t.children ?? [])]);
const parse = raw => {
  const dto = JSON.parse(api.parseForEditor(raw));
  assert.equal(dto.version, 1);
  for (const token of flatten(dto.tokens)) {
    assert.deepEqual(Object.keys(token).sort(), ['type', 'tag', 'nesting', 'attrs', 'content', 'markup', 'info', 'children', 'meta', 'map', 'block', 'hidden'].sort());
  }
  return dto.tokens;
};
const find = (raw, type) => flatten(parse(raw)).find(t => t.type === type);
const attrs = token => Object.fromEntries(token.attrs ?? []);

assert.deepEqual(parse(''), []);
assert.deepEqual(parse(' \n\t'), []);
assert.throws(() => api.parseForEditor(null));
const links = flatten(parse('[mock文字](https://mock.example.com/explicit) https://mock.example.com/auto <https://mock.example.com/angle>'));
const linkTokens = links.filter(t => t.type === 'link_open');
assert.equal(linkTokens.length, 3);
assert.equal(linkTokens[0].markup, '');
assert.equal(linkTokens[1].markup, 'linkify');
assert.equal(linkTokens[1].info, 'auto');
assert.equal(linkTokens[2].markup, 'autolink');
assert.equal(attrs(linkTokens[0]).href, 'https://mock.example.com/explicit');

const image = find('![mock图|640x480,50%](upload://mockPicture.png)', 'image');
assert.equal(image.content, 'mock图|640x480,50%');
assert.equal(attrs(image)['data-orig-src'], 'upload://mockPicture.png');
assert.equal(attrs(image).scale, '50');
assert.equal(image.children[0].content, image.content);

const grid = parse('[grid]\n![mock甲](upload://mockA.png)\n![mock乙](upload://mockB.png)\n[/grid]');
assert.equal(grid[0].type, 'bbcode_open');
assert.equal(attrs(grid[0]).class, 'd-image-grid');
assert.equal(flatten(grid).filter(t => t.type === 'image').length, 2);
assert.deepEqual(grid[0].map, [0, 3]); // 官方范围不含关闭行，不能伪装完整源码范围。
const details = parse('[details="mock摘要"]\nmock正文\n[/details]');
assert.equal(details[0].tag, 'details');
assert.equal(details[1].tag, 'summary');
assert.equal(details[2].content, 'mock摘要');
assert.equal(details[0].map, null); // 官方没有范围；不推断。
assert.deepEqual(details[0].meta.fluxdoSource, { startLine: 0, endLine: 3, tokenCount: details.length, root: true });
const quote = parse('[quote="mock_user, post:2, topic:42"]\nmock引用\n[/quote]');
assert.equal(quote[0].type, 'bbcode_open');
assert.equal(attrs(quote[0])['data-topic'], 42);
assert.ok(find('[spoiler]mock隐藏[/spoiler]', 'wrap_bbcode'));
const poll = parse('[poll type=regular results=always chartType=bar]\n* mock甲\n* mock乙\n[/poll]');
assert.equal(poll[0].type, 'poll_open');
assert.deepEqual(poll[0].meta.fluxdoSource, { startLine: 0, endLine: 4, tokenCount: poll.length, root: true });
const nestedPoll = parse('> [poll]\n> * mock甲\n> * mock乙\n> [/poll]');
assert.equal(nestedPoll.find(t => t.type === 'poll_open').meta.fluxdoSource.root, false);
assert.equal(attrs(poll[0])['data-poll-type'], 'regular');
assert.equal(attrs(poll[0])['data-poll-chartType'], 'bar');
assert.ok(poll.some(t => t.type === 'poll_info_open'));
assert.equal(attrs(find('[date=2027-03-12 time=09:30:00 timezone="Asia/Shanghai"]', 'span_open'))['data-timezone'], 'Asia/Shanghai');
assert.ok(find(':smile:', 'emoji'));
assert.ok(find('@mock_user', 'mention_open'));

const html = '<section data-mock="x">\nmock正文\n</section>\n';
assert.equal(parse(html)[0].content, html);
assert.equal(parse(html)[0].type, 'html_block');
assert.deepEqual(parse(html)[0].map, [0, 3]);
assert.equal(find('前 <kbd>后</kbd>', 'html_inline').content, '<kbd>');
assert.equal(find('[unknown]mock[/unknown]', 'text').content, '[unknown]mock[/unknown]');
const code = parse('```html\n<div> mock </div>  \n\n```')[0];
assert.equal(code.type, 'fence');
assert.equal(code.info, 'html');
assert.equal(code.markup, '```');
assert.equal(code.content, '<div> mock </div>  \n\n');
assert.equal(find('    mock  \n\n    second\n', 'code_block').content, 'mock  \n\nsecond\n');

// 阅读替换及 onebox 缓存不能污染编辑 token；交错调用也不能改变原文。
const source = 'mocksecret mockreplace\n\nhttps://mock.example.com/deep/path';
const before = api.parseForEditor(source);
assert.ok(before.includes('mocksecret mockreplace'));
assert.ok(!before.includes('onebox'));
assert.ok(api.cook(source).includes('mockchanged'));
assert.ok(!api.cook(source).includes('mocksecret'));
api.seedOnebox('https://mock.example.com/deep/path', '<aside class="onebox">mock卡片</aside>');
api.seedInlineOnebox('https://mock.example.com/deep/path', 'mock标题', null);
api.parseForEditor(html);
api.cook(source);
assert.equal(api.parseForEditor(source), before);
assert.equal(api.cookForEditor, undefined);
assert.ok(JSON.parse(api.parseForEditor(html)).tokens.some(t => t.type === 'html_block'));
assert.ok(api.cook(html).includes('mock正文'));

// 未知插件 meta 保留 JSON 结构；不执行 toJSON/访问器，不悄悄截断循环。
const base = { type: 'mock', tag: '', nesting: 0, attrs: null, content: '', markup: '', info: '', children: null, meta: null, map: null, block: false, hidden: false };
const dto = meta => serializeEditorTokens([{ ...base, meta }]);
const shared = { mock: [1, true, null, '值'] };
assert.deepEqual(JSON.parse(JSON.stringify(dto({ a: shared, b: shared }))).tokens[0].meta, { a: shared, b: shared });
const circular = {}; circular.self = circular;
for (const invalid of [circular, undefined, NaN, Infinity, 1n, new Date(), () => {}, { get x() { throw Error('不应执行'); } }, { toJSON() { return '不应执行'; } }]) {
  if (invalid === undefined) continue; // token.meta 缺省按 null 处理。
  assert.throws(() => dto(invalid));
}
const token = { ...base }; token.children = [token];
assert.throws(() => serializeEditorTokens([token]), /循环/);
let deep = {}; for (let i = 0; i < 260; i++) deep = { deep };
assert.throws(() => dto(deep), /嵌套过深/);
console.log('✓ 编辑 token：基础、链接、图片、grid/details/quote/spoiler/poll/date、HTML/raw/fence、引擎隔离与 JSON 安全全部通过');

assert.equal(JSON.stringify(dto({ label: undefined }).tokens[0].meta), '{}');
