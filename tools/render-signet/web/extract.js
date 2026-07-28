// FluxDO 屏幕标识印记提取 · 浏览器 Web Worker 版
// 算法与 tools/render-signet/extract.py 逐行对应,常量必须与
// lib/widgets/render_signet/render_signet_codec.dart 保持一致。
// 渲染端 modulate+plus 双笔混合只动 B 通道(ΔB = DELTA·(1-2B/255),
// 极性逐像素随底色翻转),解码端以局部 B 均值估计极性权重统一归一。
// 输入 RGBA 像素,输出候选命中列表;图片不离开浏览器。

"use strict";

// ---- 与 Dart/Python 端严格一致的常量 ----
const GRID = 7;
const CELL = 12;
const PERIOD = GRID * CELL; // 84
const SYNC_ROW = [1, 0, 1, 1, 0, 0, 1];
const LEFT_COLS = [1, 6];   // bit=1 点位 x∈[1,6)
const RIGHT_COLS = [6, 11]; // bit=0 点位 x∈[6,11)
const DOT_H = 6;            // 点高

// 单元格内点 y 偏移,逐格打散(消条纹感)。与 Dart wmDotYOffset 一致
function dotY(row, col) {
  return (3 * row + 5 * col) % 7;
}

const DPR_CANDIDATES = [1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 2.625, 2.75, 3.0, 3.5, 4.0];
const MAX_CANDIDATES = 4000;
const CLIP = 2.0;
const SOFT_FLIP_POOL = 8;
const SOFT_FLIP_MAX = 3;
// 极性权重估计:B 通道盒模糊半径(逻辑 px)。核 13x13 覆盖整个单元
// 格,点自身 ΔB=±2 被稀释 ~30 倍,估出的 w 不受印记自污染
const WEIGHT_BLUR = 6;
const VERIFY_RATIO_STRONG = 2.0; // 复核:凭相位集中度即可信的 ratio 下限
const VERIFY_STRONG_MIN_MARGIN = 0.02; // 复核:STRONG 分支的 margin 地板
                                 // (软判决选择偏置可把纹理噪声 ratio 推过 2,
                                 // 但噪声 margin 恒 ~0.01,真信号 ≥0.15)
const VERIFY_RATIO_WEAK = 1.45;   // 复核:与 margin 联合判定的 ratio 下限
const VERIFY_MIN_MARGIN = 0.05;  // 复核:联合判定的最弱格净票强度下限
const PEAK_MASK_RADIUS = 3;      // 求次峰时屏蔽主峰邻域的半径
const BLIND_SEED_MIN_Z = 4.0;    // 盲搜:梳状周期峰的最低显著性
const BLIND_METRIC_BLOCKS = 12;  // 盲搜:爬山度量参与投票的块数上限
const BLIND_HILL_STEPS = [0.02, 0.01, 0.005]; // 盲搜:爬山相对步长
const BLIND_HILL_MAX_ITER = 8;   // 盲搜:每档步长最多爬山轮数
const N_CELLS = GRID * GRID; // 49
const N_PHASE = PERIOD * PERIOD; // 7056

// CRC-8 poly 0x07 init 0x00,对 uid 的 4 个大端字节
function crc8(uid) {
  let crc = 0;
  for (let i = 3; i >= 0; i--) {
    crc ^= Math.floor(uid / 2 ** (8 * i)) & 0xff;
    for (let b = 0; b < 8; b++) {
      crc = crc & 0x80 ? ((crc << 1) ^ 0x07) & 0xff : (crc << 1) & 0xff;
    }
  }
  return crc;
}

// 49 位 → uid;同步行、备用位或 CRC 不符返回 null
function decodeBits(bits) {
  for (let i = 0; i < GRID; i++) {
    if (bits[i] !== SYNC_ROW[i]) return null;
  }
  if (bits[GRID + 40] !== 1 || bits[GRID + 41] !== 0) return null;
  let uid = 0;
  for (let i = 0; i < 32; i++) uid = uid * 2 + bits[GRID + i];
  let crc = 0;
  for (let i = 0; i < 8; i++) crc = (crc << 1) | bits[GRID + 32 + i];
  return crc === crc8(uid) ? uid : null;
}

