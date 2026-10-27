#!/usr/bin/env bash
# horizon.setup — Omasnap 汉化层测试。
#
# 这层的特殊之处：上游没有任何 i18n 设施，汉化 = 改源码 + 重新编译。
# 所以测试的重点不是「文案对不对」，而是三件会静默出错的事：
#   ① fail-closed：上游一改文案，词表就必须整条判定失配、拒绝产出二进制，
#      绝不能编出一个半汉化的程序（那是用户看不见的坏）。
#   ② 词法正确：多行拼接的 C++ 字面量必须被当成一个逻辑串，否则会漏译；
#      而裸字符串（const char* 数组）不能用裸词替换，否则误伤别处。
#   ③ 状态即真相：stock/zh/stale/missing 四态从「实际生效的二进制」读出。
#
# 全部在临时目录跑：不联网、不编译、不碰 ~/.local。真编译留给人手工验证。
#
# 运行：bash tests/omasnap_zh_test.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected=[$3] actual=[$2]"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

APPLY="$ROOT/lib/apply-omasnap-zh.py"
TABLE="$ROOT/lib/omasnap-zh.json"

printf '\n=== 0. 词表资产本身 ===\n'
[ -f "$APPLY" ] && ok "应用器存在" || bad "缺 lib/apply-omasnap-zh.py"
[ -f "$TABLE" ] && ok "词表存在" || bad "缺 lib/omasnap-zh.json"
python3 - "$TABLE" <<'PY' && ok "词表可解析且有 strings" || bad "词表结构不对"
import json,sys
d=json.load(open(sys.argv[1]))
assert isinstance(d.get("strings"), dict) and len(d["strings"]) > 300
PY
# 键里不能有中文（说明误把译文当键），值里必须有中文（说明真的译了）。
python3 - "$TABLE" <<'PY' && ok "键为英文、值为中文（抽查）" || bad "键值方向错了"
import json,sys,re
d=json.load(open(sys.argv[1]))["strings"]
bad_keys=[k for k in d if re.search(r'[\u4e00-\u9fff]', k)]
assert not bad_keys, bad_keys[:3]
translated=[v for k,v in d.items() if v != k]
assert translated and all(re.search(r'[\u4e00-\u9fff]', v) for v in translated), "有译文不含中文"
PY

printf '\n=== 1. 词法：多行拼接的 QStringLiteral 必须整体命中 ===\n'
mkdir -p "$TMP/r1/src"
cat > "$TMP/r1/src/one.cpp" <<'CPP'
void f() {
  setStatus(QStringLiteral(
      "Drag to select an area"));
  setStatus(QStringLiteral("Highlighter · Snap · text height automatic · wheel "
                           "sets off-text size %1 · H toggles Normal"));
}
CPP
cat > "$TMP/one.json" <<'JSON'
{"strings": {
  "Drag to select an area": "拖拽选择区域",
  "Highlighter · Snap · text height automatic · wheel sets off-text size %1 · H toggles Normal":
    "荧光笔 · 吸附 · 文字高度自动 · 滚轮设置文字外尺寸 %1 · H 切换普通"
}}
JSON
out=$(python3 "$APPLY" --table "$TMP/one.json" --root "$TMP/r1" 2>&1)
grep -q '覆盖 2/2 条' <<<"$out" && ok "两条（含跨行拼接）都命中" || bad "拼接未命中" "$out"
grep -q '拖拽选择区域' "$TMP/r1/src/one.cpp" && ok "单行写入正确" || bad "未写入译文"
grep -q '荧光笔 · 吸附' "$TMP/r1/src/one.cpp" && ok "跨行拼写成一个译文" || bad "跨行拼接处理错误"
# 替换后必须仍是合法的一行：不能再残留被拼接的两段英文
grep -q 'sets off-text size %1 · H toggles Normal' "$TMP/r1/src/one.cpp" \
  && bad "残留英文片段" || ok "无英文残片"

