.pragma library

// 桌面海洋的 ASCII 光栅。移植自 stackedlol/ascii-sharks（MIT）的 src/renderer.ts，
// 但渲染策略按本机实测重写过。
//
// 为什么不能照搬上游：上游逐格 ctx.fillText，在浏览器里没问题，但在
// Quickshell 的 Canvas 上实测 1600 格只有 10fps。这里改成「按行批处理」——
// 先把每格归类成（字形, 调色桶），再对每个（桶, 行）拼成一整行字符串，
// 一次 fillText 画完一行。实测每帧约 180 次 fillText → 30~39fps。
//
// 为什么鲨鱼用体型查表：逐格遍历 19 段脊线求最近点，340 条鱼时只有 19fps。
// 体型（沿脊的 s、横向的 v）是静态的，所以预计算成 64x48 的表，
// 每格只剩 2 次乘法 + 2 次查表。

.import "Math.js" as Math2

var SHARK_NODES = 20;

// 表尺寸。s 覆盖吻到尾，v 覆盖到胸鳍尖（±0.3L），否则鳍会被裁掉。
var TS = 64;
var TV = 48;
var VSPAN = 0.30;

// 类别：低 4 位是字形档位（0=空），高 4 位是类别。
var CAT_BODY = 0;
var CAT_FIN = 1;
var CAT_RIDGE = 2;
var CAT_EYE = 3;
var CAT_MARK = 4;

// 鱼用 15 标记，与鲨鱼字形的 1..8 区分开：否则最亮的鲨鱼格会被画成鱼的横杠。
var GLYPH_FISH = 15;

var SKIN_RAMP = ":;t%SX8#@";
var FIN_GLYPHS = "%;tS:";
var RIDGE_GLYPHS = "@8%";
var MARK_GLYPHS = "#%@";

// 经典真鲨的体型：吻部收窄、鳃后最宽、尾柄骤细。
function classicHalfWidth(s) {
  if (s < 0.13) return 0.09 * Math.pow(Math.sin((s / 0.13) * Math.PI / 2), 0.95);
  if (s < 0.3) return 0.09 + 0.016 * Math2.smoothstep(0.13, 0.3, s);
  if (s < 0.84) return 0.019 + 0.087 * Math.pow(1 - (s - 0.3) / 0.54, 1.25);
  var k = (s - 0.84) / 0.16;
  return 0.019 * (1 - k) + 0.012 * Math.sin(k * Math.PI);
}

