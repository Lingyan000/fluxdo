# Changelog

所有版本的变更记录。beta / rc 版本提交在 stable 发版时会折叠并入对应 stable 版本。

## [0.2.27] - 2026-08-21


### 🌟 新功能

- 搜索卡片长按预览:一镜到底 + 排版对齐话题预览 by @Lingyan000

- 密文嗅探增强:Base32 + 内容探测建议 + enc 块语言信号 + 折行/分隔形态 by @Lingyan000

- 话题卡长按预览一镜到底:壳从卡片连续变形,内容嵌壳随飞 by @Lingyan000

- 加解密工具箱:划词解密 + 编辑器加密 + 算法选择器 by @Lingyan000

- 图片长按浮起菜单:对齐 X/iOS 系统上下文菜单动效 by @Lingyan000

- 底部弹框支持预测式返回:慢划边缘跟手下滑 by @Lingyan000

- 「切兼容模式」询问增加第二条出路:关闭自动过盾 by @Lingyan000

- Spoiler 揭开涟漪动画 + 移除二次点击回遮(fluxdo_render:Telegram startRipple 同款圆形裁剪扩散 + 遮罩淡出) by @Lingyan000

- 放大态返回让 Hero 承载缩放:删掉「先归位再起飞」两段动作 by @Lingyan000

- 悬浮胶囊底栏:选中态改满槽极淡底,几何锁比例 by @Lingyan000

- 树形视图话题内跳转:统一分发到 context 定位,对齐 Discourse nested 路由重定向 by @Lingyan000

- 话题目录(TOC)面板:对齐 DiscoTOC 的目录树与锚点跳转 by @Lingyan000

- 恢复层落地:单一重放引擎 + 限流/瞬态两个策略,退役 dio_smart_retry by @Lingyan000

- 网络健康快照:五处状态源聚合为单一只读视图 + 日志导出 by @Lingyan000

- 主题系统扩展:中性/纯黑独立开关 + 自定义背景透明模式 + 调色板主题色彩 by @Lingyan000

- 查看器预测返回缩放松弛:跟手渐进归位替代瞬时跳变 by @Lingyan000

- 话题内支持只看任意用户:用户卡片/头像菜单过滤入口 + 卡片按钮排版优化 by @Lingyan000

- 更新系统支持自定义 GitHub 反代前缀 by @Lingyan000


### 🐛 修复

- 修公平运存检测不到:补 KILL 特征串+回执改发本次 callback by @Lingyan000

- 修 HyperOS 小窗空白只剩底栏:钳制虚报的 captionBar 顶 padding by @Lingyan000

- 飞行体贴源端按源端展示方式算,不再被放大态覆盖 by @Lingyan000

- 放大后返回:飞行中取景框张回完整图,不再落地才突变 by @Lingyan000

- 聊天图片返回尾帧停在裁切态:补 heroSourceFit 告知查看器 by @Lingyan000

- 加解密嗅探鲁棒性:摩斯 Unicode 变体识别 + URL 编码嗅探 by @Lingyan000

- 修聊天跳转消息:原地定位替代整页替换,首次点击不再卡住 by @Lingyan000

- 修富文本无法开启:行内 spoiler 整段写回被 cook 块规则吞成 div(fluxdo_render:命中形态段落行尾补双空格保行内 span) by @Lingyan000

- 补轮播放大态返回的飞行起点:大图不再瞬间变小 by @Lingyan000