printf '\n=== 2. fail-closed：词表条目没命中时报错且不改动文件 ===\n'
mkdir -p "$TMP/r2/src"
printf 'void g() { setStatus(QStringLiteral("Upstream changed this")); }\n' > "$TMP/r2/src/two.cpp"
cp "$TMP/r2/src/two.cpp" "$TMP/two.orig"
cat > "$TMP/two.json" <<'JSON'
{"strings": {"Drag to select an area": "拖拽选择区域"}}
JSON
python3 "$APPLY" --table "$TMP/two.json" --root "$TMP/r2" >/dev/null 2>&1
eq "未命中时退出码为 1" "$?" "1"
cmp -s "$TMP/r2/src/two.cpp" "$TMP/two.orig" && ok "未命中不改动源码" || bad "未命中却改了文件"

printf '\n=== 3. 裸字符串：按带上下文片段替换，不误伤同名裸词 ===\n'
mkdir -p "$TMP/r3/src"
cat > "$TMP/r3/src/three.cpp" <<'CPP'
constexpr std::array<RegionAspect, 2> kAspects{{{"Free", 0, 0}, {"1:1", 1, 1}}};
QString other = QString::fromLatin1("Free");
CPP
cat > "$TMP/three.json" <<'JSON'
{"strings": {}, "fragments": {"{\"Free\", 0, 0}": "{\"自由\", 0, 0}"}}
JSON
python3 "$APPLY" --table "$TMP/three.json" --root "$TMP/r3" >/dev/null 2>&1
grep -qF '{"自由", 0, 0}' "$TMP/r3/src/three.cpp" && ok "数组标签被译" || bad "片段未替换"
# fromLatin1("Free") 不在替换片段里，必须原样留着（它可能是逻辑值）
grep -qF 'fromLatin1("Free")' "$TMP/r3/src/three.cpp" && ok "同名裸词未被误伤" || bad "误伤了他处的 Free"

printf '\n=== 4. 状态：stock/zh/stale/missing 从实际二进制读出 ===\n'
export OMASNAP_BIN_DIR="$TMP/bin"
export OMASNAP_ZH_MARK="$OMASNAP_BIN_DIR/.zh-version"
export OMASNAP_ZH_PIN="1.23.0"
mkdir -p "$OMASNAP_BIN_DIR" "$TMP/emptybin"
# shellcheck source=../lib/omasnapzh.sh
source "$ROOT/lib/omasnapzh.sh"

# 用 PATH 桩模拟「装没装 omasnap」
mkdir -p "$TMP/stub"
printf '#!/bin/sh\nexit 0\n' > "$TMP/stub/omasnap"
chmod +x "$TMP/stub/omasnap"

PATH="$TMP/nonexistent:/usr/bin:/bin" omasnapzh_state >/dev/null 2>&1
eq "没有 omasnap → missing" "$(PATH=/usr/bin:/bin omasnapzh_state)" "missing"

export PATH="$TMP/stub:$PATH"
omasnapzh_state >/dev/null 2>&1
eq "有启动器但没有 bin → missing" "$(omasnapzh_state)" "missing"

printf 'stock' > "$OMASNAP_BIN_DIR/omasnap.bin"
eq "只有 bin、无标记 → stock" "$(omasnapzh_state)" "stock"

printf '1.23.0\n' > "$OMASNAP_ZH_MARK"
eq "标记与 pin 一致 → zh" "$(omasnapzh_state)" "zh"

printf '1.22.0\n' > "$OMASNAP_ZH_MARK"
eq "标记与 pin 不一致 → stale" "$(omasnapzh_state)" "stale"

printf '\n=== 5. revert：无汉化版时拒绝，不静默失败 ===\n'
printf '1.23.0\n' > "$OMASNAP_ZH_MARK"
omasnapzh_revert >/dev/null 2>&1
eq "没有 stock 二进制时 revert 失败" "$?" "1"