// 软判决:硬判不过 CRC 时,按 |票数| 从弱到强穷举翻转至多 3 位
function softDecode(v) {
  const hard = new Array(N_CELLS);
  for (let i = 0; i < N_CELLS; i++) hard[i] = v[i] > 0 ? 1 : 0;
  let uid = decodeBits(hard);
  if (uid !== null) return { uid, bits: hard };

  const payload = [];
  for (let i = GRID; i < N_CELLS; i++) payload.push(i);
  payload.sort((a, b) => Math.abs(v[a]) - Math.abs(v[b]));
  const pool = payload.slice(0, SOFT_FLIP_POOL);

  const combos = [];
  const pick = (start, chosen) => {
    if (chosen.length > 0) combos.push([...chosen]);
    if (chosen.length === SOFT_FLIP_MAX) return;
    for (let i = start; i < pool.length; i++) {
      chosen.push(pool[i]);
      pick(i + 1, chosen);
      chosen.pop();
    }
  };
  pick(0, []);
  combos.sort((a, b) => a.length - b.length); // 少翻优先

  for (const combo of combos) {
    const bits = [...hard];
    for (const idx of combo) bits[idx] ^= 1;
    uid = decodeBits(bits);
    if (uid !== null) return { uid, bits };
  }
  return null;
}

// (2r+1)x(2r+1) 盒模糊,边界收缩(积分图实现)
function boxBlur(a, w, h, r) {
  const S = new Float64Array((h + 1) * (w + 1));
  for (let y = 0; y < h; y++) {
    let rowSum = 0;
    for (let x = 0; x < w; x++) {
      rowSum += a[y * w + x];
      S[(y + 1) * (w + 1) + (x + 1)] = S[y * (w + 1) + (x + 1)] + rowSum;
    }
  }
  const out = new Float64Array(w * h);
  for (let y = 0; y < h; y++) {
    const y0 = Math.max(y - r, 0), y1 = Math.min(y + r + 1, h);
    for (let x = 0; x < w; x++) {
      const x0 = Math.max(x - r, 0), x1 = Math.min(x + r + 1, w);
      const sum = S[y1 * (w + 1) + x1] - S[y0 * (w + 1) + x1] -
                  S[y1 * (w + 1) + x0] + S[y0 * (w + 1) + x0];
      out[y * w + x] = sum / ((y1 - y0) * (x1 - x0));
    }
  }
  return out;
}

// RGBA(物理px) → 极性归一的加权通道 O·w(匹配滤波最优加权),同时
// 按 (sx, sy) 各向异性面积平均降采样到逻辑像素(与 PIL BOX 等价)。
// O = B-(R+G)/2 承载印记(渲染端 modulate+plus 双笔只动 B,故
// ΔO = ΔB = DELTA·(1-2B/255));w = 1-2·blur(B)/255 是由局部底色
// 估计的逐像素期望极性(黑底 +1、白底 -1)。乘 w 后印记信号恒为
// 正,同屏明暗混排统一成单极性提取;中灰死区 w≈0 自动降权。
function weightedChannelLogical(rgba, w, h, sx, sy) {
  const tw = Math.max(1, Math.round(w / sx));
  const th = Math.max(1, Math.round(h / sy));
  const oCh = new Float64Array(tw * th);
  const bCh = new Float64Array(tw * th);
  const fx = w / tw, fy = h / th;
  for (let ty = 0; ty < th; ty++) {
    const y0 = ty * fy, y1 = y0 + fy;
    const iy0 = Math.floor(y0), iy1 = Math.min(Math.ceil(y1), h);
    for (let tx = 0; tx < tw; tx++) {
      const x0 = tx * fx, x1 = x0 + fx;
      const ix0 = Math.floor(x0), ix1 = Math.min(Math.ceil(x1), w);
      let sumO = 0, sumB = 0, area = 0;
      for (let yy = iy0; yy < iy1; yy++) {
        const wy = Math.min(yy + 1, y1) - Math.max(yy, y0);
        for (let xx = ix0; xx < ix1; xx++) {
          const wx = Math.min(xx + 1, x1) - Math.max(xx, x0);
          const p = (yy * w + xx) * 4;
          const b = rgba[p + 2];
          sumO += (b - (rgba[p] + rgba[p + 1]) / 2) * wy * wx;
          sumB += b * wy * wx;
          area += wy * wx;
        }
      }
      oCh[ty * tw + tx] = sumO / area;
      bCh[ty * tw + tx] = sumB / area;
    }
  }
  const blurred = boxBlur(bCh, tw, th, WEIGHT_BLUR);
  for (let i = 0; i < oCh.length; i++) {
    oCh[i] *= 1 - (2 * blurred[i]) / 255;
  }
  return { data: oCh, w: tw, h: th };
}

