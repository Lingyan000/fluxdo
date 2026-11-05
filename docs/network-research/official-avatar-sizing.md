# 官方头像尺寸与重定向复核

2026-11-05，只读检查 `/Applications/LINUX DO 2.app/Wrapper/LINUX DO.app/LINUX DO`。SHA256 再次核对为 `b68f916172e491437d0c6878b248c6e887020ea9cde3b65c80136fa3c0a76bc7`，与前次 iOS 1.0.4 build 9 样本相同。本次没有运行官方应用、访问账号数据或修改 FluxDO 业务代码。

## 新确认的行为

官方存在按离散规格生成头像 URL 的路径，不能简单说它任意填写像素数后依靠 HTTP 重定向修正。

- 主程序只读表 `0x10269cfa8`：六个 Int64 为 `24, 48, 72, 96, 144, 288`。
- 比较表 `0x10269cf78`：六个 Double 为相同数值；索引表 `0x102e58320` 的字节为 `00 01 02 03 04 05`。
- `NotificationActivityListView.swift` 相关路径 `0x100cbfc60` 将输入尺寸乘 3；随后逐档比较，选择首个不小于目标的档位，超过最大值用最后一档。`0x100cbfcfc` 构造 Swift 小字符串 `{size}`，`0x100cbfd18` 读取所选整数规格，`0x100cbfd3c` 转成字符串，`0x100cbfd80` 调用 replacingOccurrences 完成模板替换。
- `TopicInspectorView.swift` 路径 `0x101c70c40` 起也遍历相同档位索引，然后替换 `{size}`。另有 `TopicVotingHeader.swift` 路径 `0x101d000e4` 明确使用 288。
- CommunityFoundation 的 PushAvatarURLPolicy 路径 `0x7011c` 构造 `{size}`，`0x70130` 构造字符串 `96` 并执行替换；只适用于这一通知头像分支。

这些证据确认了档位表和实际 URL 构造调用，不只是找到常量。不能推广为所有页面都乘 3、所有头像都用 96，或官方所有请求都没有 302。

## 与日志 13 的对应关系

FluxDO 日志明确出现 `/128/ → 302 → /144/`，以及其他非档位尺寸请求。官方已确认路径在 URL 生成前选档，因而可以避免这一类“请求非标准尺寸后由服务器纠正”的额外往返。官方在同手机/同网络上的实际跳转率、速度和缓存命中率尚未实测。

普通 CDN 图片走 SystemURLSessionTransport 和共享 URLCache、共享加载任务有取消机制的证据见 official-ios-image-pipeline.md。没有证据证明 URLCache 一定消除本例 302，也不能把 curl/H3 配置当成普通 CDN 的实际协议。

建议借鉴的是统一头像规格选择：基于显示尺寸与像素密度选择合适档位，限制最大尺寸，集中替换模板，并以真实响应确认无跳转。先核对站点支持规格，再覆盖 topic/search/user 等入口；不要全局放大为 288，不提高下载并发，也不照搬 iOS 特定路径的倍率。

证据来源：`/tmp/linuxdo-main-asm.txt`、`/tmp/linuxdo-community-asm.txt` 以及用 `/tmp/linuxdo_macho.py` 对当前主程序表数据的读取。这里只确认本地 iOS 包，未取得官方 Android 实现证据。

## Discourse 源码交叉核对

2026-11-05 读取 `/Users/pengyongteng1/f/discourse`，HEAD `b3b561e5fad`。仅检查源码与已有测试，未运行服务或测试，未修改此仓库。

- `config/site_settings.yml:2393`：avatar_sizes 默认 `24|48|72|96|144|288`，client=true，站点可配置。因此官方包中的六档是默认值，不能作为所有站点的唯一标准。
- `frontend/discourse/app/lib/avatar-utils.js:28`：网页端将 DPR 分为 1/2/3 倍（大于 1.1 且小于 2.1 用 2，至少 2.1 用 3），再乘显示尺寸；`getRawAvatarSize` 读取并排序站点 avatar_sizes，选择首个不小于目标的档位，超过最大则封顶。
- `frontend/discourse/tests/unit/lib/avatar-utils-test.js:13` 明确有 `getRawAvatarSize avoids redirects` 测试，覆盖向上选档与最大值限制。
- `app/controllers/user_avatars_controller.rb:113`：非标准尺寸且使用外部存储时，按绝对差取最近档并重定向。这与网页端“向上选档保清晰度”不同，不应混用。`spec/requests/user_avatars_controller_spec.rb` 有自定义档位 `100|98|49`、请求 97 跳 98 的例子。
- 同控制器还有旧头像版本转向新上传、外部存储跳转等路径，所以修正尺寸只能消除尺寸原因的跳转，不能保证所有 302 消失。

FluxDO 接入点：`PreloadedDataService.siteSettingsSync` 已提供站点设置，应复用 avatar_sizes，不为每个头像发额外配置请求。topic/search/user 多个模型目前直接替换 size；列表有显式 128、搜索默认 120。通知头像注释声称使用标准档位，但值是 240，不在上游默认档位中，也应一并核对实际站点配置。

推荐实现契约：显示尺寸与请求像素尺寸分开；显示尺寸按受限 DPR 换算一次，已有请求像素不再重复乘 DPR；集中使用站点档位，缺失或非法时才回退默认表。更新站点配置后刷新选档缓存；只处理头像模板，不改写正文图、动图或第三方 URL。保留清晰度、缓存复用与资源上限，不通过放大所有头像或增加并发掩盖重定向。

本次没有读取线上 linux.do 当前 avatar_sizes，不能把本地默认值或官方二进制表宣称为线上实时配置。用户日志证明部分规格跳转，与这里的机制一致。
