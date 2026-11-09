.pragma library

// 桌面海洋的仿真：小鱼群与追捕它们的鲨鱼。
// 移植自 stackedlol/ascii-sharks（MIT）的 src/world.ts。
//
// 鱼：Reynolds boids（分离/对齐/聚合）落在 Couzin 式分区里，每条鱼身后
// 有盲区。警戒会在鱼群间一条条传下去（「骚动波」），所以整群会同时惊逃，
// 哪怕只有边缘那几条看得见鲨鱼。逃跑的鱼会朝鲨鱼航线的两侧让开，这正是
// 真实饵球被冲开时那种喷泉状的效果。
//
// 鲨鱼：Reynolds 转向（游荡 + 追捕 + 同类分离）驱动一条 follow-the-leader
// 的脊线。饥饿随时间累积、吃到鱼就下降。它们偏好稀疏处的鱼——密集鱼群会
// 让捕食者犯迷糊——所以落单的鱼才会被吃掉。被吃的鱼过一阵作为新鱼群从
// 画面边缘游回来，种群数量因此保持稳定。
//
// 性能约定：这里每帧跑几百条鱼，而 QML 的 JS 引擎是解释执行的。
// 因此所有每帧数据都用预分配的数组（鱼是数组里的对象，复用一个 tmp），
// 绝不在热路径里新建对象或闭包。

.import "Math.js" as Math2

var SHARK_NODES = 20;

var DEFAULTS = {
  // 只留四条经典鲨鱼：桌面背景上同时出现四种花纹会显得脏，
  // 同一种不同大小反而更像真实海面下的深度层次。
  sharks: [{ kind: "classic", size: 1 }],
  fishPerMegapixel: 4400
};

var FISH_SEPARATION_K = 420;
var FISH_ALIGN_K = 1.4;
var FISH_COHESION_K = 1;
var FISH_FLEE_K = 1100;
var BLIND_COS = -0.6; // 航向两侧约 127° 之内可见

function makeWorld(opts) {
  var w = {
    width: 0,
    height: 0,
    time: 0,
    fish: [],
    sharks: [],
    events: [],
    specs: (opts && opts.sharks && opts.sharks.length) ? opts.sharks : DEFAULTS.sharks,
    fishCap: (opts && opts.fishCap) || 0,
    // 每帧复用的临时对象
    tmp: { x: 0, y: 0 },
    sepX: [],
    sepY: [],
    perception: 60,
    foreignSep: 40,
    bucketCols: 0,
    bucketRows: 0,
    bucketHead: new Int32Array(0),
    bucketCount: new Uint16Array(0),
    bucketNext: new Int32Array(0),
    lastSpawn: 0,
    seeded: false
  };
  return w;
}

// 尺寸变化时重建网格相关参数；首次（或鱼全没了）才播种，
// 之后只把跑出边界的鱼拉回来——否则每次窗口变化都会重开一局。
function resize(w, width, height, cellW, cellH, Species) {
  var first = w.width === 0;
  w.width = width;
  w.height = height;
  // 个人空间按「格」给，保证每条鱼落在自己的格子里，不会叠成一个字。
  w.sepX = [];
  w.sepY = [];
  for (var i = 0; i < Species.SPECIES.length; i++) {
    w.sepX.push(Species.SPECIES[i].spacing[0] * cellW);
    w.sepY.push(Species.SPECIES[i].spacing[1] * cellH);
  }
  w.perception = Math.max(cellH * 3, cellW * 5.5);
  w.foreignSep = cellW * 3;

  if (first || w.fish.length === 0) {
    seed(w, Species);
    return;
  }
  for (var f = 0; f < w.fish.length; f++) {
    w.fish[f].x = Math2.clamp(w.fish[f].x, 0, width);
    w.fish[f].y = Math2.clamp(w.fish[f].y, 0, height);
  }
}