printf 'x' > "$OMASNAP_BIN_DIR/omasnap.stock.bin"
printf 'y' > "$OMASNAP_BIN_DIR/omasnap.zh.bin"
chmod +x "$OMASNAP_BIN_DIR/omasnap.stock.bin" "$OMASNAP_BIN_DIR/omasnap.zh.bin"
ln -sfn omasnap.zh.bin "$OMASNAP_BIN_DIR/omasnap.bin"
printf '1.23.0\n' > "$OMASNAP_ZH_MARK"
omasnapzh_revert >/dev/null 2>&1
eq "revert 后退出码 0" "$?" "0"
eq "revert 后指向 stock" "$(readlink "$OMASNAP_BIN_DIR/omasnap.bin")" "omasnap.stock.bin"
[ -f "$OMASNAP_ZH_MARK" ] && bad "revert 后标记未清" || ok "revert 后标记已清"
eq "revert 后状态为 stock" "$(omasnapzh_state)" "stock"
[ -f "$OMASNAP_BIN_DIR/omasnap.zh.bin" ] && ok "汉化二进制保留（再次开启不必重编译）" \
  || bad "汉化二进制被删了"

printf '\n=== 6. 面板行契约：7 列 TAB 分隔，state 可被面板识别 ===\n'
printf '1.23.0\n' > "$OMASNAP_ZH_MARK"
row=$(omasnapzh_row)
eq "恰好 7 列" "$(awk -F'\t' '{print NF}' <<<"$row")" "7"
eq "首列是 omasnap-ui（面板按 id 路由）" "$(cut -f1 <<<"$row")" "omasnap-ui"
eq "zh 态下 state 为 zh" "$(cut -f3 <<<"$row")" "zh"
rm -f "$OMASNAP_ZH_MARK"
eq "stock 态下 state 为 stock" "$(cut -f3 <<<"$(omasnapzh_row)")" "stock"

printf '\n=== 7. setup.sh 路由：zhcn 命令覆盖 omasnap ===\n'
grep -qE '^    omasnap-zh)$' "$ROOT/setup.sh" && ok "setup.sh 有 omasnap-zh 子命令" || bad "缺子命令"
grep -q 'omasnap-zh-install)' "$ROOT/setup.sh" && ok "有安装子命令" || bad "缺安装子命令"
grep -q 'omasnap-zh-revert)' "$ROOT/setup.sh" && ok "有还原子命令" || bad "缺还原子命令"
grep -q 'source "$HERE/lib/omasnapzh.sh"' "$ROOT/setup.sh" && ok "setup.sh 引入了本层" || bad "未引入"
# 映射表层必须把 omasnap 路由过去，否则面板按钮点了没反应
grep -q 'omasnap-ui' "$ROOT/lib/zhcn.sh" && ok "zhcn 层路由 omasnap-ui" || bad "zhcn 未路由"
grep -q 'stale:' "$ROOT/ZhcnTab.qml" && ok "面板认识 stale 状态" || bad "面板缺 stale 文案"

# 回归闸门：面板按钮只看 clean/applied 时，omasnap 的 stock/zh 让按钮永远
# 点不动（真发生过）。这里断言：本层汇报的每种 state 都能被面板的
# canApply / canRevert 判据覆盖。
for st in stock zh stale; do
  if [ "$st" = "zh" ]; then
    grep -q "canRevert: ({ applied: true, zh: true })" "$ROOT/ZhcnTab.qml" \
      && ok "面板可还原 $st 态" || bad "面板不能还原 $st 态（按钮会点不动）"
  else
    grep -q "canApply: ({ clean: true, stock: true, stale: true })" "$ROOT/ZhcnTab.qml" \
      && ok "面板可汉化 $st 态" || bad "面板不能汉化 $st 态（按钮会点不动）"
  fi
done
# 按钮本身必须走判据，不能再写死某个状态词
grep -q 'modelData.state === "clean"' "$ROOT/ZhcnTab.qml" \
  && bad "按钮仍写死 clean，会漏掉 stock" || ok "按钮已改用统一判据"

printf '\n---------------------------------------\n'
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
