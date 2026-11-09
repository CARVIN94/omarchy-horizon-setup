.pragma library

// 桌面海洋的数学基元。移植自 stackedlol/ascii-sharks（MIT）的 src/math.ts。
//
// 全部无状态、无 IO：这里只做算术，方便被 World.js / Render.js 各自引用。

var TAU = Math.PI * 2;

function clamp(v, lo, hi) {
  return v < lo ? lo : v > hi ? hi : v;
}

function rand(lo, hi) {
  return lo + Math.random() * (hi - lo);
}

function randInt(lo, hi) {
  return Math.floor(rand(lo, hi + 1));
}

function smoothstep(e0, e1, x) {
  var t = clamp((x - e0) / (e1 - e0), 0, 1);
  return t * t * (3 - 2 * t);
}

// 从 a 到 b 的最短有符号角，落在 (-PI, PI]。鲨鱼转向与鱼群转向都用它，
// 直接用减法会在 ±PI 处跳变，表现为整条鱼突然抽一下。
function angleDiff(a, b) {
  var d = (b - a) % TAU;
  if (d > Math.PI) d -= TAU;
  if (d < -Math.PI) d += TAU;
  return d;
}

// 整数哈希 → [0,1)。同一格在每一帧得到同一个值，鲨鱼皮肤纹理才不会闪。
function hash3(x, y, z) {
  var h = (Math.imul(x | 0, 374761393) ^ Math.imul(y | 0, 668265263) ^ Math.imul(z | 0, 1442695041)) | 0;
  h = Math.imul(h ^ (h >>> 13), 1274126177);
  h ^= h >>> 16;
  return (h >>> 0) / 4294967296;
}

var K1 = 1 / 260;
var K2 = 1 / 310;
var K3 = 1 / 190;
var CURRENT_SCALE = 3400;

// 无源无汇的洋流：一个缓慢漂移的流函数 ψ 的旋度。
// 正因为无散度，它只会把鱼群整体带着走，不会把它们全挤到一个角落。
// 结果写进 out，避免每帧为每条鱼分配对象（QML 的 JS 引擎没有 JIT，
// 分配开销在这里是实打实的帧时间）。
function current(x, y, t, out) {
  var a = x * K1 + t * 0.07;
  var b = y * K2 - t * 0.05;
  var c = (x + y) * K3 + t * 0.11;
  out.x = (-K2 * Math.sin(a) * Math.sin(b) + 0.5 * K3 * Math.cos(c)) * CURRENT_SCALE;
  out.y = (-K1 * Math.cos(a) * Math.cos(b) - 0.5 * K3 * Math.cos(c)) * CURRENT_SCALE;
  return out;
}