// 84x84 块 → diff[cell*7056 + phase]:每格"左位均值-右位均值"在
// 全部相位下的取值(2x2 平铺 + 积分图)
function diffFields(tile) {
  const T = PERIOD * 2;
  const S = new Float64Array((T + 1) * (T + 1));
  for (let y = 0; y < T; y++) {
    let rowSum = 0;
    for (let x = 0; x < T; x++) {
      rowSum += tile[(y % PERIOD) * PERIOD + (x % PERIOD)];
      S[(y + 1) * (T + 1) + (x + 1)] = S[y * (T + 1) + (x + 1)] + rowSum;
    }
  }
  const rect = (y0, y1, x0, x1) =>
    S[y1 * (T + 1) + x1] - S[y0 * (T + 1) + x1] - S[y1 * (T + 1) + x0] + S[y0 * (T + 1) + x0];

  const diff = new Float64Array(N_CELLS * N_PHASE);
  const lArea = DOT_H * (LEFT_COLS[1] - LEFT_COLS[0]);
  const rArea = DOT_H * (RIGHT_COLS[1] - RIGHT_COLS[0]);
  for (let row = 0; row < GRID; row++) {
    for (let col = 0; col < GRID; col++) {
      const cell = row * GRID + col;
      const y0 = row * CELL + dotY(row, col), y1 = y0 + DOT_H;
      const xl0 = col * CELL + LEFT_COLS[0], xl1 = col * CELL + LEFT_COLS[1];
      const xr0 = col * CELL + RIGHT_COLS[0], xr1 = col * CELL + RIGHT_COLS[1];
      const base = cell * N_PHASE;
      for (let py = 0; py < PERIOD; py++) {
        for (let px = 0; px < PERIOD; px++) {
          const l = rect(y0 + py, y1 + py, xl0 + px, xl1 + px) / lArea;
          const r = rect(y0 + py, y1 + py, xr0 + px, xr1 + px) / rArea;
          diff[base + py * PERIOD + px] = l - r;
        }
      }
    }
  }
  return diff;
}

function tryExtract(chan, dpr, onBlock) {
  const { data, w, h } = chan;
  const bx = Math.floor(w / PERIOD), by = Math.floor(h / PERIOD);
  if (bx < 1 || by < 1) return null;
  const n = bx * by;

  // 逐块差分、限幅后累计
  const vAll = new Float64Array(N_CELLS * N_PHASE);
  const tile = new Float64Array(N_PHASE);
  for (let b = 0; b < n; b++) {
    const oy = Math.floor(b / bx) * PERIOD, ox = (b % bx) * PERIOD;
    for (let y = 0; y < PERIOD; y++) {
      for (let x = 0; x < PERIOD; x++) tile[y * PERIOD + x] = data[(oy + y) * w + ox + x];
    }
    const d = diffFields(tile);
    for (let i = 0; i < d.length; i++) {
      vAll[i] += d[i] > CLIP ? CLIP : d[i] < -CLIP ? -CLIP : d[i];
    }
    if (onBlock) onBlock();
  }

  // 候选相位:同步行符号精确匹配,margin = 最弱格净票强度
  const cands = [];
  for (let ph = 0; ph < N_PHASE; ph++) {
    let okSync = true;
    for (let i = 0; i < GRID; i++) {
      const positive = vAll[i * N_PHASE + ph] > 0;
      if (positive !== (SYNC_ROW[i] === 1)) { okSync = false; break; }
    }
    if (!okSync) continue;
    let minAbs = Infinity;
    for (let c = 0; c < N_CELLS; c++) {
      const a = Math.abs(vAll[c * N_PHASE + ph]);
      if (a < minAbs) minAbs = a;
    }
    cands.push({ ph, margin: minAbs / (n * CLIP) });
  }
  if (!cands.length) return null;
  cands.sort((a, b) => b.margin - a.margin);

  let best = null;
  const v = new Float64Array(N_CELLS);
  const score = new Float64Array(N_PHASE);
  for (const { ph, margin } of cands.slice(0, MAX_CANDIDATES)) {
    for (let c = 0; c < N_CELLS; c++) v[c] = vAll[c * N_PHASE + ph];
    const result = softDecode(v);
    if (!result) continue;
    // 匹配滤波复核:解码位模板(±1)对所有相位的票数打分。真印记
    // 只在唯一正确相位有能量,主峰远超次峰;噪声候选的"峰"本就
    // 来自相位分布尾部,主峰次峰同量级(软判决选择偏置可虚高 ratio
    // 但 margin 恒 ~0,故用双条件)。
    score.fill(0);
    for (let c = 0; c < N_CELLS; c++) {
      const t = result.bits[c] ? 1 : -1;
      const base = c * N_PHASE;
      for (let p = 0; p < N_PHASE; p++) score[p] += t * vAll[base + p];
    }
    const sorted = Float64Array.from(score).sort();
    const med = sorted[N_PHASE >> 1];
    const py = Math.floor(ph / PERIOD), px = ph % PERIOD;
    let second = -Infinity;
    for (let p = 0; p < N_PHASE; p++) {
      const yy = Math.floor(p / PERIOD), xx = p % PERIOD;
      const dy = Math.min(Math.abs(yy - py), PERIOD - Math.abs(yy - py));
      const dx = Math.min(Math.abs(xx - px), PERIOD - Math.abs(xx - px));
      if (dy <= PEAK_MASK_RADIUS && dx <= PEAK_MASK_RADIUS) continue;
      if (score[p] > second) second = score[p];
    }
    const ratio = (score[ph] - med) / (second - med + 1e-12);
    const verified = n >= 4 &&
      ((ratio >= VERIFY_RATIO_STRONG && margin >= VERIFY_STRONG_MIN_MARGIN) ||
       (ratio >= VERIFY_RATIO_WEAK && margin >= VERIFY_MIN_MARGIN));
    const hit = {
      uid: result.uid, dpr, margin, nBlocks: n, verified, ratio,
      phase: [py, px],
    };
    if (!best || (hit.verified ? 1 : 0) > (best.verified ? 1 : 0) ||
        (hit.verified === best.verified && hit.ratio > best.ratio)) {
      best = hit;
    }
  }
  return best;
}

