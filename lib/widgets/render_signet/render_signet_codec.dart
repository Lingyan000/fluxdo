/// 渲染帧亚阈值标识印记 · 编解码内核(纯 Dart,可单测)。
///
/// 把一个 32 位标识值编码为一层肉眼不可见的低对比点阵,平铺进渲染
/// 输出,可从无损帧还原。用于渲染输出的会话标识与合成一致性核验。
///
/// ## 编码结构
///
/// 一个印记块为 [kSignetGridRows] x [kSignetGridCols] 个单元格
/// (行优先):
/// - 第 0 行(7 格):固定同步图案 [kSignetSyncRow],供解码端对齐块原点;
/// - 其余 42 格:32 位标识值(大端) + 8 位 CRC-8 + 2 位备用定值。
///
/// ## 单元格 = 蓝通道位置编码
///
/// 每格只在左/右两个候选位之一画点:bit=1 在左位,bit=0 在右位。
///
/// ## 逐像素自适应极性:modulate + plus 双笔混合
///
/// 早期实现按全局主题明暗二选一画蓝点/黄点,但同屏混排明暗区域是
/// 常态(暗色主题里的白底图片、浅色主题里的代码块),错配区域要么
/// 可见要么信号清零。现方案让 GPU 混合方程逐像素完成极性自适应:
/// 同一点位按顺序叠两笔,全程只动 B 通道:
///
/// 1. modulate 笔:不透明白底图块,点色 (255,255,255-[kSignetModulateDrop])
///    → B' = B·(255-drop)/255,白底满效、黑底无效;
/// 2. plus 笔:透明底图块,点色 (0,0,255)@α=[kSignetPlusDelta]
///    → B' = B + delta,黑底满效、白底饱和自动熄火。
///
/// 取 drop = 2·delta,合成 ΔB = delta·(1 - 2B/255):黑底 +delta、
/// 白底 -delta,极性随局部底色连续翻转,无需(也不存在)全局主题
/// 判断。必须先 modulate 后 plus:结果值域 [delta, 255-delta] 无
/// clamp,两端严格对称;反序会在白底被 clamp 截断成 -2·delta。
/// 两种混合模式在 Skia/Impeller 均为系数混合(非 advanced blend),
/// 不触发离屏 pass。
///
/// 不可见性:R/G/A 全程不动,ΔB=±delta 的亮度权重仅 7%,
/// delta=1/255 的扰动与显示面板自身的量化/FRC 抖动同量级,任意
/// 底色上都低于亮度 JND——物理上的"完全不可见",不是"淡到难察觉"。
/// 代价是单点信噪比低,且 B≈128 的中灰是天然死区(信号过零),靠
/// 加大点面积 + 全屏多块投票在解码端统计还原;无损帧任何 delta>0
/// 都完整保留。
///
/// 解码端在蓝-黄对立通道 O = B-(R+G)/2 上做左右位差分(只动 B,
/// 故 ΔO = ΔB),并以局部 B 均值估计期望极性权重 w = 1-2B/255 对
/// 差分加权投票。
///
/// 块以 [kSignetBlockPeriod] 逻辑像素为周期平铺:帧被裁剪也能命中
/// 完整块,且多块符号投票可摊平内容纹理与 JPEG 色度量化噪声。
///
/// 几何常量(逻辑像素,离线核验脚本 tools/render-signet/extract.py
/// 必须与此保持一致):
/// - 单元格 [kSignetCellSize] x [kSignetCellSize];
/// - 左位 x∈[1,6)、右位 x∈[6,11),点 5x6,左右相邻(相邻背景相关性
///   最强,差分抵消内容纹理效果最好)。
library;

/// 印记块列数(单元格)
const int kSignetGridCols = 7;

/// 印记块行数(单元格)
const int kSignetGridRows = 7;

/// 单元格边长(逻辑像素)
const double kSignetCellSize = 12.0;

/// 单元格内左位 x 偏移
const double kSignetDotLeftX = 1.0;

/// 单元格内右位 x 偏移
const double kSignetDotRightX = 6.0;