function seed(w, Species) {
  var W = w.width, H = w.height;
  var minSide = Math.min(W, H);
  var baseLength = Math2.clamp(minSide * 0.44, 170, 430);
  var specs = w.specs;
  var n = specs.length;

  w.sharks = [];
  for (var i = 0; i < n; i++) {
    var spec = specs[i];
    var length = baseLength * (spec.size === undefined ? 1 : spec.size);
    var orbitRadius = minSide * Math2.rand(0.28, 0.4);
    var a = (i / n) * Math2.TAU + Math2.rand(-0.4, 0.4);
    var orbitDir = i % 2 === 0 ? 1 : -1;
    var x = W / 2 + Math.cos(a) * orbitRadius * (W / minSide) * 0.9;
    var y = H / 2 + Math.sin(a) * orbitRadius;
    var heading = a + (orbitDir * Math.PI) / 2;
    var nodes = new Float32Array(SHARK_NODES * 2);
    var seg = length / (SHARK_NODES - 1);
    for (var k = 0; k < SHARK_NODES; k++) {
      nodes[k * 2] = x - Math.cos(heading) * seg * k;
      nodes[k * 2 + 1] = y - Math.sin(heading) * seg * k;
    }
    w.sharks.push({
      id: i + 1, kind: spec.kind, length: length, nodes: nodes,
      heading: heading, speed: 30, phase: Math2.rand(0, Math2.TAU), turn: 0,
      hunger: Math2.rand(0.25, 0.75), wander: 0, orbitDir: orbitDir,
      orbitRadius: orbitRadius, target: null, retargetAt: 0,
      depth: spec.size === undefined ? 1 : spec.size
    });
  }
  // 小的（远的）先画，大的（近的）压在上面，才有前后深度。
  w.sharks.sort(function (p, q) { return p.length - q.length; });

  var total = w.fishCap > 0 ? w.fishCap
    : Math2.clamp(Math.round((W * H) / DEFAULTS.fishPerMegapixel), 85, 340);
  w.fish = [];
  while (w.fish.length < total) {
    var species = Species.pickSpecies();
    var sp = Species.SPECIES[species];
    var size = Math.min(Math2.randInt(sp.schoolSize[0], sp.schoolSize[1]), total - w.fish.length);
    var millDir = Math.random() < 0.5 ? 1 : -1;
    var cx = Math2.rand(W * 0.06, W * 0.94);
    var cy = Math2.rand(H * 0.08, H * 0.92);
    // 航向基本水平：真鱼横向巡游远多于上下窜。
    var dir = (Math.random() < 0.5 ? 0 : Math.PI) + Math2.rand(-0.5, 0.5);
    for (var m = 0; m < size; m++) {
      w.fish.push({
        x: cx + Math2.rand(-1, 1) * w.sepX[species] * Math.sqrt(size),
        y: cy + Math2.rand(-1, 1) * w.sepY[species] * Math.sqrt(size) * 0.6,
        vx: Math.cos(dir) * sp.cruise, vy: Math.sin(dir) * sp.cruise,
        species: species, alarm: 0, alive: true, respawnAt: 0,
        phase: Math2.rand(0, Math2.TAU), turn: 0, depth: Math2.rand(0.55, 1), millDir: millDir
      });
    }
  }
  w.bucketNext = new Int32Array(w.fish.length);
  w.seeded = true;
}

function splash(w, x, y) {
  w.events.push({ kind: "splash", x: x, y: y });
  var r = 240;
  for (var i = 0; i < w.fish.length; i++) {
    var f = w.fish[i];
    if (!f.alive) continue;
    var dx = f.x - x, dy = f.y - y;
    var d = Math.sqrt(dx * dx + dy * dy);
    if (d > r || d < 1e-3) continue;
    // 闪光式扩张：附近的鱼全部朝外弹开。
    var k = (1 - d / r) * 260;
    f.vx += (dx / d) * k;
    f.vy += (dy / d) * k;
    f.alarm = 1;
  }
}

function step(w, dt, Species) {
  w.time += dt;
  rebuildHash(w);
  stepFish(w, dt, Species);
  stepSharks(w, dt);
  respawn(w, Species);
}

function rebuildHash(w) {
  var size = w.perception;
  var pad = 2;
  w.bucketCols = Math.ceil(w.width / size) + pad * 2;
  w.bucketRows = Math.ceil(w.height / size) + pad * 2;
  var n = w.bucketCols * w.bucketRows;
  if (w.bucketHead.length !== n) {
    w.bucketHead = new Int32Array(n);
    w.bucketCount = new Uint16Array(n);
  }
  w.bucketHead.fill(-1);
  w.bucketCount.fill(0);
  if (w.bucketNext.length !== w.fish.length) w.bucketNext = new Int32Array(w.fish.length);
  for (var i = 0; i < w.fish.length; i++) {
    var f = w.fish[i];
    if (!f.alive) continue;
    var b = bucketOf(w, f.x, f.y);
    w.bucketNext[i] = w.bucketHead[b];
    w.bucketHead[b] = i;
    w.bucketCount[b]++;
  }
}

