#!/usr/bin/env bash
# horizon.setup 插件汉化层测试。全部使用临时 fixture 映射表与假插件目录，
# 不触碰 ~/.local/share/omarchy-zh-cn/ 与真实插件。
#
# 核心闸门：
#   ① 幂等：apply 两次 == apply 一次；revert 后与原始字节逐位一致。
#   ② fail-closed：任何一条失配，apply/revert 整体拒绝且文件一字不动。
#   ③ 状态即真相：clean/applied/mismatch/missing 四态照实汇报，不猜。
#
# 运行：bash tests/zhcn_test.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected=[$3] actual=[$2]"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---- 桩件：假插件目录 + fixture 映射表 -------------------------------------
export ZH_ROOT="$TMP/zh"
export ZH_APPLY="$ZH_ROOT/apply-zh.py"
export ZH_MAPS="$ZH_ROOT/maps"
mkdir -p "$ZH_MAPS" "$TMP/plugin-a"
cp "$HOME/.local/share/omarchy-zh-cn/apply-zh.py" "$ZH_APPLY"

cat > "$TMP/plugin-a/View.qml" <<'EOF'
Item {
  text: "Hello"
  label: "World"
}
EOF
cp "$TMP/plugin-a/View.qml" "$TMP/plugin-a/View.qml.orig"

cat > "$ZH_MAPS/test.hello.json" <<EOF
{
  "id": "test.hello",
  "title": "问候",
  "root": "$TMP/plugin-a",
  "replacements": [
    { "file": "View.qml", "find": "text: \\"Hello\\"", "replace": "text: \\"你好\\"", "count": 1 },
    { "file": "View.qml", "find": "label: \\"World\\"", "replace": "label: \\"世界\\"", "count": 1 }
  ]
}
EOF

# 缺目录的映射表（missing 态）
cat > "$ZH_MAPS/test.ghost.json" <<EOF
{ "id": "test.ghost", "title": "幽灵", "root": "$TMP/nope", "replacements": [] }
EOF

# ---- 载入被测层 -------------------------------------------------------------
# shellcheck source=../lib/zhcn.sh
source "$ROOT/lib/zhcn.sh"

row() { zhcn_rows | awk -F'\t' -v id="$1" '$1 == id'; }
field() { row "$1" | cut -f"$2"; }

# ---- ① 状态四态 -------------------------------------------------------------
eq "clean 态如实汇报" "$(field test.hello 3)" "clean"
eq "missing 态如实汇报" "$(field test.ghost 3)" "missing"
eq "行契约 7 列" "$(row test.hello | awk -F'\t' '{print NF}')" "7"
eq "title 走映射表" "$(field test.hello 2)" "问候"

# ---- ② 应用 + 幂等 ----------------------------------------------------------
zhcn_apply test.hello >/dev/null
eq "apply 后转 applied" "$(field test.hello 3)" "applied"
eq "计数正确" "$(field test.hello 4):$(field test.hello 5)" "2:0"
grep -q '你好' "$TMP/plugin-a/View.qml" && ok "中文落入文件" || bad "中文落入文件"

cp "$TMP/plugin-a/View.qml" "$TMP/after-first"
zhcn_apply test.hello >/dev/null
eq "二次 apply 字节不变（幂等）" "$(cmp -s "$TMP/after-first" "$TMP/plugin-a/View.qml" && echo same)" "same"

# ---- ③ 还原与原始逐位一致 ---------------------------------------------------
zhcn_revert test.hello >/dev/null
eq "revert 后回 clean" "$(field test.hello 3)" "clean"
eq "revert 与原始逐位一致" "$(cmp -s "$TMP/plugin-a/View.qml.orig" "$TMP/plugin-a/View.qml" && echo same)" "same"

# ---- ④ fail-closed：失配时整体拒绝、文件不动 --------------------------------
# 上游改动把 find 改掉一条 → mismatch
cat > "$TMP/plugin-a/View.qml" <<'EOF'
Item {
  text: "Hello!"
  label: "World"
}
EOF
cp "$TMP/plugin-a/View.qml" "$TMP/before-mismatch"
eq "mismatch 态如实汇报" "$(field test.hello 3)" "mismatch"
if zhcn_apply test.hello >/dev/null 2>&1; then
  bad "失配时 apply 必须非 0 退出"
else
  ok "失配时 apply 非 0 退出"
fi
eq "失配时文件一字不动" "$(cmp -s "$TMP/before-mismatch" "$TMP/plugin-a/View.qml" && echo same)" "same"

# ---- ⑤ 未知 id 拒绝 ---------------------------------------------------------
if zhcn_apply no.such.id >/dev/null 2>&1; then
  bad "未知 id 必须非 0 退出"
else
  ok "未知 id 非 0 退出"
fi

echo
echo "zhcn_test: $PASS ok, $FAIL failed"
[ "$FAIL" -eq 0 ]
