# 网络受控验证工具

使用已有 Rust/Python/macOS 工具，不增加应用运行依赖。实验只绑定回环地址，
不配置系统代理/DNS，不安装 CA。默认测试证书、日志、Chrome profile 位于
临时目录；工具输出具体目录。结果不能替代 Android TUN/Bettbox 真机验证。

## 构建

在仓库根目录执行：

```sh
cargo build --manifest-path core/net_core/Cargo.toml --example transport_bench --example tls_backup_probe --example proxy_tls_probe --offline
```

如指定 `CARGO_TARGET_DIR`，下列二进制路径也应相应调整。

## 代理与握手分段

```sh
python3 tool/network_validation/proxy_lab.py \
  --mihomo '/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo' \
  --chrome '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' \
  --probe core/net_core/target/debug/examples/proxy_tls_probe \
  --output /tmp/fluxdo-proxy-results.json
```

工具启动独立 Mihomo，临时 Chrome 仅允许实验服务器证书的 SPKI；核心探针
使用独立信任根。两边均检验测试页面标记；映射缺失且嗅探关闭必须失败，其余
五种条件必须成功。结果不符合预期返回非零。此实验分割 TCP 写入，不改写
TLS record；输出时间包含工具启动开销，不用于跨客户端速度排名。

## 传输与 TLS 备用对照

准备两个 `transport_bench`：在待比较提交中使用相同的示例源码和编译配置，
各自构建后复制到不同文件，不能先后运行指向同一个 target 产物的路径。
基线可以从 `git archive <commit> core/net_core` 解出到临时目录，避免动当前
工作区；依赖、测试证书、平台、编译优化级别应一致。

```sh
python3 tool/network_validation/transport_bench.py \
  --baseline /tmp/baseline-transport \
  --candidate /tmp/candidate-transport \
  --tls-probe core/net_core/target/debug/examples/tls_backup_probe \
  --output /tmp/fluxdo-transport-results.json
```

每版交错执行五轮，每轮 600 个 64 KiB HTTP/1.1 响应、并发 12、服务端延迟
10 ms。macOS `/usr/bin/time -l` 提供进程用户/系统 CPU 时间和峰值 RSS。
TLS 备用对照在同一程序中比较有/无备用，包含实验服务端和证书生成成本。
编译必须在测量前完成；运行期间避免其他构建。结果只代表传输层，图片解码、
Dart 调度、设备耗电与 Release/真机表现需要单独测量。