// 每种鲨鱼的体型与花纹。数值取自上游，改一个就会失去该物种的辨识度。
var SHAPES = {
  classic: {
    halfWidth: classicHalfWidth,
    pectoral: [0.15, 0.43, 0.55, 0.26], falcate: true,
    pelvic: [0.57, 0.65, 0.69, 0.085], caudal: 0.085,
    dorsal: [0.33, 0.47], secondDorsal: [0.71, 0.76],
    eye: [0.10, 0.14], gills: [0.19, 0.29],
    tint: [0.92, 0.97, 1.05]
  },
  hammerhead: {
    halfWidth: function (s) {
      if (s < 0.06) return 0.045;
      if (s < 0.3) return 0.045 + 0.061 * Math2.smoothstep(0.06, 0.3, s);
      return classicHalfWidth(s) * 0.92;
    },
    head: { span: 0.17, sweep: 0.035, depth: 0.09, notch: 0 },
    pectoral: [0.17, 0.4, 0.5, 0.22], falcate: true,
    pelvic: [0.56, 0.63, 0.67, 0.075], caudal: 0.11,
    dorsal: [0.28, 0.44], secondDorsal: [0.70, 0.74],
    eye: null, gills: [0.16, 0.26],
    tint: [0.96, 0.98, 0.90]
  },
  greathammer: {
    halfWidth: function (s) {
      if (s < 0.05) return 0.04;
      if (s < 0.3) return 0.04 + 0.07 * Math2.smoothstep(0.05, 0.3, s);
      return classicHalfWidth(s) * 0.95;
    },
    head: { span: 0.21, sweep: 0.006, depth: 0.085, notch: 0.014 },
    pectoral: [0.16, 0.38, 0.49, 0.24], falcate: true,
    pelvic: [0.55, 0.62, 0.67, 0.085], caudal: 0.13,
    dorsal: [0.24, 0.45], secondDorsal: [0.68, 0.74],
    eye: null, gills: [0.15, 0.25],
    tint: [0.86, 0.93, 1.02]
  },
  tiger: {
    halfWidth: function (s) {
      if (s < 0.13) return 0.1 * Math.pow(Math.sin((s / 0.13) * Math.PI / 2), 0.45);
      if (s < 0.3) return 0.1 + 0.014 * Math2.smoothstep(0.13, 0.3, s);
      if (s < 0.84) return 0.019 + 0.095 * Math.pow(1 - (s - 0.3) / 0.54, 1.2);
      var k = (s - 0.84) / 0.16;
      return 0.019 * (1 - k) + 0.012 * Math.sin(k * Math.PI);
    },
    pectoral: [0.15, 0.42, 0.53, 0.25], falcate: true,
    pelvic: [0.57, 0.65, 0.69, 0.085], caudal: 0.095,
    dorsal: [0.33, 0.46], secondDorsal: [0.71, 0.75],
    eye: [0.08, 0.12], gills: [0.19, 0.28],
    tint: [1.02, 0.95, 0.84]
  },
  zebra: {
    halfWidth: function (s) {
      if (s < 0.1) return 0.075 * Math.pow(Math.sin((s / 0.1) * Math.PI / 2), 0.7);
      if (s < 0.28) return 0.075 + 0.025 * Math2.smoothstep(0.1, 0.28, s);
      if (s < 0.55) return 0.022 + 0.078 * Math.pow(1 - (s - 0.28) / 0.27, 1.1);
      var k = (s - 0.55) / 0.45;
      return 0.022 * (1 - k * k) + 0.012 * Math.sin(k * Math.PI);
    },
    pectoral: [0.12, 0.3, 0.36, 0.19], falcate: false,
    pelvic: [0.42, 0.48, 0.51, 0.065], caudal: 0,
    dorsal: [0.36, 0.44], secondDorsal: [0.49, 0.53],
    eye: [0.06, 0.09], gills: [0.13, 0.20],
    tint: [1.08, 0.97, 0.74]
  },
  mako: {
    halfWidth: function (s) {
      if (s < 0.17) return 0.088 * Math.pow(Math.sin((s / 0.17) * Math.PI / 2), 1.5);
      if (s < 0.32) return 0.088 + 0.012 * Math2.smoothstep(0.17, 0.32, s);
      if (s < 0.86) return 0.014 + 0.086 * Math.pow(1 - (s - 0.32) / 0.54, 1.45);
      var k = (s - 0.86) / 0.14;
      return 0.014 * (1 - k) + 0.01 * Math.sin(k * Math.PI);
    },
    pectoral: [0.18, 0.4, 0.5, 0.21], falcate: true,
    pelvic: [0.58, 0.64, 0.68, 0.06], caudal: 0.13,
    dorsal: [0.34, 0.45], secondDorsal: [0.76, 0.79],
    eye: [0.11, 0.15], gills: [0.20, 0.30],
    tint: [0.78, 0.90, 1.20]
  },
  thresher: {
    halfWidth: function (s) {
      if (s < 0.08) return 0.07 * Math.pow(Math.sin((s / 0.08) * Math.PI / 2), 0.75);
      if (s < 0.2) return 0.07 + 0.02 * Math2.smoothstep(0.08, 0.2, s);
      if (s < 0.48) return 0.012 + 0.078 * Math.pow(1 - (s - 0.2) / 0.28, 1.3);
      var k = (s - 0.48) / 0.52;
      return 0.012 * (1 - k) + 0.006 * Math.sin(k * Math.PI * 0.9) + 0.002;
    },
    pectoral: [0.12, 0.27, 0.36, 0.20], falcate: true,
    pelvic: [0.37, 0.41, 0.44, 0.045], caudal: 0,
    dorsal: [0.24, 0.32], secondDorsal: [0.45, 0.47],
    eye: [0.05, 0.10], gills: [0.11, 0.18],
    tint: [1.00, 0.90, 1.08]
  },
  nurse: {
    halfWidth: function (s) {
      if (s < 0.08) return 0.085 * Math.pow(Math.sin((s / 0.08) * Math.PI / 2), 0.4);
      if (s < 0.3) return 0.085 + 0.02 * Math2.smoothstep(0.08, 0.3, s);
      if (s < 0.72) return 0.022 + 0.083 * Math.pow(1 - (s - 0.3) / 0.42, 1.1);
      var k = (s - 0.72) / 0.28;
      return 0.022 * (1 - k * k) + 0.014 * Math.sin(k * Math.PI);
    },
    pectoral: [0.16, 0.34, 0.4, 0.17], falcate: false,
    pelvic: [0.45, 0.52, 0.55, 0.075], caudal: 0,
    dorsal: [0.50, 0.58], secondDorsal: [0.63, 0.69],
    eye: [0.05, 0.075], gills: [0.14, 0.22],
    tint: [1.10, 0.96, 0.76]
  }
};

