.pragma library

// 鱼群物种参数。移植自 stackedlol/ascii-sharks（MIT）的 src/species.ts。
//
// 五种鱼靠行为权重的不同组合产生不同的集体形状（Couzin 等 2002）：
// 对齐强 → 极化成带状鱼群；对齐弱 → 散成一团；切向拉力 → 绕圈成饵球。
// 这些数值不是随手调的，改一个就会让某一种鱼失去自己的性格。

var SPECIES = [
  { name: "sardine",    cruise: 36, maxSpeed: 64, minSpeed: 18, weight: 3,
    schoolSize: [18, 28], spacing: [1.8, 1.1], align: 1.6, cohesion: 1.6,
    jitter: 40, mill: 70, verticalDrag: 0.5 },
  { name: "anchovy",    cruise: 46, maxSpeed: 78, minSpeed: 22, weight: 3,
    schoolSize: [20, 32], spacing: [1.5, 1.0], align: 3.2, cohesion: 0.45,
    jitter: 30, mill: 0, verticalDrag: 1.4 },
  { name: "silverside", cruise: 40, maxSpeed: 70, minSpeed: 20, weight: 3,
    schoolSize: [12, 20], spacing: [2.0, 1.1], align: 2.4, cohesion: 1.1,
    jitter: 35, mill: 0, verticalDrag: 1.6 },
  { name: "mackerel",   cruise: 32, maxSpeed: 60, minSpeed: 16, weight: 2,
    schoolSize: [5, 9],   spacing: [2.6, 1.3], align: 2.0, cohesion: 0.9,
    jitter: 25, mill: 0, verticalDrag: 2.0 },
  { name: "goby",       cruise: 26, maxSpeed: 56, minSpeed: 10, weight: 1,
    schoolSize: [8, 12],  spacing: [1.4, 1.1], align: 0.35, cohesion: 1.4,
    jitter: 110, mill: 0, verticalDrag: 0.3 }
];

var TOTAL_WEIGHT = 0;
for (var i = 0; i < SPECIES.length; i++) TOTAL_WEIGHT += SPECIES[i].weight;

// 按权重抽一种鱼：沙丁鱼/鳀鱼/银鱼各 3 份、鲭鱼 2 份、虾虎鱼 1 份。
function pickSpecies() {
  var r = Math.random() * TOTAL_WEIGHT;
  for (var k = 0; k < SPECIES.length; k++) {
    r -= SPECIES[k].weight;
    if (r <= 0) return k;
  }
  return 0;
}