// ---- 盲缩放搜索:档位表失败时,从图中自测缩放 ----

// 梳状周期盲测垂直缩放种子:每行 7 个点的 dy 恰好遍历 0~6(打散表
// 5 与 7 互素),行投影仍是周期 12·sy 的梳状信号(梯形轮廓),加权
// 通道上信号恒正,Goertzel 扫描 T∈[11,52] 取显著峰
function combPeriodSeeds(chan) {
  const { data, w, h } = chan;
  const n = h;
  if (n < 60) return [];
  const proj = new Float64Array(n);
  for (let y = 0; y < h; y++) {
    let s = 0;
    for (let x = 0; x < w; x++) s += data[y * w + x];
    proj[y] = s / w;
  }
  let mean = 0;
  for (const v of proj) mean += v;
  mean /= n;

  const ts = [];
  for (let t = 11.0; t < 52.0; t += 0.02) ts.push(t);
  const amps = new Float64Array(ts.length);
  for (let i = 0; i < ts.length; i++) {
    const wfreq = (2 * Math.PI) / ts[i];
    let c = 0, s = 0;
    for (let t = 0; t < n; t++) {
      const v = proj[t] - mean;
      c += v * Math.cos(wfreq * t);
      s += v * Math.sin(wfreq * t);
    }
    amps[i] = Math.hypot(c, s);
  }
  const sorted = Float64Array.from(amps).sort();
  const med = sorted[amps.length >> 1];
  const devs = Float64Array.from(amps, (a) => Math.abs(a - med)).sort();
  const mad = devs[devs.length >> 1] * 1.4826 + 1e-12;
  const peaks = [];
  for (let i = 1; i < ts.length - 1; i++) {
    const z = (amps[i] - med) / mad;
    if (z >= BLIND_SEED_MIN_Z && amps[i] >= amps[i - 1] && amps[i] >= amps[i + 1]) {
      peaks.push({ z, sy: ts[i] / CELL });
    }
  }
  peaks.sort((a, b) => b.z - a.z);
  return peaks.slice(0, 3).map((p) => p.sy);
}

// 爬山度量:同步行匹配相位上的最弱格净票强度峰值(无需已知 uid)。
// 只取前 BLIND_METRIC_BLOCKS 块控制成本。
function blindMetric(rgba, w, h, sx, sy) {
  const chan = weightedChannelLogical(rgba, w, h, sx, sy);
  const bx = Math.floor(chan.w / PERIOD), by = Math.floor(chan.h / PERIOD);
  const n = Math.min(bx * by, BLIND_METRIC_BLOCKS);
  if (bx < 1 || by < 1 || bx * by < 4) return -1;

  const vAll = new Float64Array(N_CELLS * N_PHASE);
  const tile = new Float64Array(N_PHASE);
  for (let b = 0; b < n; b++) {
    const oy = Math.floor(b / bx) * PERIOD, ox = (b % bx) * PERIOD;
    for (let y = 0; y < PERIOD; y++) {
      for (let x = 0; x < PERIOD; x++) tile[y * PERIOD + x] = chan.data[(oy + y) * chan.w + ox + x];
    }
    const d = diffFields(tile);
    for (let i = 0; i < d.length; i++) {
      vAll[i] += d[i] > CLIP ? CLIP : d[i] < -CLIP ? -CLIP : d[i];
    }
  }
  let best = 0;
  // 加权通道极性已归一,单极性扫描即可
  for (let ph = 0; ph < N_PHASE; ph++) {
    let okSync = true;
    for (let i = 0; i < GRID; i++) {
      if ((vAll[i * N_PHASE + ph] > 0) !== (SYNC_ROW[i] === 1)) { okSync = false; break; }
    }
    if (!okSync) continue;
    let minAbs = Infinity;
    for (let c = 0; c < N_CELLS; c++) {
      const a = Math.abs(vAll[c * N_PHASE + ph]);
      if (a < minAbs) minAbs = a;
    }
    const m = minAbs / (n * CLIP);
    if (m > best) best = m;
  }
  return best;
}

