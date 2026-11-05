# 官方图片管线复核：速度与资源占用

2026-11-05 第二轮，覆盖上一版中尚未确认的行为。只读检查 LINUX DO iOS 1.0.4 (build 9) 与当前 FluxDO 工作区。未修改应用包、代码或系统配置，未读取钥匙串内容、账号数据，未启动应用，也未做手机性能实测。

## 结论更新

1. 已确认官方图片共享任务会在等待者清空后取消任务，不再只是根据 Flight/waiters 名字推测。
2. 已确认图片解码路径调用 RenderConcurrencyLimiter，初始化配额 max(1, activeProcessorCount - 1)，并存在解码前/中的取消检查。并非所有格式分支都必然经过同一个限流分支。
3. 已确认图片按域名分流：linux.do 及子域名进入自定义网络服务路径；普通 cdn.ldstatic.com 等非 linux.do 图片进入 SystemURLSessionTransport。上一版不能据 curl 的 6 连接/H3 配置推断 CDN 图片表现。
4. 已确认系统资源会话配置共享 URLCache；图片处理代码没有找到 FluxDO 那种显式 await 图片文件 flush 后才返回字节的链路。URLSession/URLCache 内部的磁盘写入时序仍不能从应用二进制证明。
5. 已确认 curl 的 TLS session load/save 回调已接到 KeychainStore 的 tls_sessions 读写，并非只有库里未使用的接口。这里只看调用代码，没有读取钥匙串。
6. 发现不宜照搬的配置：资源 URLCache.diskCapacity 设置为 Int64.max。这是配置值，不代表系统会实际分配该容量，也不代表其他平台相同。FluxDO 应保留明确的磁盘预算。

## 样本与方法

包：/Applications/LINUX DO 2.app/Wrapper/LINUX DO.app。
主程序 SHA256：b68f916172e491437d0c6878b248c6e887020ea9cde3b65c80136fa3c0a76bc7。
CommunityFoundation SHA256：5a46919637998efb5caf3cf08cc44aa8658db44dcf22d2589f4594b8258f2bfb。

原生 Swift/iOS arm64 包，经 macOS 包装运行。本轮没有官方 Android APK，结论只针对这个包。

除了 strings/nm，本轮解析了 Mach-O 的段、函数起点、Swift 类型描述与字段信息、Objective-C selector stubs，并跟踪 ARM64 条件分支和具体调用。部分内部函数已去符号，Swift async 拆成多个 continuation，未声称恢复了完整源代码。下列地址均为未加运行时 slide 的地址；CommunityFoundation 地址相对该 Mach-O。

Swift 元数据布局参考原项目定义：https://raw.githubusercontent.com/swiftlang/swift/main/include/swift/ABI/Metadata.h 。

## 已确认行为与证据

### A. 最后一个等待者退出后取消共享任务

ImageResourceLoads 的类字段为 cache、groups；其 Flight 类字段为 id、task、waiters。通过 otool 的 ivar 信息定位：waiters 偏移变量 0x102df1060，task 偏移变量 0x102df1058。

主程序函数 0x100098d88：
- 0x100098f60–0x100098f90 取 Flight.waiters，调用集合移除逻辑。
- 0x100098ff8–0x100099004 取移除后的集合计数；非零则跳过取消。
- 0x100099008–0x100099040 在计数归零时读取 Flight.task，调用 Swift.Task.cancel。
- 后续移除 flight 并恢复当前等待者 continuation。

RemoteImageLoader 的 0x101efae30 同样读取其 task，0x101efaeb4 调用 cancel，清空 task 并递增 generation。另在 0x101efb1c8 的释放相关路径看到 task.cancel。

因此“共享任务按消费者管理、无人等待后发出取消”有实际分支证据。尚未证明所有视图每次离屏都调用同一清理入口，也未用抓包测量取消后实际少传多少字节。

### B. 解码限流与取消