var KINDS = ["classic", "hammerhead", "greathammer", "tiger", "zebra", "mako", "thresher", "nurse"];

function inTriangle(px, py, ax, ay, bx, by, cx, cy) {
  var d1 = (px - bx) * (ay - by) - (ax - bx) * (py - by);
  var d2 = (px - cx) * (by - cy) - (bx - cx) * (py - cy);
  var d3 = (px - ax) * (cy - ay) - (cx - ax) * (py - ay);
  var neg = (d1 < 0) || (d2 < 0) || (d3 < 0);
  var pos = (d1 > 0) || (d2 > 0) || (d3 > 0);
  return !(neg && pos);
}

// 把一种鲨鱼的体型烘焙成查表。表项 = (类别 << 4) | 字形档位（0 表示空）。
function buildShapeTable(kind) {
  var shape = SHAPES[kind] || SHAPES.classic;
  var table = new Uint8Array(TS * TV);
  for (var si = 0; si < TS; si++) {
    var s = (si + 0.5) / TS;
    var hw = shape.halfWidth(s);
    var u = s; // 归一化弧长
    for (var vi = 0; vi < TV; vi++) {
      var v = ((vi + 0.5) / TV * 2 - 1) * VSPAN;
      var av = Math.abs(v);
      var cell = 0;

      // 双髻鲨的头翼：吻端一道横扫的翼，边缘略向后掠，中央可能有凹口。
      var head = shape.head;
      var hitHead = false;
      if (head) {
        var span = head.span;
        var r = av / span;
        var front = head.sweep * r * r + head.notch * Math.max(0, 1 - r / 0.14);
        var depth = head.depth * (1 - 0.2 * r * r * r * r);
        if (r <= 1 && u >= front && u <= front + depth) {
          var headShade = r > 0.84 ? 0 : 0.62 - 0.2 * r + (u < front + 0.012 ? 0.1 : 0);
          cell = (r > 0.84 ? CAT_EYE : CAT_BODY) << 4;
          cell |= 1 + Math.min(7, Math.floor((1 - headShade) * 7));
          table[si * TV + vi] = cell;
          hitHead = true;
        }
      }
      if (hitHead) continue;

      // 身体
      if (av <= hw) {
        var across = av / (hw || 1);
        // 背脊受光（左上打光），体侧落入阴影
        var facing = -0.6 * (v < 0 ? -1 : 1) * across;
        var shade = 0.58 - across * across * 0.42 + facing * 0.26;
        var cat = CAT_BODY;
        if (s > shape.dorsal[0] && s < shape.dorsal[1] && across < 0.3) {
          cat = CAT_RIDGE; shade = 1;
        } else if (s > shape.secondDorsal[0] && s < shape.secondDorsal[1] && across < 0.4) {
          shade = Math.max(shade, 0.82);
        } else if (shape.eye && s > shape.eye[0] && s < shape.eye[1] && across > 0.6) {
          cat = CAT_EYE; shade = 0;
        } else if (s > shape.gills[0] && s < shape.gills[1] && across > 0.58) {
          // 五道鳃裂
          if (Math.floor(((s - shape.gills[0]) / (shape.gills[1] - shape.gills[0])) * 5) % 2 === 0) shade *= 0.45;
        } else if (s < 0.05) {
          shade = Math.max(shade, 0.7); // 吻端泛白
        } else if (kind === "tiger" && s > 0.08 && s < 0.55 && (across < 0.1 || Math.abs(across - 0.6) < 0.08)) {
          shade = Math.max(shade, 0.8);
        } else if (isMarked(kind, s, v, across)) {
          cat = CAT_MARK; shade = 0.3;
        }
        cell = cat << 4;
        cell |= 1 + Math.min(7, Math.floor((1 - Math2.clamp(shade, 0, 1)) * 7));
        table[si * TV + vi] = cell;
        continue;
      }

      // 胸鳍：从根部三角展开，镰刀状（falcate）的有内凹的后缘。
      var p = shape.pectoral;
      if (inTriangle(u, av, p[0], 0, p[1], 0, p[2], p[3])
          && !(shape.falcate && inTriangle(u, av, p[1], 0, p[1] + (p[2] - p[1]) * 0.33, p[3] * 0.55, p[2], p[3]))) {
        var finShade = 0.38 + 0.22 * (1 - Math2.clamp(av / p[3], 0, 1));
        cell = CAT_FIN << 4;
        cell |= 1 + Math.min(7, Math.floor((1 - finShade) * 7));
        table[si * TV + vi] = cell;
        continue;
      }
      // 腹鳍 + 尾鳍
      var pv = shape.pelvic;
      if (inTriangle(u, av, pv[0], 0, pv[1], 0, pv[2], pv[3])
          || (shape.caudal > 0 && inTriangle(u, av, 0.86, 0, 0.95, 0, 1, shape.caudal))) {
        cell = CAT_FIN << 4;
        cell |= 1 + Math.min(7, Math.floor((1 - 0.36) * 7));
        table[si * TV + vi] = cell;
      }
    }
  }
  return table;
}

