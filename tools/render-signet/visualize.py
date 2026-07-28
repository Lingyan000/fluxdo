# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "pillow"]
# ///
"""把 render-signet 的加权通道 O·w 直接可视化——不跑完整提取算法,
只做"反色看水印"这一步:算出承载印记的加权通道,把 ±DELTA 的微小
扰动做极端对比度拉伸,人眼直接看到点阵网格。

原理照抄 extract.py 的 weighted_channel:
- O = B-(R+G)/2 只保留印记所在的蓝-黄对立通道,内容亮度纹理近似抵消
- w = 1-2*blur(B)/255 按局部底色把极性归一(黑底/白底统一符号),
  这一步就是问题里说的"反色"——但不是整图反色,是按局部底色做符号
  归一化,不然黑底白底会长得像两种不同的花纹
- 拉伸对比度(默认 40 倍)后±1 的信号被放大到肉眼可辨的黑白点阵
"""

import sys

import numpy as np
from PIL import Image

WEIGHT_BLUR = 6


def _box_blur(a: np.ndarray, r: int) -> np.ndarray:
    h, w = a.shape
    s = np.zeros((h + 1, w + 1))
    s[1:, 1:] = a.cumsum(0).cumsum(1)
    y0 = np.clip(np.arange(h) - r, 0, h)
    y1 = np.clip(np.arange(h) + r + 1, 0, h)
    x0 = np.clip(np.arange(w) - r, 0, w)
    x1 = np.clip(np.arange(w) + r + 1, 0, w)
    area = (y1 - y0)[:, None] * (x1 - x0)[None, :]
    return (s[y1][:, x1] - s[y0][:, x1] - s[y1][:, x0] + s[y0][:, x0]) / area


def weighted_channel(rgb: np.ndarray) -> np.ndarray:
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    o = b - (r + g) / 2
    w = 1.0 - 2.0 * _box_blur(b, WEIGHT_BLUR) / 255.0
    return o * w


def main():
    if len(sys.argv) < 2:
        print("用法: uv run visualize.py <图片路径> [放大倍数,默认40]")
        return 1
    path = sys.argv[1]
    gain = float(sys.argv[2]) if len(sys.argv) > 2 else 40.0

    img = Image.open(path).convert("RGB")
    rgb = np.asarray(img, dtype=np.float64)
    chan = weighted_channel(rgb)

    vis = np.clip(chan * gain + 128, 0, 255).astype(np.uint8)
    out_path = path.rsplit(".", 1)[0] + "_signet_visible.png"
    Image.fromarray(vis, mode="L").save(out_path)
    print(f"已保存: {out_path}  (gain={gain})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