function bucketOf(w, x, y) {
  var size = w.perception;
  var c = Math2.clamp(Math.floor(x / size) + 2, 0, w.bucketCols - 1);
  var r = Math2.clamp(Math.floor(y / size) + 2, 0, w.bucketRows - 1);
  return r * w.bucketCols + c;
}

function stepFish(w, dt, Species) {
  var fish = w.fish, sharks = w.sharks;
  var W = w.width, H = w.height, time = w.time;
  var R = w.perception, R2 = R * R;
  var foreignSep = w.foreignSep;
  var size = w.perception;
  var cols = w.bucketCols, rows = w.bucketRows;
  var head = w.bucketHead, next = w.bucketNext;
  var cur = w.tmp;
  var calmDecay = Math.exp(-dt * 0.7);
  var contagion = Math.min(1, dt * 6);

  for (var i = 0; i < fish.length; i++) {
    var f = fish[i];
    if (!f.alive) continue;
    var sp = Species.SPECIES[f.species];
    // 受惊的鱼要更多空间：鱼群会在鲨鱼周围炸开，威胁消退后再收拢。
    var spread = 1 + 1.8 * f.alarm;
    var sepX = w.sepX[f.species] * spread;
    var sepY = w.sepY[f.species] * spread;

    var speed = Math.sqrt(f.vx * f.vx + f.vy * f.vy) || 1;
    var hx = f.vx / speed, hy = f.vy / speed;

    var ax = 0, ay = 0, sx = 0, sy = 0, avx = 0, avy = 0, cx = 0, cy = 0, n = 0;
    var neighbourAlarm = 0;

    var bc = Math2.clamp(Math.floor(f.x / size) + 2, 0, cols - 1);
    var br = Math2.clamp(Math.floor(f.y / size) + 2, 0, rows - 1);
    for (var r = Math.max(0, br - 1); r <= Math.min(rows - 1, br + 1); r++) {
      for (var c = Math.max(0, bc - 1); c <= Math.min(cols - 1, bc + 1); c++) {
        var j = head[r * cols + c];
        while (j !== -1) {
          if (j !== i) {
            var o = fish[j];
            var dx = o.x - f.x, dy = o.y - f.y;
            var d2 = dx * dx + dy * dy;
            if (d2 < R2 && d2 > 1e-6) {
              var d = Math.sqrt(d2);
              // 正后方的盲区
              if ((dx * hx + dy * hy) / d > BLIND_COS) {
                // 椭圆个人空间：横向宽、纵向紧
                var qx = dx / sepX, qy = dy / sepY;
                var q2 = qx * qx + qy * qy;
                if (q2 < 1) {
                  var q = Math.sqrt(q2) || 1e-3;
                  var kk = (1 - q) / q;
                  sx -= qx * kk;
                  sy -= qy * kk;
                }
                if (o.species === f.species) {
                  avx += o.vx; avy += o.vy;
                  cx += dx; cy += dy;
                  n++;
                } else if (d < foreignSep) {
                  // 不同种各自成群
                  var fk = ((1 - d / foreignSep) / d) * 0.6;
                  sx -= dx * fk;
                  sy -= dy * fk;
                }
                if (o.alarm > neighbourAlarm) neighbourAlarm = o.alarm;
              }
            }
          }
          j = next[j];
        }
      }
    }

    ax += sx * FISH_SEPARATION_K;
    ay += sy * FISH_SEPARATION_K;
    if (n > 0) {
      var alignK = FISH_ALIGN_K * sp.align;
      var cohesionK = FISH_COHESION_K * sp.cohesion * (1 - 0.8 * f.alarm);
      ax += (avx / n - f.vx) * alignK + (cx / n) * cohesionK;
      ay += (avy / n - f.vy) * alignK + (cy / n) * cohesionK;
      if (sp.mill > 0) {
        // 绕局部中心转：鱼群旋成一个饵球。
        var cl = Math.sqrt(cx * cx + cy * cy) || 1;
        ax += (-cy / cl) * f.millDir * sp.mill * (1 - f.alarm);
        ay += (cx / cl) * f.millDir * sp.mill * (1 - f.alarm);
      }
    }

    // 捕食者。距离取鲨鱼前半身最近的那一点，所以鱼对两侧也会远远避开。
    var fear = 0;
    for (var si = 0; si < sharks.length; si++) {
      var sh = sharks[si];
      var fearR = sh.length * 0.6 + 60;
      var best = Infinity, bx = 0, by = 0;
      for (var k2 = 0; k2 <= 12; k2 += 3) {
        var nx = sh.nodes[k2 * 2], ny = sh.nodes[k2 * 2 + 1];
        var dd = (f.x - nx) * (f.x - nx) + (f.y - ny) * (f.y - ny);
        if (dd < best) { best = dd; bx = nx; by = ny; }
      }
      var fd = Math.sqrt(best);
      if (fd >= fearR || fd < 1e-3) continue;
      var wgt = 1 - fd / fearR;
      wgt *= wgt;
      var awayX = (f.x - bx) / fd, awayY = (f.y - by) / fd;
      // 喷泉效果：朝鲨鱼航线中你所处的那一侧闪开。
      var shx = Math.cos(sh.heading), shy = Math.sin(sh.heading);
      var side = shx * (f.y - sh.nodes[1]) - shy * (f.x - sh.nodes[0]) >= 0 ? 1 : -1;
      ax += (awayX * 0.7 - shy * side * 0.9) * FISH_FLEE_K * wgt;
      ay += (awayY * 0.7 + shx * side * 0.9) * FISH_FLEE_K * wgt;
      fear = Math.max(fear, Math.sqrt(wgt));
    }

    // 警戒：直接威胁设它，邻居再一跳跳传下去（每跳略弱），并自行消退。
    var alarm = Math.max(f.alarm * calmDecay, fear);
    var relayed = neighbourAlarm * 0.86;
    if (relayed > alarm) alarm += (relayed - alarm) * contagion;
    f.alarm = alarm;

    // 软墙
    var m = 36;
    if (f.x < m) ax += (m - f.x) * 7;
    else if (f.x > W - m) ax -= (f.x - (W - m)) * 7;
    if (f.y < m) ay += (m - f.y) * 7;
    else if (f.y > H - m) ay -= (f.y - (H - m)) * 7;

    // 环境洋流 + 一点点个体躁动
    Math2.current(f.x, f.y, time, cur);
    ax += cur.x * 0.5 + (Math.random() - 0.5) * sp.jitter;
    ay += cur.y * 0.5 + (Math.random() - 0.5) * sp.jitter;
    // 保持水平游动，除非正在逃命。
    ay -= f.vy * sp.verticalDrag * (1 - 0.7 * f.alarm);

    // 向偏好速度收敛，恐慌时偏好速度更高。
    var preferred = sp.cruise * (1 + 1.3 * f.alarm);
    ax += (preferred - speed) * hx * 1.6;
    ay += (preferred - speed) * hy * 1.6;

    var before = Math.atan2(f.vy, f.vx);
    f.vx += ax * dt;
    f.vy += ay * dt;
    var maxSpeed = sp.maxSpeed * (1 + 1.8 * f.alarm);
    var s = Math.sqrt(f.vx * f.vx + f.vy * f.vy);
    if (s > maxSpeed) { f.vx *= maxSpeed / s; f.vy *= maxSpeed / s; }
    else if (s < sp.minSpeed && s > 1e-3) { f.vx *= sp.minSpeed / s; f.vy *= sp.minSpeed / s; }
    f.turn += (Math2.angleDiff(before, Math.atan2(f.vy, f.vx)) / dt - f.turn) * Math.min(1, dt * 8);
    f.phase += dt * (7 + Math.sqrt(f.vx * f.vx + f.vy * f.vy) * 0.12);
    f.x = Math2.clamp(f.x + f.vx * dt, -60, W + 60);
    f.y = Math2.clamp(f.y + f.vy * dt, -60, H + 60);
  }
}