// 虎鲨的波状横纹、斑马鲨的豹斑。必须随皮肤走，所以按 (s, v) 判定而非屏幕坐标。
function isMarked(kind, s, v, across) {
  if (kind === "tiger") {
    if (s < 0.2 || s > 0.9 || across > 0.85) return false;
    var wobble = 0.35 * Math.sin(v * 25 + s * 5);
    var bar = Math.sin(s * Math.PI * 2 * 9 + wobble);
    return bar > 0.65 - 0.5 * Math2.smoothstep(0.2, 0.42, s) + 0.4 * Math2.smoothstep(0.8, 0.9, s);
  }
  if (kind === "zebra") {
    if (s < 0.07) return false;
    var gu = (s * 1) / 0.06;
    var gv = v / 0.045;
    var cu = Math.floor(gu), cv = Math.floor(gv);
    var jx = Math2.hash3(cu, cv, 1) * 0.5 + 0.25;
    var jy = Math2.hash3(cu, cv, 12) * 0.5 + 0.25;
    return (gu - cu - jx) * (gu - cu - jx) + (gv - cv - jy) * (gv - cv - jy) < 0.08;
  }
  return false;
}

// 调色桶。数量直接决定每帧 fillText 次数，所以刻意压到 8 个：
// 鱼 3 档亮度 + 鲨鱼身体 3 档 + 鳍 1 档 + 高光（眼/斑纹/背脊）1 档。
var BUCKET_FISH0 = 0;
var BUCKET_FISH1 = 1;
var BUCKET_FISH2 = 2;
var BUCKET_BODY0 = 3;
var BUCKET_BODY1 = 4;
var BUCKET_BODY2 = 5;
var BUCKET_FIN = 6;
var BUCKET_HILITE = 7;
var BUCKETS = 8;

