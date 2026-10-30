// 独立审计夹具：真实 bundle、小型构造正文，不访问网络。
import {readFile,writeFile} from 'node:fs/promises';
import vm from 'node:vm';
const context=vm.createContext({console});
vm.runInContext(await readFile(new URL('../../../assets/cook/discourse-cook.js',import.meta.url),'utf8'),context);
const api=context.__fluxdoCook;
api.init(JSON.stringify({siteSettings:{enable_markdown_linkify:true,enable_mentions:true,enable_emoji:true,emoji_set:'twitter',poll_enabled:true,poll_maximum_options:30,spoiler_enabled:true,discourse_local_dates_enabled:true,enable_markdown_footnotes:true,discourse_math_enabled:true,discourse_math_enable_asciimath:true,discourse_math_provider:'mathjax'}}));
const cases={
 mathAscii:'前 %x+y% 后',mathTex:'前 $x+y$ 后',mathBlock:'$$\nx+y\n$$',
 hashtag:'前 #mock 后',nestedPoll:'> [poll]\n> * 甲\n> * 乙\n> [/poll]',
 emptyQuote:'>',emptyDetails:'[details="mock"]\n[/details]',emptySpoiler:'[spoiler]\n[/spoiler]',
 nestedList:'* mock\n\n  3. nested\n  4. second',
 tableCaption:'<table>\n<caption>mock说明</caption>\n<tr><th>甲</th></tr><tr><td>乙</td></tr>\n</table>',
 adjacentLists:'3. 甲\n\n<!-- 分隔 -->\n\n7. 乙',
 htmlEmpty:'前 <kbd></kbd> 后',
 htmlNestedSize:'前 <small>甲 <small>乙</small> 丙</small> 后',
 attachment:'[mock|attachment](upload://mock.pdf)',
 bbUnderline:'[u]mock[/u]', bbStrike:'[s]mock[/s]',
 wrap:'[wrap data-mock="x"]\n正文\n[/wrap]',
 dateRecurring:'[date=2027-03-12 recurring="1.months" timezone="Asia/Shanghai"]',
 dateCountdown:'[date=2027-03-12 countdown=false]',
 dateRange:'[date-range from=2027-03-12 to=2027-03-15 timezone="Asia/Shanghai"]',
 htmlNested:'前 <kbd>甲 <kbd>乙</kbd> 丙</kbd> 后',htmlUnderline:'前 <u>mock</u> 后',
 bbBold:'[b]mock[/b]',bbItalic:'[i]mock[/i]',
 table:'|甲|乙|\n|---|---|\n|a|b|',tableAlign:'|甲|乙|\n|:---|---:|\n|a|b|',
 caption:'![mock](upload://mock.png)\n*mock caption*',
 poll:'[poll type=regular results=always chartType=bar]\n* 甲\n* 乙\n[/poll]',
 quoteAttrs:'[quote="mock, post:2, topic:42, full:true"]\n正文\n[/quote]',
 spoilerInline:'前 [spoiler]mock[/spoiler] 后',
 footnote:'正文[^1]\n\n[^1]: 注释',linkTitle:'[mock](https://mock.example "title")',
 headingAttrs:'# mock',check:'* [x] mock',
};
const out={};
for(const [name,raw] of Object.entries(cases)) out[name]={raw,cooked:api.cook(raw),...JSON.parse(api.parseForEditor(raw))};
await writeFile(new URL('../../../packages/fluxdo_render/test/fixtures/audit_token_matrix.json',import.meta.url),JSON.stringify(out,null,2)+'\n');
console.log(`审计真实 bundle 夹具 ${Object.keys(out).length} 项`);