- 修代码块内部分选中复制被强包 ```lang(fluxdo_render:选区覆盖完整块才带语言,部分选中复制为纯文本) by @Lingyan000

- 修轮播图返回:尾帧铺满槽位、且图被裁切 by @Lingyan000

- 修复投票/政策操作后滚出滚回状态丢失 by @Lingyan000

- 修复 cf_clearance 被旧值覆盖导致的 CF 验证循环:被拒值墓碑 + 防旧盖新守卫 by @Lingyan000

- 修复 CF 验证通过后 ScreenTrack 无法恢复阅读时长上报 by @Lingyan000

- 修 CF 失败计数口径:按验证轮次而非并发请求个数 by @Lingyan000

- 修 Hero 飞行被 pop 打断时源端锁死不可见的黑闪 by @Lingyan000

- 修 Hero 飞行未完成时关闭图片查看器的黑闪 by @Lingyan000

- 表格图片 cell 崩溃+缩略图(fluxdo_render:行弃 IntrinsicHeight 竖线通高绘制 + 列宽补采 <img width>) by @Lingyan000

- 消除返回重播:commit 自己收尾,不触发框架的二次 reverse by @Lingyan000

- 修进度条概率跳顶/跳底:弹簧过冲期冻结 eyeline 上报,整流刷新落地重锚视口 by @Lingyan000

- 修树形视图帖子不展示解决方案标识:树节点补齐水印章与三轨状态同步 by @Lingyan000

- 恢复层不再重放 FormData/Stream 请求体;清理死参数与冗余重试 by @Lingyan000

- 连划黑底根因:手势期冻结分支剥掉了背景填充,露出 Navigator 黑底 by @Lingyan000

- 修自定义底栏重新登录后跳到第二个 tab:当前页改按稳定 id 跟踪 by @Lingyan000

- 连划黑底:OnBackInvokedCallback 常驻注册(原生终点闸门) by @Lingyan000

- 修退出登录卡「正在退出…」真凶:mounted 失效导致 loading 关不掉 by @Lingyan000

- 修退出登录卡「正在退出…」:异常路径下 loading 永不关闭 by @Lingyan000

- 修退出登录一直 loading:自愈误接手登出 401 触发 sweep 重放 by @Lingyan000

- CF 验证两处放弃时机修正:无 UI 环境不再挂死,拒绝记忆改带时效 by @Lingyan000

- 资料页横屏头部溢出叠印:高度受限时精简头部(隐简介卡/活跃胶囊),骨架屏同步 by @Lingyan000

- 修拦截器链两处时序错误:自愈注册顺序 + 429/5xx 丢 response by @Lingyan000

- 修长帖内容字体大小设置不生效:chunk 渲染漏传 baseTextStyle(含 contentFontScale),回退成了默认字号 by @Lingyan000

- 修 div[align]/center 容器内列表/表格不居中(fluxdo_render:对齐下放覆盖 list/table + cell align) by @Lingyan000

- 附件下载图标垂直居中 by @Lingyan000

- 连划黑边 logcat 定案:双击退出模式静默认领被 popDisposition 拒绝 by @Lingyan000

- 修 CF 挑战型 429 无法自愈:判定去 server 头前置闸 + CSRF 刷新失败冷却 by @Lingyan000

- 查看器缩放松弛补完:commit 后骑退场动画收拢,消灭松手 snap by @Lingyan000

- 修 iOS 概率启动泛紫:校准层图块避开 GPU 不可用窗口期 by @Lingyan000

- 嵌套 Navigator 弹层 ESC 隐形:先关弹框不再误关平行视界层 by @Lingyan000

- 连划黑底最后一环:手势进行中禁撤 OnBackInvokedCallback 注册 by @Lingyan000

- 表情包加载失败可诊断:结构化日志落盘 + 界面查看详情入口 by @Lingyan000

- 全屏侧滑返回让位平台视图:WebView 区域落点不参赛 by @Lingyan000

- 预测返回两残余症状定案:陈旧 cancel 毒计数 + 根路由退场窗口无人认领 by @Lingyan000

- 连划黑边与锁屏后预测返回失效的共同上游:引擎回调注册态失守 by @Lingyan000


### ⚡ 性能

- 主贴 cooked 改走 posts#by_number 单帖接口:只回一帖 JSON,比 TopicView(20 楼 chunk)轻量得多 by @Lingyan000


### ♻️ 重构

- 六处图片源端全部迁到 HeroImage 统一件 by @Lingyan000

- 源端展示方式收成单一描述:ViewerSourceStyle by @Lingyan000

- 放大态返回的飞行起点收口成共享函数,补齐漏掉的四处 by @Lingyan000

- 余下 6 处底部弹框迁到统一入口,一并拿到预测返回 by @Lingyan000

- 返回转场统一为 Cupertino 单分支:消灭同页面两种退出动画 by @Lingyan000

- CSRF 刷新迁主链,自建迷你 Dio 退役 by @Lingyan000

- 会话自愈与引擎降级迁入恢复层,两个旧拦截器退役 by @Lingyan000

- 请求语义读取侧收口到 FluxRequestSpec by @Lingyan000

- 渲染校准层 v2 形态:超周期去周期化 + 饱和避让 + 提取器自适应限幅 by @Lingyan000


### 📝 文档

- 起草 v0.2.27 版本亮点 by @Lingyan000

- 记录 CF 盾不迁恢复层的定案与边界(评估后放弃 M5-b) by @Lingyan000


### ✅ 测试

- 补网络层三条跨层契约测试:限流重试/静默原始错误/OTP 兑换豁免 by @Lingyan000


### 🎨 样式

- 功能设置页重新分类 + 设置搜索定位修复 by @Lingyan000


### 🔧 其他

- 🔥 移除渲染校准层 by @Lingyan000

- 💄 预览细节打磨:圆角随位同步定形 + loading 换骨架屏 by @Lingyan000

- 💄 预览弹窗改版:轻量排版 + 长按意图预加载正文 by @Lingyan000

- 💬 补「关闭自动验证」链接的引导语文案 by @Lingyan000

- ⏪ 撤销连划黑底的全部无效修复,保留锁屏与 Hero 相关成果 by @Lingyan000

- 🔍 预测返回黑底染色探针:分层判定黑区归属(默认关闭) by @Lingyan000

- 🧹 清理误诊期的冗余改动与错误因果注释 by @Lingyan000

- 🧹 清理请求 extra 死键,并让 requestTag 诊断口真正可用 by @Lingyan000

- 💄 搜索胶囊 Hero 飞行体插值化:消除起飞/落地两端跳变 by @Lingyan000

- ⬆️ fluxdo_render:编辑器软换行吞 mark + 投影原子性失配修复 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.2.26...v0.2.27

## [0.2.26] - 2026-08-07


### 🌟 新功能

- 话题/帖子指定功能(discourse-assign):数据层+弹窗+三管线系统帖识别+siteSettings 门控 (#363) ([#363](https://github.com/lingyan000/fluxdo/pull/363)) by @homo11451419

- 话题标记为未读:二级菜单双语义(回退一层/清空进度)+上报侧 abandon+双头游标显式回退 by @Lingyan000

- 平行视界大修:胶片带层间动画+同树投影+ESC 路由级兜底+资料页宽版排版 by @Lingyan000

- 投票饼图对齐网页版 + 问答评论输入桌面/移动分流 by @Lingyan000

- 问答话题(post-voting)全套:创建/赞成反对/专属排版/评论 by @Lingyan000

- 投票构建器:创建/编辑全表单化 + 编辑器预览卡 + 饼图结果 by @Lingyan000

- 树形视图三连:通知 context 定位视图+失败自动回落平铺+正文划词引用 by @Lingyan000

- Hero 路由接入预测返回跟手飞行:认领手势与预览解耦 by @Lingyan000

- 增强 Android 预测式返回支持 (#370) by @yorkyang2333

- Chat 移动端打磨:长按气泡壳/键盘面板协作/内边距收紧 + 已读上报官方化 by @Lingyan000

- Chat DM 全量落地:频道/消息流/表情包直发/删除展开/置顶/收藏/用户卡片 by @Lingyan000

- Hashtag 药丸宿主接线:分类真图标 + 平行视界导航 by @Lingyan000

- 话题列表未读实时同步:双向单调合并追踪状态 (#366) ([#366](https://github.com/lingyan000/fluxdo/pull/366)) by @homo11451419

- 跨设备扫码登录:key+OTP 协议 + 平台自适应弹层 (#358) ([#358](https://github.com/lingyan000/fluxdo/pull/358)) by @stevessr

- 帖子纪念日/生日图标 + Premium 头衔渐变 + 徽章 tooltip 修复 (#356) ([#356](https://github.com/lingyan000/fluxdo/pull/356)) by @homo11451419

- 编辑器即时渲染模式:composerLiveRender 设置 + fluxdo_render ir 内核 by @Lingyan000

- 校准提取器小截图增强:方差加权投票 + 全块共识复核 by @Lingyan000

- 平行视界统一化:空态铺底/ESC 体系/草稿页独立双栏 by @Lingyan000

- 播放器移动端手势补全 + M3E 形态 + 交互修复 by @Lingyan000

- 渲染管线校准层:全屏/分享图合成一致性 by @Lingyan000

- 播放器重做:六端统一自绘控制层 + media_kit 桌面后端 by @Lingyan000

- 图片查看器开合转场:裁切插值飞行体 + 动图退役帧修复 by @Lingyan000

- 页面弹窗新增全屏打开按钮 by @Lingyan000

- 富文本编辑器体验与稳定性修复批次 (#355) ([#355](https://github.com/lingyan000/fluxdo/pull/355)) by @homo11451419

- 通知落点重构:大屏页面弹窗 + 通知翻页/列表,点击零延迟 by @Lingyan000

- 全屏侧滑返回开关:页面任意位置右滑返回上一页,默认关闭 by @Lingyan000

- 平行视界与追觅功能 (#340) by @homo11451419

- 话题详情底部推荐话题(相关/建议),阅读设置可关 by @Lingyan000


### 🐛 修复

- 通知链路四修:弹窗二跳全屏化/查看器 Hero 退化/移动端面板保留/横屏 Rail 让位 by @Lingyan000

- Details 折叠块在楼层上方展开时标题被顶出视口:锚定哨兵补齐三处 by @Lingyan000

- 连划返回黑边:转场期静默认领 + windowBackground 主题化 by @Lingyan000

- 正文轮播图桌面端鼠标/触控板无法拖拽翻页 by @Lingyan000

- 图片查看器放大后返回闪烁:退场瞬间缩放归位 by @Lingyan000

- 移动端通知徽章不显示:计数 provider 改「实时更新前跟随服务端」 by @Lingyan000

- Commit 收尾窗口锁屏毒化手势计数:代打 cancel 收紧到活跃 phase by @Lingyan000

- 饼图判定改以 API poll.chart_type 为主源 by @Lingyan000

- 内联图标行内上飘修复:字形 span 改回 WidgetSpan 行中线对齐 by @Lingyan000

- 个人页头像预测返回不飞:源端 Hero 补 transitionOnUserGestures by @Lingyan000

- 后台/锁屏打断预测返回手势后永久失效:代打 cancel 归零手势态 by @Lingyan000

- 播放器音量/亮度 HUD:100% 文本折行修复 by @Lingyan000

- 预测返回 commit 收尾动画被吞:静态背景判定改用 phase 而非 isCurrent by @Lingyan000

- 聊天输入框表情后光标错位:WidgetSpan 等长补位(U+2060 零宽填充,boost 输入条同款) by @Lingyan000

- 修复预测返回交互回归 by @Lingyan000

- 面板容器闪白底(panelBgColor 默认纯白,深色主题跟 scaffold 底色)+返回键拦截失效(面板态提为页面状态驱动 canPop) by @Lingyan000

- 长按副本矩形外扩气泡壳内边距(短消息竖排/长消息菜单叠压根修)+菜单钉屏下缘 by @Lingyan000

- 聊天列表下拉刷新失灵:TabBarView 内列表 depth=1,补 notificationPredicate by @Lingyan000

- 举报标题补显 + 底栏上限自适应 + 编辑器附件上传(白名单动态派生) (#367) ([#367](https://github.com/lingyan000/fluxdo/pull/367)) by @homo11451419

- 修复 Windows render-signet 大色块:图块笔刷禁用拉伸 by @Lingyan000

- 修复创建帖子编辑区顶底跳跃:光标跟随锚定正文输入框 (#337) by @Lingyan000

- Win+V 贴图/插链接失效:可逆修饰键路径改用宽松版判定 by @Lingyan000

- IOS 校准层回退内联:原生 CALayer 路径下线止血 by @Lingyan000

- 修复 macOS 启动时未恢复窗口状态 + 隐藏启动消除闪跳 (#343) ([#343](https://github.com/lingyan000/fluxdo/pull/343)) by @Yuv96

- 登录收尾刷新与元素生死解耦:修复扫码登录后无登录态需重启 by @Lingyan000

- Preloaded 链路补强:解析失败不再静默 + 当前用户渐进 emit by @Lingyan000

- 提取器共识复核补 ratio 下限:堵错误缩放档混叠假阳性 by @Lingyan000

- 规避桌面端原生崩溃:CF WebView 定位/后台缓存清理/cookie 同步节流 ([#364](https://github.com/lingyan000/fluxdo/pull/364)) by @homo11451419

- 帧监控 revision 通知避开 build 阶段:persistentCallbacks 推迟帧后合并 by @Lingyan000

- 修 Android 偶现启动白屏:内联校准层改「消饱和+单极性」 by @Lingyan000

- 播放器移动端交互修正:双击全区播停 + 紧凑单行条 + 防闪现 by @Lingyan000

- 修话题列表透明 gif 头像双影:动图首帧就绪后收起静态打底层 by @Lingyan000

- 修 Windows 校准层编译错:ABI 枚举缺命名空间限定 by @Lingyan000

- 修复第一页未加载时话题详情页 AppBar 不变色 by @Lingyan000

- 划词引用反查修复:meta 遮罩去噪 + 全选快路径 + 引用头对齐官方 (#352) ([#352](https://github.com/lingyan000/fluxdo/pull/352)) by @homo11451419

- 双栏初次加载后点 boost 触发假跳转+帖子高亮 by @Lingyan000

- 性能与桌面交互修复 (#341) by @homo11451419

- 锚定哨兵盲区:视口停在推荐区等单盒 sliver 时新帖落地无补偿 by @Lingyan000

- 在底部看帖时收到新回复,列表闪跳到最后一帖 by @Lingyan000

- 内容与媒体功能 (#339) ([#339](https://github.com/lingyan000/fluxdo/pull/339)) by @homo11451419

- 话题内跳转帖子触底回弹:落点改 jumpTo,不留 animateTo 动画窗口 by @Lingyan000

- Windows 网络与 WebView 稳定性 (#338) ([#338](https://github.com/lingyan000/fluxdo/pull/338)) by @homo11451419

- 「我的」页下拉刷新同屏双 loading by @Lingyan000

- 分类/标签话题列表从详情返回后滚动位置跳回第一页底部 by @Lingyan000

- M3E 下拉刷新圆片阴影被 SizeTransition 裁剪截断 by @Lingyan000


### ⚡ 性能

- ️ 话题卡排版空闲预热:滚入帧零排版 + 头像/emoji 预解码 + 字形预烤 by @Lingyan000

- 首次进入外观设置页掉帧 by @Lingyan000


### ♻️ 重构

- 书签同步重构:全局同步控制器+首次流式同步+增删写穿闭环 by @Lingyan000

- 渲染校准层下沉窗口级合成:修桌面 WebView 交互与全屏混合开销 by @Lingyan000


### 📝 文档

- V0.2.26 版本亮点 by @Lingyan000


### 🔧 其他

- 💄 长按菜单重做:位置跟随就地展开+消息卡充实+双卡菜单+频道页拆分归目录 by @Lingyan000

- 💄 聊天移动端体验打磨:长按菜单收进屏内+输入条悬浮内容透穿+键盘/表情面板交互修正 by @Lingyan000

- 💄 附件入口移到输入框右侧([表情][输入框][附件][发送]),图标换回形针 + 注释中性化 by @Lingyan000

- 💄 移动端聊天打磨:长按按压反馈/弹出动画蓄势/底部沉浸/输入条图标语义 by @Lingyan000

- 🔒️ User API Key 用完即焚:登录收口即撤销 + 展示端轮询感知扫码成功 by @Lingyan000

- ⬆️ 更新 flutter 到 3.44.8 by @Lingyan000

- ⬆️ fluxdo_render:裸链接改文字同步改写 href by @Lingyan000

- ⬆️ fluxdo_render:IME 纯上屏路径补规则命中后的 reconcile by @Lingyan000

- ⬆️ fluxdo_render:移动端 IME 整窗清空落地,输入法「清空」键生效 by @Lingyan000

- ⬆️ fluxdo_render:Win+V 修法换抖动阈值判据 by @Lingyan000

- 🔧 忽略内嵌 webview 插件 example 的 ephemeral 生成物与 Windows lock,并停止跟踪机器相关 symlink by @Lingyan000

- ⬆️ macOS Podfile.lock:补播放器重做新增原生 pod(media_kit_video/screen_brightness/volume_controller) by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.2.25...v0.2.26

## [0.2.25] - 2026-07-24


### 🌟 新功能

- M3eNavigationBar 暂时关闭 by @Lingyan000

- 稍后阅读浮层重做:整屏模糊遮罩+横向卡片列表 by @Lingyan000

- 自研 M3E 组件库 m3e_ui:动效/组件全家桶 + 全局开关 by @Lingyan000

- 图片查看器:双击/缩放弹簧动画 + 打开转场升级 by @Lingyan000

- 私信列表支持新建私信(可搜索收件人) (#345) ([#345](https://github.com/lingyan000/fluxdo/pull/345)) by @homo11451419

- : 进度悬浮条支持「返回」动作 ([#323](https://github.com/lingyan000/fluxdo/pull/323)) by @dashu33

- 表情面板退格键全覆盖:主编辑器接入 + 公共删除工具 + 移动端限定 by @Lingyan000

- Boost 表情面板:底部安全区 + 悬浮退格键 by @Lingyan000

- 数据管理页重做:缓存分类多选清理 + 备份反白名单 v2 by @Lingyan000

- 接入金标联盟公平运行内存机制:TRIM 广播转标准 memoryPressure by @Lingyan000


### 🐛 修复

- 适配 preloaded 数据新版承载形态:script/json 标签 + 旧属性形态兼容 by @Lingyan000

- 待审回复撤回重编不再丢回复目标:送审时会话级补记 + 冷场景降级提示 by @Lingyan000

- 修复 Windows MSVC UTF-8 源码编码构建失败 by @Lingyan000

- Win+V 粘贴图片无反应:补原生剪贴板兜底 (#346) ([#346](https://github.com/lingyan000/fluxdo/pull/346)) by @homo11451419

- 修 dec 归因盲区:raster 大帧独立附解码名单 by @Lingyan000

- 修复富 composer 表情面板打开后返回键失效 by @Lingyan000

- 下载并发分通道:贴纸独立 3 槽,治贴纸风暴饿死正文图 by @Lingyan000

- 查看器 AVIF fallback 补 original bucket by @Lingyan000

- 数据管理:图片缓存统计/清理纳入迁移 .trash 待删目录 by @Lingyan000

- Boost 弹幕全链路收口:provider 单一数据源 + 长帖弹幕层 by @Lingyan000

- 大代码块进视口滚动卡顿:高亮熔断对齐网页端 + span 扁平化合并 by @Lingyan000


### ⚡ 性能

- ️ 下载视野优先级:首帧 paint 提级 + 滚出沉底 + 查看器插队 by @Lingyan000

- ️ AVIF 零拷贝帧桥:直连 FFI 免 protobuf 三拷贝 + 帧级降采样 + 滚动首帧放行 by @Lingyan000

- ️ 面板加载提速:emoji 独立 12 槽通道 + 贴纸预取全流水线 + 解码 3 worker by @Lingyan000

- ️ 图片缓存全量 blob 收编 + 正文图契约取用(srcset/主色/原图直链) by @Lingyan000

- ️ 小图缓存重构:blob 直寻址 + emojis.json SWR 快照 + 迁移防卡顿 by @Lingyan000

- ️ 图片管线三笔修复 + 解码归因探针 by @Lingyan000

- ️ 子包指针:emoji 占位岛(emoji 段落进直绘,见 fluxdo_render ccf857b) by @Lingyan000

- ️ 滚动停止后段落预热:首见段落也变缓存命中 by @Lingyan000

- ️ 接入正文段落直绘布局缓存:tlay:miss span 上报 + 子包指针 by @Lingyan000

- ️ 性能三件套:解码闸门离屏摘除 + 帧调度归因 + 图片引用作用域 by @Lingyan000


### ♻️ 重构

- 图片查看器重构:手势状态外提+持久层栈+关闭转场统一 by @Lingyan000


### 📝 文档

- 起草 v0.2.25 版本亮点 by @Lingyan000


### 🔧 其他

- 🌟 桌面端表情面板改为悬浮弹层 by @Lingyan000

- 🌟 图片直链改为内置查看器打开,不再走"离站确认"弹窗 (#347) ([#347](https://github.com/lingyan000/fluxdo/pull/347)) by @homo11451419

- 💄 数据管理页打磨:统计色板/占比标注/彩条分段圆角/按钮通栏 by @Lingyan000

- 🔧 macOS 自签证书签名:消除钥匙串反复弹窗 + CI 接入 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.2.24...v0.2.25

## [0.2.24] - 2026-07-17


### 🌟 新功能

- 话题卡片自定义样式:字段精简/头像布局/动态头像 + 设置页实时预览 by @Lingyan000

- 增加 CF 会话级临时兼容恢复 by @Lingyan000

- 桌面端撰写快捷键完善(对齐 Discourse composer) by @Lingyan000

- 待审核内容支持:主题页待审块 + 待审列表页 + 撤回/重编辑 by @Lingyan000

- ComposerSwitchFade:双模切换淡入壳(无并存直切+新编辑器淡入) by @Lingyan000

- Onebox 工具条:选中卡片浮出[复制|移除预览|访问](官方 onebox-toolbar 对齐) by @Lingyan000

- 行内 onebox 链接可编辑(子包)+ 加载预览接 onebox 种子链 by @Lingyan000

- 链接体验对齐官方 composer:光标进链浮工具条 + 编辑对话框升级 by @Lingyan000


### 🐛 修复

- 自绘卡动图头像:双 URL 分层(静帧秒出 + overlay 原位播放) by @Lingyan000

- 修复 CF 会话内持续 403(重启也无解):回收无效恢复机器 + cf_clearance 单向流 by @Lingyan000

- 修复静默 CF 验证循环与会话网络恢复 by @Lingyan000

- 恢复 WebView 分区 cookie(CHIPS):移除进程级禁用 by @Lingyan000

- 修复首页侧栏无法通过返回键关闭 by @Lingyan000

- 修复 boost 删除误报失败且无法重新 boost by @Lingyan000

- 补提 onebox 标记的 bundle 改动(seedOnebox 注入 data-fluxdo-onebox-url) by @Lingyan000

- 双模切换与 macOS 快捷键系列修复(合并笔) by @Lingyan000

- 链接工具条水平锚定链接(此前居中屏幕);tooltip 加等待窗防叠字 by @Lingyan000

- 切换后旧文字无法删除第三刀:flush 原子赋值(选区不再 -1 首帧发平台) by @Lingyan000

- 富→源切换 IME 交接补完:unfocus 放开连接后延迟交棒回聚焦 by @Lingyan000

- 动画 SVG 画面空白时隐藏播放角标:快照 alpha 抽样判定 by @Lingyan000

- 撤销签名 COEP 准入闸门:归因依据是 CF 盾页响应头,真实页面无 COEP by @Lingyan000

- 手写签名 SVG 空白修复:CSS d:path() 帧值解包 + 首帧采样改周期中点 by @Lingyan000

- 自绘卡已读态不即时更新:排版缓存内容变即换实例 by @Lingyan000

- 富→源切换后无法输入/删除修复 + collapsed 长按粘贴(子包) by @Lingyan000

- 用户签名默认关闭:对齐网页 opt-in 语义 by @Lingyan000


### ⚡ 性能

- ️ 关闭触摸重采样(-38ms 延迟主导项) + 监控精细化五件套 by @Lingyan000

- ️ 优化详情页掉帧并统一敏感存储 by @Lingyan000

- ️ 相对时间全局单心跳:每实例 Timer 归零 + 自绘卡时间自刷 by @Lingyan000

- ️ 详情页解析预热滚动让路:原子长任务不再挤占滚动帧 by @Lingyan000


### 📝 文档

- 起草 v0.2.24 版本亮点 by @Lingyan000


### 🔧 其他

- 🔇 cf_clearance 双变体日志降噪:良性形态五道核验后降级 by @Lingyan000

- ⬆️ doh_proxy: CF 验证域名走隧道直连 by @Lingyan000

- ⬆️ fluxdo_render:代码块横向溢出内容可拖选(内部滚动器边缘自动滚) by @Lingyan000

- ⬆️ fluxdo_render:选区对齐 SDK(全选/ProcessText/原生放大镜/失焦清选区) by @Lingyan000

- ⬆️ fluxdo_render:岛加段把手 + onIslandSelected by @Lingyan000

- 💄 富文本 hint 占位随编辑区边距同步到 20(光标压字错位) by @Lingyan000

- 💄 编辑区水平边距统一 20:富文本(12)/源码(16)对齐 header 标题(20) by @Lingyan000

- ⬆️ fluxdo_render:onebox 展开物不固化 [quote](毁帖修复)+ magnifier 新签名适配 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.2.23...v0.2.24

## [0.2.23] - 2026-07-14


### 🌟 新功能

- 发布日志双层化:stable 用人工亮点正文 + 折叠 commit 明细,附 v0.2.23 亮点 by @Lingyan000

- 源码模式升级悬浮虚拟指针:幽灵光标二维漂移+命中吸附(与富文本同交互) by @Lingyan000

- 滑钮可发现性:首次按下浮内联提示(前几次,持久计数永久收声) by @Lingyan000

- Callout 插入/壳全属性编辑 + 斜杠菜单补全 by @Lingyan000

- 手势光标升级虚拟指针:富文本按住滑钮二维漂移驱动光标 by @Lingyan000

- 手势光标:工具栏滑钮驱动光标移动/扩选(移动端) by @Lingyan000

- 富 composer 插入菜单接「我的模板」:与 MD 模式同一选择器,内容经 cook 富内容化 by @Lingyan000

- Composer 插入入口补全:MD 模式插入块菜单 + 富文本插入菜单链接项 by @Lingyan000

- Composer 媒体全家桶:富粘贴 + 音视频上传 + 语音消息 + 超 4MB 压缩 by @Lingyan000

- Segments 重算计时归因:定位分页落地帧的 33ms 无构建记录嫌疑 by @Lingyan000

- 图片首绘归因:raster 大帧清单区分 img+(新首绘)/img≈(缓存重挂) by @Lingyan000

- 帖内构成归因:header/footer 细粒度埋点,点名单帖固定成本大头 by @Lingyan000

- 签名体系对齐网页+动画 SVG 管线:user_signature 语义/服务端开关门禁/full_svg_flutter 首帧快照点击播放 by @Lingyan000

- 首页收放体系四改:耦合收尾+起手迟滞+消隐纱+chip飞标题一镜到底 by @Lingyan000

- 渐变顶栏模糊质感定稿:IGN 盘旋转 + 轻 blur 收口,雾面干净 by @Lingyan000

- 折叠态标题前缀报当前分类(信息迁移) + 工具栏弹性化防窄栏溢出 by @Lingyan000

- 首页统一弹簧运动系统 + 侧栏分类⇄标签双页签(服务端标签组/搜索/组导航) by @Lingyan000

- Composer 顶栏渐变模糊:单 pass 变力 shader,消散连续、内容透出 by @Lingyan000

- 首页整块右滑跟手拖出侧栏(手势语义纠偏+受控抽屉) by @Lingyan000

- 创建页 AppBar 按钮区重排:功能直出不折叠 + 草稿指示瞬态化 by @Lingyan000

- Composer 顶栏渐变模糊:模糊+遮罩自上而下消散到透明 by @Lingyan000

- Composer UI 重设计:透出式顶栏 + 底部元数据属性条 by @Lingyan000

- 手机端 composer 重构:分类上收 AppBar + 标题/标签入滚动流 by @Lingyan000

- 侧栏全局手势 + 收放语义分治 + 搜索胶囊/空白三症终修 by @Lingyan000

- 分类侧栏跟手滑动 + 搜索胶囊大字体档撑破修复 by @Lingyan000

- RichComposer 手机端三缺口:安全区 + 编辑区点击铺满 + 键盘⇄表情等高切换 by @Lingyan000

- 首页头部/分类导航整体重构:overlay 收缩 + 胶囊一镜到底 + 分类侧栏 by @Lingyan000

- 编辑话题页接入富文本模式(三宿主页齐了) by @Lingyan000

- 源码⇄富文本双向切换 + 工具栏气质优化 by @Lingyan000

- 编辑器移动端 M2(S6/S7):浮层键盘安全区 + 触控目标 + 键盘占位 by @Lingyan000

- 网格内图工具条(宿主侧)+ 查看器打开时浮层隐藏 by @Lingyan000

- 图片交互 1:1 复刻官方 composer(宿主侧):浮层工具条 + alt 输入条 + 查看器 by @Lingyan000

- 掉帧诊断增强:platform views 计数、CPU「其它」线程名明细、STALL 现场抓取、回跳近帧构建归因 by @Lingyan000

- Rich composer 接线代码块岛内编辑:onCodeBlockEdited → updateIslandNode 直换 by @Lingyan000

- 编辑预览图片缩放控件(100/75/50):源码预览 + 富文本岛,官方正则改 raw by @Lingyan000

- WebM/Opus 语音重封装 CAF:苹果系可播浏览器录音贴 by @Lingyan000

- 性能监控升级:全局悬浮面板 + JANK 排队拆分 + 线程 CPU 自动采样 by @Lingyan000

- Mermaid 图表块重做:legacy UI 回归 + kroki 双源出图 + 矢量查看页 by @Lingyan000

- 斜杠菜单:段首 / 唤起块插入(类 Notion 输入体验之二) by @Lingyan000

- 浏览器授权登录:User API Key 授权 + OTP 换 _t by @Lingyan000

- 日期时间可编辑:属性对话框(官方 local-dates-create modal 精简版) by @Lingyan000

- 富文本 composer:表格原位编辑/壳标题编辑接线,删对话框式表格编辑器 by @Lingyan000

- 表格结构化编辑 + 行内剧透入口 + 红屏修复 by @Lingyan000

- 富文本 composer:岛双击源码编辑 + 源码模式切换按钮 by @Lingyan000

- 富文本 composer(实验性):M3 宿主接入 + 编辑帖子 + 插入面板 by @Lingyan000

- 帧内构建归因:JANK 大帧 detail 列出本帧在建什么(release 可用) by @Lingyan000

- 搜索卡片对齐话题卡片新版布局 + 搜索列表骨架屏 by @Lingyan000


### 🐛 修复

- 源码模式滑钮光标不可见根因修复:readOnly 态 TextField 不渲染光标 by @Lingyan000

- 滑钮手势按下即独占:左滑预览等外层同向手势抢不走 by @Lingyan000

- 手势光标三修:去 Tooltip 长按冲突 + 滑钮 44x36 足尺 + MD 步进滚动跟随 by @Lingyan000

- 卡片按压灰底残留修复 + 书签列表滚动三刀 by @Lingyan000

- 随包 ffmpeg 降级为可选组件:离线打包环境(Flatpak 沙箱禁网)不挡构建 by @Lingyan000

- 解码闸门:排队期间 codec 被 dispose 的竞态防护 + 队列级取消 by @Lingyan000

- 视频全屏 dispose 崩溃修复:只读缓存+GlobalKey收养+keepAlive钉住 by @Lingyan000

- Linux 补 quickjs_engine 头缺失的 FLUTTER_PLUGIN_EXPORT 宏定义:Flatpak 编译 unknown type name by @Lingyan000

- Windows 桥接 quickjs_engine 插件注册符号错位:pluginClass 生成名→实际导出的 CApi 名 by @Lingyan000

- 渐变顶栏收口 blur 补 TileMode.clamp:去掉暗色下顶边一条未模糊线 by @Lingyan000

- 渐变顶栏两修:初始态不遮标题 + 属性条字数贴最右 by @Lingyan000

- 表情面板切键盘不弹:关闭分支同样显式 TextInput.show by @Lingyan000

- 修复 CF 验证子资源错误误报 by @Lingyan000

- 手机端三修:点击区真铺满 + 面板切回弹键盘 + 斜杠菜单状态栏安全距离 by @Lingyan000

- Common_ui:级联子菜单高度过估致面板飘离锚点 by @Lingyan000

- 修 Android Chrome 授权登录浏览器一闪跳回:改用 Custom Tabs by @Lingyan000

- Alt 输入体验对齐官方:展开变高(3 行)+ 展开即聚焦全选 by @Lingyan000

- 图片浮层红屏:_FloatingPanel 补 Material 祖先 by @Lingyan000

- 富文本表情包插不进:sticker markdown 带 ,30% 后缀,手写正则不匹配静默丢 by @Lingyan000

- Grid 瓦片不出缩放胶囊:FittedBox 无约束上下文浮层会缩放变形 by @Lingyan000

- 短链解析负缓存:lookup-urls 确认不存在的 upload 短链会话内不再重试 by @Lingyan000

- 帖内视频/音频播放修复:short-url 路径解析 + 改名上传媒体兼容 by @Lingyan000

- 斜杠菜单初始位置滞后一帧:光标矩形变化时重建活跃浮层 by @Lingyan000

- 插入菜单锚定「+」按钮 + 密度收敛 by @Lingyan000

- 斜杠菜单三修:光标锚定 + 上下键/回车导航 + hint 叠列表圆点 by @Lingyan000

- 真机红屏主犯:对话框 controller pop 后立即 dispose by @Lingyan000

- 插入块无反应:cook 挂起无降级 + 插入链路诊断日志 by @Lingyan000

- Bootstrap 治理:404 永动机(退避+换弹药)+ 成功态改「进程×登录会话」级 by @Lingyan000

- 图片滑动关闭停帧:滑动中冻结 loading→completed 树切换 + 载体重绑 by @Lingyan000

- 图片治理:占位挂 frameBuilder(AVIF/动图无占位根因)+ 比例记忆治回跳残余 by @Lingyan000

- 视频帖治理:滚动不连续(比例记忆+滚动冻结展开)+ 初始化失败降级卡 by @Lingyan000

- 滚动锚定哨兵改武装式:arm 在 state 落地帧才修正,修"回复给"展开/收起位置漂移 by @Lingyan000


### ⚡ 性能

- ️ 视频压缩上 HEVC:同码率画质 +30~50%,失败自动回退 H264 by @Lingyan000

- ️ 视频压缩提质三刀:预算折扣 0.74→0.92 + 分辨率按码率动态(短视频 720p)+ 桌面 x264 veryfast by @Lingyan000

- ️ 话题卡全线自绘:单渲染对象 + 排版全局缓存,挂载帧纯绘制 by @Lingyan000

- ️ 头像解码尺寸约束:治多头像同帧上屏的 raster 尖峰 by @Lingyan000

- ️ 书签卡分类表列表层直传:去掉每卡 categoryMapProvider 订阅 by @Lingyan000

- ️ message bus 滚动期延迟投递:治"帧开工晚"型掉帧 by @Lingyan000

- ️ 去掉 /latest 消息的双重处理 by @Lingyan000

- ️ 卡片减负第二批:catTags 去 Opacity 层 + 色带图标字形化 + 字形 span 公共化 by @Lingyan000

- ️ 卡片挂载帧减负:统计项单段落化 + 已读退灰去 Opacity 层 by @Lingyan000

- ️ 书签长列表结构病对症:三趟 O(N) 记忆化 + 卡片签名缓存 by @Lingyan000

- ️ 标题状态图标字形化:清掉标题段落上最后 6 个 WidgetSpan 占位 by @Lingyan000

- ️ 详情页重建减负四刀 + 头像主题失效修复 by @Lingyan000

- ️ 优化首页话题列表滚动性能 by @Lingyan000

- ️ CJK 字形图集预热:把 Impeller 图集扩容/搬家赶出滚动帧 by @Lingyan000

- ️ 动画 SVG 播放/首帧四连修:首帧剪层 + 低频时钟 + 自持播放器 + 签名 COEP 准入 by @Lingyan000

- ️ 接入 native_animated_image 0.3.4:webp/GIF 首帧上传纳入全局解码闸门 by @Lingyan000

- ️ 全局图片解码并发闸门:限解码即限 Impeller 纹理上传,治图密话题 raster 尖峰 by @Lingyan000

- ️ 首页快滚专项:头像 SVG 探测记忆 + 列表卡去 keepalive 包装 + 偏好 select 化 by @Lingyan000

- ️ 话题卡片 Card 壳换轻装:砍每卡一套 AnimatedPhysicalModel 隐式动画基建 by @Lingyan000

- ️ 图片操作卡顿两刀:缩放切档零重解码 + 瓦片解码 cap 屏宽 by @Lingyan000

- 话题页整页 rebuild 解耦:detail watch 下沉到 AppBar/body/AI 页 Consumer 边界,落地帧页面骨架短路 by @Lingyan000

- 高负载滚动掉帧专项:图片首绘分帧、动图滚动冻结、翻页渐进物化+解析预热、msgbus 大包隔离、cf WebView 滚动挂起 by @Lingyan000

- ️ emoji 动图 RepaintBoundary 改无条件:堵住动 WebP/AVIF 漏网导致的整帖每帧重绘 by @Lingyan000

- ️ 列表滚动优化(闲鱼方案落地):比例监听收口 + 跳转进入渐进物化 by @Lingyan000

- ️ 弹幕 Ticker 生命周期:可见才跑、放完即停,消每帧 setState 空转 by @Lingyan000

- ️ 进入掉帧治理:转场期先骨架 + 首屏渐进物化,物化成本挪出动画窗口 by @Lingyan000

- ️ 内容滚动首建治理:随分块阈值下调扩容长帖解析缓存(64→128) by @Lingyan000

- ️ 转场治理:FadeForwards saveLayer 换 Cupertino,Android 预测返回拷贝改造保留 by @Lingyan000


### ♻️ 重构

- 撤宿主 grid 浮层(动作已内聚进子包 EditorImageGrid),只留查看器接线 by @Lingyan000


### 📦 依赖更新

- Flatpak:静态 ffmpeg 经 file source 装入 /app/bin(媒体压缩 CLI) by @Lingyan000


### 🔧 其他

- ⬆️ fluxdo_render:div/center 容器拆壳修复(对齐 div 包图丢图只剩 meta 文字)+ 测试基建 Windows 兼容 by @Lingyan000

- 🔥 源码模式手势光标下线:TextField 命中吸附不可靠(悬浮到位不落真光标),只保留富文本侧 by @Lingyan000

- ⬆️ fluxdo_render:虚拟指针无光标用例语义更新 by @Lingyan000

- 💄 手势光标单控件化 + 随时可用 by @Lingyan000

- 💄 手势光标恢复移动端限定(桌面验收完毕,物理键盘无需滑钮) by @Lingyan000

- 🔥 字形图集预热退场:未经 A/B 终审的机制不留在生产里 by @Lingyan000

- 💄 手势光标图标修正:滑钮=I 光标、选择开关=text_select 图标,说明文案同步 by @Lingyan000

- ⬆️ fluxdo_render:mention 去 WidgetSpan(纯 TextSpan + painter 药丸) by @Lingyan000

- ⬆️ fluxdo_render:移动端选区二期(collapsed 光标拖柄 + 手柄边缘自动滚) by @Lingyan000

- ⬆️ fluxdo_render:行内代码灰底 painter 条件挂载(无行内代码的文本块省一个 CustomPaint) by @Lingyan000

- ⬆️ fluxdo_render:图片体系 1:1 复刻官方 + 编辑器移动端一期 + emoji 修复 by @Lingyan000

- 💄 浮层规格拉平:插入菜单/标题弹层接统一容器样式 by @Lingyan000

- 💄 斜杠/mention 浮层 Notion 化 by @Lingyan000

- ⬆️ fluxdo_render:表格块选择柄被裁(根 Stack Clip.none) by @Lingyan000

- ⬆️ fluxdo_render:表格圆角回归 + hover 柄淡显体系 by @Lingyan000

- ⬆️ fluxdo_render:表格行列操作 Notion 化 + cell 编辑态强化 by @Lingyan000

- ⬆️ fluxdo_render:表格块级选择柄(整选/删除入口) by @Lingyan000

- ⬆️ fluxdo_render:修表格 cell 双光标(自管区让路 + hasPrimaryFocus) by @Lingyan000

- 💄 修双 spinner 叠影:富 composer 挂载门禁占位改留空 by @Lingyan000

- ⬆️ fluxdo_render:修表格 cell 编辑按键被编辑器拦截 by @Lingyan000

- ⬆️ fluxdo_render:修粘贴丢容器壳 + 壳重排红屏(M5-B 回归) by @Lingyan000

- ⬆️ fluxdo_render:M5 容器块可进入编辑 + 行内 spoiler/link mark by @Lingyan000

- 💄 富文本 composer UI 止血:单一底部工具栏,与纯文本编辑器同构 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.2.22...v0.2.23

## [0.2.22] - 2026-07-07


### 🌟 新功能

- 话题列表 keyed reconcile + 锚定哨兵,修顶部动态插入的错位/跳变 by @Lingyan000

- 滚动锚定哨兵:空闲期上方帖子高度变化同帧修正,对齐浏览器 scroll anchoring by @Lingyan000

- 诊断导出带应用版本指纹,防旧包日志误判新修复无效 by @Lingyan000

- 预览补齐 unicode emoji 转换 + onebox 异步展开 by @Lingyan000

- 编辑器预览 1:1 cook:app 内跑 Discourse 官方 markdown-it 管线 by @Lingyan000

- 性能监控补 WebView/线程阻塞归因:WEBVIEW 事件流 + STALL 双探针 by @Lingyan000

- 话题卡片改为标题置顶布局:头像跨两行,分类固定行首 by @Lingyan000

- 话题卡片改版:Gmail 式三行布局 by @Lingyan000

- 长按头像径向菜单 + 复制用户名 by @Lingyan000

- 添加本地实现的用户黑名单功能 (#307) ([#307](https://github.com/lingyan000/fluxdo/pull/307)) by @Ooxygen7

- 优化 Boost 点击预览交互 (#299) ([#299](https://github.com/lingyan000/fluxdo/pull/299)) by @miniworldcnmm

- 用户个人页新增 Boost/投票/已解决列表 + 修 tab 回弹抖动 by @Lingyan000

- 更新渲染引擎:spoiler 动画连续不重播 + pipeline 预热消首帧卡顿 by @Lingyan000

- 分享成图接入 screenshotMode:表格全渲染 + mermaid 立即出图 by @Lingyan000


### 🐛 修复

- Fingerprint 端点正则不再写死压缩函数名 by @Lingyan000

- 滚动中冻结 msgbus 帖子更新,修"滚动时被拉一下"的布局跳变 by @Lingyan000

- AVIF 帖内图全尺寸纹理上传漏洞 + raster 大帧 ImageCache 归因快照 by @Lingyan000

- 修图片解码上限对 webp 完全失效:改 decode-time ResizeImage + 高度双向 cap by @Lingyan000

- 修 CF 盾频发:CHIPS 双 cf_clearance 变体 + 边界同步选优振荡 by @Lingyan000

- 贴底改用 viewport anchor:底部空白排除在滚动范围外 + 修回顶停半路 by @Lingyan000

- Fingerprint 端点正则不再写死压缩函数名 by @Lingyan000

- 修复桌面端用户卡片更多菜单不显示:菜单推到兄弟 Navigator 时 InheritedTheme.capture 祖先断言失败 by @Lingyan000

- 修复话题详情页进度条初始定位时数字爬升 by @Lingyan000

- 修复 Hive box 损坏崩溃,图片缓存索引改用 sqlite 后端 by @Lingyan000


### ⚡ 性能

- ️ msgbus 积压攒批+坍缩,修长时间挂后台回前台的几秒卡顿 by @Lingyan000

- ️ 启用 HCPP:修 iframe 在屏时整页滚动降级卡顿 by @Lingyan000

- ️ iframe 帖子滚动卡顿:WebView 平台视图 KeepAlive 保活,修 chunk 虚拟化反复销毁重建 by @Lingyan000

- ️ Android cookie IPC 全面撤离平台主线程:raw_cookie 通道下沉 HandlerThread by @Lingyan000

- ️ CfRefresh 平台线程减负:stale 重建改原地重载 + 轮询降频 + health 免同步 by @Lingyan000

- ️ 滚动/更新掉帧治理 + 性能诊断设施 by @Lingyan000

- ️ 补回全局解析缓存层 + 滚动停止后空闲预热 chunk by @Lingyan000

- ️ 修图片引发的滚动卡顿:内容图/轮播/emoji/视频封面按显示尺寸解码 + RepaintBoundary 隔离动画重绘 + 挂载即预取 by @Lingyan000

- ️ 帖子初始定位改 center 锚点构造性定位:首帧即目标顶对齐 by @Lingyan000

- ️ 更新渲染引擎:表格列宽测量缓存 + 行内代码灰底矩形缓存 by @Lingyan000

- ️ 分页 spinner 改 ValueNotifier 驱动:loadMore/loadPrevious 起止不再发射 AsyncLoading 整页 rebuild by @Lingyan000

- ️ 拆除帖子列表外层系统 SelectionArea:正文选区统一走自研,未登录降级仅复制 by @Lingyan000

- ️ 更新渲染引擎:spoiler shader 降耗,修大区域/滚动掉帧 by @Lingyan000

- ️ 更新渲染引擎:InlineSpanText flatten 缓存 + 块级 widget 树记忆化,rebuild 不再全量重排版 by @Lingyan000

- ️ 长帖 chunk 懒解析:进入 cacheExtent 才 parse,画廊推迟到首次点图构建 by @Lingyan000

- ️ _buildRenderSegments 按 posts/gaps 身份记忆化,高频 rebuild 不再重付 O(N) 建表成本 by @Lingyan000

- ️ 已读上报不再触发整页 rebuild:session watch 改 listen,updateSeen 推迟到 idle by @Lingyan000

- ️ typingUsers 监听下沉到打字指示器,presence 消息不再整列表重建 by @Lingyan000

- ️ 更新渲染引擎:spoiler 遮罩改 GPU shader 粒子,修多实例同屏卡顿 by @Lingyan000

- ️ 修复图片缓存索引迁移后初次加载慢,v7 清空旧缓存目录 by @Lingyan000

- ️ 优化启动预加载解析 by @Lingyan000


### 🔧 其他

- Revert "⚡️ iframe 帖子滚动卡顿:WebView 平台视图 KeepAlive 保活,修 chunk 虚拟化反复销毁重建" by @Lingyan000

- 💄 LoadingSpinner 撑满可见尺寸:去掉 38/48 容器留白,按动画全程最大回转半径精确防溢出 by @Lingyan000

- 💄 分段卡片下沉 common_ui,补齐 ai_model_manager 覆盖 by @Lingyan000

- 💄 LoadingSpinner 1:1 复刻 M3E LoadingIndicator:7 形状循环 morph + 650ms 弹簧节奏 + 4666ms 全局旋转 by @Lingyan000

- 💄 外观页 UI 优化:主题色卡大屏定宽、应用图标改 keyline 设计稿风格卡片 by @Lingyan000

- ⬆️ 更新渲染引擎:修复两手柄重合时拖拽死亡、放大镜残留 by @Lingyan000

- 💄 设置/个人页全面切换 M3 Expressive 分段卡片风格 by @Lingyan000

- 💚 修复 Flatpak 离线构建:sqlite3 hook 改用 vendored amalgamation 源码编译 by @Lingyan000

- 🔧 移除 .gitmodules 中的 fetchRecurseSubmodules 配置 by @Lingyan000

- ⬆️ 更新渲染引擎:修复行内代码灰底溢出到相邻文字 by @Lingyan000

- ⬆️ 更新渲染引擎:修复移动端选区滚动误清、手柄反选、放大镜焦点 by @Lingyan000

- 🔧 修复子模块依赖配置 by @Lingyan000

- ⬆️ fluxdo_render → 90e8f48:长串软换行(修行内代码/长串溢出) by @Lingyan000

- ⬆️ fluxdo_render → cce35c9:移动端选区震动/拖柄toolbar/向回选修复 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.2.21...v0.2.22

## [0.2.21] - 2026-06-23


### 🌟 新功能

- 接入 fluxdo_render 自研渲染引擎,完整下线 fwfh by @Lingyan000

- 支持信任要求空状态进度展示 by @Lingyan000

- 全局图标统一为 Material Symbols Rounded + 支持自绘 by @Lingyan000

- 加载更多统一使用自定义 LoadingSpinner by @Lingyan000

- 支持查看 DNS 缓存记录 by @Lingyan000

- 支持 Premium 回复最小长度 by @Lingyan000

- 统一底部弹框为 AppSheetScaffold(贴边/卡片双形态) by @Lingyan000


### 🐛 修复

- 修复渲染 benchmark 引用已删 legacy + 清理 iframe dead code by @Lingyan000

- 修复元宇宙余额卡片 loading 态与数据态高度不一致 by @Lingyan000

- 修复 Windows 最小化后窗口无法还原 (#302) by @Lingyan000

- 修复网络适配器与 Cookie 同步稳定性 by @Lingyan000

- 修复用户卡片更多菜单层级 by @Lingyan000

- 修复 CF 静默验证页布局异常 by @Lingyan000


### ⚡ 性能

- 合并 HTML 解析路径,长帖渲染走 isolate 预热 by @Lingyan000

- 隔离自驱动重绘 + 头像 SVG 探测短路 by @Lingyan000

- 优化后台 WebView 资源占用 by @Lingyan000


### ✅ 测试

- 修复测试超时和断言失败 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.2.20...v0.2.21

## [0.2.20] - 2026-06-19


### 🌟 新功能

- 改进移动端表情长按面板体验 by @Lingyan000

- 弹出菜单顶部快捷按钮条 + 子面板展开动画 by @Lingyan000

- 帖子编辑历史 + 修复 callout 跨标签贪婪正则 by @Lingyan000

- 优化 CF 信任刷新与 Cookie 同步 by @Lingyan000

- 表情选择器改造为手势驱动的连贯交互 by @Lingyan000

- 长按进度条菜单加入衍生 / 收回动画 by @Lingyan000

- 支持轻量 WebView 会话 cookie bootstrap by @Lingyan000


### 🐛 修复

- 识别 CHIPS 分区 cf_clearance，终结 sweep 空转 by @Lingyan000

- 修复页面刷新后通知徽章回退到初值 by @Lingyan000

- 修复通知图标 build 阶段 setState 报错 by @Lingyan000

- 修复 mac 进度指示器卡死 + 表情选择器 tap 误触发动画 by @Lingyan000

- 修复启动页动画卡顿 by @Lingyan000

- 修复话题详情 listener 触发 inactive ancestor lookup by @Lingyan000

- 修复 Cloudflare 验证完成后的 404 闪烁 by @Lingyan000

- 修复登录态 probe 的 _t 回退逻辑 by @Lingyan000


### ⚡ 性能

- CDK/LDC 余额改为进入页面才请求，不在冷启动预取 by @Lingyan000


### ♻️ 重构

- WebView session bootstrap CF 失败接入 BrowserTrustCoordinator by @Lingyan000

- 网络引擎设置重做为预设单选 + VPN 开关意图/生效分离 by @Lingyan000


### 🎨 样式

- 收尾表情选择器手势细节 by @Lingyan000


### 🔧 其他

- 🔒 优化浏览器信任与 Cookie 同步 by @Lingyan000

- ⬆️ lock 更新 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.2.19...v0.2.20

## [0.2.19] - 2026-06-16


### 🐛 修复

- 修复 LDC 余额趋势符号显示 by @Lingyan000

- 修复实时 Boost 权限误判 by @Lingyan000

- Harden WebView session cookie sync by @Lingyan000

- Fix: 修复 Windows 登录验证和加载卡住 by @Lingyan000

- Fix: 兼容伪装成 PNG 的 SVG 头像 by @Lingyan000


### ♻️ 重构

- 抽象分页加载状态 by @Lingyan000


### 🔧 其他

- :bug: fix: 收敛 Discourse 登录态与上报逻辑 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.2.18...v0.2.19

## [0.2.18] - 2026-06-13


### 🌟 新功能

- 登录页调整 by @Lingyan000

- 增加本地草稿兜底缓存 by @Lingyan000

- 优化启动页 UI 并统一氛围页角落按钮 by @Lingyan000

- 点击通知跳转后不再主动关闭通知面板 by @Lingyan000

- 统一登录文案为 LINUX.DO by @Lingyan000

- 调整主题预览弹窗自适应高度 by @Lingyan000

- 支持话题摘要流式更新 by @Lingyan000

- Cdk 卡片跳转地址更改 by @Lingyan000

- 头像点击改弹用户卡片:基于话题私信/关注/静音忽略 by @Lingyan000

- 统一错误页 UI:补网络设置入口 + 收敛 9 个页面到 ErrorView by @Lingyan000

- MessageBus 对齐官方 v4 协议：消除 iOS 100ms 重连风暴 by @Lingyan000

- CF 验证期间冻结业务请求：模拟网页 CF 403 直接停滞 by @Lingyan000

- 编辑器工具栏极简化：网格工具面板 + 可自定义外显工具 by @Lingyan000

- Boost 弹幕化 + 阅读设置开关 by @Lingyan000

- 移除「连通性检查」,「测试模型」按钮挪到 AppBar by @Lingyan000

- 支持 Boost 举报功能 (#279) ([#279](https://github.com/lingyan000/fluxdo/pull/279)) by @miniworldcnmm

- 登录 dialog CSRF 403 自动重过 CF 验证 by @Lingyan000


### 🐛 修复

- 修复私信草稿 key 恢复和收件人同步 by @Lingyan000

- 用户卡片背景图露边:背景图移入 child 与渐变蒙版同层,避免 border 内缩导致边缘未被遮罩覆盖 by @Lingyan000

- Cookie 读写加固:显式删除被新鲜度仲裁拦截 + 并发写竞态 + 每响应全量写盘 by @Lingyan000

- Cf_clearance 新旧变体打架致 cdk 反复 403:jar 版本化防旧盖新 + native 精确删 by @Lingyan000

- 关键词过滤场景下话题列表死循环 loadMore 导致下拉刷新卡 loading by @Lingyan000

- Profile 页下拉刷新 LDC/CDK 卡片无 spinner 也不刷数据 by @Lingyan000

- LDC 今日收益偶发 +0:score 与 LDC 数据解耦,展示层组合 by @Lingyan000

- 多图发帖偶发永久裂图:lookup-urls 失败不再缓存 null + 批量合并加 429 重试 by @Lingyan000

- 草稿偶发 409:对齐 Discourse 前端的 sequence 三板斧 by @Lingyan000

- 复制日志炸 TransactionTooLargeException:>1MB 回退分享 by @Lingyan000

- CF 速率限制 challenge 返 429:拦截器只看 403 漏判 by @Lingyan000

- 修登录后 ProfilePage 卡 loading：refresher 改用 ProviderContainer by @Lingyan000

- 修 rhttp 写死 30s timeout 截断长请求：违反 HttpClientAdapter 契约 by @Lingyan000

- 修 macOS CF 验证死循环：补齐 WKWebView 半截 UA by @Lingyan000

- 修 AI 对话表格 1px 溢出：totalWidth 算错列间分隔线 by @Lingyan000

- 修 footer 操作栏溢出：表情叠叠乐 + 弹幕开关挪到 header by @Lingyan000

- 修 Anthropic 多个真实失败 + baseUrl 自动补 /v1 + 诊断增强 by @Lingyan000

- 修预见式返回手势进行中锁屏致 UI 卡死 by @Lingyan000


### ⚡ 性能

- DoH 提速:接入 h2 MITM 开关 + 升级 doh_proxy 子模块 by @Lingyan000

- 表情面板滚动卡顿:缓存 panel/页面实例阻断 rebuild 级联 by @Lingyan000

- AVIF 解码:缩略图单帧解码 + 并发 1→4 恢复预热 + 预览流式逐帧 by @Lingyan000

- 图片加载地基:缓存索引 JSON→Hive + 失败 evict 自动重试 + 下载全局限流 by @Lingyan000


### ♻️ 重构

- 日志系统重构:统一入口 + 缓冲落盘轮换 + 日志页重做 by @Lingyan000


### 🔧 其他

- Keep node tools for crashlytics upload by @Lingyan000

- Fix release workflow failures by @Lingyan000

- 👷 TG 发布失败不再静默：CI 报错可重跑 + 回收半截消息，并美化消息模板 by @Lingyan000

- 👷 Android 构建前清理 runner 预装组件,避免磁盘写满导致构建失败 by @Lingyan000

- 👷 macOS CI 改 M1 交叉编 x86_64 + 全 Rust job 加缓存 by @Lingyan000

- 💄 网络并发设置文案太硬核:改大白话 + 档位预设 + 一键重置 by @Lingyan000

- 👷 CI 出 Android 包时分离并上传 Dart symbols 到 Crashlytics by @Lingyan000

- ⬆️ 升若干依赖 + 项目级关 SwiftPM 修 gal macOS 11.0 报错 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.2.17...v0.2.18

## [0.2.17] - 2026-06-10


### 🌟 新功能

- Hcaptcha create endpoint 可配置 + fallback 列表 by @Lingyan000

- Hcaptcha create endpoint 可配置 + fallback 列表 by @Lingyan000


### 🐛 修复

- ApiKey 改明文存储 + 诊断走应用日志,根治「未收到 AI 回复」 by @Lingyan000

- 修 Android nukeAllVariants 因无 Looper 线程致空操作 by @Lingyan000

- 升 native_animated_image 0.3.1: 修不透明动画 WebP 解码 crash by @Lingyan000

- 修请求调度器按 dio 实例独立窗口, 导致服务端 429 by @Lingyan000

- 修请求调度器按 dio 实例独立窗口, 导致服务端 429 by @Lingyan000

- Release notes 从上个 stable 起算 + Pages 图标路径动态化 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.2.16...v0.2.17

## [0.2.16] - 2026-06-09


### 🌟 新功能

- 俺也一样: OP 帖底部 ME TOO 表态按钮 (discourse-solved shared_issue) by @Lingyan000

- Notion 同步: 帖子/话题 -> Notion Database (close [#230](https://github.com/lingyan000/fluxdo/issues/230)) by @Lingyan000

- 导出历史: 帖子导出/同步统一可追溯 (PR1/2 → #227) by @Lingyan000

- Native 应用登录页: WebView 内 JS 全流程登录 by @Lingyan000

- 多解决方案支持: 列表化 banner + 兼容 discourse-solved 新分支 by @Lingyan000

- 老 WKWebView 兼容层: core-js polyfill 子工程 + JS 错误回传 by @Lingyan000

- Cookie 引擎 v0.4.0 闭环: 全量同步 + 跨平台 observer + Win/Linux 接通 by @Lingyan000

- 进度悬浮条手势：按压时间反馈 + 长按菜单设置页 by @Lingyan000

- 进度悬浮条手势：左右上滑 + 长按半圆菜单 by @Lingyan000

- CF 盾自动验证开关 by @Lingyan000

- APK 更新支持后台下载 + 通知栏进度 by @Lingyan000

- Release 日志改造：接入 git-cliff + TG 通知重构 by @Lingyan000

- Cookie 引擎 v0.4.0 (#276) ([#276](https://github.com/lingyan000/fluxdo/pull/276)) by @Lingyan000

- : 更新桌面端 App Icon ([#272](https://github.com/lingyan000/fluxdo/pull/272)) by @Silhouette-my

- 字体粗细调整 by @Lingyan000

- CF 验证样式优化 by @Lingyan000

- Flutter 更新到 3.44.0 by @Lingyan000

- 刷新率设置支持 by @Lingyan000

- 优化 CF 盾处理与验证体验 (#266) ([#266](https://github.com/lingyan000/fluxdo/pull/266)) by @Lingyan000

- 添加话题关键词过滤功能，允许用户根据标题关键词筛选话题 (#268) ([#268](https://github.com/lingyan000/fluxdo/pull/268)) by @SuperJeason

- 跨平台我的书签工作区与统一书签编辑体验（clean） (#262) ([#262](https://github.com/lingyan000/fluxdo/pull/262)) by @liucong2013

- AI 提供商排序置顶与模型收藏排序，新增发帖 AI 审核，修复网页端草稿编辑问题 (#261) ([#261](https://github.com/lingyan000/fluxdo/pull/261)) by @miniworldcnmm

- 优化桌面布局与侧边栏导航分组 (#249) ([#249](https://github.com/lingyan000/fluxdo/pull/249)) by @liucong2013

- AI 助手功能优化 by @Lingyan000


### 🐛 修复

- 修 AI 测试模型弹框标题撞状态栏 by @Lingyan000

- 修 _t 被错存为 domain cookie 挂到子域名 by @Lingyan000

- 修 cdk/ldc OAuth callback "CSRF 验证失败" by @Lingyan000

- Cdk/ldc OAuth 链路拟人化, 缓解 429 by @Lingyan000

- 修 iOS 切换应用图标无法切回主图标 by @Lingyan000

- 修 iOS 真机 AI「未收到 AI 回复」+ 跟随网络 Claude 第二次起必挂 by @Lingyan000

- 修日志文件含非法 utf-8 字节时日志页面崩溃打不开 by @Lingyan000

- 修双栏布局下正在输入指示器居中显示 by @Lingyan000

- 修 cdk/ldc OAuth user-info 双发 + 链路无间隔触发 429 by @Lingyan000

- 修 Priming 与 cf_challenge 竞态导致 CF 第一次验证关闭 by @Lingyan000

- 修 CF 验证循环 bug + sameSite 字段全链路保留 by @Lingyan000

- 修复 release notes stable 漏合 beta + TG 双消息缺少关联 by @Lingyan000

- 修复 Priming 同步失败: 去掉 fast path + 加 verify by @Lingyan000

- 修复查看图片隐藏状态栏之后不再显示的问题 by @Lingyan000

- Flutter 升级兼容性修复 by @Lingyan000

- 修复 AI 功能跟随应用网络配置失效的问题 by @Lingyan000

- LDC 功能错误提示优化 by @Lingyan000

- Fix post-login loading handoff (#258) ([#258](https://github.com/lingyan000/fluxdo/pull/258)) by @liucong2013

- 修复 rhttp 引擎开关退出重进自动关闭问题 (#254) ([#254](https://github.com/lingyan000/fluxdo/pull/254)) by @miniworldcnmm


### 🔧 其他

- Revert ":rocket: AVIF 走 Skia 内置 codec 优先 — 跟浏览器同档 path" by @Lingyan000

- :rocket: AVIF 走 Skia 内置 codec 优先 — 跟浏览器同档 path by @Lingyan000

- :zap: Android AVIF 卡 + 关闭面板还卡 — generation cancel + AVIF 并发 1 by @Lingyan000

- :zap: sticker / AVIF 完整方案 (2/2): 后续微优化(解码并发/UI/网络) by @Lingyan000

- :sparkles: sticker / AVIF 完整方案 (1/2): native 集成 + 架构重构 + 主要修复 by @Lingyan000

- 🔥 移除 hCaptcha 无障碍 Cookie 功能 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.2.15...v0.2.16

## [0.2.15] - 2026-05-09


### 🌟 新功能

- 为「新话题」筛选新增二级子过滤下拉，对齐 Linux.do 网页版行为。 (#243) ([#243](https://github.com/lingyan000/fluxdo/pull/243)) by @miniworldcnmm

- Boost 切换到帖子回复 (#238) ([#238](https://github.com/lingyan000/fluxdo/pull/238)) by @miniworldcnmm

- 新增剪贴板话题链接识别服务 (#237) ([#237](https://github.com/lingyan000/fluxdo/pull/237)) by @miniworldcnmm

- 取消主动指纹上报 by @Lingyan000

- Cookie 同步到 webview 逻辑优化 by @Lingyan000

- 用户签名显示支持，close [#234](https://github.com/lingyan000/fluxdo/issues/234) by @Lingyan000

- 图片查看器体验优化 by @Lingyan000

- 树形视图体验优化 by @Lingyan000

- 编辑器支持插入 Callout，close [#95](https://github.com/lingyan000/fluxdo/issues/95) by @Lingyan000

- AI 模型快捷词支持导出导入 by @Lingyan000

- AI 助手模型调用 prompt 缓存支持 by @Lingyan000

- 优化 AI 助手关闭连接逻辑 by @Lingyan000

- AI 助手支持选择思考深度 by @Lingyan000

- 模型配置界面优化 by @Lingyan000

- AI 助手提示词界面优化，生图模式优化 by @Lingyan000

- AI 助手优化 by @Lingyan000

- 发布脚本优化 by @Lingyan000

- 国际化功能优化，项目工程优化 by @Lingyan000

- 快捷键功能优化 by @Lingyan000


### 🐛 修复

- 修复回复话题和 messageBus 的竞态问题，fix [#233](https://github.com/lingyan000/fluxdo/issues/233) by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.2.13...v0.2.15

## [0.2.13] - 2026-04-24


### 🌟 新功能

- 默认树形视图支持，树形视图功能优化 by @Lingyan000

- 话题详情更多菜单中支持更多的功能 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.2.12...v0.2.13

## [0.2.12] - 2026-04-22


### 🌟 新功能

- 树形视图界面优化 by @Lingyan000


### 🐛 修复

- 树形视图 404 修复 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.2.11...v0.2.12

## [0.2.11] - 2026-04-20


### 🌟 新功能

- 帖子 details 性能优化 by @Lingyan000

- 帖子 policy 内容支持 by @Lingyan000

- 贴内时间内容支持，close [#202](https://github.com/lingyan000/fluxdo/issues/202) by @Lingyan000

- 顶栏自定义布局支持 by @Lingyan000

- 添加底栏设置 by @Lingyan000


### 🐛 修复

- Android PassKey 修复 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.2.10...v0.2.11

## [0.2.10] - 2026-04-20


### 🐛 修复

- 修复 macOS 下 per-device CA 未启用导致 WKWebView 证书验证失败 (#228) ([#228](https://github.com/lingyan000/fluxdo/pull/228)) by @AmosBloomfield




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.2.9...v0.2.10

## [0.2.9] - 2026-04-18


### 🌟 新功能

- 对话框模糊性能优化 by @Lingyan000

- PassKey 支持 by @Lingyan000

- 内置浏览器网址输入弹框优化 by @Lingyan000

- 请求添加 Discourse-Present 头 by @Lingyan000

- 内置浏览器性能优化 by @Lingyan000

- 添加指纹上报 by @Lingyan000

- 优化 DOH 保活检测 by @Lingyan000

- 优化通知列表更新逻辑 by @Lingyan000

- 新增侧栏分类快捷入口与 Windows WebView 兜底逻辑 (#217) ([#217](https://github.com/lingyan000/fluxdo/pull/217)) by @liucong2013


### 🐛 修复

- 修复一些无感知异常 by @Lingyan000


### ♻️ 重构

- 代码优化 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.2.8...v0.2.9

## [0.2.8] - 2026-04-13


### 🌟 新功能

- 修复 Windows 无法分享的问题，close [#200](https://github.com/lingyan000/fluxdo/issues/200) by @Lingyan000

- 修复 windows 无法上传图片，close [#212](https://github.com/lingyan000/fluxdo/issues/212) by @Lingyan000

- 网络检查性能优化，ref #205 by @Lingyan000

- 通知、私信功能优化，并添加私信列表，close [#216](https://github.com/lingyan000/fluxdo/issues/216) by @Lingyan000

- 保守登出复检机制 by @Lingyan000

- WebView 适配器缓存问题修复 by @Lingyan000

- 日志记录优化 by @Lingyan000


### 🐛 修复

- 修复 Windows 无法关闭的问题 by @Lingyan000

- 修复某些场景无法加载更多帖子的问题 by @Lingyan000

- 修复帖子内容更新后无法发送 boost by @Lingyan000

- 修复 cookieJar 同步到 webview 的异常 by @Lingyan000


### ♻️ 重构

- 取消提交多语言的 merged by @Lingyan000

- 多语言能力模块化设计 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.2.7...v0.2.8

## [0.2.7] - 2026-04-12


### 🌟 新功能

- 自检优化 by @Lingyan000

- 优化 boost 显示 by @Lingyan000

- 解决应用内清除 Cookie 的隐患 by @Lingyan000

- 移除 Android CDP 同步 Cookie by @Lingyan000

- 一些功能优化 by @Lingyan000

- 样式优化 by @Lingyan000

- Webview 适配器支持 by @Lingyan000

- 嵌套视图实现（实验性） by @Lingyan000

- Boost 支持 by @Lingyan000

- 登录流程优化 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.2.6...v0.2.7

## [0.2.6] - 2026-03-31


### 🌟 新功能

- 请求链路优化 by @Lingyan000

- 适配器优化 by @Lingyan000

- 桌面端快捷键完善 by @Lingyan000

- CF 自动续期逻辑优化 by @Lingyan000

- Windows 图标圆角，close [#183](https://github.com/lingyan000/fluxdo/issues/183) by @Lingyan000

- 桌面端快捷键支持 by @Lingyan000

- 桌面平台鼠标操作优化，ref #186 by @Lingyan000

- 支持私信反馈日志 by @Lingyan000

- 附件上传支持 by @Lingyan000

- MessageBus 日志记录优化 by @Lingyan000

- 模糊效果优化 by @Lingyan000


### 🐛 修复

- 修复 Windows 上 WebView 不被代理的问题，fix [#199](https://github.com/lingyan000/fluxdo/issues/199) by @Lingyan000

- 修复 Cronet 适配器异常降级无法恢复的问题 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.2.5...v0.2.6

## [0.2.5] - 2026-03-30


### 🔧 其他

- 🚑️ Windows 卡验证修复 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.2.4...v0.2.5

## [0.2.4] - 2026-03-30


### 🌟 新功能

- 添加元宇宙授权遇到异常时的提示，close [#172](https://github.com/lingyan000/fluxdo/issues/172) by @Lingyan000

- 下载功能优化，close [#180](https://github.com/lingyan000/fluxdo/issues/180) by @Lingyan000

- Cookie 逻辑精简优化，⚠️ 需要重新登录 by @Lingyan000

- CA 证书相关优化，IOS 编译优化 by @Lingyan000

- 模糊效果优化 by @Lingyan000


### 🐛 修复

- 修复双栏模式下，分类/标签详情列表无法跳转的问题，fix [#191](https://github.com/lingyan000/fluxdo/issues/191) by @Lingyan000

- : APP内置网页浏览注入 iOS 15 polyfill 修复JS缺失导致白屏问题 (#190) ([#190](https://github.com/lingyan000/fluxdo/pull/190)) by @nebula5725




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.2.3...v0.2.4

## [0.2.3] - 2026-03-29


### 🐛 修复

- : 注入 iOS 15 JS polyfill 修复登录页白屏问题 (#185) ([#185](https://github.com/lingyan000/fluxdo/pull/185)) by @nebula5725


### 🔧 其他

- 🚑️ 取消 Android 默认 CDP 机制，不再支持 WebView 双向同步，解决新版本掉登录问题 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.2.2...v0.2.3

## [0.2.2] - 2026-03-28


### 🔧 其他

- 🚑️ 尝试解决掉登录的问题 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.2.1...v0.2.2

## [0.2.1] - 2026-03-27


### 🌟 新功能

- 支持对话框模糊背景 by @Lingyan000

- 长表格渲染优化，close [#170](https://github.com/lingyan000/fluxdo/issues/170) by @Lingyan000

- 功能优化 by @Lingyan000

- AI 助手可开启滑动显示模式 by @Lingyan000

- 统计卡片自定义 by @Lingyan000

- 功能优化，UI 更新 by @Lingyan000

- 新 Cookie 机制迁移 by @Lingyan000

- Windows DOH 适配 by @Lingyan000

- 修改 CookieJar 与 WebView Cookie 的同步方式 by @Lingyan000

- Cookie 相关代码逻辑优化 by @Lingyan000

- CA 证书相关优化 by @Lingyan000

- IOS DOH 功能支持 by @Lingyan000

- 优化 macOS 构建以及支持 macOS 的 WebView 代理 (#171) ([#171](https://github.com/lingyan000/fluxdo/pull/171)) by @RebornQ


### 🐛 修复

- 修复一些问题 by @Lingyan000

- 修复 IOS 编译问题 by @Lingyan000

- 修复 macOS 14 版本判断错误 ([#176](https://github.com/lingyan000/fluxdo/pull/176)) by @RebornQ

- 修复 macOS 滚轮/触控板滚动导致的吸附跳动 ([#173](https://github.com/lingyan000/fluxdo/pull/173)) by @RebornQ


### 🔧 其他

- 🚑️ 修复 Cookie 无法读取的问题 by @Lingyan000

- 🚀 CI 优化 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.56...v0.2.1

## [0.1.56] - 2026-03-23


### 🌟 新功能

- 功能优化 by @Lingyan000

- 优化下载附件文件名获取逻辑 by @Lingyan000

- AI助手未配置 API Key 时提示 by @Lingyan000

- Hcaptcha 无障碍支持，close [#166](https://github.com/lingyan000/fluxdo/issues/166) by @Lingyan000

- 优化桌面端登录按钮样式 by @Lingyan000

- 支持滑动关闭 PopupMenu by @Lingyan000

- Flatpak 构建测试 by @Lingyan000

- 优化 windows 关闭窗口流程 by @Lingyan000

- 取消登录失效二次验证，网络设置支持调整速率 by @Lingyan000

- 登录流程优化 by @Lingyan000

- 登录失效验证优化 by @Lingyan000

- Windows exe 安装包支持 by @Lingyan000


### 🐛 修复

- 修复含有 emoji 的链接无法点击跳转的问题，fix [#163](https://github.com/lingyan000/fluxdo/issues/163) by @Lingyan000

- 修复错误的日志记录 by @Lingyan000

- 修复通知面板骨架屏下移的问题 by @Lingyan000

- 尝试修复 windows 上登录完成之后不触发登录成功的问题 by @Lingyan000

- 修复个人页常用功能区域会溢出的问题 by @Lingyan000

- 加载新帖逻辑修复 by @Lingyan000

- 修复 windows 最大化异常问题 by @Lingyan000

- 通知面板显示修复，fix [#160](https://github.com/lingyan000/fluxdo/issues/160) by @Lingyan000


### 🔧 其他

- 🚀 部署优化 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/flatpak-wpe-layer-gnome48-v2...v0.1.56

## [0.1.55] - 2026-03-20


### 🌟 新功能

- 编辑器支持插入模板 by @Lingyan000

- Windows 兼容优化 by @Lingyan000

- 个人页布局优化 by @Lingyan000

- 请求并发控制优化 by @Lingyan000

- 优化 Cookie 同步逻辑 by @Lingyan000

- 提升内置浏览器体验，添加收藏能力，添加下载管理 by @Lingyan000

- 桌面端体验优化 by @Lingyan000

- 优化回复报错提示，close [#155](https://github.com/lingyan000/fluxdo/issues/155) by @Lingyan000

- 帖子详情和只看顶层实现，close [#153](https://github.com/lingyan000/fluxdo/issues/153) by @Lingyan000

- 用户登录失效判断优化 by @Lingyan000

- 过盾体验优化 by @Lingyan000

- 提高 rhttp 适配器稳定性 by @Lingyan000

- DOH 网关模式稳定性修复 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.54...v0.1.55

## [0.1.53] - 2026-03-17


### 🌟 新功能

- 支持邮箱链接登录 by @Lingyan000

- 支持切换字体，ref #152 by @Lingyan000

- AI 服务可跟随应用网络设置，close [#147](https://github.com/lingyan000/fluxdo/issues/147) by @Lingyan000

- 图片批量上传策略优化，close [#151](https://github.com/lingyan000/fluxdo/issues/151) by @Lingyan000

- 更新下载界面优化 by @Lingyan000

- 国际化支持 by @Lingyan000

- RHttp 适配器支持 by @Lingyan000


### 🐛 修复

- CF 验证相关问题修复 by @Lingyan000


### 🔧 其他

- 🚑️ 修复安卓无法启动 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.52...v0.1.53

## [0.1.52] - 2026-03-15


### 🌟 新功能

- 预览弹框可点击进入分类、标签列表 by @Lingyan000

- DOH 功能优化 by @Lingyan000

- 话题内头部信息分类、标签支持跳转，close [#146](https://github.com/lingyan000/fluxdo/issues/146) by @Lingyan000

- 表情面板功能优化 by @Lingyan000


### 🐛 修复

- 模糊剧透问题修复，fix [#150](https://github.com/lingyan000/fluxdo/issues/150) by @Lingyan000

- 修复创建或编辑话题时切换到预览无法发布的问题，fix [#116](https://github.com/lingyan000/fluxdo/issues/116) by @Lingyan000

- 修复 macOS 未声明相册权限导致的闪退，fix [#149](https://github.com/lingyan000/fluxdo/issues/149) by @Lingyan000

- 修复附件无法下载，fix [#141](https://github.com/lingyan000/fluxdo/issues/141) by @Lingyan000

- 修复了一些问题 by @Lingyan000


### 🔧 其他

- 🚀 CI 修复 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.51...v0.1.52

## [0.1.51] - 2026-03-13


### 🌟 新功能

- 表情包支持，感谢 @stevessr by @Lingyan000

- 提升网络请求稳定性 by @Lingyan000

- VPN 自动切换，close [#115](https://github.com/lingyan000/fluxdo/issues/115) by @Lingyan000

- DOH 支持复制地址、编辑，close [#138](https://github.com/lingyan000/fluxdo/issues/138)，close [#100](https://github.com/lingyan000/fluxdo/issues/100) by @Lingyan000

- 更新 doh_proxy by @Lingyan000

- FAB 子按钮支持 by @Lingyan000

- Improve upstream proxy support on android ([#125](https://github.com/lingyan000/fluxdo/pull/125)) by @RiftRays

- 帖子内容优化 by @Lingyan000

- 用户封禁显示，close [#139](https://github.com/lingyan000/fluxdo/issues/139) by @Lingyan000

- 支持图标切换 by @Lingyan000

- 图片批量上传，close [#130](https://github.com/lingyan000/fluxdo/issues/130) by @Lingyan000

- 图片查看器手势优化 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.50...v0.1.51

## [0.1.50] - 2026-03-12


### 🐛 修复

- 修复部分图片资源无法加载 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.49...v0.1.50

## [0.1.49] - 2026-03-12


### 🌟 新功能

- MacOS 图标优化 by @Lingyan000

- 图片链接提取优化 by @Lingyan000

- AI 助手界面优化，close [#136](https://github.com/lingyan000/fluxdo/issues/136) by @Lingyan000

- 帖子通知显示支持 by @Lingyan000


### 📝 文档

- README 更新 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.48...v0.1.49

## [0.1.48] - 2026-03-12


### 🌟 新功能

- 请求策略优化 by @Lingyan000

- 数据管理功能，refs #115 by @Lingyan000

- 优化书签列表显示效果 by @Lingyan000


### 🐛 修复

- 修复一些场景图片加载失效的问题 by @Lingyan000


### 🔧 其他

- 🚀 CI 修复 by @Lingyan000

- 🚀 MacOS 构建支持 by @Lingyan000

- 🚀 Altstore 支持，close [#135](https://github.com/lingyan000/fluxdo/issues/135) by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.47...v0.1.48

## [0.1.47] - 2026-03-11


### 🐛 修复

- 解决部分帖子无法点击查看大图的问题，fix [#134](https://github.com/lingyan000/fluxdo/issues/134) by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.46...v0.1.47

## [0.1.46] - 2026-03-10


### 🌟 新功能

- 优化书签卡片展示，refs #133 by @Lingyan000

- AI 助手导出图片功能，close [#132](https://github.com/lingyan000/fluxdo/issues/132) by @Lingyan000

- 优化回应弹框显示效果 by @Lingyan000

- 稍后阅读浮窗数量角标显示优化 by @Lingyan000

- AI 助手优化，close [#132](https://github.com/lingyan000/fluxdo/issues/132) by @Lingyan000

- 优化部分场景动画效果 by @Lingyan000

- 浮窗位置计算优化 by @Lingyan000

- 支持开关滚动收起导航栏 by @Lingyan000

- 启动页优化，防止一些极端场景卡启动页 by @Lingyan000

- 稍后阅读功能，refs #115 by @Lingyan000

- 书签功能优化，refs #115 by @Lingyan000

- SVG 渲染优化，close [#126](https://github.com/lingyan000/fluxdo/issues/126) by @Lingyan000

- 优化过盾逻辑 by @Lingyan000

- 异形屏横屏适配，close [#110](https://github.com/lingyan000/fluxdo/issues/110) by @Lingyan000

- Token 变更日志 by @Lingyan000

- 更详情的退出日志 by @Lingyan000


### 🐛 修复

- 修复邀请链接显示与限频提示 (#129) ([#129](https://github.com/lingyan000/fluxdo/pull/129)) by @N1nEmAn




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.45...v0.1.46

## [0.1.45] - 2026-03-10


### 🔧 其他

- 🚑️ 修复 CF 过盾异常 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.44...v0.1.45

## [0.1.44] - 2026-03-10


### 🐛 修复

- 修复话题详情到底还会继续触发加载的问题 by @Lingyan000


### 🔧 其他

- 🚑️ 修复 CF 盾后无法进入页面 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.43...v0.1.44

## [0.1.43] - 2026-03-09


### 🌟 新功能

- 一些功能优化 by @Lingyan000

- 元宇宙功能优化 by @Lingyan000

- 网络添加会话代守卫拦截器，提升应用稳定性 by @Lingyan000

- 过盾体验优化 by @Lingyan000


### 🐛 修复

- 修复了一些问题，ref #116 by @Lingyan000


### 🔧 其他

- Add invite links and remember AI model selection (#120) ([#120](https://github.com/lingyan000/fluxdo/pull/120)) by @N1nEmAn




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.42...v0.1.43

## [0.1.42] - 2026-03-07


### 🌟 新功能

- 应用日志功能优化 by @Lingyan000

- 请求相关问题优化 by @Lingyan000


### 🐛 修复

- 修复游客模式调用错误的 MessageBus 接口的问题 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.41...v0.1.42

## [0.1.41] - 2026-03-06


### 🌟 新功能

- 日志功能优化 by @Lingyan000

- 优化请求策略 by @Lingyan000

- 优化首页 tab 逻辑，避免同时请求 by @Lingyan000

- 请求相关优化 by @Lingyan000

- 网络断开提示 by @Lingyan000

- 优化 Toast 样式 by @Lingyan000

- 优化一些场景的请求 by @Lingyan000


### 🐛 修复

- 修复一些问题 by @Lingyan000

- 修复会通过主域名触发 MessageBus 的问题 by @Lingyan000

- 修复单栏创建话题时没有打开话题详情页面的问题 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.40...v0.1.41

## [0.1.40] - 2026-03-05


### 🌟 新功能

- 优化请求策略，避免频繁触发站点风控、掉登录等问题，close [#111](https://github.com/lingyan000/fluxdo/issues/111) #93 #75 #84 #60 by @Lingyan000

- 新话题/未读完计数展示 by @Lingyan000

- 优化通知计数自动归零的问题 by @Lingyan000


### 🐛 修复

- 修复话题更新提示功能的一些问题 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.39...v0.1.40

## [0.1.39] - 2026-03-05


### 🌟 新功能

- 优化话题更新提示和功能 by @Lingyan000

- 排序功能支持，close [#104](https://github.com/lingyan000/fluxdo/issues/104) #70 by @Lingyan000


### 🐛 修复

- 修复热门无法和其他筛选项组合的问题，fix [#107](https://github.com/lingyan000/fluxdo/issues/107) by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.38...v0.1.39

## [0.1.38] - 2026-03-03


### 🌟 新功能

- 应用样式焕新，取消绝大多数场景的卡片边框，更清爽 by @Lingyan000

- 轮播图查看支持 by @Lingyan000

- 文本选择修改为只能选择帖子内容 by @Lingyan000

- 日志集成设备信息，close [#92](https://github.com/lingyan000/fluxdo/issues/92) by @Lingyan000

- 应用日志功能实现 by @Lingyan000

- 首页向上滚动时 FAB 切换为刷新 by @Lingyan000

- 优化用户信息请求策略，回到前台时不再自动请求 by @Lingyan000

- 长按预览显示主贴，close [#98](https://github.com/lingyan000/fluxdo/issues/98) by @Lingyan000

- 优化图片上传功能，gif 不允许压缩 by @Lingyan000

- 优化内置浏览器体验，支持打开应用，close [#102](https://github.com/lingyan000/fluxdo/issues/102) by @Lingyan000

- 标签选择器逻辑优化，close [#103](https://github.com/lingyan000/fluxdo/issues/103) by @Lingyan000

- 优化 MessageBus 逻辑，更新为最新域名 by @Lingyan000

- 支持竖屏锁定 by @Lingyan000

- 集成 Firebase Crashlytics by @Lingyan000

- 优化响应式布局效果 by @Lingyan000

- 边界场景优化 by @Lingyan000

- 话题详情性能优化 by @Lingyan000

- 优化启动速度 by @Lingyan000

- 优化启动服务执行顺序 by @Lingyan000


### 🐛 修复

- 修复一些问题 by @Lingyan000

- 修复一处不影响使用的报错 by @Lingyan000


### 📝 文档

- 更新 README by @Lingyan000

- README 更新 by @Lingyan000


### 🔧 其他

- 🔧 追加 google-services.json by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.37...v0.1.38

## [0.1.37] - 2026-03-02


### 🔧 其他

- 🚑️ 回退 doh_proxy by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.36...v0.1.37

## [0.1.36] - 2026-03-02


### 🌟 新功能

- 网络错误场景优化 by @Lingyan000

- 更新 doh_proxy by @Lingyan000

- 优化一些边界场景的逻辑 by @Lingyan000

- 登录自动填充支持，close [#94](https://github.com/lingyan000/fluxdo/issues/94) by @Lingyan000

- 优化应用基础功能体验 by @Lingyan000

- 登录失效时弹框提示 by @Lingyan000


### 🐛 修复

- 修复首页不松手也会触发吸附显隐的问题 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.35...v0.1.36

## [0.1.35] - 2026-03-01


### 🌟 新功能

- 折叠帖子的显示，以及用户订阅功能实现 by @Lingyan000

- 混排优化功能优化，解决一些破坏 md 格式的问题 by @Lingyan000

- 元宇宙多卡片合并显示，close [#89](https://github.com/lingyan000/fluxdo/issues/89) by @Lingyan000

- AI 摘要渲染优化 by @Lingyan000


### 🐛 修复

- 修复首次打开更多菜单时打赏选项不显示的问题 by @Lingyan000

- 修复模糊剧透无法揭示的问题 by @Lingyan000


### ⚡ 性能

- ️ 长贴性能优化 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.34...v0.1.35

## [0.1.34] - 2026-02-28


### 🌟 新功能

- AI 助手交互优化，close [#83](https://github.com/lingyan000/fluxdo/issues/83) by @Lingyan000

- 图片缓存优化 by @Lingyan000

- 帖子内容渲染优化 by @Lingyan000

- 发帖审核提示，close [#86](https://github.com/lingyan000/fluxdo/issues/86) by @Lingyan000

- 实现打赏功能 by @Lingyan000

- 优化元宇宙相关功能显示逻辑 by @Lingyan000

- 图片支持长按打开菜单 by @Lingyan000

- DOH 逻辑优化 by @Lingyan000

- 模糊剧透的图片揭示之后可以点击查看大图 by @Lingyan000

- 支持输入楼层跳转，close [#80](https://github.com/lingyan000/fluxdo/issues/80) by @Lingyan000

- 离开 AI 页面时取消输入框焦点，防止返回时键盘意外弹出 by @Lingyan000


### 🐛 修复

- 修复 IOS 的一些异常情况 by @Lingyan000

- 修复贴内话题链接跳转异常问题 by @Lingyan000


### ⚡ 性能

- ️ 部分场景性能优化 by @Lingyan000


### 🔧 其他

- Create LICENSE by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.33...v0.1.34

## [0.1.33] - 2026-02-27


### 🌟 新功能

- 功能优化 by @Lingyan000

- 优化应用稳定性 by @Lingyan000

- 引用回复功能实现 by @Lingyan000

- 优化浏览分类弹框 UI by @Lingyan000

- 通知功能改版 by @Lingyan000

- 优化图片查看页面左右滑动 by @Lingyan000

- 图片查看器手势优化 by @Lingyan000

- DOH 日志完善 by @Lingyan000


### 🐛 修复

- 修复 AI 助手输入框聚焦时，帖子列表页面会弹出键盘的问题 by @Lingyan000

- 修复登录失效问题 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.32...v0.1.33

## [0.1.32] - 2026-02-26


### 🌟 新功能

- 优化 Cookie 读取逻辑 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.31...v0.1.32

## [0.1.31] - 2026-02-26


### 🌟 新功能

- 优化 AI 助手界面 UI，close [#74](https://github.com/lingyan000/fluxdo/issues/74) by @Lingyan000

- 优化后台通知逻辑 by @Lingyan000

- 通知卡片显示优化 by @Lingyan000

- 优化 MessageBus 代码逻辑 by @Lingyan000

- 优化 messageBus 429 重试逻辑 by @Lingyan000

- 时间显示优化 by @Lingyan000

- 通知列表分页支持 by @Lingyan000


### 🐛 修复

- 修复 IOS 保存图片闪退的问题，fix [#73](https://github.com/lingyan000/fluxdo/issues/73) by @Lingyan000

- 修复一些问题 by @Lingyan000

- 修复某些场景代码块显示异常 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.30...v0.1.31

## [0.1.30] - 2026-02-26


### 🐛 修复

- Cookie 问题修复 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.29...v0.1.30

## [0.1.29] - 2026-02-25


### 🐛 修复

- 修复 ci 异常 by @Lingyan000

- 修复 ios ci 编译异常 by @Lingyan000

- 修复一些问题 by @Lingyan000


### 🔧 其他

- 更新 CHANGELOG.md by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.28...v0.1.29

## [0.1.28] - 2026-02-24


### 🌟 新功能

- 编辑器图片上传前置 by @Lingyan000

- AI 助手集成 by @Lingyan000

- Cookie 同步逻辑优化 by @Lingyan000

- 元宇宙接入 CDK，close [#59](https://github.com/lingyan000/fluxdo/issues/59) by @Lingyan000

- 修复 callout 嵌套异常，fix [#69](https://github.com/lingyan000/fluxdo/issues/69) by @Lingyan000

- 优化图片显示 by @Lingyan000

- 优化图片查看体验 by @Lingyan000

- 图片查看页面显示图片名，close [#65](https://github.com/lingyan000/fluxdo/issues/65) by @Lingyan000

- 退出二次确认，close [#54](https://github.com/lingyan000/fluxdo/issues/54) by @Lingyan000

- 解决楼层数滚不到底的问题。 (#63) ([#63](https://github.com/lingyan000/fluxdo/pull/63)) by @Antman2023

- 优化小白条沉浸效果 by @Lingyan000


### 🐛 修复

- 修复 IOS 后台异常导致的重启 by @Lingyan000

- 修复底栏分享图标和其他图标颜色不一致的问题，fix [#68](https://github.com/lingyan000/fluxdo/issues/68) by @Lingyan000

- 修复模糊剧透显示到未展开 details 的问题，fix [#66](https://github.com/lingyan000/fluxdo/issues/66) by @Lingyan000

- 修复内置代理，webview 不被代理的问题，fix [#62](https://github.com/lingyan000/fluxdo/issues/62) by @Lingyan000


### ⚡ 性能

- ️ 优化内存占用 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.27...v0.1.28

## [0.1.27] - 2026-02-22


### 🌟 新功能

- 添加未浏览筛选项，close [#61](https://github.com/lingyan000/fluxdo/issues/61) by @Lingyan000

- 优化版主操作样式 by @Lingyan000


### 🐛 修复

- 修复表情选择器打开时，点击编辑器状态未切换的问题 by @Lingyan000


### ⚡ 性能

- ️ 缓存查询性能优化 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.26...v0.1.27

## [0.1.26] - 2026-02-22


### 🌟 新功能

- 回应支持查看回应人 by @Lingyan000

- 编辑器功能优化 by @Lingyan000


### 🐛 修复

- 修复进度指示器可能不准确的问题 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.25...v0.1.26

## [0.1.25] - 2026-02-21


### 🌟 新功能

- 长按预览支持更多页面，并支持快捷分享 by @Lingyan000

- 编辑器支持插入模糊剧透 by @Lingyan000

- 搜索结果包含 AI 结果，close [#52](https://github.com/lingyan000/fluxdo/issues/52) by @Lingyan000

- 话题列表排序持久化，close [#57](https://github.com/lingyan000/fluxdo/issues/57) by @Lingyan000

- 编辑器体验优化 by @Lingyan000

- 添加书签支持话题添加书签，close [#50](https://github.com/lingyan000/fluxdo/issues/50) by @Lingyan000

- 话题卡片更紧凑，并更新预览弹框显示更多信息，close [#58](https://github.com/lingyan000/fluxdo/issues/58) by @Lingyan000

- 优化全局提示效果 by @Lingyan000

- 后台通知优化 by @Lingyan000


### 🐛 修复

- 尝试修复自动混排和输入法自动括号冲突问题 by @Lingyan000

- 修复话题阅读数量不被统计的问题 by @Lingyan000

- 修复首贴不会被销毁的问题 by @Lingyan000

- 尝试修复横屏切换竖屏，布局不更新的问题，fix [#48](https://github.com/lingyan000/fluxdo/issues/48) by @Lingyan000

- 修复 IOS、MACOS 上的一些问题 by @Lingyan000

- 修复 ios 无法使用谷歌登录的问题，fix [#56](https://github.com/lingyan000/fluxdo/issues/56) by @Lingyan000

- 修复小白条沉浸问题，Fixes [#55](https://github.com/lingyan000/fluxdo/issues/55) by @Lingyan000

- 修复回复成功之后会回弹的问题 by @Lingyan000

- 修复我的页面的部分状态表情不显示的问题 by @Lingyan000

- 修复进入话题详情必须滑动才能触发阅读记录的问题 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.24...v0.1.25

## [0.1.24] - 2026-02-13


### 🌟 新功能

- 优化体验 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.23...v0.1.24

## [0.1.23] - 2026-02-12


### 🐛 修复

- 修复首页卡死 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.22...v0.1.23

## [0.1.22] - 2026-02-12


### 🌟 新功能

- 搜索功能优化 by @Lingyan000

- 用户资料页面优化，fix [#44](https://github.com/lingyan000/fluxdo/issues/44) by @Lingyan000

- 新、未读排序下可以一键已读，close [#42](https://github.com/lingyan000/fluxdo/issues/42) by @Lingyan000

- 优化体验 by @Lingyan000

- 首页焕新，全新的过滤交互，ref #43 by @Lingyan000

- 优化视频播放体验 by @Lingyan000

- 搜索功能优化 by @Lingyan000

- 用户资料页面优化，fix [#44](https://github.com/lingyan000/fluxdo/issues/44) by @Lingyan000

- 新、未读排序下可以一键已读，close [#42](https://github.com/lingyan000/fluxdo/issues/42) by @Lingyan000

- 优化体验 by @Lingyan000

- 首页焕新，全新的过滤交互，ref #43 by @Lingyan000

- 优化视频播放体验 by @Lingyan000


### 🐛 修复

- 修复一些问题 by @Lingyan000

- 修复一些问题 by @Lingyan000


### ♻️ 重构

- 重构图片粘贴实现 by @Lingyan000

- 重构图片粘贴实现 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.21...v0.1.22

## [0.1.21] - 2026-02-11


### 🌟 新功能

- 表情面板键盘切换效果优化 by @Lingyan000

- Connect UI 同步 by @Lingyan000

- 编辑体验优化，支持粘贴图片，refs #42 by @Lingyan000

- 链接确认打开弹框 by @Lingyan000

- 话题预览弹框样式优化 by @Lingyan000

- 生成图片分享功能优化 by @Lingyan000


### 🐛 修复

- 修复表情选择器无法切换 tab by @Lingyan000

- 修复了一些问题 by @Lingyan000

- 修复进度指示器部分场景不更新的问题 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.20...v0.1.21

## [0.1.19] - 2026-02-09


### 🌟 新功能

- 一些功能优化 by @Lingyan000

- 长贴性能优化 by @Lingyan000

- 新 connect 兼容 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.18...v0.1.19

## [0.1.18] - 2026-02-08


### 🐛 修复

- 转义 Telegram Markdown 特殊字符" by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.17...v0.1.18

## [0.1.17] - 2026-02-08


### 🌟 新功能

- 扫描性能优化 by @Lingyan000

- Code 表格内样式优化 by @Lingyan000

- 话题详情 Bar Actions 优化 by @Lingyan000

- 优化首页顶栏底栏隐藏逻辑，close [#39](https://github.com/lingyan000/fluxdo/issues/39) by @Lingyan000

- 话题内搜索 by @Lingyan000

- 我的书签、我的话题、浏览历史实现搜索功能 by @Lingyan000

- 优化扫描类背景的稳定性 by @Lingyan000

- 分享支持生成分享图片、导出文章功能，close [#38](https://github.com/lingyan000/fluxdo/issues/38) by @Lingyan000

- 帖子卡片显示更多的用户信息，close [#37](https://github.com/lingyan000/fluxdo/issues/37) by @Lingyan000

- Code 标签样式优化 by @Lingyan000


### 🐛 修复

- 修复分块渲染时没显示链接点击数 by @Lingyan000

- 修复搜索分页无效的问题 by @Lingyan000

- 修复 onebox 链接没有走通用链接跳转逻辑，fix [#40](https://github.com/lingyan000/fluxdo/issues/40) by @Lingyan000

- 修复图片高度显示异常 by @Lingyan000

- 修复某些场景提交完成之后不会正确删除草稿 by @Lingyan000

- 修复 image grid 画廊被隔离的问题 by @Lingyan000

- 修复引导页登录之后进入页面卡 loading 的问题 by @Lingyan000


### ♻️ 重构

- 重构 post_item by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.16...v0.1.17

## [0.1.12] - 2026-02-03


### 🌟 新功能

- 内联元素样式优化 by @Lingyan000

- 模糊剧透效果优化 by @Lingyan000

- 提升 iframe 浏览体验 by @Lingyan000

- DeepLink 逻辑优化 by @Lingyan000

- 支持图片网络显示/编辑 by @Lingyan000

- 有序/无序列表显示优化 by @Lingyan000

- 搜索记录排序记忆，Refs #31 by @Lingyan000

- 优化提及、内嵌代码块显示样式 by @Lingyan000

- Iframe 兼容性适配 by @Lingyan000

- 草稿功能体验优化 by @Lingyan000

- 响应式布局优化 by @Lingyan000

- 手动代理，close [#19](https://github.com/lingyan000/fluxdo/issues/19) by @Lingyan000

- 安卓动态图标实现，close [#33](https://github.com/lingyan000/fluxdo/issues/33) by @Lingyan000

- 草稿功能，close [#36](https://github.com/lingyan000/fluxdo/issues/36) by @Lingyan000

- 内容字体大小调节，close [#35](https://github.com/lingyan000/fluxdo/issues/35) by @Lingyan000

- 优化 iframe 实现，close [#34](https://github.com/lingyan000/fluxdo/issues/34) by @Lingyan000

- 内嵌网页版编辑个人信息，close [#27](https://github.com/lingyan000/fluxdo/issues/27) by @Lingyan000

- 页面错误提示优化 by @Lingyan000

- 支持应用链接，close [#26](https://github.com/lingyan000/fluxdo/issues/26) by @Lingyan000

- 头像显示优化 by @Lingyan000

- 链接点击数优化 by @Lingyan000

- X 卡片样式优化 by @Lingyan000

- 话题筛选功能优化，close [#29](https://github.com/lingyan000/fluxdo/issues/29) by @Lingyan000

- 应用内更新，close [#25](https://github.com/lingyan000/fluxdo/issues/25) by @Lingyan000

- 标签样式更新 by @Lingyan000

- 通知列表 emoji 显示 by @Lingyan000

- 偏好设置提供外部链接使用内置浏览器开关 by @Lingyan000

- 页面 loading 统一使用骨架屏 by @Lingyan000


### 🐛 修复

- 修复话题详情浅色模式骨架屏显示问题 by @Lingyan000

- 修复回应列表不能加载更多 by @Lingyan000

- 修复部分场景话题详情无法向下加载 by @Lingyan000

- 修复无法话题浏览器打开功能失效 by @Lingyan000

- 修复回应列表不能加载更多 by @Lingyan000

- 修复话题详情页面异常场景循环构建的问题 by @Lingyan000

- 修复部分场景跳转白屏问题 by @Lingyan000


### ⚡ 性能

- ️ 提升话题详情页滑动流畅性 by @Lingyan000


### ♻️ 重构

- 重构话题详情代码 by @Lingyan000

- 分页加载统一管理，fix [#27](https://github.com/lingyan000/fluxdo/issues/27) by @Lingyan000

- 通知列表标题优先展示纯文本，fix [#30](https://github.com/lingyan000/fluxdo/issues/30) by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.11...v0.1.12

## [0.1.11] - 2026-02-02


### 🌟 新功能

- Callout 显示优化 by @Lingyan000

- 话题头部排版优化 by @Lingyan000

- 首页底栏顶栏显示隐藏优化 by @Lingyan000

- 相关链接显示 by @Lingyan000

- 恢复完整的 pangu，提供降标安全保护，close [#18](https://github.com/lingyan000/fluxdo/issues/18) by @Lingyan000

- 切图体验优化 by @Lingyan000

- 搜索记录显示，错误消息处理，fix 23，close [#24](https://github.com/lingyan000/fluxdo/issues/24) by @Lingyan000

- 排版优化简化 by @Lingyan000

- 构建 ipa by @Lingyan000


### 🐛 修复

- 修复投票不显示查看结果按钮，fix [#13](https://github.com/lingyan000/fluxdo/issues/13) by @Lingyan000

- Tag 兼容补充 by @Lingyan000


### ⚡ 性能

- ️ 提升滑动流畅度 by @Lingyan000


### ♻️ 重构

- DiscourseService 重构 by @Lingyan000

- 代码警告消除 by @Lingyan000


### 🔧 其他

- CI 修复 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.10...v0.1.11

## [0.1.10] - 2026-02-02


### 🌟 新功能

- 图片查看器图片过渡显示优化 by @Lingyan000

- 底栏滑动自动隐藏 by @Lingyan000

- 骨架屏显示优化 by @Lingyan000

- 长按预览功能 by @Lingyan000


### 🐛 修复

- 修复话题详情嵌套视图滚动会显示隐藏底栏的问题 by @Lingyan000


### 🔧 其他

- 🚑️ 兼容新的 api 结构，解决无法显示话题详情的问题（fix [#20](https://github.com/lingyan000/fluxdo/issues/20)） by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.9...v0.1.10

## [0.1.9] - 2026-02-01


### 🌟 新功能

- 匿名分享功能实现，(close [#15](https://github.com/lingyan000/fluxdo/issues/15)) by @Lingyan000

- 话题编辑功能，(close [#17](https://github.com/lingyan000/fluxdo/issues/17)) by @Lingyan000

- 支持混排优化，(close [#16](https://github.com/lingyan000/fluxdo/issues/16)) by @Lingyan000

- 修改回复主贴为等同回复话题，(close [#14](https://github.com/lingyan000/fluxdo/issues/14)) by @Lingyan000

- 支持删除线编辑，(close [#10](https://github.com/lingyan000/fluxdo/issues/10)) by @Lingyan000

- 时间解析优化，(fix [#10](https://github.com/lingyan000/fluxdo/issues/10)) by @Lingyan000

- 兼容聊天记录引用卡片 by @Lingyan000

- 登录登出体验优化 by @Lingyan000

- 采用更真实的设备 ua by @Lingyan000

- 图片查看优化 by @Lingyan000

- 公式内容显示支持 by @Lingyan000

- 图片上传体验优化，(close [#8](https://github.com/lingyan000/fluxdo/issues/8)) by @Lingyan000

- 帖子删除功能，(close [#6](https://github.com/lingyan000/fluxdo/issues/6)) by @Lingyan000

- 快问快答话题兼容 by @Lingyan000

- 优化图片查看页面状态栏显示 by @Lingyan000

- 优化过盾流程，仅不影响操作的放到后台过盾，并在网络设置中支持手动过盾 by @Lingyan000


### 🐛 修复

- 话题详情页面 bar 背景颜色切换错误修复 by @Lingyan000

- 修复 LDC 余额显示错误，(fix [#12](https://github.com/lingyan000/fluxdo/issues/12)) by @Lingyan000

- 修复相对路径图片不加载的问题，(fix [#3](https://github.com/lingyan000/fluxdo/issues/3)) by @Lingyan000


### 📝 文档

- 添加项目提示词 by @Lingyan000


### 📦 依赖更新

- ️ 依赖更新 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.8...v0.1.9

## [0.1.8] - 2026-01-31


### 🌟 新功能

- 添加 CIRA Canadian Shield 为内置 DOH 服务，（close [#5](https://github.com/lingyan000/fluxdo/issues/5)） by @Lingyan000

- 热门回复/只看题主体验优化 by @Lingyan000

- 大屏显示优化 by @Lingyan000


### 🔧 其他

- 🚑️ CF 过盾体验优化，解决启动时遇到盾会无法启动的问题 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.7...v0.1.8

## [0.1.7] - 2026-01-30


### 🌟 新功能

- UA 修改静态值，修复无法使用谷歌登录 by @Lingyan000

- 代码块显示优化 by @Lingyan000

- 只看题主功能实现 by @Lingyan000


### 🐛 修复

- 修复发送提示不会自动消失，(fixes [#2](https://github.com/lingyan000/fluxdo/issues/2)) by @Lingyan000

- 跳转问题修复 by @Lingyan000

- Mac 构建修复 by @Lingyan000


### ⚡ 性能

- ️ CF 过盾优化与日志导出 by @Lingyan000

- ️ 优化大屏使用体验 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.6...v0.1.7

## [0.1.6] - 2026-01-29


### 🌟 新功能

- 大图查看支持隐藏功能按钮、状态栏 by @Lingyan000

- 贴内图片支持分享 by @Lingyan000

- 优化大图查看体验 by @Lingyan000

- 用户资料页面头像支持大图查看 by @Lingyan000

- 优化提及块样式 by @Lingyan000

- 热门回复功能 by @Lingyan000

- 显示题主[主]，本人[我]的标识 by @Lingyan000


### 🐛 修复

- 修复分享完成后不能回到当前应用的问题 by @Lingyan000

- Onebox 显示优化 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.5...v0.1.6

## [0.1.5] - 2026-01-28


### 🌟 新功能

- 新的代码高亮实现 by @Lingyan000

- Bar 点击标题展开 header by @Lingyan000

- 追踪链接点击 by @Lingyan000

- OneBox 更多类型展示 by @Lingyan000

- 话题订阅功能 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.4...v0.1.5

## [0.1.4] - 2026-01-27


### 🌟 新功能

- 支持帖子编辑功能和编辑时支持提及（@触发） by @Lingyan000


### 🐛 修复

- 修复话题投票时会直接刷新整个详情的问题 by @Lingyan000

- 修复回到顶部概率触发刷新 by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.3...v0.1.4

## [0.1.3] - 2026-01-26


### 🌟 新功能

- Add PreloadedDataService for efficient initial data loading and configure Android build with ABI filtering. by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.2...v0.1.3

## [0.1.2] - 2026-01-25


### 🌟 新功能

- Implement topic detail page with scroll management, post display, and visibility tracking. by @Lingyan000

- Add Discourse HTML content rendering with custom builders for various elements, including quote cards. by @Lingyan000

- Implement Discourse poll rendering and voting, and configure Android build with signing and desugaring. by @Lingyan000

- Add user profile page with login/logout, user settings, and initial Android build configuration. by @Lingyan000

- Implement topic detail page with dynamic post loading, scrolling, and user activity tracking. by @Lingyan000

- Implement core Discourse API service and topic detail page, including authentication, network handling, and screen tracking. by @Lingyan000

- Initialize Android build configuration and Flutter app entry point with service setup, theming, and localization. by @Lingyan000

- Implement topic creation flow with floating action button, navigation, and list refresh. by @Lingyan000

- Implement topic detail page with bi-directional post loading and new reply updates. by @Lingyan000

- Add GitHub Actions workflow for automated Android build, release, and changelog generation, including supporting scripts. by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.1...v0.1.2

## [0.1.1] - 2026-01-25


### 🌟 新功能

- Implement comprehensive CI/CD pipeline for Android builds, including Rust DOH proxy compilation, artifact generation, changelog, and release automation. by @Lingyan000




**Full Changelog**: https://github.com/lingyan000/fluxdo/compare/v0.1.0...v0.1.1

## [0.1.0] - 2026-01-24


### 🔧 其他

- Mvp by @Lingyan000