var BUCKET_STYLE = [
  "rgba(214,228,255,0.34)",  // 远鱼
  "rgba(224,236,255,0.58)",  // 中距鱼
  "rgba(238,245,255,0.88)",  // 近鱼 / 惊逃闪光
  "rgb(96,108,128)",         // 鲨鱼暗部
  "rgb(140,155,180)",        // 鲨鱼中间调
  "rgb(196,212,238)",        // 鲨鱼受光面
  "rgb(120,134,158)",        // 鳍
  "rgb(232,240,255)"         // 背脊 / 眼 / 斑纹
];

function makeState() {
  return {
    tables: {},
    cols: 0,
    rows: 0,
    frame: 0,
    cw: 0,
    ch: 0,
    glyph: new Uint8Array(0),
    bucket: new Int16Array(0),
    energy: new Float32Array(0),
    energyTmp: new Float32Array(0),
    heat: new Float32Array(0),
    hot: [],
    fontFamily: "monospace"
  };
}

function tableFor(state, kind) {
  var t = state.tables[kind];
  if (!t) {
    t = buildShapeTable(kind);
    state.tables[kind] = t;
  }
  return t;
}

function resize(state, width, height, dpr) {
  // 列宽按「约 124 列」反推并夹住上限：字符有最小宽度，
  // 太窄会让相邻字形互相重叠糊成一团（实测踩过）。
  var cw = Math2.clamp(Math.round(width / 124), 8, 13);
  var ch = Math.round(cw * 1.45);
  var cols = Math.ceil(width / cw);
  var rows = Math.ceil(height / ch);
  state.cw = cw;
  state.ch = ch;
  state.cols = cols;
  state.rows = rows;
  var n = cols * rows;
  state.glyph = new Uint8Array(n);
  state.bucket = new Int16Array(n);
  state.energy = new Float32Array(n);
  state.energyTmp = new Float32Array(n);
  state.heat = new Float32Array(n);
  initRows(rows);
}

// 一帧：把仿真状态光栅成（字形, 桶）网格，并维护尾迹场。
function raster(w, state, dt) {
  var cols = state.cols, rows = state.rows;
  if (cols === 0) return;
  var cw = state.cw, ch = state.ch;
  var glyph = state.glyph, bucket = state.bucket;
  glyph.fill(0);
  bucket.fill(-1);

  consumeEvents(w, state);
  rasterSharks(w, state);
  depositWake(w, state);
  // 扩散隔帧做：尾迹是慢变的视觉余韵，15Hz 下看不出与每次都扩散的差别，
  // 而这一步实测独占 26ms/帧（整帧光栅的绝大部分）。
  if ((state.frame & 1) === 0) diffuse(state, dt * 2);
  state.frame++;
  markFish(w, state);
}

function consumeEvents(w, state) {
  for (var i = 0; i < w.events.length; i++) {
    var e = w.events[i];
    if (e.kind === "eat") {
      stamp(state.heat, state, e.x, e.y, 2, 1);
      registerHot(state, e.x, e.y, 3);
      stamp(state.energy, state, e.x, e.y, 3, 0.9);
    } else {
      stamp(state.energy, state, e.x, e.y, 6, 1.4);
    }
  }
  w.events.length = 0;
}

function stamp(field, state, x, y, radius, amount) {
  var c0 = Math.floor(x / state.cw);
  var r0 = Math.floor(y / state.ch);
  for (var r = r0 - radius; r <= r0 + radius; r++) {
    for (var c = c0 - radius; c <= c0 + radius; c++) {
      if (c < 0 || r < 0 || c >= state.cols || r >= state.rows) continue;
      var d = Math.sqrt((c - c0) * (c - c0) + (r - r0) * 1.4 * ((r - r0) * 1.4));
      if (d > radius + 0.5) continue;
      var i = r * state.cols + c;
      field[i] = Math.min(1.6, field[i] + amount * (1 - d / (radius + 1)));
    }
  }
}

