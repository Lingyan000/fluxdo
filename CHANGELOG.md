## v0.2.8


## v0.2.8-beta.6

- 🐛 CI 修复

## v0.2.8-beta.5

- ✨ 修复 Windows 无法分享的问题，close #200

- ✨ 修复 windows 无法上传图片，close #212

- ✨ 网络检查性能优化，ref #205

- ✨ 通知、私信功能优化，并添加私信列表，close #216

- ♻️ 取消提交多语言的 merged

- 🐛 修复 Windows 无法关闭的问题

- ♻️ 多语言能力模块化设计

- 🐛 修复某些场景无法加载更多帖子的问题

- 🐛 修复帖子内容更新后无法发送 boost

## v0.2.8-beta.4

- ✨ 保守登出复检机制

## v0.2.8-beta.3

- ✨ WebView 适配器缓存问题修复

## v0.2.8-beta.2

- ✨ 日志记录优化

## v0.2.8-beta.1

- 🐛 修复 cookieJar 同步到 webview 的异常


## v0.2.7


- ✨ 自检优化

- ✨ 优化 boost 显示

## v0.2.7-beta.10

- ✨ 解决应用内清除 Cookie 的隐患

## v0.2.7-beta.9

- ✨ 移除 Android CDP 同步 Cookie

## v0.2.7-beta.8

- ✨ 一些功能优化

## v0.2.7-beta.7

- ✨ 样式优化

- ✨ Webview 适配器支持

- ✨ 嵌套视图实现（实验性）

- ✨  boost 支持

## v0.2.7-beta.5

- ✨ 适配器优化

## v0.2.7-beta.4

- ✨ 登录流程优化

## v0.2.7-beta.2



## v0.2.7-beta.1

- ✨ 请求链路优化

- ✨ 桌面端快捷键完善

- 🐛 修复 Windows 上 WebView 不被代理的问题，fix #199

- ✨ CF 自动续期逻辑优化

## v0.2.6


- ✨ Windows 图标圆角，close #183

- ✨ 桌面端快捷键支持

- ✨ 桌面平台鼠标操作优化，ref #186

- ✨ 支持私信反馈日志

- ✨ 附件上传支持

- ✨ MessageBus 日志记录优化

- 🐛 修复 Cronet 适配器异常降级无法恢复的问题

- ✨ 模糊效果优化

## v0.2.5


- 🚑️ Windows 卡验证修复


## v0.2.4


## v0.2.4-beta.2

- ✨ 添加元宇宙授权遇到异常时的提示，close #172

- 🐛 修复双栏模式下，分类/标签详情列表无法跳转的问题，fix #191

## v0.2.4-beta.1

- ✨ 下载功能优化，close #180

- ✨ Cookie 逻辑精简优化，⚠️ 需要重新登录

- ✨ CA 证书相关优化，IOS 编译优化

- ✨ 模糊效果优化

