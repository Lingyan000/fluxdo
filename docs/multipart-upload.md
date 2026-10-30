# 配置驱动的分片上传

本地「网络设置 → 文件上传 → 强制关闭分片上传」默认为关闭；开启后统一使用普通上传，跳过站点能力查询，对下一次上传生效，不中断在途请求。设置持久化键为 `pref_force_disable_multipart_upload`。

未强制关闭时，`uploadFile` 等待预加载站点配置。仅 `enable_direct_s3_uploads == true` 使用 S3 分片；缺失或 false 继续 `/uploads.json`。配置加载异常不静默改换路径。

## 协议

对齐 Discourse `frontend/discourse/app/lib/uppy/s3-multipart.js` 和 `lib/external_upload_helpers.rb`：

1. `POST /uploads/create-multipart.json`：文件名、长度、`upload_type=composer`。
2. `POST /uploads/batch-presign-multipart-parts.json`：unique_identifier、每批最多五个 part_numbers。
3. 独立 Dio PUT 签名 URL：逐片读文件，保留响应 ETag。
4. `POST /uploads/complete-multipart.json`：unique_identifier、part_number/etag 列表，返回常规 Upload 对象。
5. 失败尝试 `abort-multipart.json`，不自动回退普通上传。

5 MiB 分片；文件达到 100/500 MiB 时分别采用 10/20 MiB。顺序上传，每片最多三次尝试，仅重试网络异常、超时、429、5xx。控制请求禁用自动恢复与重定向；签名 PUT 使用独立客户端，不安装站点凭据拦截器，仅接受 HTTPS、无 URL 用户凭据、无 fragment，禁止重定向。

分片发送和响应预算各两分钟；合并响应预算两分钟。合并不是异步完成查询，超时仍可能结果不确定，因此不自动重试。失败清理等待最多五秒；异常信息保留原始原因。

## 验证与边界

`flutter test --no-pub test/services/uploads/s3_multipart_upload_test.dart`

测试覆盖官方分片尺寸、跨分片字节完整性、控制接口、ETag、凭据隔离、失败清理。尚未验证问题华为设备或真实站点上传；直传能绕过上传请求体进入 WebView 的开销，但不能保证解决对象存储网络或服务端图片处理超时。未增加图片压缩、断点续传或 UI 进度功能。