// 鲨鱼：沿脊线逐格查体型表。ASCII 字形永远是正立的，所以不需要旋转贴图
// （实测旋转贴图 4~12fps，比查表慢一个数量级）。
function rasterSharks(w, state) {
  var cols = state.cols, rows = state.rows, cw = state.cw, ch = state.ch;
  var glyph = state.glyph, bucket = state.bucket;
  for (var si = 0; si < w.sharks.length; si++) {
    var sh = w.sharks[si];
    var table = tableFor(state, sh.kind);
    var L = sh.length;
    var nodes = sh.nodes;
    var cosH = Math.cos(sh.heading), sinH = Math.sin(sh.heading);
    var invL = 1 / L;

    // 包围盒必须沿身体方向覆盖整条长度（身体从吻部向后延伸 L），
    // 横向只需覆盖 VSPAN。按 heading 的朝向分别算两个轴上的半径，
    // 否则横着游的鲨鱼只会画出头部那一小截（实测踩过）。
    var ac = Math.abs(cosH), as = Math.abs(sinH);
    var reachX = Math.ceil((L * ac + L * VSPAN * as) / cw) + 2;
    var reachY = Math.ceil((L * as + L * VSPAN * ac) / ch) + 2;
    var hc = Math.floor(nodes[0] / cw);
    var hr = Math.floor(nodes[1] / ch);

    for (var dr = -reachY; dr <= reachY; dr++) {
      for (var dc = -reachX; dc <= reachX; dc++) {
        var cc = hc + dc, rr = hr + dr;
        if (cc < 0 || cc >= cols || rr < 0 || rr >= rows) continue;
        var wx = (cc + 0.5) * cw - nodes[0];
        var wy = (rr + 0.5) * ch - nodes[1];
        // 转到身体坐标：s 沿吻→尾，v 横向
        var s = (wx * cosH + wy * sinH) * invL;
        if (s < 0 || s >= 1) continue;
        var v = (-wx * sinH + wy * cosH) * invL;
        if (v < -VSPAN || v >= VSPAN) continue;
        var tsi = (s * TS) | 0;
        var tvi = ((v / VSPAN * 0.5 + 0.5) * TV) | 0;
        if (tvi < 0) tvi = 0; else if (tvi >= TV) tvi = TV - 1;
        var cell = table[tsi * TV + tvi];
        if (cell === 0) continue;
        var cat = cell >> 4;
        var ramp = cell & 0x0F;
        var i = rr * cols + cc;
        glyph[i] = ramp;
        if (cat === CAT_BODY) {
          bucket[i] = ramp <= 3 ? BUCKET_BODY2 : (ramp <= 5 ? BUCKET_BODY1 : BUCKET_BODY0);
        } else if (cat === CAT_FIN) {
          bucket[i] = BUCKET_FIN;
        } else {
          bucket[i] = BUCKET_HILITE;
        }
      }
    }
  }
}

function depositWake(w, state) {
  var energy = state.energy;
  for (var i = 0; i < w.fish.length; i++) {
    var f = w.fish[i];
    if (!f.alive) continue;
    var idx = cellIndex(state, f.x, f.y);
    if (idx >= 0) energy[idx] = Math.min(1.6, energy[idx] + 0.012 + f.alarm * 0.03);
  }
  // 尾巴扫过的水最多
  for (var si = 0; si < w.sharks.length; si++) {
    var sh = w.sharks[si];
    for (var k = SHARK_NODES - 6; k < SHARK_NODES; k++) {
      var j = cellIndex(state, sh.nodes[k * 2], sh.nodes[k * 2 + 1]);
      if (j >= 0) energy[j] = Math.min(1.6, energy[j] + 0.05 + sh.speed * 0.0012);
    }
  }
}

