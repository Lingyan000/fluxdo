# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = [
#   "tensorflow==2.21.0", "numpy==2.2.6", "onnx==1.20.1",
#   "onnxruntime==1.26.0", "ai-edge-litert==2.4.0",
# ]
# ///
"""从固定摘要的飞桨官方权重生成 LiteRT 模型，验证后输出可发布资源包。

运行：uv run --python 3.12 tool/ocr/convert_models.py --output .dart_tool/ocr-litert
已有官方文件时使用 --source-dir DIR，文件名为 det.onnx、rec.onnx、rec.yml。
"""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import tarfile
import urllib.request

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")
import numpy as np
import onnx
import onnxruntime as ort
import tensorflow as tf
from ai_edge_litert.interpreter import Interpreter
from ai_edge_litert import schema_py_generated as schema

BUNDLE = "ppocr-v6-small-litert-1"
SOURCES = {
    "det.onnx": (
        "PP-OCRv6_small_det_onnx",
        "956a0b620a4017cc04056c692be1703b0025d028",
        "inference.onnx",
        "d73e0058b7a8086bbd57f3d10b8bcd4ff95363f67e06e2762b5e814fe9c9410e",
    ),
    "rec.onnx": (
        "PP-OCRv6_small_rec_onnx",
        "296d43bc0ebced0fd9c605174aa5962e49810ab6",
        "inference.onnx",
        "5435fd747c9e0efe15a96d0b378d5bd157e9492ed8fd80edf08f30d02fa24634",
    ),
    "rec.yml": (
        "PP-OCRv6_small_rec_onnx",
        "296d43bc0ebced0fd9c605174aa5962e49810ab6",
        "inference.yml",
        "ab078671bb49f06228eadccd34f1bb501e157f7a047095ffb943ba81512c77d1",
    ),
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def source_files(directory):
    directory.mkdir(parents=True, exist_ok=True)
    for name, (repo, revision, member, expected) in SOURCES.items():
        path = directory / name
        if not path.exists():
            url = f"https://modelscope.cn/models/PaddlePaddle/{repo}/resolve/{revision}/{member}"
            with urllib.request.urlopen(url, timeout=120) as response:
                data = response.read()
            if digest(data) != expected:
                raise ValueError(f"官方文件校验失败：{name}")
            path.write_bytes(data)
        elif digest(path.read_bytes()) != expected:
            raise ValueError(f"已有官方文件校验失败：{path}")


class OcrGraph(tf.Module):
    def __init__(self, source_path, name):
        super().__init__()
        self.source = onnx.load(source_path)
        self.weights = {
            w.name: onnx.numpy_helper.to_array(w) for w in self.source.graph.initializer
        }
        # 按图的连线识别精确 GELU，避免引入 FlexErf 及额外运行库。
        self.gelu = {}
        nodes = list(self.source.graph.node)
        producers = {name: n for n in nodes for name in n.output}
        for half in nodes:
            if (
                half.op_type != "Mul"
                or half.input[1] not in self.weights
                or not np.all(self.weights[half.input[1]] == 0.5)
            ):
                continue
            mul = producers.get(half.input[0])
            if mul is None or mul.op_type != "Mul":
                continue
            add = producers.get(mul.input[1])
            if (
                add is None
                or add.op_type != "Add"
                or not np.all(self.weights.get(add.input[1], 0) == 1)
            ):
                continue
            erf = producers.get(add.input[0])
            if erf is None or erf.op_type != "Erf":
                continue
            div = producers.get(erf.input[0])
            if (
                div is None
                or div.op_type != "Div"
                or not np.allclose(self.weights.get(div.input[1], 0), np.sqrt(2))
            ):
                continue
            if mul.input[0] == div.input[0]:
                self.gelu[half.output[0]] = div.input[0]
        shape = [1, 3, 48 if name == "rec" else None, None]
        self.run = tf.function(
            self._call,
            input_signature=[tf.TensorSpec(shape, tf.float32, name="pixels")],
        )

    def _call(self, pixels):
        values = {name: tf.constant(value) for name, value in self.weights.items()}
        values["x"] = pixels
        for node in self.source.graph.node:
            a = {
                attr.name: onnx.helper.get_attribute_value(attr)
                for attr in node.attribute
            }
            args = [values[name] if name else None for name in node.input]
            x = args[0]
            op = node.op_type
            if node.output[0] in self.gelu:
                y = tf.nn.gelu(values[self.gelu[node.output[0]]], approximate=False)
            elif op == "Conv":
                x = tf.transpose(x, [0, 2, 3, 1])
                padding = "SAME" if a.get("auto_pad") == b"SAME_UPPER" else "VALID"
                pads = a.get("pads", [0, 0, 0, 0])
                if any(pads):
                    x = tf.pad(
                        x, [[0, 0], [pads[0], pads[2]], [pads[1], pads[3]], [0, 0]]
                    )
                strides = a.get("strides", [1, 1])
                dilations = a.get("dilations", [1, 1])
                group = a.get("group", 1)
                if group == 1:
                    y = tf.nn.conv2d(
                        x,
                        tf.transpose(args[1], [2, 3, 1, 0]),
                        strides,
                        padding,
                        dilations=dilations,
                    )
                else:
                    assert args[1].shape[1] == 1 and args[1].shape[0] == group
                    y = tf.nn.depthwise_conv2d(
                        x,
                        tf.transpose(args[1], [2, 3, 0, 1]),
                        [1, *strides, 1],
                        padding,
                        dilations=dilations,
                    )
                if len(args) == 3:
                    y = y + args[2]
                y = tf.transpose(y, [0, 3, 1, 2])
            elif op == "ConvTranspose":
                assert a.get("group", 1) == 1 and not any(a.get("pads", [0] * 4))
                assert a["kernel_shape"] == a["strides"] and a["dilations"] == [1, 1]
                x = tf.transpose(x, [0, 2, 3, 1])
                shape = tf.shape(x)
                strides = a["strides"]
                shape = [
                    shape[0],
                    shape[1] * strides[0],
                    shape[2] * strides[1],
                    args[1].shape[1],
                ]
                y = tf.nn.conv2d_transpose(
                    x,
                    tf.transpose(args[1], [2, 3, 1, 0]),
                    shape,
                    [1, *strides, 1],
                    "VALID",
                )
                if len(args) == 3:
                    y = y + args[2]
                y = tf.transpose(y, [0, 3, 1, 2])
            elif op == "Resize":
                assert (
                    a["mode"] == b"nearest"
                    and a["coordinate_transformation_mode"] == b"asymmetric"
                    and a["nearest_mode"] == b"floor"
                )
                x = tf.transpose(x, [0, 2, 3, 1])
                size = tf.cast(
                    tf.cast(tf.shape(x)[1:3], tf.float32) * args[2][2:4], tf.int32
                )
                y = tf.transpose(
                    tf.raw_ops.ResizeNearestNeighbor(
                        images=x,
                        size=size,
                        align_corners=False,
                        half_pixel_centers=False,
                    ),
                    [0, 3, 1, 2],
                )
            elif op == "GlobalAveragePool":
                y = tf.reduce_mean(x, axis=[2, 3], keepdims=True)
            elif op in ("MaxPool", "AveragePool"):
                assert not any(a.get("pads", [0, 0, 0, 0])) and not a.get(
                    "ceil_mode", 0
                )
                x = tf.transpose(x, [0, 2, 3, 1])
                padding = "SAME" if a.get("auto_pad") == b"SAME_UPPER" else "VALID"
                pool = tf.nn.max_pool2d if op == "MaxPool" else tf.nn.avg_pool2d
                y = tf.transpose(
                    pool(x, a["kernel_shape"], a["strides"], padding), [0, 3, 1, 2]
                )
            elif op == "BatchNormalization":
                scale, bias, mean, variance = [
                    tf.reshape(t, [1, -1, 1, 1]) for t in args[1:]
                ]
                y = (x - mean) * tf.math.rsqrt(variance + a["epsilon"]) * scale + bias
            elif op == "Add":
                y = x + args[1]
            elif op == "Sub":
                y = x - args[1]
            elif op == "Mul":
                y = x * args[1]
            elif op == "Div":
                y = x / args[1]
            elif op == "Pow":
                y = tf.pow(x, args[1])
            elif op == "Sqrt":
                y = tf.sqrt(x)
            elif op == "Erf":
                y = tf.math.erf(x)
            elif op == "Relu":
                y = tf.nn.relu(x)
            elif op == "Sigmoid":
                y = tf.math.sigmoid(x)
            elif op == "HardSigmoid":
                y = tf.clip_by_value(
                    x * a.get("alpha", 0.2) + a.get("beta", 0.5), 0.0, 1.0
                )
            elif op == "Identity":
                y = x
            elif op == "ReduceMean":
                y = tf.reduce_mean(
                    x, axis=a["axes"], keepdims=bool(a.get("keepdims", 1))
                )
            elif op == "Softmax":
                y = tf.nn.softmax(x, axis=a.get("axis", -1))
            elif op == "MatMul":
                y = tf.matmul(x, args[1])
            elif op == "Transpose":
                y = tf.transpose(x, a["perm"])
            elif op == "Concat":
                y = tf.concat(args, axis=a["axis"])
            elif op == "Shape":
                y = tf.shape(x, out_type=tf.int64)
            elif op == "Squeeze":
                y = tf.squeeze(x, axis=a.get("axes"))
            elif op == "Unsqueeze":
                y = x
                for axis in sorted(a["axes"]):
                    y = tf.expand_dims(y, axis)
            elif op == "Reshape":
                dims = args[1]
                # ONNX 的 0 表示沿用输入的同序维度。
                current = tf.shape(x, out_type=dims.dtype)
                current = tf.concat(
                    [
                        current,
                        tf.ones(
                            [tf.maximum(0, tf.size(dims) - tf.size(current))],
                            dims.dtype,
                        ),
                    ],
                    0,
                )[: tf.size(dims)]
                y = tf.reshape(x, tf.where(dims == 0, current, dims))
            elif op == "Slice":
                starts, ends = args[1:3]
                axes = (
                    tf.get_static_value(args[3])
                    if len(args) > 3
                    else np.arange(starts.shape[0])
                )
                steps = (
                    tf.get_static_value(args[4])
                    if len(args) > 4
                    else np.ones(len(axes), np.int64)
                )
                begin = [0] * x.shape.rank
                end = [0] * x.shape.rank
                stride = [1] * x.shape.rank
                mask = (1 << x.shape.rank) - 1
                for i, axis in enumerate(axes):
                    axis = int(axis) % x.shape.rank
                    begin[axis], end[axis], stride[axis] = (
                        starts[i],
                        ends[i],
                        int(steps[i]),
                    )
                    mask &= ~(1 << axis)
                y = tf.strided_slice(
                    x, begin, end, stride, begin_mask=mask, end_mask=mask
                )
            else:
                raise ValueError(f"Unsupported {op}: {node.name}")
            assert len(node.output) == 1
            values[node.output[0]] = y
        return values[self.source.graph.output[0].name]


def convert(source_dir, output_dir, name):
    graph = OcrGraph(source_dir / f"{name}.onnx", name)
    concrete = graph.run.get_concrete_function()
    converter = tf.lite.TFLiteConverter.from_concrete_functions([concrete], graph)
    converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS]
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    converter.target_spec.supported_types = [tf.float16]
    model = converter.convert()
    flat = schema.Model.GetRootAsModel(model, 0)
    if any(
        flat.OperatorCodes(i).BuiltinCode() == schema.BuiltinOperator.CUSTOM
        for i in range(flat.OperatorCodesLength())
    ):
        raise ValueError("模型含自定义算子，不能使用精简随包运行库")
    path = output_dir / f"{name}.tflite"
    path.write_bytes(model)
    runtime = Interpreter(model_path=str(path), num_threads=2)
    reference = ort.InferenceSession(
        str(source_dir / f"{name}.onnx"), providers=["CPUExecutionProvider"]
    )
    shapes = (
        [(320, 48), (328, 48), (640, 48), (1600, 48), (320, 48)]
        if name == "rec"
        else [(192, 128), (320, 320), (1280, 32), (192, 128)]
    )
    checks = []
    for width, height in shapes:
        pixels = (
            np.random.default_rng(42)
            .uniform(-1, 1, (1, 3, height, width))
            .astype(np.float32)
        )
        expected = reference.run(None, {"x": pixels})[0]
        tf_result = graph.run(pixels).numpy()
        np.testing.assert_allclose(tf_result, expected, rtol=0.005, atol=0.0001)
        runtime.resize_tensor_input(
            runtime.get_input_details()[0]["index"], pixels.shape
        )
        runtime.allocate_tensors()
        runtime.set_tensor(runtime.get_input_details()[0]["index"], pixels)
        runtime.invoke()
        actual = runtime.get_tensor(runtime.get_output_details()[0]["index"])
        if actual.shape != expected.shape or not np.isfinite(actual).all():
            raise ValueError(f"{name} 动态输出异常：{actual.shape}")
        error = np.abs(actual - expected)
        # 数值比较用于阻止转换错误；正式发布还应跑真实中英文截图回归。
        if error.max() > 0.03 or error.mean() > 0.0001:
            raise ValueError(f"{name} FP16 误差过大：{error.max()}, {error.mean()}")
        if name == "rec" and not np.array_equal(actual.argmax(-1), expected.argmax(-1)):
            raise ValueError("识别模型的验证序列发生变化")
        checks.append(
            {
                "width": width,
                "height": height,
                "maxError": float(error.max()),
                "meanError": float(error.mean()),
            }
        )
    print(f"{name}: {len(model)} bytes, sha256={digest(model)}", flush=True)
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source-dir", type=Path)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=True)
    sources = args.source_dir.resolve() if args.source_dir else root / "sources"
    source_files(sources)
    publish = root / BUNDLE
    publish.mkdir(exist_ok=True)
    checks = {name: convert(sources, publish, name) for name in ("det", "rec")}
    (publish / "rec.yml").write_bytes((sources / "rec.yml").read_bytes())
    # 模型沿用飞桨的 Apache-2.0 许可证，运行库的通知单独随应用分发。
    license_text = (
        Path(__file__).resolve().parents[2] / "packages/fluxdo_ocr/LICENSE"
    ).read_text(encoding="utf-8")
    license_text = license_text[
        license_text.index("PP-OCRv6 small (PaddlePaddle)") : license_text.index(
            "Google LiteRT"
        )
    ]
    (publish / "LICENSE").write_text(
        license_text + "\n", encoding="utf-8", newline="\n"
    )
    (publish / "README.md").write_text(
        """---
license: apache-2.0
---
# FluxDO PP-OCRv6 small LiteRT

从 PaddlePaddle 官方 PP-OCRv6 small ONNX 权重转换，FP16 权重、FP32 输入输出。
模型仅使用 LiteRT 内置算子。检测输入 NCHW `[1,3,H,W]`，H/W 为 32 的倍数；识别输入 `[1,3,48,W]`，W 为 8 的倍数。
转换工具：FluxDO 仓库 `tool/ocr/convert_models.py`。原始文件来源和校验值见 manifest.json。

模型在用户设备离线推理。上传至项目自己的模型仓库后，应用通过固定版本路径和 SHA-256 校验下载。
""",
        encoding="utf-8",
        newline="\n",
    )
    files = [
        {"name": p.name, "size": p.stat().st_size, "sha256": digest(p.read_bytes())}
        for p in (publish / "det.tflite", publish / "rec.tflite", publish / "rec.yml")
    ]
    archive = root / f"{BUNDLE}.tar"
    with tarfile.open(archive, "w", format=tarfile.USTAR_FORMAT) as tar:
        for name in ("det.tflite", "rec.tflite", "rec.yml", "LICENSE", "README.md"):
            data = (publish / name).read_bytes()
            entry = tarfile.TarInfo(f"{BUNDLE}/{name}")
            entry.size = len(data)
            entry.mode = 0o644
            tar.addfile(entry, io.BytesIO(data))
    manifest = {
        "id": BUNDLE,
        "runtime": "LiteRT 2.4.0",
        "files": files,
        "archive": {
            "name": archive.name,
            "size": archive.stat().st_size,
            "sha256": digest(archive.read_bytes()),
        },
        "sources": {
            name: {"repo": repo, "revision": revision, "file": member, "sha256": sha}
            for name, (repo, revision, member, sha) in SOURCES.items()
        },
    }
    (publish / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    (root / "verification.json").write_text(
        json.dumps(checks, indent=2) + "\n", encoding="utf-8"
    )
    print(f"发布目录：{publish}\n备用归档：{archive}")


if __name__ == "__main__":
    main()