RenderConcurrencyLimiter 的类型描述位于 0x102773754，accessor=0x1021ed500，反射字段 limit、availablePermits、waiterOrder、waiters。

0x10008d400 初始化图片解码使用的 limiter：
- 0x10008d428 调用 NSProcessInfo.activeProcessorCount。
- 减 1，并通过比较选择最小值 1。
- 0x10008d474 将值写入 limit 与 availablePermits，保存到全局 0x102df0ec0。

DecodedImageCache 准备路径 0x10008b850 读取此 limiter；解码函数 0x10008d4c8 在格式判断命中后进入 limiter 异步方法 0x1021ec72c。后续明确调用 Task.isCancelled、AnimatedImageDecoder.resource、CGImageSource.downsampled、ImageThumbnailDecoder.resource。

确定存在 CPU 相关的有界重解码与取消；没有将 CPU 核数减一解释成所有图片下载或所有静态图解码的统一并发数。也不能从此推断该值对 Android 最优。

### C. 图片 CDN 的实际分流

CommunityFoundation.LinuxDoHostPolicy.usesCustomTransport 位于 0x62854，构造 linux.do 字符串后调用 0x671d8。后者读取并规范化 URL host，检查域名相等或带点的子域后缀。

主程序 ImageResourceLoader+App 相关分支 0x10009ccf0：
- 0x10009cd18 调用 usesCustomTransport。
- 命中进入自定义网络服务的 task-local 路径。
- 非命中进入 0x10009cd54，使用系统传输对象；0x10009ce48 后按 resourceCachePolicy 是否存在选择普通 session 或 resourceSession。

SystemURLSessionTransport 的字段 userAgent、session、resourceSession 与这条分支的对象偏移一致；其实际请求实现 0x100178424 调用 URLSession.data(for:) / download(for:)。

因此普通 cdn.ldstatic.com 初始图片请求走系统 URLSession 分支。重定向后的每一跳、运行中配置与最终实际 HTTP 协议仍需运行时观测。系统传输仍可能受到系统 DNS/网络策略影响，不能把这个结论扩展成“关闭一切加密 DNS”。

HostRoutingHTTPTransport 还对预签名上传、MessageBus 等有特殊分支；这不改变普通 CDN 图片入口的上述判断。

上一版 curl 每主机 6 连接、Alt-Svc H1/H2/H3 的反汇编结果仍成立，但只应作为 curl 路径配置，不能直接当作 CDN 图片的速度优势。不能为了模仿它而让 FluxDO 在用户要求 DoH 时悄悄改走系统 DNS。

### D. 资源缓存及落盘

0x10017a750 的 Objective-C selector 已逐个解码：
- defaultSessionConfiguration。
- sharedURLCache，随后 0x10017a79c 设置参数 0x7fffffffffffffff，0x10017a7a0 调用 setDiskCapacity:。
- setURLCache: 使用共享缓存，setRequestCachePolicy: 参数 0。
- CookieStorage、HTTPShouldSetCookies、URLCredentialStorage 关闭或设空。

0x10017a810 先创建带缓存的 resourceSession（对象 +0x28），然后清空配置中的 URLCache，再创建普通 session（+0x20）。调用点 0x10017694c/0x1001769a0、0x1001fdb68/0x1001fdbb0 确认该配置和构造函数有实际使用。

ImageResourceLoader/DecodedImageCache 主路径能追到内存缓存、整段 Data 返回、解码；没有找到应用自行调用图片文件 write/flush 的对应步骤。准确结论是“已追踪路径没有我们这样的显式写盘等待”，不是“系统绝不先写盘”。系统框架的实现不在此包中。

### E. TLS session 持久化已接入

主程序 0x10015479c 调用 CurlMultiActor 初始化，将 0x1001549dc、0x1001549e4 作为 load/save 回调传入。
- load → 0x10022e194 → 0x10022e1d4；0x10022e258 调用 KeychainStore.read，键是 tls_sessions。
- save → 0x10022e1b4 → 0x10022e4f8；0x10022e5d8 调用 KeychainStore.write，空值分支调用 delete。