// 把 (x,y) 附近 radius 内的格子登记进活跃集合，供 heat 衰减用。
function registerHot(state, x, y, radius) {
  var c0 = Math.floor(x / state.cw), r0 = Math.floor(y / state.ch);
  for (var r = r0 - radius; r <= r0 + radius; r++) {
    for (var c = c0 - radius; c <= c0 + radius; c++) {
      if (c < 0 || r < 0 || c >= state.cols || r >= state.rows) continue;
      var i = r * state.cols + c;
      if (state.heat[i] > 0 && state.hot.indexOf(i) === -1) state.hot.push(i);
    }
  }
}

function cellIndex(state, x, y) {
  var c = Math.floor(x / state.cw);
  var r = Math.floor(y / state.ch);
  if (c < 0 || r < 0 || c >= state.cols || r >= state.rows) return -1;
  return r * state.cols + c;
}

// 模糊 + 衰减：尾迹像涟漪一样扩散开再淡去。
function diffuse(state, dt) {
  var cols = state.cols, rows = state.rows;
  var energy = state.energy, tmp = state.energyTmp, heat = state.heat;
  var decay = Math.exp(-dt * 1.5);
  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < cols; c++) {
      var i = r * cols + c;
      var l = c > 0 ? energy[i - 1] : energy[i];
      var rt = c < cols - 1 ? energy[i + 1] : energy[i];
      var u = r > 0 ? energy[i - cols] : energy[i];
      var d = r < rows - 1 ? energy[i + cols] : energy[i];
      tmp[i] = (energy[i] * 4 + l + rt + u + d) * 0.125 * decay;
    }
  }
  state.energy = tmp;
  state.energyTmp = energy;
  // heat 只在进食瞬间写进极少数格，衰减若全量扫 8436 格纯属浪费；
  // 改为只衰减活跃索引集合（进食时登记、衰减到 0 时摘除）。
  var heatDecay = Math.exp(-dt * 2.2);
  var hot = state.hot;
  for (var a = hot.length - 1; a >= 0; a--) {
    var idx = hot[a];
    var v = heat[idx] * heatDecay;
    heat[idx] = v;
    if (v < 0.001) { hot.splice(a, 1); heat[idx] = 0; }
  }
}

// 每行的字符缓冲与长度，随网格大小重建。必须声明在 buildRows 之前：
// var 只提升声明不提升赋值，写在后面会让首次调用拿到 undefined
// （实测整屏刷成 "undefined"）。
var rowBufs = [];
var rowLen = [];

// 空格模板。必须长到覆盖最宽屏幕的列数（1920 / 13 = 148，加余量）。
// 用定长模板 + substring 取段：每格只做一次截取；
// 若用循环拼串，QML 的解释器会为每格反复分配新字符串，
// 实测那是 buildRows 的主要开销。
var SPACES = (function () {
  var s = "";
  for (var i = 0; i < 512; i++) s += " ";
  return s;
})();

function initRows(rows) {
  rowBufs = [];
  rowLen = [];
  for (var r = 0; r < rows; r++) {
    var a = [];
    var l = [];
    for (var b = 0; b < BUCKETS; b++) { a.push(""); l.push(0); }
    rowBufs.push(a);
    rowLen.push(l);
  }
}

// 每条鱼占一格。近处的鱼先占位，两鱼落进同一格时远的让位。
function markFish(w, state) {
  var cols = state.cols, rows = state.rows;
  var glyph = state.glyph, bucket = state.bucket;
  for (var pass = 0; pass < 2; pass++) {
    for (var i = 0; i < w.fish.length; i++) {
      var f = w.fish[i];
      if (!f.alive) continue;
      if ((f.depth > 0.78 ? 0 : 1) !== pass) continue;
      var idx = cellIndex(state, f.x, f.y);
      if (idx < 0) continue;
      if (glyph[idx] !== 0) continue; // 鲨鱼优先
      glyph[idx] = GLYPH_FISH;
      var glint = Math2.clamp(Math.abs(f.turn) / 3.5, 0, 1);
      var bright = 0.3 + (0.4 * (f.depth - 0.55)) / 0.45 + 0.3 * Math.max(glint, f.alarm);
      bucket[idx] = bright < 0.42 ? BUCKET_FISH0 : (bright < 0.66 ? BUCKET_FISH1 : BUCKET_FISH2);
    }
  }
}