// 坐标轮换爬山
function hillClimb(rgba, w, h, sx0, sy0) {
  let sx = sx0, sy = sy0;
  let best = blindMetric(rgba, w, h, sx, sy);
  for (const step of BLIND_HILL_STEPS) {
    for (let iter = 0; iter < BLIND_HILL_MAX_ITER; iter++) {
      let improved = false;
      for (const [dx, dy] of [[step, 0], [-step, 0], [0, step], [0, -step]]) {
        const nx = sx * (1 + dx), ny = sy * (1 + dy);
        const m = blindMetric(rgba, w, h, nx, ny);
        if (m > best) { sx = nx; sy = ny; best = m; improved = true; }
      }
      if (!improved) break;
    }
  }
  return { sx, sy, metric: best };
}

function blindExtract(rgba, w, h, report) {
  let seeds = combPeriodSeeds(weightedChannelLogical(rgba, w, h, 1, 1)).map((sy) => [sy, sy]);
  if (!seeds.length) {
    // 兜底:等比粗扫
    const coarse = [];
    for (let s = 0.8; s < 4.2; s += 0.03) {
      coarse.push([s, blindMetric(rgba, w, h, s, s)]);
    }
    coarse.sort((a, b) => b[1] - a[1]);
    seeds = coarse.slice(0, 3).filter(([, m]) => m > 0).map(([s]) => [s, s]);
  }
  let bestHit = null;
  for (const [sx0, sy0] of seeds) {
    if (report) report(`盲搜:细化 ${sx0.toFixed(3)} 附近`);
    const { sx, sy, metric } = hillClimb(rgba, w, h, sx0, sy0);
    if (metric <= 0) continue;
    const hit = tryExtract(weightedChannelLogical(rgba, w, h, sx, sy), Math.round(sx * 1e4) / 1e4, null);
    if (hit) {
      hit.dprY = Math.round(sy * 1e4) / 1e4;
      if (!bestHit || (hit.verified ? 1 : 0) > (bestHit.verified ? 1 : 0) ||
          (hit.verified === bestHit.verified && hit.ratio > bestHit.ratio)) {
        bestHit = hit;
      }
    }
    if (bestHit && bestHit.verified) break;
  }
  return bestHit;
}

self.onmessage = (e) => {
  const { data, width, height } = e.data;
  const rgba = new Uint8ClampedArray(data);

  // 预估总块数用于进度
  let totalBlocks = 0;
  const opps = [];
  for (const dpr of DPR_CANDIDATES) {
    const tw = Math.max(1, Math.round(width / dpr));
    const th = Math.max(1, Math.round(height / dpr));
    totalBlocks += Math.floor(tw / PERIOD) * Math.floor(th / PERIOD);
    opps.push(dpr);
  }

  let done = 0;
  const hits = [];
  for (const dpr of opps) {
    self.postMessage({ type: "progress", done, total: totalBlocks, label: `dpr=${dpr} 重采样` });
    const chan = weightedChannelLogical(rgba, width, height, dpr, dpr);
    const hit = tryExtract(chan, dpr, () => {
      done++;
      if (done % 4 === 0) {
        self.postMessage({ type: "progress", done, total: totalBlocks, label: `dpr=${dpr} 分析中` });
      }
    });
    if (hit) hits.push(hit);
  }
  if (!hits.some((h) => h.verified)) {
    // 快路径失败:捕获帧可能被连续比例/非等比缩放,转盲搜
    self.postMessage({ type: "progress", done, total: totalBlocks, label: "盲缩放搜索中(可能需要十几秒)" });
    const blind = blindExtract(rgba, width, height, (label) =>
      self.postMessage({ type: "progress", done, total: totalBlocks, label }));
    if (blind) hits.push(blind);
  }
  hits.sort((a, b) =>
    (b.verified ? 1 : 0) - (a.verified ? 1 : 0) || b.ratio - a.ratio,
  );
  self.postMessage({ type: "done", hits });
};
