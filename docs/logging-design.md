# 日志整理（2026-11-05）

本批修改公共日志与请求关联，未改变业务网络策略。旧 APK 不含本批改动。

- 统一写入 schemaVersion=2、sessionId、seq、event；保持原 type/tag 字段兼容日志页面。
- 接口完成摘要携带 traceId、attemptId、coreRequestId。Rust 请求任务使用 tracing span，宿主桥保留 coreRequestId；按 sessionId + coreRequestId 对齐两端。图片耗时记录共享 traceId。异步独立 DNS/H3 探测任务并非全部继承请求 span，不把它们冒充某次请求独占耗时。
- 无关联的完全相同记录在一次批量写入窗口内合并，首次保留，repeat_summary 记录省略数及首末时间。不同请求与 error 不合并。
- 单条通常最大 16KiB，字符串截断 4096 字符，嵌套最多 6 层/每容器 64 项；超限保留关联和错误摘要。写入缓冲最多 500 条/512KiB，溢出计数以 log_overflow 写出；继续使用现有双代轮换与两秒批量写入。
- 公共落盘与导出统一过滤敏感键、Bearer 值、URL 用户信息/参数/片段。自由文本识别为尽力过滤，不保证未知格式的秘密自动识别；调用处仍应只记录允许字段。
- 默认导出本次启动，附诊断统计；getShareFilePath(fullHistory: true) 可导出保留历史，当前页面尚无历史范围选择器。原日志未因导出而删除。
- NetworkLogger 只在 debug 构建打印控制台；release 继续统一落盘，避免重复输出。

本批未实现专项诊断开关/自动截止、故障前环形追踪缓冲、跨所有重试层的操作级 span 或新的日志页面。这些不是现有功能，不能据本次改动宣称全部日志改造完成。

验证：日志/请求标签/图片管线 19 项测试通过；Rust 全量 66 项通过；相关 Dart 文件静态检查通过；git diff --check 通过。改动保留工作区，未提交、未推送，本轮未重建 APK。

后续补充：原生连接 ID 已接入 H1/H2/H3、FFI 与请求/图片连接元数据；复用保持 ID 不变，跨启动结合 sessionId。