/// 点宽
const double kSignetDotW = 5.0;

/// 点高
const double kSignetDotH = 6.0;

/// 单元格内点 y 偏移由 [signetDotYOffset] 逐格打散(0~6),不再全局定值:
/// 若所有格的点同 y,整屏每 12 逻辑 px 形成一条同符号"点带",人眼
/// 对长条纹有沿线积分效应(阈值比孤立色块低 2~4 倍),蓝黄 CSF 又是
/// 低通——单点不可见但整屏"发脏"。逐格伪随机相位把能量从条纹
/// 频谱峰摊平到二维频谱,总信号能量不变,条纹感消失。
int signetDotYOffset(int row, int col) => (3 * row + 5 * col) % 7;

/// 块平铺周期(逻辑像素) = 列数 x 单元格边长
const double kSignetBlockPeriod = kSignetGridCols * kSignetCellSize;

/// plus 笔点位 B 通道抬升量(0~255)。黑底上 ΔB=+kSignetPlusDelta。
/// 取 1(可行的物理最小值):亮度基频对比 ~0.03%(CSF 阈值的
/// 1/10)、蓝黄色度 ~0.3%(阈值的 1/7),低于显示面板自身量化
/// 抖动,任何底色上物理不可见;无损帧解码不受影响,代价是 JPEG
/// 重压缩后的统计信噪比减半(解码端符号投票对幅度不敏感,算法
/// 无需改动)。
const int kSignetPlusDelta = 1;

/// modulate 笔点位 B 通道乘性压降(0~255):B' = B·(255-drop)/255。
/// 取 2·kSignetPlusDelta,使黑/白底合成信号 ±kSignetPlusDelta 严格对称。
const int kSignetModulateDrop = 2 * kSignetPlusDelta;

/// 同步行图案(块首行,解码端用于块原点对齐与方向校验)
const List<bool> kSignetSyncRow = [true, false, true, true, false, false, true];

/// 备用定值位(暂不参与校验,留作版本扩展)
const List<bool> kSignetSpareBits = [true, false];

/// CRC-8 (poly 0x07, init 0x00),对标识值的 4 个大端字节计算。
int signetCrc8(int id) {
  var crc = 0;
  for (var i = 3; i >= 0; i--) {
    crc ^= (id >> (8 * i)) & 0xFF;
    for (var b = 0; b < 8; b++) {
      crc = (crc & 0x80) != 0 ? ((crc << 1) ^ 0x07) & 0xFF : (crc << 1) & 0xFF;
    }
  }
  return crc;
}

/// 把标识值编码为一个印记块的位序列(长度 = 行数 x 列数,行优先)。
List<bool> encodeSignetBits(int id) {
  assert(id >= 0 && id <= 0xFFFFFFFF, '标识值超出 32 位范围');
  final bits = <bool>[...kSignetSyncRow];
  for (var i = 31; i >= 0; i--) {
    bits.add((id >> i) & 1 == 1);
  }
  final crc = signetCrc8(id);
  for (var i = 7; i >= 0; i--) {
    bits.add((crc >> i) & 1 == 1);
  }
  bits.addAll(kSignetSpareBits);
  assert(bits.length == kSignetGridRows * kSignetGridCols);
  return bits;
}

/// 从位序列解码标识值。同步行或 CRC 校验失败返回 null。
int? decodeSignetBits(List<bool> bits) {
  if (bits.length != kSignetGridRows * kSignetGridCols) return null;
  for (var i = 0; i < kSignetSyncRow.length; i++) {
    if (bits[i] != kSignetSyncRow[i]) return null;
  }
  var id = 0;
  for (var i = 0; i < 32; i++) {
    id = (id << 1) | (bits[kSignetGridCols + i] ? 1 : 0);
  }
  var crc = 0;
  for (var i = 0; i < 8; i++) {
    crc = (crc << 1) | (bits[kSignetGridCols + 32 + i] ? 1 : 0);
  }
  if (crc != signetCrc8(id)) return null;
  // 备用位不校验:留作前向兼容
  return id;
}