function stepSharks(w, dt) {
  var sharks = w.sharks, W = w.width, H = w.height, time = w.time;
  var minSide = Math.min(W, H);
  var cxW = W / 2, cyW = H / 2;

  for (var si = 0; si < sharks.length; si++) {
    var sh = sharks[si];
    var L = sh.length;
    var nodes = sh.nodes;
    var hx = nodes[0], hy = nodes[1];

    sh.hunger = Math.min(1, sh.hunger + dt * 0.03);

    // 惯性
    var dx = Math.cos(sh.heading), dy = Math.sin(sh.heading);

    // 游荡：吻前一个圆上缓慢漂移的偏移量
    sh.wander = Math2.clamp(sh.wander + (Math.random() - 0.5) * dt * 3.2, -1.1, 1.1);
    dx += Math.cos(sh.heading + sh.wander) * 0.45;
    dy += Math.sin(sh.heading + sh.wander) * 0.45;

    // 捕食
    if (time >= sh.retargetAt) {
      sh.target = findPrey(w, sh);
      sh.retargetAt = time + 0.45;
    }
    var t = sh.target;
    var hunting = false;
    var closing = 0;
    if (t && t.alive && sh.hunger > 0.3) {
      // 追捕：瞄准鱼即将到达的位置
      var tx = t.x + t.vx * 0.35 - hx;
      var ty = t.y + t.vy * 0.35 - hy;
      var td = Math.sqrt(tx * tx + ty * ty) || 1;
      var tw = 1.4 + 2.6 * sh.hunger;
      dx += (tx / td) * tw;
      dy += (ty / td) * tw;
      hunting = true;
      closing = Math2.clamp(1 - td / (L * 0.9), 0, 1);
    } else {
      // 巡游：绕标题区慢慢兜圈
      var rx = (hx - cxW) / (W / minSide);
      var ry = hy - cyW;
      var r = Math.sqrt(rx * rx + ry * ry) || 1;
      var radius = sh.orbitRadius * (1 + 0.15 * Math.sin(time * 0.05 + sh.id));
      var radial = Math2.clamp((radius - r) / radius, -1, 1);
      dx += ((-ry / r) * sh.orbitDir + (rx / r) * radial * 0.9) * 0.55;
      dy += ((rx / r) * sh.orbitDir + (ry / r) * radial * 0.9) * 0.55;
    }

    // 给同类让位
    for (var oi = 0; oi < sharks.length; oi++) {
      if (oi === si) continue;
      var other = sharks[oi];
      for (var k = 0; k < SHARK_NODES; k += 4) {
        var ox = hx - other.nodes[k * 2];
        var oy = hy - other.nodes[k * 2 + 1];
        var od = Math.sqrt(ox * ox + oy * oy);
        var range = (L + other.length) * 0.45;
        if (od < range && od > 1e-3) {
          var ow = (1 - od / range) * 3;
          dx += (ox / od) * ow;
          dy += (oy / od) * ow;
        }
      }
    }

    // 中心区域留白：一个软性椭圆禁泳区
    var ex = (hx - cxW) / (W * 0.3);
    var ey = (hy - cyW) / (H * 0.16);
    var e2 = ex * ex + ey * ey;
    if (e2 < 1) {
      var e = Math.sqrt(e2) || 1e-3;
      var ew = (1 - e) * (hunting ? 1 : 2.5);
      dx += (ex / e) * ew;
      dy += (ey / e) * ew;
    }

    // 吻部一出画就掉头：身体偶尔滑出屏幕，但鲨鱼不会一去不回。
    var over = Math.max(-hx, hx - W, -hy, hy - H);
    if (over > -L * 0.05) {
      var ovw = Math2.clamp((over + L * 0.05) / (L * 0.35), 0, 1) * 3.5;
      var toX = cxW - hx, toY = cyW - hy;
      var toD = Math.sqrt(toX * toX + toY * toY) || 1;
      dx += (toX / toD) * ovw;
      dy += (toY / toD) * ovw;
    }

    var desired = Math.atan2(dy, dx);
    // 鲨鱼不能原地转身：转弯半径随速度变大。
    var agility = Math.min(hunting ? 1.7 + closing : 0.8, sh.speed / (L * 0.22));
    var maxTurn = agility * dt;
    var turned = Math2.clamp(Math2.angleDiff(sh.heading, desired), -maxTurn, maxTurn);
    sh.heading += turned;
    sh.turn += (turned / dt - sh.turn) * Math.min(1, dt * 3);

    var cruise = 30 + L * 0.04;
    var targetSpeed = hunting ? cruise * (1.45 + closing * 1.5) : cruise;
    sh.speed += (targetSpeed - sh.speed) * Math.min(1, dt * 1.1);
    sh.phase += dt * (2 + sh.speed / 24);

    nodes[0] += Math.cos(sh.heading) * sh.speed * dt;
    nodes[1] += Math.sin(sh.heading) * sh.speed * dt;

    // follow-the-leader 脊线，每个关节有转角上限，所以身体最多弯成 C 形，
    // 永远不会折回自己身上。
    var seg = L / (SHARK_NODES - 1);
    var maxBend = 0.16;
    var prevAngle = sh.heading + Math.PI;
    for (var kk = 1; kk < SHARK_NODES; kk++) {
      var px = nodes[(kk - 1) * 2], py = nodes[(kk - 1) * 2 + 1];
      var ang = Math.atan2(nodes[kk * 2 + 1] - py, nodes[kk * 2] - px);
      ang = prevAngle + Math2.clamp(Math2.angleDiff(prevAngle, ang), -maxBend, maxBend);
      nodes[kk * 2] = px + Math.cos(ang) * seg;
      nodes[kk * 2 + 1] = py + Math.sin(ang) * seg;
      prevAngle = ang;
    }

    // 进食
    if (sh.hunger > 0.15) {
      var mouthR = L * 0.05 + 8;
      var mx = nodes[0], my = nodes[1];
      for (var fi = 0; fi < w.fish.length; fi++) {
        var ff = w.fish[fi];
        if (!ff.alive) continue;
        if ((ff.x - mx) * (ff.x - mx) + (ff.y - my) * (ff.y - my) < mouthR * mouthR) {
          ff.alive = false;
          ff.respawnAt = time + Math2.rand(3, 8);
          sh.hunger = Math.max(0, sh.hunger - 0.16);
          w.events.push({ kind: "eat", x: ff.x, y: ff.y });
        }
      }
    }
  }
}