这确认了主程序的持久化接线，不等于每次重启后都成功恢复 TLS；服务端是否接受票据仍需实测。且普通 CDN 图片走系统传输，不能把 curl 的票据持久化收益直接算到这些图片上。

## 对 FluxDO 的资源约束

当前源码已确认：
- content 全局 6 个任务，small 12，sticker 3；Rust H2 多路复用与 H1 每主机 6 条连接另行存在。
- LazyImage.dispose 只降低排队优先级，在途请求不取消。
- BlobImageCache._download 需 await write；write 使用 flush:true，返回后 ImageProvider 才解码。
- Flutter ImageCache 配置 256 MiB；大图磁盘缓存按 bucket 限量；ImagePaintGate 每帧放行一个新的首次绘制。
- 当前 image_download_timing 不覆盖写盘、解码、首次绘制。

后续实现应同时满足以下约束，而不是单独提高并发：

| 优化 | 必须同时保留的资源约束 |
| --- | --- |
| 可见图优先调度 | 初期保留现有总任务上限，通过公平排队/保留前台机会改进；不随域名数量无限扩容 |
| 离屏取消 | 同 URL 消费者计数，剩余消费者不受影响；考虑短暂宽限及接近完成任务，避免反复重下浪费流量 |
| 解码不等落盘 | 写入队列同时限制任务数和待写字节；保留原子文件写入、失败处理以及 getFile 返回时文件可用的契约 |
| 解码调度 | 网络/写盘/解码分别控制；保留尺寸限制、动图策略及首绘分帧，避免网络快后同时解码产生内存/CPU 峰值 |
| 缓存 | 保留可量化的内存与磁盘预算，不复制官方 Int64.max 磁盘配置 |
| 验证 | 同时测首帧 p50/p95、队列等待、峰值内存、在途字节/任务、解码耗时、滚动帧耗时与重复下载量 |

验收场景需覆盖正常可达/受限网络、冷/热缓存、连续快滚、滚回重复查看、多视图同 URL、大图与动图混合。没有设备测量前不承诺总体内存绝不增加或官方一定更快。

## 经过追踪仍不能从此包确认的事项

- 官方 Android 实现：本次样本是 iOS 包，不能替代 Android APK。
- CDN 实际协商 H2/H3、DNS/IP、首字节与吞吐：二进制只给选择逻辑，不包含本次请求结果。
- URLCache 内部写盘时序：已追到系统 API，系统框架内部不在本应用包。
- 所有视图的离屏取消覆盖率：已确认 loader 与共享任务取消机制，完整 SwiftUI 生命周期路径未全部还原。
- 官方解码内存的完整容量/淘汰策略、各页面 srcset 选档：尚未得到足以报告准确数值/规则的完整调用链。
- 以上策略的实测内存、电量和速度收益：需要设备数据，不能由静态实现推算。

本轮补查已显著收窄不确定性；没有改代码、没有新 APK。

## 可复查材料

- /tmp/linuxdo-image-confirmed-evidence.txt：关键指令及 Objective-C selector 注释。
- /tmp/linuxdo-flight-cancel-asm.txt：共享任务取消函数。
- /tmp/linuxdo-decode-prepare-asm.txt、/tmp/linuxdo-decode-body-asm.txt：解码准备与执行分支。
- /tmp/linuxdo-image-request-asm.txt、/tmp/linuxdo-system-request-asm.txt：图片请求与系统传输。
- /tmp/linuxdo-main-objc.txt、/tmp/linuxdo-main-asm.txt：完整类信息与主程序指令。
- /tmp/linuxdo-community-symbols.txt、/tmp/linuxdo-community-asm.txt：framework 符号与指令。
- /tmp/linuxdo_macho.py、/tmp/linuxdo_trace.py、/tmp/linuxdo_objc_calls.py：只读解析脚本。