// 把网格拼成按（桶, 行）的整行字符串。这是性能的关键：一次 fillText 画一行。
function buildRows(state) {
  var cols = state.cols, rows = state.rows;
  var glyph = state.glyph, bucket = state.bucket;
  for (var b = 0; b < BUCKETS; b++)
    for (var q = 0; q < rows; q++) { rowBufs[q][b] = ""; rowLen[q][b] = 0; }

  for (var r = 0; r < rows; r++) {
    var base = r * cols;
    for (var c = 0; c < cols; c++) {
      var bk = bucket[base + c];
      if (bk < 0) continue;
      var g = glyph[base + c];
      var ch;
      if (g === GLYPH_FISH) ch = "-";
      else if (bk === BUCKET_FIN) ch = FIN_GLYPHS.charAt(c % FIN_GLYPHS.length);
      else if (bk === BUCKET_HILITE) ch = (c + r) % 7 === 0 ? "o" : RIDGE_GLYPHS.charAt((c + r) % RIDGE_GLYPHS.length);
      else ch = SKIN_RAMP.charAt(Math.min(SKIN_RAMP.length - 1, g - 1));
      // 用空格补齐到目标列，保证字形落在正确的横坐标上
      var cur = rowBufs[r][bk];
      if (cur.length < c) cur += SPACES.substring(0, c - cur.length);
      rowBufs[r][bk] = cur + ch;
    }
  }
  return rowBufs;
}



// 实际绘制。调用方负责设置 font/textAlign/textBaseline 一次。
function paint(ctx, state, w) {
  var cols = state.cols, rows = state.rows, ch = state.ch;
  // buildRows 返回 [行][桶]。外层仍按桶遍历：fillStyle 是 Canvas 上
  // 较贵的状态写入，每桶设一次比每行每桶设一次少一个数量级。
  var lines = buildRows(state);
  var energy = state.energy, heat = state.heat;
  for (var b = 0; b < BUCKETS; b++) {
    var painted = false;
    for (var r = 0; r < rows; r++) {
      var line = lines[r][b];
      if (line === "") continue;
      if (!painted) { ctx.fillStyle = BUCKET_STYLE[b]; painted = true; }
      ctx.fillText(line, 0, r * ch + ch / 2);
    }
  }
  // 尾迹与热斑：只扫真有值的格。绝大多数格子 energy 恒为 0
  // （上游刻意让背景保持全黑），所以按行快速跳过整行空段，
  // 比每格判断两次快得多。
  var cw = state.cw;
  var wakeStyle = ["rgba(110,230,255,0.18)", "rgba(110,230,255,0.38)",
                   "rgba(110,230,255,0.58)", "rgba(110,230,255,0.78)"];
  for (var r = 0; r < rows; r++) {
    var base = r * cols;
    for (var c2 = 0; c2 < cols; c2++) {
      var e = energy[base + c2];
      if (e >= 0.45) {
        var level = Math2.clamp(Math.floor((e - 0.45) * 5), 0, 3);
        ctx.fillStyle = wakeStyle[level];
        ctx.fillRect(Math.round(c2 * cw + cw * 0.66 - 1), Math.round(r * ch + ch * 0.64 - 1), 2, 2);
      }
      var hv = heat[base + c2];
      if (hv >= 0.08) {
        ctx.fillStyle = hv > 0.5 ? "rgba(255,120,60," + hv.toFixed(2) + ")"
                                 : "rgba(220,40,40," + (hv * 1.6).toFixed(2) + ")";
        ctx.fillText(hv > 0.6 ? "*" : "\u00b7", c2 * cw + cw / 2, r * ch + ch / 2);
      }
    }
  }
}