- 🐛: APP内置网页浏览注入 iOS 15 polyfill 修复JS缺失导致白屏问题 (#190)

## v0.2.3


- 🚑️ 取消 Android 默认 CDP 机制，不再支持 WebView 双向同步，解决新版本掉登录问题

- 🐛: 注入 iOS 15 JS polyfill 修复登录页白屏问题 (#185)


## v0.2.2


- 🚑️ 尝试解决掉登录的问题

## v0.2.1


- 🚑️ 修复 Cookie 无法读取的问题



- 🐛 修复一些问题

## v0.2.0-beta.3

- ✨ 支持对话框模糊背景

## v0.2.0-beta.2

- 🐛 修复 IOS 编译问题

## v0.2.0-beta.1

- ✨ 长表格渲染优化，close #170

- ✨ 功能优化

- ✨ AI 助手可开启滑动显示模式

- ✨ 统计卡片自定义

- 🐛 修复 macOS 14 版本判断错误 (#176)

- ✨ 功能优化，UI 更新

- ✨ 新 Cookie 机制迁移

- ✨ Windows DOH 适配

- ✨ 修改 CookieJar 与 WebView Cookie 的同步方式

- ✨ Cookie 相关代码逻辑优化

## v0.1.57-beta.1

- ✨ CA 证书相关优化

- 🚀 CI 优化

- ✨ IOS DOH 功能支持

- 🐛 修复 macOS 滚轮/触控板滚动导致的吸附跳动 (#173)

- ✨ 优化 macOS 构建以及支持 macOS 的 WebView 代理 (#171)


## v0.1.56


- ✨ 功能优化

## v0.1.56-beta.11

- 🚀 部署优化

- ✨ 优化下载附件文件名获取逻辑

- ✨ AI助手未配置 API Key 时提示

- 🐛 修复含有 emoji 的链接无法点击跳转的问题，fix #163

- ✨ Hcaptcha 无障碍支持，close #166

- ✨ 优化桌面端登录按钮样式

- ✨ 支持滑动关闭 PopupMenu

## v0.1.56-beta.9

- ✨ Flatpak 构建测试

## v0.1.56-beta.4

- 🐛 修复错误的日志记录

- 🐛 修复通知面板骨架屏下移的问题

- ✨ 优化 windows 关闭窗口流程

- ✨ 取消登录失效二次验证，网络设置支持调整速率

## v0.1.56-beta.3

- ✨ 登录流程优化

## v0.1.56-beta.2

- 🐛 CI 修复

## v0.1.56-beta.1

- ✨ 登录失效验证优化

- ✨ Windows exe 安装包支持

- 🐛 尝试修复 windows 上登录完成之后不触发登录成功的问题

- 🐛 修复个人页常用功能区域会溢出的问题

- 🐛 加载新帖逻辑修复

- 🐛 修复 windows 最大化异常问题

- 🐛 通知面板显示修复，fix #160

## flatpak-wpe-layer-gnome48-v1


## flatpak-wpe-layer-gnome48-v2


## v0.1.55


- ✨ 编辑器支持插入模板

- ✨ Windows 兼容优化

- ✨ 个人页布局优化

## v0.1.55-beta.6

- ✨ 请求并发控制优化

## v0.1.55-beta.5

- ✨ 优化 Cookie 同步逻辑

- ✨ 提升内置浏览器体验，添加收藏能力，添加下载管理

- ✨ 桌面端体验优化

- ✨ 优化回复报错提示，close #155

- ✨ 帖子详情和只看顶层实现，close #153

## v0.1.55-beta.3

- ✨ 用户登录失效判断优化

## v0.1.55-beta.2

- ✨ 过盾体验优化

## v0.1.55-beta.1

- ✨ 提高 rhttp 适配器稳定性

- ✨ DOH 网关模式稳定性修复


## v0.1.54


- 🚑️ 修复安卓无法启动


## v0.1.53


- ✨ 支持邮箱链接登录

- ✨ 支持切换字体，ref #152

- ✨ AI 服务可跟随应用网络设置，close #147

- ✨ 图片批量上传策略优化，close #151

- 🐛 CF 验证相关问题修复

- ✨ 更新下载界面优化

- ✨ 国际化支持

## v0.1.53-beta.11

- ✨ RHttp 适配器支持

- ✨ 预览弹框可点击进入分类、标签列表

- 🐛 模糊剧透问题修复，fix #150



## v0.1.53-beta.2

- 🚀 CI 修复

## v0.1.53-beta.1

- ✨ DOH 功能优化

- 🐛 修复创建或编辑话题时切换到预览无法发布的问题，fix #116

- ✨ 话题内头部信息分类、标签支持跳转，close #146

- 🐛 修复 macOS 未声明相册权限导致的闪退，fix #149

## v0.1.52


- 🐛 修复附件无法下载，fix #141

- ✨ 表情面板功能优化

## v0.1.52-beta.1

- 🐛 修复了一些问题


## v0.1.51


- ✨ 表情包支持，感谢 @stevessr

- ✨ 提升网络请求稳定性

- ✨ VPN 自动切换，close #115

- ✨ DOH 支持复制地址、编辑，close #138，close #100

- ✨ 更新 doh_proxy

- ✨ FAB 子按钮支持

- ✨ improve upstream proxy support on android (#125)

- ✨ 帖子内容优化

- ✨ 用户封禁显示，close #139

- ✨ 支持图标切换

- ✨ 图片批量上传，close #130

- ✨ 图片查看器手势优化

- ✨ MacOS 图标优化


## v0.1.50


- 🐛 修复部分图片资源无法加载


## v0.1.49


- ✨ 图片链接提取优化

- ✨ AI 助手界面优化，close #136

- ✨ 帖子通知显示支持

- 📝 README 更新


## v0.1.48

- 🚀 CI 修复


- 🚀 MacOS 构建支持

- ✨ 请求策略优化

- 🐛 修复一些场景图片加载失效的问题

- ✨ 数据管理功能，refs #115

- 🚀 Altstore 支持，close #135

- ✨ 优化书签列表显示效果


## v0.1.47


- 🐛 解决部分帖子无法点击查看大图的问题，fix #134

- ✨ 优化书签卡片展示，refs #133

- ✨ AI 助手导出图片功能，close #132

- ✨ 优化回应弹框显示效果

- ✨ 稍后阅读浮窗数量角标显示优化

- ✨ AI 助手优化，close #132

- ✨ 优化部分场景动画效果

- ✨ 浮窗位置计算优化


## v0.1.46


- ✨ 支持开关滚动收起导航栏

- ✨ 启动页优化，防止一些极端场景卡启动页

- 🐛 修复邀请链接显示与限频提示 (#129)

## v0.1.46-beta.2

- ✨ 稍后阅读功能，refs #115

- ✨ 书签功能优化，refs #115

- ✨ SVG 渲染优化，close #126

- ✨ 优化过盾逻辑

- ✨ 异形屏横屏适配，close #110

## v0.1.46-beta.1

- ✨ Token 变更日志

- ✨ 更详情的退出日志


## v0.1.45


- 🚑️ 修复 CF 过盾异常


## v0.1.44


- 🐛 修复话题详情到底还会继续触发加载的问题

- 🚑️ 修复 CF 盾后无法进入页面


## v0.1.43


- ✨ 一些功能优化

- Add invite links and remember AI model selection (#120)

- 🐛 修复了一些问题，ref #116

- ✨ 元宇宙功能优化

- ✨ 网络添加会话代守卫拦截器，提升应用稳定性

- ✨ 过盾体验优化


## v0.1.42


- ✨ 应用日志功能优化

- ✨ 请求相关问题优化

- 🐛 修复游客模式调用错误的 MessageBus 接口的问题


## v0.1.41


- ✨ 日志功能优化

- ✨ 优化请求策略

- 🐛 修复一些问题

- 🐛 修复会通过主域名触发 MessageBus 的问题

- ✨ 优化首页 tab 逻辑，避免同时请求

- ✨ 请求相关优化

- ✨ 网络断开提示

- ✨ 优化 Toast 样式

- 🐛 修复单栏创建话题时没有打开话题详情页面的问题

- ✨ 优化一些场景的请求


## v0.1.40


- ✨ 优化请求策略，避免频繁触发站点风控、掉登录等问题，close #111 #93 #75 #84 #60

- ✨ 新话题/未读完计数展示

- 🐛 修复话题更新提示功能的一些问题

- ✨ 优化通知计数自动归零的问题


## v0.1.39


- ✨ 优化话题更新提示和功能

- ✨ 排序功能支持，close #104 #70

- 🐛 修复热门无法和其他筛选项组合的问题，fix #107

- ✨ 应用样式焕新，取消绝大多数场景的卡片边框，更清爽

- ✨ 轮播图查看支持

- ✨ 文本选择修改为只能选择帖子内容

- ✨ 日志集成设备信息，close #92

- 🐛 修复一些问题

- ✨ 应用日志功能实现

- 📝 更新 README

- 🐛 修复一处不影响使用的报错

- ✨ 首页向上滚动时 FAB 切换为刷新

- ✨ 优化用户信息请求策略，回到前台时不再自动请求


## v0.1.38


- ✨ 长按预览显示主贴，close #98

- ✨ 优化图片上传功能，gif 不允许压缩

- ✨ 优化内置浏览器体验，支持打开应用，close #102

- ✨ 标签选择器逻辑优化，close #103

- ✨ 优化 MessageBus 逻辑，更新为最新域名

- 🔧 追加 google-services.json

- ✨ 支持竖屏锁定

- ✨ 集成 Firebase Crashlytics

- ✨ 优化响应式布局效果

- ✨ 边界场景优化

- ✨ 话题详情性能优化

- ✨ 优化启动速度

- ✨ 优化启动服务执行顺序

- 📝 README 更新


## v0.1.37


- 🚑️ 回退 doh_proxy


## v0.1.36


- ✨ 网络错误场景优化

- ✨ 更新 doh_proxy

- ✨ 优化一些边界场景的逻辑

- ✨ 登录自动填充支持，close #94

- ✨ 优化应用基础功能体验

- ✨ 登录失效时弹框提示

- 🐛 修复首页不松手也会触发吸附显隐的问题


## v0.1.35


- ✨ 折叠帖子的显示，以及用户订阅功能实现

- 🐛 修复首次打开更多菜单时打赏选项不显示的问题

- ✨ 混排优化功能优化，解决一些破坏 md 格式的问题

- ⚡️ 长贴性能优化

- 🐛 修复模糊剧透无法揭示的问题

- ✨ 元宇宙多卡片合并显示，close #89

- ✨ AI 摘要渲染优化


## v0.1.34


- ⚡️ 部分场景性能优化

- ✨ AI 助手交互优化，close #83

- ✨ 图片缓存优化

- ✨ 帖子内容渲染优化

- ✨ 发帖审核提示，close #86

- ✨ 实现打赏功能

- 🐛 修复 IOS 的一些异常情况

- ✨ 优化元宇宙相关功能显示逻辑

- 🐛 修复贴内话题链接跳转异常问题

- ✨ 图片支持长按打开菜单

- ✨ DOH 逻辑优化

- ✨ 模糊剧透的图片揭示之后可以点击查看大图

- ✨ 支持输入楼层跳转，close #80

- Create LICENSE

- ✨ 离开 AI 页面时取消输入框焦点，防止返回时键盘意外弹出


## v0.1.33


- ✨ 功能优化

## v0.1.33-beta.2


- ✨ 优化应用稳定性

- ✨ 引用回复功能实现

- ✨ 优化浏览分类弹框 UI

- ✨ 通知功能改版

- ✨ 优化图片查看页面左右滑动

- ✨ 图片查看器手势优化

- ✨ DOH 日志完善

- 🐛 修复 AI 助手输入框聚焦时，帖子列表页面会弹出键盘的问题

- 🐛 修复登录失效问题


## v0.1.32


- ✨ 优化 Cookie 读取逻辑


## v0.1.31


- 🐛 修复 IOS 保存图片闪退的问题，fix #73

- ✨ 优化 AI 助手界面 UI，close #74

- 🐛 修复一些问题

- 🐛 修复某些场景代码块显示异常

- ✨ 优化后台通知逻辑

- ✨ 通知卡片显示优化

- ✨ 优化 MessageBus 代码逻辑

- ✨ 优化 messageBus 429 重试逻辑

- ✨ 时间显示优化

- ✨ 通知列表分页支持


## v0.1.30


- 🐛 Cookie 问题修复

## v0.1.29

- 🐛 修复 ci 异常

- 🐛 修复 ios ci 编译异常


- 🐛 修复一些问题

- ✨ 编辑器图片上传前置

- 🐛 修复 IOS 后台异常导致的重启

- ✨ AI 助手集成

- ✨ Cookie 同步逻辑优化

- ✨ 元宇宙接入 CDK，close #59

- ⚡️ 优化内存占用

- ✨ 修复 callout 嵌套异常，fix #69

- 🐛 修复底栏分享图标和其他图标颜色不一致的问题，fix #68

- 更新 CHANGELOG.md


## v0.1.28


- ✨ 优化图片显示

- ✨ 优化图片查看体验

- 🐛 修复模糊剧透显示到未展开 details 的问题，fix #66

- ✨ 图片查看页面显示图片名，close #65

- ✨ 退出二次确认，close #54

- 🐛 修复内置代理，webview 不被代理的问题，fix #62

- ✨ 解决楼层数滚不到底的问题。 (#63)

- ✨ 优化小白条沉浸效果


## v0.1.27


- 🐛 修复表情选择器打开时，点击编辑器状态未切换的问题

- ✨ 添加未浏览筛选项，close #61

- ✨ 优化版主操作样式

- ⚡️ 缓存查询性能优化


## v0.1.26


- ✨ 回应支持查看回应人

- ✨ 编辑器功能优化

- 🐛 修复进度指示器可能不准确的问题


## v0.1.25


- ✨ 长按预览支持更多页面，并支持快捷分享

- 🐛 尝试修复自动混排和输入法自动括号冲突问题

- ✨ 编辑器支持插入模糊剧透

- 🐛 修复话题阅读数量不被统计的问题

- 🐛 修复首贴不会被销毁的问题

- ✨ 搜索结果包含 AI 结果，close #52

- ✨ 话题列表排序持久化，close #57

- 🐛 尝试修复横屏切换竖屏，布局不更新的问题，fix #48

- 🐛 修复 IOS、MACOS 上的一些问题

- 🐛 修复 ios 无法使用谷歌登录的问题，fix #56

- ✨ 编辑器体验优化

- ✨ 添加书签支持话题添加书签，close #50

- ✨ 话题卡片更紧凑，并更新预览弹框显示更多信息，close #58

- 🐛 修复小白条沉浸问题，Fixes #55

- 🐛 修复回复成功之后会回弹的问题

- ✨ 优化全局提示效果

- 🐛 修复我的页面的部分状态表情不显示的问题

- 🐛 修复进入话题详情必须滑动才能触发阅读记录的问题

- ✨ 后台通知优化


## v0.1.24


- ✨ 优化体验


## v0.1.23


- 🐛 修复首页卡死


- ✨ 搜索功能优化

- ✨ 用户资料页面优化，fix #44

- ✨ 新、未读排序下可以一键已读，close #42

- ✨ 优化体验

- ♻️ 重构图片粘贴实现

- 🐛 修复一些问题

- ✨ 首页焕新，全新的过滤交互，ref #43

- ✨ 优化视频播放体验

## v0.1.22


- ✨ 搜索功能优化

- ✨ 用户资料页面优化，fix #44

- ✨ 新、未读排序下可以一键已读，close #42

- ✨ 优化体验

- ♻️ 重构图片粘贴实现

- 🐛 修复一些问题

- ✨ 首页焕新，全新的过滤交互，ref #43

- ✨ 优化视频播放体验


## v0.1.21

- 🐛 修复表情选择器无法切换 tab


- 🐛 修复了一些问题


- ✨ 表情面板键盘切换效果优化

- ✨ Connect UI 同步

- ✨ 编辑体验优化，支持粘贴图片，refs #42

- ✨ 链接确认打开弹框

- ✨ 话题预览弹框样式优化

- 🐛 修复进度指示器部分场景不更新的问题

- ✨ 生成图片分享功能优化

## v0.1.20



## v0.1.19


- ✨ 一些功能优化

- ✨ 长贴性能优化

- ✨ 新 connect 兼容

- ✨ 扫描性能优化

- 🐛 修复分块渲染时没显示链接点击数

- ✨ Code 表格内样式优化

- ✨ 话题详情 Bar Actions 优化

- ✨ 优化首页顶栏底栏隐藏逻辑，close #39

- 🐛 修复搜索分页无效的问题

- ✨ 话题内搜索

- ✨ 我的书签、我的话题、浏览历史实现搜索功能

- ✨ 优化扫描类背景的稳定性

- 🐛 修复 onebox 链接没有走通用链接跳转逻辑，fix #40


## v0.1.18


- 🐛 转义 Telegram Markdown 特殊字符"

## v0.1.17


- ✨  分享支持生成分享图片、导出文章功能，close #38

- 🐛 修复图片高度显示异常

- 🐛 修复某些场景提交完成之后不会正确删除草稿

- ♻️ 重构 post_item

- ✨ 帖子卡片显示更多的用户信息，close #37

- 🐛 修复 image grid 画廊被隔离的问题

- ✨ Code 标签样式优化

- 🐛 修复引导页登录之后进入页面卡 loading 的问题


## v0.1.16


- ✨ 内联元素样式优化

- 🐛 修复话题详情浅色模式骨架屏显示问题

- ✨ 模糊剧透效果优化

- ✨ 提升 iframe 浏览体验

- ✨ DeepLink 逻辑优化

- ✨ 支持图片网络显示/编辑

- ✨ 有序/无序列表显示优化

- ✨ 搜索记录排序记忆，Refs #31

- ✨ 优化提及、内嵌代码块显示样式

- ✨ Iframe 兼容性适配

- ✨ 草稿功能体验优化


## v0.1.15


- ✨ 响应式布局优化

- ✨ 手动代理，close #19

- ✨ 安卓动态图标实现，close #33

- ✨ 草稿功能，close #36

- ✨ 内容字体大小调节，close #35

- ✨ 优化 iframe 实现，close #34

- ⚡️ 提升话题详情页滑动流畅性

- ♻️ 重构话题详情代码

- 🐛 修复回应列表不能加载更多

- 🐛 修复部分场景话题详情无法向下加载


## v0.1.14


- 🐛 修复无法话题浏览器打开功能失效

- 🐛 修复回应列表不能加载更多


## v0.1.13


- ✨ 内嵌网页版编辑个人信息，close #27

- ✨ 页面错误提示优化

- 🐛 修复话题详情页面异常场景循环构建的问题

- ✨ 支持应用链接，close #26

- ✨ 头像显示优化

- ✨ 链接点击数优化

- ✨ X 卡片样式优化

- ✨ 话题筛选功能优化，close #29

- ♻️ 分页加载统一管理，fix #27

- ♻️ 通知列表标题优先展示纯文本，fix #30

- 🐛 修复部分场景跳转白屏问题

## v0.1.12


- ✨ 应用内更新，close #25

- ✨ 标签样式更新

- ✨ 通知列表 emoji 显示

- ✨ 偏好设置提供外部链接使用内置浏览器开关

- ✨ 页面 loading 统一使用骨架屏

- ♻️ DiscourseService 重构

- ♻️ 代码警告消除

- ⚡️ 提升滑动流畅度


## v0.1.11

- chore: CI 修复


- ✨ Callout 显示优化

- ✨ 话题头部排版优化

- ✨ 首页底栏顶栏显示隐藏优化

- ✨ 相关链接显示

- 🐛 修复投票不显示查看结果按钮，fix #13

- ✨ 恢复完整的 pangu，提供降标安全保护，close #18

- ✨ 切图体验优化

- ✨ 搜索记录显示，错误消息处理，fix 23，close #24

- 🐛 Tag 兼容补充

- ✨ 排版优化简化

- ✨ 构建 ipa


## v0.1.10


- 🚑️ 兼容新的 api 结构，解决无法显示话题详情的问题（fix #20）

- ✨ 图片查看器图片过渡显示优化

- 🐛 修复话题详情嵌套视图滚动会显示隐藏底栏的问题

- ✨ 底栏滑动自动隐藏

- ✨ 骨架屏显示优化

- ✨ 长按预览功能


## v0.1.9


- 🐛 话题详情页面 bar 背景颜色切换错误修复

- ✨ 匿名分享功能实现，(close #15)

- ✨ 话题编辑功能，(close #17)

- ✨ 支持混排优化，(close #16)

- ✨ 修改回复主贴为等同回复话题，(close #14)

- ✨ 支持删除线编辑，(close #10)

- ✨ 时间解析优化，(fix #10)

- 📝 添加项目提示词

- 🐛 修复 LDC 余额显示错误，(fix #12)

- ✨ 兼容聊天记录引用卡片

- ✨ 登录登出体验优化

- 📦️ 依赖更新

- ✨ 采用更真实的设备 ua

- ✨ 图片查看优化

- ✨ 公式内容显示支持

- ✨ 图片上传体验优化，(close #8)

- ✨ 帖子删除功能，(close #6)

- 🐛 修复相对路径图片不加载的问题，(fix #3)

- ✨ 快问快答话题兼容

- ✨ 优化图片查看页面状态栏显示

- ✨ 优化过盾流程，仅不影响操作的放到后台过盾，并在网络设置中支持手动过盾


## v0.1.8


- ✨ 添加 CIRA Canadian Shield 为内置 DOH 服务，（close #5）

- 🚑️ CF 过盾体验优化，解决启动时遇到盾会无法启动的问题

- ✨ 热门回复/只看题主体验优化

- ✨ 大屏显示优化


## v0.1.7


- ✨ UA 修改静态值，修复无法使用谷歌登录

- ⚡️ CF 过盾优化与日志导出

- ⚡️ 优化大屏使用体验

- ✨ 代码块显示优化

- 🐛 修复发送提示不会自动消失，(fixes #2)

- ✨ 只看题主功能实现

- 🐛 跳转问题修复

- 🐛 Mac 构建修复


## v0.1.6


- ✨ 大图查看支持隐藏功能按钮、状态栏

- ✨ 贴内图片支持分享

- 🐛 修复分享完成后不能回到当前应用的问题

- ✨ 优化大图查看体验

- ✨ 用户资料页面头像支持大图查看

- ✨ 优化提及块样式

- ✨ 热门回复功能

- ✨ 显示题主[主]，本人[我]的标识

- 🐛 Onebox 显示优化


## v0.1.5


- ✨ 新的代码高亮实现

- ✨ Bar 点击标题展开 header

- ✨ 追踪链接点击

- ✨ OneBox 更多类型展示

- ✨ 话题订阅功能


## v0.1.4


- 🐛 修复话题投票时会直接刷新整个详情的问题

- 🐛 修复回到顶部概率触发刷新

- ✨ 支持帖子编辑功能和编辑时支持提及（@触发）


## v0.1.3


- feat: add PreloadedDataService for efficient initial data loading and configure Android build with ABI filtering.

- feat: implement topic detail page with scroll management, post display, and visibility tracking.

- feat: Add Discourse HTML content rendering with custom builders for various elements, including quote cards.

- feat: Implement Discourse poll rendering and voting, and configure Android build with signing and desugaring.

- feat: add user profile page with login/logout, user settings, and initial Android build configuration.

- feat: implement topic detail page with dynamic post loading, scrolling, and user activity tracking.

- feat: Implement core Discourse API service and topic detail page, including authentication, network handling, and screen tracking.

- feat: initialize Android build configuration and Flutter app entry point with service setup, theming, and localization.


## v0.1.2


- feat: implement topic creation flow with floating action button, navigation, and list refresh.

- feat: implement topic detail page with bi-directional post loading and new reply updates.

- feat: Add GitHub Actions workflow for automated Android build, release, and changelog generation, including supporting scripts.


## v0.1.1


- feat: Implement comprehensive CI/CD pipeline for Android builds, including Rust DOH proxy compilation, artifact generation, changelog, and release automation.


## v0.1.0

- mvp

## v0.2.0


- 🐛 修复一些问题

## v0.2.0-beta.3

- ✨ 支持对话框模糊背景

## v0.2.0-beta.2

- 🐛 修复 IOS 编译问题

## v0.2.0-beta.1

- ✨ 长表格渲染优化，close #170

- ✨ 功能优化

- ✨ AI 助手可开启滑动显示模式

- ✨ 统计卡片自定义

- 🐛 修复 macOS 14 版本判断错误 (#176)

- ✨ 功能优化，UI 更新

- ✨ 新 Cookie 机制迁移

- ✨ Windows DOH 适配

- ✨ 修改 CookieJar 与 WebView Cookie 的同步方式

- ✨ Cookie 相关代码逻辑优化

## v0.1.57-beta.1

- ✨ CA 证书相关优化

- 🚀 CI 优化

- ✨ IOS DOH 功能支持

- 🐛 修复 macOS 滚轮/触控板滚动导致的吸附跳动 (#173)

- ✨ 优化 macOS 构建以及支持 macOS 的 WebView 代理 (#171)


## v0.1.56

- ✨ 功能优化

## v0.1.56-beta.11

- 🚀 部署优化

- ✨ 优化下载附件文件名获取逻辑

- ✨ AI助手未配置 API Key 时提示

- 🐛 修复含有 emoji 的链接无法点击跳转的问题，fix #163

- ✨ Hcaptcha 无障碍支持，close #166

- ✨ 优化桌面端登录按钮样式

- ✨ 支持滑动关闭 PopupMenu

## v0.1.56-beta.9

- ✨ Flatpak 构建测试

## v0.1.56-beta.4

- 🐛 修复错误的日志记录

- 🐛 修复通知面板骨架屏下移的问题

- ✨ 优化 windows 关闭窗口流程

- ✨ 取消登录失效二次验证，网络设置支持调整速率

## v0.1.56-beta.3

- ✨ 登录流程优化

## v0.1.56-beta.2

- 🐛 CI 修复

## v0.1.56-beta.1

- ✨ 登录失效验证优化

- ✨ Windows exe 安装包支持

- 🐛 尝试修复 windows 上登录完成之后不触发登录成功的问题

- 🐛 修复个人页常用功能区域会溢出的问题

- 🐛 加载新帖逻辑修复

- 🐛 修复 windows 最大化异常问题

- 🐛 通知面板显示修复，fix #160

## flatpak-wpe-layer-gnome48-v1

## flatpak-wpe-layer-gnome48-v2

## v0.1.55

- ✨ 编辑器支持插入模板

- ✨ Windows 兼容优化

- ✨ 个人页布局优化

## v0.1.55-beta.6

- ✨ 请求并发控制优化

## v0.1.55-beta.5

- ✨ 优化 Cookie 同步逻辑

- ✨ 提升内置浏览器体验，添加收藏能力，添加下载管理

- ✨ 桌面端体验优化

- ✨ 优化回复报错提示，close #155

- ✨ 帖子详情和只看顶层实现，close #153

## v0.1.55-beta.3

- ✨ 用户登录失效判断优化

## v0.1.55-beta.2

- ✨ 过盾体验优化

## v0.1.55-beta.1

- ✨ 提高 rhttp 适配器稳定性

- ✨ DOH 网关模式稳定性修复

## v0.1.54

- 🚑️ 修复安卓无法启动

## v0.1.53

- ✨ 支持邮箱链接登录

- ✨ 支持切换字体，ref #152

- ✨ AI 服务可跟随应用网络设置，close #147

- ✨ 图片批量上传策略优化，close #151

- 🐛 CF 验证相关问题修复

- ✨ 更新下载界面优化

- ✨ 国际化支持

## v0.1.53-beta.11

- ✨ RHttp 适配器支持

- ✨ 预览弹框可点击进入分类、标签列表

- 🐛 模糊剧透问题修复，fix #150

## v0.1.53-beta.2

- 🚀 CI 修复

## v0.1.53-beta.1

- ✨ DOH 功能优化

- 🐛 修复创建或编辑话题时切换到预览无法发布的问题，fix #116

- ✨ 话题内头部信息分类、标签支持跳转，close #146

- 🐛 修复 macOS 未声明相册权限导致的闪退，fix #149

## v0.1.52

- 🐛 修复附件无法下载，fix #141

- ✨ 表情面板功能优化

## v0.1.52-beta.1

- 🐛 修复了一些问题

## v0.1.51

- ✨ 表情包支持，感谢 @stevessr

- ✨ 提升网络请求稳定性

- ✨ VPN 自动切换，close #115

- ✨ DOH 支持复制地址、编辑，close #138，close #100

- ✨ 更新 doh_proxy

- ✨ FAB 子按钮支持

- ✨ improve upstream proxy support on android (#125)

- ✨ 帖子内容优化

- ✨ 用户封禁显示，close #139

- ✨ 支持图标切换

- ✨ 图片批量上传，close #130

- ✨ 图片查看器手势优化

- ✨ MacOS 图标优化

## v0.1.50

- 🐛 修复部分图片资源无法加载

## v0.1.49

- ✨ 图片链接提取优化

- ✨ AI 助手界面优化，close #136

- ✨ 帖子通知显示支持

- 📝 README 更新

## v0.1.48

- 🚀 CI 修复

- 🚀 MacOS 构建支持

- ✨ 请求策略优化

- 🐛 修复一些场景图片加载失效的问题

- ✨ 数据管理功能，refs #115

- 🚀 Altstore 支持，close #135

- ✨ 优化书签列表显示效果

## v0.1.47

- 🐛 解决部分帖子无法点击查看大图的问题，fix #134

- ✨ 优化书签卡片展示，refs #133

- ✨ AI 助手导出图片功能，close #132

- ✨ 优化回应弹框显示效果

- ✨ 稍后阅读浮窗数量角标显示优化

- ✨ AI 助手优化，close #132

- ✨ 优化部分场景动画效果

- ✨ 浮窗位置计算优化

## v0.1.46

- ✨ 支持开关滚动收起导航栏

- ✨ 启动页优化，防止一些极端场景卡启动页

- 🐛 修复邀请链接显示与限频提示 (#129)

- * Fix invite link visibility and pending fetch

- * 邀请链接缓存与提示优化

- * 邀请错误提示与空态优化

- ---------

- Co-authored-by: N1nEmAn <S3vn@S3vn.localdomain>

## v0.1.46-beta.2

- ✨ 稍后阅读功能，refs #115

- ✨ 书签功能优化，refs #115

- ✨ SVG 渲染优化，close #126

- ✨ 优化过盾逻辑

- ✨ 异形屏横屏适配，close #110

## v0.1.46-beta.1

- ✨ Token 变更日志

- ✨ 更详情的退出日志

## v0.1.45

- 🚑️ 修复 CF 过盾异常

## v0.1.44

- 🐛 修复话题详情到底还会继续触发加载的问题

- 🚑️ 修复 CF 盾后无法进入页面

## v0.1.43

- ✨ 一些功能优化

- Add invite links and remember AI model selection (#120)

- Co-authored-by: N1nEmAn <S3vn@S3vn.localdomain>

- 🐛 修复了一些问题，ref #116

- ✨ 元宇宙功能优化

- ✨ 网络添加会话代守卫拦截器，提升应用稳定性

- ✨ 过盾体验优化

## v0.1.42

- ✨ 应用日志功能优化

- ✨ 请求相关问题优化

- 🐛 修复游客模式调用错误的 MessageBus 接口的问题

## v0.1.41

- ✨ 日志功能优化

- ✨ 优化请求策略

- 🐛 修复一些问题

- 🐛 修复会通过主域名触发 MessageBus 的问题

- ✨ 优化首页 tab 逻辑，避免同时请求

- ✨ 请求相关优化

- ✨ 网络断开提示

- ✨ 优化 Toast 样式

- 🐛 修复单栏创建话题时没有打开话题详情页面的问题

- ✨ 优化一些场景的请求

## v0.1.40

- ✨ 优化请求策略，避免频繁触发站点风控、掉登录等问题，close #111 #93 #75 #84 #60

- ✨ 新话题/未读完计数展示

- 🐛 修复话题更新提示功能的一些问题

- ✨ 优化通知计数自动归零的问题

## v0.1.39

- ✨ 优化话题更新提示和功能

- ✨ 排序功能支持，close #104 #70

- 🐛 修复热门无法和其他筛选项组合的问题，fix #107

- ✨ 应用样式焕新，取消绝大多数场景的卡片边框，更清爽

- ✨ 轮播图查看支持

- ✨ 文本选择修改为只能选择帖子内容

- ✨ 日志集成设备信息，close #92

- 🐛 修复一些问题

- ✨ 应用日志功能实现

- 📝 更新 README

- 🐛 修复一处不影响使用的报错

- ✨ 首页向上滚动时 FAB 切换为刷新

- ✨ 优化用户信息请求策略，回到前台时不再自动请求

## v0.1.38

- ✨ 长按预览显示主贴，close #98

- ✨ 优化图片上传功能，gif 不允许压缩

- ✨ 优化内置浏览器体验，支持打开应用，close #102

- ✨ 标签选择器逻辑优化，close #103

- ✨ 优化 MessageBus 逻辑，更新为最新域名

- 🔧 追加 google-services.json

- ✨ 支持竖屏锁定

- ✨ 集成 Firebase Crashlytics

- ✨ 优化响应式布局效果

- ✨ 边界场景优化

- ✨ 话题详情性能优化

- ✨ 优化启动速度

- ✨ 优化启动服务执行顺序

- 📝 README 更新

## v0.1.37

- 🚑️ 回退 doh_proxy

## v0.1.36

- ✨ 网络错误场景优化

- ✨ 更新 doh_proxy

- ✨ 优化一些边界场景的逻辑

- ✨ 登录自动填充支持，close #94

- ✨ 优化应用基础功能体验

- ✨ 登录失效时弹框提示

- 🐛 修复首页不松手也会触发吸附显隐的问题

## v0.1.35

- ✨ 折叠帖子的显示，以及用户订阅功能实现

- 🐛 修复首次打开更多菜单时打赏选项不显示的问题

- ✨ 混排优化功能优化，解决一些破坏 md 格式的问题

- ⚡️ 长贴性能优化

- 🐛 修复模糊剧透无法揭示的问题

- ✨ 元宇宙多卡片合并显示，close #89

- ✨ AI 摘要渲染优化

## v0.1.34

- ⚡️ 部分场景性能优化

- ✨ AI 助手交互优化，close #83

- ✨ 图片缓存优化

- ✨ 帖子内容渲染优化

- ✨ 发帖审核提示，close #86

- ✨ 实现打赏功能

- 🐛 修复 IOS 的一些异常情况

- ✨ 优化元宇宙相关功能显示逻辑

- 🐛 修复贴内话题链接跳转异常问题

- ✨ 图片支持长按打开菜单

- ✨ DOH 逻辑优化

- ✨ 模糊剧透的图片揭示之后可以点击查看大图

- ✨ 支持输入楼层跳转，close #80

- Create LICENSE

- ✨ 离开 AI 页面时取消输入框焦点，防止返回时键盘意外弹出

## v0.1.33

- ✨ 功能优化

## v0.1.33-beta.2

- ✨ 优化应用稳定性

- ✨ 引用回复功能实现

- ✨ 优化浏览分类弹框 UI

- ✨ 通知功能改版

- ✨ 优化图片查看页面左右滑动

- ✨ 图片查看器手势优化

- ✨ DOH 日志完善

- 🐛 修复 AI 助手输入框聚焦时，帖子列表页面会弹出键盘的问题

- 🐛 修复登录失效问题

## v0.1.32

- ✨ 优化 Cookie 读取逻辑

## v0.1.31

- 🐛 修复 IOS 保存图片闪退的问题，fix #73

- ✨ 优化 AI 助手界面 UI，close #74

- 🐛 修复一些问题

- 🐛 修复某些场景代码块显示异常

- ✨ 优化后台通知逻辑

- ✨ 通知卡片显示优化

- ✨ 优化 MessageBus 代码逻辑

- ✨ 优化 messageBus 429 重试逻辑

- ✨ 时间显示优化

- ✨ 通知列表分页支持

## v0.1.30

- 🐛 Cookie 问题修复

## v0.1.29

- 🐛 修复 ci 异常

- 🐛 修复 ios ci 编译异常

- 🐛 修复一些问题

- ✨ 编辑器图片上传前置

- 🐛 修复 IOS 后台异常导致的重启

- ✨ AI 助手集成

- ✨ Cookie 同步逻辑优化

- ✨ 元宇宙接入 CDK，close #59

- ⚡️ 优化内存占用

- ✨ 修复 callout 嵌套异常，fix #69

- 🐛 修复底栏分享图标和其他图标颜色不一致的问题，fix #68

- 更新 CHANGELOG.md

## v0.1.28

- ✨ 优化图片显示

- ✨ 优化图片查看体验

- 🐛 修复模糊剧透显示到未展开 details 的问题，fix #66

- ✨ 图片查看页面显示图片名，close #65

- ✨ 退出二次确认，close #54

- 🐛 修复内置代理，webview 不被代理的问题，fix #62

- ✨ 解决楼层数滚不到底的问题

- ✨ 优化小白条沉浸效果

## v0.1.27

- 🐛 修复表情选择器打开时，点击编辑器状态未切换的问题

- ✨ 添加未浏览筛选项，close #61

- ✨ 优化版主操作样式

- ⚡️ 缓存查询性能优化

## v0.1.26

- ✨ 回应支持查看回应人

- ✨ 编辑器功能优化

- 🐛 修复进度指示器可能不准确的问题

## v0.1.25

- ✨ 长按预览支持更多页面，并支持快捷分享

- 🐛 尝试修复自动混排和输入法自动括号冲突问题

- ✨ 编辑器支持插入模糊剧透

- 🐛 修复话题阅读数量不被统计的问题

- 🐛 修复首贴不会被销毁的问题

- ✨ 搜索结果包含 AI 结果，close #52

- ✨ 话题列表排序持久化，close #57

- 🐛 尝试修复横屏切换竖屏，布局不更新的问题，fix #48

- 🐛 修复 IOS、MACOS 上的一些问题

- 🐛 修复 ios 无法使用谷歌登录的问题，fix #56

- ✨ 编辑器体验优化

- ✨ 添加书签支持话题添加书签，close #50

- ✨ 话题卡片更紧凑，并更新预览弹框显示更多信息，close #58

- 🐛 修复小白条沉浸问题，Fixes #55

- 🐛 修复回复成功之后会回弹的问题

- ✨ 优化全局提示效果

- 🐛 修复我的页面的部分状态表情不显示的问题

- 🐛 修复进入话题详情必须滑动才能触发阅读记录的问题

- ✨ 后台通知优化

## v0.1.24

- ✨ 优化体验

## v0.1.23

- 🐛 修复首页卡死

- ✨ 搜索功能优化

- ✨ 用户资料页面优化，fix #44

- ✨ 新、未读排序下可以一键已读，close #42

- ✨ 优化体验

- ♻️ 重构图片粘贴实现

- 🐛 修复一些问题

- ✨ 首页焕新，全新的过滤交互，ref #43

- ✨ 优化视频播放体验

## v0.1.22

- ✨ 搜索功能优化

- ✨ 用户资料页面优化，fix #44

- ✨ 新、未读排序下可以一键已读，close #42

- ✨ 优化体验

- ♻️ 重构图片粘贴实现

- 🐛 修复一些问题

- ✨ 首页焕新，全新的过滤交互，ref #43

- ✨ 优化视频播放体验

## v0.1.21

- 🐛 修复表情选择器无法切换 tab

- 🐛 修复了一些问题

- ✨ 表情面板键盘切换效果优化

- ✨ Connect UI 同步

- ✨ 编辑体验优化，支持粘贴图片，refs #42

- ✨ 链接确认打开弹框

- ✨ 话题预览弹框样式优化

- 🐛 修复进度指示器部分场景不更新的问题

- ✨ 生成图片分享功能优化

## v0.1.20

## v0.1.19

- ✨ 一些功能优化

- ✨ 长贴性能优化

- ✨ 新 connect 兼容

- ✨ 扫描性能优化

- 🐛 修复分块渲染时没显示链接点击数

- ✨ Code 表格内样式优化

- ✨ 话题详情 Bar Actions 优化

- ✨ 优化首页顶栏底栏隐藏逻辑，close #39

- 🐛 修复搜索分页无效的问题

- ✨ 话题内搜索

- ✨ 我的书签、我的话题、浏览历史实现搜索功能

- ✨ 优化扫描类背景的稳定性

- 🐛 修复 onebox 链接没有走通用链接跳转逻辑，fix #40

## v0.1.18

- 🐛 转义 Telegram Markdown 特殊字符"

## v0.1.17

- ✨  分享支持生成分享图片、导出文章功能，close #38

- 🐛 修复图片高度显示异常

- 🐛 修复某些场景提交完成之后不会正确删除草稿

- ♻️ 重构 post_item

- ✨ 帖子卡片显示更多的用户信息，close #37

- 🐛 修复 image grid 画廊被隔离的问题

- ✨ Code 标签样式优化

- 🐛 修复引导页登录之后进入页面卡 loading 的问题

## v0.1.16

- ✨ 内联元素样式优化

- 🐛 修复话题详情浅色模式骨架屏显示问题

- ✨ 模糊剧透效果优化

- ✨ 提升 iframe 浏览体验

- ✨ DeepLink 逻辑优化

- ✨ 支持图片网络显示/编辑

- ✨ 有序/无序列表显示优化

- ✨ 搜索记录排序记忆，Refs #31

- ✨ 优化提及、内嵌代码块显示样式

- ✨ Iframe 兼容性适配

- ✨ 草稿功能体验优化

## v0.1.15

- ✨ 响应式布局优化

- ✨ 手动代理，close #19

- ✨ 安卓动态图标实现，close #33

- ✨ 草稿功能，close #36

- ✨ 内容字体大小调节，close #35

- ✨ 优化 iframe 实现，close #34

- ⚡️ 提升话题详情页滑动流畅性

- ♻️ 重构话题详情代码

- 🐛 修复回应列表不能加载更多

- 🐛 修复部分场景话题详情无法向下加载

## v0.1.14

- 🐛 修复无法话题浏览器打开功能失效

- 🐛 修复回应列表不能加载更多

## v0.1.13

- ✨ 内嵌网页版编辑个人信息，close #27

- ✨ 页面错误提示优化

- 🐛 修复话题详情页面异常场景循环构建的问题

- ✨ 支持应用链接，close #26

- ✨ 头像显示优化

- ✨ 链接点击数优化

- ✨ X 卡片样式优化

- ✨ 话题筛选功能优化，close #29

- ♻️ 分页加载统一管理，fix #27

- ♻️ 通知列表标题优先展示纯文本，fix #30

- 🐛 修复部分场景跳转白屏问题

## v0.1.12

- ✨ 应用内更新，close #25

- ✨ 标签样式更新

- ✨ 通知列表 emoji 显示

- ✨ 偏好设置提供外部链接使用内置浏览器开关

- ✨ 页面 loading 统一使用骨架屏

- ♻️ DiscourseService 重构

- ♻️ 代码警告消除

- ⚡️ 提升滑动流畅度

## v0.1.11

- chore: CI 修复

- ✨ Callout 显示优化

- ✨ 话题头部排版优化

- ✨ 首页底栏顶栏显示隐藏优化

- ✨ 相关链接显示

- 🐛 修复投票不显示查看结果按钮，fix #13

- ✨ 恢复完整的 pangu，提供降标安全保护，close #18

- ✨ 切图体验优化

- ✨ 搜索记录显示，错误消息处理，fix 23，close #24

- 🐛 Tag 兼容补充

- ✨ 排版优化简化

- ✨ 构建 ipa

## v0.1.10

- 🚑️ 兼容新的 api 结构，解决无法显示话题详情的问题（fix #20）

- ✨ 图片查看器图片过渡显示优化

- 🐛 修复话题详情嵌套视图滚动会显示隐藏底栏的问题

- ✨ 底栏滑动自动隐藏

- ✨ 骨架屏显示优化

- ✨ 长按预览功能

## v0.1.9

- 🐛 话题详情页面 bar 背景颜色切换错误修复

- ✨ 匿名分享功能实现，(close #15)

- ✨ 话题编辑功能，(close #17)

- ✨ 支持混排优化，(close #16)

- ✨ 修改回复主贴为等同回复话题，(close #14)

- ✨ 支持删除线编辑，(close #10)

- ✨ 时间解析优化，(fix #10)

- 📝 添加项目提示词

- 🐛 修复 LDC 余额显示错误，(fix #12)

- ✨ 兼容聊天记录引用卡片

- ✨ 登录登出体验优化

- 📦️ 依赖更新

- ✨ 采用更真实的设备 ua

- ✨ 图片查看优化

- ✨ 公式内容显示支持

- ✨ 图片上传体验优化，(close #8)

- ✨ 帖子删除功能，(close #6)

- 🐛 修复相对路径图片不加载的问题，(fix #3)

- ✨ 快问快答话题兼容

- ✨ 优化图片查看页面状态栏显示

- ✨ 优化过盾流程，仅不影响操作的放到后台过盾，并在网络设置中支持手动过盾

## v0.1.8

- ✨ 添加 CIRA Canadian Shield 为内置 DOH 服务，（close #5）

- 🚑️ CF 过盾体验优化，解决启动时遇到盾会无法启动的问题

- ✨ 热门回复/只看题主体验优化

- ✨ 大屏显示优化

## v0.1.7

- ✨ UA 修改静态值，修复无法使用谷歌登录

- ⚡️ CF 过盾优化与日志导出

- ⚡️ 优化大屏使用体验

- ✨ 代码块显示优化

- 🐛 修复发送提示不会自动消失，(fixes #2)

- ✨ 只看题主功能实现

- 🐛 跳转问题修复

- 🐛 Mac 构建修复

## v0.1.6

- ✨ 大图查看支持隐藏功能按钮、状态栏

- ✨ 贴内图片支持分享

- 🐛 修复分享完成后不能回到当前应用的问题

- ✨ 优化大图查看体验

- ✨ 用户资料页面头像支持大图查看

- ✨ 优化提及块样式

- ✨ 热门回复功能

- ✨ 显示题主[主]，本人[我]的标识

- 🐛 Onebox 显示优化

## v0.1.5

- ✨ 新的代码高亮实现

- ✨ Bar 点击标题展开 header

- ✨ 追踪链接点击

- ✨ OneBox 更多类型展示

- ✨ 话题订阅功能

## v0.1.4

- 🐛 修复话题投票时会直接刷新整个详情的问题

- 🐛 修复回到顶部概率触发刷新

- ✨ 支持帖子编辑功能和编辑时支持提及（@触发）

## v0.1.3

- feat: add PreloadedDataService for efficient initial data loading and configure Android build with ABI filtering.

- feat: implement topic detail page with scroll management, post display, and visibility tracking.

- feat: Add Discourse HTML content rendering with custom builders for various elements, including quote cards.

- feat: Implement Discourse poll rendering and voting, and configure Android build with signing and desugaring.

- feat: add user profile page with login/logout, user settings, and initial Android build configuration.

- feat: implement topic detail page with dynamic post loading, scrolling, and user activity tracking.

- feat: Implement core Discourse API service and topic detail page, including authentication, network handling, and screen tracking.

- feat: initialize Android build configuration and Flutter app entry point with service setup, theming, and localization.

## v0.1.2

- feat: implement topic creation flow with floating action button, navigation, and list refresh.

- feat: implement topic detail page with bi-directional post loading and new reply updates.

- feat: Add GitHub Actions workflow for automated Android build, release, and changelog generation, including supporting scripts.

## v0.1.1

- chore: bump version to 0.1.1

- Co-Authored-By: Release Script <noreply@github.com>

- feat: Implement comprehensive CI/CD pipeline for Android builds, including Rust DOH proxy compilation, artifact generation, changelog, and release automation.

## v0.1.0

- mvp

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
