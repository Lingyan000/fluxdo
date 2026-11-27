# 图片识字运行库与模型

运行库随安装包分发，模型首次使用时下载。`hook/build.dart` 从 Google 官方 LiteRT 2.4.0 发布物提取目标架构的 CPU 库，并验证整个发布包的 SHA-256。Windows、Linux 使用官方 Python wheel 中的独立原生库，应用不携带 Python、GPU/NPU 插件或 Python 绑定。Android 使用官方 AAR，macOS 使用官方通用动态库，iOS 将官方静态框架链接进桥库。

Android 支持 arm64、armv7、x64；桌面支持 x64、arm64；iOS 支持 arm64 设备和 arm64 模拟器。官方此版本没有提供 Android x86 或 iOS x64 模拟器对应的发布物，构建会明确报告不支持。Apple 的最终链接、签名和设备运行仍需在 Apple 环境验证。Linux 官方库要求 glibc 2.27 或更新版本。

`OcrInferenceModel` 使用 LiteRT 保留的 Interpreter C API，开启 XNNPACK 双线程 CPU 推理。检测、识别都使用动态尺寸，输出尺寸在执行结束后读取，内存由解释器管理。CompiledModel 的外部输出缓冲区要求不能直接套用到此类执行过程中才确定尺寸的模型。模型字节保留到会话释放，输出视图只在回调期间有效，不能在回调中关闭或重入会话。

## 模型转换

```sh
uv run --python 3.12 tool/ocr/convert_models.py --output .dart_tool/ocr-litert
```

脚本固定 Python 依赖，下载并校验飞桨官方 PP-OCRv6 small ONNX 和字典配置，再转换为 LiteRT。已有官方文件可以用 `--source-dir` 指定目录，文件也必须通过摘要校验。转换保持 NCHW、BGR 归一化和 CTC 输出约定，以 FP16 保存权重，输入、输出和 CPU 算术使用 FP32。GELU 从图连接关系识别并转换为内置算子，禁止引入 Flex 或自定义算子库。

转换会比较多个动态尺寸下的 TensorFlow、ONNX、LiteRT 输出并检查识别序列。正式替换模型还须使用真实中文、英文、长截图和透明图验证结果及字符坐标。随机数值回归不能代替真实文字精度评估。TensorFlow 的图序列化顺序可能使重复导出的文件摘要不同；脚本保证转换与验证流程可重跑，不保证二进制逐字节一致。发布时保存经过真实图片回归的整组产物及清单，不在应用构建时重新转换。重新导出或升级工具链后，需要验证新产物并同步应用内固定清单，不能覆盖已发布版本。

## 资源发布

转换输出目录包含散文件目录、SHA-256 清单和完整 tar。模型使用 Apache-2.0 许可证，原始来源和固定 revision 写入清单。发布仓库为项目维护者账号下的 [pyteng/fluxdo-ocr](https://modelscope.cn/models/pyteng/fluxdo-ocr)，支持匿名下载。应用默认地址固定到具体提交，配合文件 SHA-256 校验，后续上传不会改变已发布应用使用的模型。

日常构建直接使用默认源，无需额外参数。需要更换分发站点时，可传入 `--dart-define=FLUXDO_OCR_MODEL_BASE_URL=<包含 det.tflite、rec.tflite、rec.yml 的 HTTPS 目录>` 覆盖。可选的 `FLUXDO_OCR_MODEL_ARCHIVE_BASE_URL` 指向存放完整 tar 的独立 HTTPS 目录；默认不配置备用源，下载失败会保留断点并报告错误。魔搭仓库中的 tar 便于完整下载和再分发，与散文件同站，不作为独立备用源。

升级时先上传经过回归的完整产物、许可证和来源清单，匿名下载校验后，再同步应用内的模型版本、固定提交地址及文件清单。不要将未发布的地址写入默认配置，也不要将旧 ONNX 模型用作 LiteRT 的备用源。

应用使用独立的 LiteRT 模型目录。只有新模型全部通过 SHA-256 校验后才回收旧 OCR 目录；下载失败保留旧资源。旧 ONNX 文件不会送入 LiteRT。

## 验证与离线构建

`test/services/ocr_inference_model_test.dart` 使用不含训练权重的小型真实模型测试动态尺寸、NCHW 布局、重入和资源释放。`test/services/ocr_model_store_test.dart` 覆盖断点、校验、取消、备用源和源配置。大模型和诊断输出放在 `.dart_tool/`，不提交进应用资源目录。

转换后的真实模型回归使用 `flutter test test/services/local_ocr_service_model_test.dart --dart-define=FLUXDO_OCR_TEST_MODEL_DIR=.dart_tool/ocr-litert/ppocr-v6-small-litert-1`。未指定模型目录时跳过这组测试；指定后会验证实际发布文件的摘要、识别结果与字符坐标。

运行库下载缓存可提前放在 `packages/fluxdo_ocr/.dart_tool/runtime/`，文件名和 SHA-256 必须与构建 hook 一致。Flatpak manifest 已为离线构建预取 Linux 官方发布物。

## 智能段落归并（line2para）

`src/line2para.c` 与 `OcrParagraphModel` 提供基于视觉外观（前景/背景 HSV 色彩、笔画宽度与一致性）和几何布局上下文的轻量图注意力网络（B-Scale 4 层 GNN）段落归并能力，以纯 C99 编译进 `fluxdo_ocr_ops`，不额外引入 ONNX Runtime，适用于全部五个平台及系统原生 Vision / 本地 LiteRT 两种识字引擎；模型未就绪或不可用时自动回退到本地几何排版。

上游来源与许可证：

- 推理算法（特征提取、四层 B-Scale GNN 前向计算与 Signed 聚类解码）：移植自 [mg-chao/simd-paddle-ocr-rs](https://github.com/mg-chao/simd-paddle-ocr-rs)（`src/paragraph/`，Apache-2.0 许可证）。
- 预训练模型文件 `line2para_1_2-epoch12-signed-1.625.onnx`（约 2.92 MiB）：来源于 [mgchao/SnowShotOCR](https://modelscope.cn/models/mgchao/SnowShotOCR)（固定提交 `a74b1a19f017058b3481906cbdb345622f2f2911`，Apache-2.0 许可证），按需下载并通过 SHA-256 校验，可通过 `--dart-define=FLUXDO_OCR_LINE2PARA_URL=<HTTPS URL>` 覆盖分发地址。