// 在前向锥里挑猎物，偏好近处、且所在网格稀疏（落单）的鱼。
function findPrey(w, sh) {
  var range = sh.length * 0.9 + 160;
  var hx = sh.nodes[0], hy = sh.nodes[1];
  var fx = Math.cos(sh.heading), fy = Math.sin(sh.heading);
  var best = null, bestScore = Infinity, currentScore = Infinity;

  for (var i = 0; i < w.fish.length; i++) {
    var f = w.fish[i];
    if (!f.alive) continue;
    var dx = f.x - hx, dy = f.y - hy;
    var d = Math.sqrt(dx * dx + dy * dy);
    if (d > range || d < 1e-3) continue;
    var cos = (dx * fx + dy * fy) / d;
    if (cos < 0.2) continue;
    var crowd = w.bucketCount[bucketOf(w, f.x, f.y)];
    var score = d * (1 + (1 - cos) * 0.8) * (1 + crowd * 0.07);
    if (score < bestScore) { bestScore = score; best = f; }
    if (f === sh.target) currentScore = score;
  }
  // 除非别处明显更好，否则咬住当前目标不放。
  if (sh.target && currentScore < bestScore * 1.3) return sh.target;
  return best;
}

function respawn(w, Species) {
  var time = w.time, W = w.width, H = w.height;
  var due = [];
  for (var i = 0; i < w.fish.length; i++) {
    var f = w.fish[i];
    if (!f.alive && f.respawnAt <= time) due.push(f);
  }
  if (due.length === 0) return;
  if (due.length < 6 && time - w.lastSpawn < 9) return;
  w.lastSpawn = time;

  // 新鱼群从随机一条边游进来。
  var side = Math2.randInt(0, 3);
  var along = Math2.rand(0.15, 0.85);
  var x = side === 0 ? -20 : side === 1 ? W + 20 : along * W;
  var y = side === 2 ? -20 : side === 3 ? H + 20 : along * H;
  var inward = Math.atan2(H / 2 - y, W / 2 - x) + Math2.rand(-0.5, 0.5);
  var species = Species.pickSpecies();
  var sp = Species.SPECIES[species];
  var millDir = Math.random() < 0.5 ? 1 : -1;
  var cap = Math.min(due.length, sp.schoolSize[1]);
  for (var k = 0; k < cap; k++) {
    var g = due[k];
    g.alive = true;
    g.species = species;
    g.alarm = 0;
    g.turn = 0;
    g.millDir = millDir;
    g.x = x + Math2.rand(-1, 1) * w.perception;
    g.y = y + Math2.rand(-1, 1) * w.perception;
    g.vx = Math.cos(inward) * sp.cruise * 1.4;
    g.vy = Math.sin(inward) * sp.cruise * 1.4;
  }
}
